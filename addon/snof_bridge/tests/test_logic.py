"""Pure-logic checks for the bridge. No network, no Firebase, no HA.

Run from the add-on directory:  python3 tests/test_logic.py
"""
import asyncio
import json
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


def test_dcon_dashboard_keeps_presentation_only():
    """The real 2026-09-23 payload, redacted. An earlier version of this
    parser mirrored a scrubbed copy of the whole node and put eleven phone
    numbers and the modem IMEI into Firebase."""
    live = ("##,DCON-MCON874Q000568,0-0-0!2026-09-23 09:00:43+05:30,V68,"
            "SibhiSump,1,0--,1,TM,1-1,9,2.8")
    out = vendors.normalize_dcon_dashboard({
        "MCON874Q000568": {
            "device_id": "12043", "server_time": "2026-09-23 09:04:04",
            "time_zone": "+05:30", "sim": "vi-7639508756",
            "packets": {"live": live, "4": "##,DCON,919566562440,916381499586"},
            "users": {"A1": {"name": "gvkovai", "mobile": "919566562440"}},
        }})
    assert out == {"device": "SibhiSump", "serial": "MCON874Q000568",
                   "lastPacket": "2026-09-23 09:00:43",
                   "serverTime": "2026-09-23 09:04:04",
                   "timeZone": "+05:30"}, out
    # An allow-list, so nothing from the payload can ride along.
    blob = json.dumps(out)
    assert "919566562440" not in blob and "7639508756" not in blob
    assert "packets" not in out and "users" not in out and "extra" not in out


def test_dcon_dashboard_degrades_without_a_live_packet():
    out = vendors.normalize_dcon_dashboard({})
    assert out["device"] == "Irrigation Controller" and out["serial"] == ""
    assert out["lastPacket"] == ""


def test_dcon_nodes_are_where_valve_names_come_from():
    out = vendors.normalize_dcon_nodes({
        "action": "get_node",
        "Node1": {"type": "FL-10", "valve": {
            "2": {"valve_name": "2 BPump", "valve_type": "Booster Pump"},
            "4": {"valve_name": "4 Veg", "valve_type": "Irrigation"}}}})
    assert out == [{"id": "2", "name": "2 BPump", "type": "Booster Pump"},
                   {"id": "4", "name": "4 Veg", "type": "Irrigation"}], out
    assert vendors.normalize_dcon_nodes({"action": "get_node"}) == []


def test_scrub_redacts_numbers_hiding_inside_packet_strings():
    """DCON hides phone numbers and the IMEI inside comma-joined strings where
    no key names them, so the deny-list alone cannot catch them."""
    out = vendors.scrub({"note": "##,DCON-MCON874Q000568,861190059555299,ok"})
    assert "861190059555299" not in out["note"]
    assert "[redacted]" in out["note"]
    # Short numbers are data, not identifiers, and must survive.
    assert vendors.scrub({"v": "pressure 2.8 bar"})["v"] == "pressure 2.8 bar"


def test_dcon_valves_sum_their_days_and_cap():
    """The live shape is keyed by valve number with runtime bucketed per day as
    HH:MM, so a window's runtime is the sum of its days — and "00:36" is 36
    minutes, not 36 hours."""
    out = vendors.normalize_dcon_valves({
        "action": "get_all_valve",
        "1": {"valve_name": "1 Tank", "valve_type": "Fertilizer",
              "runtime": {"2026-09-20": "00:00", "2026-09-21": "00:00"}},
        "3": {"valve_name": "3 Backwash", "valve_type": "Backwash",
              "runtime": {"2026-09-20": "00:36", "2026-09-21": "00:23",
                          "2026-09-22": "00:53"}}})
    idle, ran = out
    assert idle["minutes"] == 0 and idle["status"] == "off"
    assert ran["minutes"] == 112 and ran["runtime"] == "1h 52m"
    assert ran["name"] == "3 Backwash" and ran["status"] == "on"
    assert [d["value"] for d in ran["days"]] == [36, 23, 53]
    # Non-numeric keys are metadata, not valves.
    assert all(v["id"].isdigit() for v in out)
    big = vendors.normalize_dcon_valves(
        {str(i): {"valve_name": f"V{i}", "runtime": {}} for i in range(1, 40)})
    assert len(big) == 16


