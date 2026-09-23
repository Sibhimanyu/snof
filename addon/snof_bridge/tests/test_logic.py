"""Pure-logic checks for the bridge. No network, no Firebase, no HA.

Run from the add-on directory:  python3 tests/test_logic.py
"""
import asyncio
import logging
import re
import sys
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
logging.disable(logging.CRITICAL)

from bridge.commands import CommandConsumer  # noqa: E402
from bridge.mapper import StateMapper, filter_attributes  # noqa: E402
from bridge.registry import Registry  # noqa: E402
from bridge import vendors  # noqa: E402  (pure: no network, no deps)
from bridge.irrigation import (IrrigationRunner, REPORT_LABELS,  # noqa: E402
                               REPORT_TYPES)

CFG = types.SimpleNamespace(
    exclude_entities=frozenset({"sensor.noisy"}),
    exclude_domains=frozenset({"automation"}),
    include_domains=frozenset(),
    expose_location=False,
)


def build():
    reg = Registry()
    reg.load(
        areas=[
            {"area_id": "pump_house", "name": "Pump House", "icon": "mdi:water-pump"},
            {"area_id": "orchard", "name": "North Orchard"},
        ],
        devices=[{"id": "dev1", "area_id": "pump_house"}],
        entities=[
            {"entity_id": "light.pump_main", "device_id": "dev1"},
            {"entity_id": "sensor.soil", "area_id": "orchard", "device_id": "dev1"},
            {"entity_id": "switch.stray"},
        ],
    )
    return reg, StateMapper(CFG, reg)


def test_room_resolution():
    reg, _ = build()
    assert reg.area_for("light.pump_main") == "pump_house"   # inherited from device
    assert reg.area_for("sensor.soil") == "orchard"          # entity overrides device
    assert reg.area_for("switch.stray") == "unassigned"
    assert reg.area_for("light.never_seen") == "unassigned"


def test_publish_gating():
    _, m = build()
    assert m.should_publish("light.pump_main")
    assert not m.should_publish("automation.x")
    assert not m.should_publish("sensor.noisy")
    assert not m.should_publish("device_tracker.car")
    assert not m.should_publish("person.sibhi")


def test_no_secrets_or_gps_escape():
    leaky = {
        "friendly_name": "Gate Cam", "access_token": "SECRET123",
        "entity_picture": "/api/camera_proxy/x?token=abc",
        "latitude": 11.01, "longitude": 76.9,
        "stream_source": "rtsp://user:pw@10.0.0.5",
        "device_class": "motion", "battery_level": 87,
    }
    out = filter_attributes(leaky, domain="camera", expose_location=False)
    for banned in ("access_token", "entity_picture", "latitude", "longitude", "stream_source"):
        assert banned not in out, f"leaked {banned}"
    assert out["device_class"] == "motion" and out["battery_level"] == 87


def test_node_shape_and_key_legality():
    _, m = build()
    domain, obj, node = m.to_node({
        "entity_id": "sensor.soil", "state": "42.5",
        "attributes": {"friendly_name": "Soil Moisture", "unit_of_measurement": "%",
                       "device_class": "moisture", "access_token": "nope"},
        "last_changed": "2026-09-21T05:00:00+00:00",
        "last_updated": "2026-09-21T05:00:00+00:00",
    })
    assert (domain, obj) == ("sensor", "soil")
    assert node["area"] == "orchard" and node["name"] == "Soil Moisture"
    assert "access_token" not in node["attrs"]
    # RTDB rejects . $ # [ ] / in keys; the domain/object_id split must stay safe.
    for seg in f"farms/snof/entities/{domain}/{obj}".split("/"):
        assert re.fullmatch(r"[A-Za-z0-9_-]+", seg), f"illegal key segment {seg!r}"


def test_value_capping():
    out = filter_attributes({"media_title": "x" * 5000, "effect": ["a"] * 100},
                            domain="media_player", expose_location=False)
    assert len(out["media_title"]) == 255
    assert len(out["effect"]) == 16


