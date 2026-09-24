# Irrigation reports (the DCON controller)

The farm's valves and timers are driven by a Mobitech DCON (MCON) controller,
not Home Assistant. Reports read it and nothing else.

Since **2026-09-23** reports run in a **Cloud Function**
(`dashboard/functions/`), not on the NUC. The NUC add-on no longer calls a
vendor API, holds no vendor credential, and has no irrigation options (0.8.0
removed them). Reports keep working when the farm's internet, the NUC or the
bridge is down, and changing one is a `firebase deploy`, not an add-on
release.

Livesky (river motor), Niagara (well motors) and OpenWeather were wired here
too until 2026-09-23, when the owner confirmed the farm does not use them.
They were removed rather than left dormant. The Postman collection that
captured these APIs ("Mobitech Hack") lives outside the repo; nothing from it
is quoted here.

## How it works

Nothing is polled. Every vendor call answers someone pressing **Generate
report**, so an idle farm costs nothing:

```
dashboard / iOS                     Cloud Function                 Mobitech DCON
  pick type + dates           irrigation_report (asia-southeast1)
  Generate ──append──▶ /farms/snof/irrigation_requests/<id>
                              (controllers only)
                                   │ onValueCreated
                                   ▼
                             validate ──1–3 read calls──────────▶  /v1/http/
                                   │
  render ◀──────────── /farms/snof/irrigation_reports/<id>   (no client writes)
                        /farms/snof/irrigation               (last-results cache)
                        /farms/snof/meta/reports             (status)
                             delete the request, always
```

1. The client appends `{type, from?, to?, uid, at}` to `irrigation_requests`.
   RTDB rules let controllers append and do nothing else there. It is the same
   tier as device control, because reports hit a vendor API.
2. `main.py` fires on the create. It checks the farm slug, skips a
   redelivered request whose report already exists, and runs
   `reports.validate()`: type allow-list, strict `YYYY-MM-DD` dates, `to` not
   before `from`, 31 days at most, and a request no older than 5 minutes.
   Then `reports.build()` makes that report's calls through `dcon.py` and
   writes the result. The request node is deleted either way.
3. The dashboard watches for its report id (60 s deadline), toasts
   Ready/Failed, and lists the last 20 reports newest first.

Files:

| File | What | Imports |
|---|---|---|
| `main.py` | trigger, secrets, RTDB writes | firebase-admin, firebase-functions |
| `dcon.py` | the eight read calls, nothing else | requests |
| `reports.py` | validation, one builder per report type | pure |
| `vendors.py` | parsers for each DCON response | pure |
| `tests/test_reports.py` | 35 checks, synthetic fixtures in the real shapes | nothing |

`cd dashboard/functions && python3 tests/test_reports.py` runs with nothing
installed.

### Credentials, switches, cost

- `DCON_TOKEN_ID` and `DCON_SERIAL` are **Secret Manager secrets**, bound
  only to this function. They never reach RTDB or a client. The token is an
  FCM-style app registration string ending in `@ios`.
- **Kill switch:** set `/farms/snof/meta/reports/enabled` to `false`, using
  the service account (clients cannot write `meta`). Every request then gets
  a plain "switched off" report and no vendor call. The dashboard and the iOS
  app read the same flag and disable Generate with that reason. No redeploy
  is needed.
- **Cost shape:** one invocation per press. Each takes 1–3 s at 512 MB, and a
  month of pressure data is ~2 MB and ~2 s. Capped at 2 instances. It never
  runs on a schedule and cannot trigger itself: it writes a create only
  outside `irrigation_requests`, and deleting the request is a delete. At
  this farm's volume that is well inside the free tier. The only standing
  cost is two Secret Manager secrets (inside the 6-version free tier) plus
  the function's container image in Artifact Registry.

Deploy: see `docs/firebase-deploy.md` → "Report function".

## How a result is presented

Each report is a list of **sections**, and each section declares its *kind*.
The dashboard draws by kind and never sniffs shapes:

