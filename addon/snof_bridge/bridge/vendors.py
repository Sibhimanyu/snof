"""Vendor response parsers for the irrigation mirror.

The farm's motors and valves live behind three vendor APIs plus OpenWeather
(see the "Mobitech Hack" Postman collection): Livesky (river motor), Niagara
(well-motor controllers) and Mobitech DCON (the MCON irrigation controller:
dashboard, valves, timer/motor logs, electricity and pressure reports).

Everything in here is pure: bytes in, presentation dicts out. No network, no
credentials, no aiohttp — so tests/test_logic.py can import this with nothing
installed. The async fetching lives in irrigation.py; the dashboard only ever
reads the normalized mirror this produces, never a vendor API.

Two deliberate constraints, matching the rest of the bridge:

* Response shapes were captured without saved examples, so every parser is
  defensive: dicts, lists or scalars are all accepted, unknown keys are
  ignored, and anything unrecognised degrades to "unknown" rather than
  raising. Tighten the key lists once live samples are seen, never by
  guessing.
* Vendor payloads carry tokens, FCM ids and URLs. scrub() drops anything that
  looks like a credential before it can reach the mirror, the same way
  mapper.py drops secret-looking attributes.
"""
from __future__ import annotations

import re
from typing import Any

#Saver: vendor payloads are capped before mirroring, the way HA attributes are.
MAX_STR = 255
MAX_LIST = 16

# Key fragments that must never reach the mirror. Mirrors the deny-list in
# mapper.py, extended for the vendor world (FCM tokens, auth headers, URLs).
_SECRET_HINTS = (
    "token", "password", "secret", "auth", "appid", "apikey", "api_key",
    "url", "picture", "mac", "ssid", "imei", "mobile", "usermail",
    "authorization", "session",
)

_ON_TOKENS = {"on", "1", "true", "running", "run", "open", "start", "started"}
_OFF_TOKENS = {"off", "0", "false", "stopped", "stop", "closed", "close", "idle"}


def status_of(value: Any) -> str:
    """Collapse a vendor on/off spelling to on | off | unknown."""
    if isinstance(value, bool):
        return "on" if value else "off"
    if isinstance(value, (int, float)):
        if value == 1:
            return "on"
        if value == 0:
            return "off"
        return "unknown"
    if isinstance(value, str):
        word = value.strip().lower()
        if word in _ON_TOKENS:
            return "on"
        if word in _OFF_TOKENS:
            return "off"
    return "unknown"


def _is_secret_key(key: str) -> bool:
    lowered = key.lower()
    return any(hint in lowered for hint in _SECRET_HINTS)


def scrub(value: Any, depth: int = 0) -> Any:
    """Drop credential-looking keys and cap sizes. Never raises."""
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str) or _is_secret_key(key):
                continue
            out[key[:64]] = scrub(item, depth + 1)
            if len(out) >= 32:
                break
        return out
    if isinstance(value, (list, tuple)):
        return [scrub(item, depth + 1) for item in list(value)[:MAX_LIST]]
    if isinstance(value, str):
        return value[:MAX_STR]
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(value)[:MAX_STR]


def _as_list(payload: Any) -> list[Any]:
    """Vendor endpoints variously return a list, a dict holding a list under
    some key, or a single object. Normalise to a list."""
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("motors", "data", "result", "rows", "items", "list",
                    "controllers", "valves", "nodes", "logs"):
            inner = payload.get(key)
            if isinstance(inner, list):
                return inner
        return [payload]
    return [payload]


def _pick(node: dict, *keys: str, default: Any = None) -> Any:
    for key in keys:
        if key in node and node[key] not in (None, ""):
            return node[key]
    return default


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value)[:MAX_STR]


# ---- Livesky (river motor) -----------------------------------------------

def normalize_livesky(payload: Any) -> list[dict]:
    """getMotors?imei=… → [{ id, name, status, source }]."""
    motors = []
    for raw in _as_list(payload)[:MAX_LIST]:
        if not isinstance(raw, dict):
            continue
        state = _pick(raw, "motor_status", "status", "state", "on_off",
                      "motorState", "run_status")
        motors.append({
            "id": _text(_pick(raw, "imei", "id", "motor_id", "device_id",
                              default="river")),
            "name": _text(_pick(raw, "name", "motor_name", "label",
                                default="River Motor")),
            "status": status_of(state),
            "source": "livesky",
            "detail": _text(_pick(raw, "detail", "remark", "last_update",
                                  "updated_at", default="")),
        })
    return motors


# ---- Niagara (well-motor controllers) -------------------------------------

def normalize_niagara(payload: Any, label: str = "") -> list[dict]:
    """/controller → [{ id, name, status, source }]. One endpoint per cluster,
    so the caller labels each (e.g. "Zone valves" vs "7.5HP well motor")."""
    controllers = []
    for raw in _as_list(payload)[:MAX_LIST]:
        if not isinstance(raw, dict):
            continue
        state = _pick(raw, "status", "state", "controller_status",
                      "motor_status", "on_off", "value")
        controllers.append({
            "id": _text(_pick(raw, "id", "controller_id", "cluster_id",
                              "clusterId", default=label or "well")),
            "name": _text(_pick(raw, "name", "controller_name", "label",
                                default=label or "Well Motor")),
            "status": status_of(state),
            "source": "niagara",
            "detail": _text(_pick(raw, "detail", "zone_type", "zoneType",
                                  "updated_at", default="")),
        })
    return controllers