def test_dcon_timer_log_reads_a_real_entry():
    out = vendors.normalize_dcon_logs({"action": "timer_log", "log": [
        {"dt": "2026-09-22 06:44:50", "timer_name": "Grass", "timer_no": "11",
         "completed": "1", "on_valves": "7-0-0-0-0-0-0-0-0-0",
         "run_time": "00:01-00:30"}]}, "timer")
    assert out[0]["at"] == "2026-09-22 06:44:50"
    assert out[0]["event"] == "Grass"
    # The zero-padded valve slots are noise; only the live one is named.
    assert "valve 7" in out[0]["detail"] and "0-0-0" not in out[0]["detail"]
    assert "completed" in out[0]["detail"]


def test_motor_log_joins_its_split_stamp_and_reads_the_meter():
    """motor_log splits the stamp into dt1 + time and reports a day's running
    total, not an event. Without joining them a motor row sorts by a bare clock
    time and lands in the wrong day of a merged timeline."""
    out = vendors.normalize_dcon_logs({"action": "motor_log", "log": [
        {"device_type": "DCON", "dt1": "2026-09-23", "time": "09:09:06",
         "ph3_runtime": "06.54-06.53", "kilowatt_start": "615.81",
         "kilowatt_end": "649.21"}]}, "motor")
    assert out[0]["at"] == "2026-09-23 09:09:06"
    assert out[0]["event"] == "Motor run"
    assert "33.4 kWh" in out[0]["detail"]


def test_pressure_rows_chart_the_inlet_and_keep_the_rest():
    out = vendors.normalize_report({"status": "success", "data": [
        {"dt": "2026-09-23 09:00:08", "pressure": "2.5-1.7", "flow_rate": "0"},
        {"dt": "2026-09-23 09:01:06", "pressure": "2.6-1.8", "flow_rate": "12"}]})
    assert [r["value"] for r in out] == ["2.5", "2.6"]
    assert out[0]["unit"] == "bar" and out[0]["detail"] == "outlet 1.7 bar"
    assert "flow 12" in out[1]["detail"]
    assert vendors.series_stats(out)["avg"] == 2.55


def test_electricity_labels_only_what_it_can_identify():
    """The packet is undocumented. A voltage triple and a current triple are
    recognisable by shape and range; everything else stays unlabelled, because
    a wrong label on an electrical reading is worse than no label."""
    out = vendors.normalize_dcon_electricity({"status": "success", "data": [
        {"dt": "2026-09-23 09:00:08",
         "raw_data": "##,DCON-MCON874Q000568,6-0-0!2026-09-23 09:00:08+05:30,,"
                     "225-219-263,384-417-422,9.7-9.5-9.6,0.35-0-1.0,53.7,20"}]})
    assert [r["label"] for r in out] == ["Phase voltage", "Phase current"]
    assert out[0]["value"] == "225 / 219 / 263" and out[0]["unit"] == "V"
    assert out[1]["value"] == "9.7 / 9.5 / 9.6" and out[1]["unit"] == "A"
    assert vendors.normalize_dcon_electricity({"data": [{"dt": "x"}]}) == []


def test_snapshot_defaults():
    """An empty snapshot is all the empty collections, so a dead controller
    blanks a card rather than crashing the page."""
    snap = vendors.build_snapshot({})
    assert snap["valves"] == [] and snap["dcon"] == {}
    assert snap["electricity"] == [] and snap["pressure"] == []
    assert snap["timerLog"] == [] and snap["motorLog"] == []
    assert snap["meta"] == {"sources": {}, "error": ""}
    # The three removed vendors must not come back as empty keys either.
    assert "motors" not in snap and "controllers" not in snap
    assert "weather" not in snap


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
    assert len(live) == 4, REPORT_TYPES
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
    """A runner whose controller calls are canned, so the section builders can
    be exercised without aiohttp or a credential."""
    runner = irr_runner()

    async def valves(start, end):
        return vendors.normalize_dcon_valves({
            "action": "get_all_valve",
            "4": {"valve_name": "4 Veg", "valve_type": "Irrigation",
                  "runtime": {"2026-02-20": "01:20"}},
            "5": {"valve_name": "5 Onion", "valve_type": "Irrigation",
                  "runtime": {"2026-02-21": "00:40"}}}) 

    async def pressure(start, end):
        return [{"at": "2026-02-20 06:00", "value": "1.8", "unit": "bar"},
                {"at": "2026-02-22 12:00", "value": "2.6", "unit": "bar"}]

    async def log(kind, start, end):
        return [{"at": f"2026-02-2{1 if kind == 'timer' else 2} 06:00",
                 "event": kind, "detail": f"{kind} entry"}]

    runner._dcon_valves = valves
    runner._dcon_log = log
    runner._dcon_pressure_range = pressure
    return runner


