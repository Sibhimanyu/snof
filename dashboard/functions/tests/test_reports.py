"""Pure checks for the irrigation report function. No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_reports.py

Fixtures are synthetic but copy the live shapes seen on 2026-09-23 (see
docs/irrigation.md). Never paste a real payload in here: the dashboard one
carries the farm's phone book.
"""
import datetime as dt
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import reports as R  # noqa: E402
import vendors as V  # noqa: E402


def req(**over):
    base = {"type": "valves", "from": "2026-09-20", "to": "2026-09-22",
            "uid": "u1", "at": time.time() * 1000}
    base.update(over)
    return base


def refused(payload) -> bool:
    try:
        R.validate(payload)
    except R.Refused:
        return True
    return False


# ---- fixtures, in the controller's real shapes ---------------------------------

def seg(at, seen, name, kind, left, planned, valves="12-15-0-0-0-0-0-0-0-0",
        done="0", start="TM", end=None, no="20", **extra):
    return {"dt": at, "last_sync": seen, "timer_type": kind, "timer_name": name,
            "timer_no": no, "completed": done, "on_valves": valves,
            "valve_comm_error": "0-0-0-0-0-0-0-0-0-0",
            "valve_not_on": "0-0-0-0-0-0-0-0-0-0",
            "valve_not_off": "0-0-0-0-0-0-0-0-0-0",
            "run_time": f"{left}-{planned}", "start_control": start,
            "end_control": end, **extra}


def wash(at, seen):
    return seg(at, seen, "Backwash Mode", "4", "00:01", "00:03",
               valves="3-0-0-0-0-0-0-0-0-0", done="1", start="MM", no="20")


# One hour of Coconut, logged the way the controller logs it: in pieces
# around each backwash, remaining time counting down.
COCONUT = [
    seg("2026-09-21 08:58:00", "2026-09-21 09:09:00", "Coconut", "1", "00:50", "01:00"),
    wash("2026-09-21 09:09:00", "2026-09-21 09:12:30"),
    seg("2026-09-21 09:13:00", "2026-09-21 09:28:00", "Coconut", "1", "00:36", "01:00"),
    wash("2026-09-21 09:28:00", "2026-09-21 09:32:00"),
    seg("2026-09-21 09:33:00", "2026-09-21 10:20:00", "Coconut", "1", "00:01", "01:00",
        done="1"),
]
# Then a vegetable run that was cut short, with a valve that never opened.
VEG = [seg("2026-09-21 10:26:00", "2026-09-21 10:34:00", "Vegetables", "1",
           "00:22", "00:30", valves="4-6-0-0-0-0-0-0-0-0", end="U8",
           valve_not_on="0-1-0-0-0-0-0-0-0-0")]
TIMER_LOG = {"action": "timer_log", "log": COCONUT + VEG}

NODES = {"action": "get_node",
         "Node1": {"type": "FL-10", "valve": {
             "3": {"valve_name": "3 Backwash", "valve_type": "Backwash"},
             "4": {"valve_name": "4 Veg", "valve_type": "Irrigation"},
             "6": {"valve_name": "6 Kulam", "valve_type": "Irrigation"}}},
         "Node2": {"type": "AC-10", "valve": {
             "12": {"valve_name": "12 Coco 1", "valve_type": "Irrigation"},
             "15": {"valve_name": "15 Coco 2", "valve_type": "Irrigation"}}}}

MOTOR_LOG = {"action": "motor_log", "log": [
    {"dt1": "2026-09-09", "time": "23:59:01", "ph3_runtime": "19.51-14.22",
     "kilowatt_start": "25612.31", "kilowatt_end": "25677.94"},
    {"dt1": "2026-09-10", "time": "23:59:03", "ph3_runtime": "21.19-21.18",
     "kilowatt_start": "25678.80", "kilowatt_end": "171.69"},
    {"dt1": "2026-09-11", "time": "23:59:47", "ph3_runtime": "20.47-19.42",
     "kilowatt_start": "171.81", "kilowatt_end": "268.60"},
]}