# ---- Mobitech DCON ---------------------------------------------------------

def normalize_dcon_dashboard(payload: Any) -> dict:
    """action=dashboard → device card + timer summary. Only presentation
    fields are kept; SIM/auth/user-list material is scrubbed, not mirrored."""
    node = payload if isinstance(payload, dict) else {}
    if not node:
        for raw in _as_list(payload)[:1]:
            node = raw if isinstance(raw, dict) else {}
    timers = node.get("timers") if isinstance(node.get("timers"), dict) else {}
    return {
        "device": _text(_pick(node, "device_name", "name", "controller_name",
                              default="Irrigation Controller")),
        "serial": _text(_pick(node, "serial_no", "serial", default="")),
        "gprs": _text(_pick(node, "gprs_status", "gprs", "connectivity",
                            default="")),
        "last": _text(_pick(timers, "last", "last_completed",
                            "lastCompleted", default="")),
        "running": _text(_pick(timers, "running", "current", "currently_running",
                               default="")),
        "next": _text(_pick(timers, "next", "upcoming", "next_scheduled",
                            default="")),
        "extra": scrub({k: v for k, v in node.items()
                        if k not in ("timers",)}) if node else {},
    }


def normalize_dcon_valves(payload: Any) -> list[dict]:
    """get_all_valve → [{ id, name, status, runtime }], newest first when the
    vendor supplies an ordering, capped for the mirror."""
    valves = []
    for raw in _as_list(payload)[:MAX_LIST]:
        if not isinstance(raw, dict):
            continue
        state = _pick(raw, "status", "state", "valve_status", "on_off")
        valves.append({
            "id": _text(_pick(raw, "valve_no", "valve", "id", "node_id",
                              default="")),
            "name": _text(_pick(raw, "valve_name", "name", "label",
                                default="Valve")),
            "status": status_of(state),
            "runtime": _text(_pick(raw, "runtime", "run_time", "duration",
                                   default="")),
        })
    return valves


def normalize_dcon_logs(payload: Any, kind: str = "event") -> list[dict]:
    """timer_log / motor_log → capped [{ at, event, detail }]."""
    logs = []
    for raw in _as_list(payload)[:MAX_LIST]:
        if isinstance(raw, dict):
            logs.append({
                "at": _text(_pick(raw, "at", "time", "date", "datetime",
                                   "timestamp", default="")),
                "event": _text(_pick(raw, "event", "action", "type",
                                      "method", default=kind)),
                "detail": _text(_pick(raw, "detail", "desc", "description",
                                       "message", "name", default="")),
            })
        else:
            logs.append({"at": "", "event": kind, "detail": _text(raw)})
    return logs


def normalize_report(payload: Any, kind: str = "reading") -> list[dict]:
    """reports?type=electricity|pressure_* → capped [{ at, value, unit }]."""
    readings = []
    for raw in _as_list(payload)[:MAX_LIST]:
        if isinstance(raw, dict):
            readings.append({
                "at": _text(_pick(raw, "at", "dt", "time", "date",
                                   "timestamp", default="")),
                "value": _text(_pick(raw, "value", "reading", "data",
                                      "electricity", "pressure", default="")),
                "unit": _text(_pick(raw, "unit", default="")),
            })
        else:
            readings.append({"at": "", "value": _text(raw), "unit": ""})
    return readings


# ---- OpenWeather -------------------------------------------------------------

def normalize_weather(payload: Any) -> dict:
    """api.openweathermap.org → { temp, feels, humidity, desc, wind }."""
    node = payload if isinstance(payload, dict) else {}
    main = node.get("main") if isinstance(node.get("main"), dict) else {}
    wind = node.get("wind") if isinstance(node.get("wind"), dict) else {}
    weather = node.get("weather")
    desc = ""
    if isinstance(weather, list) and weather and isinstance(weather[0], dict):
        desc = _text(_pick(weather[0], "description", "main", default=""))
    return {
        "temp": main.get("temp") if isinstance(main.get("temp"),
                                               (int, float)) else None,
        "feels": main.get("feels_like") if isinstance(main.get("feels_like"),
                                                      (int, float)) else None,
        "humidity": main.get("humidity") if isinstance(main.get("humidity"),
                                                       (int, float)) else None,
        "desc": desc,
        "wind": wind.get("speed") if isinstance(wind.get("speed"),
                                                (int, float)) else None,
    }


# ---- snapshot ------------------------------------------------------------------

