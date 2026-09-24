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

**Update, same day (mitmproxy capture, [mobitech-app.md](mobitech-app.md)):**
the token is the phone's Firebase push token plus `@ios`. Signing out and
back in on the same phone keeps it, so it changes only when the phone's push
token rotates. The app itself runs valves with `V…ON HH MM` and stops them
with `MOFF`, not `FON` / `OFF`, and confirms through `cmd_status`
(`sent: 2`).

Also seen in the history: Mobitech's own app sends manual runs as
`V003,000,…(10 slots)ON 00 15!1@A1` and, in the capture,
`V012,015ON 01 20@A8`; `FON …` appears too. Our `FON` template is taken from
accepted history entries; if a live token still gets 400 on a run while the
status poll succeeds, switch to the `V…ON HH MM` form.

## Signing in to Mobitech from the app (2026-09-24)

The session valve commands need is now created the way Mobitech's own iOS
app creates one (captured by the owner):

1. `POST /v1/otp/`, body `{"mobile":"91XXXXXXXXXX"}` as the whole
   form-encoded body: Mobitech texts a code.
2. `POST /v1/http/?` with `action=login&type=otp&otp&mobile` (10 digits)
   `&token=<device token>@ios&product=DCON&app_id=com.mobitech.drip`:
   `{"state":"ok","id":"<the same token>","name","uname",…}`.

The token is one the client makes up (shaped like the app's FCM token) and
Mobitech binds to the session; the `id` it echoes is what commands are sent
with. **Admin** on the web and **Account** in the iOS app (admins only) run
this directly against Mobitech (it allows any origin; it refuses Google
Cloud, so a function could not), then write the token to
`/private/mobitech` — admins may write it, **no client can read it**, only
the service accounts of the NUC and the function — and a non-secret line to
`farms/<farm>/mobitech_status` (name, username, last four digits, when).
The number and the code are never stored.

Both consumers take the signed-in token first and the old hand-set value
(`dcon_command_auth` / `DCON_COMMAND_AUTH`) only as a fallback; with
neither, a command is refused "not signed in to Mobitech". An expired
session now reads "an admin signs in to Mobitech again".
`scripts/set-mobitech-command-token.sh` stays as the manual fallback.
Unproven until the first sign-in: whether Mobitech keeps one session per
account (signing in here would then sign the phone's Mobitech app out, and
the other way round).

## Reconciled with the app capture (2026-09-24)

[mobitech-app.md](mobitech-app.md) is the ground truth for everything that
talks to Mobitech. Checked against it, harmlessly (fingerprints and shapes
only, no command sent):

**Corrections to the sections above**

- "The command token expires" is wrong in its cause. The token is the
  phone's FCM push token + `@ios`; it dies when that token is unregistered
  (a sign-out in the app) or rotates (reinstall, restore, new phone), not
  on a timer. Our code's message "the Mobitech session has expired" reads
  as a timeout; the real meaning is "Mobitech no longer accepts the command
  token".
- The add-on's read token `dcon_token_id` has the **same fingerprint as the
  capture's live command token**, and a dashboard read with it works. Only
  `dcon_command_auth` holds the dead 2025 Postman token. Commands and
  `token_id` take the same token, so a working one is already on the NUC.
  Putting it in place is open decision (a); not done.
- "Signing in to Mobitech from the app" (PR #18) **is open decision (c)**:
  a session of SNOF's own, with a client-made token that is not a real FCM
  token. The capture confirms the protocol but not that Mobitech accepts
  such a token, nor whether one user may hold two sessions (it might sign
  the phone out). It is deployed but has never been used:
  `/private/mobitech` and `mobitech_status` are empty. Pressing it is the
  owner's call.

**Settled by the capture**

- A manual run during a scheduled program: the controller's
  `timers.current` switches to *Manual Mode* on the requested valves
  (`start_control: MM`), displacing the program. So our run confirmation
  (manual, on those valves) sees it. The "unproven" note above is closed.
- A stop: after `MOFF` the interrupted program resumes (`start_control:
  TM`). Our stop confirmation ("no manual run going") is right for it.
- Timing: changes showed on the dashboard after 40–50 s, well inside our
  2-minute, 10 s-poll window.

**Still open, owner's call:** (a) the command token; (b) run/stop as
`V…ON HH MM` / `MOFF` with `cmd_status sent: 2` as an earlier yes (our code
still sends `FON` / `OFF`); (c) SNOF's own session.

## Mobitech sign-in, rebuilt on the capture (2026-09-24)

The owner asked for the Mobitech part of both apps to be rebuilt on the
login flow in [mobitech-app.md](mobitech-app.md), which settles open
decision (c): **SNOF has its own Mobitech session.** (a) and (b) remain
open: commands still go out as `FON` / `OFF`.

- **Sign in** (Admin on the web, Account in the app; admins): number, then
  `/v1/otp/` (its `{"message":"Success"}` is checked), then the code and
  `action=login` with a SNOF-made `…@ios` token. **Before anything is
  stored the session is proved** with a read-only `action=dashboard` using
  that token as `token_id`, one of the two calls that check it. A token
  Mobitech will not serve fails here, in words, and nothing is kept.
- **Kept** as before: the token in `/private/mobitech` (admins write, no
  client reads), a status line in `farms/<farm>/mobitech_status`.
- **Used for both token-checking calls.** The NUC (add-on 0.10.5) and the
  Cloud Function now read the controller's dashboard with the same signed-in
  token they send commands with, falling back to the old values.
- **Mobitech's verdict is recorded.** After each command the sender writes
  `lastOk` or `lastRejected` (service account) to the status line. The apps
  show "Mobitech rejected SNOF's session at … — sign in again", in the
  Mobitech section and, for admins, on the Irrigation screen. No polling.
- **Sign SNOF out** removes the token and the status line. Mobitech's own
  logout needs the token, which no client can read, so the registration
  stays at Mobitech, unused, until the next sign-in replaces it.
- The screen says what is still unproven: signing SNOF in may sign the
  phone's Mobitech app out if Mobitech allows one session per account.
