"""Motor control: on and off for the river motor (Livesky) and the other
farm's two motors (Niagara). The only code in SNOF that can start or stop a
motor, and the only place their command endpoints are named.

Built from the ground up on the owner's rules (2026-09-25): the vendors' own
apps barely guard their APIs (repeated calls, no confirmation), so SNOF does
all of it, and no motor may ever be started or stopped by anything automatic.

    app ──append──▶ /farms/<farm>/motor_commands/<id>   {motor, action, uid, at}
    fn  ◀─onCreate─┘  validate, claim, read the motor, send once, confirm
    fn  ──result───▶ /farms/<farm>/motor_command_results/<id>

Gates, every one of which must pass:

1. **RTDB rules**: only an admin may append; only while
   meta/motorControl/enabled and meta/motorControl/motors/<motor> are true
   (service account only); only while no change is in flight
   (meta/motorControl/lock); `at` must be the server's now and the press
   time `clientAt` within 30 s of it (a write queued offline is refused);
   `motor` and `action` shape-checked.
2. **This module re-checks all of it** and adds what only it can know:
   * the command is fresh (≤ 60 s) and has exactly the four fields;
   * once only: claimed in a transaction (triggers are at-least-once);
   * **rate limits**, in the same transaction: 15 s between any two commands,
     2 min between changes to one motor, 12 changes per motor per farm day;
   * **a live read of the motor before sending**: refused if it is already
     in that state, if a change is still on its way to it, if its state is
     unknown, if it is tripped, has no power or (Livesky) no link, or if its
     last report is stale.
3. **Exactly one send, never retried.** Livesky once left a command
   unapplied and its app sent it again; SNOF does not. The lock is taken
   before sending and the motor is read every 10 s for up to 150 s until its
   *own* report shows the change (Livesky: `motor_status` without
   "-inprogress"; Niagara: the controller's report, never `status`, which
   only echoes the request). Confirmed: the lock is released. Not confirmed:
   the lock is left to expire, so nobody fires a second command blind.

Only two commands exist per vendor. Nothing here can send auto-start
(Livesky's AUTOON starts a stopped motor on its own), timers, settings or
programs. Nothing automatic can reach this module: the only caller is the
motor_command trigger, and tests/test_motor_control.py checks that no other
code names these endpoints or the queue.

The pure pieces (validate, checks, confirmation, the claim transaction) are
tested with no network and nothing installed.
"""
from __future__ import annotations

import datetime as _dt
import re
import time
from typing import Any

import water

QUEUE = "motor_commands"
RESULTS = "motor_command_results"
META = "meta/motorControl"

ACTIONS = ("on", "off")
MAX_AGE_SECONDS = 60.0
# The press itself (clientAt, the phone's clock corrected to the server's) and
# its arrival (at, the server's own time) must be this close: a write queued
# while offline arrives late and is refused, never run hours afterwards.
MAX_QUEUE_SECONDS = 30.0
MIN_GAP_SECONDS = 15.0
MOTOR_COOLDOWN_SECONDS = 120.0
DAILY_CAP = 12
VERIFY_EVERY_SECONDS = 10.0
VERIFY_WINDOW_SECONDS = 150.0
# Reads made while confirming get a shorter timeout, so the whole attempt fits
# the function's budget: pre-read (≤ ~60 s for Niagara) + send (≤ 20 s) +
# window (150 s) + one last read (≤ ~30 s) < FUNCTION_TIMEOUT_SECONDS.
CONFIRM_READ_TIMEOUT = 10
FUNCTION_TIMEOUT_SECONDS = 320
# Longer than the function can live, so the lock always outlives the attempt;
# left to expire when the motor never confirms.
LOCK_SECONDS = 340.0
# The zoned Niagara controller sends a live packet every few seconds while
# connected; older than this, it is not answering.
NIAGARA_LIVE_STALE_SECONDS = 15 * 60
# A Livesky starter reports every few seconds; older than this, it is not
# answering and a command would not be heard.
LIVESKY_STALE_SECONDS = 15 * 60

RIVER = "river"
_MOTOR = re.compile(r"^[a-z0-9-]{1,40}$")
SERVER_TIMESTAMP = {".sv": "timestamp"}

