# The water chain (Livesky + Niagara), read-only

Added 2026-09-24 at the owner's request, reversing the 2026-09-23 removal
(git `0af4c68`). **Read-only.** Nothing in SNOF can switch any of these
motors yet; see "Control (not built)" below.

```
river ──[Livesky "River Motor", 3φ]──▶ other farm
                                        ├─[Niagara "Wellmotor75HP", group "Water 7.5hp"]──▶ main farm (Mobitech DCON, the Irrigation tab)
                                        └─[Niagara "Well motor", group "GROUP ONE"]──────▶ that farm's own drip zones (programs, 8 zones)
```

Vendor ground truth: [livesky-app.md](livesky-app.md), [niagara-app.md](niagara-app.md).

## Where it runs: Cloud Functions only

Both vendors answer Google Cloud addresses. On 2026-09-24 a throwaway
function in asia-southeast1 got Livesky's own `200` / `401` and Niagara's
Express `404`, the same answers as from the farm network. So unlike Mobitech
there is no relay, no static IP and nothing on the NUC.

| Function (codebase `reports`) | Trigger | Does |
|---|---|---|
| `water_poll` | every 10 min | one pull |
| `water_refresh` | create on `farms/<farm>/water_requests/<id>` | one pull, then deletes the node |
| `water_session` | HTTPS POST, Firebase ID token, **admins only** | Livesky SMS sign-in / sign-out |

A pull is 1 Livesky `getMotors` + Niagara `cluster` + one `controller` list
per group (3 groups, one empty). `claim_pull()` (a transaction on
`meta/water/pullClaim`) spaces pulls **≥15 s apart whoever asks**, and both
triggers are `max_instances=1`. The web page and the app ask every 30 s
while the Water screen is open and visible, and on pull-to-refresh / the
Refresh button. That is far gentler than the vendor apps (2–5 s).

Cost shape: ~4,300 scheduled runs/month plus at most 4/min while someone
watches. All within the free tier; the Cloud Scheduler job is one of the
three free ones. Loop audit: the refresh trigger writes `water/` and
`meta/water`, never `water_requests` except to delete, and a delete is not a
create.

## Kill switch and gates

- `farms/<farm>/meta/water/enabled` must be **true** (service account only).
  Anything else, and no vendor is called. The apps show "Water readings are
  switched off" and disable Refresh. Set to true on 2026-09-24.
- RTDB rules: `water_requests` is append-only for viewers, shape `{uid, at}`
  only. `water/` and `meta/water` have no client write. `/private/livesky`
  has no client read or write.

## Credentials

| What | Where | Why it's secret |
|---|---|---|
| Niagara base URL (bare IP, plain HTTP) | Secret `NIAGARA_BASE` | the host is not published |
| Niagara user id | Secret `NIAGARA_USER_ID` | **Niagara has no authentication**; the id in the path is the credential |
| Livesky JWT (24 h) + the starter's IMEI | RTDB `/private/livesky` | written only by `water_session` |
| Livesky host | param `LIVESKY_BASE` (default in code; per-machine `.env` must list it for non-interactive deploys) | public |

Niagara controller ids are discovered on each pull and never leave the
function. Motors are keyed by a slug of their name (`wellmotor75hp`,
`well-motor`).

**The Livesky session lasts 24 hours and no refresh call is known**, so an
admin signs in again with an SMS code: web Admin → "Livesky account", or iOS
Account. The function sends the code, logs in, proves the session with
`getimeis` (read-only, and the only source of the IMEI), and stores it. The
apps never see the token. When it expires the pull stops calling Livesky,
keeps the last reading and says so, and admins see a sign-in prompt on the
Water page. Livesky's own logout revokes nothing, so SNOF's sign-in does not
sign the phone out. The first session (2026-09-24) was the capture's own
fresh token, bootstrapped so the pipeline could be verified that night. It
ends ~2026-09-25 21:59.

