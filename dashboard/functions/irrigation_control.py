"""Irrigation control from a Cloud Function: the one path from the app to the
Mobitech DCON controller's command endpoint.

Moved here from the NUC (addon/snof_bridge/bridge/irrigation_control.py) on
the owner's rule that the NUC runs the Home Assistant bridge and nothing else.
Every check the add-on made is made here, spelled the same way:

    run   "FON 012,015,000,000,000-00 20-00,00,…!0--@A8"
          Manual Mode on up to five valves for HH MM. The controller stops it
          by itself when the time is up.
    stop  "OFF@A8"
          Ends Manual Mode.

    app ──append──▶ /farms/<farm>/irrigation_commands/<id>   {action, valves, minutes, uid, at}
    fn  ◀─onCreate─┘  validate, claim, read the controller, send, record
    fn  ──result───▶ /farms/<farm>/irrigation_command_results/<id>   {ok, message, …}

What a function cannot keep in memory, the database keeps:
  * **Once only.** Triggers are at-least-once. Before anything is sent the
    command is *claimed* with a transaction on its result node; a redelivered
    trigger finds the claim and does nothing. max_instances=1 serialises the
    rest.
  * **One command per 10 s,** from meta/irrigationControl/lastSent, taken in
    the same transaction as the claim.
  * **Hands off while switched off.** Until meta/irrigationControl/enabled is
    true (service account only; clients cannot write meta) this function does
    not touch the queue at all — no delete, no result — so the NUC can keep
    consuming it until the cut-over. Turn the NUC's allow_irrigation_control
    off *before* turning this on, or a command would be sent twice.

The pure pieces (validate, the two command templates, the valve and controller
checks) are copied from the add-on verbatim and tested the same way.
"""
from __future__ import annotations

import json
import re
import time
from typing import Any

import dcon

QUEUE = "irrigation_commands"
RESULTS = "irrigation_command_results"
META = "meta/irrigationControl"

MAX_AGE_SECONDS = 60.0
MIN_GAP_SECONDS = 10.0
MAX_VALVES = 5
REQUEST_TIMEOUT_SECONDS = 30

_SLOT = re.compile(r"^A[0-9A-Z]$")
_VALVES = re.compile(r"^[0-9]{1,2}(,[0-9]{1,2}){0,4}$")
_FON_TAIL = "00,00,00,00,00-0000,0000,0000,0000,0000-00-00-0-0-0000-0000!0--"
SERVER_TIMESTAMP = {".sv": "timestamp"}


class Refused(Exception):
    """A command that will not be sent, with the reason in plain words."""


# ---- pure: copied from the add-on, unchanged -----------------------------------

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
    return {"running": running, "manual": running and str(cur.get("timer_type")) == "3",
            "name": str(cur.get("timer_name") or "")}


def check_against(action: str, valves: list[int], state: dict, allowed: dict[int, str]) -> None:
    """The checks only the controller's own answers can make."""
    if action == "run":
        bad = [v for v in valves if v not in allowed]
        if bad:
            raise Refused(f"not an irrigation valve: {', '.join(map(str, bad))}")
        if state["running"]:
            raise Refused(f"{state['name'] or 'a program'} is running — stop it first")
    elif not state["manual"]:
        raise Refused("no manual run to stop" if not state["running"]
                      else f"{state['name']} is a scheduled program; only manual runs can be stopped from the app")


def _scrub(text: str) -> str:
    return re.sub(r"\d{10,}", "…", text)[:200]


# ---- the command endpoint -------------------------------------------------------

class Commander:
    """The controller's write endpoint, and only the two templated commands.
    Kept out of dcon.py on purpose: the report path has no way to write."""

    def __init__(self, base: str, device_id: str, command_auth: str, session=None):
        if not (device_id and command_auth):
            raise Refused("irrigation control is not configured")
        import requests

        self._url = base.rstrip("/") + "/v1/command/"
        self._device, self._auth = device_id, command_auth
        self._http = session or requests.Session()

    def send(self, command: str) -> tuple[int, str]:
        resp = self._http.post(self._url, json={"device_id": self._device, "command": command},
                               headers={"authorization": self._auth, "accept": "*/*"},
                               timeout=REQUEST_TIMEOUT_SECONDS)
        return resp.status_code, resp.text


