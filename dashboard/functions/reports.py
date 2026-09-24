"""Irrigation reports: validated request in, drawable report out.

A controller on the dashboard (or the iOS app) appends a request to
/farms/<slug>/irrigation_requests. main.py hands it here; this module checks
it, makes the one to three controller calls that report needs through a
`source` (dcon.py in production, a fake in tests), and returns the report
plus the patch for the /irrigation last-results cache.

Pure apart from the source: no Firebase, no network, no credentials. That is
what lets tests/test_reports.py exercise every report with nothing installed.

Until 2026-09-23 this ran on the NUC inside the Home Assistant add-on. It
moved to a Cloud Function so reports no longer depend on the farm's
internet, the NUC being up, or an add-on deploy to change — and so the DCON
token no longer sits in add-on options on a box in a shed.

Deliberately read-only. The DCON API has command endpoints (/v1/command/,
valve ON/OFF); dcon.py has no way to reach them and validate() refuses any
type not listed here. Operating a pump from a browser is a separate security
decision, the same class as cover/lock.

How a report is drawn is the section contract in docs/irrigation.md: each
section declares a kind — metrics, status, series, bars, timeline, facts —
and the dashboard draws by kind and never sniffs shapes.
"""
from __future__ import annotations

import datetime as _dt
import re
import time
from typing import Any, Callable

import vendors as V

# A request left in the queue longer than this is dropped, not run.
REQUEST_MAX_AGE_SECONDS = 300.0

# Ranges are user-chosen; cap them so a typo cannot ask for a decade. A
# month of pressure is ~32,000 samples, ~2 MB, about two seconds.
MAX_RANGE_DAYS = 31

# The controller's clock. Cloud Functions run in UTC; every DCON stamp, and
# every date a person picks on the dashboard, is farm time.
FARM_TZ = _dt.timezone(_dt.timedelta(hours=5, minutes=30))

# The controller answers a snapshot query with the samples at or after `dt`,
# one every ~11 s, so asking for the current second returns nothing. Ask for
# the last few minutes and take the newest.
SNAPSHOT_LOOKBACK = _dt.timedelta(minutes=5)

# Rows a section may carry. The dashboard shows eight and says how many more.
MAX_ROWS = 32
# A line chart is points, not rows a person reads one by one: a day at
# 15-minute resolution is 96 of them.
MAX_POINTS = 96
# Columns of a matrix section: one per day of the longest allowed range.
MAX_COLS = 32

SERVER_TIMESTAMP = {".sv": "timestamp"}

# Type -> "range" (needs from/to) or "live" (no params). Names are the RTDB
# rule's allow-list and the dashboard's and iOS app's builder values; renaming
# one is a three-client change.
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
    "power_range": "range",
    "pressure_hour": "live",
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
    "power_range": "Power over time",
    "pressure_hour": "Pressure, last hour",
}

# Valve types that deliver water to a crop. Backwash, the master valve, the
# fertiliser tank and the booster pump are plumbing, and counting their
# minutes as irrigation would double every total.
IRRIGATION_TYPES = {"irrigation"}

_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")


class Refused(ValueError):
    """A request not worth running. The message is shown to nobody but the
    log; the request is deleted either way."""


def farm_now() -> _dt.datetime:
    return _dt.datetime.now(FARM_TZ).replace(tzinfo=None)


def _parse_date(value: Any) -> _dt.date | None:
    """Strict YYYY-MM-DD, and a real calendar date, not month 13."""
    if not isinstance(value, str):
        return None
    match = _DATE_RE.match(value.strip())
    if not match:
        return None
    try:
        return _dt.date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    except ValueError:
        return None


def validate(req: Any, now_s: float | None = None) -> tuple[str, dict]:
    """Return (report_type, params) or raise Refused. Mirrors the RTDB rule,
    which is the first gate; this is the second, and the one that also knows
    the clock and the range cap."""
    if not isinstance(req, dict):
        raise Refused("not an object")
    rtype = req.get("type")
    if not isinstance(rtype, str) or rtype not in REPORT_TYPES:
        raise Refused(f"unknown report type {rtype!r}")
    at = req.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        raise Refused("no timestamp")
    age = (time.time() if now_s is None else now_s) - at / 1000.0
    if age > REQUEST_MAX_AGE_SECONDS or age < -60:
        raise Refused(f"stale by {age:.0f}s")
    params: dict[str, str] = {}
    if REPORT_TYPES[rtype] == "range":
        start, end = _parse_date(req.get("from")), _parse_date(req.get("to"))
        if start is None or end is None:
            raise Refused("from/to must be YYYY-MM-DD dates")
        if end < start:
            raise Refused("to is before from")
        if (end - start).days > MAX_RANGE_DAYS:
            raise Refused(f"range over {MAX_RANGE_DAYS} days")
        # The electricity call returns everything from `from` up to *now*,
        # whatever `to` says, so an old start costs a month of packets.
        if rtype == "power_range" and (farm_now().date() - start).days > MAX_RANGE_DAYS:
            raise Refused(f"power_range starts over {MAX_RANGE_DAYS} days ago")
        params = {"from": start.isoformat(), "to": end.isoformat()}
    return rtype, params


# ---- building blocks -----------------------------------------------------------

