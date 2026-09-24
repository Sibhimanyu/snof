# Irrigation control (Mobitech DCON)

Added 2026-09-24 at the owner's request. **Off until armed** —
`allow_irrigation_control: false` in the add-on options.

## What it can do

| Action | Sent as | Effect | Who |
|---|---|---|---|
| Run valves | `FON 012,015,000,000,000-00 20-<zeros>!0--@A8` | Manual Mode on up to five Irrigation valves for 1–60 min; the controller stops by itself when the time is up | admins |
| Stop | `OFF@A8` | Ends a Manual Mode run (logged as `end_control: A8`) | admins, only while a manual run is active |

Not offered: starting a saved program (`ET01-<timer>-HH MM`), and stopping
or pausing a scheduled one. Mobitech's portal reads a `U` slot as "Pause
by", and the app sends `OFF@U1` for a program but `OFF@A1` for manual mode,
so program stop is ambiguous until it is tried deliberately.

## How the format was established

Read-only, from the farm's own account, on 2026-09-24:

1. `GET /v1/command/?device_id&from&to` (command history, the call
   Mobitech's portal uses) for 09-11 → 09-24. Every command the Mobitech app
   sent: `?` (status poll), `OFF`, `FON …`, `V008ON 02 00`, `ET01-…`.
2. `timer_log` for the same days, matched command by command:
   `FON 008,009…-00 10` at 08:01 on 09-17 → *Manual Mode, valves 8-9,
   run_time …-00:10*, and the `OFF@A1` after it → `end_control: A1`.
   `FON 007,017…-00 22` on 09-19 ran out by itself (`completed: 1`).
3. `@A8` is the Mobitech user slot, not a checksum: `sibhi` = A8,
   `gvkovai` = A1.

The command endpoint is `POST /v1/command/` with JSON
`{"device_id": "<dashboard device_id>", "command": "…"}` and header
`authorization: <app session token>@ios` — a different credential from the
`token_id` the read relay uses.

## The path

```
app (admin) ──▶ /farms/snof/irrigation_commands/<id>   {action, valves, minutes, uid, at}
NUC         ◀── stream; validate; get_node (Irrigation valves only);
                dashboard (refuse run only over another manual run, stop unless manual);
                POST /v1/command/
NUC         ──▶ /farms/snof/irrigation_command_results/<id>  {ok, status, message, valves, minutes}
```

The queue node is deleted whether it ran or not; commands older than 60 s
are dropped; at most one command per 10 s. The app waits 60 s for the result
and then refreshes the controller report 20 s after a success.

## Arming

Needs someone at the pump house for the first run. Merge these keys into
the Supervisor options (never POST a partial options dict):

```
allow_irrigation_control: true
dcon_device_id: "<device_id from the dashboard payload>"
dcon_command_auth: "<the Mobitech app's authorization value, …@ios>"
dcon_user_slot: "A8"
```

Restart the add-on; the log says
`Watching irrigation commands (run up to 60 min, stop manual runs) as A8`
and `meta/bridge.irrigationControl` becomes true. First test: one valve for
5 minutes, watch it open, press Stop, watch it close. To disarm, set
`allow_irrigation_control: false` the same way and restart.

## No second change until the first is confirmed (2026-09-24)

Owner's rule: Mobitech accepts every command and its server cannot handle
conflicts, so nothing may change a valve again until the controller's own
state shows the last change took. Enforced at every layer:

| Layer | What it does |
|---|---|
| RTDB rules | Refuse any new `irrigation_commands` node while `irrigation_lock/until` is in the future. Clients cannot write the lock. |
| Consumer (add-on 0.10.1 today, the `irrigation_command` function after cut-over) | Refuses while the lock is live; takes the lock before sending (`until` = send + 3 min); after a successful send writes the result with `confirming: true`, re-reads the dashboard every 10 s for up to 2 min (at most 12 reads, gentle on a weak server) until `timers.current` shows it — a run: a Manual Mode run on the requested valves (`on_valves`); a stop: no Manual Mode run — then writes `verified: true/false` and releases the lock. |
| iOS 0.4.0 | Run and Stop stay locked while its own command is pending or confirming, or while the farm's lock is live; says "Confirmed" only on `verified: true`, and "not confirmed after 2 minutes — check before trying again" on `false`. |

Consequence to know: Stop is locked too while a change is being confirmed
(usually well under 2 minutes). The lock expires by itself after 3 minutes,
so a crash mid-confirmation cannot block control for ever.

## A scheduled cycle does not block a manual run (2026-09-24)

Owner: "the cycle timer is ongoing but the manual mode should still work".
`check_against` refuses a run only while a **manual** run is active (two
manual commands would collide); a scheduled program such as Coconut running
on its timer no longer blocks it. Stop is unchanged: manual runs only.

Unproven: what the dashboard's `timers.current` shows while a manual run
overlaps a cycle. Confirmation reads it; if a manual run during a cycle ends
"not confirmed" although the valves opened, switch confirmation to the
timer_log (a timer_type 3 / start_control MM entry after the send), built
against a real payload, not blind.

## The command token expires (found 2026-09-24)

The first two real presses came back `400 {"message":"Bad request"}` and
never reached the controller (its command history has nothing after 09-23).
Probed from the NUC, harmlessly (the status poll `?@A8`):

| authorization sent | Mobitech's answer |
|---|---|
| the stored token | 400 Bad request |
| an obviously fake token | 400 Bad request — identical |
| none | 400 Unauthorized access |

The stored token was byte-for-byte the one in the Postman capture, whose
requests are dated 2025-05-06: a Mobitech app *session* token that had long
ended. Device id, headers and body shape all match the capture. There is no
login call in the capture, so a fresh token has to be captured from the app
(the `authorization` header, ending `@ios`) and put in place with
`scripts/set-mobitech-command-token.sh`, which reads it from the clipboard,
merges it into the add-on options and the DCON_COMMAND_AUTH secret, and
proves it with a status poll. Both consumers now turn this 400 into "the
Mobitech app token has expired" instead of "Bad request". Signing in to the
Mobitech app again ends the session, so expect to repeat this.

Also seen in the history: Mobitech's own app sends manual runs as
`V003,000,…(10 slots)ON 00 15!1@A1` and, in the capture,
`V012,015ON 01 20@A8`; `FON …` appears too. Our `FON` template is taken from
accepted history entries; if a live token still gets 400 on a run while the
status poll succeeds, switch to the `V…ON HH MM` form.
