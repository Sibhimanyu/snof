"""Irrigation reports: vendor APIs -> normalized results, on demand.

The farm's valves and timers are driven by a Mobitech DCON (MCON) controller
whose API needs a token id and a serial (see the "Mobitech Hack" Postman
collection). Livesky, Niagara and OpenWeather were wired here until
2026-09-23 and were removed at the owner's request; the farm does not use
them. Those credentials live in the add-on options and never leave
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
# point-in-time pulls, and the energy/pressure snapshots, which the bridge
# stamps with its own clock.
#
# Every one of these reads the same controller. The first three are
# *composites*: one press, two calls, one report, because the questions the
# farm actually asks span two endpoints — did the line hold while the valves
# were open, did the motor stop mid-timer. The rest pull exactly one endpoint.
REPORT_TYPES = {
    "live_readings": "live",
    "session_log": "range",
    "performance": "range",
    "controller": "live",
    "electricity": "live",
    "pressure": "live",
    "valves": "range",
    "timer_log": "range",
    "motor_log": "range",
    "pressure_range": "range",
}

REPORT_LABELS = {
    "live_readings": "Power and pressure now",
    "session_log": "Irrigation session log",
    "performance": "Valve runtime against pressure",
    "controller": "Controller dashboard",
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


# The controller answers a snapshot query with the samples at or after `dt`,
# and it stores one every ~11 seconds. Asking for the current second therefore
# returns nothing at all — the first live pull came back empty for exactly this
# reason. Ask for the last few minutes instead and take the newest row.
SNAPSHOT_LOOKBACK = _dt.timedelta(minutes=5)


def _snapshot_stamp() -> str:
    return (_dt.datetime.now() - SNAPSHOT_LOOKBACK).strftime("%Y-%m-%d %H:%M:%S")


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
        # aiohttp is imported per call site, not at module scope, so
        # tests/test_logic.py can import this module with nothing installed.
        # _get_json did that and this did not, so every POST — which is most of
        # the DCON API — died with "name 'aiohttp' is not defined" the first
        # time a report ran for real.
        import aiohttp

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

    # ---- vendor calls, one shape per section ------------------------------

    async def _dcon_controller(self) -> tuple[dict, list[dict]]:
        """The controller card is itself two calls: the app dashboard for the
        device and its clock, get_node for the valve registry. get_node is the
        only source of valve *names* — "4 Veg", "6 Kulam" — so a runtime report
        without it is a list of numbers."""
        cfg = self._cfg
        dash_raw = await self._dcon_form(
            {"action": "dashboard", "p": "app",
             "token_id": cfg.dcon_token_id, "product": cfg.dcon_product or "DCON"})
        node_raw = await self._dcon_form(
            {"action": "dcon_node", "method": "get_node",
             "serial_no": cfg.dcon_serial})
        return (vendors.normalize_dcon_dashboard(dash_raw or {}),
                vendors.normalize_dcon_nodes(node_raw or {}))

    async def _dcon_valves(self, start: str, end: str) -> list[dict]:
        raw = await self._dcon_form(
            {"action": "dcon_node", "method": "get_all_valve",
             "from": start, "to": end, "serial_no": self._cfg.dcon_serial})
        return vendors.normalize_dcon_valves(raw)

    async def _dcon_log(self, kind: str, start: str, end: str) -> list[dict]:
        raw = await self._dcon_form(
            {"action": "logs", "method": kind + "_log",
             "serial_no": self._cfg.dcon_serial, "from": start, "to": end})
        return vendors.normalize_dcon_logs(raw, kind)

    async def _dcon_now(self, kind: str) -> list[dict]:
        """electricity / pressure_cond: a point-in-time pull the controller
        wants stamped with a clock, so the bridge supplies its own. The two
        answer in different shapes — pressure as readings, electricity as the
        raw controller packet — so they parse differently."""
        raw = await self._dcon_report(
            {"action": "reports", "type": kind,
             "serial_no": self._cfg.dcon_serial, "dt": _snapshot_stamp(),
             "product": self._cfg.dcon_product or "DCON"})
        if kind == "electricity":
            return vendors.normalize_dcon_electricity(raw)
        return vendors.normalize_report(raw, kind)

    async def _dcon_pressure_range(self, start: str, end: str) -> list[dict]:
        raw = await self._dcon_report(
            {"action": "reports", "type": "pressure_timer",
             "serial_no": self._cfg.dcon_serial,
             "from": f"{start} 00:00:00", "to": f"{end} 23:59:59",
             "product": self._cfg.dcon_product or "DCON"})
        return vendors.normalize_report(raw, "pressure")

    # ---- one request, end to end ------------------------------------------

    def _report_base(self, rtype: str, params: dict) -> dict:
        return {"type": rtype, "label": REPORT_LABELS[rtype],
                "params": params, "at": SERVER_TIMESTAMP}

    async def _leg(self, call) -> tuple[Any, str]:
        """Run one call of a composite report. A leg that fails hands back its
        plain-word reason instead of sinking the whole report: a timer log the
        controller will not produce must not cost the user the motor log they
        asked for in the same pull."""
        try:
            return await call(), ""
        except Exception as err:
            return None, str(err)[:200] or type(err).__name__

    def _result(self, rtype: str, params: dict, sections: list[dict],
                summary: str, rows: list | None = None,
                patch: dict | None = None) -> tuple[dict, dict]:
        """Roll sections into one report. Status is ok, partial when a leg
        failed but something still rendered, error when nothing did — the
        dashboard tags all three differently so a half-report never reads as
        a whole one."""
        drawn = [s for s in sections if s.get("rows") or s.get("note")]
        failed = [s for s in sections if s.get("status") == "error"]
        # Two legs of the same vendor fail for the same reason; say it once.
        reasons = list(dict.fromkeys(s["error"] for s in failed if s["error"]))
        if failed and not drawn:
            status, error = "error", "; ".join(reasons)[:200]
        elif failed:
            status, error = "partial", "; ".join(reasons)[:200]
        else:
            status, error = "ok", ""
        report = {**self._report_base(rtype, params), "status": status,
                  "summary": summary, "sections": sections,
                  # rows stays for the pre-sections dashboard build: a client
                  # that has not reloaded still renders the primary rows.
                  "rows": list(rows or [])[:vendors.MAX_LIST]}
        if error:
            report["error"] = error
        return report, (patch or {})

    @staticmethod
    def _metric(label: str, value: Any, unit: str = "", note: str = "") -> dict:
        return {"label": label, "value": value, "unit": unit, "note": note}

    @staticmethod
    def _reading_sections(title: str, rows: list, err: str,
                          source: str) -> list[dict]:
        """One vendor reading: the latest value as a headline, and a
        sparkline only when the vendor actually returned a curve."""
        if err:
            return [vendors.section("metrics", title, source=source, error=err)]
        stats = vendors.series_stats(rows)
        if not stats.get("count"):
            return [vendors.section("metrics", title, source=source,
                                    note="the vendor returned no reading")]
        unit = stats.get("unit") or ""
        metrics = [{"label": title, "value": stats["last"], "unit": unit,
                    "note": (rows[-1].get("at") if isinstance(rows[-1], dict)
                             else "") or "latest"}]
        if stats["count"] > 1:
            metrics.append({"label": f"{title} range", "value":
                            f"{stats['min']} – {stats['max']}", "unit": unit,
                            "note": f"avg {stats['avg']} over "
                                    f"{stats['count']} readings"})
        out = [vendors.section("metrics", title, metrics, source=source)]
        if stats["count"] > 1:
            out.append(vendors.section("series", f"{title} over time", rows,
                                       source=source))
        return out

    async def _run_validated(self, rtype: str, params: dict) -> tuple[dict, dict]:
        """Execute one validated request. Returns (report, cache_patch)."""
        handler = getattr(self, f"_report_{rtype}")
        return await handler(params)

    # ---- live reports ------------------------------------------------------

    @staticmethod
    def _controller_facts(dcon: dict) -> list[dict]:
        pairs = (("Device", dcon.get("device")), ("Serial", dcon.get("serial")),
                 ("Last packet", dcon.get("lastPacket")),
                 ("Controller clock", dcon.get("serverTime")),
                 ("Time zone", dcon.get("timeZone")))
        return [{"label": label, "value": value}
                for label, value in pairs if value]

    async def _report_controller(self, params: dict) -> tuple[dict, dict]:
        dcon, valves = await self._dcon_controller()
        facts = self._controller_facts(dcon)
        sections = [vendors.section("facts", "Controller", facts, source="dcon")] \
            if facts else [vendors.section(
                "facts", "Controller", source="dcon",
                note="the controller answered with no readable fields")]
        if valves:
            sections.append(vendors.section(
                "status", "Valves on this controller",
                [{"name": v["name"], "status": "unknown",
                  "meta": v.get("type") or f"valve {v['id']}", "source": "dcon"}
                 for v in valves], source="dcon",
                note="names as programmed on the controller; runtime is a "
                     "separate report"))
        summary = dcon.get("device") or "Controller"
        if valves:
            summary += f" · {len(valves)} valves"
        return self._result("controller", params, sections, summary,
                            [], {"dcon": dcon, "valveNames": valves})

    @staticmethod
    def _electricity_sections(rows: list, err: str) -> list[dict]:
        if err:
            return [vendors.section("metrics", "Electricity", source="dcon",
                                    error=err)]
        if not rows:
            return [vendors.section(
                "metrics", "Electricity", source="dcon",
                note="the controller's last packet carried no readable "
                     "voltage or current")]
        return [vendors.section("metrics", "Electricity", rows, source="dcon")]

    async def _report_electricity(self, params: dict) -> tuple[dict, dict]:
        rows = await self._dcon_now("electricity")
        sections = self._electricity_sections(rows, "")
        summary = " · ".join(f"{r['label']} {r['value']} {r['unit']}".strip()
                             for r in rows) or "no reading"
        return self._result("electricity", params, sections, summary, rows,
                            {"electricity": rows})

    async def _report_pressure(self, params: dict) -> tuple[dict, dict]:
        rows = await self._dcon_now("pressure_cond")
        sections = self._reading_sections("Pressure", rows, "", "dcon")
        stats = vendors.series_stats(rows)
        summary = (f"{stats['last']} {stats.get('unit') or ''}".strip()
                   if stats.get("count") else "no reading")
        return self._result("pressure", params, sections, summary, rows,
                            {"pressure": rows})

    async def _report_live_readings(self, params: dict) -> tuple[dict, dict]:
        """Composite: electricity and pressure, pulled together. Read apart
        they are two numbers; read together they say whether the pump is
        drawing power and producing head."""
        power, power_err = await self._leg(lambda: self._dcon_now("electricity"))
        press, press_err = await self._leg(lambda: self._dcon_now("pressure_cond"))
        sections = (self._electricity_sections(power or [], power_err)
                    + self._reading_sections("Pressure", press or [],
                                             press_err, "dcon"))
        patch = {}
        if power is not None:
            patch["electricity"] = power
        if press is not None:
            patch["pressure"] = press
        bits = [f"{r['label']} {r['value']} {r['unit']}".strip()
                for r in (power or [])]
        stats = vendors.series_stats(press or [])
        if stats.get("count"):
            bits.append(f"pressure {stats['last']} {stats.get('unit') or ''}".strip())
        summary = " · ".join(bits) or "no reading"
        return self._result("live_readings", params, sections, summary,
                            list(power or []) + list(press or []), patch)

    # ---- range reports -----------------------------------------------------

    @staticmethod
    def _valve_sections(rows: list, err: str, window: str) -> list[dict]:
        if err:
            return [vendors.section("bars", "Valve runtime", source="dcon",
                                    error=err)]
        bars = [{"name": v.get("name") or (f"Valve {v['id']}" if v.get("id")
                                           else "Valve"),
                 "value": int(v.get("minutes") or 0),
                 "unit": "min", "status": v.get("status") or "unknown"}
                for v in rows]
        ran = [b for b in bars if b["value"] > 0]
        total = sum(b["value"] for b in ran)
        metrics = [{"label": "Valves run", "value": len(ran), "unit": "",
                    "note": f"of {len(rows)} in {window}" if window
                            else f"of {len(rows)}"},
                   {"label": "Total runtime", "value":
                    vendors.fmt_minutes(total), "unit": "",
                    "note": (f"longest {vendors.fmt_minutes(max(b['value'] for b in ran))}"
                             if ran else "nothing ran")},
                   {"label": "Busiest day", "value":
                    (max((d["value"] for v in rows for d in (v.get("days") or [])),
                         default=0) or 0), "unit": "min",
                    "note": "most any one valve ran in a single day"}]
        out = [vendors.section("metrics", "Valves", metrics, source="dcon")]
        if ran:
            out.append(vendors.section("bars", "Runtime per valve",
                                       sorted(ran, key=lambda b: -b["value"]),
                                       source="dcon"))
        else:
            out.append(vendors.section(
                "status", "Valves",
                [{"name": v.get("name") or "Valve",
                  "status": v.get("status") or "unknown",
                  "meta": v.get("runtime") or "no runtime recorded",
                  "source": "dcon"} for v in rows], source="dcon"))
        return out

    async def _report_valves(self, params: dict) -> tuple[dict, dict]:
        start, end = params["from"], params["to"]
        rows = await self._dcon_valves(start, end)
        sections = self._valve_sections(rows, "", f"{start} → {end}")
        ran = sum(1 for v in rows if int(v.get("minutes") or 0) > 0)
        total = sum(int(v.get("minutes") or 0) for v in rows)
        return self._result(
            "valves", params, sections,
            f"{ran} of {len(rows)} valves ran · {vendors.fmt_minutes(total)} "
            f"· {start} → {end}", rows, {"valves": rows})

    async def _report_timer_log(self, params: dict) -> tuple[dict, dict]:
        return await self._one_log("timer_log", "timer", params)

    async def _report_motor_log(self, params: dict) -> tuple[dict, dict]:
        return await self._one_log("motor_log", "motor", params)

    async def _one_log(self, rtype: str, kind: str,
                       params: dict) -> tuple[dict, dict]:
        start, end = params["from"], params["to"]
        rows = await self._dcon_log(kind, start, end)
        sections = [vendors.section(
            "timeline", f"{kind.capitalize()} log",
            [{**r, "source": kind} for r in rows], source="dcon",
            note="" if rows else f"nothing logged between {start} and {end}")]
        patch = {"timerLog": rows} if kind == "timer" else {"motorLog": rows}
        return self._result(rtype, params, sections,
                            f"{len(rows)} entries · {start} → {end}",
                            rows, patch)

    async def _report_session_log(self, params: dict) -> tuple[dict, dict]:
        """Composite: timer log and motor log woven into one chronology. Read
        separately you cannot see that the motor stopped mid-timer; read
        together that is the first thing you see."""
        start, end = params["from"], params["to"]
        timers, timer_err = await self._leg(
            lambda: self._dcon_log("timer", start, end))
        motors, motor_err = await self._leg(
            lambda: self._dcon_log("motor", start, end))
        merged = vendors.merge_timeline((timers or [], "timer"),
                                        (motors or [], "motor"))
        sections = [vendors.section(
            "metrics", "Entries",
            [{"label": "Timer entries", "value": len(timers or []), "unit": "",
              "note": timer_err or f"{start} → {end}"},
             {"label": "Motor entries", "value": len(motors or []), "unit": "",
              "note": motor_err or f"{start} → {end}"}])]
        if merged:
            sections.append(vendors.section("timeline", "Combined log", merged,
                                            source="dcon"))
        if timer_err:
            sections.append(vendors.section("timeline", "Timer log",
                                            source="dcon", error=timer_err))
        if motor_err:
            sections.append(vendors.section("timeline", "Motor log",
                                            source="dcon", error=motor_err))
        patch = {}
        if timers is not None:
            patch["timerLog"] = timers
        if motors is not None:
            patch["motorLog"] = motors
        return self._result(
            "session_log", params, sections,
            f"{len(merged)} entries · {start} → {end}", merged, patch)

    async def _report_pressure_range(self, params: dict) -> tuple[dict, dict]:
        start, end = params["from"], params["to"]
        rows = await self._dcon_pressure_range(start, end)
        stats = vendors.series_stats(rows)
        sections = self._pressure_sections(rows, "", f"{start} → {end}")
        summary = (f"{stats['min']}–{stats['max']} {stats.get('unit') or ''}"
                   f" · {start} → {end}" if stats.get("count")
                   else f"no readings · {start} → {end}")
        return self._result("pressure_range", params, sections, summary, rows,
                            {"pressure": rows})

    @staticmethod
    def _pressure_sections(rows: list, err: str, window: str) -> list[dict]:
        if err:
            return [vendors.section("series", "Pressure", source="dcon",
                                    error=err)]
        stats = vendors.series_stats(rows)
        if not stats.get("count"):
            return [vendors.section("series", "Pressure", source="dcon",
                                    note=f"no readings in {window}"
                                         if window else "no readings")]
        unit = stats.get("unit") or ""
        metrics = [{"label": "Average", "value": stats["avg"], "unit": unit,
                    "note": f"{stats['count']} readings"},
                   {"label": "Low", "value": stats["min"], "unit": unit,
                    "note": window},
                   {"label": "High", "value": stats["max"], "unit": unit,
                    "note": window}]
        return [vendors.section("metrics", "Pressure", metrics, source="dcon"),
                vendors.section("series", "Pressure over time", rows,
                                source="dcon")]

    async def _report_performance(self, params: dict) -> tuple[dict, dict]:
        """Composite: valve runtime against the pressure over the same window.
        The one question a runtime bar cannot answer on its own is whether the
        line held while the valve was open."""
        start, end = params["from"], params["to"]
        window = f"{start} → {end}"
        valves, valve_err = await self._leg(
            lambda: self._dcon_valves(start, end))
        press, press_err = await self._leg(
            lambda: self._dcon_pressure_range(start, end))
        sections = (self._valve_sections(valves or [], valve_err, window)
                    + self._pressure_sections(press or [], press_err, window))
        patch = {}
        if valves is not None:
            patch["valves"] = valves
        if press is not None:
            patch["pressure"] = press
        total = sum(int(v.get("minutes") or 0) for v in (valves or []))
        stats = vendors.series_stats(press or [])
        bits = [f"{vendors.fmt_minutes(total)} of valve runtime" if total else "",
                (f"pressure {stats['min']}–{stats['max']} "
                 f"{stats.get('unit') or ''}".strip()
                 if stats.get("count") else ""), window]
        return self._result("performance", params, sections,
                            " · ".join(b for b in bits if b),
                            list(valves or []), patch)

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

    async def _purge_queue(self) -> None:
        """Drop whatever is sitting in the queue when reports are switched off.

        The queue is client-writable, and only this runner ever deletes from it.
        With the runner off, a request written by the dashboard stayed there
        forever — two were found in production on 2026-09-23, one of them a day
        old. Nothing would have executed them (they are long stale by the time
        anyone enables reports), so they were pure litter on a path clients can
        append to. One read, one delete, at startup."""
        path = f"{self._cfg.root}/irrigation_requests"
        try:
            existing = await self._rtdb.get(path, shallow=True)
        except Exception:
            _LOGGER.debug("Could not read the irrigation queue to purge it",
                          exc_info=True)
            return
        if not existing:
            return
        try:
            await self._rtdb.put(path, None)
            _LOGGER.info("Reports are off: dropped %d queued request(s) that "
                         "nothing would have answered", len(existing))
        except Exception:
            _LOGGER.warning("Could not clear the irrigation queue")

    async def run(self) -> None:
        if not self.enabled:
            _LOGGER.info("Irrigation reports are disabled; not watching the "
                         "request queue")
            await self._purge_queue()
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