def section(kind: str, title: str, rows: Any = None, note: str = "",
            source: str = "dcon", error: str = "", unit: str = "",
            legend: list[dict] | None = None) -> dict:
    """One drawable block. An errored section carries a plain-word reason and
    no rows, so a half-failed composite still renders the half that worked.

    `legend` names the keys a multi-value row carries: the lines of a `lines`
    chart, the two parts of a `stack`, the columns of a `matrix`. Rows stay
    flat {key: value} maps so every client can read them the same way."""
    cap = MAX_POINTS if kind == "lines" else MAX_ROWS
    out = {
        "kind": kind,
        "title": V._text(title),
        "note": V._text(note),
        "source": V._text(source),
        "status": "error" if error else "ok",
        "error": V._text(error),
        "unit": V._text(unit),
        "rows": [V.scrub(row) for row in list(rows or [])[-cap:]
                 if isinstance(row, dict)] if kind == "lines" else
                [V.scrub(row) for row in list(rows or [])[:cap]],
    }
    if legend:
        out["legend"] = [{"key": V._text(l["key"]), "label": V._text(l["label"])}
                         for l in legend[:MAX_COLS]]
    return out


def _clock(at: str, multi_day: bool) -> str:
    """ "2026-09-22 13:57:04" -> "13:57", or "09-22 13:57" across days."""
    return at[5:16] if multi_day else at[11:16]


def _spread(points: list[dict], field: str, unit: str, multi_day: bool) -> str:
    lo, hi = V.extreme(points, field, min), V.extreme(points, field, max)
    if not lo:
        return ""
    return (f"low {lo[field]:g} at {_clock(lo['at'], multi_day)}, "
            f"high {hi[field]:g} at {_clock(hi['at'], multi_day)}")


def metric(label: str, value: Any, unit: str = "", note: str = "") -> dict:
    return {"label": label, "value": value, "unit": unit, "note": note}


def leg(call: Callable[[], Any]) -> tuple[Any, str]:
    """Run one controller call of a composite. A call that fails hands back
    its plain-word reason instead of sinking the whole report."""
    try:
        return call(), ""
    except Exception as err:          # noqa: BLE001 — every failure is a section
        return None, (str(err)[:200] or type(err).__name__)


def _window(params: dict) -> str:
    start, end = params.get("from", ""), params.get("to", "")
    return start if start == end else f"{start} → {end}"


def _days(params: dict) -> int:
    start, end = _parse_date(params["from"]), _parse_date(params["to"])
    return (end - start).days + 1


def _names(valves: list[dict] | None) -> dict[str, str]:
    return {v["id"]: v["name"] for v in (valves or [])}


def _valve_list(ids: list[str], names: dict[str, str]) -> str:
    return ", ".join(names.get(i, f"valve {i}") for i in ids) or "no valves"


def _triple(values: list[float]) -> str:
    return " / ".join(f"{v:g}" for v in values)


def imbalance_pct(values: list[float]) -> float | None:
    """Largest deviation from the mean, as a percentage of it — the usual
    three-phase voltage-imbalance figure. Motors are rated for a few percent;
    beyond that they run hot."""
    if not values:
        return None
    mean = sum(values) / len(values)
    if mean <= 0:
        return None
    return round(max(abs(v - mean) for v in values) / mean * 100, 1)


# ---- controller --------------------------------------------------------------

def _program_facts(prog: dict | None, names: dict[str, str], label: str) -> list[dict]:
    if not prog:
        return []
    bits = [prog["kind"], _valve_list(prog["valves"], names)]
    if prog["plannedMin"] is not None:
        if prog["completed"]:
            bits.append(f"{V.fmt_minutes(prog['plannedMin'])} planned, finished")
        elif prog["remainingMin"] is not None:
            bits.append(f"{V.fmt_minutes(prog['remainingMin'])} left of "
                        f"{V.fmt_minutes(prog['plannedMin'])}")
    return [{"label": label, "value": f"{prog['name']} · " + " · ".join(bits)},
            {"label": f"{label} since", "value": prog["start"]}]


def controller_sections(dash: Any, nodes: list[dict] | None,
                        nodes_err: str) -> tuple[list[dict], dict, str]:
    info = V.normalize_dcon_dashboard(dash or {})
    timers = V.dcon_timers(dash or {})
    names = _names(nodes)
    facts = [{"label": k, "value": v} for k, v in (
        ("Device", info["device"]), ("Serial", info["serial"]),
        ("Last packet", info["lastPacket"]),
        ("Controller clock", info["serverTime"]),
        ("Time zone", info["timeZone"])) if v]
    current = timers["current"]
    running = current and not current["completed"]
    facts += _program_facts(current, names, "Running now" if running else "Last program")
    if running:
        facts += _program_facts(timers["previous"], names, "Before that")
        for v, label in timers.get("faults") or []:
            facts.append({"label": "Valve fault", "value": f"{names.get(v, f'valve {v}')} {label}"})
    nxt = timers.get("next")
    if nxt:
        bits = [nxt["name"], _valve_list(nxt["valves"], names)]
        if nxt["plannedMin"] is not None:
            bits.append(V.fmt_minutes(nxt["plannedMin"]))
        facts.append({"label": "Next program", "value": " · ".join(bits)})
    sections = [section("facts", "Controller", facts)]
    if nodes_err:
        sections.append(section("status", "Valves", error=nodes_err))
    elif nodes:
        sections.append(section(
            "status", "Valves on this controller",
            [{"name": v["name"],
              "status": ("on" if running and v["id"] in current["valves"] else "off"),
              "meta": " · ".join(x for x in (v["type"], v["node"]) if x),
              "source": "dcon"} for v in nodes],
            note=f"{len(nodes)} valves on "
                 f"{len({v['node'] for v in nodes})} field nodes; "
                 "runtime is a separate report"))
    summary = info["device"]
    if nodes:
        summary += f" · {len(nodes)} valves"
    if running:
        summary += f" · running {current['name']}"
    return sections, info, summary


