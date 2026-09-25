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


def cmd(action="on", motor="river", at=None, client=None):
    at = NOW if at is None else at
    return {"motor": motor, "action": action, "uid": "u1", "at": at * 1000,
            "clientAt": (at if client is None else client) * 1000}


def run(store, c, motor, clock, cmd_id="c1"):
    # The trigger fires for a node that exists; its result does not yet.
    if store.reference(f"{ROOT}/{MC.RESULTS}/{cmd_id}").get() is None:
        store.reference(f"{ROOT}/{MC.QUEUE}/{cmd_id}").set(c if isinstance(c, dict) else {"x": 1})
    return MC.handle(store, ROOT, cmd_id, c, motor_factory=lambda _m: motor, now=clock.now, sleep=clock.sleep)


def lock(store):
    return (meta(store) or {}).get("lock")


def meta(store):
    return store.reference(f"{ROOT}/{MC.META}").get() or {}


# ---- the happy path ----------------------------------------------------------

def test_on_is_sent_once_and_confirmed_by_the_motor():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock, running=False)
    r = run(store, cmd("on"), m, clock)
    assert r["ok"] and r["verified"] and not r["confirming"], r
    assert m.sends == ["on"], "exactly one send"
    assert lock(store) is None, "confirmed: lock released"
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
    held = lock(store)
    assert held and held["until"] > clock.now() * 1000, "left to expire, so nobody resends blind"


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
    store = armed_store()
    store.data["farms"]["snof"]["meta"]["motorControl"]["lock"] = {"cmd": "other", "until": (NOW + 60) * 1000}
    m = FakeMotor(clock)
    r = run(store, cmd("on"), m, clock)
    assert "still being confirmed" in r["message"] and m.sends == []


def test_a_redelivered_trigger_does_nothing():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock)
    run(store, cmd("on"), m, clock)
    m2 = FakeMotor(clock, running=False)
    clock.t = NOW + 1                       # same command id, delivered again
    assert run(store, cmd("on", at=NOW), m2, clock) is None
    assert m2.sends == [] and m2.reads == 0



def test_a_redelivery_after_an_unconfirmed_send_keeps_its_result():
    clock, store = Clock(), armed_store()
    run(store, cmd("off"), FakeMotor(clock, running=True, applies=False), clock)
    first = store.reference(f"{ROOT}/{MC.RESULTS}/c1").get()
    m2 = FakeMotor(clock, running=True)
    assert run(store, cmd("off", at=clock.t), m2, clock) is None, "lock still live, but it is a duplicate"
    assert store.reference(f"{ROOT}/{MC.RESULTS}/c1").get() == first and m2.sends == []


def test_a_refused_command_never_runs_on_redelivery():
    # Review bug 1: refused (lock live), then the same event again once the
    # lock has cleared — it must not be claimed and sent.
    clock, store = Clock(), armed_store()
    store.data["farms"]["snof"]["meta"]["motorControl"]["lock"] = {"cmd": "x", "until": (NOW + 5) * 1000}
    m = FakeMotor(clock)
    r = run(store, cmd("on"), m, clock)
    assert not r["ok"] and m.sends == []
    store.data["farms"]["snof"]["meta"]["motorControl"].pop("lock")
    m2 = FakeMotor(clock)
    assert MC.handle(store, ROOT, "c1", cmd("on"), motor_factory=lambda _m: m2, now=clock.now, sleep=clock.sleep) is None
    assert m2.sends == [] and m2.reads == 0


def test_a_failed_read_while_confirming_is_just_another_try():
    # Review bug 2: a Refused from read() mid-confirmation must not end it.
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock, running=False)
    real = m.read
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] == 2:
            raise MC.Refused("no such motor at the other farm")
        return real()
    m.read = flaky
    r = run(store, cmd("on"), m, clock)
    assert r["verified"] and not r["confirming"] and m.sends == ["on"], r
    assert meta(store).get("refused") is None


def test_a_press_queued_offline_is_refused():
    # Review bug 3: arrives (server `at`) long after the press (clientAt).
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock)
    r = run(store, cmd("on", client=NOW - 600), m, clock)
    assert "offline" in r["message"] and m.sends == [] and m.reads == 0, r
    r = run(store, {k: v for k, v in cmd("on").items() if k != "clientAt"}, FakeMotor(clock), clock, "c2")
    assert "press time" in r["message"]


