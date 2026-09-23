"""Vendor response parsers for the irrigation mirror.

Everything here reads one controller: the Mobitech DCON (MCON) unit that runs
the farm's irrigation — dashboard, valves, timer and motor logs, electricity
and pressure reports. See the "Mobitech Hack" Postman collection.

Livesky (river motor), Niagara (well motors) and OpenWeather were wired here
until 2026-09-23 and were removed at the owner's request: the farm does not
use them. Their parsers, options and report types are gone rather than left
dormant, because a dead code path with a credential slot is worse than no
code path.

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
# Extended on 2026-09-23 after the first live DCON pull: the dashboard payload
# carries the farm's phone book (packets 1/4/8 are SMS recipient lists, "users"
# maps names to mobile numbers, "sim" is the controller's own number) and the
# modem IMEI. None of it is presentation data and all of it reached the mirror
# once before this list grew.
_SECRET_HINTS = (
    "token", "password", "secret", "auth", "appid", "apikey", "api_key",
    "url", "picture", "mac", "ssid", "imei", "mobile", "usermail",
    "authorization", "session", "sim", "packets", "users", "phone",
    "device_id", "contact",
)

# Anything that looks like a phone number or a modem id, wherever it appears.
# The deny-list above is by key; this is by value, because DCON hides numbers
# inside comma-joined packet strings where no key names them.
_DIGIT_RUN = re.compile(r"\b\d{10,}\b")

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
        return _DIGIT_RUN.sub("[redacted]", value)[:MAX_STR]
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return _DIGIT_RUN.sub("[redacted]", str(value))[:MAX_STR]


def _as_list(payload: Any) -> list[Any]:
    """Vendor endpoints variously return a list, a dict holding a list under
    some key, or a single object. Normalise to a list."""
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("data", "log", "result", "rows", "items", "list",
                    "valves", "nodes", "logs"):
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


# ---- Mobitech DCON ---------------------------------------------------------

def normalize_dcon_dashboard(payload: Any) -> dict:
    """action=dashboard -> the controller card, presentation fields only.

    The live shape, seen for the first time on 2026-09-23, is keyed by serial:

        {"MCON874Q000568": {"device_id": ..., "server_time": ...,
                            "sim": ..., "packets": {"live": "##,DCON-...", ...},
                            "users": {...}}}

    Almost none of that is showable. `packets` 1/4/8 are SMS recipient lists,
    `users` maps names to mobile numbers, `sim` is the controller's own number
    and packet 5 carries the modem IMEI. An earlier version of this function
    mirrored a scrubbed copy of the whole node and put eleven phone numbers
    into Firebase. It now returns a fixed set of fields and nothing else — an
    allow-list, like every other export in this bridge.
    """
    node = payload if isinstance(payload, dict) else {}
    serial, inner = "", {}
    for key, value in node.items():
        if isinstance(value, dict) and str(key).upper().startswith("MCON"):
            serial, inner = str(key), value
            break
    if not inner:
        inner = node

    packets = inner.get("packets") if isinstance(inner.get("packets"), dict) else {}
    live = packets.get("live") if isinstance(packets.get("live"), str) else ""
    stamp, name = "", ""
    if live:
        # "##,DCON-<serial>,0-0-0!<timestamp>+05:30,V68,<name>,1,0--,..."
        body = live.split("!", 1)[1] if "!" in live else ""
        fields = [f.strip() for f in body.split(",")]
        for field in fields[:6]:
            if not stamp and re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", field):
                stamp = field[:19]
                continue
            # The name is the one plain word in the head of the packet: not a
            # timestamp, not a Vnn firmware tag, not a number or a flag pair.
            if (not name and field and not re.match(r"^V?\d", field)
                    and re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]{1,40}", field)):
                name = field
    return {
        "device": _text(name or _pick(inner, "device_name", "name",
                                      default="Irrigation Controller")),
        "serial": _text(serial or _pick(inner, "serial_no", "serial", default="")),
        "lastPacket": _text(stamp),
        "serverTime": _text(_pick(inner, "server_time", default="")),
        "timeZone": _text(_pick(inner, "time_zone", default="")),
    }


def normalize_dcon_nodes(payload: Any) -> list[dict]:
    """method=get_node -> the valve registry: [{id, name, type}].

    This is the only place the farm's valve *names* come from — "4 Veg",
    "6 Kulam", "9 Mulberry". get_all_valve reports runtime against numbers, so
    without this a runtime report is a list of integers.
    """
    node = payload if isinstance(payload, dict) else {}
    valves: list[dict] = []
    for key, group in node.items():
        if not isinstance(group, dict) or not str(key).lower().startswith("node"):
            continue
        entries = group.get("valve")
        if not isinstance(entries, dict):
            continue
        for number, valve in entries.items():
            if not isinstance(valve, dict):
                continue
            valves.append({
                "id": _text(number),
                "name": _text(_pick(valve, "valve_name", "name",
                                    default=f"Valve {number}")),
                "type": _text(_pick(valve, "valve_type", default="")),
            })
            if len(valves) >= MAX_LIST:
                return valves
    return valves


def normalize_dcon_valves(payload: Any) -> list[dict]:
    """method=get_all_valve -> [{id, name, type, runtime, minutes, days}].

    The live shape is keyed by valve number, with runtime bucketed per day as
    HH:MM:

        {"action": "get_all_valve",
         "3": {"valve_name": "3 Backwash", "valve_type": "Backwash",
               "runtime": {"2026-09-20": "00:36", "2026-09-21": "00:23"}}}

    So a valve's runtime over a window is the sum of its days, and the daily
    split is worth keeping: "57 minutes" and "19 minutes on each of three
    days" are different facts about a valve.
    """
    node = payload if isinstance(payload, dict) else {}
    valves: list[dict] = []
    for key, entry in node.items():
        if not isinstance(entry, dict) or not str(key).strip().isdigit():
            continue
        per_day = entry.get("runtime") if isinstance(entry.get("runtime"), dict) else {}
        days = []
        total = 0
        for day, spent in list(per_day.items())[:31]:
            minutes = _hhmm_minutes(spent)
            total += minutes
            if minutes:
                days.append({"at": _text(day), "value": minutes, "unit": "min"})
        valves.append({
            "id": _text(key),
            "name": _text(_pick(entry, "valve_name", "name",
                                default=f"Valve {key}")),
            "type": _text(_pick(entry, "valve_type", default="")),
            "minutes": total,
            "runtime": fmt_minutes(total) if total else "",
            "status": "on" if total else "off",
            "days": days[:MAX_LIST],
        })
        if len(valves) >= MAX_LIST:
            break
    return valves


def _hhmm_minutes(value: Any) -> int:
    """DCON reports valve runtime as HH:MM, and "00:36" is 36 minutes, not 36
    hours. Anything else is not a runtime and counts as zero rather than as a
    guess."""
    text = str(value or "").strip()
    match = re.fullmatch(r"(\d{1,3}):(\d{2})", text)
    if not match:
        return 0
    return int(match.group(1)) * 60 + int(match.group(2))


def normalize_dcon_logs(payload: Any, kind: str = "event") -> list[dict]:
    """timer_log / motor_log -> capped [{at, event, detail}].

    A live timer entry carries the timer's name and number, whether it
    completed, how long it ran, and which valves were open:

        {"dt": "2026-09-22 06:44:50", "timer_name": "Grass", "timer_no": "11",
         "completed": "1", "run_time": "00:01-00:30",
         "on_valves": "7-0-0-0-0-0-0-0-0-0"}

    The detail line is assembled from those rather than dumped, because the
    zero-padded valve slots are noise in every entry that has them.
    """
    logs = []
    for raw in _as_list(payload)[:MAX_ROWS]:
        if not isinstance(raw, dict):
            logs.append({"at": "", "event": kind, "detail": _text(raw)})
            continue
        name = _pick(raw, "timer_name", "name", "event", "action", default="")
        number = _pick(raw, "timer_no", "motor_no", default="")
        # A motor row is a day's running total, not an event: three-phase
        # runtime and the energy meter either side of it.
        run3 = _pick(raw, "ph3_runtime", default="")
        if run3:
            start = number_of(_pick(raw, "kilowatt_start", default=""))
            end = number_of(_pick(raw, "kilowatt_end", default=""))
            used = (f"{round(end - start, 2)} kWh"
                    if start is not None and end is not None and end >= start else "")
            logs.append({
                "at": _text(" ".join(str(x) for x in
                                     (_pick(raw, "dt1", default=""),
                                      _pick(raw, "time", default="")) if x)),
                "event": "Motor run",
                "detail": _text(" · ".join(x for x in (f"3-phase {run3}", used) if x)),
            })
            continue
        event = _text(name or f"{kind} {number}".strip() or kind)
        bits = []
        completed = raw.get("completed")
        if completed is not None and str(completed) != "":
            bits.append("completed" if str(completed) == "1" else "did not complete")
        run_time = _pick(raw, "run_time", "on_time", default="")
        if run_time:
            bits.append(f"ran {run_time}")
        valves = [v for v in str(_pick(raw, "on_valves", default="")).split("-")
                  if v and v != "0"]
        if valves:
            bits.append("valve " + ", ".join(valves[:6]))
        if number and name:
            bits.append(f"timer {number}")
        # timer_log stamps a row with "dt"; motor_log splits it into "dt1"
        # (date) and "time". Without joining them a motor row sorts by a bare
        # clock time and lands in the wrong day.
        at = _pick(raw, "dt", "at", "timestamp", default="")
        if not at:
            day, clock = _pick(raw, "dt1", "date", default=""), _pick(raw, "time", default="")
            at = " ".join(str(x) for x in (day, clock) if x)
        logs.append({
            "at": _text(at),
            "event": event,
            "detail": _text(" · ".join(bits)) or _text(
                _pick(raw, "detail", "desc", "description", "message", default="")),
        })
    return logs


def normalize_report(payload: Any, kind: str = "reading") -> list[dict]:
    """reports?type=pressure_cond|pressure_timer -> [{at, value, unit, detail}].

    Live rows are {"dt": ..., "pressure": "2.5-1.7", "flow_rate": "0"}, where
    the pair is inlet and outlet. The series charts the inlet, because that is
    the number that answers "did the line hold"; the outlet and the flow ride
    along as detail rather than being dropped or averaged into a fiction.
    """
    readings = []
    for raw in _as_list(payload)[:MAX_ROWS]:
        if not isinstance(raw, dict):
            readings.append({"at": "", "value": _text(raw), "unit": ""})
            continue
        at = _text(_pick(raw, "dt", "at", "time", "date", "timestamp", default=""))
        pair = str(_pick(raw, "pressure", default="") or "")
        parts = [p for p in pair.split("-") if p.strip()]
        if parts:
            detail = (f"outlet {parts[1]} bar" if len(parts) > 1 else "")
            flow = _pick(raw, "flow_rate", default="")
            if flow not in (None, "", "0"):
                detail = " · ".join(x for x in (detail, f"flow {flow}") if x)
            readings.append({"at": at, "value": _text(parts[0]), "unit": "bar",
                             "detail": _text(detail)})
            continue
        value = _pick(raw, "value", "reading", "electricity", default="")
        if value != "" and value is not None:
            readings.append({"at": at, "value": _text(value),
                             "unit": _text(_pick(raw, "unit", default=""))})
    return readings


# Three numbers joined by hyphens: how DCON writes a per-phase measurement.
_TRIPLE = re.compile(r"^\d{1,3}(?:\.\d+)?(?:-\d{1,3}(?:\.\d+)?){2}$")


def normalize_dcon_electricity(payload: Any) -> list[dict]:
    """reports?type=electricity -> [{label, value, unit, note}] for the newest
    packet.

    Electricity does not come back as readings. It comes back as the raw
    controller packet:

        ##,DCON-<serial>,6-0-0!<ts>+05:30,,225-219-263,384-417-422,
        9.7-9.5-9.6,0.35-0-1.0,...

    Only two of those groups are safely identifiable: a phase-voltage triple
    and a phase-current triple, recognised by shape and by plausible range
    rather than by position, since the packet is undocumented. Everything else
    is left alone — a wrong label on an electrical reading is worse than no
    label.
    """
    rows = _as_list(payload)
    newest = None
    for raw in rows:
        if isinstance(raw, dict) and raw.get("raw_data"):
            newest = raw
    if not newest:
        return []
    packet = str(newest.get("raw_data") or "")
    body = packet.split("!", 1)[1] if "!" in packet else ""
    fields = [f.strip() for f in body.split(",")]
    triples = [f for f in fields if _TRIPLE.match(f)]
    out = []
    for field in triples:
        values = [float(v) for v in field.split("-")]
        if all(90 <= v <= 300 for v in values) and not any(
                r["label"] == "Phase voltage" for r in out):
            out.append({"label": "Phase voltage", "value": " / ".join(field.split("-")),
                        "unit": "V", "note": _text(newest.get("dt") or "")})
        elif all(0 <= v <= 100 for v in values) and not any(
                r["label"] == "Phase current" for r in out):
            out.append({"label": "Phase current", "value": " / ".join(field.split("-")),
                        "unit": "A", "note": _text(newest.get("dt") or "")})
    return out


# ---- snapshot ------------------------------------------------------------------

def build_snapshot(parts: dict) -> dict:
    """Assemble the /irrigation node. Callers pass whichever sections polled
    cleanly; missing sections stay empty so a dead vendor degrades one card,
    not the page."""
    return {
        "dcon": parts.get("dcon") or {},
        "valveNames": list(parts.get("valveNames") or [])[:MAX_LIST],
        "valves": list(parts.get("valves") or [])[:MAX_LIST],
        "timerLog": list(parts.get("timerLog") or [])[:MAX_LIST],
        "motorLog": list(parts.get("motorLog") or [])[:MAX_LIST],
        "electricity": list(parts.get("electricity") or [])[:MAX_LIST],
        "pressure": list(parts.get("pressure") or [])[:MAX_LIST],
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