def report_controller(src, params: dict) -> tuple[list, str, list, dict]:
    dash = src.dashboard()
    nodes, nodes_err = leg(lambda: V.normalize_dcon_nodes(src.nodes()))
    sections, info, summary = controller_sections(dash, nodes, nodes_err)
    names = _names(nodes)
    timers = V.dcon_timers(dash or {})
    patch = {"dcon": info, "program": program_cache(timers, names)}
    if nodes is not None:
        patch["valveNames"] = nodes
    packet = V.dashboard_electricity(dash or {})
    if packet:
        esec, erows = electricity_sections(packet, "")
        sections += esec
        if erows:
            patch["electricity"] = erows
    return sections, summary, list(nodes or []), patch


def program_cache(timers: dict, names: dict[str, str]) -> dict:
    """The controller's current (or last) program, what it starts next, and
    any valve that did not answer, for the app's Overview: "watering now" is
    the first thing anyone asks. An allow-list of fields, like every other
    patch — nothing else from the dashboard payload."""
    prog, nxt = timers.get("current"), timers.get("next")
    out: dict[str, Any] = {"at": SERVER_TIMESTAMP}
    if nxt:
        out["next"] = {"name": nxt["name"], "plannedMin": nxt["plannedMin"],
                       "valves": _valve_list(nxt["valves"], names) if nxt["valves"] else ""}
    if not prog:
        return {**out, "running": False}
    running = not prog["completed"]
    faults = [f"{names.get(v, f'valve {v}')} {label}" for v, label in timers.get("faults") or []]
    if faults and running:
        out["faults"] = faults
    return {
        **out, "name": prog["name"], "kind": prog["kind"],
        "running": not prog["completed"],
        "valves": _valve_list(prog["valves"], names) if prog["valves"] else "",
        "start": prog["start"], "lastSeen": prog["lastSeen"],
        "plannedMin": prog["plannedMin"], "remainingMin": prog["remainingMin"],
    }


# ---- electricity and pressure, now -------------------------------------------------

def electricity_sections(packet: dict | None, err: str) -> tuple[list[dict], list[dict]]:
    if err:
        return [section("metrics", "Electricity", error=err)], []
    if not packet:
        return [section("metrics", "Electricity",
                        note="the controller sent no electricity packet")], []
    rows = []
    if "supplyMin" in packet:
        rows.append(metric("Supply today", V.fmt_minutes(packet["supplyMin"] or 0),
                           note="three-phase power present"))
        rows.append(metric("Pump today", V.fmt_minutes(packet["pumpMin"] or 0),
                           note="motor running on it"))
    if "currentA" in packet:
        rows.append(metric("Current", _triple(packet["currentA"]), "A",
                           note="per phase" if any(packet["currentA"])
                           else "pump is off"))
    if "lineV" in packet:
        rows.append(metric("Line voltage", _triple(packet["lineV"]), "V",
                           note="phase to phase"))
    if "phaseV" in packet:
        imb = imbalance_pct(packet["phaseV"])
        rows.append(metric("Phase voltage", _triple(packet["phaseV"]), "V",
                           note=(f"{imb}% imbalance · " if imb is not None else "")
                           + f"at {packet['at'][11:16]}"))
    if not rows:
        return [section("metrics", "Electricity",
                        note="the controller's packet carried nothing readable")], []
    return [section("metrics", "Electricity", rows)], rows


def pressure_now_sections(points: list[dict] | None, err: str) -> tuple[list[dict], list[dict]]:
    if err:
        return [section("metrics", "Pressure", error=err)], []
    if not points:
        return [section("metrics", "Pressure",
                        note="no samples in the last five minutes — the "
                             "controller only logs pressure while the pump runs")], []
    last = points[-1]
    rows = [metric("Inlet", last["inlet"], "bar", note=f"at {last['at'][11:19]}")]
    if last["outlet"] is not None:
        rows.append(metric("Outlet", last["outlet"], "bar", note="after the filter"))
        rows.append(metric("Filter drop", round(last["inlet"] - last["outlet"], 2),
                           "bar", note="inlet minus outlet"))
    out = [section("metrics", "Pressure", rows)]
    if len(points) > 1:
        out.append(section("series", "Inlet, last five minutes",
                           [{"at": p["at"], "value": p["inlet"], "unit": "bar"}
                            for p in points[-MAX_ROWS:]]))
    cache = [{"at": last["at"], "value": last["inlet"], "unit": "bar",
              "detail": (f"outlet {last['outlet']} bar"
                         if last["outlet"] is not None else "")}]
    return out, cache