def test_the_lock_is_taken_with_the_claim_and_released_only_by_its_owner():
    # Review bug 4.
    clock, store = Clock(), armed_store()
    txn_meta = {"enabled": True, "motors": {"river": True}}
    out = {}
    after = MC.claim_txn("A", "river", NOW * 1000, out)(txn_meta)
    assert after["lock"]["cmd"] == "A" and out["claimed"] == "yes"
    out2 = {}
    MC.claim_txn("B", "river", (NOW + 60) * 1000, out2)(after)
    assert "still being confirmed" in out2["why"]
    store.data["farms"]["snof"]["meta"]["motorControl"]["lock"] = {"cmd": "B", "until": (NOW + 99) * 1000}
    MC.release(store, ROOT, "A")
    assert lock(store)["cmd"] == "B", "A cannot release B's lock"


def test_refusals_do_not_spend_the_cooldown_or_the_daily_count():
    clock, store = Clock(), armed_store()
    r = run(store, cmd("on"), FakeMotor(clock, running=True), clock)          # already running
    assert "already running" in r["message"]
    mc = meta(store)
    assert not (mc.get("lastByMotor") or {}) and not (mc.get("daily") or {}) and lock(store) is None
    clock.t = NOW + 20
    r = run(store, cmd("on", at=NOW + 20), FakeMotor(clock), clock, "c2")
    assert r["verified"], r


def test_disarming_during_the_read_stops_the_send():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock)
    real = m.read

    def read_then_disarm():
        store.data["farms"]["snof"]["meta"]["motorControl"]["enabled"] = False
        return real()
    m.read = read_then_disarm
    r = run(store, cmd("on"), m, clock)
    assert "switched off" in r["message"] and m.sends == [] and lock(store) is None


def test_a_send_that_fails_mid_flight_says_it_may_have_been_sent_and_keeps_the_lock():
    clock, store = Clock(), armed_store()
    m = FakeMotor(clock)

    def boom(_a):
        raise TimeoutError()
    m.send = boom
    r = run(store, cmd("on"), m, clock)
    assert "may have been sent" in r["message"] and not r["confirming"] and lock(store), r


def test_livesky_on_is_confirmed_only_with_current_flowing():
    assert not MC.confirmed("on", {"vendor": "livesky", "running": True, "amps": [0, 0]})
    assert MC.confirmed("on", {"vendor": "livesky", "running": True, "amps": [10.1, 10.2]})
    assert MC.confirmed("off", {"vendor": "livesky", "running": False, "amps": [0, 0]})


def test_a_silent_zoned_niagara_controller_is_refused():
    s = {"vendor": "niagara", "running": False, "requested": False, "power": True, "liveAt": iso(NOW - 3600)}
    try:
        MC.check_before("on", s, NOW)
        assert False
    except MC.Refused as e:
        assert "not reported" in str(e)


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
        assert lock(store) is None, "no lock without a send"


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

def test_only_known_commands_exist():
    assert MC.LIVESKY_KEYWORD == {"on": "MOTORON", "off": "MOTOROFF"}
    assert set(MC.NIAGARA_BODY) == {"on", "off"}
    src = (HERE / "motor_control.py").read_text()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    body = code.split('"""', 2)[2]      # past the module docstring
    for forbidden in ("AUTOON", "AUTOOFF", "CYCLIC", "menu/91", "menu/93", "PROGSTART", "MANUALON",
                      "MANUALSWITCH", "VALVEON", "SKIPDAY", "DRYRUN"):
        assert forbidden not in body, forbidden
    # The one settings write: CHANGE FROM on the drip menu, nothing else.
    assert body.count("menu/92/settings") == 2, "one read of the menu, one write"
    assert body.count("CHANGEFROM") == 1


class FakeZoned(FakeMotor):
    """The zoned Niagara controller: running program P1 on a zone."""
    vendor = "niagara"

    def __init__(self, clock, zone=3, running=True, program="P1", moves=True, stops=False, **kw):
        super().__init__(clock, running=running, **kw)
        self.zone, self.program, self.moves, self.stops, self.zone_sends = zone, program, moves, stops, []

    def read(self):
        self.reads += 1
        return {"vendor": "niagara", "running": self.running, "requested": self.running, "power": True,
                "liveAt": iso(self.clock.now() - 5), "program": self.program, "zone": self.zone}

    def send_zone(self, zone):
        self.zone_sends.append(zone)
        if self.stops:
            self.running = False
        elif self.moves:
            self.zone = zone
        return "sent to the controller"


