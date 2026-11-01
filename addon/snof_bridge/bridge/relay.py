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
Function. This module knows eight read calls (and the three sign-in calls below) by name and how to spell each
one; it never sees a report type.

Safety, in the same spirit as commands.py:
  * off unless `dcon_relay` is true in the add-on options
  * a job names a call from a fixed allow-list; there is no way to pass a URL,
    a path, an action or a method, and the only endpoints are /v1/http/ (every
    read, and the two sign-in calls) and /v1/otp/ (the SMS code) — the vendor's
    command endpoint is not reachable from here
  * arguments are strict dates or timestamps; anything else is refused
  * the serial and token are the add-on's own, never taken from a job

    ONE documented, narrow exception (owner's decision, 2026-11-01, so the web
    dashboard can sign SNOF in to Mobitech: a browser cannot, no CORS header,
    and Google Cloud is refused): three SIGNIN_CALLS, `otp`, `login` and
    `prove`. They take a 10-digit mobile, a 4-8 digit code and a device token
    from the job, because that is the whole point of them. The token is one
    the `mobitech_session` Cloud Function has just minted (the owner-only
    path; rules never let a client near /relay), its shape is checked here,
    and it is only ever sent to Mobitech's own sign-in and dashboard calls.
    Their answers are cut down on the NUC (reduce_*) to a few fields; the
    code and the token are never logged and never echoed back.
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

from .wire import STREAM_READ_TIMEOUT_SECONDS

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
_MOBILE = re.compile(r"^\d{10}$")
_CODE = re.compile(r"^\d{4,8}$")
# A device token as the Mobitech app (and SNOF) registers one: an FCM-shaped
# token + "@ios", url-safe characters and ":" only, at least 40 long in all.
_TOKEN = re.compile(r"^[A-Za-z0-9_:\-]{36,400}@ios$")

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
    # Signing in (docs/mobitech-app.md); see the module docstring.
    "otp":            ("POST", {"mobile": _MOBILE}),
    "login":          ("POST", {"mobile": _MOBILE, "code": _CODE, "token": _TOKEN}),
    "prove":          ("POST", {"token": _TOKEN}),
}
SIGNIN_CALLS = frozenset({"otp", "login", "prove"})

# What survives of the dashboard payload. `users` maps names to mobile numbers,
# `sim` is the controller's own number, packets 1/4/8 are SMS recipient lists
# and packet 5 carries the IMEI — none of it leaves the NUC.
_DASHBOARD_KEEP = ("server_time", "time_zone", "timers")


# The Mobitech session an admin signs in with from the app (RTDB, no client
# reads). Mobitech keeps one session per account, so each new sign-in ends
# the one before: the reads must use it too, or a sign-in in the app signs the
# relay out (2026-09-26: "it told me it was signed in, then when I refresh it
# tells me Mobitech logged me out"). The add-on option is only the fallback.
TOKEN_PATH = "private/mobitech/token"


def pick_token(signed_in: Any, fallback: str | None) -> str:
    """The session from signing in to Mobitech wins; the hand-set option is
    the fallback. Only something shaped like the app's token counts."""
    for cand in (signed_in, fallback):
        if isinstance(cand, str) and cand.strip().endswith("@ios") and len(cand.strip()) >= 40:
            return cand.strip()
    return ""


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


_UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"


def _enc(value: str) -> str:
    """Percent-encode as the iOS app does: everything but A-Z a-z 0-9 - . _ ~"""
    return "".join(c if c in _UNRESERVED else "".join(f"%{b:02X}" for b in c.encode())
                   for c in value)