def _snapshot_stamp() -> str:
    return (farm_now() - SNAPSHOT_LOOKBACK).strftime("%Y-%m-%d %H:%M:%S")


def report_electricity(src, params):
    packet = V.electricity_packet(src.electricity(_snapshot_stamp()))
    sections, rows = electricity_sections(packet, "")
    summary = " · ".join(f"{r['label']} {r['value']} {r['unit']}".strip()
                         for r in rows[:2]) or "no reading"
    return sections, summary, rows, {"electricity": rows}


def report_pressure(src, params):
    points = V.pressure_points(src.pressure_now(_snapshot_stamp()))
    sections, cache = pressure_now_sections(points, "")
    summary = (f"inlet {points[-1]['inlet']} bar" if points
               else "pump off — no recent samples")
    return sections, summary, cache, {"pressure": cache} if cache else {}


def report_live_readings(src, params):
    """Composite: power and pressure together say whether the pump is drawing
    current and producing head. Apart, they are two numbers."""
    stamp = _snapshot_stamp()
    packet, perr = leg(lambda: V.electricity_packet(src.electricity(stamp)))
    points, qerr = leg(lambda: V.pressure_points(src.pressure_now(stamp)))
    esec, erows = electricity_sections(packet, perr)
    psec, pcache = pressure_now_sections(points, qerr)
    bits = []
    if packet and "currentA" in packet:
        bits.append("pump running" if any(packet["currentA"]) else "pump off")
    if points:
        bits.append(f"inlet {points[-1]['inlet']} bar")
    if packet and "phaseV" in packet:
        bits.append(f"{_triple(packet['phaseV'])} V")
    patch = {}
    if packet is not None and erows:
        patch["electricity"] = erows
    if pcache:
        patch["pressure"] = pcache
    return esec + psec, " · ".join(bits) or "no reading", erows + pcache, patch


# ---- valves --------------------------------------------------------------------

def valve_sections(valves: list[dict] | None, err: str, window: str) -> list[dict]:
    if err:
        return [section("bars", "Valve runtime", error=err)]
    valves = valves or []
    crop = [v for v in valves if v["type"].lower() in IRRIGATION_TYPES]
    plumbing = [v for v in valves if v not in crop]
    ran = [v for v in crop if v["minutes"] > 0]
    total = sum(v["minutes"] for v in ran)
    per_day: dict[str, int] = {}
    for v in crop:
        for d in v["days"]:
            per_day[d["at"]] = per_day.get(d["at"], 0) + d["value"]
    backwash = sum(v["minutes"] for v in plumbing if "backwash" in v["type"].lower())
    idle = [v["name"] for v in crop if v["minutes"] == 0]
    rows = [metric("Valves watered", len(ran), note=f"of {len(crop)} in {window}"),
            metric("Valve time", V.fmt_minutes(total),
                   note="each valve's minutes added up; two open at once count twice")]
    if ran:
        top = max(ran, key=lambda v: v["minutes"])
        rows.append(metric("Most watered", top["name"], note=V.fmt_minutes(top["minutes"])))
    if per_day:
        busiest = max(per_day.items(), key=lambda kv: kv[1])
        rows.append(metric("Busiest day", V.fmt_minutes(busiest[1]), note=busiest[0]))
    if backwash:
        rows.append(metric("Backwash", V.fmt_minutes(backwash), note="filter cleaning"))
    out = [section("metrics", "Valves", rows)]
    days = sorted(per_day)
    if len(days) <= 1:
        # One day: every valve at a glance, the ones that got nothing included.
        out.append(section("grid", "Every valve", [
            {"name": v["name"], "value": v["minutes"], "unit": "min",
             "status": "on" if v["minutes"] else "off", "type": v["type"]}
            for v in crop], note=(f"{len(idle)} not watered" if idle else "")))
        return out
    # A range: valve by day, so a valve that ran every morning and one that
    # ran once for four hours stop looking the same.
    cols = [{"key": f"c{i}", "label": d[5:]} for i, d in enumerate(days)]
    grid = []
    for v in crop:
        by_day = {d["at"]: d["value"] for d in v["days"]}
        grid.append({"name": v["name"], "total": v["minutes"],
                     **{c["key"]: by_day.get(d, 0) for c, d in zip(cols, days)}})
    out.append(section("matrix", "Minutes per valve per day", grid, unit="min",
                       legend=cols, note=(f"not watered: {', '.join(idle)}" if idle else "")))
    out.append(section("series", "Valve time per day",
                       [{"at": d, "value": per_day[d], "unit": "min"} for d in days]))
    if ran:
        out.append(section("bars", "Runtime per valve",
                           [{"name": v["name"], "value": v["minutes"], "unit": "min",
                             "status": "on"} for v in sorted(ran, key=lambda v: -v["minutes"])]))
    return out


def report_valves(src, params):
    window = _window(params)
    valves = V.normalize_dcon_valves(src.valves(params["from"], params["to"]))
    crop = [v for v in valves if v["type"].lower() in IRRIGATION_TYPES]
    total = sum(v["minutes"] for v in crop)
    ran = sum(1 for v in crop if v["minutes"])
    return (valve_sections(valves, "", window),
            f"{ran} of {len(crop)} valves watered · {V.fmt_minutes(total)} · {window}",
            valves, {"valves": valves})