def zone_store(zones=True):
    store = armed_store()
    mc = store.data["farms"]["snof"]["meta"]["motorControl"]
    mc["motors"]["well-motor"] = True
    if zones:
        mc["zones"] = {"well-motor": True}
    return store


def zcmd(zone=5, **kw):
    c = cmd("zone", motor="well-motor", **kw)
    c["zone"] = zone
    return c


def test_zone_change_is_sent_once_and_confirmed_by_the_controller():
    clock, store = Clock(), zone_store()
    m = FakeZoned(clock)
    r = run(store, zcmd(5), m, clock)
    assert r["ok"] and r["verified"] and "zone 5" in r["message"], r
    assert m.zone_sends == [5] and m.sends == [], "one zone change, no motor command"
    assert lock(store) is None


def test_zone_change_refusals():
    cases = [
        (dict(running=False), "never starts it"),
        (dict(program=None), "no program"),
        (dict(zone=5), "already on zone 5"),
    ]
    for state, words in cases:
        clock, store = Clock(), zone_store()
        m = FakeZoned(clock, **state)
        r = run(store, zcmd(5), m, clock)
        assert words in r["message"] and m.zone_sends == [], (state, r)
    clock, store = Clock(), zone_store(zones=False)          # motor armed, zones not
    m = FakeZoned(clock)
    r = run(store, zcmd(5), m, clock)
    assert "zone changes are switched off" in r["message"] and m.reads == 0
    clock, store = Clock(), zone_store()                       # the river has no zones
    store.data["farms"]["snof"]["meta"]["motorControl"]["zones"]["river"] = True
    r = run(store, cmd("zone", motor="river") | {"zone": 2}, FakeMotor(clock), clock)
    assert "no zones" in r["message"], r
    for bad in (0, 9, "3", 2.5, True, None):
        clock, store = Clock(), zone_store()
        r = run(store, zcmd(bad), FakeZoned(clock), clock)
        assert "zone must be 1-8" in r["message"], (bad, r)
    r = run(zone_store(), cmd("on", motor="well-motor") | {"zone": 3}, FakeZoned(Clock(), running=False), Clock())
    assert "only goes with a zone change" in r["message"]


def test_a_zone_change_the_controller_answers_differently_is_said_plainly():
    clock, store = Clock(), zone_store()
    r = run(store, zcmd(5), FakeZoned(clock, stops=True), clock)
    assert not r["verified"] and "motor has stopped" in r["message"] and lock(store), r
    clock, store = Clock(), zone_store()
    r = run(store, zcmd(5), FakeZoned(clock, moves=False), clock)
    assert not r["verified"] and "has not reported zone 5" in r["message"], r


def test_zone_request_matches_the_capture():
    """docs/niagara-app.md: POST …/menu/92/settings {menuSettingId, sendData,
    sentSms: "CHANGEFROM003", receivedData: ""}, found by the item's name."""
    import json as _json

    class Resp:
        def __init__(self, body): self.status_code, self._b = 200, body
        def json(self): return self._b

    class Http:
        def __init__(self): self.posts = []
        def post(self, url, json=None, headers=None, timeout=None):
            self.posts.append((url, json, headers)); return Resp({"code": 200, "message": "SUCCESS"})

    http = Http()
    m = MC.NiagaraMotor("http://h:8080/api/v1", "7", "well-motor", http=http)
    m._id = 42
    m._client._get = lambda path: {"code": 200, "data": [{"menuItem": "DRIP COMMON SETTINGS", "menuSettingId": 1},
                                                         {"menuItem": "CHANGE FROM", "menuSettingId": 486}]}
    assert m.send_zone(3) == "sent to the controller"
    url, body, headers = http.posts[0]
    assert url == "http://h:8080/api/v1/user/7/subuser/0/controller/42/menu/92/settings"
    assert body == {"menuSettingId": 486, "sentSms": "CHANGEFROM003", "receivedData": "",
                    "sendData": '{"changeFromValue":"3","type":"128","placeHolderString":"Change From"}'}, body
    assert headers == {"deviceType": "web"}
    m._client._get = lambda path: {"code": 200, "data": []}
    try:
        m.send_zone(3); assert False
    except MC.Refused as e:
        assert "CHANGE FROM" in str(e)
    assert len(http.posts) == 1, "nothing sent without the setting"


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
