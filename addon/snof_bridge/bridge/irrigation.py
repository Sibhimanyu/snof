"""Irrigation reports: vendor APIs -> normalized results, on demand.

The farm's motors and valves are driven by vendor controllers (Livesky,
Niagara, Mobitech DCON) whose APIs need bearer tokens and device ids, plus
OpenWeather for field conditions (see the "Mobitech Hack" Postman
collection). Those credentials live in the add-on options and never leave
the NUC: the dashboard appends a *report request* to
/farms/<slug>/irrigation_requests, this runner executes that one vendor
call server-side, normalizes with vendors.py, and writes the result to
/farms/<slug>/irrigation_reports/<request-id>. The dashboard renders
results and never sees a credential.

Nothing here is polled. Every vendor call answers a user pressing Generate;
an idle farm costs zero vendor traffic. Request validation mirrors
commands.py — allow-listed report types, strict date shapes, a 31-day range
cap, and a staleness drop so a queue that piles up while the bridge is down
does not fire all at once when it comes back.

Deliberately read-only. The collection also captures command endpoints
(DCON /v1/command/, valve ON/OFF) — this runner never calls them. Operating
a pump from a browser tab is the same class of decision as cover/lock, and
would go through the /commands queue with its own allow-list, not as a
direct vendor call from here. Nothing in this module performs an action.
"""
from __future__ import annotations

import asyncio
import datetime as _dt
import json
import logging
import re
import time
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:          # aiohttp is imported where it is used, so the pure
    import aiohttp         # validation logic stays testable with no deps installed.

from . import vendors

_LOGGER = logging.getLogger(__name__)

REQUEST_TIMEOUT_SECONDS = 30

# A request left in the queue longer than this is dropped, not run.
REQUEST_MAX_AGE_SECONDS = 300.0

# DCON log/report ranges are user-chosen; cap them so a typo cannot ask for
# a decade.
MAX_RANGE_DAYS = 31

# Ids of requests already handled, so a re-delivered snapshot cannot run one
# twice. Same bound rationale as commands.SEEN_LIMIT.
SEEN_LIMIT = 512

SERVER_TIMESTAMP = {".sv": "timestamp"}

_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")

# Report type -> needs. "range" means from/to dates, "live" means no params:
# point-in-time pulls (Livesky, Niagara, DCON dashboard, weather) and the
# energy/pressure snapshots, which the bridge stamps with its own clock.
REPORT_TYPES = {
    "river_status": "live",
    "well_status": "live",
    "controller": "live",
    "weather": "live",
    "electricity": "live",
    "pressure": "live",
    "valves": "range",
    "timer_log": "range",
    "motor_log": "range",
    "pressure_range": "range",
}

REPORT_LABELS = {
    "river_status": "River motor status",
    "well_status": "Well motor status",
    "controller": "Controller dashboard",
    "weather": "Field weather",
    "electricity": "Electricity snapshot",
    "pressure": "Pressure snapshot",
    "valves": "Valve runtime",
    "timer_log": "Timer log",
    "motor_log": "Motor log",
    "pressure_range": "Pressure range",
}


def _parse_date(value: Any) -> _dt.date | None:
    """Strict YYYY-MM-DD, and a real calendar date, not month 13."""
    if not isinstance(value, str):
        return None
    match = _DATE_RE.match(value.strip())
    if not match:
        return None
    try:
        return _dt.date(int(match.group(1)), int(match.group(2)),
                        int(match.group(3)))
    except ValueError:
        return None


def _now_stamp() -> str:
    return _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


