"""Irrigation control in the Cloud Function. No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_irrigation_control.py

This path operates valves, so the negative cases are the point: switched off
it must not touch the queue; a redelivered trigger must not send twice; a
second command inside 10 s, a non-irrigation valve, a stop with no manual run
and a stale or malformed command must all be refused without a send.
"""
import copy
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import irrigation_control as IC  # noqa: E402

ROOT = "farms/snof"


class Ref:
    def __init__(self, db, path):
        self.db, self.path = db, path.strip("/")

    def _parts(self):
        return [p for p in self.path.split("/") if p]

    def get(self, shallow=False):
        node = self.db.data
        for p in self._parts():
            if not isinstance(node, dict) or p not in node:
                return None
            node = node[p]
        return copy.deepcopy(node)

    def set(self, value):
        self.db.writes.append((self.path, value))
        parts = self._parts()
        node = self.db.data
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        if value is None:
            node.pop(parts[-1], None)
        else:
            node[parts[-1]] = copy.deepcopy(value)

    def delete(self):
        self.db.deletes.append(self.path)
        self.set(None)

    def transaction(self, fn):
        self.set(fn(self.get()))


class Store:
    def __init__(self, data=None):
        self.data = data or {}
        self.writes, self.deletes = [], []

    def reference(self, path):
        return Ref(self, path)


NODES = {"node1": {"valve": {
    "4": {"valve_name": "4 Veg", "valve_type": "Irrigation"},
    "6": {"valve_name": "6 Kulam", "valve_type": "Irrigation"},
    "2": {"valve_name": "2 BPump", "valve_type": "Booster Pump"},
}}}
IDLE = {"MCON1": {"timers": {"current": {"completed": "1", "timer_type": "1", "timer_name": "Morning"}}}}
MANUAL = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "3", "timer_name": "Manual"}}}}
PROGRAM = {"MCON1": {"timers": {"current": {"completed": "0", "timer_type": "1", "timer_name": "Morning"}}}}


class Reads:
    def __init__(self, dashboard=IDLE):
        self._dash = dashboard

    def nodes(self):
        return NODES

    def dashboard(self):
        return self._dash


class Commander:
    def __init__(self):
        self.sent = []

    def send(self, command):
        self.sent.append(command)
        return 200, '{"message": "Command sent"}'


def enabled_store(**meta):
    return Store({"farms": {"snof": {"meta": {"irrigationControl": {"enabled": True, **meta}},
                                     "irrigation_commands": {}}}})


def cmd(**over):
    base = {"action": "run", "valves": "4,6", "minutes": 20, "uid": "u1", "at": time.time() * 1000}
    base.update(over)
    return base


def run(store, cmd_id, command, reads=None, commander=None, now=time.time):
    commander = commander or Commander()
    store.data.setdefault("farms", {}).setdefault("snof", {}).setdefault("irrigation_commands", {})[cmd_id] = command
    result = IC.handle(store, ROOT, cmd_id, command, reads=reads or Reads(),
                       commander_factory=lambda: commander, slot="A8", max_minutes=60, now=now)
    return result, commander


def test_switched_off_leaves_the_queue_to_the_nuc():
    store = Store({"farms": {"snof": {"meta": {}, "irrigation_commands": {}}}})
    result, c = run(store, "-a", cmd())
    assert result is None and c.sent == []
    # Not one write or delete anywhere: the NUC still owns this queue.
    assert store.deletes == [] and store.writes == [], (store.deletes, store.writes)
    assert store.reference(f"{ROOT}/irrigation_commands/-a").get() is not None, "node must stay for the NUC"
    store2 = Store({"farms": {"snof": {"meta": {"irrigationControl": {"enabled": False}}}}})
    assert run(store2, "-b", cmd())[0] is None


def test_run_sends_the_template_and_records_it():
    store = enabled_store()
    result, c = run(store, "-a", cmd())
    assert c.sent == ["FON 004,006,000,000,000-00 20-" + IC._FON_TAIL + "@A8"], c.sent
    assert result["ok"] and result["valves"] == "4 Veg, 6 Kulam" and result["runtime"] == "cloud-functions"
    assert store.reference(f"{ROOT}/irrigation_command_results/-a").get()["ok"] is True
    assert store.reference(f"{ROOT}/irrigation_commands/-a").get() is None, "handled node is deleted"
    assert store.reference(f"{ROOT}/meta/irrigationControl/sent").get() == 1


def test_a_redelivered_trigger_never_sends_twice():
    store = enabled_store()
    c = Commander()
    first, _ = run(store, "-a", cmd(), commander=c)
    again, _ = run(store, "-a", cmd(), commander=c, now=lambda: time.time() + 30)
    assert first["ok"] and again is None and len(c.sent) == 1, c.sent


def test_second_command_inside_ten_seconds_is_refused():
    store = enabled_store()
    c = Commander()
    t = time.time()
    run(store, "-a", cmd(at=t * 1000), commander=c, now=lambda: t)
    second, _ = run(store, "-b", cmd(at=t * 1000), commander=c, now=lambda: t + 4)
    assert len(c.sent) == 1 and second["ok"] is False and "seconds ago" in second["message"]
    third, _ = run(store, "-c", cmd(at=(t + 11) * 1000), commander=c, now=lambda: t + 11)
    assert third["ok"] and len(c.sent) == 2


def test_refusals_never_send():
    cases = {
        "booster pump is not an irrigation valve": (cmd(valves="2"), Reads()),
        "a program is running": (cmd(), Reads(PROGRAM)),
        "stop with nothing running": (cmd(action="stop", valves=None, minutes=None), Reads(IDLE)),
        "stop a scheduled program": (cmd(action="stop", valves=None, minutes=None), Reads(PROGRAM)),
        "stale": (cmd(at=(time.time() - 300) * 1000), Reads()),
        "too long": (cmd(minutes=61), Reads()),
        "six valves": (cmd(valves="1,2,3,4,5,6"), Reads()),
        "valve twice": (cmd(valves="4,4"), Reads()),
        "extra field": (dict(cmd(), command="FON 999"), Reads()),
        "unknown action": (cmd(action="open"), Reads()),
    }
    for why, (command, reads) in cases.items():
        command = {k: v for k, v in command.items() if v is not None}
        store = enabled_store()
        result, c = run(store, "-x", command, reads=reads)
        assert c.sent == [] and result["ok"] is False, f"sent for: {why} -> {result}"
        assert store.reference(f"{ROOT}/irrigation_commands/-x").get() is None, f"left behind: {why}"


def test_stop_a_manual_run():
    store = enabled_store()
    result, c = run(store, "-s", {"action": "stop", "uid": "u1", "at": time.time() * 1000}, reads=Reads(MANUAL))
    assert c.sent == ["OFF@A8"] and result["ok"]


def test_a_bad_slot_is_refused_before_any_read():
    store = enabled_store()
    c = Commander()
    store.data["farms"]["snof"]["irrigation_commands"]["-a"] = cmd()
    result = IC.handle(store, ROOT, "-a", cmd(), reads=Reads(), commander_factory=lambda: c,
                       slot="U3", max_minutes=60)
    assert c.sent == [] and "not configured" in result["message"]


def test_command_template_matches_the_add_on():
    assert IC.run_command([12, 15], 80, "A8") == "FON 012,015,000,000,000-01 20-" + IC._FON_TAIL + "@A8"
    assert IC.stop_command("A8") == "OFF@A8"


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