PACKET = ("##,DCON-MCON000TEST000,6-0-0!2026-09-23 22:04:00+05:30,,255-249-264,"
          "436-443-448,9.7-9.5-9.6,1.0-0-1.0,17.47-16.21,00.00-00.00,50.0,20,"
          "693.70,0.0,4.214-100,0.0,00000-00,")
ELECTRICITY = {"status": "success", "data": [{"dt": "2026-09-23 22:04:00",
                                              "raw_data": PACKET}]}

FAKE_PHONE = "919876543210"
DASHBOARD = {"MCON000TEST000": {
    "device_id": "00000", "server_time": "2026-09-23 22:08:08",
    "time_zone": "+05:30", "sim": f"vi-{FAKE_PHONE[2:]}",
    "packets": {"live": "##,DCON-MCON000TEST000,0-0-0!2026-09-23 22:04:28+05:30,"
                        "V68,SibhiSump,1,0--,0",
                "4": f"##,DCON,{FAKE_PHONE},{FAKE_PHONE}",
                "5": "##,DCON,5-0-0!x,DCON_V8,490154203237518"},
    "users": {"A1": {"name": "owner", "mobile": FAKE_PHONE}},
    "timers": {"current": seg("2026-09-23 20:41:05", "2026-09-23 20:44:35",
                              "Vegetable", "1", "00:25", "00:30",
                              valves="4-6-0-0-0-0-0-0-0-0"),
               "previous": wash("2026-09-23 20:37:02", "2026-09-23 20:41:05"),
               # The real shape of `next`, first seen set on 2026-09-24.
               "next": {"timer_mode_type": "1", "timer_mode": "1", "timer_name": "Coconut",
                        "timer_no": "2", "valves": "12-15-0-0-0-0-0-0-0-0",
                        "on_time": "01:00", "off_time": "00:00", "on_days": "0"}},
}}
# Packet 6 of the dashboard: the live electricity packet, as it arrived on
# 2026-09-24 (pump drawing ~9.7 A, supply 13 h 06 m and pump 6 h 38 m today).
DASHBOARD["MCON000TEST000"]["packets"]["6"] = (
    "##,DCON-MCON000TEST000,6-0-0!2026-09-24 14:29:06+05:30,,228-223-264,390-421-426,"
    "9.8-9.5-9.7,1.0-0-1.0,13.06-06.38,00.00-00.00,49.8,20,725.72,6913.70,4.196-100,0.0,00000-00,")


def pressure_day(n=4000, day="2026-09-22"):
    start = dt.datetime.fromisoformat(f"{day} 06:00:00")
    return {"status": "success", "data": [
        {"dt": (start + dt.timedelta(seconds=11 * i)).strftime("%Y-%m-%d %H:%M:%S"),
         "pressure": f"{2.0 + (i % 10) / 10:.1f}-{1.5 + (i % 5) / 10:.1f}",
         "flow_rate": "0"} for i in range(n)]}


def valves_payload(count=27):
    out = {"action": "get_all_valve"}
    for i in range(1, count + 1):
        kind = "Backwash" if i == 3 else "Irrigation"
        out[str(i)] = {"valve_name": f"{i} Crop", "valve_type": kind,
                       "runtime": {"2026-09-20": "00:30" if i % 2 else "00:00",
                                   "2026-09-21": "01:10" if i % 2 else "00:00"}}
    return out


class Source:
    """Stands in for dcon.Dcon. Any call named in `dead` raises."""
    def __init__(self, dead=()):
        self.dead, self.calls = set(dead), []

    def _go(self, name, value):
        self.calls.append(name)
        if name in self.dead:
            raise RuntimeError(f"DCON {name}: HTTP 502")
        return value

    def dashboard(self): return self._go("dashboard", DASHBOARD)
    def nodes(self): return self._go("nodes", NODES)
    def valves(self, a, b): return self._go("valves", valves_payload())
    def timer_log(self, a, b): return self._go("timer_log", TIMER_LOG)
    def motor_log(self, a, b): return self._go("motor_log", MOTOR_LOG)
    def electricity(self, since):
        return self._go("electricity",
                        ELECTRICITY_DAYS if since.endswith("00:00:00") else ELECTRICITY)
    def pressure_now(self, since): return self._go("pressure_now", pressure_day(20))
    def pressure_range(self, a, b): return self._go("pressure_range", pressure_day())


