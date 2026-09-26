"""Irrigation control: the one path from the app to the Mobitech DCON controller.

Two commands exist, both spelled exactly as Mobitech's own app spells them
(read back from the controller's command history, 2026-09-11 → 09-24, and
matched against the timer log it produced):

    run   "FON 012,015,000,000,000-00 20-00,00,…!0--@A8"
          Manual Mode on up to five valves for HH MM. The controller stops
          it by itself when the time is up (19 Sep: completed=1, no OFF).
    stop  "OFF@A8"
          Ends Manual Mode. The log records it as end_control "A8".

`@A8` is the Mobitech user slot the command is sent as (sibhi = A8). A `U`
slot means "pause" to Mobitech's portal, and the app uses it to stop a timer
program — which is why stopping a *program* is not offered here yet.

    app ──append──▶ /farms/<farm>/irrigation_commands/<id>  {action, valves, minutes, uid, at}
    NUC ◀─stream──┘  validate, read the controller, send, record
    NUC ──result──▶ /farms/<farm>/irrigation_command_results/<id>  {ok, message, …}

Every check the database rules make is made again here, plus the ones only
the farm can make:
  * off unless `allow_irrigation_control` is true, and then only with the
    command credential, device id and user slot all set
  * two actions, from a fixed template each; nothing from the app is ever
    passed through as text
  * valves must be *Irrigation* valves on this controller (get_node) — never
    the tank, booster pump or backwash valve — at most five, no repeats
  * minutes are 1..`irrigation_max_minutes`; the controller ends the run itself
  * the controller is read first: `run` is refused while anything is
    running, `stop` is refused unless a Manual Mode run is
  * commands older than 60 s are dropped, one command per 10 s at most, and
    every node is deleted whether it ran or not
  * **no second change until the first is confirmed** (owner, 2026-09-24:
    Mobitech accepts anything and its server cannot handle conflicts). A lock
    at /farms/<farm>/irrigation_lock is taken before sending and held while
    the controller is re-read every 10 s for up to 2 min, until its own state
    shows the run started or stopped. The RTDB rules refuse new commands
    while the lock is live, and so does this code. The result records
    `verified`.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from typing import TYPE_CHECKING, Any

from .relay import TOKEN_PATH, form_for, pick_token

if TYPE_CHECKING:
    import aiohttp

_LOGGER = logging.getLogger(__name__)

# The Mobitech session token (TOKEN_PATH, pick_token) lives in relay.py: the
# reads and the commands must use the same session, since Mobitech keeps one
# per account. The add-on option dcon_command_auth is only the fallback.
STATUS = "mobitech_status"

QUEUE = "irrigation_commands"
RESULTS = "irrigation_command_results"
LOCK = "irrigation_lock"

MAX_AGE_SECONDS = 60.0
MIN_GAP_SECONDS = 10.0
MAX_VALVES = 5
NODES_TTL_SECONDS = 600.0
REQUEST_TIMEOUT_SECONDS = 30
STREAM_RETRY_SECONDS = 5.0
SEEN_LIMIT = 512
# Confirmation: gentle on Mobitech's server — at most VERIFY_WINDOW /
# VERIFY_EVERY reads of the dashboard per change.
VERIFY_EVERY_SECONDS = 10.0
VERIFY_WINDOW_SECONDS = 120.0
# The lock outlives the confirmation window, so a crash mid-way cannot leave
# the rules refusing commands forever: it simply expires.
LOCK_SECONDS = 180.0

_SLOT = re.compile(r"^A[0-9A-Z]$")
_VALVES = re.compile(r"^[0-9]{1,2}(,[0-9]{1,2}){0,4}$")

# The tail of a manual-mode command: fertigation, EC/pH and flow fields,
# all unused on this farm and sent as zeros, exactly as the Mobitech app does.
_FON_TAIL = "00,00,00,00,00-0000,0000,0000,0000,0000-00-00-0-0-0000-0000!0--"


class Refused(Exception):
    """A command that will not be sent, with the reason in plain words."""


def run_command(valves: list[int], minutes: int, slot: str) -> str:
    """ "FON 012,015,000,000,000-00 20-<tail>@A8"."""
    if not 1 <= len(valves) <= MAX_VALVES or len(set(valves)) != len(valves):
        raise Refused("one to five different valves")
    if not all(1 <= v <= 99 for v in valves):
        raise Refused("valve out of range")
    if not 1 <= minutes <= 180:
        raise Refused("minutes out of range")
    if not _SLOT.match(slot):
        raise Refused("bad user slot")
    slots = ",".join(f"{v:03d}" for v in (valves + [0] * MAX_VALVES)[:MAX_VALVES])
    return f"FON {slots}-{minutes // 60:02d} {minutes % 60:02d}-{_FON_TAIL}@{slot}"


def stop_command(slot: str) -> str:
    if not _SLOT.match(slot):
        raise Refused("bad user slot")
    return f"OFF@{slot}"


def validate(cmd: Any, max_minutes: int, now: float | None = None) -> tuple[str, list[int], int]:
    """(action, valves, minutes) for a command worth considering, else Refused."""
    if not isinstance(cmd, dict):
        raise Refused("not an object")
    action = cmd.get("action")
    if action not in ("run", "stop"):
        raise Refused("unknown action")
    at = cmd.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        raise Refused("no timestamp")
    age = (time.time() if now is None else now) - at / 1000.0
    if age > MAX_AGE_SECONDS or age < -60:
        raise Refused(f"stale by {age:.0f}s")
    extra = set(cmd) - {"action", "valves", "minutes", "uid", "at"}
    if extra:
        raise Refused(f"unexpected fields {sorted(extra)}")
    if action == "stop":
        return "stop", [], 0
    raw = cmd.get("valves")
    if not isinstance(raw, str) or not _VALVES.match(raw):
        raise Refused("valves must be like 12,15")
    valves = [int(v) for v in raw.split(",")]
    if len(set(valves)) != len(valves):
        raise Refused("a valve is listed twice")
    minutes = cmd.get("minutes")
    if not isinstance(minutes, int) or isinstance(minutes, bool) or not 1 <= minutes <= max_minutes:
        raise Refused(f"minutes must be 1–{max_minutes}")
    return "run", valves, minutes


def irrigation_valves(nodes: Any) -> dict[int, str]:
    """get_node -> {valve number: name} for Irrigation valves only."""
    out: dict[int, str] = {}
    if not isinstance(nodes, dict):
        return out
    for key, group in nodes.items():
        if not isinstance(group, dict) or not str(key).lower().startswith("node"):
            continue
        entries = group.get("valve")
        if not isinstance(entries, dict):
            continue
        for number, valve in entries.items():
            if not isinstance(valve, dict) or not str(number).isdigit():
                continue
            if str(valve.get("valve_type") or "").strip().lower() == "irrigation":
                out[int(number)] = str(valve.get("valve_name") or f"Valve {number}")
    return out


def controller_state(dashboard: Any) -> dict:
    """The dashboard's current timer: is anything running, and is it manual."""
    node = dashboard if isinstance(dashboard, dict) else {}
    if len(node) == 1 and isinstance(next(iter(node.values())), dict):
        node = next(iter(node.values()))
    timers = node.get("timers") if isinstance(node.get("timers"), dict) else {}
    cur = timers.get("current") if isinstance(timers.get("current"), dict) else None
    if not cur:
        return {"running": False, "manual": False, "name": ""}
    running = str(cur.get("completed")) != "1"
    valves = [int(v) for v in re.split(r"[-,]", str(cur.get("on_valves") or "")) if v.strip().isdigit() and int(v)]
    return {"running": running, "manual": running and str(cur.get("timer_type")) == "3",
            "name": str(cur.get("timer_name") or ""), "valves": valves}