| Kind | Row shape | Drawn as |
|---|---|---|
| `metrics` | `{label, value, unit, note}` | tiles, the headline numbers |
| `status` | `{name, status, meta, source}` | on/off board |
| `series` | `{at, value, unit}` | sparkline + min/latest/max |
| `bars` | `{name, value, unit, status}` | bar per row, value in **minutes** |
| `timeline` | `{at, event, detail, source}` | entries grouped by day, newest first |
| `facts` | `{label, value}` | key/value grid |
| `lines` | `{at, <key>…, on?}` + `legend` | multi-line chart, up to 96 points; a missing key is a gap; `on: 1` shades the window |
| `stack` | `{at, <whole>, <part>}` + `legend` | day bars: the whole (power available) with the part (pump ran) inside it |
| `grid` | `{name, value, unit, status, type}` | every valve as a tile, the idle ones dimmed and kept |
| `matrix` | `{name, total, c0…cN}` + `legend` (columns) | valve × day table, heat by minutes |

`legend` is a section-level `[{key, label}]`: which keys of a row to draw and
what to call them. Rows stay flat `{key: value}` maps, because the iOS app
reads every row as `[String: String]`, and a test fails any report whose rows
nest. Lines are told apart by weight and dash (accent, then the page's
greys), not by a rainbow.

These four kinds were added on 2026-09-23 after a look at how Mobitech's own
app charts the same data. Only *what* it charts was taken, not how it looks.

- **The browser parses nothing.** Durations, averages and joins all happen in
  the function, once.
- **Parse everything, cap only what is drawn.** A section carries at most 32
  rows, and the dashboard shows 8 and says how many more. Aggregates (totals,
  averages, bucketed series) are computed over the *whole* response first.
  The old NUC parsers capped before aggregating, so a one-day pressure report
  summarised the first 32 of ~4,000 samples, about six minutes of the
  morning. Their 16-row list cap also dropped 11 of the farm's 27 valves.
- **`bars` are minutes.** Old clients format a bar as `Xh Ym`, so kWh or
  hours per day go out as a `series`, which carries its own unit.
- **An unknown kind is skipped.** Adding one is safe for an open tab.
- **A leg that fails costs a section, not the report.** A combined report
  runs each call in its own `leg()`. A failed leg becomes an errored section
  and the card reads **Partly ready**. Nothing from a failed leg reaches the
  last-results cache.

## The reports

The original ten type names are unchanged, and `power_range` and
`pressure_hour` were added. Type names are the RTDB rule's allow-list and the
dashboard's and iOS app's builder values, and a test pins the rule to
`REPORT_TYPES`.

| Builder label | Calls | Dates | What it answers |
|---|---|---|---|
| **Power and pressure now** | electricity + pressure_cond | — | Is the pump drawing current and making head? Per-phase V and line V, current, supply/pump time today, voltage imbalance, inlet/outlet/filter drop. |
| **Irrigation session log** | timer_log + motor_log + get_node | range | Program runs and the pump's day in one chronology. Runs, water time, backwashes, faults, energy, pump hours vs power hours. |
| **Valve runtime against pressure** | get_all_valve + pressure_timer | range | Runtime per valve next to whether the line held. |
| Controller dashboard | dashboard + get_node | — | Device, clock, **what is running right now** (program, valves, minutes left), and the 27-valve board with the open ones lit. |
| Electricity snapshot | electricity | — | The power half of the first report. |
| Pressure snapshot | pressure_cond | — | The pressure half. "Pump off" when the controller has no samples. |
| Valve runtime | get_all_valve | range | Valves watered of 23, valve time, most watered, busiest day, backwash minutes. One day: a **grid of every valve**, idle ones kept. A range: a **valve × day matrix**, valve time per day, and runtime per valve. |
| Timer log | timer_log + get_node | range | Program **runs**, not log rows: finished vs stopped early, water time per program, backwash pauses, valve faults. |
| Motor log | motor_log | range | Energy (kWh), pump hours, power-present hours, pump share of available power, average draw (kW), **power and pump stacked per day**, energy per day. |
| Pressure range | pressure_timer | range | Inlet/outlet average with **when** the low and high happened, filter drop, inlet and outlet as two lines (15-minute windows for a day, 2-hourly for a week). |
| Pressure, last hour | pressure_cond from an hour back | — | The same, at 1-minute resolution. "Pump off" when there are no samples. |
| **Power over time** | electricity from the start date | range | Voltage per phase and current per phase as lines, gaps at supply cuts, pump-running windows shaded. Averages, imbalance, lowest and highest with phase and time, current while running with its peak, pump time against power time, supply cuts and the longest. |

