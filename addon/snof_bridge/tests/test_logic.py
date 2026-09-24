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
    control_domains=frozenset({"switch", "light", "fan"}),
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
    # Byte for byte what the Mobitech app sent on 2026-09-17 (valves 8 and 9
    # for ten minutes) and 2026-09-20 17:24 (valve 6 for two hours).
    assert ic.run_command([8, 9], 10, "A1") == (
        "FON 008,009,000,000,000-00 10-00,00,00,00,00-0000,0000,0000,0000,0000"
        "-00-00-0-0-0000-0000!0--@A1")
    assert ic.run_command([6], 120, "A1").startswith("FON 006,000,000,000,000-02 00-")
    assert _refused(ic.run_command, [30], 480, "A1"), "three hours is the hard ceiling"
    assert ic.run_command([12, 15], 60, "A8").startswith("FON 012,015,000,000,000-01 00-")
    assert ic.stop_command("A8") == "OFF@A8"
    assert _refused(ic.stop_command, "U8"), "a U slot means pause to Mobitech"
    assert _refused(ic.run_command, [1, 2, 3, 4, 5, 6], 10, "A8")
    assert _refused(ic.run_command, [4, 4], 10, "A8")


def test_irrigation_validation_refuses_everything_else():
    now = 1_790_000_000.0
    ok = {"action": "run", "valves": "12,15", "minutes": 20, "uid": "u", "at": now * 1000}
    assert ic.validate(ok, 60, now) == ("run", [12, 15], 20)
    assert ic.validate({"action": "stop", "uid": "u", "at": now * 1000}, 60, now) == ("stop", [], 0)
    bad = [
        {**ok, "action": "program"},
        {**ok, "minutes": 61}, {**ok, "minutes": 0}, {**ok, "minutes": 20.5}, {**ok, "minutes": True},
        {**ok, "valves": "12;15"}, {**ok, "valves": "1,2,3,4,5,6"}, {**ok, "valves": "12,12"},
        {**ok, "valves": 12}, {**ok, "at": (now - 61) * 1000}, {**ok, "at": "now"},
        {**ok, "command": "OFF@A8"}, "FON 012", None,
    ]
    for cmd in bad:
        assert _refused(ic.validate, cmd, 60, now), cmd


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
    for key, off in [("allow_irrigation_control", False), ("dcon_command_auth", ""),
                     ("dcon_device_id", ""), ("dcon_user_slot", ""), ("dcon_user_slot", "U8")]:
        assert not ic.IrrigationControl(NS(**{**full, key: off}), None, None).enabled, key


def test_the_read_relay_still_cannot_send_a_command():
    src = open(os.path.join(os.path.dirname(__file__), "..", "bridge", "relay.py")).read()
    assert "/v1/command" not in src



if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