# ---- one command ----------------------------------------------------------------

def claim(store, root: str, cmd_id: str, now_ms: float) -> None:
    """Take the command, or refuse it. One transaction on meta/irrigationControl
    holds both the once-only ledger and the 10 s gap, so two deliveries of one
    trigger, or two commands seconds apart, cannot both get through."""
    outcome: dict[str, str] = {}

    def txn(meta):
        meta = dict(meta or {})
        claimed = dict(meta.get("claimed") or {})
        if cmd_id in claimed:
            outcome["why"] = "duplicate"
            return meta
        last = meta.get("lastSent") or 0
        if isinstance(last, (int, float)) and now_ms - last < MIN_GAP_SECONDS * 1000:
            outcome["why"] = "gap"
            return meta
        # Keep the ledger short: commands are deleted within seconds, so only
        # the last few ids can ever be redelivered.
        claimed = dict(sorted(claimed.items(), key=lambda kv: kv[1])[-20:])
        claimed[cmd_id] = now_ms
        meta["claimed"] = claimed
        meta["lastSent"] = now_ms
        return meta

    store.reference(f"{root}/{META}").transaction(txn)
    if outcome.get("why") == "duplicate":
        raise _Duplicate()
    if outcome.get("why") == "gap":
        raise Refused("another command was sent seconds ago")


class _Duplicate(Exception):
    """A redelivered trigger for a command already handled: do nothing."""


def handle(store, root: str, cmd_id: str, cmd: Any, *, reads, commander_factory,
           slot: str, max_minutes: int, now=time.time) -> dict | None:
    """Run one command end to end. Returns the result written, or None when the
    function is switched off (and the queue must be left alone for the NUC).
    `reads` is a dcon.Dcon; `commander_factory()` builds a Commander."""
    meta = store.reference(f"{root}/{META}").get() or {}
    if meta.get("enabled") is not True:
        return None

    result: dict[str, Any] = {"ok": False, "runtime": "cloud-functions",
                              "action": cmd.get("action") if isinstance(cmd, dict) else None}
    try:
        try:
            action, valves, minutes = validate(cmd, max_minutes, now())
            if not _SLOT.match(slot or ""):
                raise Refused("irrigation control is not configured")
            claim(store, root, cmd_id, now() * 1000)
            allowed = irrigation_valves(reads.nodes()) if action == "run" else {}
            state = controller_state(reads.dashboard())
            check_against(action, valves, state, allowed)
            command = run_command(valves, minutes, slot) if action == "run" else stop_command(slot)
            status, text = commander_factory().send(command)
            ok = status < 400
            try:
                message = str(json.loads(text).get("message") or "")
            except (ValueError, AttributeError):
                message = text
            result.update(ok=ok, status=status, message=_scrub(message or f"HTTP {status}"),
                          valves=", ".join(allowed.get(v, f"valve {v}") for v in valves), minutes=minutes)
            _count(store, root, "sent" if ok else "failed")
        except _Duplicate:
            return None
        except Refused as why:
            result["message"] = str(why)
            _count(store, root, "refused")
        except dcon.DconError as err:
            result["message"] = f"could not read the controller ({_scrub(str(err))})"
            _count(store, root, "failed")
        except Exception as err:          # noqa: BLE001 — reported, not raised
            result["message"] = f"could not reach the controller ({type(err).__name__})"
            _count(store, root, "failed")
        store.reference(f"{root}/{RESULTS}/{cmd_id}").set({**result, "at": SERVER_TIMESTAMP})
        return result
    finally:
        # Switched on, the node always goes — ran, refused or failed — so a
        # bad one cannot loop. (Switched off we returned above, untouched.)
        store.reference(f"{root}/{QUEUE}/{cmd_id}").delete()


def _count(store, root: str, key: str) -> None:
    try:
        store.reference(f"{root}/{META}/{key}").transaction(lambda n: (n or 0) + 1)
    except Exception:                     # noqa: BLE001 — counters are best-effort
        pass