# The two commands, spelled exactly as the vendors' apps send them
# (docs/livesky-app.md, docs/niagara-app.md). Nothing else is ever sent.
LIVESKY_KEYWORD = {"on": "MOTORON", "off": "MOTOROFF"}
NIAGARA_BODY = {"on": {"status": "1", "sentSms": "MTRON,iPhone"},
                "off": {"status": "0", "sentSms": "MTROF,iPhone"}}


class Refused(Exception):
    """A command that will not be sent, with the reason in plain words."""


class _Duplicate(Exception):
    """A redelivered trigger for a command already handled: do nothing."""


# ---- pure --------------------------------------------------------------------

def validate(cmd: Any, now: float) -> tuple[str, str]:
    """(motor, action) for a command worth considering, else Refused."""
    if not isinstance(cmd, dict):
        raise Refused("not an object")
    extra = set(cmd) - {"motor", "action", "uid", "at", "clientAt"}
    if extra:
        raise Refused(f"unexpected fields {sorted(extra)}")
    motor, action = cmd.get("motor"), cmd.get("action")
    if not isinstance(motor, str) or not _MOTOR.match(motor):
        raise Refused("unknown motor")
    if action not in ACTIONS:
        raise Refused("unknown action")
    if not isinstance(cmd.get("uid"), str) or not cmd["uid"]:
        raise Refused("no user")
    at = cmd.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        raise Refused("no timestamp")
    age = now - at / 1000.0
    if age > MAX_AGE_SECONDS or age < -60:
        raise Refused(f"stale by {age:.0f}s")
    client = cmd.get("clientAt")
    if not isinstance(client, (int, float)) or isinstance(client, bool):
        raise Refused("no press time")
    if abs(at - client) > MAX_QUEUE_SECONDS * 1000:
        raise Refused("pressed while offline; it arrived too late to act on")
    return motor, action


def armed(meta: Any, motor: str) -> bool:
    """meta/motorControl: switched on, and this motor switched on."""
    if not isinstance(meta, dict) or meta.get("enabled") is not True:
        return False
    motors = meta.get("motors")
    return isinstance(motors, dict) and motors.get(motor) is True


def lock_live(lock: Any, now_ms: float) -> bool:
    return isinstance(lock, dict) and isinstance(lock.get("until"), (int, float)) and lock["until"] > now_ms


def farm_day(now_s: float) -> str:
    return _dt.datetime.fromtimestamp(now_s, water.FARM_TZ).strftime("%Y-%m-%d")


def check_before(action: str, state: dict, now_s: float) -> None:
    """What the motor's own fresh report must say before anything is sent."""
    if not state:
        raise Refused("could not read the motor")
    if state.get("pending"):
        raise Refused("a change is still on its way to this motor")
    requested, running = state.get("requested"), state.get("running")
    if requested is not None and running is not None and requested != running:
        raise Refused("the controller has not caught up with the last request")
    if running is None:
        raise Refused("the motor's state is unknown")
    if action == "on" and running:
        raise Refused("it is already running")
    if action == "off" and not running:
        raise Refused("it is already off")
    if state.get("vendor") == "livesky":
        if not state.get("connected"):
            raise Refused("the starter is not connected")
        at = _iso_seconds(state.get("reportedAt"))
        if at is None or now_s - at > LIVESKY_STALE_SECONDS:
            raise Refused("the starter has not reported recently")
    if state.get("vendor") == "niagara" and state.get("liveAt"):
        at = _iso_seconds(state.get("liveAt"))
        if at is None or now_s - at > NIAGARA_LIVE_STALE_SECONDS:
            raise Refused("the controller has not reported recently")
    if action == "on":
        if state.get("trips"):
            raise Refused(f"it tripped ({', '.join(state['trips'])}): check it at the pump")
        if state.get("power") is False:
            raise Refused("there is no power at the motor")


def confirmed(action: str, state: dict) -> bool:
    """Does the motor's own report show the change? Never the request echo."""
    if not state or state.get("pending"):
        return False
    if state.get("running") is not (action == "on"):
        return False
    # Livesky "on" is the starter's word; current flowing is the pump's. A
    # dry-run trip seconds later would otherwise read as a confirmed start.
    if action == "on" and state.get("vendor") == "livesky" and state.get("amps") is not None:
        return any(a > 0 for a in state.get("amps") or [])
    return True


