"""Motor control. No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_motor_control.py

This path starts and stops pumps, so the refusals are the point: switched
off (or this motor not armed) nothing is read or sent; a redelivered trigger
never sends twice; the rate limits hold; a motor already in the asked state,
mid-change, tripped, unpowered or unheard is refused before any send; exactly
one send happens, it is never retried, and the lock is released only when the
motor's own report confirms the change.
"""
import copy
import datetime as dt
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import motor_control as MC  # noqa: E402
import water  # noqa: E402

ROOT = "farms/snof"
NOW = 1_790_300_000.0            # a fixed clock


class Ref:
    def __init__(self, db, path):
        self.db, self.path = db, path.strip("/")

    def _parts(self):
        return [p for p in self.path.split("/") if p]

    def get(self):
        node = self.db.data
        for p in self._parts():
            if not isinstance(node, dict) or p not in node:
                return None
            node = node[p]
        return copy.deepcopy(node)

    def set(self, value):
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

    def update(self, patch):
        cur = self.get() or {}
        cur.update(patch)
        self.set(cur)


class Store:
    def __init__(self, data=None):
        self.data = data or {}
        self.deletes = []

    def reference(self, path):
        return Ref(self, path)


class Clock:
    def __init__(self, t=NOW):
        self.t = t

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def iso(t):
    return dt.datetime.fromtimestamp(t, water.FARM_TZ).isoformat()


class FakeMotor:
    """Reads come from a script; the motor 'applies' a send after n reads."""
    vendor = "livesky"

    def __init__(self, clock, running=False, applies_after=2, applies=True, **state):
        self.clock, self.running, self.after, self.applies = clock, running, applies_after, applies
        self.state, self.sends, self.reads, self.pending_until = state, [], 0, None

    def read(self):
        self.reads += 1
        s = {"vendor": "livesky", "connected": True, "power": True, "trips": [],
             "reportedAt": iso(self.clock.now() - 5), "running": self.running, "pending": False}
        s.update(self.state)
        if self.pending_until is not None:
            if self.reads >= self.pending_until and self.applies:
                self.running, self.pending_until = self.target, None
                s["running"] = self.running
            else:
                s["pending"] = True
        return s

    def send(self, action):
        self.sends.append(action)
        self.target = action == "on"
        self.pending_until = self.reads + self.after
        return "sent to the starter"


def armed_store(**extra):
    data = {"farms": {"snof": {"meta": {"motorControl": {"enabled": True, "motors": {"river": True}}}}}}
    data["farms"]["snof"]["motor_commands"] = {"c1": {}}
    data["farms"]["snof"].update(extra)
    return Store(data)


def cmd(action="on", motor="river", at=None):
    return {"motor": motor, "action": action, "uid": "u1", "at": (NOW if at is None else at) * 1000}


def run(store, c, motor, clock, cmd_id="c1"):
    return MC.handle(store, ROOT, cmd_id, c, motor_factory=lambda _m: motor, now=clock.now, sleep=clock.sleep)


def meta(store):
    return store.reference(f"{ROOT}/{MC.META}").get() or {}


# ---- the happy path ----------------------------------------------------------

def test_on_is_sent_once_and_confirmed_by_the_motor():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock, running=False)
    r = run(store, cmd("on"), m, clock)
    assert r["ok"] and r["verified"] and not r["confirming"], r
    assert m.sends == ["on"], "exactly one send"
    assert store.reference(f"{ROOT}/{MC.LOCK}").get() is None, "confirmed: lock released"
    assert f"{ROOT}/motor_commands/c1" in store.deletes, "the command node always goes"
    assert store.reference(f"{ROOT}/water/river").get()["running"] is True, "confirmed state mirrored"
    assert meta(store)["sent"] == 1


def test_unconfirmed_is_never_resent_and_keeps_the_lock():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock, running=True, applies=False)
    r = run(store, cmd("off"), m, clock)
    assert r["ok"] and not r["verified"], r
    assert "not confirmed" in r["message"]
    assert m.sends == ["off"], "never retried, whatever the motor says"
    assert m.reads <= 1 + MC.VERIFY_WINDOW_SECONDS / MC.VERIFY_EVERY_SECONDS, "reads are bounded"
    lock = store.reference(f"{ROOT}/{MC.LOCK}").get()
    assert lock and lock["until"] > clock.now() * 1000, "left to expire, so nobody resends blind"


# ---- gates before anything is read or sent -----------------------------------

def test_switched_off_or_motor_not_armed_reads_and_sends_nothing():
    for m_meta in ({"enabled": False, "motors": {"river": True}}, {"enabled": True, "motors": {}},
                   {"enabled": True, "motors": {"river": "yes"}}, None):
        clock = Clock()
        store = armed_store()
        store.data["farms"]["snof"]["meta"]["motorControl"] = m_meta
        m = FakeMotor(clock)
        r = run(store, cmd("on"), m, clock)
        assert not r["ok"] and m.reads == 0 and m.sends == [], (m_meta, r)
        assert f"{ROOT}/motor_commands/c1" in store.deletes


def test_malformed_or_stale_commands_are_refused():
    bad = [None, {"motor": "river", "action": "on", "uid": "u1"},
           {**cmd("on"), "extra": 1}, cmd("start"), cmd("on", motor="River Motor"),
           cmd("on", motor="../x"), cmd("on", at=NOW - 120), {**cmd("on"), "at": True}]
    for c in bad:
        clock, store = Clock(), armed_store()
        m = FakeMotor(clock)
        r = run(store, c, m, clock)
        assert not r["ok"] and m.sends == [] and m.reads == 0, (c, r)


