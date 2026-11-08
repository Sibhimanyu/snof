"""Mobitech DCON response parsers for the irrigation reports.

Everything here reads one controller: the Mobitech DCON (MCON) unit that runs
the farm's irrigation. It moved here from the NUC add-on on 2026-09-23, when
reports became a Cloud Function (main.py); the parsing did not change home so
much as finally get read against a full set of real payloads.

Everything in here is pure: vendor JSON in, plain dicts out. No network, no
credentials, no Firebase — so tests/test_vendors.py runs with nothing
installed. Fetching is dcon.py; turning parsed rows into a report is
reports.py.

Two constraints, same as the rest of the project:

* **Allow-lists, never dumps.** Every parser names the fields it keeps. The
  dashboard payload carries the farm's phone book and the modem IMEI; an
  earlier parser mirrored "everything else, scrubbed" and put eleven phone
  numbers into Firebase. scrub() is the second line, not the first.
* **Parse everything, cap at the end.** The old parsers capped rows *before*
  aggregating, so a one-day pressure report summarised the first 32 of ~4,000
  samples — about six minutes of the morning. Parsers here return the whole
  response; only reports.section() caps, and only what gets drawn.

What the live payloads actually are (2026-09-23) is written up in
docs/irrigation.md under "Response shapes".
"""
from __future__ import annotations

import datetime as _dt
import re
from typing import Any

MAX_STR = 255
# Lists that reach the mirror. 32, not 16: the farm has 27 valves, and the old
# cap of 16 silently dropped eleven of them from every runtime report.
MAX_LIST = 32

# Key fragments that must never reach the mirror, whatever the parser thought
# it was keeping. See the module docstring for why each vendor word is here.
_SECRET_HINTS = (
    "token", "password", "secret", "auth", "appid", "apikey", "api_key",
    "url", "picture", "mac", "ssid", "imei", "mobile", "usermail",
    "authorization", "session", "sim", "packets", "users", "phone",
    "device_id", "contact",
)

# Anything that looks like a phone number or a modem id, wherever it appears.
# By value, because DCON hides numbers inside comma-joined packet strings
# where no key names them.
_DIGIT_RUN = re.compile(r"\b\d{10,}\b")

_ON_TOKENS = {"on", "1", "true", "running", "run", "open", "start", "started"}
_OFF_TOKENS = {"off", "0", "false", "stopped", "stop", "closed", "close", "idle"}

_STAMP = "%Y-%m-%d %H:%M:%S"


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


# Keys that contain a hint word but hold nothing secret: the date the SIM's
# plan ends (never the SIM's number, which is `sim` and stays out).
_SAFE_KEYS = frozenset({"simexpiry"})


def _is_secret_key(key: str) -> bool:
    lowered = key.lower()
    if lowered in _SAFE_KEYS:
        return False
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
    """DCON answers with a list, a dict holding a list under "data" or "log",
    or a single object. Normalise to a list."""
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("data", "log", "result", "rows", "items", "list"):
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


def parse_stamp(value: Any) -> _dt.datetime | None:
    """ "2026-09-22 06:44:50" -> naive datetime in controller time (+05:30)."""
    try:
        return _dt.datetime.strptime(str(value or "")[:19], _STAMP)
    except ValueError:
        return None


def hhmm_minutes(value: Any) -> int | None:
    """DCON writes durations as HH:MM, and "00:36" is 36 minutes, not 36
    hours. Anything else is not a duration: None, not a guessed zero."""
    match = re.fullmatch(r"(\d{1,3}):(\d{2})", str(value or "").strip())
    if not match:
        return None
    return int(match.group(1)) * 60 + int(match.group(2))


def hdot_minutes(value: Any) -> int | None:
    """The motor log and the electricity packet write hours as HH.MM —
    "22.51" is 22 h 51 m, not 22.51 hours."""
    match = re.fullmatch(r"(\d{1,2})\.(\d{2})", str(value or "").strip())
    if not match or int(match.group(2)) > 59:
        return None
    return int(match.group(1)) * 60 + int(match.group(2))