## Data (`farms/<farm>/water`)

```
pulledAt
river:   {name, vendor:"livesky", running, pending, connected, reportedAt, volts[], amps[], power,
          runMinutes, stopMinutes, autoStart, trips[], signal}
motors/<slug>: {name, group, role:"main-farm"|"drip"|"", vendor:"niagara", model, running, requested,
          power, supply, event, eventCode, reportedAt, liveAt, volts[], amps[], pressureOut,
          program, zone, zoneRun, zoneLeft, skippedZone}
```
`meta/water`: `enabled`, `lastPull`, `livesky/{ok,error,at,expires,signedInAt,mobileLast4,by}`,
`niagara/{ok,error,at}`.

A vendor that fails keeps its last good state, with its error beside it.

**Current or not** (2026-09-25, `waterCurrent()` in app.js,
`WaterState.isCurrent` in SNOFCore): a motor is drawn as running (green, pipe
flowing) only when its vendor's last *good* read (`meta/water/<vendor>/at`,
stamped only on success — `pulledAt` is stamped on every pull) is under 10
minutes old and, for Livesky, whose starter reports every few seconds, its
own report is under 15 minutes old. Niagara reports on change, so an hour-old "motor on" with no
"off" since is still the state. Otherwise Home shows the last state with its
age ("Running · 2h ago", or "not read" once SNOF's Livesky session has ended),
the Water tab shows it in grey, and the card's header drops "just now" — the
pull's age would vouch for readings it did not refresh. "readings off" when
the kill switch is off.

## Parsing rules learned from the real payloads

- **Niagara `running`**: the zoned controller's `liveMessage` field 0
  (`1`/`0`). Zone events (044/045/114) *overwrite* `msgcode`, so `msgcode`
  alone loses the motor state. The 7.5 HP controller sends no live packet;
  its last `msgcode` 001/020 stands, then the words "MOTOR ON/OFF" in
  `msgDesc`, else unknown. `status` is only what the app last asked for, and
  it is shown as "on its way" when it differs.
- `liveMessage` positions kept: 0, 3, 5–7 volts, **11 and 13** currents, 21
  outlet pressure (matches `Pout`, unit unstated). Position 12 is not a
  current on this controller: 0.0 when C2 read 00.0, 116.3 a packet later.
- `ctrlLatestMsg` carries `OPERATED BY:<phone>`. Only its DATE/TIME
  (controller clock, ~2 min fast) and a skipped zone number are read.
- Livesky: `motor_status` minus `-inprogress`; any field ending
  `-inprogress` means a change is on its way. `stop_timer` while running is
  the previous off spell, so show run time when on and stop time when off.
  `clientip_port` (the modem's IP) is never kept.
- Everything passes `scrub()` (10+ digit runs redacted). Tests:
  `cd dashboard/functions && python3 tests/test_water.py`, fixtures with
  invented values.

First live pull (2026-09-24 22:44): river motor running 42 min at
467/457/453 V; the zoned motor on P1 zone 3; the 7.5 HP motor off. No long
digit run anywhere under `water/` except the `pulledAt` timestamp.

## Control

Built 2026-09-25: on and off, one motor at a time, confirmed by the motor
itself, off by default and armed per motor. See
[motor-control.md](motor-control.md). Still open, and still the owner's:

1. Do the Niagara "well" motors draw from wells, from storage the river
   motor fills, or both? Do they share one source?
2. What does the 7.5 HP motor fill at the main farm: a sump, a tank, or
   straight into the DCON mains?
3. Is the empty group "Irrigation 5HP" a retired motor or one still to come?
4. Livesky auto-start (`AUTOON`) stays out of scope: with power present it
   *starts* the motor. So do settings keywords and program starts.

Any cross-farm interlock (for example: no 7.5 HP run while the river motor
is off) is a new safety decision: propose it, and don't build it until the
owner agrees.
