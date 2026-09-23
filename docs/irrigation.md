# Irrigation reports (vendor motors & valves)

The farm's pumps and valves are driven by vendor controllers, not Home
Assistant: a Livesky GSM unit on the river motor, Niagara controllers on the
well motors, and a Mobitech DCON unit for the irrigation valves and timers,
plus OpenWeather for field conditions. The Postman collection that captured
these APIs ("Mobitech Hack") lives outside the repo; nothing from it is
quoted here.

## How it works: the user builds the request

Nothing is polled — every vendor call answers a user pressing **Generate
report** on `#/irrigation`. An idle farm costs zero vendor traffic:

```
Dashboard report builder          Bridge (NUC)                     Vendor APIs
  pick type + dates          /farms/<slug>/                  Livesky / Niagara /
  press Generate ──append──▶ irrigation_requests              Mobitech / OWM
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

Five **combined** pulls and ten single-source ones. A combined report is one
press, two vendor calls, one card — they exist because the farm's questions
span vendors, and answering them from two cards left the correlating to the
reader. They cost two calls; the single-source reports stay for asking one
vendor exactly one thing, and for telling which vendor is broken.

| Builder label | Vendor calls | Dates? |
|---|---|---|
| **Motors — river and wells** | Livesky `getMotors` + Niagara `/controller` | no |
| **Controller and field conditions** | DCON `dashboard`+`get_node` + OpenWeather | no |
| **Power and pressure now** | DCON `reports?type=electricity` + `pressure_cond` | no |
| **Irrigation session log** | DCON `timer_log` + `motor_log`, woven into one chronology | from → to |
| **Valve runtime against pressure** | DCON `get_all_valve` + `reports?type=pressure_timer` | from → to |
| River motor status | Livesky `getMotors` | no |
| Well motor status | Niagara `/controller` per cluster | no |
| Controller dashboard | DCON `dashboard` + `get_node` | no |
| Field weather | OpenWeather `weather` | no |
| Electricity snapshot | DCON `reports?type=electricity`, stamped now | no |
| Pressure snapshot | DCON `reports?type=pressure_cond`, stamped now | no |
| Valve runtime | DCON `get_all_valve` | from → to |
| Timer log | DCON `logs?method=timer_log` | from → to |
| Motor log | DCON `logs?method=motor_log` | from → to |
| Pressure range | DCON `reports?type=pressure_timer` | from → to |

**A leg that fails costs a section, not the report.** Each call of a combined
report runs in its own `_leg()`; a failed one becomes an errored section with
a plain-word reason, and the card is tagged **Partly ready** rather than
Ready — a half-answer must never read as a whole one. Nothing from a failed
leg is written to the `/irrigation` last-results cache, so a dead vendor
leaves the previous good value standing rather than blanking it. All legs
failing is an ordinary `error` report.

## Setup

Off by default. In the add-on Configuration tab:

1. `irrigation_enabled: true` (combined reports and sections shipped in
   add-on 0.6.0 — update it on the NUC via the usual Supervisor flow).
2. Fill in only the vendors on the farm. Each is optional and fails
   independently — an unconfigured vendor's report errors with a
   plain-word reason on its card, and the rest still run:
   - Livesky: `livesky_bearer` (JWT — expires, renew it when the feed
     reports an error), `livesky_imei`.
   - Niagara: `niagara_base`, `niagara_user`, `niagara_clusters` as
     `"id:label"` entries, e.g. `"6039:Well Motor 7.5HP"`.
   - DCON: `dcon_token_id`, `dcon_serial` (`dcon_device_id`,
     `dcon_product` if they differ from defaults).
   - Weather: `owm_appid`, `owm_place` (e.g. `638673,in`).
3. Deploy rules with the dashboard (`firebase deploy --only
   database`), or the request write is refused.

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

## Response shapes

The collection was exported without saved responses, so `vendors.py`
parsers accept a list, a dict holding a list, or a single object, pick
from several likely key spellings, and degrade unknown states to
`unknown`. When live responses are seen, tighten the key lists against
real payloads — the tests in `tests/test_logic.py` pin the request
validator and the current parser behaviour, including the credential
scrub.
