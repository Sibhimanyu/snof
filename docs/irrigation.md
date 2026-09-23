# Irrigation reports (the DCON controller)

The farm's valves and timers are driven by a Mobitech DCON (MCON) controller,
not Home Assistant. Reports read it and nothing else.

Livesky (river motor), Niagara (well motors) and OpenWeather were wired here
too until **2026-09-23**, when the owner confirmed the farm does not use them.
They were removed rather than left dormant: parsers, add-on options, report
types and the RTDB allow-list entries are all gone. A dead code path holding a
credential slot is worse than no code path. The Postman collection that
captured these APIs ("Mobitech Hack") lives outside the repo; nothing from it
is quoted here.

## How it works: the user builds the request

Nothing is polled — every vendor call answers a user pressing **Generate
report** on `#/irrigation`. An idle farm costs zero vendor traffic:

```
Dashboard report builder          Bridge (NUC)                    Mobitech DCON
  pick type + dates          /farms/<slug>/
  press Generate ──append──▶ irrigation_requests
                              (controller-only) ──1-2 calls──▶   ▲
  render card ◀──sanitized── irrigation_reports/<id> ──write──┘
                result       (bridge-only writes)
```

1. The dashboard appends `{type, from?, to?, uid, at}` to
   `irrigation_requests`. RTDB rules let controllers append and nothing
   else — same tier as device control, because reports hit billable vendor
   APIs. Viewers see results but get no builder.
2. `bridge/irrigation.py` streams the queue (same pattern as
   `commands.py`), validates the request — type allow-list, strict
   `YYYY-MM-DD` dates, `to` after `from`, max 31-day range, max 5-minute
   queue age — executes that report's one or two vendor calls with the
   credentials from the add-on options, and writes the normalized result to
   `irrigation_reports/<request-id>`. The request node is deleted either
   way, so nothing runs twice.
3. The dashboard watches for its report id (60s deadline with a plain-word
   timeout note), toasts Ready/Failed, and lists the last 20 reports
   newest-first. Each fulfilled report also refreshes the matching section
   of the `/irrigation` last-results cache (motors, valves, weather…).

## How a result is presented

A report is not a bag of rows the dashboard has to guess at. Each vendor call
contributes one or more **sections**, and the bridge declares the *kind* of
each one; the dashboard draws by kind and never sniffs shapes.

| Kind | Row shape | Drawn as |
|---|---|---|
| `metrics` | `{label, value, unit, note}` | tiles — the headline numbers |
| `status` | `{name, status, meta, source}` | on/off board (motors, valves) |
| `series` | `{at, value, unit}` | sparkline + min/latest/max |
| `bars` | `{name, value, unit, status}` | runtime bar per row, value in minutes |
| `timeline` | `{at, event, detail, source}` | log entries grouped by day |
| `facts` | `{label, value}` | key/value grid (the controller card) |

Three consequences worth keeping:

- **The browser parses nothing.** `"1h 20m"` becomes `80` in
  `vendors.runtime_minutes()`, on the NUC, once. A vendor spelling the
  dashboard has never seen costs one section, not a wrong chart.
- **An unknown kind is skipped, not guessed at.** A tab that has been open
  since before a new kind shipped ignores it and renders the rest, which is
  why adding one is safe.
- **`rows` is still there.** Every report carries its primary rows alongside
  the sections, so a dashboard build from before this change still renders
  something. The old shape-sniffing renderer survives as `irrLegacyBody()`
  for report history written before sections existed.

The visuals are the ones the DCON app suggests — flow, power, pressure,
duration — redrawn in this dashboard's own near-monochrome system rather than
copied: one accent hue for magnitude, the existing on/off green-vs-grey for
state. Hand-rolled inline SVG, no chart library, matching the no-framework
constraint the rest of the dashboard keeps. A `series` section with a single
reading degrades to that reading rather than drawing a flat line.

The dashboard never talks to a vendor API (CORS and secrets both forbid
it) and never sees a credential. Results carry presentation fields only —
names, on/off/unknown, runtimes, summaries, rows — capped the way HA
attributes are (strings 255, lists 16); `vendors.py` scrubs anything that
looks like a token, id or URL before it can reach the mirror.

## The reports

Ten of them, all reading the same controller. The first three are
**combined**: one press, two calls, one card. They exist because the questions
the farm actually asks span two endpoints, and answering them from two
separate cards left the correlating to the reader.

