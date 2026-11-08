"""Developer console: raw Mobitech requests, owner only, reads only.

Third documented exception to "no new DCON code on the NUC" (owner, 2026-11-08;
docs/dev-console.md, docs/dcon-off-the-nuc.md). Moves to Cloud Functions at the
cut-over, like the other two.

    app ──append──▶ /farms/<farm>/dev_requests/<id>  {uid, at, method, path, query, body, bodyType, auth}
    NUC ◀─stream──┘  validate, fill placeholders, send to the fixed host
    NUC ──result──▶ /private/dev_results/<farm>/<id>   {status, ms, json, body (redacted), truncated, request, …}

The client never holds the session token: it writes `{{token}}`, `{{serial}}`
and `{{device_id}}` and this module fills them on the NUC. Every check the RTDB
rules make is made again here:
  * off unless `allow_dev_console` is true (heartbeat meta/bridge.devConsole)
  * the owner only. The NUC cannot verify a Google ID token, so it uses the
    strongest data it has: `acl/admins/<uid>` (service-account-only, no client
    can grant it) AND the email in `acl/directory/<uid>` equals
    `acl/owner/email` (service-account-only). The directory entry is written by
    the signed-in user themselves, so on its own it proves nothing; the
    verified-email check lives in the RTDB rules, which are the first gate.
  * an ALLOW-LIST (ALLOWED_REQUESTS): only /v1/http/ with a listed `action`
    (and `method`/`type` from that action's list) and /v1/weather/cumulative/
    with type=rain; duplicates, nested or disguised keys refused. Commands,
    sign-in and sign-out are simply not in it (a login or logout would end the
    one Mobitech session SNOF and the owner's phone share). Host is always the
    configured Mobitech host
  * age <= 60 s, one request per 3 s, 300 per day, 20 s timeout
  * every answer is redacted before it is written (phone numbers, SIM, IMEI,
    SMS recipient packets, the token, serial, device id, any 10+ digit run)
    and capped at 256 KB; a response too large to redact reliably is dropped
  * every request node is deleted whether it ran or was refused; results are
    deleted after 10 minutes
"""
from __future__ import annotations

import asyncio
import html
import json
import logging
import re
import time
from typing import TYPE_CHECKING, Any
from urllib.parse import parse_qsl, quote

from .relay import TOKEN_PATH, pick_token
from .wire import STREAM_READ_TIMEOUT_SECONDS

if TYPE_CHECKING:
    import aiohttp

_LOGGER = logging.getLogger(__name__)

QUEUE = "dev_requests"
RESULTS = "private/dev_results"   # outside /farms: a viewer read grant cannot reach it

MAX_AGE_SECONDS = 60.0
MIN_GAP_SECONDS = 3.0
MAX_PER_DAY = 300
REQUEST_TIMEOUT_SECONDS = 20
MAX_QUERY = 2000
MAX_BODY = 8000
RESPONSE_CAP = 256 * 1024          # what is written back
READ_CAP = 2 * 1024 * 1024         # what is read at all; beyond it nothing is returned
RESULT_TTL_SECONDS = 600.0
STREAM_RETRY_SECONDS = 5.0
SEEN_LIMIT = 512

# THE ALLOW-LIST (mirrored by the apps; docs/dev-console-allowlist.json is
# generated from this table and a test keeps them equal). Anything not here is
# refused. For /v1/http/ an `action` is required and must be a key below; the
# `method` / `type` parameters, when present, must be in that action's list
# (None = any value; a parameter an action does not list is refused).
ALLOWED_REQUESTS: dict = {
    "/v1/http/": {
        "param": "action",
        "actions": {
            "dashboard": {},
            "dcon_node_details": {"type": ["get"]},
            "dcon_node": {"method": ["get_node", "get_all_valve"]},
            "dcon_timer": {"method": ["select"]},
            "logs": {"method": ["motor_log", "timer_log", "valve_log", "flow_log"]},
            "reports": {"type": None},
            "ferti": {"type": ["tank_get", "inj_get", "get", "tank_log_web"]},
            "fertiSett": {"type": ["get"]},
            "getWliData": {},
            "cmd_status": {},
        },
    },
    "/v1/weather/cumulative/": {
        "param": None,
        "fixed": {"type": "rain"},
    },
}
_GUARDED = ("action", "method", "type")
_REQ_ID = re.compile(r"^[-_A-Za-z0-9]{1,64}$")
_KEYS = {"uid", "at", "method", "path", "query", "body", "bodyType", "auth"}
_PLACEHOLDER = re.compile(r"\{\{(token|serial|device_id)\}\}")