KINDS = ("metrics", "status", "series", "bars", "timeline", "facts",
         "lines", "stack", "grid", "matrix")

# Two days of electricity packets, one a minute: a supply cut 10:00–10:30 on
# the first day (0 V, controller on battery), pump drawing ~9 A 06:00–09:00.
# The last two fields are the controller's day counters, HH.MM supply-pump.
def _packet(at, volts, amps, supply, pump):
    return {"dt": at, "raw_data": f"##,DCON-MCON000TEST000,6-0-0!{at}+05:30,,{volts},"
            f"436-443-448,{amps},1.0-0-1.0,{supply},00.00-00.00,50.0,20,693.70,"}


def _hm(minutes):
    return f"{minutes // 60:02d}.{minutes % 60:02d}"


def electricity_days():
    out, supply, pump = [], 0, 0
    start = dt.datetime.fromisoformat("2026-09-22 00:00:00")
    for m in range(2 * 1440):
        at = start + dt.timedelta(minutes=m)
        if at.hour == 0 and at.minute == 0:
            supply = pump = 0
        cut = at.date().day == 22 and at.hour == 10 and at.minute < 30
        on = 6 <= at.hour < 9 and not cut
        supply += 0 if cut else 1
        pump += 1 if on else 0
        volts = "0-0-0" if cut else f"{240 + (m % 7)}-{232 + (m % 5)}-263"
        amps = "9.2-9.0-9.1" if on else "0.0-0.0-0.0"
        out.append(_packet(at.strftime("%Y-%m-%d %H:%M:%S"), volts, amps,
                           f"{_hm(supply)}-{_hm(pump)}", pump))
    return {"status": "success", "data": out}


ELECTRICITY_DAYS = electricity_days()


def params_for(rtype):
    return {} if R.REPORT_TYPES[rtype] == "live" else {"from": "2026-09-20",
                                                         "to": "2026-09-22"}


# ---- validation -------------------------------------------------------------------

def test_every_known_type_validates():
    for rtype, need in R.REPORT_TYPES.items():
        payload = req(type=rtype) if need == "range" else {"type": rtype, "uid": "u",
                                                           "at": time.time() * 1000}
        got = R.validate(payload)
        assert got[0] == rtype, got
        assert (got[1] == {}) == (need == "live"), got


def test_types_labels_and_builders_do_not_drift():
    assert set(R.REPORT_TYPES) == set(R.REPORT_LABELS) == set(R.BUILDERS)


def test_types_match_the_rtdb_rule():
    rules = (HERE.parent / "database.rules.json").read_text()
    allowed = re.search(r"irrigation_requests.*?matches\(/\^\(([a-z_|]+)\)\$/\)",
                        rules, re.S).group(1).split("|")
    assert set(allowed) == set(R.REPORT_TYPES), allowed


def test_refuses_bad_shapes():
    bad = {
        "not an object": "valves",
        "unknown type": req(type="valve_on"),
        "no timestamp": req(at=None),
        "boolean timestamp": req(at=True),
        "stale": req(at=(time.time() - 900) * 1000),
        "postdated": req(at=(time.time() + 3600) * 1000),
        "range without dates": {"type": "motor_log", "uid": "u", "at": time.time() * 1000},
        "bad date format": req(**{"from": "20-09-2026"}),
        "month 13": req(**{"from": "2026-13-01"}),
        "Feb 30": req(**{"from": "2026-02-30"}),
        "to before from": req(**{"from": "2026-09-22", "to": "2026-09-20"}),
        "a decade": req(**{"from": "2016-01-01", "to": "2026-09-22"}),
    }
    for why, payload in bad.items():
        assert refused(payload), f"accepted a request that is {why}"


def test_live_types_ignore_stray_dates():
    got = R.validate({"type": "controller", "from": "2020-01-01", "uid": "u",
                      "at": time.time() * 1000})
    assert got == ("controller", {}), got


