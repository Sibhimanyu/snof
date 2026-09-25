# Motor control: on and off for the water-chain motors

Built 2026-09-25 at the owner's request: "their native apps have very low
checks … we should take careful measures and construct that safety from the
ground up … no motor can be turned on or off or manipulated with some random
automatically triggering cloud function … when we turn it off we have to
fetch and wait for it to confirm that it is off."

Motors: the **river motor** (Livesky, key `river`) and the other farm's
Niagara motors (keys are the water pull's slugs: `wellmotor75hp` sends water
to the main farm, `well-motor` runs that farm's drip zones). Code:
`dashboard/functions/motor_control.py`, the `motor_command` function in
`main.py`, the `motor_commands` rule in `database.rules.json`, `motorControls()`
in `app.js`, `MotorSwitch` (WaterView.swift) and `MotorControl` (SNOFCore).

## The path

```
admin presses Turn on/off → confirms (what happens, and that it is sent once)
app ──append──▶ /farms/<farm>/motor_commands/<id>   {motor, action, uid, at, clientAt}
motor_command (onCreate only) ── gates, live read, lock, ONE send, confirm
      ──▶ /farms/<farm>/motor_command_results/<id>  {ok, confirming, verified, message}
      ──▶ /farms/<farm>/water/...                   the confirmed state, at once
```

## Gates (all must pass)

1. **RTDB rules**: an admin; `meta/motorControl/enabled` **and**
   `meta/motorControl/motors/<motor>` true (service account only, off by
   default, each motor armed on its own); no live `meta/motorControl/lock`;
   `at` is the server's now and `clientAt` (the press, on the phone's clock
   corrected to the server's) within 30 s of it, so a press queued while
   offline is refused when it finally arrives; exactly `motor`, `action`
   (`on`|`off`), `uid`, `at`, `clientAt`. The apps also refuse to press
   while offline.
2. **The function re-checks all of it**, then:
   - a redelivered trigger does nothing: a command that already has a
     result, or whose queue node is gone, is never run again (so a refused
     command cannot run on a second delivery);
   - **one transaction** decides everything that could race: still armed,
     once only, no change in flight, **and takes the lock** — 15 s between
     any two motor commands, **2 min between changes to one motor**, **12
     changes per motor per farm day**. Cooldown and count are spent only when
     a command is actually sent;
   - **a live read of the motor first**, refusing if it is already in that
     state, a change is still on its way (Livesky `-inprogress`; Niagara's
     request echo differs from the controller's report), its state is
     unknown, it tripped, has no power, or (Livesky) the starter is not
     connected or has not reported for 15 min, or (the zoned Niagara
     controller) its live packets stopped 15 min ago;
   - disarming is re-checked just before the send.
3. **One send, never retried.** The lock is taken before sending; the motor
   is read every 10 s for up to 150 s until **its own report** shows the
   change (Livesky: `motor_status` settled without `-inprogress`, and for
   "on" current flowing; Niagara: the controller's `liveMessage`/`msgcode`,
   never `status`). A failed read is just another try. Confirmed: the lock is
   released (only by the command that holds it) and the new state mirrored
   into `water/`. Not confirmed, or a send whose answer was lost ("may have
   been sent"): the result says so and the lock is **left to expire** (340 s,
   longer than the function's 320 s budget),
   so nobody fires a second command blind. Livesky has left a command
   unapplied before; its own app then sent it again. SNOF does not.

## Zone change (the zoned Niagara controller)

Added 2026-09-25 at the owner's request. `action: "zone"` with `zone` 1-8
moves the **Well motor**'s running program to that zone, using the settings
menu's CHANGE FROM exactly as the Niagara app sends it (`POST
…/controller/<id>/menu/92/settings`, `sentSms: "CHANGEFROM00N"`, the item's
`menuSettingId` looked up by name each time). Its meaning ("continue the
program from zone N") is **inferred from one capture**, so it is fenced in:

- armed separately: `meta/motorControl/zones/<motor>` as well as the motor;
- only while that motor is **running a program** — it can never start one;
- only a zoned controller heard from in the **last 90 s**, never the current
  zone, never while a change is on its way, and only with **5+ minutes left**
  on the current zone (so a natural advance cannot land in the window);
- the menu item is looked up (and matched to the capture: template 128,
  keyword CHANGEFROM) and the state **read again right before the send**, so
  a program that ended meanwhile never gets it; a failed lookup is a refusal,
  not a send;
- the same lock and claim, its own cooldown and daily count (so zone changes
  never use up a motor's on/off budget), one send, never retried;
- confirmed only by a controller report **made after the send** carrying a
  zone event (044/045) for **that zone, the same program, still running**. If
  it stops, changes program or does not move, the result says exactly that
  and the lock stays until it expires.

Why these fences: the one capture shows CHANGE FROM sent *after* the program
had skipped a zone and gone idle, so its effect mid-program is unproven. The
first press is the proof; watch the controller when you make it.

**Stopping is never held back**: OFF ignores the cooldown and the daily cap
(only a change in flight blocks it).

## What can never be sent

Only the two commands per vendor exist in code: Livesky `MOTORON`/`MOTOROFF`
(`<imei>@motor1@page1@<CMD>`, `GET /applychange`), Niagara
`{"status":"1","sentSms":"MTRON,iPhone"}` / `{"status":"0","sentSms":"MTROF,iPhone"}`
(`PUT …/controller/<id>/manualstatus`). No auto-start (`AUTOON` starts a
stopped Livesky motor by itself), no timers, settings, programs or zones.
`MOTORON` was not in the capture; it follows the captured `MOTOROFF`, and the
confirmation step catches it if the starter does not act on it.

## Nothing automatic can reach a motor

The only trigger is an admin's own append, which the rules gate. No
schedule, no other function, no report and no water pull writes
`motor_commands` or names the command endpoints — `tests/test_motor_control.py`
fails the build if any other file does. `max_instances=1`, `concurrency=1`.

## Arming (service account only)

Off by default. Arm one motor at a time, with someone able to see it:

```bash
firebase database:update /farms/snof/meta/motorControl '{"enabled": true}' --project snof-live
firebase database:update /farms/snof/meta/motorControl/motors '{"river": true}' --project snof-live
firebase database:update /farms/snof/meta/motorControl/zones '{"well-motor": true}' --project snof-live   # zone changes
# disarm everything at once:
firebase database:update /farms/snof/meta/motorControl '{"enabled": false}' --project snof-live
```

Counters (`sent`, `refused`, `failed`), `lastByMotor` and today's counts sit
beside the switches in `meta/motorControl`.

## What the apps do

A motor card on the Water tab shows **Turn on** or **Turn off** only for an
armed motor, only to admins, and only the action that matches the motor's
current state. Closed, with the reason, while the reading is not current,
during any motor change (lock), during the motor's cooldown, or while its
state is unknown. The confirmation says what will happen ("Its drip program
starts with it"; "Auto-start is on: the starter may start it again when power
returns"), and that SNOF sends once and waits up to 2½ minutes.

## Known limits (review, 2026-09-25)

- The 7.5 HP Niagara controller sends no live packets, so SNOF cannot tell
  whether it is online before sending. Niagara's server answers `code:200`
  either way; whether it holds the command and delivers it when the
  controller reconnects is unknown. A pending request then blocks further
  presses (the request echo differs from the report). Check this at the pump
  before arming that motor.
- Livesky is a single-motor starter here (`motor1`); `MOTORON` is inferred.
- Two Niagara controllers with the same name would get keys by the API's
  order; today's names are distinct.

## Still the owner's to decide

No cross-farm interlocks are built (for example: no 7.5 HP run while the
river motor is off). The questions in [water.md](water.md) still stand;
until they are answered, arm only the motors you are ready to switch by
hand, and switch them as you would in the vendors' own apps.
