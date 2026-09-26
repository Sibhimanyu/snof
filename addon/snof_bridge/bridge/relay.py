"""DCON relay: fetch raw Mobitech data for the report Cloud Function.

Irrigation reports are built in a Cloud Function (dashboard/functions), but
Mobitech's server answers every Google Cloud address with HTTP 403 — tested
from asia-southeast1 and asia-south1 on 2026-09-24. The farm's own connection
is accepted, so the NUC does the fetching and nothing else:

    Function ──job──▶ /relay/jobs/<id>      {call, args, at}
    NUC      ◀─stream─┘  validate, fetch, compress
    NUC      ──result─▶ /relay/results/<id> {ok, status, gz, error}
    Function ◀─reads, parses, builds the report, deletes the result

Everything that makes a report — parsing, joining, charts — stays in the
Function. This module knows eight read calls by name and how to spell each
one; it never sees a report type.

Safety, in the same spirit as commands.py:
  * off unless `dcon_relay` is true in the add-on options
  * a job names a call from a fixed allow-list; there is no way to pass a URL,
    a path, an action or a method, and the only endpoint is /v1/http/ — the
    vendor's write endpoint is not reachable from here
  * arguments are strict dates or timestamps; anything else is refused
  * the serial and token are the add-on's own, never taken from a job
  * jobs older than JOB_MAX_AGE_SECONDS are dropped, and every job is deleted
    whether it ran or not
  * /relay is outside /farms, so the RTDB rules' default deny keeps it
    unreadable and unwritable by every client; only service accounts touch it
  * the dashboard call carries the farm's phone book and the modem IMEI;
    those keys are dropped here, before anything leaves the NUC
"""
from __future__ import annotations

import asyncio
import base64
import gzip
import json
import logging
import re
import time
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:          # aiohttp is imported where it is used, so the pure
    import aiohttp         # validation logic stays testable with no deps installed.

_LOGGER = logging.getLogger(__name__)

JOBS = "relay/jobs"
RESULTS = "relay/results"

JOB_MAX_AGE_SECONDS = 60.0
REQUEST_TIMEOUT_SECONDS = 30
STREAM_RETRY_SECONDS = 5.0
SEEN_LIMIT = 512

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_STAMP = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")

# call -> (HTTP method, the argument names it takes, and their shape)
CALLS = {
    "dashboard":      ("POST", {}),
    "nodes":          ("POST", {}),
    "valves":         ("POST", {"from": _DATE, "to": _DATE}),
    "timer_log":      ("POST", {"from": _DATE, "to": _DATE}),
    "motor_log":      ("POST", {"from": _DATE, "to": _DATE}),
    "electricity":    ("GET", {"since": _STAMP}),
    "pressure_now":   ("GET", {"since": _STAMP}),
    "pressure_range": ("GET", {"from": _DATE, "to": _DATE}),
}

# What survives of the dashboard payload. `users` maps names to mobile numbers,
# `sim` is the controller's own number, packets 1/4/8 are SMS recipient lists
# and packet 5 carries the IMEI — none of it leaves the NUC.
_DASHBOARD_KEEP = ("server_time", "time_zone", "timers")


def validate(job: Any, now: float | None = None) -> tuple[str, dict] | None:
    """(call, args) for a job worth running, or None."""
    if not isinstance(job, dict):
        return None
    call = job.get("call")
    if not isinstance(call, str) or call not in CALLS:
        return None
    at = job.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        return None
    age = (time.time() if now is None else now) - at / 1000.0
    if age > JOB_MAX_AGE_SECONDS or age < -60:
        return None
    wanted = CALLS[call][1]
    args = job.get("args") or {}
    if not isinstance(args, dict) or set(args) != set(wanted):
        return None
    for key, shape in wanted.items():
        if not isinstance(args[key], str) or not shape.match(args[key]):
            return None
    return call, dict(args)


def form_for(call: str, args: dict, serial: str, token: str,
             product: str = "DCON") -> dict:
    """The request fields for one call, spelled the way the controller wants.
    The serial and token always come from the add-on options."""
    if call == "dashboard":
        return {"action": "dashboard", "p": "app", "token_id": token, "product": product}
    if call == "nodes":
        return {"action": "dcon_node", "method": "get_node", "serial_no": serial}
    if call == "valves":
        return {"action": "dcon_node", "method": "get_all_valve",
                "from": args["from"], "to": args["to"], "serial_no": serial}
    if call in ("timer_log", "motor_log"):
        return {"action": "logs", "method": call, "serial_no": serial,
                "from": args["from"], "to": args["to"]}
    if call in ("electricity", "pressure_now"):
        return {"action": "reports",
                "type": "electricity" if call == "electricity" else "pressure_cond",
                "serial_no": serial, "dt": args["since"], "product": product}
    if call == "pressure_range":
        return {"action": "reports", "type": "pressure_timer", "serial_no": serial,
                "from": f"{args['from']} 00:00:00", "to": f"{args['to']} 23:59:59",
                "product": product}
    raise ValueError(call)


