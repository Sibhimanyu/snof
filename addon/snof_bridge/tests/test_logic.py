"""Pure-logic checks for the bridge. No network, no Firebase, no HA.

Run from the add-on directory:  python3 tests/test_logic.py
"""
import asyncio
import json
import os
import logging
import re
import sys
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
logging.disable(logging.CRITICAL)

from bridge.commands import CommandConsumer  # noqa: E402
from bridge import updater  # noqa: E402  (pure decisions, aiohttp imported lazily)
from bridge import dev_console as dc  # noqa: E402  (pure validation, aiohttp imported lazily)
from bridge import relay  # noqa: E402  (pure validation, aiohttp imported lazily)
from bridge.mapper import StateMapper, filter_attributes  # noqa: E402
from bridge.registry import Registry  # noqa: E402

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


def test_unassigned_entities_do_not_exist():
    """No room, no mirror: an entity without an area is never published, and
    'unassigned' is not an area anyone can see."""
    reg, m = build()
    assert not m.should_publish("switch.stray")
    assert not m.should_publish("light.never_seen")
    assert "unassigned" not in reg.areas_payload()
    assert set(reg.areas_payload()) == {"pump_house", "orchard"}


def test_area_pointing_at_a_deleted_room_is_unassigned():
    reg = Registry()
    reg.load(areas=[{"area_id": "orchard", "name": "Orchard"}], devices=[],
             entities=[{"entity_id": "switch.ghost", "area_id": "demolished_shed"}])
    assert not reg.is_assigned("switch.ghost")
    assert not StateMapper(CFG, reg).should_publish("switch.ghost")


def test_only_entities_on_a_roomed_device_exist():
    """A room on the entity alone is not enough: its device must be in a room."""
    reg = Registry()
    reg.load(areas=[{"area_id": "shed", "name": "Shed"}],
             devices=[{"id": "roomed", "area_id": "shed"}, {"id": "loose"}],
             entities=[{"entity_id": "switch.on_roomed_device", "device_id": "roomed"},
                       {"entity_id": "switch.own_room_loose_device", "area_id": "shed", "device_id": "loose"},
                       {"entity_id": "switch.own_room_no_device", "area_id": "shed"}])
    assert reg.is_assigned("switch.on_roomed_device")
    assert not reg.is_assigned("switch.own_room_loose_device")
    assert not reg.is_assigned("switch.own_room_no_device")


def test_devices_are_named_and_carried_on_each_node():
    reg, m = build()
    assert reg.devices_payload() == {"dev1": {"name": "dev1"}}
    _, _, node = m.to_node({"entity_id": "light.pump_main", "state": "on", "attributes": {}})
    assert node["device"] == "dev1"
    reg.load(areas=[{"area_id": "shed", "name": "Shed"}],
             devices=[{"id": "d1", "area_id": "shed", "name": "Bambu P1S", "name_by_user": "Printer"},
                      {"id": "d2", "name": "Loose plug"},
                      {"id": "d3", "area_id": "demolished", "name": "Ghost"}],
             entities=[])
    assert reg.devices_payload() == {"d1": {"name": "Printer"}}, "no-room devices must not be named"


def test_consumer_with_no_visibility_check_refuses_everything():
    c = CommandConsumer(CTL_CFG, None, lambda: None, None)
    assert c.validate("x", cmd()) is None


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
    control_domains=frozenset({"switch", "light", "fan", "climate"}),
    control_max_age_seconds=120.0,
    root="farms/snof",
    allow_control=True,
)


def consumer(visible=lambda eid: eid != "switch.stray"):
    return CommandConsumer(CTL_CFG, None, lambda: None, None, is_visible=visible)


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
        "for an entity in no room": cmd(entity_id="switch.stray"),
    }
    for why, payload in bad.items():
        assert consumer().validate("x", payload) is None, f"accepted a command that is {why}"


def _ac(service, data=None):
    return cmd(entity_id="climate.guest_ac", domain="climate", service=service, data=data or {})


def test_ac_commands_the_app_sends():
    """The ACs (2026-09-25): power, temperature, mode, fan speed, preset."""
    c = consumer()
    assert c.validate("a", _ac("turn_on")) == ("climate", "turn_on", {})
    assert c.validate("a", _ac("turn_off")) == ("climate", "turn_off", {})
    assert c.validate("a", _ac("set_temperature", {"temperature": 24})) == ("climate", "set_temperature", {"temperature": 24})
    assert c.validate("a", _ac("set_hvac_mode", {"hvac_mode": "dry"})) == ("climate", "set_hvac_mode", {"hvac_mode": "dry"})
    assert c.validate("a", _ac("set_fan_mode", {"fan_mode": "turbo"})) == ("climate", "set_fan_mode", {"fan_mode": "turbo"})
    assert c.validate("a", _ac("set_preset_mode", {"preset_mode": "wind_free"})) == ("climate", "set_preset_mode", {"preset_mode": "wind_free"})


def test_ac_commands_refused():
    bad = {
        "temperature too hot": _ac("set_temperature", {"temperature": 60}),
        "temperature as a word": _ac("set_temperature", {"temperature": "24"}),
        "temperature as a boolean": _ac("set_temperature", {"temperature": True}),
        "set_temperature with no temperature": _ac("set_temperature"),
        "set_temperature smuggling a mode": _ac("set_temperature", {"temperature": 24, "hvac_mode": "heat"}),
        "an hvac mode Home Assistant does not have": _ac("set_hvac_mode", {"hvac_mode": "eco"}),
        "an hvac mode as a number": _ac("set_hvac_mode", {"hvac_mode": 3}),
        "a fan mode that is not a token": _ac("set_fan_mode", {"fan_mode": "high; rm -rf"}),
        "a fan mode on the wrong service": _ac("set_preset_mode", {"fan_mode": "low"}),
        "turn_on with data": _ac("turn_on", {"temperature": 24}),
        "a service ACs are not given": _ac("set_humidity", {"humidity": 40}),
        "toggle, which ACs are not given": _ac("toggle"),
        "brightness on an AC": _ac("turn_on", {"brightness": 100}),
        "a temperature on a switch": cmd(data={"temperature": 24}),
        "percentage on a light": cmd(entity_id="light.a", domain="light", service="turn_on", data={"percentage": 50}),
    }
    for why, payload in bad.items():
        assert consumer().validate("x", payload) is None, f"accepted an AC command with {why}"


def test_ac_commands_need_climate_enabled():
    cfg = types.SimpleNamespace(**{**vars(CTL_CFG), "control_domains": frozenset({"switch"})})
    c = CommandConsumer(cfg, None, lambda: None, None, is_visible=lambda eid: True)
    assert c.validate("x", _ac("turn_on")) is None


def test_command_booleans_are_not_numbers():
    """bool is a subclass of int in Python; True must not pass as a brightness."""
    assert consumer().validate("x", cmd(entity_id="light.a", domain="light",
                                        service="turn_on", data={"brightness": True})) is None


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


# Regression: ISSUE-003 — a delete sent no body at all, so nothing was deleted
# Found by /qa on 2026-09-23 (RTDB answered "400 No data supplied.")
# Report: .gstack/qa-reports/qa-report-snof-live-web-app-2026-09-23.md