DROP_KEYS = frozenset({"users", "sim", "mobile", "mobile_no", "email", "mail", "uname",
                       "user_id", "imei", "phone"})
DROP_PACKETS = frozenset({"1", "4", "5", "8"})
_LONG_DIGITS = re.compile(r"[0-9]{10,}")


class Refused(Exception):
    """A request that will not be sent, with the reason in plain words."""


# ---- validation --------------------------------------------------------------

_NO = "Only the listed read requests are allowed from the console"


def _canonical_path(path: str) -> str | None:
    if not isinstance(path, str) or "//" in path or not re.match(r"^/v1/[a-z_/]{1,60}$", path):
        return None
    full = path if path.endswith("/") else path + "/"
    return full if full in ALLOWED_REQUESTS else None


def _flatten_json(text: str) -> list[tuple[str, str]]:
    """Top-level pairs of a JSON object body. Anything else is refused, and so
    is an action/method/type key anywhere below the top level."""
    try:
        obj = json.loads(text)
    except ValueError:
        raise Refused("the body is not valid JSON") from None
    if not isinstance(obj, dict):
        raise Refused("a JSON body must be an object")

    def deep(v: Any) -> None:
        if isinstance(v, dict):
            for k, sub in v.items():
                if str(k).strip().lower() in _GUARDED:
                    raise Refused(_NO)
                deep(sub)
        elif isinstance(v, list):
            for sub in v:
                deep(sub)

    pairs = []
    for k, v in obj.items():
        if isinstance(v, (dict, list)):
            deep(v)
            continue
        if str(k).strip().lower() in _GUARDED and not isinstance(v, str):
            raise Refused(_NO)
        pairs.append((str(k), v if isinstance(v, str) else json.dumps(v)))
    return pairs


def _pairs(query: str, body: str, body_type: str) -> list[tuple[str, str]]:
    for text in (query, body if body_type == "form" else ""):
        if ";" in text:
            raise Refused(_NO)
    out = parse_qsl(query, keep_blank_values=True)
    if body_type == "form":
        out += parse_qsl(body, keep_blank_values=True)
    elif body_type == "json" and body.strip():
        out += _flatten_json(body)
    return out


def check_params(path: str, query: str, body: str, body_type: str) -> None:
    """The allow-list. Called on the request as written and again once the
    placeholders are filled."""
    canon = _canonical_path(path)
    if canon is None:
        raise Refused(_NO)
    entry = ALLOWED_REQUESTS[canon]
    seen: dict[str, str] = {}
    for k, v in _pairs(query, body, body_type):
        low = k.strip().lower()
        if "%" in k or "=" in k or "&" in k or (low in _GUARDED and k != low):
            raise Refused(_NO)             # disguised key
        if k in _GUARDED:
            if k in seen:
                raise Refused("duplicate " + k)
            seen[k] = v
    if "fixed" in entry:
        if seen != entry["fixed"]:
            raise Refused(_NO)
        return
    action = seen.get("action")
    rules = entry["actions"].get(action) if action is not None else None
    if rules is None:
        raise Refused(_NO)
    for key in ("method", "type"):
        if key in seen:
            if key not in rules:
                raise Refused(_NO)
            allowed = rules[key]
            if allowed is not None and seen[key] not in allowed:
                raise Refused(_NO)


def validate(req: Any, now: float | None = None) -> dict:
    """The request normalised, or Refused. Does not touch the network."""
    if not isinstance(req, dict) or set(req) - _KEYS or not {"uid", "at", "method", "path"} <= set(req):
        raise Refused("not a console request")
    uid = req["uid"]
    if not isinstance(uid, str) or not uid or len(uid) > 128 or "/" in uid:
        raise Refused("bad uid")
    at = req["at"]
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        raise Refused("bad time")
    age = (time.time() if now is None else now) - at / 1000.0
    if age > MAX_AGE_SECONDS or age < -60:
        raise Refused("request is too old")
    method = req["method"]
    if method not in ("GET", "POST"):
        raise Refused("only GET and POST")
    path = req["path"]
    if _canonical_path(path) is None:
        raise Refused(_NO)
    query = req.get("query", "")
    body = req.get("body", "")
    if not isinstance(query, str) or len(query) > MAX_QUERY:
        raise Refused("query too long")
    if not isinstance(body, str) or len(body) > MAX_BODY:
        raise Refused("body too long")
    body_type = req.get("bodyType", "none")
    if body_type not in ("form", "json", "none"):
        raise Refused("bad body type")
    if body_type == "none" and body:
        raise Refused("a body needs a body type")
    if method == "GET" and body:
        raise Refused("a GET has no body")
    auth = req.get("auth", False)
    if not isinstance(auth, bool):
        raise Refused("bad auth flag")
    check_params(path, query, body, body_type)
    return {"uid": uid, "method": method, "path": path, "query": query,
            "body": body, "bodyType": body_type, "auth": auth}