def _iso_seconds(value: Any) -> float | None:
    try:
        return _dt.datetime.fromisoformat(str(value)).timestamp()
    except (TypeError, ValueError):
        return None


def claim_txn(cmd_id: str, motor: str, now_ms: float, outcome: dict):
    """One transaction on meta/motorControl decides everything that could
    race: still armed, once only, no change in flight (the lock lives here),
    the 15 s gap, this motor's cooldown and today's cap. It takes the lock.
    Cooldown and the daily count are *spent* only once a command is sent
    (record_sent), so a refusal costs nothing."""
    def txn(meta):
        outcome.clear()                       # retries must not keep an old verdict
        meta = dict(meta or {})
        claimed = dict(meta.get("claimed") or {})
        if cmd_id in claimed:
            outcome["why"] = "duplicate"
            return meta
        if not armed(meta, motor):
            outcome["why"] = "motor control is switched off for this motor"
            return meta
        if lock_live(meta.get("lock"), now_ms):
            outcome["why"] = "the last motor change is still being confirmed"
            return meta
        last = meta.get("lastSent")
        if isinstance(last, (int, float)) and now_ms - last < MIN_GAP_SECONDS * 1000:
            outcome["why"] = "another motor command was sent seconds ago"
            return meta
        prev = (meta.get("lastByMotor") or {}).get(motor)
        if isinstance(prev, (int, float)) and now_ms - prev < MOTOR_COOLDOWN_SECONDS * 1000:
            wait = int(MOTOR_COOLDOWN_SECONDS - (now_ms - prev) / 1000) + 1
            outcome["why"] = f"this motor changed moments ago; wait {wait}s"
            return meta
        day = farm_day(now_ms / 1000)
        if int(((meta.get("daily") or {}).get(day) or {}).get(motor) or 0) >= DAILY_CAP:
            outcome["why"] = f"{DAILY_CAP} changes today already; the limit protects the motor"
            return meta
        claimed = dict(sorted(claimed.items(), key=lambda kv: kv[1])[-50:])
        claimed[cmd_id] = now_ms
        meta["claimed"] = claimed
        meta["lastSent"] = now_ms
        meta["lock"] = {"cmd": cmd_id, "motor": motor, "until": int(now_ms + LOCK_SECONDS * 1000)}
        outcome["claimed"] = "yes"
        return meta
    return txn


def claim(store, root: str, cmd_id: str, motor: str, now_s: float) -> None:
    outcome: dict[str, str] = {}
    store.reference(f"{root}/{META}").transaction(claim_txn(cmd_id, motor, now_s * 1000, outcome))
    why = outcome.get("why")
    if why == "duplicate":
        raise _Duplicate()
    if why or outcome.get("claimed") != "yes":
        raise Refused(why or "could not claim the command")


def record_sent(store, root: str, motor: str, now_s: float) -> None:
    """Spend the cooldown and today's count: a command went out."""
    day = farm_day(now_s)

    def txn(meta):
        meta = dict(meta or {})
        by_motor = dict(meta.get("lastByMotor") or {})
        by_motor[motor] = now_s * 1000
        meta["lastByMotor"] = by_motor
        today = dict((meta.get("daily") or {}).get(day) or {})
        today[motor] = int(today.get(motor) or 0) + 1
        meta["daily"] = {day: today}            # only today is kept
        return meta
    store.reference(f"{root}/{META}").transaction(txn)


def release(store, root: str, cmd_id: str) -> None:
    """Drop the lock only if it is this command's."""
    def txn(meta):
        meta = dict(meta or {})
        lock = meta.get("lock")
        if isinstance(lock, dict) and lock.get("cmd") == cmd_id:
            meta.pop("lock", None)
        return meta
    store.reference(f"{root}/{META}").transaction(txn)


def _scrub(text: str) -> str:
    return re.sub(r"\S+@\S+", "…", re.sub(r"\d{9,}", "…", str(text)))[:200]


# ---- the two vendors: read one motor, send one command -------------------------