def test_a_live_lock_refuses():
    clock = Clock()
    store = armed_store(motor_lock={"until": (NOW + 60) * 1000})
    m = FakeMotor(clock)
    r = run(store, cmd("on"), m, clock)
    assert "still being confirmed" in r["message"] and m.sends == []


def test_a_redelivered_trigger_does_nothing():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock)
    run(store, cmd("on"), m, clock)
    m2 = FakeMotor(clock, running=False)
    clock.t = NOW + 1                       # same command id, delivered again
    store.data["farms"]["snof"]["motor_commands"] = {"c1": {}}
    assert run(store, cmd("on", at=NOW), m2, clock) is None
    assert m2.sends == [] and m2.reads == 0



def test_a_redelivery_after_an_unconfirmed_send_keeps_its_result():
    clock, store = Clock(), armed_store()
    run(store, cmd("off"), FakeMotor(clock, running=True, applies=False), clock)
    first = store.reference(f"{ROOT}/{MC.RESULTS}/c1").get()
    m2 = FakeMotor(clock, running=True)
    assert run(store, cmd("off", at=clock.t), m2, clock) is None, "lock still live, but it is a duplicate"
    assert store.reference(f"{ROOT}/{MC.RESULTS}/c1").get() == first and m2.sends == []

# ---- rate limits -------------------------------------------------------------

def test_rate_limits():
    clock, store = Clock(), armed_store()
    store.data["farms"]["snof"]["meta"]["motorControl"]["motors"]["well-motor"] = True
    assert run(store, cmd("on"), FakeMotor(clock), clock)["verified"]
    # Another motor 5 s after the first claim: the 15 s gap between any two.
    t = NOW + 5
    clock.t = t
    m = FakeMotor(clock)
    r = run(store, cmd("on", motor="well-motor", at=t), m, clock, "c2")
    assert "seconds ago" in r["message"] and m.sends == [], r
    # The same motor again 60 s after its change: its 2-minute cooldown.
    t = NOW + 60
    clock.t = t
    m = FakeMotor(clock, running=True)
    r = run(store, cmd("off", at=t), m, clock, "c3")
    assert "changed moments ago" in r["message"] and m.sends == [], r


def test_daily_cap():
    clock, store = Clock(), armed_store()
    day = MC.farm_day(NOW)
    store.data["farms"]["snof"]["meta"]["motorControl"]["daily"] = {day: {"river": MC.DAILY_CAP}}
    m = FakeMotor(clock)
    r = run(store, cmd("on"), m, clock)
    assert "limit" in r["message"] and m.sends == [] and m.reads == 0, r


# ---- what the motor must say first -------------------------------------------

def test_refused_by_the_motors_own_state():
    cases = [
        ("on", {"running": True}, "already running"),
        ("off", {"running": False}, "already off"),
        ("on", {"pending": True}, "on its way"),
        ("on", {"running": None}, "unknown"),
        ("on", {"trips": ["dry run"]}, "tripped"),
        ("on", {"power": False}, "no power"),
        ("off", {"running": True, "connected": False}, "not connected"),
        ("off", {"running": True, "reportedAt": iso(NOW - 3600)}, "not reported recently"),
    ]
    for action, state, words in cases:
        clock, store = Clock(), armed_store()
        base_running = state.pop("running", action == "off")
        m = FakeMotor(clock, running=base_running, **state)
        if base_running is None:
            m.running = None
        r = run(store, cmd(action), m, clock)
        assert words in r["message"] and m.sends == [], (action, state, r)
        assert store.reference(f"{ROOT}/{MC.LOCK}").get() is None, "no lock without a send"


def test_niagara_request_echo_is_not_the_state():
    s = {"vendor": "niagara", "running": False, "requested": True, "power": True}
    try:
        MC.check_before("on", s, NOW)
        assert False, "a controller still catching up must refuse"
    except MC.Refused as e:
        assert "caught up" in str(e)
    # Confirmation reads the controller's report, never `requested`.
    assert not MC.confirmed("on", {"running": False, "requested": True})
    assert MC.confirmed("on", {"running": True, "requested": True})
    assert not MC.confirmed("off", {"running": False, "pending": True})


# ---- nothing else can reach a motor ------------------------------------------

def test_only_two_commands_exist():
    assert MC.LIVESKY_KEYWORD == {"on": "MOTORON", "off": "MOTOROFF"}
    assert set(MC.NIAGARA_BODY) == {"on", "off"}
    src = (HERE / "motor_control.py").read_text()
    for forbidden in ("AUTOON", "AUTOOFF", "CYCLIC", "menu/9", "settings", "CHANGEFROM"):
        code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
        body = code.split('"""', 2)[2]      # past the module docstring
        assert forbidden not in body.replace("# ", ""), forbidden


def test_no_other_code_can_command_a_motor():
    """The command endpoints and the queue are named in motor_control.py and
    the one trigger in main.py, nowhere else: the water poll, the reports and
    the valve path cannot start or stop a motor."""
    for path in HERE.glob("*.py"):
        text = path.read_text()
        if path.name != "motor_control.py":
            assert "applychange" not in text, path.name
            assert "manualstatus" not in text, path.name
        if path.name not in ("motor_control.py", "main.py"):
            assert "motor_commands" not in text, path.name
    main = (HERE / "main.py").read_text()
    # Only the trigger reads the queue; nothing writes it.
    assert len(re.findall(r"motor_commands", main)) == 1, "one trigger path, nothing else"
    assert "motor_control.handle(" in main


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