def fill(req: dict, token: str, serial: str, device_id: str) -> tuple[str, str, str]:
    """(query, body, authorization) with the placeholders filled. Values are
    encoded for where they land: percent-encoded in a query or a form, escaped
    in JSON. Refused if a placeholder has nothing to fill it with."""
    values = {"token": token, "serial": serial, "device_id": device_id}

    def sub(text: str, mode: str) -> str:
        def one(m: re.Match) -> str:
            v = values[m.group(1)]
            if not v:
                raise Refused(f"no {m.group(1)} is set on the farm box")
            return json.dumps(v)[1:-1] if mode == "json" else quote(v, safe="")
        return _PLACEHOLDER.sub(one, text)

    query = sub(req["query"], "form")
    body = sub(req["body"], "json" if req["bodyType"] == "json" else "form")
    authorization = ""
    if req["auth"]:
        if not token:
            raise Refused("no Mobitech session: the owner signs in first")
        authorization = token
    # Re-check the filled text: the placeholders must not have built anything
    # the allow-list would refuse.
    check_params(req["path"], query, body, req["bodyType"])
    return query, body, authorization


# ---- redaction ---------------------------------------------------------------

def _drop(value: Any, in_packets: bool = False) -> Any:
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if str(k).lower() in DROP_KEYS:
                continue
            if in_packets and str(k) in DROP_PACKETS:
                continue
            out[k] = _drop(v, str(k).lower() == "packets")
        return out
    if isinstance(value, list):
        return [(_drop(v) if not (in_packets and str(i) in DROP_PACKETS) else None)
                for i, v in enumerate(value)]
    return value


_PHONE = re.compile(r"[+(]?\d[\d \-()]{8,}\d")
_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")


def _phone(m: re.Match) -> str:
    text = m.group(0)
    if sum(c.isdigit() for c in text) < 10 or _ISO_DATE.match(text):
        return text           # a date and time is not a phone number
    return "<redacted>"


def _forms(value: str) -> set[str]:
    return {value, json.dumps(value)[1:-1], quote(value, safe=""), quote(value, safe=":"),
            quote(value, safe="@"), quote(value, safe=":@"), html.escape(value),
            value.replace("@", "&#64;"), html.escape(value).replace("@", "&#64;"),
            value.replace("@", "&#x40;")}


def scrub_text(text: str, secrets: dict[str, str]) -> str:
    """Secrets back to their placeholders (the whole value, then the token's
    core between ':' and '@'), then phone-like and 10+ digit runs gone."""
    for name, value in secrets.items():
        if not value or len(value) < 4:
            continue
        ph = "{{" + name.rstrip("23") + "}}"
        for form in sorted(_forms(value), key=len, reverse=True):
            text = text.replace(form, ph)
        if name.startswith("token") and ":" in value and "@" in value:
            core = value.split(":", 1)[1].rsplit("@", 1)[0]
            if len(core) >= 20:
                for form in sorted(_forms(core), key=len, reverse=True):
                    text = text.replace(form, ph)
    text = _PHONE.sub(_phone, text)
    return _LONG_DIGITS.sub("<redacted>", text)


def redact(raw: str, secrets: dict[str, str], cap: int = RESPONSE_CAP) -> tuple[str, bool, bool]:
    """(body, is_json, truncated). Always applied; JSON is pruned structurally
    first, and the final text is scrubbed whatever it is."""
    try:
        parsed = json.loads(raw)
        is_json = True
    except ValueError:
        parsed, is_json = None, False
    text = json.dumps(_drop(parsed), separators=(",", ":")) if is_json else raw
    text = scrub_text(text, secrets)
    truncated = len(text.encode("utf-8")) > cap
    if truncated:
        text = text.encode("utf-8")[:cap].decode("utf-8", "ignore")
        is_json = False          # a cut JSON document is no longer JSON
    return text, is_json, truncated