**Deliberately not built: operating pumps or valves.** The collection
captures `/v1/command/` (valve ON/OFF, manual mode off). `dcon.py` has one
URL, `/v1/http/`, and no method for anything else, and a test fails if the
word "command" appears in its code. Turning a pump on from a browser tab is
the same class of decision as `cover`/`lock`. It would arrive through the
`/commands` queue with its own allow-list, never as a direct vendor call.

## Everything the API offers (surveyed 2026-09-23)

All read calls go to `https://dcon.mobitechwireless.com/v1/http/`, as either
POST form or GET query:

| Call | Form / query | Returns |
|---|---|---|
| `dashboard` | POST `action=dashboard&p=app&token_id&product=DCON` | device node keyed by serial |
| `get_node` | POST `action=dcon_node&method=get_node&serial_no` | valve registry, 3 field nodes, 27 valves |
| `get_all_valve` | POST `…&method=get_all_valve&from&to&serial_no` | per-valve, per-day runtime |
| `timer_log` | POST `action=logs&method=timer_log&serial_no&from&to` | timer segments |
| `motor_log` | POST `action=logs&method=motor_log&…` | one row per day |
| electricity | GET `action=reports&type=electricity&serial_no&dt&product` | packet 6 for **every minute from `dt` to now** |
| pressure now | GET `…&type=pressure_cond&dt` | samples at/after `dt` |
| pressure range | GET `…&type=pressure_timer&from&to` (datetimes) | every sample in the window |

Probed and **not** useful: `logs?method=valve_log` is `get_all_valve` under
another name. `logs?method=flow_log` answers with an empty list, because
there is no flow meter. Every other report type tried (flow, flow_timer,
energy, power, voltage, current, motor, water, level, moisture, temperature,
valve, fertigation, electricity_timer) returns `"Invalid request parameter"`.
Other log and `dcon_node` method names return an empty body. The table above
is everything there is.

## Response shapes, as they actually are

The first parsers were written blind and every one was wrong. These are the
real shapes, read against a full pull on 2026-09-23 (7 days of timers,
30 days of motor and valves, a full day of pressure).

**`dashboard`** is keyed by serial. Almost none of it is showable:

```
{"MCON874Q000568": {"device_id", "server_time", "time_zone", "sim": "vi-…",
   "packets": {"live": "##,DCON-…!<ts>+05:30,V68,SibhiSump,…", "1".."6"},
   "users": {"A1": {"name", "mobile"}, …},
   "timers": {"current": {…timer record…}, "previous": {…}, "next": null},
   "valve_details": {"1": {"valve_name", "valve_type"}, …}, …}}
```

Packets 1/4/8 are SMS recipient lists, `users` maps names to mobile numbers,
`sim` is the controller's own number, and packet 5 carries the modem IMEI and
firmware. **The first live pull put eleven phone numbers and the IMEI into
Firebase** (purged the same hour). The parser now returns five named fields
plus the two timer records, and `scrub()` redacts any run of ten or more
digits wherever it appears. A test builds every report from a dashboard
fixture full of numbers and fails on any 10-digit run in the output. Never
widen a vendor parser to "everything else".

`timers.current` is the live view: the program running now, its valves, and
its countdown. The controller report is built on it.

**`get_node`**: `{"Node1": {"type": "FL-10", "valve": {"4": {"valve_name":
"4 Veg", "valve_type": "Irrigation"}}}, "Node2": …, "Node3": …}`. This is the
only source of valve names. Types: Irrigation (23), Backwash, Master1,
Fertilizer, Booster Pump. Only `Irrigation` counts as water; the rest is
plumbing, and adding backwash minutes to crop totals would double them.

**`get_all_valve`**: keyed by valve number, runtime per day as `HH:MM`
(`"00:36"` is 36 minutes). Days with nothing are `"00:00"`, not absent.
Summing across valves gives *valve time*, not water time, because two valves
opened by one program count twice. The report says so.

**`timer_log` is segments, not runs.** Each row has `dt`, `last_sync`,
`timer_type` (1 program, 3 manual, 4 backwash), `timer_name`, `timer_no`,
`on_valves` (ten zero-padded slots), `run_time`, `completed`,
`start_control`, `end_control`, and three fault slot-strings
(`valve_comm_error`, `valve_not_on`, `valve_not_off`) aligned with
`on_valves`.

- `run_time` is **`remaining-planned`**, not `ran-planned`. One hour of
  Coconut logs as 00:50, 00:36, 00:23, 00:15, 00:06, 00:01 of 01:00.