def test_composite_report_weaves_two_endpoints_into_one_chronology():
    runner = _stub_runner()
    report, patch = asyncio.run(runner._run_validated(
        "session_log", {"from": "2026-02-20", "to": "2026-02-22"}))
    assert report["status"] == "ok"
    kinds = [s["kind"] for s in report["sections"]]
    assert kinds == ["metrics", "timeline"], kinds
    rows = report["sections"][1]["rows"]
    assert [r["source"] for r in rows] == ["timer", "motor"]   # oldest first
    assert set(patch) == {"timerLog", "motorLog"}


def test_composite_report_survives_one_dead_endpoint():
    """A composite is two calls; one failing must cost one section, not the
    report. The status says so rather than passing a half-answer off as
    whole."""
    runner = _stub_runner()

    async def half(kind, start, end):
        if kind == "motor":
            raise RuntimeError("DCON logs: POST -> 500")
        return [{"at": "2026-02-22 06:00", "event": "timer", "detail": "done"}]

    runner._dcon_log = half
    report, patch = asyncio.run(runner._run_validated(
        "session_log", {"from": "2026-02-20", "to": "2026-02-22"}))
    assert report["status"] == "partial", report
    assert report["error"] == "DCON logs: POST -> 500"
    assert [s["status"] for s in report["sections"]] == ["ok", "ok", "error"]
    assert set(patch) == {"timerLog"}, patch   # nothing stale is cached


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
    assert [b["name"] for b in bars] == ["4 Veg", "5 Onion"]
    assert "2h of valve runtime" in report["summary"]
    assert "pressure 1.8" in report["summary"]


def test_reports_still_carry_rows_for_an_unreloaded_dashboard():
    """sections is additive: a browser tab open since before this change
    renders rows and ignores what it does not know."""
    runner = _stub_runner()
    report, _ = asyncio.run(runner._run_validated(
        "valves", {"from": "2026-02-20", "to": "2026-02-22"}))
    assert len(report["rows"]) == 2
    assert all("status" in row for row in report["rows"])


# Regression: ISSUE-002 — report requests piled up forever while reports were off
# Found by /qa on 2026-09-23 (two orphans were sitting in production, one a day old)
# Report: .gstack/qa-reports/qa-report-snof-live-web-app-2026-09-23.md

class _FakeRTDB:
    def __init__(self, node):
        self.node = node
        self.reads: list[str] = []
        self.writes: list[tuple] = []

    async def get(self, path, shallow=False):
        self.reads.append(path)
        return self.node

    async def put(self, path, value):
        self.writes.append((path, value))


def _disabled_runner(node):
    cfg = types.SimpleNamespace(root="farms/snof", irrigation_enabled=False)
    rtdb = _FakeRTDB(node)
    return IrrigationRunner(cfg, rtdb, None), rtdb


def test_disabled_runner_drains_the_queue_nothing_will_answer():
    """Only this runner deletes from irrigation_requests, and clients can append
    to it. With the runner off, a request written by the dashboard used to stay
    there forever."""
    runner, rtdb = _disabled_runner({"-Pabc": True, "-Pdef": True})
    asyncio.run(runner.run())
    assert rtdb.writes == [("farms/snof/irrigation_requests", None)], rtdb.writes


def test_disabled_runner_writes_nothing_when_the_queue_is_empty():
    """The common case is an empty queue on every boot; it must not cost a
    write."""
    for empty in (None, {}):
        runner, rtdb = _disabled_runner(empty)
        asyncio.run(runner.run())
        assert rtdb.writes == [], (empty, rtdb.writes)