# ---- timer log: program runs -------------------------------------------------------

def _control(code: str) -> str:
    return V.CONTROL_CODES.get(code, code)


def run_row(run: dict, names: dict[str, str]) -> dict:
    planned = run["plannedMin"]
    if planned is None:
        amount = ""
    elif run["finished"]:
        amount = f"{V.fmt_minutes(planned)}, finished"
    else:
        amount = f"{V.fmt_minutes(run['deliveredMin'] or 0)} of {V.fmt_minutes(planned)}, stopped"
    bits = [amount, _valve_list(run["valves"], names)]
    if run["backwashes"]:
        bits.append(f"{run['backwashes']} backwash pause"
                    + ("s" if run["backwashes"] > 1 else ""))
    if run["startedBy"]:
        bits.append(f"started by {_control(run['startedBy'])}")
    if run["endedBy"] and not run["finished"]:
        bits.append(f"ended by {_control(run['endedBy'])}")
    bits += run["faults"]
    return {"at": run["start"], "event": f"{run['kind']} · {run['name']}",
            "detail": " · ".join(b for b in bits if b), "source": "timer"}


def timer_sections(segments: list[dict] | None, err: str, names: dict[str, str],
                   window: str) -> tuple[list[dict], list[dict], list[dict]]:
    """-> (sections, runs, timeline rows newest first)."""
    if err:
        return [section("timeline", "Program runs", error=err)], [], []
    segments = segments or []
    runs = V.join_runs(segments)
    if not runs:
        return [section("timeline", "Program runs",
                        note=f"no programs ran in {window}")], [], []
    washes = V.backwash_stats(segments)
    delivered = sum(r["deliveredMin"] or 0 for r in runs)
    finished = sum(1 for r in runs if r["finished"])
    faults = sum(len(r["faults"]) for r in runs)
    rows = [metric("Runs", len(runs), note=f"{finished} finished, "
                   f"{len(runs) - finished} stopped early"),
            metric("Water time", V.fmt_minutes(delivered),
                   note="by the controller's countdown"),
            metric("Backwashes", washes["count"],
                   note=f"{V.fmt_minutes(washes['minutes'])} of filter cleaning"),
            metric("Valve faults", faults, note="no signal, or did not open/close"
                   if faults else "none logged")]
    by_program: dict[str, int] = {}
    for r in runs:
        by_program[r["name"]] = by_program.get(r["name"], 0) + (r["deliveredMin"] or 0)
    timeline = [run_row(r, names) for r in reversed(runs)]
    out = [section("metrics", "Programs", rows)]
    if len(by_program) > 1:
        out.append(section("bars", "Water time per program",
                           [{"name": n, "value": m, "unit": "min", "status": "on"}
                            for n, m in sorted(by_program.items(), key=lambda kv: -kv[1]) if m]))
    out.append(section("timeline", "Program runs, newest first", timeline,
                       note=f"{len(segments)} log rows joined into {len(runs)} runs "
                            "— the controller logs a run in pieces around each backwash"))
    return out, runs, timeline


def _timer_leg(src, params):
    return V.timer_segments(src.timer_log(params["from"], params["to"]))


def _names_leg(src):
    nodes, _err = leg(lambda: V.normalize_dcon_nodes(src.nodes()))
    return _names(nodes)


def report_timer_log(src, params):
    window = _window(params)
    segments = _timer_leg(src, params)
    names = _names_leg(src)
    sections, runs, timeline = timer_sections(segments, "", names, window)
    finished = sum(1 for r in runs if r["finished"])
    return (sections, f"{len(runs)} runs, {finished} finished · {window}",
            timeline, {"timerLog": timeline[:V.MAX_LIST]})


# ---- motor log: power, pump, energy -------------------------------------------------

def motor_sections(days: list[dict] | None, err: str,
                   window: str) -> tuple[list[dict], list[dict]]:
    if err:
        return [section("metrics", "Pump and power", error=err)], []
    days = days or []
    if not days:
        return [section("metrics", "Pump and power",
                        note=f"nothing logged in {window}")], []
    pump = sum(d["pumpMin"] or 0 for d in days)
    supply = sum(d["supplyMin"] or 0 for d in days)
    metered = [d for d in days if d["kwh"] is not None]
    kwh = round(sum(d["kwh"] for d in metered), 1)
    metered_pump = sum(d["pumpMin"] or 0 for d in metered)
    rows = [metric("Energy", kwh, "kWh",
                   note=f"{len(metered)} of {len(days)} days metered"),
            metric("Pump ran", V.fmt_minutes(pump),
                   note=f"avg {V.fmt_minutes(pump / len(days))} a day"),
            metric("Power present", V.fmt_minutes(supply),
                   note=(f"pump used {round(pump / supply * 100)}% of it"
                         if supply else "no supply logged"))]
    if metered_pump:
        rows.append(metric("Average draw", round(kwh / (metered_pump / 60), 2), "kW",
                           note="energy over pump hours"))
    resets = [d["day"] for d in days if d["meterReset"]]
    out = [section("metrics", "Pump and power", rows,
                   note=(f"energy meter reset on {', '.join(resets)}; that day "
                         "has no energy figure") if resets else "")]
    if len(days) > 1:
        out.append(section(
            "stack", "Power and pump, per day",
            [{"at": d["day"], "total": round((d["supplyMin"] or 0) / 60, 1),
              "part": round((d["pumpMin"] or 0) / 60, 1)} for d in days],
            unit="h", legend=[{"key": "total", "label": "Power available"},
                              {"key": "part", "label": "Pump ran"}]))
        if len(metered) > 1:
            out.append(section("series", "Energy per day",
                               [{"at": d["day"], "value": d["kwh"], "unit": "kWh"}
                                for d in metered]))
    timeline = [{"at": f"{d['day']} {d['through']}".strip(), "event": "Pump day",
                 "detail": " · ".join(x for x in (
                     f"pump {V.fmt_minutes(d['pumpMin'] or 0)} of "
                     f"{V.fmt_minutes(d['supplyMin'] or 0)} with power",
                     f"{d['kwh']} kWh" if d["kwh"] is not None else "meter reset")
                     if x), "source": "motor"} for d in reversed(days)]
    return out, timeline