def confirmed(action: str, valves: list[int], state: dict) -> bool:
    """Does the controller's own state show the change took? A run: a manual
    run is going on exactly these valves. A stop: no manual run is going."""
    if action == "run":
        return bool(state.get("manual")) and set(valves) <= set(state.get("valves") or [])
    return not state.get("manual")


def lock_live(lock: Any, now_ms: float) -> bool:
    return isinstance(lock, dict) and isinstance(lock.get("until"), (int, float)) and lock["until"] > now_ms


def check_against(action: str, valves: list[int], state: dict, allowed: dict[int, str]) -> None:
    """The checks only the controller's own answers can make."""
    if action == "run":
        bad = [v for v in valves if v not in allowed]
        if bad:
            raise Refused(f"not an irrigation valve: {', '.join(map(str, bad))}")
        # A scheduled program (a cycle timer such as Coconut) does not block a
        # manual run: the owner runs valves by hand while a cycle is going
        # (2026-09-24). Only another manual run does — two manual commands
        # would collide.
        if state["manual"]:
            raise Refused("a manual run is already going — stop it first")
    elif not state["manual"]:
        raise Refused("no manual run to stop" if not state["running"]
                      else f"{state['name']} is a scheduled program; only manual runs can be stopped from the app")


def _scrub(text: str) -> str:
    return re.sub(r"\d{10,}", "…", text)[:200]