def test_disabled_runner_survives_a_queue_it_cannot_read():
    """A failed purge is a log line, not a crashed task: the bridge's other
    work does not depend on it."""
    runner, rtdb = _disabled_runner({"-Pabc": True})

    async def boom(path, shallow=False):
        raise RuntimeError("RTDB GET -> 401")

    rtdb.get = boom
    asyncio.run(runner.run())          # must not raise
    assert rtdb.writes == []


# Regression: ISSUE-003 — a delete sent no body at all, so nothing was deleted
# Found by /qa on 2026-09-23 (RTDB answered "400 No data supplied.")
# Report: .gstack/qa-reports/qa-report-snof-live-web-app-2026-09-23.md

def test_delete_encodes_a_literal_null_body():
    """Deleting a node is a PUT of JSON null, and that is how every executed
    command and every fulfilled report clears its queue entry. aiohttp's
    `json=None` sends no body, which RTDB rejects — so the body is built here
    instead, and null must survive as the four characters."""
    from bridge.wire import encode_body
    assert encode_body(None) == "null"
    assert encode_body({"a": 1}) == '{"a": 1}'
    assert encode_body([]) == "[]"
    assert encode_body(False) == "false"
    assert encode_body(0) == "0"



# Regression: control queue piled up while allow_control was false
# Found by /investigate on 2026-09-23 (three unexecuted turn_on commands live)
# Same shape as the irrigation queue below; /commands is the one client-writable
# path in the tree, so litter on it matters more than litter anywhere else.

def _disabled_consumer(node):
    cfg = types.SimpleNamespace(root="farms/snof", allow_control=False,
                                control_domains=["switch"],
                                control_max_age_seconds=120)
    rtdb = _FakeRTDB(node)
    return CommandConsumer(cfg, rtdb, lambda: None, None), rtdb


def test_disabled_consumer_drains_the_command_queue():
    consumer, rtdb = _disabled_consumer({"-Pa": True, "-Pb": True, "-Pc": True})
    asyncio.run(consumer.run())
    assert rtdb.writes == [("farms/snof/commands", None)], rtdb.writes


def test_disabled_consumer_writes_nothing_when_the_queue_is_empty():
    for empty in (None, {}):
        consumer, rtdb = _disabled_consumer(empty)
        asyncio.run(consumer.run())
        assert rtdb.writes == [], (empty, rtdb.writes)


# Regression: every DCON POST died with "name 'aiohttp' is not defined"
# Found by /investigate on 2026-09-23, on the first report ever run for real.
# aiohttp is imported per call site so this suite can run with nothing
# installed; _get_json did it, _post_form did not, and most of the DCON API is
# POST. A static check, because the pure suite cannot make a network call.

def test_every_runtime_use_of_aiohttp_has_a_local_import():
    import ast
    root = Path(__file__).resolve().parent.parent / "bridge"
    offenders = []
    for path in sorted(root.glob("*.py")):
        tree = ast.parse(path.read_text())
        # Module-scope import is fine for modules the pure suite never imports;
        # these three it does import, so they must keep aiohttp out of scope.
        if path.name not in ("irrigation.py", "commands.py", "vendors.py"):
            continue
        assert not any(
            isinstance(n, ast.Import) and any(a.name == "aiohttp" for a in n.names)
            for n in tree.body), f"{path.name} imports aiohttp at module scope"
        for fn in [n for n in ast.walk(tree)
                   if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
            # Annotations do not evaluate (`from __future__ import
            # annotations`), so a parameter typed aiohttp.ClientSession is not
            # a runtime use. Only the body counts.
            body = ast.Module(body=fn.body, type_ignores=[])
            uses = any(isinstance(n, ast.Attribute)
                       and isinstance(n.value, ast.Name)
                       and n.value.id == "aiohttp"
                       for n in ast.walk(body))
            if not uses:
                continue
            has_import = any(
                isinstance(n, ast.Import) and any(a.name == "aiohttp" for a in n.names)
                for n in ast.walk(body))
            if not has_import:
                offenders.append(f"{path.name}::{fn.name}")
    assert not offenders, f"aiohttp used without a local import in: {offenders}"


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
        "r", {"type": "controller", "uid": "u1",
              "from": "2020-01-01", "at": time.time() * 1000})
    assert got == ("controller", {}), got


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