def build_snapshot(parts: dict) -> dict:
    """Assemble the /irrigation node. Callers pass whichever sections polled
    cleanly; missing sections stay empty so a dead vendor degrades one card,
    not the page."""
    return {
        "motors": list(parts.get("motors") or [])[:MAX_LIST],
        "controllers": list(parts.get("controllers") or [])[:MAX_LIST],
        "dcon": parts.get("dcon") or {},
        "valves": list(parts.get("valves") or [])[:MAX_LIST],
        "timerLog": list(parts.get("timerLog") or [])[:MAX_LIST],
        "motorLog": list(parts.get("motorLog") or [])[:MAX_LIST],
        "electricity": list(parts.get("electricity") or [])[:MAX_LIST],
        "pressure": list(parts.get("pressure") or [])[:MAX_LIST],
        "weather": parts.get("weather") or {},
        "meta": {
            "sources": parts.get("sources") or {},
            "error": _text(parts.get("error") or ""),
        },
    }


# ---- report sections -------------------------------------------------------
#
# A report is no longer a bag of rows the dashboard has to guess at. Each
# vendor call contributes one or more *sections*, and a section declares how it
# wants to be drawn:
#
#   metrics  [{label, value, unit, note}]        headline numbers
#   status   [{name, status, meta, source}]      on/off board (motors, valves)
#   series   [{at, value, unit}]                 sparkline + min/avg/max
#   bars     [{name, value, unit, status}]       magnitude per row (runtime)
#   timeline [{at, event, detail, source}]       chronological entries
#   facts    [{label, value}]                    key/value card (controller)
#
# The kind is the contract: the dashboard renders by kind and never sniffs
# shapes, so a vendor returning something unexpected loses one section rather
# than producing a chart of nonsense. Unknown kinds are skipped by the
# dashboard, which is why adding one here is safe for old clients.

SECTION_KINDS = ("metrics", "status", "series", "bars", "timeline", "facts")

# Merged sections (a timeline of two logs) may carry more than one vendor
# call's worth of rows, so they get their own, larger cap.
MAX_ROWS = 32


def section(kind: str, title: str, rows: Any = None, note: str = "",
            source: str = "", error: str = "") -> dict:
    """One drawable block of a report. An errored section carries a
    plain-word reason and no rows, so a half-failed composite still renders."""
    return {
        "kind": kind if kind in SECTION_KINDS else "facts",
        "title": _text(title),
        "note": _text(note),
        "source": _text(source),
        "status": "error" if error else "ok",
        "error": _text(error),
        "rows": [scrub(row) for row in list(rows or [])[:MAX_ROWS]],
    }


def number_of(value: Any) -> float | None:
    """Vendor readings arrive as "2.1", "2.1 bar" or 2.1. Pull the number out
    or give up — never guess a zero, which would flatten a chart."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", value)
    return float(match.group(0)) if match else None


def series_stats(rows: Any) -> dict:
    """min / avg / max / last over [{at, value, unit}]. Rows whose value is
    not a number are ignored rather than counted as zero."""
    values, unit = [], ""
    for row in list(rows or []):
        if not isinstance(row, dict):
            continue
        num = number_of(row.get("value"))
        if num is None:
            continue
        values.append(num)
        unit = unit or _text(row.get("unit"))
    if not values:
        return {"count": 0, "unit": unit}
    return {
        "count": len(values),
        "min": round(min(values), 2),
        "max": round(max(values), 2),
        "avg": round(sum(values) / len(values), 2),
        "last": round(values[-1], 2),
        "unit": unit,
    }


def runtime_minutes(value: Any) -> int:
    """"1h 20m" / "80" / 80 -> 80. DCON spells runtimes several ways and the
    bars need one number, so the parsing happens here, once, not in the
    browser."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return max(0, int(value))
    text = str(value or "")
    hours = re.search(r"(\d+)\s*h", text, re.I)
    mins = re.search(r"(\d+)\s*m(?!s)", text, re.I)
    if hours or mins:
        return (int(hours.group(1)) * 60 if hours else 0) + \
               (int(mins.group(1)) if mins else 0)
    colon = re.match(r"^\s*(\d+):(\d{2})", text)
    if colon:
        return int(colon.group(1)) * 60 + int(colon.group(2))
    num = number_of(text)
    return int(num) if num and num > 0 else 0


def fmt_minutes(total: int) -> str:
    if total >= 60:
        hours, mins = divmod(int(total), 60)
        return f"{hours}h {mins}m" if mins else f"{hours}h"
    return f"{int(total)}m"


def merge_timeline(*groups: tuple) -> list[dict]:
    """Interleave several logs into one chronology, newest last, each row
    stamped with where it came from. Vendor timestamps are "YYYY-MM-DD
    HH:MM:SS"-ish, which sorts correctly as text; an entry with no stamp
    sorts to the end rather than being dropped."""
    merged: list[dict] = []
    for rows, source in groups:
        for row in list(rows or []):
            if not isinstance(row, dict):
                continue
            merged.append({**row, "source": _text(source)})
    merged.sort(key=lambda row: (not str(row.get("at") or ""),
                                 str(row.get("at") or "")))
    return merged[:MAX_ROWS]