def test_delete_encodes_a_literal_null_body():
    """Deleting a node is a PUT of JSON null, and that is how every executed
    command clears its queue entry. aiohttp's
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
# /commands is the one client-writable path the bridge consumes, so litter on
# it matters more than litter anywhere else.

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
        # this one it does import, so it must keep aiohttp out of scope.
        if path.name not in ("commands.py", "relay.py"):
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


# ------------------------------------------------------------- DCON relay

def _job(**over):
    base = {"call": "valves", "args": {"from": "2026-09-20", "to": "2026-09-22"},
            "at": time.time() * 1000}
    base.update(over)
    return base


def test_every_firebase_stream_has_a_read_timeout():
    """A socket lost without a clean close never raises on its own. The relay
    sat deaf for nine days with sock_read=None (2026-10-17); RTDB's keep-alive
    comes every ~30 s, so every stream must give up on a silent socket."""
    from bridge.wire import STREAM_READ_TIMEOUT_SECONDS
    assert 45 <= STREAM_READ_TIMEOUT_SECONDS <= 120
    for name in ("commands.py", "relay.py", "irrigation_control.py"):
        src = (Path(__file__).resolve().parent.parent / "bridge" / name).read_text()
        assert "sock_read=None" not in src, name
        assert "sock_read=STREAM_READ_TIMEOUT_SECONDS" in src, name


def test_relay_status_reports_how_long_its_stream_has_been_silent():
    r = relay.DconRelay.__new__(relay.DconRelay)
    r._cfg = type("C", (), {"dcon_relay": True, "dcon_serial": "x", "dcon_token_id": "y"})()
    r.served = r.refused = 0
    r.last_error = ""
    r._stream_seen = None
    assert r.status()["streamIdleSeconds"] is None
    import time
    r._stream_seen = time.monotonic() - 42
    assert 41 <= r.status()["streamIdleSeconds"] <= 44


def test_relay_runs_only_named_reads_with_strict_args():
    assert relay.validate(_job()) == ("valves", {"from": "2026-09-20", "to": "2026-09-22"})
    assert relay.validate(_job(call="dashboard", args={})) == ("dashboard", {})
    assert relay.validate(_job(call="electricity", args={"since": "2026-09-24 08:00:00"}))
    bad = {
        "unknown call": _job(call="valve_on"),
        "a url": _job(call="https://dcon.mobitechwireless.com/v1/http/"),
        "extra arg": _job(args={"from": "2026-09-20", "to": "2026-09-22", "action": "x"}),
        "missing arg": _job(args={"from": "2026-09-20"}),
        "bad date": _job(args={"from": "20-09-2026", "to": "2026-09-22"}),
        "injected field": _job(args={"from": "2026-09-20&serial_no=X", "to": "2026-09-22"}),
        "stale": _job(at=(time.time() - 600) * 1000),
        "no timestamp": _job(at=None),
        "not a dict": "valves",
    }
    for why, job in bad.items():
        assert relay.validate(job) is None, why


def test_relay_new_reads_take_strict_args_and_spell_their_forms():
    ok = {"programs": {}, "electricity_day": {}, "rain": {},
          "pressure_day": {"date": "2026-11-08"}, "cmd_status": {"trans_id": "1234567890"}}
    for call, args in ok.items():
        assert relay.validate(_job(call=call, args=args)) == (call, args), call
    bad = [("programs", {"date": "2026-11-08"}), ("pressure_day", {}), ("pressure_day", {"date": "08-11-2026"}),
           ("pressure_day", {"date": "2026-11-08&x=1"}), ("electricity_day", {"from": "2026-11-08"}),
           ("rain", {"device_id": "12043"}), ("cmd_status", {"trans_id": "123"}),
           ("cmd_status", {"trans_id": "12345678901"}), ("cmd_status", {"trans_id": "12345678a0"}),
           ("cmd_status", {"trans_id": "1234567890", "serial_no": "X"})]
    for call, args in bad:
        assert relay.validate(_job(call=call, args=args)) is None, (call, args)
    f = relay.form_for
    assert f("programs", {}, "S", "T") == {"action": "dcon_timer", "method": "select", "serial_no": "S"}
    assert f("electricity_day", {}, "S", "T") == {"action": "reports", "type": "electricity_day",
                                                  "serial_no": "S", "product": "DCON"}
    assert f("pressure_day", {"date": "2026-11-08"}, "S", "T")["dt"] == "2026-11-08"
    assert f("cmd_status", {"trans_id": "1234567890"}, "S", "T") == {
        "action": "cmd_status", "random_no": "1234567890", "serial_no": "S"}
    assert relay.RAIN_PATH == "/v1/weather/cumulative/"
    assert relay.rain_params("12043") == {"device_id": "12043", "type": "rain"}
    src = (Path(__file__).resolve().parent.parent / "bridge" / "relay.py").read_text()
    assert "/v1/command" not in src


def test_relay_cuts_the_new_reads_down_on_the_nuc():
    programs = {"action": "dcon_timer", "users": {"A1": {"mobile": "9876543210"}}, "sim": "9876543210",
                "1": {"2": {"group_name": "Coconut 9876543210", "valve_details": "12-15", "on_time": "01:00",
                            "off_time": "00:00", "on_days": "0", "timer_status": "1", "data": "call 9876543210",
                            "backwash": "0", "motor_status": "0--"},
                      "x": {"group_name": "bad key"}}}
    out = relay.reduce_read("programs", programs)
    assert list(out) == ["1"] and list(out["1"]) == ["2"]
    assert "data" not in out["1"]["2"] and "9876543210" not in json.dumps(out)
    assert relay.reduce_read("rain", {"today": 1.5, "last24hrs": 2, "yesterday": "x", "week": 3.2, "device_id": "12043"}) == {
        "today": 1.5, "last24hrs": 2, "yesterday": 0, "week": 3.2}
    st = relay.reduce_read("cmd_status", {"sent": "2", "dt": "2026-11-08 06:00:00", "serial_no": "MCON000X000001",
                                          "device_id": "12043", "user_id": "3276",
                                          "cmd": "DATA=1234567890$ET01-002-01 00@A8$A8!MCON000X000001!$"})
    assert st == {"sent": "2", "dt": "2026-11-08 06:00:00"}
    day = relay.reduce_read("electricity_day", {"status": "success", "data": [
        {"dt": "2026-11-08 00:00:00", "raw_data": "##,DCON-9876543210,6-0-0!2026-11-08 00:00:00+05:30,,254-248-264",
         "serial_no": "S"}]})
    assert set(day["data"][0]) == {"dt", "raw_data"} and "9876543210" not in json.dumps(day)
    pd = relay.reduce_read("pressure_day", {"data": [{"dt": "t", "pressure": "1.5-0.8", "flow_rate": "0", "x": 1}]})
    assert pd["data"] == [{"dt": "t", "pressure": "1.5-0.8", "flow_rate": "0"}]


def test_relay_uses_its_own_credentials_and_one_endpoint():
    form = relay.form_for("valves", {"from": "2026-09-20", "to": "2026-09-22"},
                          serial="MCONOWN", token="TOKENOWN")
    assert form["serial_no"] == "MCONOWN"
    assert relay.form_for("dashboard", {}, "MCONOWN", "TOKENOWN")["token_id"] == "TOKENOWN"
    src = (Path(__file__).resolve().parent.parent / "bridge" / "relay.py").read_text()
    assert src.count("/v1/http/") >= 1 and "/v1/command" not in src


def test_relay_strips_the_phone_book_before_anything_leaves():
    raw = {"MCONTEST": {"server_time": "t", "time_zone": "+05:30", "timers": {"current": None},
                        "sim": "vi-9876543210", "users": {"A1": {"mobile": "919876543210"}},
                        "device_id": "12043",
                        "packets": {"live": "##,DCON-MCONTEST,0-0-0!x,V68,SibhiSump",
                                    "4": "##,DCON,919876543210", "5": "##,IMEI,490154203237518",
                                    "6": "##,DCON-MCONTEST,6-0-0!2026-09-24 14:29:06+05:30,,228-223-264,"
                                         "390-421-426,9.8-9.5-9.7,1.0-0-1.0,13.06-06.38,919876543210,",
                                    "1": "##,DCON,1-0-0!x,919876543210", "8": "##,DCON,919876543210"}}}
    out = json.dumps(relay.trim_dashboard(raw))
    assert "9876543210" not in out and "490154203237518" not in out and "12043" not in out
    assert "SibhiSump" in out and "server_time" in out
    kept = relay.trim_dashboard(raw)["MCONTEST"]["packets"]
    assert set(kept) == {"live", "6"}, kept
    assert "228-223-264" in kept["6"] and "13.06-06.38" in kept["6"]


def test_relay_packs_round_trip():
    import base64, gzip
    text = json.dumps({"data": [{"dt": "x"}] * 1000})
    assert gzip.decompress(base64.b64decode(relay.pack(text))).decode() == text
    assert len(relay.pack(text)) < len(text) / 5

# ---- irrigation control --------------------------------------------------------

from bridge import irrigation_control as ic  # noqa: E402


def _refused(fn, *a):
    try:
        fn(*a)
    except ic.Refused as why:
        return str(why)
    raise AssertionError(f"not refused: {a}")


def test_irrigation_commands_are_spelled_as_mobitech_spells_them():
    # The Mobitech app's own forms (captured 2026-09-24, docs/mobitech-app.md):
    # decision (b), 2026-11-08, moved run and stop off FON/OFF.
    assert ic.run_command([8, 9], 10, "A8") == "V008,009ON 00 10@A8"
    assert ic.run_command([6], 120, "A1") == "V006ON 02 00@A1"
    assert ic.run_command([12, 15], 60, "A8") == "V012,015ON 01 00@A8"
    assert _refused(ic.run_command, [30], 480, "A1"), "three hours is the hard ceiling"
    assert ic.stop_command("A8") == "MOFF@A8"
    assert _refused(ic.stop_command, "U8"), "a U slot means pause to Mobitech"
    assert _refused(ic.run_command, [1, 2, 3, 4, 5, 6], 10, "A8")
    assert _refused(ic.run_command, [4, 4], 10, "A8")
    assert ic.program_command(2, 60, "A8") == "ET01-002-01 00@A8"
    assert ic.program_command(8, 30, "A8") == "ET01-008-00 30@A8"
    assert _refused(ic.program_command, 0, 60, "A8") and _refused(ic.program_command, 100, 60, "A8")
    assert _refused(ic.program_command, 2, 0, "A8") and _refused(ic.program_command, 2, 60, "U8")
    for old in ("FON", "OFF@"):
        src = open(os.path.join(os.path.dirname(__file__), "..", "bridge", "irrigation_control.py")).read()
        assert f'"{old}' not in src and f"f\"{old}" not in src, "the old spellings are gone"


def test_irrigation_validation_refuses_everything_else():
    now = 1_790_000_000.0
    ok = {"action": "run", "valves": "12,15", "minutes": 20, "uid": "u", "at": now * 1000}
    assert ic.validate(ok, 60, now) == ("run", [12, 15], 20)
    assert ic.validate({"action": "stop", "uid": "u", "at": now * 1000}, 60, now) == ("stop", [], 0)
    prog = {"action": "program", "program": 2, "uid": "u", "at": now * 1000}
    assert ic.validate(prog, 60, now) == ("program", [], 0) and ic.program_number(prog) == 2
    bad = [
        {**ok, "action": "restart"}, {**ok, "program": 2},
        {**prog, "program": 0}, {**prog, "program": 100}, {**prog, "program": "2"},
        {**prog, "program": True}, {**prog, "program": 2.0}, {"action": "program", "at": now * 1000},
        {**prog, "valves": "12"}, {**prog, "minutes": 10}, {**prog, "at": (now - 61) * 1000},
        {"action": "stop", "program": 2, "at": now * 1000},
        {**ok, "minutes": 61}, {**ok, "minutes": 0}, {**ok, "minutes": 20.5}, {**ok, "minutes": True},
        {**ok, "valves": "12;15"}, {**ok, "valves": "1,2,3,4,5,6"}, {**ok, "valves": "12,12"},
        {**ok, "valves": 12}, {**ok, "at": (now - 61) * 1000}, {**ok, "at": "now"},
        {**ok, "command": "OFF@A8"}, "FON 012", None,
    ]
    for cmd in bad:
        assert _refused(ic.validate, cmd, 60, now), cmd


PROGRAMS = {"action": "dcon_timer", "1": {
    "2": {"valve_details": "12-15-0-0-0-0-0-0-0-0", "on_time": "01:00", "off_time": "00:00",
          "on_days": "0", "group_name": "Coconut", "backwash": "0", "motor_status": "0--",
          "timer_status": "1", "data": ""},
    "4": {"valve_details": "5-0-0-0-0-0-0-0-0-0", "on_time": "00:30", "off_time": "00:00",
          "on_days": "0", "group_name": "Onion", "timer_status": "0"},
    "9": {"valve_details": "17-0", "on_time": "00:00", "group_name": "Zero", "timer_status": "1"}}}


def test_a_program_start_needs_a_real_enabled_program_with_a_duration():
    got = ic.find_program(PROGRAMS, 2)
    assert got == {"number": 2, "name": "Coconut", "minutes": 60, "valves": [12, 15]}
    assert "no program 3" in _refused(ic.find_program, PROGRAMS, 3)
    assert "switched off" in _refused(ic.find_program, PROGRAMS, 4), "a disabled program"
    assert "duration" in _refused(ic.find_program, PROGRAMS, 9)
    assert _refused(ic.find_program, None, 2) and _refused(ic.find_program, {"1": []}, 2)
    # the duration is the record's on_time, never the app's
    assert ic.program_command(got["number"], got["minutes"], "A8") == "ET01-002-01 00@A8"


def test_a_program_start_is_off_unless_both_options_are_on():
    from types import SimpleNamespace as NS
    full = dict(allow_irrigation_control=True, dcon_serial="s", dcon_token_id="t",
                dcon_command_auth="x@ios", dcon_device_id="1", dcon_user_slot="A8",
                irrigation_max_minutes=60, allow_program_start=True)
    assert ic.IrrigationControl(NS(**full), None, None).program_start_enabled
    assert not ic.IrrigationControl(NS(**{**full, "allow_program_start": False}), None, None).program_start_enabled
    assert not ic.IrrigationControl(NS(**{**full, "allow_irrigation_control": False}), None, None).program_start_enabled
    assert ic.IrrigationControl(NS(**{**full, "allow_program_start": False}), None, None).enabled
    cfg = open(os.path.join(os.path.dirname(__file__), "..", "config.yaml")).read()
    assert "allow_program_start: false" in cfg and "allow_program_start: bool" in cfg
    from bridge.config import Config
    assert Config.__dataclass_fields__["allow_program_start"].default is False


def test_a_refused_program_start_sends_nothing_and_takes_no_lock():
    import asyncio
    from types import SimpleNamespace as NS

    class RTDB:
        def __init__(self, lock=None): self.lock, self.puts = lock, []
        async def get(self, path, shallow=False): return self.lock if path.endswith("irrigation_lock") else None
        async def put(self, path, value): self.puts.append((path, value))
        async def patch(self, path, value): pass

    def make(rtdb, **over):
        cfg = NS(allow_irrigation_control=True, dcon_serial="s", dcon_token_id="t", dcon_command_auth="x@ios",
                 dcon_device_id="1", dcon_user_slot="A8", irrigation_max_minutes=60,
                 allow_program_start=True, root="farms/f", dcon_base="https://x", dcon_product="DCON", **over)
        c = ic.IrrigationControl(cfg, rtdb, None)
        sent = []
        async def send(command): sent.append(command); return 200, '{"message":"ok","trans_id":1234567890}'
        async def read(call, args=None):
            return PROGRAMS if call == "programs" else {"MCONTEST": {"timers": {"current": None}}}
        async def confirm(*a, **k): return True
        c._send, c._read, c._confirm = send, read, confirm
        return c, sent

    def cmd(**kw):
        return {"action": "program", "program": 2, "uid": "u", "at": time.time() * 1000, **kw}

    def run(c, command, cid="a"):
        asyncio.run(c.handle(cid, command))
        return c

    # option off
    c, sent = make(RTDB(), ); c._cfg.allow_program_start = False
    run(c, cmd()); assert not sent and c.refused == 1
    # unknown, disabled program
    for n in (3, 4):
        c, sent = make(RTDB()); run(c, cmd(program=n)); assert not sent and c.refused == 1, n
    # lock live
    c, sent = make(RTDB({"until": time.time() * 1000 + 60000})); run(c, cmd()); assert not sent and c.refused == 1
    # bad shape
    c, sent = make(RTDB()); run(c, cmd(program="2")); assert not sent and c.refused == 1
    # the good one: exact spelling, lock taken before the send, released after
    r = RTDB(); c, sent = make(r); run(c, cmd())
    assert sent == ["ET01-002-01 00@A8"] and c.sent == 1
    paths = [p for p, v in r.puts]
    assert paths[0] == "farms/f/irrigation_lock" and r.puts[0][1] is not None
    assert ("farms/f/irrigation_lock", None) in r.puts and ("farms/f/irrigation_commands/a", None) in r.puts
    res = [v for p, v in r.puts if p == "farms/f/irrigation_command_results/a"][-1]
    assert res["verified"] is True and res["program"] == 2 and res["minutes"] == 60 and res["valves"] == "Coconut"
    # a manual run goes out in the app's form, with the same lock
    c, sent = make(RTDB()); c._allowed_valves = lambda: asyncio.sleep(0, {12: "a", 15: "b"})
    run(c, {"action": "run", "valves": "12,15", "minutes": 10, "uid": "u", "at": time.time() * 1000})
    assert sent == ["V012,015ON 00 10@A8"]


def test_the_lock_is_held_after_a_send_that_may_have_gone_out_and_a_running_program_is_refused():
    import asyncio
    from types import SimpleNamespace as NS

    class RTDB:
        def __init__(self): self.puts = []
        async def get(self, path, shallow=False): return None
        async def put(self, path, value): self.puts.append((path, value))
        async def patch(self, path, value): pass

    def make(send, dash):
        cfg = NS(allow_irrigation_control=True, dcon_serial="s", dcon_token_id="t", dcon_command_auth="x@ios",
                 dcon_device_id="1", dcon_user_slot="A8", irrigation_max_minutes=60, allow_program_start=True,
                 root="farms/f", dcon_base="https://x", dcon_product="DCON")
        r = RTDB(); c = ic.IrrigationControl(cfg, r, None)
        async def read(call, args=None): return PROGRAMS if call == "programs" else dash
        async def confirm(*a, **k): return False
        c._send, c._read, c._confirm = send, read, confirm
        return c, r
    cmd = {"action": "program", "program": 2, "uid": "u", "at": time.time() * 1000}
    idle = {"M": {"timers": {"current": None}}}
    async def boom(command): raise TimeoutError()
    c, r = make(boom, idle); asyncio.run(c.handle("a", cmd))
    assert ("farms/f/irrigation_lock", None) not in r.puts, "timeout: the lock must outlive the handler"
    async def bad(command): return 500, "{}"
    c, r = make(bad, idle); asyncio.run(c.handle("a", cmd))
    assert ("farms/f/irrigation_lock", None) in r.puts
    async def ok(command): return 200, '{"trans_id": 1234567890}'
    c, r = make(ok, idle); asyncio.run(c.handle("a", cmd))      # unconfirmed
    assert ("farms/f/irrigation_lock", None) not in r.puts
    running = {"M": {"timers": {"current": {"completed": "0", "timer_type": "1", "timer_no": "002", "timer_name": "C"}}}}
    sent = []
    async def spy(command): sent.append(command); return 200, "{}"
    c, r = make(spy, running); asyncio.run(c.handle("a", cmd))
    assert not sent and c.refused == 1 and ("farms/f/irrigation_lock", None) not in [p for p in r.puts if p[1] is not None]
    assert ic.controller_state(running)["number"] == 2


def test_relay_never_packs_an_upstream_error_body_and_drops_packet_heads():
    day = relay.reduce_read("electricity_day", {"data": [{"dt": "t", "raw_data": "##,DCON-MCON000X000001,6-0-0!2026-09-24 00:00:00+05:30,,254-248-264"}]})
    assert day["data"][0]["raw_data"] == "!2026-09-24 00:00:00+05:30,,254-248-264" and "MCON" not in json.dumps(day)
    import asyncio
    import gzip, base64
    class Resp:
        status = 502
        async def text(self): return "<html>MCON000X000001 call 9876543210</html>"
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass
    class Sess:
        def post(self, *a, **k): return Resp()
        get = post
    class DB:
        def __init__(self): self.puts = {}
        async def put(self, path, value): self.puts[path] = value
        async def get(self, path, shallow=False): return None
    cfg = types.SimpleNamespace(dcon_relay=True, dcon_serial="S", dcon_token_id="t", dcon_product="DCON",
                                dcon_base="https://x", dcon_device_id="1")
    fake = types.ModuleType("aiohttp"); fake.ClientTimeout = lambda **k: None
    sys.modules["aiohttp"] = fake
    try:
      for call, args in (("programs", {}), ("cmd_status", {"trans_id": "1234567890"}), ("rain", {}),
                         ("electricity_day", {}), ("pressure_day", {"date": "2026-11-08"})):
        db = DB(); r = relay.DconRelay(cfg, db, Sess())
        asyncio.run(r.handle("j", _job(call=call, args=args)))
        res = db.puts["relay/results/j"]
        assert "gz" in res and res["status"] == 502, call
        text = gzip.decompress(base64.b64decode(res["gz"])).decode() if "gz" in res else json.dumps(res)
        assert res["ok"] is False and "MCON" not in text and "9876543210" not in text and "html" not in text, call
    finally:
        sys.modules.pop("aiohttp", None)


def test_confirmation_accepts_the_running_program_and_cmd_status_two():
    prog = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "1", "timer_no": "2",
                                              "timer_name": "Coconut", "on_valves": "12-15-0"}}}}
    backwash = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "4", "timer_no": "2",
                                                  "timer_name": "Backwash Mode", "on_valves": "3-0"}}}}
    done = {"MCON1": {"timers": {"current": {"completed": "1", "timer_type": "1", "timer_no": "2"}}}}
    assert ic.confirmed("program", [], ic.controller_state(prog), 2)
    assert not ic.confirmed("program", [], ic.controller_state(prog), 3), "another program is going"
    assert not ic.confirmed("program", [], ic.controller_state(backwash), 2), "same number, not a program"
    assert not ic.confirmed("program", [], ic.controller_state(done), 2)
    import asyncio
    from types import SimpleNamespace as NS
    c = ic.IrrigationControl(NS(dcon_base="x", dcon_serial="s", dcon_product="DCON"), None, None)
    seen = []
    async def read(call, args=None):
        seen.append((call, args)); return {"sent": "2"}
    c._read = read
    assert asyncio.run(c._status_of("1234567890")) == "2"
    assert seen == [("cmd_status", {"trans_id": "1234567890"})]
    assert asyncio.run(c._status_of("12")) == "" and len(seen) == 1, "only a 10-digit id is asked about"


NODES = {"node1": {"valve": {"1": {"valve_name": "1 Tank", "valve_type": "Fertilizer"},
                             "2": {"valve_name": "2 BPump", "valve_type": "Booster Pump"},
                             "3": {"valve_name": "3 Backwash", "valve_type": "Backwash"},
                             "12": {"valve_name": "12 Coco 1", "valve_type": "Irrigation"},
                             "15": {"valve_name": "15 Coco 2", "valve_type": "Irrigation"}}}}


def _dash(timer_type, completed, name="Coconut"):
    return {"MCONTEST": {"timers": {"current": {"timer_type": timer_type, "completed": completed,
                                                "timer_name": name}}}}


def test_only_irrigation_valves_and_never_over_another_manual_run():
    allowed = ic.irrigation_valves(NODES)
    assert allowed == {12: "12 Coco 1", 15: "15 Coco 2"}, "never the tank, booster or backwash"
    idle = ic.controller_state(_dash("1", "1"))
    ic.check_against("run", [12, 15], idle, allowed)
    assert "not an irrigation valve: 2, 3" in _refused(ic.check_against, "run", [2, 3], idle, allowed)
    busy = ic.controller_state(_dash("1", "0"))
    # A scheduled cycle (Coconut) running does not block a manual run (owner, 2026-09-24)...
    ic.check_against("run", [12], busy, allowed)
    # ...but another manual run does: two manual commands would collide.
    manual = ic.controller_state(_dash("3", "0", "Manual Mode"))
    assert "manual run is already going" in _refused(ic.check_against, "run", [12], manual, allowed)
    ic.check_against("stop", [], manual, allowed)
    assert "scheduled program" in _refused(ic.check_against, "stop", [], busy, allowed)
    assert "no manual run" in _refused(ic.check_against, "stop", [], idle, allowed)


def test_a_change_is_only_confirmed_by_the_controllers_own_state():
    manual = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "3",
                                                "timer_name": "Manual", "on_valves": "4-6-0-0-0"}}}}
    program = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "1",
                                                 "timer_name": "Morning", "on_valves": "4-0-0"}}}}
    idle = {"MCON1": {"timers": {"current": {"completed": "1", "timer_type": "3", "on_valves": "4-6"}}}}
    assert ic.controller_state(manual)["valves"] == [4, 6]
    assert ic.confirmed("run", [4, 6], ic.controller_state(manual))
    assert not ic.confirmed("run", [4, 12], ic.controller_state(manual)), "a valve we asked for is not on"
    assert not ic.confirmed("run", [4], ic.controller_state(program)), "a program is not our manual run"
    assert not ic.confirmed("run", [4, 6], ic.controller_state(idle)), "finished is not running"
    assert ic.confirmed("stop", [], ic.controller_state(idle))
    assert not ic.confirmed("stop", [], ic.controller_state(manual))
    now = 1_800_000_000_000
    assert ic.lock_live({"until": now + 1}, now) and not ic.lock_live({"until": now - 1}, now)
    assert not ic.lock_live(None, now) and not ic.lock_live({"cmd": "x"}, now)


def test_irrigation_control_is_off_without_every_setting():
    from types import SimpleNamespace as NS
    full = dict(allow_irrigation_control=True, dcon_serial="s", dcon_token_id="t",
                dcon_command_auth="x@ios", dcon_device_id="1", dcon_user_slot="A8",
                irrigation_max_minutes=60)
    assert ic.IrrigationControl(NS(**full), None, None).enabled
    for key, off in [("allow_irrigation_control", False),
                     ("dcon_device_id", ""), ("dcon_user_slot", ""), ("dcon_user_slot", "U8")]:
        assert not ic.IrrigationControl(NS(**{**full, key: off}), None, None).enabled, key
    # The command token may come from signing in to Mobitech in the app
    # (private/mobitech), so an empty option does not switch control off.
    assert ic.IrrigationControl(NS(**{**full, "dcon_command_auth": ""}), None, None).enabled


def test_the_signed_in_mobitech_session_wins_over_the_option():
    live, old = "L" * 60 + "@ios", "O" * 60 + "@ios"
    assert ic.pick_token(live, old) == live
    assert ic.pick_token(None, old) == old, "no sign-in yet: the option still works"
    assert ic.pick_token("", old) == old
    assert ic.pick_token("not-a-token", "") == "", "only app-shaped tokens count"
    assert ic.pick_token(None, None) == ""


def test_the_read_relay_still_cannot_send_a_command():
    src = open(os.path.join(os.path.dirname(__file__), "..", "bridge", "relay.py")).read()
    assert "/v1/command" not in src



def test_a_refused_dashboard_is_passed_on_not_trimmed_to_nothing():
    """{"state": "failed"} once trimmed to {}, which read as an idle controller."""
    from bridge import relay
    out = relay.trim_dashboard({"state": "failed", "message": "Your account has been sign-in on other mobile devices. Call 9876543210"})
    assert out["state"] == "failed" and "other mobile devices" in out["message"]
    assert "9876543210" not in out["message"]
    assert set(out) == {"state", "message"}


def test_the_relay_reads_with_the_session_signed_in_from_the_app():
    """One session per account: a sign-in in the app ended the add-on's own,
    and the relay kept using that (2026-09-26)."""
    import asyncio
    from bridge import relay

    signed = "S" * 60 + "@ios"
    old = "O" * 60 + "@ios"

    class RTDB:
        def __init__(self, v): self.v = v
        async def get(self, path, shallow=False):
            assert path == relay.TOKEN_PATH
            return self.v

    cfg = types.SimpleNamespace(dcon_relay=True, dcon_serial="S1", dcon_token_id=old,
                                dcon_product="DCON", dcon_base="https://x")
    assert asyncio.run(relay.DconRelay(cfg, RTDB(signed), None)._token()) == signed
    assert asyncio.run(relay.DconRelay(cfg, RTDB(None), None)._token()) == old
    assert asyncio.run(relay.DconRelay(cfg, RTDB("not a token"), None)._token()) == old
    # The command module picks the same way, from the same place.
    from bridge import irrigation_control as ic
    assert ic.pick_token(signed, old) == signed and ic.TOKEN_PATH == relay.TOKEN_PATH

_TOK = "A" * 22 + ":APA91b" + "b-_" * 44 + "ab" + "@ios"


def test_relay_signin_calls_take_only_well_shaped_args():
    ok = {"otp": {"mobile": "9876543210"},
          "login": {"mobile": "9876543210", "code": "123456", "token": _TOK},
          "prove": {"token": _TOK}}
    for call, args in ok.items():
        assert relay.validate(_job(call=call, args=args)) == (call, args), call
    assert relay.SIGNIN_CALLS == {"otp", "login", "prove"}
    bad = [
        ("otp", {"mobile": "98765432"}), ("otp", {"mobile": "919876543210"}),
        ("otp", {"mobile": "9876543210", "x": "1"}), ("otp", {}),
        ("login", {"mobile": "9876543210", "code": "12", "token": _TOK}),
        ("login", {"mobile": "9876543210", "code": "123456789", "token": _TOK}),
        ("login", {"mobile": "9876543210", "code": "12a456", "token": _TOK}),
        ("login", {"mobile": "9876543210", "code": "123456", "token": "short@ios"}),
        ("login", {"mobile": "9876543210", "code": "123456", "token": _TOK[:-4]}),
        ("login", {"mobile": "9876543210", "code": "123456", "token": _TOK + "&action=x"}),
        ("login", {"mobile": "9876543210", "code": "123456", "token": _TOK.replace("@ios", "@and")}),
        ("login", {"mobile": "9876543210", "code": "123456"}),
        ("prove", {"token": "x" * 50}), ("prove", {"token": _TOK + " "}),
        ("prove", {"token": _TOK, "mobile": "9876543210"}),
    ]
    for call, args in bad:
        assert relay.validate(_job(call=call, args=args)) is None, (call, args)
    assert relay.validate(_job(call="otp", args=ok["otp"], at=(time.time() - 600) * 1000)) is None


def test_relay_signin_requests_match_the_ios_app_byte_for_byte():
    assert relay.signin_request("otp", {"mobile": "9876543210"}) == \
        ("/v1/otp/", '{"mobile":"919876543210"}')
    path, body = relay.signin_request(
        "login", {"mobile": "9876543210", "code": "123456", "token": "ab:cd-_@ios"})
    assert path == "/v1/http/?"
    assert body == ("action=login&type=otp&otp=123456&mobile=9876543210"
                    "&token=ab%3Acd-_%40ios&product=DCON&app_id=com.mobitech.drip")
    path, body = relay.signin_request("prove", {"token": "ab:cd@ios"})
    assert (path, body) == ("/v1/http/",
                            "action=dashboard&p=app&token_id=ab%3Acd%40ios&product=DCON")


def test_relay_reduces_signin_answers_to_an_allow_list():
    raw = json.dumps({"state": "ok", "id": _TOK, "name": "N" * 100, "uname": "sibhi",
                      "mobile": "9876543210", "mail": "a@b.c", "user_id": 77, "x": {"y": 1}})
    out = relay.reduce_signin("login", 200, raw, _TOK)
    assert out == {"state": "ok", "idOk": True, "name": "N" * 64, "uname": "sibhi"}
    other = relay.reduce_signin("login", 200, raw, "different@ios")
    assert other["idOk"] is False
    # No id echoed: the app falls back to the token it sent, so does this.
    assert relay.reduce_signin("login", 200, '{"state":"ok"}', _TOK)["idOk"] is True
    assert relay.reduce_signin("login", 200, '{"state":"ok","id":null}', _TOK)["idOk"] is False
    refused = relay.reduce_signin("login", 200, json.dumps(
        {"state": "failed", "msg": "Wrong code for 9876543210", "mobile": "9876543210"}), _TOK)
    assert set(refused) == {"state", "idOk", "name", "uname", "message"}
    assert "9876543210" not in json.dumps(refused) and refused["state"] == "failed"
    assert relay.reduce_signin("login", 200, "not json", _TOK)["state"] == ""
    # prove: a bool, never the payload (it carries the phone book)
    dash = json.dumps({"MCON1": {"users": {"A1": {"mobile": "919876543210"}}}})
    assert relay.reduce_signin("prove", 200, dash) == {"serves": True}
    for text in ('{"state":"failed","message":"x"}', "[]", "nope", "{}"):
        assert relay.reduce_signin("prove", 200, text) == {"serves": False}, text
    assert relay.reduce_signin("prove", 500, dash) == {"serves": False}
    # otp: only Mobitech's message, trimmed
    assert relay.reduce_signin("otp", 200, '{"message":"Success","otp":"123456"}') == {"message": "Success"}
    assert relay.reduce_signin("otp", 200, "garbage") == {"message": ""}



def test_update_request_decisions():
    info = {"slug": "abc_snof_bridge", "version": "0.10.11", "versionLatest": "0.10.12", "updateAvailable": True}
    now = 1_000_000_000_000
    ok = {"uid": "u1", "at": now - 5_000}

    def chk(req=ok, admin=True, allowed=True, inf=info, last=None, now_s=10_000.0):
        return updater.check_request(req, now, admin, allowed, inf, last, now_s)

    assert chk() is None
    assert "off" in chk(allowed=False)
    assert chk(admin=False) == "not an admin"
    assert "stale" in chk(req={"uid": "u1", "at": now - 121_000})
    assert "stale" in chk(req={"uid": "u1", "at": now + 90_000})
    for bad in (None, "x", {}, {"uid": "u1"}, {"uid": "u1", "at": now, "x": 1},
                {"uid": "a/b", "at": now}, {"uid": "", "at": now}, {"uid": 5, "at": now}):
        assert chk(req=bad) is not None, bad
    assert chk(req={"uid": "u1", "at": True}) == "no timestamp"
    assert chk(inf=None) is not None
    assert chk(inf=dict(info, updateAvailable=False)) == "already up to date"
    assert "10 minutes" in chk(last=10_000.0 - 599)
    assert chk(last=10_000.0 - 601) is None


def test_update_info_and_settling():
    body = {"result": "ok", "data": {"slug": "abc_snof_bridge", "version": "0.10.11",
                                      "version_latest": "0.10.12", "update_available": True}}
    got = updater.parse_self_info(body)
    assert got == {"slug": "abc_snof_bridge", "version": "0.10.11",
                   "versionLatest": "0.10.12", "updateAvailable": True}
    same = {"data": {"slug": "s", "version": "1", "version_latest": "1", "update_available": False}}
    assert updater.parse_self_info(same)["updateAvailable"] is False
    assert updater.parse_self_info({"data": {"slug": "s"}}) is None
    assert updater.parse_self_info("nope") is None
    assert updater.heartbeat_fields(None, False) == {
        "version": None, "versionLatest": None, "updateAvailable": None, "remoteUpdate": False}
    assert updater.heartbeat_fields(got, True)["remoteUpdate"] is True
    node = {"state": "updating", "from": "0.10.11", "to": "0.10.12", "at": 1, "by": "u1"}
    assert updater.finish_state(node, "0.10.12", 5)["state"] == "done"
    assert updater.finish_state(node, "0.10.11", 5)["state"] == "failed"
    assert updater.finish_state(node, None, 5)["state"] == "failed"
    assert updater.finish_state({"state": "done"}, "0.10.12", 5) is None
    assert updater.finish_state(None, "0.10.12", 5) is None


# ---- developer console (bridge/dev_console.py) ------------------------------

DC_NOW = 1_800_000_000.0


def dc_req(**over):
    base = {"uid": "u1", "at": DC_NOW * 1000, "method": "POST", "path": "/v1/http/",
            "query": "", "body": "action=dashboard&token_id={{token}}&product=DCON",
            "bodyType": "form", "auth": True}
    base.update(over)
    return base


def dc_refused(**over):
    try:
        dc.validate(dc_req(**over), DC_NOW)
    except dc.Refused:
        return True
    return False


def test_dev_console_accepts_a_read():
    got = dc.validate(dc_req(), DC_NOW)
    assert got["path"] == "/v1/http/" and got["auth"] is True
    assert dc.validate(dc_req(method="GET", body="", bodyType="none", path="/v1/weather/cumulative/",
                              query="type=rain&device_id={{device_id}}"), DC_NOW)
    assert dc.validate(dc_req(method="GET", body="", bodyType="none", path="/v1/weather/cumulative",
                              query="type=rain"), DC_NOW)


def test_dev_console_refuses_commands_and_sessions():
    assert dc_refused(path="/v1/command/")
    assert dc_refused(path="/v1/command")
    assert dc_refused(path="/v1/otp/")
    assert dc_refused(path="/v1/version/")
    assert dc_refused(path="/v1/commands_x/")
    assert dc_refused(path="/v1/http/", query="action=logout")
    assert dc_refused(path="/v1/http/", query="a=1&action=login&b=2")
    assert dc_refused(query="action=%6Cogout")
    assert dc_refused(query="action%3Dlogout")
    assert dc_refused(query="action%253Dlogout")
    assert dc_refused(query="Action = LOGOUT")
    assert dc_refused(query="type=otp")
    assert dc_refused(body="action=logout&x=1")
    assert dc_refused(body="action=log%69n")
    assert dc_refused(body='{"action": "logout"}', bodyType="json")
    assert dc_refused(body='{"type":"otp"}', bodyType="json")


def test_dev_console_refuses_bad_shapes():
    assert dc_refused(method="PUT")
    assert dc_refused(method="DELETE")
    assert dc_refused(path="/v1/../admin")
    assert dc_refused(path="/v1/http/../x")
    assert dc_refused(path="/v1//http/")
    assert dc_refused(path="/v2/http/")
    assert dc_refused(path="http://evil.example/v1/http/")
    assert dc_refused(path="/v1/Http/")
    assert dc_refused(path="/v1/" + "a" * 61)
    assert dc_refused(query="a=" + "x" * 2000)
    assert dc_refused(body="action=dashboard&a=" + "x" * 8000)
    assert not dc_refused(query="a=" + "x" * 1990)
    assert dc_refused(bodyType="xml")
    assert dc_refused(bodyType="none", body="a=1")
    assert dc_refused(method="GET", body="a=1")
    assert dc_refused(auth="yes")
    assert dc_refused(uid="")
    assert dc_refused(uid="a/b")
    assert dc_refused(at=True)
    assert dc_refused(host="evil.example")           # extra key
    for bad in (None, [], "x", {}):
        try:
            dc.validate(bad, DC_NOW)
            assert False
        except dc.Refused:
            pass


def test_dev_console_refuses_old_requests():
    assert dc_refused(at=(DC_NOW - 61) * 1000)
    assert not dc_refused(at=(DC_NOW - 59) * 1000)
    assert dc_refused(at=(DC_NOW + 120) * 1000)


def test_dev_console_rate_limit():
    stamps = [DC_NOW - i for i in range(dc.MAX_PER_DAY)]
    assert dc.day_allows(stamps[:-1], DC_NOW)
    assert not dc.day_allows(stamps, DC_NOW)
    assert dc.day_allows([DC_NOW - 90000] * 1000, DC_NOW)
    assert dc.MIN_GAP_SECONDS == 3.0


def test_dev_console_fills_placeholders_on_the_nuc():
    req = dc.validate(dc_req(query="a={{serial}}&d={{device_id}}"), DC_NOW)
    q, b, auth = dc.fill(req, "tok@ios-AAAA", "SER123", "dev-9")
    assert q == "a=SER123&d=dev-9"
    assert b == "action=dashboard&token_id=tok%40ios-AAAA&product=DCON"
    assert auth == "tok@ios-AAAA"
    j = dc.validate(dc_req(query="action=dashboard", body='{"t":"{{token}}"}', bodyType="json", auth=False), DC_NOW)
    assert dc.fill(j, 'a"b@ios', "s", "d")[1] == '{"t":"a\\"b@ios"}'
    assert dc.fill(j, 'a"b@ios', "s", "d")[2] == ""
    for args in (("", "s", "d"), ("t@ios", "", "d")):
        try:
            dc.fill(dc.validate(dc_req(query="s={{serial}}&d={{device_id}}"), DC_NOW), *args)
            assert False
        except dc.Refused:
            pass


SECRETS = {"token": "tok-invented-0123456789@ios", "serial": "SN-INVENTED-77",
           "device_id": "dev-invented-42"}


def test_dev_console_redacts_json():
    raw = json.dumps({
        "users": {"a": "Asha 5551230001"}, "sim": "x", "mobile": "m", "email": "e@x.example",
        "imei": "i", "phone": "p",
        "keep": {"Users": 1, "n": 5, "msg": "hi " + SECRETS["token"] + " " + SECRETS["serial"]},
        "packets": {"1": "a", "2": "keep2", "3": "keep3", "4": "b", "5": "c", "8": "d", "9": "keep9"},
        "deep": [{"packets": {"1": 1, "4": 1, "5": 1, "8": 1, "6": "k"}, "id": SECRETS["device_id"]}],
        "num": "call 1234567890 or 123456789012345", "short": "123456789"})
    body, is_json, trunc = dc.redact(raw, SECRETS)
    assert is_json and not trunc
    got = json.loads(body)
    for key in ("users", "sim", "mobile", "email", "imei", "phone"):
        assert key not in got
    assert "Users" not in got["keep"] and got["keep"]["n"] == 5
    assert got["packets"] == {"2": "keep2", "3": "keep3", "9": "keep9"}
    assert got["deep"][0]["packets"] == {"6": "k"}
    assert got["deep"][0]["id"] == "{{device_id}}"
    assert got["keep"]["msg"] == "hi {{token}} {{serial}}"
    assert got["num"] == "call <redacted> or <redacted>" and got["short"] == "123456789"
    for secret in list(SECRETS.values()) + ["5551230001"]:
        assert secret not in body


def test_dev_console_redacts_text_and_truncates():
    body, is_json, trunc = dc.redact("<html>" + SECRETS["token"] + " 98765432101 "
                                     + SECRETS["serial"], SECRETS)
    assert not is_json and not trunc
    assert body == "<html>{{token}} <redacted> {{serial}}"
    big = json.dumps({"rows": ["abcdefgh"] * 100})
    body, is_json, trunc = dc.redact(big, SECRETS, cap=100)
    assert trunc and not is_json and len(body.encode()) <= 100
    # a url-encoded token is caught too
    enc = "x=" + "tok-invented-0123456789%40ios"
    assert dc.redact(enc, SECRETS)[0] == "x={{token}}"
    echoed = dc.echo(dc.validate(dc_req(), DC_NOW), SECRETS)
    assert echoed["body"] == "action=dashboard&token_id={{token}}&product=DCON"
    leaked = dc.echo(dc.validate(dc_req(query="t=" + SECRETS["token"]), DC_NOW), SECRETS)
    assert SECRETS["token"] not in leaked["query"]


def test_dev_console_allow_list():
    ok = lambda q, b="", bt="none", **kw: not dc_refused(query=q, body=b, bodyType=bt, **kw)
    for q in ("action=dashboard", "action=dcon_node_details&type=get", "action=dcon_node&method=get_node",
              "action=dcon_node&method=get_all_valve", "action=dcon_timer&method=select",
              "action=logs&method=timer_log", "action=logs&method=flow_log",
              "action=reports&type=anything_at_all", "action=ferti&type=tank_log_web",
              "action=fertiSett&type=get", "action=getWliData", "action=cmd_status&random_no=1"):
        assert ok(q), q
    for q in ("", "x=1", "action=", "action=nope", "action=Dashboard", "action=dashboard&type=get",
              "action=dashboard&method=x", "action=dcon_node_details&type=set",
              "action=dcon_node&method=set_valve", "action=dcon_node&type=get",
              "action=dcon_timer&method=insert", "action=logs&method=other", "action=logs&type=x",
              "action=reports&method=x", "action=ferti&type=inj_set", "action=fertiSett&type=set",
              "action=getWliData&type=x", "action=logout", "action=login", "action=dashboard&action=logout",
              "action=dashboard&action=dashboard", "action=dcon_node&method=get_node&method=get_node",
              "action=reports&type=a&type=b", "Action=dashboard", "action=dashboard&Type=x",
              "act%69on=dashboard&method=x", "action%2569on=dashboard", "action=dashboard;type=x",
              "action=%7B%7Btoken%7D%7D", "action={{token}}"):
        assert not ok(q), q
    # the allow-list sees the body too
    assert ok("", "action=dashboard&token_id={{token}}", "form")
    assert not ok("action=dashboard", "action=logout", "form")
    assert not ok("action=dashboard", "type=otp", "form")
    assert not ok("action=dashboard", "action=dashboard", "form")
    # weather: only type=rain
    wx = lambda q: not dc_refused(path="/v1/weather/cumulative/", method="GET", query=q, body="", bodyType="none")
    assert wx("type=rain&x=1") and not wx("type=snow") and not wx("") and not wx("type=rain&action=dashboard")
    assert not wx("type=rain&type=rain") and not wx("type=rain&method=x")
    assert dc_refused(path="/v1/weather/")
    assert dc_refused(path="/v1/weather/cumulative/x/")


def test_dev_console_json_bodies():
    ok = lambda b, q="action=dashboard": not dc_refused(query=q, body=b, bodyType="json")
    assert ok('{"a": 1, "b": "x"}')
    assert ok('{"action": "dashboard"}', q="")
    assert ok('{"action": "logs", "method": "motor_log"}', q="")
    assert not ok('{"action": "logout"}', q="")
    assert not ok('{"action": "logout"}')                  # also duplicates the query action
    assert not ok('{"action": "dashboard"}')               # duplicate
    assert not ok('{"type": "otp"}')
    assert not ok('{"a": {"action": "logout"}}')
    assert not ok('{"a": [{"Method": "x"}]}')
    assert not ok('{"action": 5}', q="")
    assert not ok('[1,2]') and not ok('"x"') and not ok('{bad json')
    assert not ok('{"a": {"b": {"type": "otp"}}}')


def test_dev_console_allow_list_file_matches_the_table():
    path = Path(__file__).resolve().parents[3] / "docs" / "dev-console-allowlist.json"
    assert json.loads(path.read_text()) == json.loads(json.dumps(dc.ALLOWED_REQUESTS))


def test_dev_console_scrubs_token_variants_and_phones():
    tok = "abcdefghijklmnopqrstuvwxyz0123456789:ZYXWVUTSRQPONMLKJIHGFEDCBA@ios"
    core = "ZYXWVUTSRQPONMLKJIHGFEDCBA"
    sec = {"token": tok, "serial": "SN-INVENTED-77", "device_id": "dev-invented-42"}
    forms = [tok, tok.replace("@", "%40"), tok.replace(":", "%3A").replace("@", "%40"),
             tok.replace("@", "&#64;"), tok.replace("@", "&#x40;"), "[" + core + "]", "x&amp;" + core,
             tok.replace(":", "%3A")]
    for f in forms:
        got = dc.scrub_text("before " + f + " after", sec)
        assert core not in got and "@ios" not in got, (f, got)
    assert dc.scrub_text("e " + core, sec) == "e {{token}}"
    # phones with separators, +country, brackets
    for ph in ("+91 98765 43210", "(555) 123-4567", "555-123-4567", "98765-43210", "+1 555 123 4567"):
        assert dc.scrub_text("tel " + ph + " end", sec) == "tel <redacted> end", ph
    assert dc.scrub_text("12 345 678", sec) == "12 345 678"            # under 10 digits
    assert dc.scrub_text("at 2026-11-08 12:30:00", sec) == "at 2026-11-08 12:30:00"
    body, _, _ = dc.redact(json.dumps({"mail": "a", "uname": "b", "user_id": "c", "mobile_no": "d",
                                       "name": "Program 1", "t": tok}), sec)
    assert json.loads(body) == {"name": "Program 1", "t": "{{token}}"}


def test_dev_console_request_ids():
    class Rt:
        def __init__(self): self.puts = []
        async def put(self, path, value): self.puts.append((path, value))
    cfg = types.SimpleNamespace(root="farms/snof", farm_slug="snof", allow_dev_console=True,
                                dcon_serial="s", dcon_token_id="t", dcon_command_auth="")
    rt = Rt()
    con = dc.DevConsole(cfg, rt, None)
    for bad in ("a/b", "a.b", "", "x" * 65, "a b", "..", "a#b", "a$b"):
        asyncio.run(con.handle(bad, dc_req()))
    assert con.refused == 8
    # nothing but safely quoted deletes of the request node
    assert all(v is None and p.startswith("farms/snof/dev_requests/") and p.count("/") == 3
               for p, v in rt.puts)
    assert not any(p.startswith("private") for p, _ in rt.puts)
    for good in ("-Nabc_123", "A" * 64):
        assert dc._REQ_ID.match(good)


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