def test_snapshot_clock_is_farm_time_not_utc():
    """Cloud Functions run in UTC; the controller does not. A UTC stamp asks
    for samples five and a half hours old."""
    utc = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    offset = (R.farm_now() - utc).total_seconds() / 3600
    assert abs(offset - 5.5) < 0.01, offset


# ---- timer log: segments become runs ----------------------------------------------

def test_timer_rows_are_stitched_into_runs():
    runs = V.join_runs(V.timer_segments(TIMER_LOG))
    assert [r["name"] for r in runs] == ["Coconut", "Vegetables"], runs
    coconut, veg = runs
    assert coconut["segments"] == 3 and coconut["backwashes"] == 2, coconut
    assert coconut["finished"] and coconut["deliveredMin"] == 59, coconut
    assert coconut["start"] == "2026-09-21 08:58:00"
    assert coconut["end"] == "2026-09-21 10:20:00"
    assert not veg["finished"] and veg["deliveredMin"] == 8, veg
    assert veg["endedBy"] == "U8"
    assert veg["faults"] == ["valve 6 did not open"], veg["faults"]


def test_run_time_is_remaining_not_elapsed():
    """ "00:50-01:00" is fifty minutes *left* of sixty. Read as elapsed, a
    finished hour of Coconut looks like a one-minute run."""
    prog = V.dcon_program(COCONUT[-1])
    assert prog["remainingMin"] == 1 and prog["plannedMin"] == 60, prog


def test_a_new_planned_length_starts_a_new_run():
    log = [seg("2026-09-20 09:49:00", "2026-09-20 10:48:00", "Manual Mode", "3",
               "07:03", "08:00", valves="30-0-0-0-0-0-0-0-0-0", start="MM"),
           seg("2026-09-20 18:04:00", "2026-09-20 18:19:00", "Manual Mode", "3",
               "03:46", "04:00", valves="30-0-0-0-0-0-0-0-0-0", start="MM")]
    assert len(V.join_runs(V.timer_segments(log))) == 2


def test_timer_report_names_valves_and_counts_backwash():
    rep, patch = R.build("timer_log", params_for("timer_log"), Source())
    assert rep["status"] == "ok", rep
    tiles = {m["label"]: m for m in rep["sections"][0]["rows"]}
    assert tiles["Runs"]["value"] == 2
    assert tiles["Backwashes"]["value"] == 2
    assert tiles["Valve faults"]["value"] == 1
    timeline = next(s for s in rep["sections"] if s["kind"] == "timeline")["rows"]
    assert timeline[0]["event"] == "Program · Vegetables", "newest first"
    assert "12 Coco 1, 15 Coco 2" in timeline[1]["detail"], timeline[1]
    assert "timerLog" in patch


def test_timer_report_survives_get_node_failing():
    rep, _ = R.build("timer_log", params_for("timer_log"), Source(dead={"nodes"}))
    assert rep["status"] == "ok"
    timeline = next(s for s in rep["sections"] if s["kind"] == "timeline")["rows"]
    assert "valve 12, valve 15" in timeline[1]["detail"], timeline[1]


# ---- motor log --------------------------------------------------------------------

def test_motor_days_read_supply_pump_and_energy():
    days = V.motor_days(MOTOR_LOG)
    first = days[0]
    assert first["supplyMin"] == 19 * 60 + 51 and first["pumpMin"] == 14 * 60 + 22
    assert first["kwh"] == 65.63


def test_motor_meter_reset_is_no_figure_not_a_negative_one():
    reset = V.motor_days(MOTOR_LOG)[1]
    assert reset["kwh"] is None and reset["meterReset"], reset
    rep, _ = R.build("motor_log", params_for("motor_log"), Source())
    tiles = {m["label"]: m for m in rep["sections"][0]["rows"]}
    assert tiles["Energy"]["value"] == round(65.63 + 96.79, 1), tiles
    assert "2 of 3 days" in tiles["Energy"]["note"]
    assert "2026-09-10" in rep["sections"][0]["note"]


# ---- pressure ------------------------------------------------------------------------

