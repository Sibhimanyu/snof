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
        if path.name != "commands.py":
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


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