class LiveskyMotor:
    """The river motor. Reads use water.LiveskyClient; the one write is here."""

    vendor = "livesky"

    def __init__(self, base: str, session: dict, http=None):
        token = session.get("token") if isinstance(session, dict) else None
        if not token:
            raise Refused("SNOF is not signed in to Livesky")
        exp = session.get("exp") or water.jwt_expiry(token)
        if exp and exp <= time.time():
            raise Refused("the Livesky session has expired: an admin signs in again")
        self._imei = str(session.get("imei") or "")
        if not re.fullmatch(r"\d{10,20}", self._imei):
            raise Refused("the river motor is not known yet: let one water pull run first")
        self._name = str(session.get("device") or "River motor")
        self._client = water.LiveskyClient(base, token)
        self._base, self._token, self._http = base.rstrip("/"), token, http

    def quick(self) -> None:
        """Confirmation reads: a shorter timeout, to fit the function's budget."""
        self._client.timeout = CONFIRM_READ_TIMEOUT

    def read(self) -> dict:
        rows = self._client.motors(self._imei)
        return water.parse_livesky_motor(rows[0], self._name) if rows else {}

    def send(self, action: str) -> str:
        requests = self._http or water._http()
        keyword = f"{self._imei}@motor1@page1@{LIVESKY_KEYWORD[action]}"
        r = requests.get(f"{self._base}/applychange", params={"imei": self._imei, "keyword": keyword},
                         headers={"Authorization": f"Bearer {self._token}"}, timeout=water.TIMEOUT)
        if r.status_code == 401:
            raise Refused("Livesky refused the session: an admin signs in again")
        if r.status_code != 200:
            raise Refused(f"Livesky answered HTTP {r.status_code}")
        return "sent to the starter"


class NiagaraMotor:
    """One of the other farm's motors, found by the same slug the water pull
    gives it. The controller id is looked up each time and never stored."""

    vendor = "niagara"

    def __init__(self, base: str, user_id: str, motor: str, http=None):
        if not base or not user_id:
            raise Refused("Niagara is not configured")
        self._client = water.NiagaraClient(base, user_id)
        self._base, self._user, self._motor, self._http = base.rstrip("/"), user_id.strip(), motor, http
        self._id: int | None = None

    def _find(self) -> tuple[int, dict]:
        seen: set[str] = set()
        for g in self._client.groups():
            gname = str(g.get("groupName") or "")
            for c in self._client.controllers(g.get("userGroupId")):
                parsed = water.parse_niagara_controller(c, gname)
                if not parsed:
                    continue
                key = parsed[0]
                while key in seen:
                    key += "-2"
                seen.add(key)
                if key == self._motor:
                    cid = c.get("userDeviceId")
                    if not isinstance(cid, int) and not str(cid).isdigit():
                        raise Refused("the controller has no id")
                    return int(cid), parsed[1]
        raise Refused("no such motor at the other farm")

    def quick(self) -> None:
        self._client.timeout = CONFIRM_READ_TIMEOUT

    def read(self) -> dict:
        cid, state = self._find()
        if self._id is not None and cid != self._id:
            raise Refused("the motor's controller changed mid-command")
        self._id = cid
        return state

    def send(self, action: str) -> str:
        if self._id is None:
            raise Refused("the motor was not read before sending")
        requests = self._http or water._http()
        r = requests.put(f"{self._base}/user/{self._user}/subuser/0/controller/{self._id}/manualstatus",
                         json=NIAGARA_BODY[action], headers={"deviceType": "web"}, timeout=water.TIMEOUT)
        try:
            body = r.json()
        except ValueError:
            body = {}
        if r.status_code != 200 or not isinstance(body, dict) or body.get("code") != 200:
            raise Refused(f"Niagara did not take the command (HTTP {r.status_code})")
        return "sent to the controller"


# ---- one command ---------------------------------------------------------------