def report_motor_log(src, params):
    window = _window(params)
    days = V.motor_days(src.motor_log(params["from"], params["to"]))
    sections, timeline = motor_sections(days, "", window)
    kwh = round(sum(d["kwh"] for d in days if d["kwh"] is not None), 1)
    pump = sum(d["pumpMin"] or 0 for d in days)
    return (sections, f"{kwh} kWh · pump {V.fmt_minutes(pump)} · {window}",
            timeline, {"motorLog": timeline[:V.MAX_LIST]})


def report_session_log(src, params):
    """Composite: program runs and the pump's day, in one chronology. Apart
    you cannot see that the pump ran sixteen hours on a day the programs
    asked for four; together it is the first thing you see."""
    window = _window(params)
    segments, terr = leg(lambda: _timer_leg(src, params))
    days, merr = leg(lambda: V.motor_days(src.motor_log(params["from"], params["to"])))
    names = _names_leg(src) if segments else {}
    tsec, runs, tline = timer_sections(segments, terr, names, window)
    msec, mline = motor_sections(days, merr, window)
    merged = sorted(tline + mline, key=lambda r: r["at"], reverse=True)
    heads = [s for s in tsec + msec if s["kind"] != "timeline"]
    errors = [s for s in tsec + msec if s["kind"] == "timeline" and s["status"] == "error"]
    sections = heads + errors
    if merged:
        sections.append(section("timeline", "Runs and pump days, newest first", merged))
    delivered = sum(r["deliveredMin"] or 0 for r in runs)
    pump = sum(d["pumpMin"] or 0 for d in (days or []))
    bits = [f"{len(runs)} runs, {V.fmt_minutes(delivered)} of water" if runs else "",
            f"pump {V.fmt_minutes(pump)}" if days else "", window]
    patch = {}
    if segments is not None:
        patch["timerLog"] = tline[:V.MAX_LIST]
    if days is not None:
        patch["motorLog"] = mline[:V.MAX_LIST]
    return sections, " · ".join(b for b in bits if b), merged, patch


# ---- pressure over a range -------------------------------------------------------

def pressure_sections(points: list[dict] | None, err: str, params: dict) -> list[dict]:
    window = _window(params)
    if err:
        return [section("series", "Pressure", error=err)]
    points = points or []
    if not points:
        return [section("series", "Pressure",
                        note=f"no samples in {window} — the controller only "
                             "logs pressure while the pump runs")]
    multi = _days(params) > 1
    return pressure_detail(points, _days(params) * 1440, multi)


def pressure_detail(points: list[dict], span_min: float, multi: bool) -> list[dict]:
    inlet = V.series_stats([p["inlet"] for p in points])
    paired = [p for p in points if p["outlet"] is not None]
    outlet = V.series_stats([p["outlet"] for p in paired])
    drops = [{"at": p["at"], "drop": round(p["inlet"] - p["outlet"], 2)} for p in paired]
    drop = V.series_stats([d["drop"] for d in drops])
    rows = [metric("Inlet", inlet["avg"], "bar",
                   note=f"avg of {inlet['count']:,} samples · "
                        + _spread(points, "inlet", "bar", multi))]
    if outlet["count"]:
        rows.append(metric("Outlet", outlet["avg"], "bar",
                           note=_spread(paired, "outlet", "bar", multi)))
        top = V.extreme(drops, "drop", max)
        rows.append(metric("Filter drop", drop["avg"], "bar",
                           note=f"up to {drop['max']:g} at {_clock(top['at'], multi)}; "
                                "rises as the filter clogs"))
    minutes = V.bucket_minutes(span_min)
    step = (f"{minutes}-minute" if minutes < 60 else
            "hourly" if minutes == 60 else
            "daily" if minutes >= 1440 else f"{minutes // 60}-hourly")
    out = [section("metrics", "Pressure", rows),
           section("lines", f"Inlet and outlet, {step} average",
                   V.bucket_multi(points, ("inlet", "outlet"), minutes), unit="bar",
                   legend=[{"key": "inlet", "label": "Inlet"},
                           {"key": "outlet", "label": "Outlet"}])]
    if paired:
        # A sparkline, so 32 points: its own window, not the line chart's.
        few = V.bucket_minutes(span_min, MAX_ROWS)
        label = (f"{few}-minute" if few < 60 else "hourly" if few == 60 else
                 "daily" if few >= 1440 else f"{few // 60}-hourly")
        series = [{"at": r["at"], "value": r["drop"], "unit": "bar"}
                  for r in V.bucket_multi(drops, ("drop",), few) if "drop" in r]
        out.append(section("series", f"Filter drop, {label} average", series))
    return out