def test_pressure_range_reads_every_sample_not_the_first_32():
    """Regression: parsers used to cap rows before aggregating, so a day's
    report summarised the first six minutes of the morning."""
    rep, _ = R.build("pressure_range", {"from": "2026-09-22", "to": "2026-09-22"},
                     Source())
    tiles = {m["label"]: m for m in rep["sections"][0]["rows"]}
    assert "4,000 samples" in tiles["Inlet"]["note"], tiles["Inlet"]
    lines = rep["sections"][1]
    assert lines["kind"] == "lines" and "15-minute" in lines["title"], lines["title"]
    assert len(lines["rows"]) == 49, len(lines["rows"])   # 06:00 → 18:15, every window


def test_pressure_series_fits_the_row_cap_for_a_month():
    assert V.bucket_hours(1) == 1
    assert V.bucket_hours(7) == 6
    assert V.bucket_hours(31) == 24


def test_pump_off_is_said_not_shown_as_zero():
    class Quiet(Source):
        def pressure_now(self, since): return {"status": "success", "data": []}
    rep, patch = R.build("pressure", {}, Quiet())
    assert rep["status"] == "ok" and "pump runs" in rep["sections"][0]["note"]
    assert "pressure" not in patch, "an empty pull must not blank the cache"


# ---- electricity ----------------------------------------------------------------------

def test_electricity_labels_only_what_it_can_cross_check():
    pkt = V.electricity_packet(ELECTRICITY)
    assert pkt["phaseV"] == [255, 249, 264]
    assert pkt["lineV"] == [436, 443, 448]
    assert pkt["currentA"] == [9.7, 9.5, 9.6]
    assert pkt["supplyMin"] == 17 * 60 + 47 and pkt["pumpMin"] == 16 * 60 + 21
    assert V.meter_from_packet(pkt, 693.70) == 693.70
    assert V.meter_from_packet(pkt, None) is None
    rep, _ = R.build("electricity", {}, Source())
    labels = [m["label"] for m in rep["sections"][0]["rows"]]
    assert labels == ["Supply today", "Pump today", "Current", "Line voltage",
                      "Phase voltage"], labels


def test_a_line_voltage_needs_root_three_times_the_phase():
    odd = {"data": [{"dt": "x", "raw_data": "##,D!t,,230-230-230,300-300-300,"}]}
    assert "lineV" not in V.electricity_packet(odd)


# ---- controller and privacy ---------------------------------------------------------

def test_controller_report_shows_what_is_running():
    rep, patch = R.build("controller", {}, Source())
    facts = {f["label"]: f["value"] for f in rep["sections"][0]["rows"]}
    assert facts["Device"] == "SibhiSump"
    assert facts["Running now"].startswith("Vegetable · Program · 4 Veg, 6 Kulam"), facts
    board = rep["sections"][1]["rows"]
    assert {r["name"]: r["status"] for r in board}["4 Veg"] == "on"
    assert set(patch) == {"dcon", "valveNames", "program", "electricity"}
    power = {r["label"]: r["value"] for r in patch["electricity"]}
    assert power["Phase voltage"] == "228 / 223 / 264", power
    assert power["Current"] == "9.8 / 9.5 / 9.7" and power["Pump today"] == "6h 38m", power
    assert facts["Next program"].startswith("Coconut"), facts
    prog = patch["program"]
    assert prog["running"] and prog["name"] == "Vegetable", prog
    assert prog["valves"] == "4 Veg, 6 Kulam" and prog["remainingMin"] == 25, prog
    assert prog["at"] == {".sv": "timestamp"}, prog
    assert prog["next"] == {"name": "Coconut", "plannedMin": 60, "valves": "12 Coco 1, 15 Coco 2"}, prog
    assert set(prog) == {"at", "next", "name", "kind", "running", "valves", "start", "lastSeen",
                         "plannedMin", "remainingMin"}