def handle(store, root: str, cmd_id: str, cmd: Any, *, motor_factory,
           now=time.time, sleep=time.sleep) -> dict | None:
    """Run one command end to end and write its result. `motor_factory(motor)`
    builds a LiveskyMotor or NiagaraMotor. Returns the result, or None for a
    redelivered trigger (which touches nothing)."""
    queue_ref = store.reference(f"{root}/{QUEUE}/{cmd_id}")
    result_ref = store.reference(f"{root}/{RESULTS}/{cmd_id}")
    # A redelivered trigger: the command already has a result, or its node is
    # gone (every handled command's node is deleted). Before anything else,
    # so a refused command can never run on a second delivery.
    if result_ref.get() is not None or queue_ref.get() is None:
        return None
    result: dict[str, Any] = {"ok": False, "verified": False, "confirming": False}
    if isinstance(cmd, dict):
        result.update(motor=str(cmd.get("motor") or "")[:40], action=str(cmd.get("action") or "")[:4],
                      uid=str(cmd.get("uid") or "")[:128])
    claimed = sent_attempted = verified = False
    try:
        try:
            motor, action = validate(cmd, now())
            claim(store, root, cmd_id, motor, now())
            claimed = True
            m = motor_factory(motor)
            before = m.read()
            check_before(action, before, now())
            # Disarming during a slow read stops it here, before the send.
            if not armed(store.reference(f"{root}/{META}").get(), motor):
                raise Refused("motor control was switched off")
            sent_attempted = True
            message = m.send(action)
            record_sent(store, root, motor, now())
            _count(store, root, "sent")
            result.update(ok=True, confirming=True, message=message)
            result_ref.set({**result, "at": SERVER_TIMESTAMP})
            verified, last = _confirm(m, action, now, sleep)
            result["message"] = ("confirmed by the motor" if verified
                                 else "sent, but the motor has not confirmed it — check before trying again")
            if last:
                _mirror(store, root, motor, last)
        except _Duplicate:
            return None
        except Refused as why:
            result["message"] = (str(why) if not sent_attempted
                                 else f"may have been sent ({why}) — check the motor before trying again")
            _count(store, root, "failed" if sent_attempted else "refused")
        except water.VendorError as err:
            result["message"] = (f"could not reach the motor ({_scrub(str(err))})" if not sent_attempted
                                 else "may have been sent; the answer was lost — check the motor before trying again")
            _count(store, root, "failed")
        except Exception as err:          # noqa: BLE001 — reported, never raised
            result["message"] = (f"could not reach the motor ({type(err).__name__})" if not sent_attempted
                                 else "may have been sent; the answer was lost — check the motor before trying again")
            _count(store, root, "failed")
        result.update(confirming=False, verified=verified)
        result_ref.set({**result, "at": SERVER_TIMESTAMP})
        return result
    finally:
        # The lock goes when confirmed, or when nothing was sent. After an
        # unconfirmed (or uncertain) send it is left to expire.
        if claimed and (verified or not sent_attempted):
            try:
                release(store, root, cmd_id)
            except Exception:             # noqa: BLE001 — it expires by itself
                pass
        # The node always goes, sent or refused, so nothing can loop or be
        # picked up again later.
        queue_ref.delete()


def _confirm(m, action: str, now, sleep) -> tuple[bool, dict]:
    """Read the motor every 10 s until its own report shows the change, for
    at most 150 s (the captures settled in 20-40 s). A failed or odd read is
    just another try. Never resends."""
    deadline = now() + VERIFY_WINDOW_SECONDS
    last: dict = {}
    if hasattr(m, "quick"):
        m.quick()
    while True:
        sleep(VERIFY_EVERY_SECONDS)
        if now() > deadline:
            return False, last
        try:
            last = m.read() or last
        except Exception:                 # noqa: BLE001 — incl. Refused: one read is not a verdict
            continue
        if confirmed(action, last):
            return True, last


def _mirror(store, root: str, motor: str, state: dict) -> None:
    """Put the motor's confirmed state where the apps read it, at once. The
    whole node, so fields the motor no longer reports do not linger."""
    try:
        path = "water/river" if motor == RIVER else f"water/motors/{motor}"
        store.reference(f"{root}/{path}").set(state)
    except Exception:                     # noqa: BLE001 — the next pull writes it anyway
        pass


def _count(store, root: str, key: str) -> None:
    try:
        store.reference(f"{root}/{META}/{key}").transaction(lambda n: (n or 0) + 1)
    except Exception:                     # noqa: BLE001 — counters are best-effort
        pass