def signin_request(call: str, args: dict) -> tuple[str, str]:
    """(path, body) for a sign-in call, byte for byte what the iOS app sends
    (Mobitech.swift codeRequest / loginRequest / dashboardRequest). The body
    is sent as-is with content-type application/x-www-form-urlencoded."""
    if call == "otp":
        # A JSON object as the whole form body, with the 91 country code.
        return "/v1/otp/", '{"mobile":"91%s"}' % args["mobile"]
    if call == "login":
        fields = [("action", "login"), ("type", "otp"), ("otp", args["code"]),
                  ("mobile", args["mobile"]), ("token", args["token"]),
                  ("product", "DCON"), ("app_id", "com.mobitech.drip")]
        return "/v1/http/?", "&".join(f"{k}={_enc(v)}" for k, v in fields)
    if call == "prove":
        return "/v1/http/", f"action=dashboard&p=app&token_id={_enc(args['token'])}&product=DCON"
    raise ValueError(call)


def _words(value: Any, limit: int) -> str:
    """Mobitech's own text, cut to `limit` with any run of 6+ digits removed."""
    return re.sub(r"\d{6,}", "", str(value or ""))[:limit]


def reduce_signin(call: str, status: int, text: str, token: str = "") -> dict:
    """What leaves the NUC from a sign-in call. Allow-lists only: the login
    answer also carries the mobile number, the mail and a user id, and the
    dashboard answer carries the phone book."""
    try:
        body = json.loads(text)
    except ValueError:
        body = None
    if not isinstance(body, dict):
        body = {}
    if call == "otp":
        return {"message": _words(body.get("message"), 120)}
    if call == "prove":
        return {"serves": status < 400 and any(isinstance(v, dict) for v in body.values())}
    # login
    state = str(body.get("state") or "")[:16]
    out: dict = {"state": state, "idOk": bool(token) and body.get("id", token) == token,
                 "name": _words(body.get("name"), 64), "uname": _words(body.get("uname"), 64)}
    if state != "ok":
        out["message"] = _words(body.get("msg") or body.get("message") or body.get("reason"), 120)
    return out


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
        self._stream_seen: float | None = None   # monotonic, any line incl. keep-alive

    @property
    def enabled(self) -> bool:
        cfg = self._cfg
        return bool(cfg.dcon_relay and cfg.dcon_serial and cfg.dcon_token_id)

    def status(self) -> dict:
        # Seconds since the job stream last said anything (keep-alives count).
        # The report function reads it to tell "the relay is not listening"
        # from "Mobitech is down"; None = never opened since start.
        idle = (None if self._stream_seen is None
                else round(time.monotonic() - self._stream_seen))
        return {"enabled": self.enabled, "served": self.served,
                "refused": self.refused, "lastError": self.last_error,
                "streamIdleSeconds": idle}

    async def _token(self) -> str:
        """The signed-in session if there is one, else the add-on option."""
        try:
            signed_in = await self._rtdb.get(TOKEN_PATH)
        except Exception:          # noqa: BLE001 — the option still works
            signed_in = None
        return pick_token(signed_in, self._cfg.dcon_token_id) or self._cfg.dcon_token_id

    async def _fetch(self, call: str, args: dict) -> tuple[int, str]:
        import aiohttp

        cfg = self._cfg
        if call in SIGNIN_CALLS:
            path, body = signin_request(call, args)
            headers = {"content-type": "application/x-www-form-urlencoded"}
            timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
            async with self._session.post(f"{cfg.dcon_base}{path}", data=body.encode(),
                                          headers=headers, timeout=timeout) as resp:
                text = await resp.text()
                return resp.status, json.dumps(
                    reduce_signin(call, resp.status, text, args.get("token", "")))
        method = CALLS[call][0]
        # Only the dashboard call carries the token; the rest need none.
        token = await self._token() if call == "dashboard" else cfg.dcon_token_id
        fields = form_for(call, args, cfg.dcon_serial, token,
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
                # The call name only: a sign-in job carries a code and a token.
                _LOGGER.warning("Refused relay job %s (call %r)", job_id,
                                job.get("call") if isinstance(job, dict) else None)
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
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30,
                                        sock_read=STREAM_READ_TIMEOUT_SECONDS)
        async with self._session.get(url, headers=headers, timeout=timeout,
                                     allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"relay stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Relay job stream open")
            self._stream_seen = time.monotonic()
            event = ""
            async for raw in resp.content:
                self._stream_seen = time.monotonic()
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