def test_node_is_stable_for_unchanged_state():
    """The dedup fingerprint only works if an unchanged entity maps to an
    identical node. lastUpdated used to break this: HA bumps it on every
    update, including attribute-only ones, so every node looked new and every
    event cost a write."""
    import hashlib
    import json

    _, m = build()

    def digest(last_updated):
        _, _, node = m.to_node({
            "entity_id": "sensor.soil", "state": "42.5",
            "attributes": {"friendly_name": "Soil Moisture", "unit_of_measurement": "%"},
            "last_changed": "2026-09-21T05:00:00+00:00",
            "last_updated": last_updated,
        })
        assert "lastUpdated" not in node, "lastUpdated defeats deduplication"
        return hashlib.sha1(
            json.dumps(node, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()

    # Same state, different HA update timestamps -> must be the same write.
    assert digest("2026-09-21T05:00:00+00:00") == digest("2026-09-21T05:59:59+00:00")


def test_real_change_still_produces_a_new_node():
    """Dedup must not swallow genuine changes."""
    import hashlib
    import json

    _, m = build()

    def digest(state):
        _, _, node = m.to_node({
            "entity_id": "sensor.soil", "state": state,
            "attributes": {"friendly_name": "Soil Moisture"},
            "last_changed": "2026-09-21T05:00:00+00:00",
            "last_updated": "2026-09-21T05:00:00+00:00",
        })
        return hashlib.sha1(
            json.dumps(node, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()

    assert digest("42.5") != digest("43.1"), "a real state change must still write"


# ---------------------------------------------------------------- commands

CTL_CFG = types.SimpleNamespace(
    control_domains=frozenset({"switch", "light", "fan"}),
    control_max_age_seconds=120.0,
    root="farms/snof",
    allow_control=True,
)


def consumer():
    return CommandConsumer(CTL_CFG, None, lambda: None, None)


def cmd(**over):
    base = {
        "entity_id": "switch.bore_pump",
        "domain": "switch",
        "service": "turn_on",
        "data": {},
        "uid": "u1",
        "at": time.time() * 1000,
    }
    base.update(over)
    return base


def test_command_happy_path():
    got = consumer().validate("c1", cmd())
    assert got == ("switch", "turn_on", {}), got

    got = consumer().validate("c2", cmd(entity_id="fan.shed", domain="fan",
                                        service="set_percentage", data={"percentage": 60}))
    assert got == ("fan", "set_percentage", {"percentage": 60}), got


def test_command_refuses_dangerous_shapes():
    """Every one of these must come back None. This is the only inbound path to
    farm hardware, so the negative cases are the point of the test."""
    bad = {
        "domain off the allow-list": cmd(entity_id="lock.gate", domain="lock", service="turn_on"),
        "service not allowed for domain": cmd(entity_id="switch.p", domain="switch",
                                              service="set_percentage"),
        "entity_id disagrees with domain": cmd(entity_id="lock.gate", domain="switch"),
        "unknown data key": cmd(data={"transition": 5}),
        "brightness out of range": cmd(entity_id="light.a", domain="light",
                                       service="turn_on", data={"brightness": 900}),
        "percentage out of range": cmd(entity_id="fan.a", domain="fan",
                                       service="set_percentage", data={"percentage": -3}),
        "no timestamp": cmd(at=None),
        "stale": cmd(at=(time.time() - 900) * 1000),
        "postdated far into the future": cmd(at=(time.time() + 3600) * 1000),
        "not an object": "turn_on the pump please",
        "missing fields": {"entity_id": "switch.p"},
    }
    for why, payload in bad.items():
        assert consumer().validate("x", payload) is None, f"accepted a command that is {why}"


def test_command_booleans_are_not_numbers():
    """bool is a subclass of int in Python; True must not pass as a brightness."""
    assert consumer().validate("x", cmd(entity_id="light.a", domain="light",
                                        service="turn_on", data={"brightness": True})) is None


# ------------------------------------------------------- irrigation vendors

def test_vendor_status_spellings():
    assert vendors.status_of("ON") == "on"
    assert vendors.status_of("running") == "on"
    assert vendors.status_of(True) == "on" and vendors.status_of(1) == "on"
    assert vendors.status_of("off") == "off"
    assert vendors.status_of("Stopped") == "off"
    assert vendors.status_of(False) == "off" and vendors.status_of(0) == "off"
    assert vendors.status_of("") == "unknown"
    assert vendors.status_of(None) == "unknown"
    assert vendors.status_of("weird") == "unknown"
    assert vendors.status_of(7) == "unknown"


def test_vendor_scrub_never_leaks_credentials():
    dirty = {"token_id": "FCM...", "Authorization": "x:y@ios",
             "appid": "abc", "imei": "123", "url": "https://x",
             "name": "ok", "nested": {"password": "p", "keep": 1},
             "big": "x" * 9000, "many": list(range(99))}
    out = vendors.scrub(dirty)
    for banned in ("token_id", "Authorization", "appid", "imei", "url"):
        assert banned not in out, f"leaked {banned}"
    assert out["name"] == "ok" and out["nested"] == {"keep": 1}
    assert len(out["big"]) == 255 and len(out["many"]) == 16
    # Garbage in, no exception out.
    assert vendors.scrub(None) is None
    assert vendors.scrub(object()) != ""


def test_livesky_shapes():
    assert vendors.normalize_livesky(None) == []
    one = vendors.normalize_livesky(
        {"motors": [{"imei": "86", "motor_status": "ON"}]})
    assert one == [{"id": "86", "name": "River Motor", "status": "on",
                    "source": "livesky", "detail": ""}], one
    # A bare dict is one motor; unknown state degrades, not explodes.
    bare = vendors.normalize_livesky({"motor_status": "bogus"})
    assert bare[0]["status"] == "unknown" and bare[0]["id"] == "river"


def test_niagara_labelled_per_cluster():
    out = vendors.normalize_niagara({"status": "off"}, "Well Motor 7.5HP")
    assert out[0]["name"] == "Well Motor 7.5HP"
    assert out[0]["status"] == "off" and out[0]["source"] == "niagara"


def test_dcon_dashboard_keeps_presentation_only():
    out = vendors.normalize_dcon_dashboard({
        "device_name": "DCON", "serial_no": "MCON1", "token_id": "SECRET",
        "timers": {"last": "T12 done", "running": "", "next": "T13 06:00"}})
    assert out["device"] == "DCON" and out["last"] == "T12 done"
    assert out["next"] == "T13 06:00" and "token_id" not in out["extra"]


def test_dcon_valves_capped():
    out = vendors.normalize_dcon_valves(
        [{"valve_no": f"V{i:03d}", "status": "on"} for i in range(40)])
    assert len(out) == 16 and out[0]["id"] == "V000"


def test_weather_and_snapshot_defaults():
    w = vendors.normalize_weather({"main": {"temp": 31.4, "humidity": 58},
                                    "weather": [{"description": "haze"}],
                                    "wind": {"speed": 3.1}})
    assert (w["temp"], w["humidity"], w["desc"], w["wind"]) == (31.4, 58, "haze", 3.1)
    snap = vendors.build_snapshot({})
    assert snap["motors"] == [] and snap["weather"] == {}
    assert snap["meta"] == {"sources": {}, "error": ""}


# --------------------------------------------- irrigation report requests

IRR_CFG = types.SimpleNamespace(root="farms/snof")


def irr_runner():
    return IrrigationRunner(IRR_CFG, None, None)


def irr_req(**over):
    base = {"type": "valves", "from": "2026-02-20", "to": "2026-02-22",
            "uid": "u1", "at": time.time() * 1000}
    base.update(over)
    return base


def test_report_every_known_type_validates():
    """Every report offered in the builder is reachable through the queue."""
    live = {t: {"type": t, "uid": "u1", "at": time.time() * 1000}
            for t in REPORT_TYPES if REPORT_TYPES[t] == "live"}
    assert len(live) == 9, REPORT_TYPES
    for t, payload in live.items():
        got = irr_runner().validate("r", payload)
        assert got == (t, {}), (t, got)
    got = irr_runner().validate("r", irr_req(type="timer_log"))
    assert got == ("timer_log", {"from": "2026-02-20", "to": "2026-02-22"}), got


def test_every_report_type_has_a_label_and_a_builder():
    """The three lists that must not drift: the type allow-list, the labels
    the dashboard shows, and the method that actually pulls the data. A type
    with no builder would validate, run, and crash with AttributeError."""
    runner = irr_runner()
    for rtype in REPORT_TYPES:
        assert rtype in REPORT_LABELS, rtype
        assert callable(getattr(runner, f"_report_{rtype}", None)), rtype
    assert set(REPORT_LABELS) == set(REPORT_TYPES)


# ------------------------------------------------- report sections (presentation)

def test_number_of_reads_vendor_spellings():
    assert vendors.number_of("2.1") == 2.1
    assert vendors.number_of("2.1 bar") == 2.1
    assert vendors.number_of(3) == 3.0
    assert vendors.number_of("-0.5") == -0.5
    # No number means no number: a zero here would flatten a chart.
    assert vendors.number_of("n/a") is None
    assert vendors.number_of(None) is None
    assert vendors.number_of(True) is None


def test_series_stats_ignores_unreadable_rows():
    stats = vendors.series_stats([
        {"at": "06:00", "value": "1.8", "unit": "bar"},
        {"at": "12:00", "value": "2.6"},
        {"at": "18:00", "value": "sensor fault"},
    ])
    assert stats == {"count": 2, "min": 1.8, "max": 2.6, "avg": 2.2,
                     "last": 2.6, "unit": "bar"}, stats
    assert vendors.series_stats([]) == {"count": 0, "unit": ""}
    assert vendors.series_stats(["not a row"]) == {"count": 0, "unit": ""}


def test_runtime_minutes_reads_the_spellings_dcon_uses():
    assert vendors.runtime_minutes("1h 20m") == 80
    assert vendors.runtime_minutes("40m") == 40
    assert vendors.runtime_minutes("2:05") == 125
    assert vendors.runtime_minutes(80) == 80
    assert vendors.runtime_minutes("80") == 80
    assert vendors.runtime_minutes("") == 0
    assert vendors.runtime_minutes(None) == 0
    assert vendors.fmt_minutes(80) == "1h 20m"
    assert vendors.fmt_minutes(120) == "2h"
    assert vendors.fmt_minutes(40) == "40m"


def test_merge_timeline_interleaves_and_stamps_its_source():
    merged = vendors.merge_timeline(
        ([{"at": "2026-02-22 06:00", "event": "timer"},
          {"at": "", "event": "timer"}], "timer"),
        ([{"at": "2026-02-21 06:00", "event": "motor"}], "motor"))
    assert [r["source"] for r in merged] == ["motor", "timer", "timer"]
    # An entry with no stamp sorts to the end rather than being dropped.
    assert merged[-1]["at"] == ""


def test_section_rejects_an_unknown_kind_and_caps_rows():
    """The kind is the contract the dashboard draws by, so an unknown one
    degrades to a key/value block rather than reaching the browser."""
    sec = vendors.section("wild", "T", [{"a": i} for i in range(80)])
    assert sec["kind"] == "facts"
    assert len(sec["rows"]) == vendors.MAX_ROWS
    err = vendors.section("series", "Pressure", error="DCON is not configured")
    assert err["status"] == "error" and err["rows"] == []
    assert vendors.section("series", "P", [{"value": 1}])["status"] == "ok"


def test_section_scrubs_vendor_rows():
    """Sections are mirrored verbatim, so they go through the same scrub as
    every other vendor field."""
    sec = vendors.section("facts", "Controller",
                          [{"label": "Serial", "value": "MCON1",
                            "token_id": "secret"}])
    assert "token_id" not in sec["rows"][0]


def _stub_runner():
    """A runner whose vendor calls are canned, so the section builders can be
    exercised without aiohttp or a credential."""
    runner = irr_runner()

    async def livesky():
        return [{"id": "river", "name": "River Motor", "status": "on",
                 "source": "livesky", "detail": ""}]

    async def niagara():
        return [{"id": "6039", "name": "Well 7.5HP", "status": "off",
                 "source": "niagara", "detail": ""}]

    async def valves(start, end):
        return [{"id": "V012", "name": "East orchard valve", "status": "on",
                 "runtime": "1h 20m"},
                {"id": "V015", "name": "Nursery valve", "status": "off",
                 "runtime": "40m"}]

    async def pressure(start, end):
        return [{"at": "2026-02-20 06:00", "value": "1.8", "unit": "bar"},
                {"at": "2026-02-22 12:00", "value": "2.6", "unit": "bar"}]

    runner._livesky = livesky
    runner._niagara = niagara
    runner._dcon_valves = valves
    runner._dcon_pressure_range = pressure
    return runner


def test_composite_report_merges_two_vendors_into_one_board():
    runner = _stub_runner()
    report, patch = asyncio.run(runner._run_validated("motors", {}))
    assert report["status"] == "ok"
    kinds = [s["kind"] for s in report["sections"]]
    assert kinds == ["metrics", "status"], kinds
    assert len(report["sections"][1]["rows"]) == 2
    # Both vendors reported, so the split is worth showing.
    assert [m["label"] for m in report["sections"][0]["rows"]] == [
        "Motors running", "River", "Wells"]
    assert set(patch) == {"motors", "controllers"}


def test_composite_report_survives_one_dead_vendor():
    """A composite is two calls; one failing must cost one section, not the
    report. The status says so rather than passing a half-answer off as
    whole."""
    runner = _stub_runner()

    async def dead():
        raise RuntimeError("Livesky is not configured")

    runner._livesky = dead
    report, patch = asyncio.run(runner._run_validated("motors", {}))
    assert report["status"] == "partial", report
    assert report["error"] == "Livesky is not configured"
    assert [s["status"] for s in report["sections"]] == ["ok", "ok", "error"]
    assert set(patch) == {"controllers"}, patch   # nothing stale is cached


def test_composite_report_with_no_vendor_left_is_an_error():
    runner = _stub_runner()

    async def dead(*args):
        raise RuntimeError("DCON is not configured")

    runner._dcon_valves = dead
    runner._dcon_pressure_range = dead
    report, patch = asyncio.run(runner._run_validated(
        "performance", {"from": "2026-02-20", "to": "2026-02-22"}))
    assert report["status"] == "error", report
    # The same reason from both legs is said once.
    assert report["error"] == "DCON is not configured"
    assert patch == {}


def test_performance_report_puts_runtime_next_to_pressure():
    runner = _stub_runner()
    report, _ = asyncio.run(runner._run_validated(
        "performance", {"from": "2026-02-20", "to": "2026-02-22"}))
    kinds = [s["kind"] for s in report["sections"]]
    assert kinds == ["metrics", "bars", "metrics", "series"], kinds
    bars = report["sections"][1]["rows"]
    assert [b["value"] for b in bars] == [80, 40]    # longest first, in minutes
    assert "2h of valve runtime" in report["summary"]
    assert "pressure 1.8" in report["summary"]


def test_reports_still_carry_rows_for_an_unreloaded_dashboard():
    """sections is additive: a browser tab open since before this change
    renders rows and ignores what it does not know."""
    runner = _stub_runner()
    report, _ = asyncio.run(runner._run_validated("motors", {}))
    assert len(report["rows"]) == 2
    assert all("status" in row for row in report["rows"])


def test_report_refuses_bad_shapes():
    """The queue is a client-writable path, so the negative cases are the
    point — same bar as the device-command validator."""
    bad = {
        "unknown report type": irr_req(type="valve_on"),
        "command endpoint as a report": irr_req(type="MOFF"),
        "not an object": "give me the valve log",
        "missing fields": {"type": "valves"},
        "no timestamp": irr_req(at=None),
        "stale": irr_req(at=(time.time() - 900) * 1000),
        "postdated far into the future": irr_req(at=(time.time() + 3600) * 1000),
        "range without dates": {"type": "motor_log", "uid": "u1",
                                "at": time.time() * 1000},
        "bad date format": irr_req(**{"from": "20-02-2026"}),
        "month 13": irr_req(**{"from": "2026-13-01"}),
        "Feb 30": irr_req(**{"from": "2026-02-30"}),
        "to before from": irr_req(**{"from": "2026-02-22", "to": "2026-02-20"}),
        "decade range": irr_req(**{"from": "2020-01-01", "to": "2026-02-22"}),
    }
    for why, payload in bad.items():
        assert irr_runner().validate("x", payload) is None, \
            f"accepted a request that is {why}"


def test_report_live_types_ignore_stray_dates():
    """Extra date keys on a live pull must not fail it — nor be trusted."""
    got = irr_runner().validate(
        "r", {"type": "river_status", "uid": "u1",
              "from": "2020-01-01", "at": time.time() * 1000})
    assert got == ("river_status", {}), got


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