def test_no_phone_number_or_imei_reaches_any_report():
    """The dashboard payload is the farm's phone book. Nothing from it but
    five named fields may reach Firebase, in any report."""
    for rtype in R.REPORT_TYPES:
        rep, patch = R.build(rtype, params_for(rtype), Source())
        blob = json.dumps([rep, patch])
        assert FAKE_PHONE not in blob and FAKE_PHONE[2:] not in blob, rtype
        assert "490154203237518" not in blob, rtype
        assert not re.search(r"\d{10,}", blob), (rtype, re.search(r"\d{10,}", blob))


def test_all_27_valves_survive():
    """The old cap of 16 dropped eleven of the farm's valves from every report."""
    assert len(V.normalize_dcon_valves(valves_payload(27))) == 27
    rep, _ = R.build("valves", params_for("valves"), Source())
    crop = rep["sections"][0]["rows"][0]
    assert crop["label"] == "Valves watered" and crop["note"].startswith("of 26"), crop


def test_backwash_minutes_are_not_counted_as_water():
    rep, _ = R.build("valves", params_for("valves"), Source())
    names = [b["name"] for b in rep["sections"][1]["rows"]]
    assert "3 Crop" not in names, names


# ---- composites and failure ------------------------------------------------------------

def test_every_report_builds_and_says_ok():
    for rtype in R.REPORT_TYPES:
        rep, _ = R.build(rtype, params_for(rtype), Source())
        assert rep["status"] == "ok", (rtype, rep.get("error"))
        assert rep["sections"] and rep["summary"], rtype
        assert rep["label"] == R.REPORT_LABELS[rtype]
        for sec in rep["sections"]:
            assert sec["kind"] in KINDS, sec
            cap = R.MAX_POINTS if sec["kind"] == "lines" else R.MAX_ROWS
            assert len(sec["rows"]) <= cap, (rtype, sec["title"], len(sec["rows"]))
            for row in sec["rows"]:
                assert all(not isinstance(v, (dict, list)) for v in row.values()), \
                    ("rows must stay flat for the iOS app", rtype, row)
            if sec["kind"] in ("lines", "stack", "matrix"):
                assert sec.get("legend"), (rtype, sec["title"])


def test_a_dead_leg_costs_a_section_not_the_report():
    rep, patch = R.build("session_log", params_for("session_log"),
                         Source(dead={"motor_log"}))
    assert rep["status"] == "partial" and "motor_log" in rep["error"], rep
    assert "timerLog" in patch and "motorLog" not in patch, patch


def test_every_leg_dead_is_an_error():
    rep, patch = R.build("performance", params_for("performance"),
                         Source(dead={"valves", "pressure_range"}))
    assert rep["status"] == "error" and patch == {}, rep


def test_a_single_call_failing_is_an_error_report():
    rep, patch = R.build("valves", params_for("valves"), Source(dead={"valves"}))
    assert rep["status"] == "error" and "502" in rep["error"] and patch == {}


# ---- power over time, and the new drawable kinds ----------------------------------

def test_power_range_reads_the_controllers_own_counters():
    rep, _ = R.build("power_range", {"from": "2026-09-22", "to": "2026-09-22"}, Source())
    tiles = {m["label"]: m for m in rep["sections"][0]["rows"]}
    assert tiles["Pump ran"]["value"] == "3h", tiles["Pump ran"]
    assert tiles["Pump ran"]["note"] == "of 23h 30m with power", tiles["Pump ran"]
    assert tiles["Supply cuts"]["value"] == 1
    assert tiles["Current, pump running"]["value"] == 9.1


def test_a_cut_packet_is_not_read_as_a_current():
    """0-0-0 during a cut passes the current rule by shape. Positions are
    learned from the packets that pass, then read by position in all."""
    rows = V.electricity_series(ELECTRICITY_DAYS, "2026-09-22 10:00:00",
                                "2026-09-22 10:05:00")
    assert rows and all(r["phaseV"] == [0, 0, 0] for r in rows), rows[:2]
    assert all(r["currentA"] == [0, 0, 0] for r in rows)