class IrrigationRunner:
    def __init__(self, cfg, rtdb, session: aiohttp.ClientSession) -> None:
        self._cfg = cfg
        self._rtdb = rtdb
        self._session = session
        self.enabled = bool(getattr(cfg, "irrigation_enabled", False))
        self._seen: list[str] = []
        self.executed = 0
        self.refused = 0
        self.last_ok: str = ""
        self.last_error: str = ""

    # ---- low level ------------------------------------------------------

    async def _get_json(self, url: str, headers: dict | None = None,
                        params: dict | None = None) -> Any:
        import aiohttp

        timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        async with self._session.get(url, headers=headers or {},
                                     params=params or {},
                                     timeout=timeout) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"GET {url} -> {resp.status}")
            try:
                return await resp.json(content_type=None)
            except Exception:
                return await resp.text()

    async def _post_form(self, url: str, form: dict) -> Any:
        timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        async with self._session.post(url, data=form,
                                      timeout=timeout) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"POST {url} -> {resp.status}")
            try:
                return await resp.json(content_type=None)
            except Exception:
                return await resp.text()

    # ---- validation -----------------------------------------------------

    def _reject(self, req_id: str, reason: str, req: Any) -> None:
        self.refused += 1
        _LOGGER.warning("Refused irrigation request %s (%s): %r",
                        req_id, reason, req)

    def validate(self, req_id: str, req: Any) -> tuple[str, dict] | None:
        """Return (report_type, params) for a request worth running."""
        if not isinstance(req, dict):
            self._reject(req_id, "not an object", req)
            return None

        rtype = req.get("type")
        if not isinstance(rtype, str) or rtype not in REPORT_TYPES:
            self._reject(req_id, f"unknown report type {rtype!r}", req)
            return None

        at = req.get("at")
        if not isinstance(at, (int, float)):
            self._reject(req_id, "no timestamp", req)
            return None
        age = time.time() - (at / 1000.0)
        if age > REQUEST_MAX_AGE_SECONDS or age < -60:
            self._reject(req_id, f"stale by {age:.0f}s", req)
            return None

        params: dict[str, str] = {}
        if REPORT_TYPES[rtype] == "range":
            start = _parse_date(req.get("from"))
            end = _parse_date(req.get("to"))
            if start is None or end is None:
                self._reject(req_id, "from/to must be YYYY-MM-DD dates", req)
                return None
            if end < start:
                self._reject(req_id, "to is before from", req)
                return None
            if (end - start).days > MAX_RANGE_DAYS:
                self._reject(req_id,
                             f"range over {MAX_RANGE_DAYS} days", req)
                return None
            params = {"from": start.isoformat(), "to": end.isoformat()}
        return rtype, params

    # ---- per-vendor fetches ----------------------------------------------

    async def _livesky(self) -> list[dict]:
        cfg = self._cfg
        if not (cfg.livesky_bearer and cfg.livesky_imei):
            raise RuntimeError("Livesky is not configured")
        raw = await self._get_json(
            f"{cfg.livesky_base}/getMotors",
            headers={"Authorization": f"Bearer {cfg.livesky_bearer}",
                     "Accept": "application/json, text/plain, */*"},
            params={"imei": cfg.livesky_imei},
        )
        return vendors.normalize_livesky(raw)

    async def _niagara(self) -> list[dict]:
        cfg = self._cfg
        if not (cfg.niagara_base and cfg.niagara_user and cfg.niagara_clusters):
            raise RuntimeError("Niagara is not configured")
        controllers: list[dict] = []
        for entry in cfg.niagara_clusters:
            cluster, _, label = str(entry).partition(":")
            cluster = cluster.strip()
            if not cluster:
                continue
            raw = await self._get_json(
                f"{cfg.niagara_base}/api/v1/user/{cfg.niagara_user}"
                f"/cluster/{cluster}/controller")
            controllers.extend(
                vendors.normalize_niagara(raw, label.strip() or cluster))
        return controllers

    async def _dcon_form(self, payload: dict) -> Any:
        cfg = self._cfg
        if not (cfg.dcon_token_id and cfg.dcon_serial):
            raise RuntimeError("DCON is not configured")
        try:
            return await self._post_form(f"{cfg.dcon_base}/v1/http/", payload)
        except Exception as err:
            raise RuntimeError(
                f"DCON {payload.get('method', payload.get('action'))}: "
                f"{err or type(err).__name__}")

    async def _dcon_report(self, url_params: dict) -> Any:
        cfg = self._cfg
        if not (cfg.dcon_token_id and cfg.dcon_serial):
            raise RuntimeError("DCON is not configured")
        return await self._get_json(f"{cfg.dcon_base}/v1/http/",
                                    params=url_params)

    async def _weather(self) -> dict:
        cfg = self._cfg
        if not (cfg.owm_appid and cfg.owm_place):
            raise RuntimeError("Weather is not configured")
        raw = await self._get_json(
            "https://api.openweathermap.org/data/2.5/weather",
            params={"q": cfg.owm_place, "units": "metric",
                    "appid": cfg.owm_appid})
        return vendors.normalize_weather(raw)

    # ---- one request, end to end ------------------------------------------

    def _report_base(self, rtype: str, params: dict) -> dict:
        return {"type": rtype, "label": REPORT_LABELS[rtype],
                "params": params, "at": SERVER_TIMESTAMP}

    async def _run_validated(self, rtype: str, params: dict) -> tuple[dict, dict]:
        """Execute one validated request. Returns (report, cache_patch)."""
        cfg = self._cfg
        serial = cfg.dcon_serial
        product = cfg.dcon_product or "DCON"

        if rtype == "river_status":
            motors = await self._livesky()
            running = sum(1 for m in motors if m["status"] == "on")
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": f"{running} running of {len(motors)} motors",
                     "rows": motors}, {"motors": motors})

        if rtype == "well_status":
            controllers = await self._niagara()
            running = sum(1 for c in controllers if c["status"] == "on")
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": f"{running} running of "
                                f"{len(controllers)} controllers",
                     "rows": controllers}, {"controllers": controllers})

        if rtype == "controller":
            dash_raw = await self._dcon_form(
                {"action": "dashboard", "p": "app",
                 "token_id": cfg.dcon_token_id, "product": product})
            node_raw = await self._dcon_form(
                {"action": "dcon_node", "method": "get_node",
                 "serial_no": serial})
            dcon = vendors.normalize_dcon_dashboard(dash_raw or node_raw or {})
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": dcon.get("device") or "Controller",
                     "rows": []}, {"dcon": dcon})

        if rtype == "weather":
            weather = await self._weather()
            desc = weather.get("desc") or "—"
            temp = weather.get("temp")
            summary = (f"{round(temp)}°C, {desc}" if temp is not None
                       else desc)
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": summary, "rows": []}, {"weather": weather})

        if rtype == "electricity":
            raw = await self._dcon_report(
                {"action": "reports", "type": "electricity",
                 "serial_no": serial, "dt": _now_stamp(),
                 "product": product})
            rows = vendors.normalize_report(raw, "electricity")
            last = rows[-1] if rows else {}
            summary = " ".join(str(last.get(k) or "") for k in ("value", "unit",
                                                                "at")).strip()
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": summary or f"{len(rows)} readings",
                     "rows": rows}, {"electricity": rows})

        if rtype == "pressure":
            raw = await self._dcon_report(
                {"action": "reports", "type": "pressure_cond",
                 "serial_no": serial, "dt": _now_stamp(),
                 "product": product})
            rows = vendors.normalize_report(raw, "pressure")
            last = rows[-1] if rows else {}
            summary = " ".join(str(last.get(k) or "") for k in ("value", "unit",
                                                                "at")).strip()
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": summary or f"{len(rows)} readings",
                     "rows": rows}, {"pressure": rows})

        # Range reports: valves, timer_log, motor_log, pressure_range.
        start, end = params["from"], params["to"]
        if rtype == "valves":
            raw = await self._dcon_form(
                {"action": "dcon_node", "method": "get_all_valve",
                 "from": start, "to": end, "serial_no": serial})
            rows = vendors.normalize_dcon_valves(raw)
            opened = sum(1 for v in rows if v["status"] == "on")
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": f"{len(rows)} valves · {opened} open · "
                                f"{start} → {end}",
                     "rows": rows}, {"valves": rows})

        if rtype in ("timer_log", "motor_log"):
            kind = "timer" if rtype == "timer_log" else "motor"
            raw = await self._dcon_form(
                {"action": "logs", "method": kind + "_log",
                 "serial_no": serial, "from": start, "to": end})
            rows = vendors.normalize_dcon_logs(raw, kind)
            patch = {"timerLog": rows} if kind == "timer" else {"motorLog": rows}
            return ({**self._report_base(rtype, params), "status": "ok",
                     "summary": f"{len(rows)} entries · {start} → {end}",
                     "rows": rows}, patch)

        raw = await self._dcon_report(
            {"action": "reports", "type": "pressure_timer",
             "serial_no": serial,
             "from": f"{start} 00:00:00", "to": f"{end} 23:59:59",
             "product": product})
        rows = vendors.normalize_report(raw, "pressure")
        return ({**self._report_base(rtype, params), "status": "ok",
                 "summary": f"{len(rows)} readings · {start} → {end}",
                 "rows": rows}, {"pressure": rows})

    async def handle(self, req_id: str, req: Any) -> None:
        if req is None or req_id in self._seen:
            return
        self._seen.append(req_id)
        if len(self._seen) > SEEN_LIMIT:
            del self._seen[: len(self._seen) - SEEN_LIMIT]
        checked = self.validate(req_id, req)
        root = self._cfg.root
        try:
            if checked is not None:
                rtype, params = checked
                try:
                    report, patch = await self._run_validated(rtype, params)
                    self.executed += 1
                    self.last_ok = _now_stamp()
                    self.last_error = ""
                    _LOGGER.info("Ran irrigation report %s (%s)", rtype, req_id)
                except Exception as err:
                    message = str(err)[:200] or type(err).__name__
                    report, patch = (
                        {**self._report_base(rtype, params), "status": "error",
                         "summary": "", "rows": [], "error": message}, {})
                    self.last_error = message
                    _LOGGER.warning("Irrigation report %s failed: %s",
                                    req_id, message)
                try:
                    await self._rtdb.put(
                        f"{root}/irrigation_reports/{req_id}", report)
                    if patch:
                        await self._rtdb.patch(f"{root}/irrigation", patch)
                    await self._rtdb.patch(
                        f"{root}/irrigation/meta",
                        {"lastUpdated": SERVER_TIMESTAMP,
                         "lastType": rtype,
                         "lastError": report.get("error", "")})
                except Exception:
                    self.last_error = "mirror write failed"
                    _LOGGER.exception("Could not mirror irrigation report %s",
                                      req_id)
        except Exception:
            _LOGGER.exception("Irrigation request %s failed", req_id)
        finally:
            # Refused or failed, the node still goes: a request left in the
            # queue would be retried on every reconnect.
            if req_id in self._seen:
                try:
                    await self._rtdb.put(
                        f"{root}/irrigation_requests/{req_id}", None)
                except Exception:
                    _LOGGER.exception("Could not clear irrigation request %s",
                                      req_id)

    async def _dispatch(self, path: str, data: Any) -> None:
        """Translate one RTDB stream event into zero or more requests."""
        path = (path or "/").strip("/")
        if not path:
            for req_id, req in (data or {}).items():
                await self.handle(req_id, req)
        elif "/" not in path:
            await self.handle(path, data)
        # Deeper paths only ever appear for a node we are already deleting.

    # ---- stream -----------------------------------------------------------

    def status(self) -> dict:
        return {"enabled": self.enabled, "requestsRun": self.executed,
                "requestsRefused": self.refused, "lastOk": self.last_ok,
                "lastError": self.last_error}

    async def run(self) -> None:
        if not self.enabled:
            _LOGGER.info("Irrigation reports are disabled; not watching the "
                         "request queue")
            return
        _LOGGER.info("Watching irrigation request queue")
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Irrigation stream error: %s",
                              err or type(err).__name__)
            await asyncio.sleep(5.0)

    async def _stream_once(self) -> None:
        import aiohttp

        url = f"{self._cfg.firebase_db_url}/{self._cfg.root}/irrigation_requests.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        # sock_read=None: the stream is idle most of the time by design, and RTDB
        # sends a keep-alive rather than closing. A total timeout would kill it.
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=None)

        async with self._session.get(url, headers=headers, timeout=timeout,
                                     allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"irrigation stream -> {resp.status}: "
                                   f"{(await resp.text())[:200]}")
            _LOGGER.info("Irrigation request stream open")
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
                            _LOGGER.warning("Unparseable irrigation stream payload")
                            continue
                        await self._dispatch(body.get("path"), body.get("data"))
                    elif event == "auth_revoked":
                        _LOGGER.info("Stream token expired; reconnecting")
                        return