def trim_dashboard(body: Any) -> Any:
    """Keep only the keys the reports read from the dashboard call."""
    if not isinstance(body, dict):
        return {}
    # A refusal ({"state": "failed", "message": "…signed in on other mobile
    # devices…"}) is passed on as one, not trimmed to {}: an empty dashboard
    # read as an idle controller, and the apps said "not watering" while
    # Mobitech had signed SNOF out (2026-09-26). The message is Mobitech's own
    # text; any run of six or more digits is cut all the same.
    if body.get("state") == "failed" or body.get("status") == "failed":
        why = str(body.get("message") or body.get("reason") or "refused")
        return {"state": "failed", "message": re.sub(r"\d{6,}", "", why)[:200]}
    out = {}
    for serial, node in body.items():
        if not isinstance(node, dict):
            continue
        kept = {k: node[k] for k in _DASHBOARD_KEEP if k in node}
        packets = node.get("packets")
        if isinstance(packets, dict):
            # `live` names the device; `6` is the live electricity reading
            # (phase/line volts, amps, today's supply and pump time). Neither
            # carries a number anyone could call, and any ten-digit run is cut
            # anyway, so a firmware change cannot leak one through here.
            kept_packets = {k: re.sub(r"\d{10,}", "", packets[k])
                            for k in ("live", "6") if isinstance(packets.get(k), str)}
            if kept_packets:
                kept["packets"] = kept_packets
        out[serial] = kept
    return out


def pack(text: str) -> str:
    """gzip + base64: a month of electricity packets is ~11 MB of JSON, over
    RTDB's 10 MB string limit, and compresses about tenfold."""
    return base64.b64encode(gzip.compress(text.encode("utf-8"))).decode("ascii")


class DconRelay:
    def __init__(self, cfg, rtdb, session: aiohttp.ClientSession) -> None:
        self._cfg = cfg
        self._rtdb = rtdb
        self._session = session
        self._seen: list[str] = []
        self.served = 0
        self.refused = 0
        self.last_error = ""

    @property
    def enabled(self) -> bool:
        cfg = self._cfg
        return bool(cfg.dcon_relay and cfg.dcon_serial and cfg.dcon_token_id)

    def status(self) -> dict:
        return {"enabled": self.enabled, "served": self.served,
                "refused": self.refused, "lastError": self.last_error}

    async def _fetch(self, call: str, args: dict) -> tuple[int, str]:
        import aiohttp

        cfg = self._cfg
        method = CALLS[call][0]
        fields = form_for(call, args, cfg.dcon_serial, cfg.dcon_token_id,
                          cfg.dcon_product or "DCON")
        url = f"{cfg.dcon_base}/v1/http/"
        timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        if method == "POST":
            ctx = self._session.post(url, data=fields, timeout=timeout)
        else:
            ctx = self._session.get(url, params=fields, timeout=timeout)
        async with ctx as resp:
            return resp.status, await resp.text()

    async def handle(self, job_id: str, job: Any) -> None:
        if job is None or job_id in self._seen:
            return
        self._seen.append(job_id)
        if len(self._seen) > SEEN_LIMIT:
            del self._seen[: len(self._seen) - SEEN_LIMIT]
        try:
            checked = validate(job)
            if checked is None:
                self.refused += 1
                _LOGGER.warning("Refused relay job %s: %r", job_id, job)
                result = {"ok": False, "status": 0, "error": "refused by the relay"}
            else:
                call, args = checked
                try:
                    status, text = await self._fetch(call, args)
                    if call == "dashboard" and status < 400:
                        try:
                            text = json.dumps(trim_dashboard(json.loads(text)))
                        except ValueError:
                            text = "{}"
                    result = {"ok": status < 400, "status": status, "gz": pack(text),
                              "error": "" if status < 400 else f"HTTP {status}"}
                    self.served += 1
                    self.last_error = result["error"]
                except Exception as err:
                    message = f"{type(err).__name__}"
                    result = {"ok": False, "status": 0, "error": message}
                    self.last_error = message
            await self._rtdb.put(f"{RESULTS}/{job_id}",
                                 {**result, "at": {".sv": "timestamp"}})
        except Exception:
            _LOGGER.exception("Relay job %s failed", job_id)
        finally:
            try:
                await self._rtdb.put(f"{JOBS}/{job_id}", None)
            except Exception:
                _LOGGER.exception("Could not clear relay job %s", job_id)

    async def _dispatch(self, path: str, data: Any) -> None:
        path = (path or "/").strip("/")
        if not path:
            for job_id, job in (data or {}).items():
                await self.handle(job_id, job)
        elif "/" not in path:
            await self.handle(path, data)

    async def run(self) -> None:
        if not self.enabled:
            _LOGGER.info("DCON relay is off; not watching relay jobs")
            return
        _LOGGER.info("Relaying DCON reads for the report function")
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Relay stream error: %s", err or type(err).__name__)
            await asyncio.sleep(STREAM_RETRY_SECONDS)

    async def _stream_once(self) -> None:
        import aiohttp

        url = f"{self._cfg.firebase_db_url}/{JOBS}.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=None)
        async with self._session.get(url, headers=headers, timeout=timeout,
                                     allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"relay stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Relay job stream open")
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