def number_of(value: Any) -> float | None:
    """ "2.1", "2.1 bar" or 2.1 -> 2.1. Never a guessed zero."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", value)
    return float(match.group(0)) if match else None


def fmt_minutes(total: float) -> str:
    total = int(round(total or 0))
    if total >= 60:
        hours, mins = divmod(total, 60)
        return f"{hours}h {mins}m" if mins else f"{hours}h"
    return f"{total}m"


def runtime_minutes(value: Any) -> int:
    """ "1h 20m" / "01:20" / "80" / 80 -> 80, for the odd vendor spelling."""
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


def _slots(value: Any) -> list[str]:
    """ "4-6-0-0-0-0-0-0-0-0" -> ["4", "6", "0", ...]. Ten zero-padded slots."""
    return [s.strip() for s in str(value or "").split("-")]


# ---- dashboard / get_node -------------------------------------------------

def _dashboard_node(payload: Any) -> tuple[str, dict]:
    """action=dashboard is keyed by serial: {"MCON000DEMO01": {...}}."""
    node = payload if isinstance(payload, dict) else {}
    for key, value in node.items():
        if isinstance(value, dict) and str(key).upper().startswith("MCON"):
            return str(key), value
    # A serial spelled some other way: the one child that carries packets.
    for key, value in node.items():
        if isinstance(value, dict) and "packets" in value:
            return str(key), value
    return "", node


def normalize_dcon_dashboard(payload: Any) -> dict:
    """action=dashboard -> the controller card: five named fields, nothing else.

    `packets` 1/4/8 are SMS recipient lists, `users` maps names to mobile
    numbers, `sim` is the controller's own number, packet 5 carries the modem
    IMEI. None of it is presentation data. The device name lives inside the
    `live` packet, not under any key.
    """
    serial, inner = _dashboard_node(payload)
    packets = inner.get("packets") if isinstance(inner.get("packets"), dict) else {}
    live = packets.get("live") if isinstance(packets.get("live"), str) else ""
    stamp, name = "", ""
    if live:
        # "##,DCON-<serial>,0-0-0!<timestamp>+05:30,V68,<name>,1,0--,..."
        body = live.split("!", 1)[1] if "!" in live else ""
        for field in [f.strip() for f in body.split(",")][:6]:
            if not stamp and re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", field):
                stamp = field[:19]
                continue
            # The one plain word in the head of the packet: not a timestamp,
            # not a Vnn firmware tag, not a number or a flag pair.
            if (not name and field and not re.match(r"^V?\d", field)
                    and re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]{1,40}", field)):
                name = field
    # Also an allow-list: the firmware tag from the live packet (V68), the date
    # the SIM's plan ends, and whether the emergency shutdown is on. Never the
    # SIM's number (`sim`), never the packets.
    firmware = ""
    if live and "!" in live:
        for field in [f.strip() for f in live.split("!", 1)[1].split(",")][:6]:
            if re.fullmatch(r"V\d+(\.\d+)*", field):
                firmware = field
                break
    expiry = _text(inner.get("expiry_dt") or "")
    shutdown = any(str(inner.get(k)) == "1" for k in
                   ("emergency_shutdown_state", "emergency_shutdown_status"))
    return {
        "firmware": firmware,
        "simExpiry": expiry if re.fullmatch(r"\d{4}-\d{2}-\d{2}", expiry) else "",
        "shutdown": shutdown,
        "device": _text(name or _pick(inner, "device_name", "name",
                                      default="Irrigation Controller")),
        "serial": _text(serial or _pick(inner, "serial_no", "serial", default="")),
        "lastPacket": _text(stamp),
        "serverTime": _text(_pick(inner, "server_time", default="")),
        "timeZone": _text(_pick(inner, "time_zone", default="")),
    }


def dcon_program(entry: Any) -> dict | None:
    """One timer record, from the dashboard's `timers.current/previous` or a
    timer_log row, reduced to what a person reads. Shared by both, because
    they are the same record in two places."""
    if not isinstance(entry, dict):
        return None
    remaining, _, planned = str(entry.get("run_time") or "").partition("-")
    valves = [v for v in _slots(entry.get("on_valves")) if v and v != "0"]
    return {
        "name": _text(entry.get("timer_name") or "Timer"),
        "kind": timer_kind(entry.get("timer_type")),
        "number": _text(entry.get("timer_no") or ""),
        "valves": valves[:10],
        "start": _text(_pick(entry, "dt", "time", default="")),
        "lastSeen": _text(_pick(entry, "last_sync", "time_end", default="")),
        "plannedMin": hhmm_minutes(planned),
        "remainingMin": hhmm_minutes(remaining),
        "completed": str(entry.get("completed")) == "1",
        "startedBy": _text(entry.get("start_control") or "").strip(),
        "endedBy": _text(entry.get("end_control") or "").strip(),
    }


def program_faults(entry: Any) -> list[tuple[str, str]]:
    """[(valve id, "no signal" | "did not open" | "did not close")] for one
    timer record: the three flag lists line up slot for slot with on_valves."""
    if not isinstance(entry, dict):
        return []
    on = _slots(entry.get("on_valves"))
    out = []
    for field, label in (("valve_comm_error", "no signal"),
                         ("valve_not_on", "did not open"),
                         ("valve_not_off", "did not close")):
        for i, flag in enumerate(_slots(entry.get(field))):
            if flag not in ("", "0") and i < len(on) and on[i] not in ("", "0"):
                out.append((on[i], label))
    return out


def dcon_next(entry: Any) -> dict | None:
    """timers.next: the program the controller will start next. A smaller
    record than current — valves under `valves`, the length as `on_time`."""
    if not isinstance(entry, dict) or not entry.get("timer_name"):
        return None
    valves = [v for v in _slots(entry.get("valves") or entry.get("on_valves")) if v and v != "0"]
    return {"name": _text(entry.get("timer_name")), "number": _text(entry.get("timer_no") or ""),
            "valves": valves[:10], "plannedMin": hhmm_minutes(entry.get("on_time"))}


_DAY_NAMES = {"1": "Mon", "2": "Tue", "3": "Wed", "4": "Thu", "5": "Fri", "6": "Sat", "7": "Sun"}


def normalize_programs(payload: Any) -> dict:
    """action=dcon_timer&method=select -> {"<no>": {number, name, valves,
    start, duration, days, enabled}}, an allow-list of the record.

    Found in the capture (2026-09-24, docs/mobitech-app.md): `on_time` is the
    program's DURATION (HH:MM; "01:00" for Coconut, whose command is
    ET01-002-01 00); `off_time` is "00:00" on all 25 programs and means
    nothing; `data` is empty. There is no start time in the record at all:
    this controller chains its programs (timers.next), so `start` is "".
    `on_days` is "0" on every program and is read as "no day rule": days is ""
    unless it spells weekdays 1-7, which has never been seen.
    """
    group = payload.get("1") if isinstance(payload, dict) else None
    out: dict[str, dict] = {}
    for key, rec in (group.items() if isinstance(group, dict) else []):
        if not isinstance(rec, dict) or not str(key).isdigit():
            continue
        minutes = hhmm_minutes(rec.get("on_time"))
        digits = [d for d in re.split(r"[^0-9]+", str(rec.get("on_days") or "")) if d]
        days = ",".join(_DAY_NAMES[d] for d in digits) if digits and all(d in _DAY_NAMES for d in digits) else ""
        out[str(int(key))] = {
            "number": int(key),
            "name": _text(rec.get("group_name") or f"Program {int(key)}")[:40],
            "valves": [int(v) for v in _slots(rec.get("valve_details")) if v.isdigit() and int(v)][:10],
            "start": "",
            "duration": f"{minutes // 60:02d}:{minutes % 60:02d}" if minutes else "",
            "days": days,
            "enabled": str(rec.get("timer_status")) == "1",
        }
    return out


def normalize_rain(payload: Any) -> dict:
    """/v1/weather/cumulative/?type=rain -> millimetres, four named numbers."""
    src = payload if isinstance(payload, dict) else {}

    def mm(*keys):
        for k in keys:
            n = number_of(src.get(k))
            if n is not None:
                return round(n, 1)
        return 0.0
    return {"today": mm("today"), "last24h": mm("last24hrs", "last24h"),
            "yesterday": mm("yesterday"), "week": mm("week")}


def dcon_timers(payload: Any) -> dict:
    """The dashboard's "what is it doing" block: the program running now,
    the one before it, and the next one (null until 2026-09-24, then set)."""
    _, inner = _dashboard_node(payload)
    timers = inner.get("timers") if isinstance(inner.get("timers"), dict) else {}
    return {"current": dcon_program(timers.get("current")),
            "previous": dcon_program(timers.get("previous")),
            "next": dcon_next(timers.get("next")),
            "faults": program_faults(timers.get("current"))}


def dashboard_electricity(payload: Any) -> dict:
    """Packet 6 of the dashboard is the same live electricity packet the
    electricity report returns, so one dashboard call answers "is the power
    there and is the pump drawing" without a second one."""
    _, inner = _dashboard_node(payload)
    packets = inner.get("packets") if isinstance(inner.get("packets"), dict) else {}
    packet = packets.get("6")
    if not isinstance(packet, str) or "!" not in packet:
        return {}
    stamp = re.search(r"!(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", packet)
    if not stamp:
        return {}
    return electricity_packet({"data": [{"dt": stamp.group(1), "raw_data": packet}]})