def test_voltage_line_breaks_at_a_cut_instead_of_joining_across_it():
    rep, _ = R.build("power_range", {"from": "2026-09-22", "to": "2026-09-22"}, Source())
    volts = next(s for s in rep["sections"] if s["title"] == "Voltage per phase")
    by_at = {r["at"]: r for r in volts["rows"]}
    assert "v0" not in by_at["2026-09-22 10:00"] and "v0" not in by_at["2026-09-22 10:15"]
    assert "v0" in by_at["2026-09-22 10:30"] and "v0" in by_at["2026-09-22 09:45"]
    assert len(volts["rows"]) == 96


def test_power_range_refuses_a_start_a_month_back():
    """The call returns everything from the start up to now."""
    old = (R.farm_now().date() - dt.timedelta(days=40)).isoformat()
    assert refused(req(type="power_range", **{"from": old, "to": old}))


def test_pressure_extremes_say_when():
    rep, _ = R.build("pressure_range", {"from": "2026-09-22", "to": "2026-09-22"}, Source())
    inlet = rep["sections"][0]["rows"][0]
    assert re.search(r"low [\d.]+ at \d\d:\d\d, high [\d.]+ at \d\d:\d\d", inlet["note"]), inlet
    lines = rep["sections"][1]
    assert lines["kind"] == "lines" and [l["key"] for l in lines["legend"]] == ["inlet", "outlet"]


def test_one_day_of_valves_is_a_grid_with_the_idle_ones_in_it():
    one = {"from": "2026-09-20", "to": "2026-09-20"}

    class OneDay(Source):
        def valves(self, a, b):
            p = valves_payload()
            for v in p.values():
                if isinstance(v, dict):
                    v["runtime"] = {"2026-09-20": v["runtime"]["2026-09-20"]}
            return p
    rep, _ = R.build("valves", one, OneDay())
    grid = next(s for s in rep["sections"] if s["kind"] == "grid")
    assert len(grid["rows"]) == 26 and any(r["status"] == "off" for r in grid["rows"])


def test_a_range_of_valves_is_a_valve_by_day_matrix():
    rep, _ = R.build("valves", params_for("valves"), Source())
    mx = next(s for s in rep["sections"] if s["kind"] == "matrix")
    assert [c["label"] for c in mx["legend"]] == ["09-20", "09-21"], mx["legend"]
    row = next(r for r in mx["rows"] if r["name"] == "1 Crop")
    assert (row["c0"], row["c1"], row["total"]) == (30, 70, 100), row


def test_motor_days_are_a_stack_of_power_and_pump():
    rep, _ = R.build("motor_log", params_for("motor_log"), Source())
    stack = next(s for s in rep["sections"] if s["kind"] == "stack")
    assert stack["unit"] == "h" and stack["rows"][0] == {"at": "2026-09-09", "total": 19.9,
                                                        "part": 14.4}, stack["rows"][0]


# ---- the relay transport -------------------------------------------------------

class _Ref:
    def __init__(self, store, path):
        self.store, self.path = store, path
        self.key = path.rsplit("/", 1)[-1]

    def push(self, value):
        key = f"-job{len(self.store.data)}"
        self.store.data[f"{self.path}/{key}"] = value
        return _Ref(self.store, f"{self.path}/{key}")

    def get(self):
        self.store.polls += 1
        if self.store.answer_after is not None and self.store.polls >= self.store.answer_after:
            return self.store.answer
        return self.store.data.get(self.path)

    def delete(self):
        self.store.deleted.append(self.path)
        self.store.data.pop(self.path, None)


class _Store:
    def __init__(self, answer=None, answer_after=None):
        self.data, self.deleted, self.polls = {}, [], 0
        self.answer, self.answer_after = answer, answer_after

    def reference(self, path):
        return _Ref(self, path)


def _packed(text):
    import base64, gzip
    return base64.b64encode(gzip.compress(text.encode())).decode()


def _relay(store):
    import dcon
    clock = iter(range(0, 10_000))
    return dcon.RelayTransport(store, wait=5, poll=0, clock=lambda: next(clock),
                               sleep=lambda s: None)