def _pressure_cache(points: list[dict]) -> list[dict]:
    return [{**row, "unit": "bar"} for row in V.bucket(points, "inlet", 1)][-V.MAX_LIST:]


def report_pressure_range(src, params):
    window = _window(params)
    points = V.pressure_points(src.pressure_range(params["from"], params["to"]))
    stats = V.series_stats([p["inlet"] for p in points])
    summary = (f"inlet {stats['min']}–{stats['max']} bar, avg {stats['avg']} · {window}"
               if stats["count"] else f"no samples · {window}")
    cache = _pressure_cache(points)
    return (pressure_sections(points, "", params), summary, cache,
            {"pressure": cache} if cache else {})


def report_performance(src, params):
    """Composite: valve runtime against the pressure over the same window —
    the one thing a runtime bar cannot say is whether the line held."""
    window = _window(params)
    valves, verr = leg(lambda: V.normalize_dcon_valves(
        src.valves(params["from"], params["to"])))
    points, perr = leg(lambda: V.pressure_points(
        src.pressure_range(params["from"], params["to"])))
    sections = valve_sections(valves, verr, window) + pressure_sections(points, perr, params)
    crop = [v for v in (valves or []) if v["type"].lower() in IRRIGATION_TYPES]
    total = sum(v["minutes"] for v in crop)
    stats = V.series_stats([p["inlet"] for p in (points or [])])
    bits = [f"{V.fmt_minutes(total)} of valve time" if total else "",
            f"inlet avg {stats['avg']} bar" if stats["count"] else "", window]
    patch = {}
    if valves is not None:
        patch["valves"] = valves
    if points:
        patch["pressure"] = _pressure_cache(points)
    return sections, " · ".join(b for b in bits if b), list(valves or []), patch


# ---- pressure, last hour ---------------------------------------------------------

def report_pressure_hour(src, params):
    since = (farm_now() - _dt.timedelta(hours=1)).strftime("%Y-%m-%d %H:%M:%S")
    points = V.pressure_points(src.pressure_now(since))
    if not points:
        return ([section("metrics", "Pressure",
                         note="no samples in the last hour — the controller only "
                              "logs pressure while the pump runs")],
                "pump off — no samples in the last hour", [], {})
    last = points[-1]
    stats = V.series_stats([p["inlet"] for p in points])
    return (pressure_detail(points, 60, False),
            f"inlet {last['inlet']} bar now, avg {stats['avg']} over the hour",
            [], {"pressure": _pressure_cache(points)})


# ---- power over time ------------------------------------------------------------

def _gap_minutes(a: str, b: str) -> float:
    x, y = V.parse_stamp(a), V.parse_stamp(b)
    return (y - x).total_seconds() / 60 if x and y else 0.0