def normalize_dcon_nodes(payload: Any) -> list[dict]:
    """method=get_node -> the valve registry: [{id, name, type, node}].

    The only place the farm's valve *names* come from ("4 Veg", "9 Mulberry").
    Three field nodes hold 27 valves; get_all_valve reports against numbers.
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
                "node": _text(key),
            })
    valves.sort(key=lambda v: int(v["id"]) if v["id"].isdigit() else 999)
    return valves[:MAX_LIST]


# ---- get_all_valve ----------------------------------------------------------

def normalize_dcon_valves(payload: Any) -> list[dict]:
    """method=get_all_valve -> [{id, name, type, minutes, runtime, status, days}].

    Keyed by valve number, runtime bucketed per day as HH:MM:

        {"3": {"valve_name": "3 Backwash", "valve_type": "Backwash",
               "runtime": {"2026-09-20": "00:36", "2026-09-21": "00:23"}}}

    A window's runtime is the sum of its days; the days are kept, because
    "57 minutes" and "19 minutes on each of three days" are different facts.
    """
    node = payload if isinstance(payload, dict) else {}
    valves: list[dict] = []
    for key, entry in node.items():
        if not isinstance(entry, dict) or not str(key).strip().isdigit():
            continue
        per_day = entry.get("runtime") if isinstance(entry.get("runtime"), dict) else {}
        days, total = [], 0
        for day, spent in sorted(per_day.items())[:31]:
            minutes = hhmm_minutes(spent) or 0
            total += minutes
            days.append({"at": _text(day), "value": minutes, "unit": "min"})
        valves.append({
            "id": _text(key),
            "name": _text(_pick(entry, "valve_name", "name",
                                default=f"Valve {key}")),
            "type": _text(_pick(entry, "valve_type", default="")),
            "minutes": total,
            "runtime": fmt_minutes(total) if total else "",
            "status": "on" if total else "off",
            "days": days,
        })
    valves.sort(key=lambda v: int(v["id"]))
    return valves[:MAX_LIST]


# ---- timer_log -----------------------------------------------------------------
#
# A timer_log row is not a run. It is one *segment* of a run, and its
# run_time is "remaining-planned" as of that segment's last sync, not
# "ran-planned". The controller pauses every program for a three-minute
# filter backwash roughly every fifteen minutes and logs the pieces
# separately, so one hour of Coconut is six rows:
#
#   08:58  Coconut   00:50-01:00      09:09  Backwash  00:01-00:03
#   09:13  Coconut   00:36-01:00      09:28  Backwash  00:01-00:03
#   ...
#   10:20  Coconut   00:01-01:00  completed
#
# Read one row at a time, that looks like six failed timers. join_runs()
# stitches them back into one run.

TIMER_KINDS = {"1": "Program", "3": "Manual", "4": "Backwash"}

# What start_control codes mean, only where the log itself says so: TM rows
# are always named timer programs, MM rows are always "Manual Mode" or the
# backwash it triggers. A8, R1, U8, PRH… are shown as the controller spells
# them rather than guessed at.
CONTROL_CODES = {"TM": "timer", "MM": "manual"}


def timer_kind(value: Any) -> str:
    code = str(value or "").strip()
    return TIMER_KINDS.get(code, f"Type {code}" if code else "Timer")


def timer_segments(payload: Any) -> list[dict]:
    """timer_log -> every segment, oldest first, with its logged span."""
    out = []
    for raw in _as_list(payload):
        prog = dcon_program(raw)
        if not prog:
            continue
        start, seen = parse_stamp(prog["start"]), parse_stamp(prog["lastSeen"])
        span = ((seen - start).total_seconds() / 60.0
                if start and seen and seen >= start else 0.0)
        faults = [f"valve {v} {label}" for v, label in program_faults(raw)]
        out.append({**prog, "spanMin": round(span, 1), "faults": faults})
    out.sort(key=lambda s: s["start"])
    return out


def join_runs(segments: list[dict], max_gap_min: float = 45.0) -> list[dict]:
    """Stitch timer segments into runs: same program, same valves, same
    planned length, remaining time counting down, no long gap between. A
    backwash that falls inside a run is counted against it, not listed as a
    run of its own."""
    runs: list[dict] = []
    open_run: dict | None = None
    for seg in segments:
        if seg["kind"] == "Backwash":
            if open_run is not None:
                open_run["backwashes"] += 1
            continue
        start = parse_stamp(seg["start"])
        key = (seg["kind"], seg["name"], seg["number"], tuple(seg["valves"]),
               seg["plannedMin"])
        if open_run is not None:
            last = parse_stamp(open_run["end"])
            gap = ((start - last).total_seconds() / 60.0
                   if start and last else 1e9)
            counting_down = (seg["remainingMin"] is None
                             or open_run["remainingMin"] is None
                             or seg["remainingMin"] <= open_run["remainingMin"] + 1)
            if open_run["_key"] == key and gap <= max_gap_min and counting_down:
                open_run.update(end=seg["lastSeen"] or open_run["end"],
                                remainingMin=seg["remainingMin"],
                                completed=seg["completed"],
                                endedBy=seg["endedBy"] or open_run["endedBy"])
                open_run["segments"] += 1
                open_run["faults"] = list(dict.fromkeys(open_run["faults"] + seg["faults"]))
                continue
        open_run = {"_key": key, "name": seg["name"], "kind": seg["kind"],
                    "number": seg["number"], "valves": seg["valves"],
                    "start": seg["start"], "end": seg["lastSeen"] or seg["start"],
                    "plannedMin": seg["plannedMin"],
                    "remainingMin": seg["remainingMin"],
                    "completed": seg["completed"], "startedBy": seg["startedBy"],
                    "endedBy": seg["endedBy"], "segments": 1, "backwashes": 0,
                    "faults": list(seg["faults"])}
        runs.append(open_run)
    for run in runs:
        run.pop("_key", None)
        planned, left = run["plannedMin"], run["remainingMin"]
        # The controller's own countdown, not the wall clock: the wall clock
        # includes every backwash pause.
        run["deliveredMin"] = (max(0, planned - (left or 0))
                               if planned is not None else None)
        # One minute left on the counter is how a finished run reads here.
        run["finished"] = bool(run["completed"] or (left is not None and left <= 1))
    return runs


def backwash_stats(segments: list[dict]) -> dict:
    washes = [s for s in segments if s["kind"] == "Backwash"]
    return {"count": len(washes),
            "minutes": round(sum(s["spanMin"] for s in washes), 1)}


# ---- motor_log --------------------------------------------------------------

def motor_days(payload: Any) -> list[dict]:
    """motor_log -> one row per day: power-on time, pump time, energy.

        {"dt1": "2026-09-07", "time": "23:59:03", "ph3_runtime": "20.53-20.53",
         "kilowatt_start": "25429.43", "kilowatt_end": "25517.80"}

    ph3_runtime is two HH.MM durations: how long three-phase supply was
    present that day, then how long the pump ran on it. Read that way the
    numbers agree with each other — the second never exceeds the first, a day
    with 00.00 pump time used 0.0 kWh, and kWh over pump hours is a steady
    ~4.2 kW every day, one pump's draw. The meter was reset on 2026-09-10
    (25678 -> 171); a day whose end is below its start has no usable energy
    figure, so it gets None rather than a negative one.
    """
    days = []
    for raw in _as_list(payload):
        if not isinstance(raw, dict) or not raw.get("dt1"):
            continue
        supply, _, pump = str(raw.get("ph3_runtime") or "").partition("-")
        start = number_of(raw.get("kilowatt_start"))
        end = number_of(raw.get("kilowatt_end"))
        kwh = (round(end - start, 2)
               if start is not None and end is not None and end >= start else None)
        days.append({"day": _text(raw.get("dt1"))[:10],
                     "through": _text(raw.get("time") or ""),
                     "supplyMin": hdot_minutes(supply),
                     "pumpMin": hdot_minutes(pump),
                     "kwh": kwh,
                     "meterReset": start is not None and end is not None and end < start})
    days.sort(key=lambda d: d["day"])
    return days


# ---- reports?type=pressure_cond | pressure_timer ---------------------------------

def pressure_points(payload: Any) -> list[dict]:
    """-> [{at, inlet, outlet}], oldest first, every row.

    Rows are {"dt": ..., "pressure": "2.5-1.7", "flow_rate": "0"}: the pair is
    inlet and outlet across the filter, and the gap between them is how
    clogged it is. flow_rate has been "0" in every one of ~32,000 rows seen —
    there is no flow meter on this controller — so it is not reported.

    The controller only logs while the pump runs (4,164 samples on 2026-09-22
    at ~11.6 s apart is 13.4 h; the motor log says the pump ran 13 h 27 m), so
    a gap in this series means the pump was off, not that the line dropped.
    """
    points = []
    for raw in _as_list(payload):
        if not isinstance(raw, dict):
            continue
        at = _text(raw.get("dt"))[:19]
        parts = str(raw.get("pressure") or "").split("-")
        inlet = number_of(parts[0]) if parts and parts[0].strip() else None
        outlet = number_of(parts[1]) if len(parts) > 1 and parts[1].strip() else None
        if at and inlet is not None:
            points.append({"at": at, "inlet": inlet, "outlet": outlet})
    points.sort(key=lambda p: p["at"])
    return points


# ---- reports?type=electricity -------------------------------------------------

_TRIPLE = re.compile(r"^\d{1,3}(?:\.\d+)?(?:-\d{1,3}(?:\.\d+)?){2}$")
_HDOT_PAIR = re.compile(r"^\d{2}\.\d{2}-\d{2}\.\d{2}$")


def electricity_packet(payload: Any) -> dict:
    """reports?type=electricity -> the newest packet, labelled where safe.

    It comes back as a raw, undocumented controller packet:

        ##,DCON-<serial>,6-0-0!2026-09-23 22:04:00+05:30,,255-249-264,
        436-443-448,0.0-0.0-0.0,1.0-0-1.0,17.47-16.21,00.00-00.00,50.0,20,
        693.70,0.0,4.214-100,0.0,00000-00,

    Each label below is earned by shape plus a cross-check, never by
    position alone:

      * phase voltage — a triple, all 90–300 V;
      * line voltage — a triple whose mean is √3 × the phase mean (±10%),
        which is what line-to-line voltage is on a three-phase supply;
      * phase current — a triple, all 0–100, after the voltages are taken;
      * supply / pump time today — an HH.MM-HH.MM pair, the same field and
        value the motor log carries as ph3_runtime for today;
      * meter — the one field equal to today's motor-log kilowatt_end, and
        only when the caller passes that in to check against.

    Everything else (a lone 50.0, 20, 4.214-100…) stays unlabelled: a wrong
    label on an electrical reading is worse than none.
    """
    rows = [r for r in _as_list(payload) if isinstance(r, dict) and r.get("raw_data")]
    if not rows:
        return {}
    newest = max(rows, key=lambda r: str(r.get("dt")))
    fields = _packet_fields(newest)
    out: dict[str, Any] = {"at": _text(newest.get("dt"))[:19], "fields": fields}
    out.update(_read_packet(fields, _classify(fields)))
    return out


def _packet_fields(raw: dict) -> list[str]:
    packet = str(raw.get("raw_data") or "")
    body = packet.split("!", 1)[1] if "!" in packet else ""
    return [f.strip() for f in body.split(",")]


def _triple(field: str) -> list[float] | None:
    return [float(v) for v in field.split("-")] if _TRIPLE.match(field or "") else None


def _classify(fields: list[str]) -> dict[str, int]:
    """Which field index holds what, in one packet, by the rules above."""
    triples = [(i, _triple(f)) for i, f in enumerate(fields)]
    triples = [(i, t) for i, t in triples if t]
    found: dict[str, int] = {}
    phase = next(((i, t) for i, t in triples if all(90 <= v <= 300 for v in t)), None)
    if phase:
        found["phaseV"] = phase[0]
        mean = sum(phase[1]) / 3
        line = next((i for i, t in triples if i != phase[0]
                     and abs(sum(t) / 3 - mean * 3 ** 0.5) <= mean * 3 ** 0.5 * 0.1), None)
        if line is not None:
            found["lineV"] = line
    taken = set(found.values())
    current = next((i for i, t in triples if i not in taken
                    and all(0 <= v <= 100 for v in t)), None)
    if current is not None and "phaseV" in found:
        found["currentA"] = current
    pair = next((i for i, f in enumerate(fields) if _HDOT_PAIR.match(f)), None)
    if pair is not None:
        found["pair"] = pair
    return found


def _read_packet(fields: list[str], where: dict[str, int]) -> dict:
    out: dict[str, Any] = {}
    for key in ("phaseV", "lineV", "currentA"):
        i = where.get(key)
        if i is not None and i < len(fields) and _triple(fields[i]):
            out[key] = _triple(fields[i])
    i = where.get("pair")
    if i is not None and i < len(fields) and _HDOT_PAIR.match(fields[i]):
        supply, _, pump = fields[i].partition("-")
        out["supplyMin"], out["pumpMin"] = hdot_minutes(supply), hdot_minutes(pump)
    return out


def electricity_series(payload: Any, start: str = "", end: str = "") -> list[dict]:
    """reports?type=electricity with a `dt` in the past -> every packet from
    then to now, about one a minute, oldest first, filtered to [start, end].

    A packet taken during a supply cut reads 0-0-0 where the voltages were,
    which the shape rules would call a current. So the positions are learned
    from the packets that do pass the rules — the index most of them agree
    on — and then read by position in every packet, the cut ones included.
    """
    rows = [r for r in _as_list(payload) if isinstance(r, dict) and r.get("raw_data")]
    parsed = [(str(r.get("dt") or "")[:19], _packet_fields(r)) for r in rows]
    parsed = [(at, f) for at, f in parsed if at]
    # Positions are learned from every packet returned, then the window is
    # applied: a window that sits inside a cut has nothing to learn from.
    votes: dict[str, dict[int, int]] = {}
    for _, fields in parsed:
        for key, i in _classify(fields).items():
            votes.setdefault(key, {}).setdefault(i, 0)
            votes[key][i] += 1
    where = {}
    for key, tally in votes.items():
        i, n = max(tally.items(), key=lambda kv: kv[1])
        if n * 2 >= len(parsed):
            where[key] = i
    out = [{"at": at, **_read_packet(fields, where)} for at, fields in parsed
           if (not start or at >= start) and (not end or at <= end)]
    out.sort(key=lambda r: r["at"])
    return out


def meter_from_packet(packet: dict, expected_kwh: float | None) -> float | None:
    """The cumulative kWh meter, only if a packet field equals the value the
    motor log independently reports for today."""
    if expected_kwh is None:
        return None
    for field in packet.get("fields") or []:
        num = number_of(field) if re.fullmatch(r"\d+\.\d{2}", field or "") else None
        if num is not None and abs(num - expected_kwh) < 0.01:
            return num
    return None


# ---- aggregation --------------------------------------------------------------

def series_stats(values: list[float]) -> dict:
    vals = [v for v in values if v is not None]
    if not vals:
        return {"count": 0}
    return {"count": len(vals), "min": round(min(vals), 2),
            "max": round(max(vals), 2),
            "avg": round(sum(vals) / len(vals), 2), "last": round(vals[-1], 2)}


def bucket(points: list[dict], field: str, hours: int) -> list[dict]:
    """Average `field` into fixed windows of `hours`, oldest first, as series
    rows. Empty windows are skipped rather than drawn as zero: no samples
    means the pump was off, not that the pressure was nothing."""
    groups: dict[str, list[float]] = {}
    for p in points:
        stamp, value = parse_stamp(p.get("at")), p.get(field)
        if stamp is None or value is None:
            continue
        if hours >= 24:
            label = stamp.strftime("%Y-%m-%d")
        else:
            label = stamp.replace(hour=stamp.hour - stamp.hour % hours, minute=0,
                                  second=0).strftime("%Y-%m-%d %H:%M")
        groups.setdefault(label, []).append(value)
    return [{"at": at, "value": round(sum(v) / len(v), 2)}
            for at, v in sorted(groups.items())]


def bucket_multi(points: list[dict], fields: tuple, minutes: int) -> list[dict]:
    """Average several fields into windows of `minutes`, oldest first. Each
    row carries the window's start and one average per field; a field with no
    readings in the window is left out rather than drawn as zero."""
    groups: dict[str, list[dict]] = {}
    for p in points:
        stamp = parse_stamp(p.get("at"))
        if stamp is None:
            continue
        since = stamp.hour * 60 + stamp.minute
        since -= since % minutes if minutes < 1440 else since
        label = stamp.replace(hour=since // 60, minute=since % 60, second=0)
        groups.setdefault(label.strftime("%Y-%m-%d %H:%M"), []).append(p)
    rows = []
    for at, members in sorted(groups.items()):
        row: dict[str, Any] = {"at": at}
        for field in fields:
            vals = [m[field] for m in members if m.get(field) is not None]
            if vals:
                row[field] = round(sum(vals) / len(vals), 2)
        rows.append(row)
    return rows


def bucket_minutes(span_minutes: float, max_points: int = 96) -> int:
    """Window so a span fits max_points: an hour -> 1 min, a day -> 15 min,
    a week -> 2 h."""
    for minutes in (1, 2, 5, 10, 15, 30, 60, 120, 180, 360, 720, 1440):
        if span_minutes / minutes <= max_points:
            return minutes
    return 1440


def extreme(points: list[dict], field: str, pick=min) -> dict | None:
    """The reading at the lowest (or highest) value of `field`, so a report
    can say *when* as well as how much."""
    have = [p for p in points if p.get(field) is not None]
    return pick(have, key=lambda p: p[field]) if have else None


def bucket_hours(days: int, max_points: int = 32) -> int:
    """Window size so a range fits in max_points: 1 day -> hourly, a week ->
    6-hourly, a month -> daily."""
    for hours in (1, 2, 3, 4, 6, 8, 12, 24):
        if days * 24 / hours <= max_points:
            return hours
    return 24