| Builder label | Controller calls | Dates? |
|---|---|---|
| **Power and pressure now** | `reports?type=electricity` + `pressure_cond` | no |
| **Irrigation session log** | `logs?method=timer_log` + `motor_log`, woven into one chronology | from → to |
| **Valve runtime against pressure** | `get_all_valve` + `reports?type=pressure_timer` | from → to |
| Controller dashboard | `dashboard` + `get_node` | no |
| Electricity snapshot | `reports?type=electricity`, stamped now | no |
| Pressure snapshot | `reports?type=pressure_cond`, stamped now | no |
| Valve runtime | `get_all_valve` | from → to |
| Timer log | `logs?method=timer_log` | from → to |
| Motor log | `logs?method=motor_log` | from → to |
| Pressure range | `reports?type=pressure_timer` | from → to |

**A leg that fails costs a section, not the report.** Each call of a combined
report runs in its own `_leg()`; a failed one becomes an errored section with
a plain-word reason, and the card is tagged **Partly ready** rather than
Ready — a half-answer must never read as a whole one. Nothing from a failed
leg is written to the `/irrigation` last-results cache, so a dead call leaves
the previous good value standing. All legs failing is an ordinary `error`
report.

## Setup

Off by default. In the add-on Configuration tab:

1. `irrigation_enabled: true`.
2. `dcon_token_id` and `dcon_serial`. `dcon_base`, `dcon_device_id` and
   `dcon_product` have working defaults and only need touching if the vendor
   changes them. The token is an FCM-style app registration string ending in
   `@ios`; it is a credential and lives only in the add-on options.
3. Deploy rules with the dashboard (`firebase deploy --only database`), or the
   request write is refused.

RTDB rules needed no new trust tier: `irrigation_requests` reuses the
controllers allow-list, and `irrigation_reports` has no client write rule,
so only the service account can produce a result.

## What is deliberately not built

**Operating pumps or valves.** The collection captures command endpoints
(DCON `/v1/command/`, valve ON/OFF) and the runner never calls them —
`validate()` refuses anything that is not one of the fifteen read-only types.
Turning a pump on from a browser tab is the same class of decision as
`cover`/`lock` — excluded at every layer until it is designed as one: it
would arrive through the `/commands` queue with its own domain allow-list
and validator cases, never as a direct vendor call. The page says so
("this page cannot operate pumps").

## Response shapes, as they actually are

The parsers were written blind against a collection exported without saved
responses. The first live pull, **2026-09-23**, showed every one of them was
wrong in some way. What the controller really returns:

**`dashboard`** is keyed by serial, and is mostly not showable:

```
{"MCON874Q000568": {"device_id": ..., "server_time": ..., "sim": "vi-76395…",
                    "packets": {"live": "##,DCON-…!<ts>+05:30,V68,SibhiSump,…",
                                "4": "##,DCON,9195…,9163…"},
                    "users": {"A1": {"name": …, "mobile": "9195…"}}}}
```

Packets 1/4/8 are SMS recipient lists, `users` maps names to mobile numbers,
`sim` is the controller's own number and packet 5 carries the modem IMEI. The
device name (`SibhiSump`) lives inside the `live` packet, not under any key.
An earlier `normalize_dcon_dashboard()` mirrored a scrubbed copy of the whole
node and **put eleven phone numbers and the IMEI into Firebase**; they were
removed the same hour. It now returns five named fields and nothing else, and
`scrub()` redacts any run of ten or more digits wherever it appears, because
DCON hides numbers inside comma-joined strings where no key names them.

**`get_node`** is the only source of valve *names* — `4 Veg`, `6 Kulam`,
`9 Mulberry`. Without it a runtime report is a list of integers.

**`get_all_valve`** is keyed by valve number, with runtime bucketed per day as
`HH:MM`. A window's runtime is the sum of its days, and `"00:36"` is 36
minutes, not 36 hours.

**`timer_log`** entries carry `timer_name`, `timer_no`, `completed`,
`run_time` and an `on_valves` string of ten zero-padded slots. **`motor_log`**
is a different shape again: no `dt`, but `dt1` (date) plus `time`, and each row
is a day's running total with the energy meter either side of it. Joining that
stamp matters — a bare `09:09:06` sorts into the wrong day of a merged
timeline.

**`reports?type=pressure_cond|pressure_timer`** returns
`{"dt": …, "pressure": "2.5-1.7", "flow_rate": "0"}`. The pair is inlet and
outlet; the series charts the inlet, because that is the number that answers
"did the line hold".

**`reports?type=electricity`** returns no readings at all — it returns the raw
controller packet. Only two groups in it are safely identifiable, a
phase-voltage triple and a phase-current triple, recognised by shape and
plausible range rather than by position. The rest is left unlabelled: a wrong
label on an electrical reading is worse than no label.

**A snapshot query needs a `dt` in the past.** The controller answers with the
samples at or after `dt` and stores one every ~11 seconds, so asking for the
current second returns an empty list. The bridge asks for five minutes back
and takes the newest row; the first live pull returned "no reading" for
exactly this reason.