def echo(req: dict, secrets: dict[str, str]) -> dict:
    """The request as the client sent it (placeholders), scrubbed anyway."""
    return {k: (scrub_text(req[k], secrets) if isinstance(req[k], str) else req[k])
            for k in ("method", "path", "query", "body", "bodyType", "auth")}


def day_allows(stamps: list[float], now: float) -> bool:
    """Under MAX_PER_DAY in the last 24 h."""
    return sum(1 for s in stamps if now - s < 86400) < MAX_PER_DAY


# ---- the consumer ------------------------------------------------------------

class DevConsole:
    def __init__(self, cfg, rtdb, session: "aiohttp.ClientSession") -> None:
        self._cfg = cfg
        self._rtdb = rtdb
        self._session = session
        self._seen: list[str] = []
        self._sent_at: list[float] = []      # monotonic-free wall times, last 24 h
        self._last = 0.0
        self._written: dict[str, float] = {}  # result id -> wall time written
        self.served = 0
        self.refused = 0

    @property
    def enabled(self) -> bool:
        c = self._cfg
        return bool(c.allow_dev_console and c.dcon_serial and (c.dcon_token_id or c.dcon_command_auth))

    # ---- owner ----------------------------------------------------------------

    async def _is_owner(self, uid: str) -> bool:
        try:
            if (await self._rtdb.get(f"acl/admins/{uid}")) is not True:
                return False
            owner = await self._rtdb.get("acl/owner/email")
            email = await self._rtdb.get(f"acl/directory/{uid}/email")
        except Exception:               # noqa: BLE001
            return False
        return (isinstance(owner, str) and isinstance(email, str) and owner.strip() != ""
                and owner.strip().lower() == email.strip().lower())

    # ---- network --------------------------------------------------------------

    async def _token(self) -> str:
        try:
            signed_in = await self._rtdb.get(TOKEN_PATH)
        except Exception:               # noqa: BLE001
            signed_in = None
        return pick_token(signed_in, self._cfg.dcon_token_id) or pick_token(None, self._cfg.dcon_command_auth)

    async def _send(self, req: dict, query: str, body: str, authorization: str) -> tuple[int, str, bool]:
        """(status, text, too_big). Never follows a redirect."""
        import aiohttp
        from yarl import URL

        cfg = self._cfg
        url = f"{cfg.dcon_base}{req['path']}" + (f"?{query}" if query else "")
        headers = {}
        if authorization:
            headers["authorization"] = authorization
        data = None
        if req["method"] == "POST" and req["bodyType"] != "none":
            data = body.encode("utf-8")
            headers["content-type"] = ("application/json" if req["bodyType"] == "json"
                                       else "application/x-www-form-urlencoded")
        timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        async with self._session.request(req["method"], URL(url, encoded=True), data=data,
                                         headers=headers, timeout=timeout,
                                         allow_redirects=False) as resp:
            chunks, size = [], 0
            async for chunk in resp.content.iter_chunked(65536):
                size += len(chunk)
                if size > READ_CAP:
                    return resp.status, "", True
                chunks.append(chunk)
            return resp.status, b"".join(chunks).decode("utf-8", "replace"), False

    # ---- one request ----------------------------------------------------------

    def _secrets(self, token: str) -> dict[str, str]:
        c = self._cfg
        return {"token": token, "serial": c.dcon_serial, "device_id": c.dcon_device_id}

    async def _check_and_run(self, req_id: str, raw: Any) -> dict:
        req = validate(raw)
        if not await self._is_owner(req["uid"]):
            raise Refused("only the owner may use the console")
        now = time.time()
        if now - self._last < MIN_GAP_SECONDS:
            raise Refused("one request every 3 seconds")
        if not day_allows(self._sent_at, now):
            raise Refused("daily limit reached")
        token = await self._token()
        query, body, authorization = fill(req, token, self._cfg.dcon_serial, self._cfg.dcon_device_id)
        secrets = self._secrets(token)
        # Also scrub the hand-set options, in case the session differs from them.
        secrets["token2"] = self._cfg.dcon_command_auth
        secrets["token3"] = self._cfg.dcon_token_id
        self._last = now
        self._sent_at = [s for s in self._sent_at if now - s < 86400] + [now]
        started = time.monotonic()
        result: dict = {"uid": req["uid"], "request": echo(req, secrets)}
        try:
            status, text, too_big = await self._send(req, query, body, authorization)
            result["status"] = int(status)
            if too_big:
                result.update(body="", json=False, truncated=True,
                              error="response too large to return")
            else:
                text, is_json, truncated = redact(text, secrets)
                result.update(body=text, json=is_json, truncated=truncated)
        except Exception as err:        # noqa: BLE001
            result.update(status=0, body="", json=False, truncated=False,
                          error=scrub_text(type(err).__name__, secrets))
        result["ms"] = int((time.monotonic() - started) * 1000)
        self.served += 1
        return result

    async def handle(self, req_id: str, raw: Any) -> None:
        if raw is None or req_id in self._seen:
            return
        if not isinstance(req_id, str) or not _REQ_ID.match(req_id):
            self.refused += 1
            _LOGGER.warning("Refused console request with a bad id")
            try:
                await self._rtdb.put(f"{self._cfg.root}/{QUEUE}/{quote(str(req_id), safe='')}", None)
            except Exception:
                _LOGGER.exception("Could not clear a console request with a bad id")
            return
        self._seen.append(req_id)
        if len(self._seen) > SEEN_LIMIT:
            del self._seen[: len(self._seen) - SEEN_LIMIT]
        try:
            try:
                result = await self._check_and_run(req_id, raw)
            except Refused as why:
                self.refused += 1
                _LOGGER.warning("Refused console request %s: %s", req_id, why)
                uid = raw.get("uid") if isinstance(raw, dict) else None
                result = {"uid": uid if isinstance(uid, str) else "", "status": 0, "ms": 0,
                          "json": False, "body": "", "truncated": False,
                          "error": scrub_text(str(why), self._secrets(""))}
            now_ms = int(time.time() * 1000)
            result["at"] = now_ms
            await self._cleanup()
            await self._rtdb.put(f"{RESULTS}/{self._cfg.farm_slug}/{req_id}", result)
            self._written[req_id] = time.time()
        except Exception:
            _LOGGER.exception("Console request %s failed", req_id)
        finally:
            try:
                await self._rtdb.put(f"{self._cfg.root}/{QUEUE}/{req_id}", None)
            except Exception:
                _LOGGER.exception("Could not clear console request %s", req_id)

    async def _cleanup(self) -> None:
        """Results older than 10 minutes go (also at start)."""
        now = time.time()
        try:
            old = [k for k, t in self._written.items() if now - t > RESULT_TTL_SECONDS]
            for k in old:
                await self._rtdb.put(f"{RESULTS}/{self._cfg.farm_slug}/{k}", None)
                self._written.pop(k, None)
        except Exception:
            _LOGGER.debug("Could not clear old console results", exc_info=True)

    async def _cleanup_at_start(self) -> None:
        try:
            keys = await self._rtdb.get(f"{RESULTS}/{self._cfg.farm_slug}", shallow=True)
            for k in (keys or {}):
                at = await self._rtdb.get(f"{RESULTS}/{self._cfg.farm_slug}/{k}/at")
                if not isinstance(at, (int, float)) or time.time() - at / 1000.0 > RESULT_TTL_SECONDS:
                    await self._rtdb.put(f"{RESULTS}/{self._cfg.farm_slug}/{k}", None)
                else:
                    self._written[k] = at / 1000.0
        except Exception:
            _LOGGER.debug("Could not clear old console results at start", exc_info=True)

    # ---- stream ---------------------------------------------------------------

    async def _dispatch(self, path: str, data: Any) -> None:
        path = (path or "/").strip("/")
        if not path:
            for req_id, req in (data or {}).items():
                await self.handle(req_id, req)
        elif "/" not in path:
            await self.handle(path, data)

    async def _purge(self) -> None:
        path = f"{self._cfg.root}/{QUEUE}"
        try:
            if await self._rtdb.get(path, shallow=True):
                await self._rtdb.put(path, None)
                _LOGGER.info("Developer console is off: dropped queued console requests")
        except Exception:
            _LOGGER.debug("Could not purge the console queue", exc_info=True)

    async def run(self) -> None:
        if not self.enabled:
            _LOGGER.info("Developer console is off; not watching the console queue")
            await self._purge()
            return
        _LOGGER.info("Watching developer console (reads only)")
        await self._cleanup_at_start()
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Console stream error: %s", err or type(err).__name__)
            await asyncio.sleep(STREAM_RETRY_SECONDS)

    async def _stream_once(self) -> None:
        import aiohttp
        url = f"{self._cfg.firebase_db_url}/{self._cfg.root}/{QUEUE}.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30,
                                        sock_read=STREAM_READ_TIMEOUT_SECONDS)
        async with self._session.get(url, headers=headers, timeout=timeout, allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"console stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Developer console stream open")
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
