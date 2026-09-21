"""Pure-logic checks for the bridge. No network, no Firebase, no HA.

Run from the add-on directory:  python3 tests/test_logic.py
"""
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


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