def test_relay_job_names_a_call_and_never_carries_a_secret():
    import dcon
    store = _Store(answer={"ok": True, "status": 200, "gz": _packed('{"status":"success","data":[]}')},
                   answer_after=2)
    body = dcon.Dcon(_relay(store)).valves("2026-09-20", "2026-09-22")
    assert body == {"status": "success", "data": []}
    # Both the job and its answer are gone once the call returns.
    assert any(p.startswith("relay/jobs/") for p in store.deleted)
    assert any(p.startswith("relay/results/") for p in store.deleted)


def test_relay_job_shape_is_call_and_dates_only():
    import dcon
    pushed = {}

    class Capture(_Store):
        def reference(self, path):
            ref = _Ref(self, path)
            if path == "relay/jobs":
                orig = ref.push
                def push(value):
                    pushed.update(value)
                    return orig(value)
                ref.push = push
            return ref
    store = Capture(answer={"ok": True, "status": 200, "gz": _packed("{}")}, answer_after=1)
    dcon.Dcon(_relay(store)).pressure_range("2026-09-22", "2026-09-22")
    assert set(pushed) == {"call", "args", "at"}, pushed
    assert pushed["call"] == "pressure_range"
    assert pushed["args"] == {"from": "2026-09-22", "to": "2026-09-22"}


def test_relay_failure_and_silence_are_plain_errors():
    import dcon
    for store, words in ((_Store(answer={"ok": False, "status": 403, "error": "HTTP 403"},
                                 answer_after=1), "403"),
                         (_Store(), "did not answer")):
        try:
            dcon.Dcon(_relay(store)).nodes()
            raise AssertionError("expected DconError")
        except dcon.DconError as err:
            assert words in str(err), err
        assert any(p.startswith("relay/jobs/") for p in store.deleted), "job left behind"


def test_dcon_client_cannot_reach_the_command_endpoint():
    """Reports are read-only. The client has one URL, and it is not /command."""
    src = (HERE / "dcon.py").read_text()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    body = code.split('"""', 2)[2]      # skip the module docstring
    assert "command" not in body.lower(), "dcon.py mentions a command endpoint"
    assert body.count("/v1/http/") == 1

def test_a_valve_that_did_not_answer_is_named():
    dash = json.loads(json.dumps(DASHBOARD))
    dash["MCON000TEST000"]["timers"]["current"]["valve_comm_error"] = "0-1-0-0-0-0-0-0-0-0"
    src = Source()
    src.dashboard = lambda: dash
    rep, patch = R.build("controller", {}, src)
    assert patch["program"]["faults"] == ["6 Kulam no signal"], patch["program"]
    facts = {f["label"]: f["value"] for f in rep["sections"][0]["rows"]}
    assert facts["Valve fault"] == "6 Kulam no signal", facts


def test_a_run_the_log_caught_part_way_is_so_far_not_stopped():
    """Read 22 minutes into an hour's run: "11m of 1h so far", never "stopped"
    (it read on Home as cut short, 2026-09-25). Once the hour and the slack for
    backwash pauses have passed, an unfinished run is stopped."""
    run = {"plannedMin": 60, "deliveredMin": 11, "finished": False, "endedBy": "",
           "start": "2026-09-24 23:40:08", "valves": ["17"], "backwashes": 1,
           "startedBy": "", "faults": [], "kind": "Program", "name": "Mango2"}
    at = V.parse_stamp("2026-09-25 00:01:57")
    assert R.still_going(run, at)
    assert R.run_row(run, {}, at)["detail"].startswith("11m of 1h so far"), R.run_row(run, {}, at)
    late = V.parse_stamp("2026-09-25 01:20:00")
    assert not R.still_going(run, late)
    assert "11m of 1h, stopped" in R.run_row(run, {}, late)["detail"]
    # A run the controller says was ended is stopped, however recent.
    assert not R.still_going({**run, "endedBy": "A8"}, at)
    # No read time (an old caller): the old wording.
    assert "stopped" in R.run_row(run, {})["detail"]
    # The metric counts it as going, not as stopped early.
    rows = R.timer_sections(V.timer_segments(TIMER_LOG), "", {}, "w", V.parse_stamp("2026-09-22 00:00:00"))[0][0]["rows"]
    assert "stopped early" in rows[0]["note"], rows[0]


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")