class IrrigationControl:
    def __init__(self, cfg, rtdb, session: aiohttp.ClientSession) -> None:
        self._cfg = cfg
        self._rtdb = rtdb
        self._session = session
        self._seen: list[str] = []
        self._nodes: tuple[float, dict[int, str]] = (0.0, {})
        self._last_sent = 0.0
        self.sent = 0
        self.refused = 0

    @property
    def enabled(self) -> bool:
        c = self._cfg
        # No command token needed to switch on: signing in to Mobitech from the
        # app supplies one (private/mobitech); a command refuses without it.
        return bool(c.allow_irrigation_control and c.dcon_serial and c.dcon_token_id
                    and c.dcon_device_id and _SLOT.match(c.dcon_user_slot or ""))

    def status(self) -> dict:
        return {"enabled": self.enabled, "sent": self.sent, "refused": self.refused,
                "maxMinutes": self._cfg.irrigation_max_minutes}

    # ---- the controller ------------------------------------------------------

    async def _read(self, call: str) -> Any:
        import aiohttp
        c = self._cfg
        # The dashboard checks the token (token_id) exactly as commands do, so
        # it reads with the same session: SNOF's own when signed in.
        token = pick_token(await self._signed_in(), c.dcon_token_id)
        fields = form_for(call, {}, c.dcon_serial, token, c.dcon_product or "DCON")
        async with self._session.post(f"{c.dcon_base}/v1/http/", data=fields,
                                      timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)) as resp:
            if resp.status >= 400:
                raise Refused(f"controller read failed (HTTP {resp.status})")
            return json.loads(await resp.text())

    async def _allowed_valves(self) -> dict[int, str]:
        fetched, valves = self._nodes
        if not valves or time.monotonic() - fetched > NODES_TTL_SECONDS:
            valves = irrigation_valves(await self._read("nodes"))
            self._nodes = (time.monotonic(), valves)
        return valves

    async def _signed_in(self) -> Any:
        try:
            return await self._rtdb.get(TOKEN_PATH)
        except Exception:
            return None

    async def _command_token(self) -> str:
        return pick_token(await self._signed_in(), self._cfg.dcon_command_auth)

    async def _record_session(self, accepted: bool) -> None:
        """lastOk / lastRejected on the status line the apps show, so a
        session Mobitech has dropped reads as that, not as a broken farm."""
        try:
            await self._rtdb.patch(f"{self._cfg.root}/{STATUS}",
                                   {"lastOk" if accepted else "lastRejected": {".sv": "timestamp"}})
        except Exception:
            _LOGGER.debug("Could not record the Mobitech session state", exc_info=True)

    async def _send(self, command: str) -> tuple[int, str]:
        import aiohttp
        c = self._cfg
        token = await self._command_token()
        if not token:
            raise Refused("not signed in to Mobitech — sign in from the app's Account (admins)")
        async with self._session.post(
                f"{c.dcon_base}/v1/command/",
                json={"device_id": c.dcon_device_id, "command": command},
                headers={"authorization": token, "accept": "*/*"},
                timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)) as resp:
            return resp.status, await resp.text()

    # ---- one command ---------------------------------------------------------

    async def handle(self, cmd_id: str, cmd: Any) -> None:
        if cmd is None or cmd_id in self._seen:
            return
        self._seen.append(cmd_id)
        del self._seen[:-SEEN_LIMIT]
        result: dict[str, Any] = {"ok": False, "action": cmd.get("action") if isinstance(cmd, dict) else None}
        locked = False
        lock_path = f"{self._cfg.root}/{LOCK}"
        try:
            action, valves, minutes = validate(cmd, self._cfg.irrigation_max_minutes)
            if time.monotonic() - self._last_sent < MIN_GAP_SECONDS:
                raise Refused("another command was sent seconds ago")
            if lock_live(await self._rtdb.get(lock_path), time.time() * 1000):
                raise Refused("the last valve change is still being confirmed")
            allowed = await self._allowed_valves() if action == "run" else {}
            state = controller_state(await self._read("dashboard"))
            check_against(action, valves, state, allowed)
            slot = self._cfg.dcon_user_slot
            command = run_command(valves, minutes, slot) if action == "run" else stop_command(slot)
            self._last_sent = time.monotonic()
            await self._rtdb.put(lock_path, {"cmd": cmd_id, "action": action,
                                             "until": int((time.time() + LOCK_SECONDS) * 1000)})
            locked = True
            status, text = await self._send(command)
            ok = status < 400
            try:
                message = str(json.loads(text).get("message") or "")
            except (ValueError, AttributeError):
                message = text
            # Mobitech answers a dead app session token with a bare "Bad
            # request" — identical to a fake one (proven 2026-09-24). Say so.
            if status < 400:
                await self._record_session(True)
            elif status == 400 and message.strip().lower() == "bad request":
                await self._record_session(False)
            if status == 400 and message.strip().lower() == "bad request":
                message = "the Mobitech session has expired — an admin signs in to Mobitech again (Admin on the web, Account in the app)"
            result.update(ok=ok, status=status, message=_scrub(message or f"HTTP {status}"),
                          valves=", ".join(allowed.get(v, f"valve {v}") for v in valves), minutes=minutes)
            if ok:
                self.sent += 1
                _LOGGER.info("Sent irrigation %s %s%s -> %s %s", action,
                             result["valves"], f" for {minutes} min" if minutes else "", status, result["message"])
                # Sent is not done. Tell the app we are confirming, then read
                # the controller until its state shows the change.
                result.update(verified=False, confirming=True)
                await self._rtdb.put(f"{self._cfg.root}/{RESULTS}/{cmd_id}", {**result, "at": {".sv": "timestamp"}})
                result["verified"] = await self._confirm(action, valves)
                result["confirming"] = False
                _LOGGER.info("Irrigation %s %s", action, "confirmed by the controller" if result["verified"]
                             else f"NOT confirmed within {VERIFY_WINDOW_SECONDS:.0f} s")
            else:
                _LOGGER.warning("Irrigation %s answered HTTP %s: %s", action, status, result["message"])
        except Refused as why:
            self.refused += 1
            result["message"] = str(why)
            _LOGGER.warning("Refused irrigation command %s: %s", cmd_id, why)
        except Exception as err:
            result["message"] = f"could not reach the controller ({type(err).__name__})"
            _LOGGER.exception("Irrigation command %s failed", cmd_id)
        finally:
            try:
                await self._rtdb.put(f"{self._cfg.root}/{RESULTS}/{cmd_id}",
                                     {**result, "at": {".sv": "timestamp"}})
            except Exception:
                _LOGGER.exception("Could not record irrigation result %s", cmd_id)
            if locked:
                try:
                    await self._rtdb.put(lock_path, None)
                except Exception:
                    _LOGGER.exception("Could not release the irrigation lock (it expires by itself)")
            try:
                await self._rtdb.put(f"{self._cfg.root}/{QUEUE}/{cmd_id}", None)
            except Exception:
                _LOGGER.exception("Could not clear irrigation command %s", cmd_id)

    async def _confirm(self, action: str, valves: list[int]) -> bool:
        deadline = time.monotonic() + VERIFY_WINDOW_SECONDS
        while time.monotonic() < deadline:
            await asyncio.sleep(VERIFY_EVERY_SECONDS)
            try:
                if confirmed(action, valves, controller_state(await self._read("dashboard"))):
                    return True
            except Exception:
                _LOGGER.debug("Confirmation read failed; retrying", exc_info=True)
        return False

    # ---- stream --------------------------------------------------------------

    async def _dispatch(self, path: str, data: Any) -> None:
        path = (path or "/").strip("/")
        if not path:
            for cmd_id, cmd in (data or {}).items():
                await self.handle(cmd_id, cmd)
        elif "/" not in path:
            await self.handle(path, data)

    async def _purge(self) -> None:
        path = f"{self._cfg.root}/{QUEUE}"
        try:
            if await self._rtdb.get(path, shallow=True):
                await self._rtdb.put(path, None)
                _LOGGER.info("Irrigation control is off: dropped queued irrigation commands")
        except Exception:
            _LOGGER.debug("Could not purge the irrigation queue", exc_info=True)

    async def run(self) -> None:
        if not self.enabled:
            _LOGGER.info("Irrigation control is off; not watching the irrigation queue")
            await self._purge()
            return
        _LOGGER.info("Watching irrigation commands (run up to %d min, stop manual runs) as %s",
                     self._cfg.irrigation_max_minutes, self._cfg.dcon_user_slot)
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Irrigation stream error: %s", err or type(err).__name__)
            await asyncio.sleep(STREAM_RETRY_SECONDS)

    async def _stream_once(self) -> None:
        import aiohttp
        url = f"{self._cfg.firebase_db_url}/{self._cfg.root}/{QUEUE}.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=None)
        async with self._session.get(url, headers=headers, timeout=timeout, allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"irrigation stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Irrigation command stream open")
            event = ""
            async for raw in resp.content:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    payload = line[5:].strip()
                    if event in ("put", "patch") and payload and payload != "null":
                        try:
                            body = json.loads(payload)
                        except ValueError:
                            continue
                        await self._dispatch(body.get("path"), body.get("data"))
                    elif event == "auth_revoked":
                        return