def power_sections(rows: list[dict], params: dict) -> tuple[list[dict], str]:
    window = _window(params)
    rows = [r for r in rows if "phaseV" in r]
    if not rows:
        return [section("metrics", "Power", note=f"no electricity packets in {window}")], \
            f"no readings · {window}"
    multi = _days(params) > 1
    # A packet reading under 90 V on every phase is the supply gone, not a
    # low supply: the controller keeps reporting on its own battery.
    cut = lambda r: max(r["phaseV"]) < 90
    running = lambda r: bool(r.get("currentA")) and max(r["currentA"]) > 0.5
    flat = [{"at": r["at"], **{f"v{i}": r["phaseV"][i] for i in range(3)},
             **({f"a{i}": r["currentA"][i] for i in range(3)} if r.get("currentA") else {})}
            for r in rows]
    live = [f for f, r in zip(flat, rows) if not cut(r)]

    # Pump and supply time come from the controller's own counters, which
    # every packet carries and which reset at midnight — not from adding up
    # gaps between packets, which overcounts across any gap in reporting.
    # Read this way 2026-09-22 ends at 20h 13m supply, 13h 27m pump: exactly
    # what the motor log says for that day.
    run_min = supply_min = 0.0
    by_day: dict[str, list[dict]] = {}
    for r in rows:
        if r.get("pumpMin") is not None:
            by_day.setdefault(r["at"][:10], []).append(r)
    for day_rows in by_day.values():
        first, last = day_rows[0], day_rows[-1]
        from_midnight = first["at"][11:16] <= "00:10"
        run_min += last["pumpMin"] - (0 if from_midnight else first["pumpMin"])
        supply_min += last["supplyMin"] - (0 if from_midnight else first["supplyMin"])
    cuts, cut_start, longest = 0, None, 0.0
    for r in rows:
        if cut(r) and cut_start is None:
            cut_start, cuts = r["at"], cuts + 1
        elif not cut(r) and cut_start is not None:
            longest, cut_start = max(longest, _gap_minutes(cut_start, r["at"])), None
    if cut_start is not None:
        longest = max(longest, _gap_minutes(cut_start, rows[-1]["at"]))

    metrics = []
    if live:
        avgs = [round(sum(f[f"v{i}"] for f in live) / len(live)) for i in range(3)]
        metrics.append(metric("Phase voltage", " / ".join(map(str, avgs)), "V",
                              note=f"average · {imbalance_pct(avgs)}% imbalance"))
        low = min(({"at": f["at"], "v": f[f"v{i}"], "p": i + 1} for f in live for i in range(3)),
                  key=lambda x: x["v"])
        high = max(({"at": f["at"], "v": f[f"v{i}"], "p": i + 1} for f in live for i in range(3)),
                   key=lambda x: x["v"])
        metrics.append(metric("Lowest", f"{low['v']:g}", "V",
                              note=f"phase {low['p']} at {_clock(low['at'], multi)}"))
        metrics.append(metric("Highest", f"{high['v']:g}", "V",
                              note=f"phase {high['p']} at {_clock(high['at'], multi)}"))
    loaded = [r for r in rows if running(r)]
    if loaded:
        amps = [sum(r["currentA"]) / 3 for r in loaded]
        peak = max(loaded, key=lambda r: max(r["currentA"]))
        metrics.append(metric("Current, pump running", round(sum(amps) / len(amps), 1), "A",
                              note=f"peak {max(peak['currentA']):g} A at "
                                   f"{_clock(peak['at'], multi)}"))
    if by_day:
        metrics.append(metric("Pump ran", V.fmt_minutes(run_min),
                              note=f"of {V.fmt_minutes(supply_min)} with power"))
    metrics.append(metric("Supply cuts", cuts,
                          note=f"longest {V.fmt_minutes(longest)}" if cuts else "none"))
    span = max(_gap_minutes(rows[0]["at"], rows[-1]["at"]), 60)
    minutes = V.bucket_minutes(span)
    amps = V.bucket_multi(flat, ("a0", "a1", "a2"), minutes)
    # Every window on the timeline, and a window with only cut packets carries
    # no voltage keys: the chart breaks the line there instead of joining
    # across an outage.
    have = {r["at"]: r for r in V.bucket_multi(live, ("v0", "v1", "v2"), minutes)}
    volts = [have.get(r["at"], {"at": r["at"]}) for r in amps]
    for r in amps:
        r["on"] = 1 if max(r.get("a0", 0), r.get("a1", 0), r.get("a2", 0)) > 0.5 else 0
    phases = [{"key": f"{k}{i}", "label": f"Phase {i + 1}"} for i in range(3) for k in "v"]
    sections = [section("metrics", "Power", metrics),
                section("lines", "Voltage per phase", volts, unit="V", legend=phases,
                        note="gaps are supply cuts"),
                section("lines", "Current per phase", amps, unit="A",
                        legend=[{"key": f"a{i}", "label": f"Phase {i + 1}"} for i in range(3)],
                        note="shaded where the pump was running")]
    summary = " · ".join(x for x in (
        f"pump {V.fmt_minutes(run_min)}" if by_day else "",
        f"{cuts} supply cut{'s' if cuts != 1 else ''}" if cuts else "no supply cuts",
        window) if x)
    return sections, summary


def report_power_range(src, params):
    raw = src.electricity(f"{params['from']} 00:00:00")
    rows = V.electricity_series(raw, f"{params['from']} 00:00:00", f"{params['to']} 23:59:59")
    sections, summary = power_sections(rows, params)
    return sections, summary, [], {}


BUILDERS = {
    "live_readings": report_live_readings,
    "session_log": report_session_log,
    "performance": report_performance,
    "controller": report_controller,
    "electricity": report_electricity,
    "pressure": report_pressure,
    "valves": report_valves,
    "timer_log": report_timer_log,
    "motor_log": report_motor_log,
    "pressure_range": report_pressure_range,
    "power_range": report_power_range,
    "pressure_hour": report_pressure_hour,
}


def build(rtype: str, params: dict, src) -> tuple[dict, dict]:
    """Run one validated request. Returns (report, cache_patch).

    Status is ok, partial when a section errored but something still drew,
    error when nothing did — three tags on the dashboard, so a half-answer
    never reads as a whole one."""
    base = {"type": rtype, "label": REPORT_LABELS[rtype], "params": params,
            "at": SERVER_TIMESTAMP}
    try:
        sections, summary, rows, patch = BUILDERS[rtype](src, params)
    except Exception as err:          # noqa: BLE001 — a failed pull is a report too
        return {**base, "status": "error", "summary": "", "sections": [], "rows": [],
                "error": str(err)[:200] or type(err).__name__}, {}
    failed = [s for s in sections if s["status"] == "error"]
    drawn = [s for s in sections if s["status"] != "error" and (s["rows"] or s["note"])]
    reasons = list(dict.fromkeys(s["error"] for s in failed if s["error"]))
    status = "error" if failed and not drawn else ("partial" if failed else "ok")
    report = {**base, "status": status, "summary": V._text(summary),
              "sections": sections,
              # rows stays for a dashboard build from before sections existed.
              "rows": [V.scrub(r) for r in list(rows or [])[:V.MAX_LIST]]}
    if failed:
        report["error"] = "; ".join(reasons)[:200]
    return report, {k: V.scrub(v) for k, v in patch.items()}