- The controller **pauses every program for a ~3-minute backwash roughly
  every 15 minutes** and logs each piece as its own row: 111 backwashes in a
  week, 7 h 18 m of filter cleaning. Read row by row, one finished hour looks
  like six failed timers.
- `vendors.join_runs()` stitches segments into runs: same program, valves
  and planned length, counting down, less than 45 minutes apart. Backwashes
  inside a run are counted against it. Delivered time is planned minus the
  final remaining (the controller's own countdown, excluding pauses). One
  minute left reads as finished. On 2026-09-23, 273 rows became 45 runs.
- `start_control`: `TM` is timer and `MM` is manual. The log itself proves
  both. `A8`, `R1` and end codes `U1`, `U8`, `A1`, `PRH` appear unexplained
  and are shown as the controller spells them, not guessed at.

**`motor_log`**: one row per day, `dt1` + `time`, `ph3_runtime` as two
**HH.MM** durations (`"22.51-09.40"`), and the energy meter either side.

- The first duration is how long three-phase power was present. The second
  is how long the pump ran on it. They check out: pump time never exceeds
  supply, a 00.00 pump day used 0.0 kWh, and kWh over pump hours is a steady
  ~4.2–4.5 kW, one pump's draw.
- The meter **reset on 2026-09-10** (25678 → 171). A day whose end reading is
  below its start gets no energy figure, rather than a negative one, and the
  report names the day.
- The pump runs far longer than the programs ask (16 h on a day with ~4 h of
  program runs), so it is also filling the sump, not only irrigating. The
  session log puts both in one timeline for exactly this reason.

**`pressure_cond` / `pressure_timer`**: `{"dt", "pressure": "2.5-1.7",
"flow_rate": "0"}`.

- The pair is inlet and outlet across the filter. Their gap, the **filter
  drop**, is how clogged the filter is (avg 0.64 bar, up to 1.1 on
  2026-09-22). It is the figure backwash exists to bring down.
- `flow_rate` was `"0"` in all ~32,000 rows seen. There is no flow meter, so
  it is not reported.
- Samples come every ~11.6 s **only while the pump runs**: 4,164 samples on
  2026-09-22 is 13.4 h, and the motor log says 13 h 27 m. A gap means the pump
  was off, so empty buckets are skipped, never drawn as zero.
- **A snapshot needs a `dt` in the past.** The controller returns samples at
  or after `dt`, so asking for "now" returns nothing. The function asks for
  five minutes back in **farm time (+05:30)**. Cloud Functions run in UTC,
  and a UTC stamp would ask for samples five and a half hours old. A test
  pins this.

**`electricity`** returns one raw packet, no readings:

```
##,DCON-<serial>,6-0-0!2026-09-23 22:04:00+05:30,,255-249-264,436-443-448,
0.0-0.0-0.0,1.0-0-1.0,17.47-16.21,00.00-00.00,50.0,20,693.70,0.0,4.214-100,…
```

Each label is earned by shape plus a cross-check, never by position alone:

- Phase voltage is a triple, all 90–300 V.
- Line voltage is the triple whose mean is √3 × the phase mean.
- Current is the next triple in 0–100.
- `17.47-16.21` is today's supply/pump time, the same value the motor log
  carries.
- `693.70` equals today's motor-log `kilowatt_end`, so it is the meter.

`50.0` (probably Hz) and `4.214-100` stay unlabelled. A wrong label on an
electrical reading is worse than none.

**It is a history, not a snapshot.** `dt` is a start: the call returns every
packet from then to *now*, about one a minute (1,136 by 22:34 on 2026-09-23,
2,489 from the day before). It ignores any end date, which is why
`power_range` refuses a start more than 31 days back. The snapshot reports
take the newest. Three things this changes:

- During a supply cut the phase triple reads `0-0-0`, which the shape rules
  would call a current. `electricity_series()` therefore learns each field's
  position from the packets that do pass the rules (the index most of them
  agree on, across the whole response, before any window is applied), then
  reads every packet by position.
- Pump and power time come from the packet's own day counters (the HH.MM
  pair, reset at midnight), not from adding up gaps between packets. That
  overcounted by ~1.8 h a day. Read from the counters, 2026-09-22 ends at 20h
  13m power and 13h 27m pump, exactly the motor log's figures.
- Phase 3 reads 259–264 V all day while phases 1 and 2 swing 198–255 V. It is
  steady, not stuck, so nothing flags it. The imbalance figure (7–8%) is where
  it shows.
