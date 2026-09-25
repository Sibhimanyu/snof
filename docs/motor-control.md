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
app ──append──▶ /farms/<farm>/motor_commands/<id>   {motor, action, uid, at}
motor_command (onCreate only) ── gates, live read, lock, ONE send, confirm
      ──▶ /farms/<farm>/motor_command_results/<id>  {ok, confirming, verified, message}
      ──▶ /farms/<farm>/water/...                   the confirmed state, at once
```

## Gates (all must pass)

1. **RTDB rules**: an admin; `meta/motorControl/enabled` **and**
   `meta/motorControl/motors/<motor>` true (service account only, off by
   default, each motor armed on its own); no live `motor_lock`; `at` is the
   server's now; exactly `motor`, `action` (`on`|`off`), `uid`, `at`.
2. **The function re-checks all of it**, then:
   - once only (a claim ledger in a transaction; triggers are at-least-once);
   - **rate limits** in the same transaction: 15 s between any two motor
     commands, **2 min between changes to one motor**, **12 changes per motor
     per farm day**;
   - **a live read of the motor first**, refusing if it is already in that
     state, a change is still on its way (Livesky `-inprogress`; Niagara's
     request echo differs from the controller's report), its state is
     unknown, it tripped, has no power, or (Livesky) the starter is not
     connected or has not reported for 15 min.
3. **One send, never retried.** The lock is taken before sending; the motor
   is read every 10 s for up to 150 s until **its own report** shows the
   change (Livesky: `motor_status` settled without `-inprogress`; Niagara:
   the controller's `liveMessage`/`msgcode`, never `status`). Confirmed: the
   lock is released and the new state mirrored into `water/`. Not confirmed:
   the result says so and the lock is **left to expire** (200 s from sending),
   so nobody fires a second command blind. Livesky has left a command
   unapplied before; its own app then sent it again. SNOF does not.

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

## Still the owner's to decide

No cross-farm interlocks are built (for example: no 7.5 HP run while the
river motor is off). The questions in [water.md](water.md) still stand;
until they are answered, arm only the motors you are ready to switch by
hand, and switch them as you would in the vendors' own apps.
