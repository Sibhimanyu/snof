# The Livesky iOS app (river motor), as it actually talks to the server

Captured 2026-09-24 with mitmproxy from the owner's iPhone: sign-out, OTP
sign-in, the motor screen, notifications, settings, one **motor off**, auto
mode toggled off and back on, and the motor coming back on by itself.
About 100 requests. No certificate pinning. Values below are placeholders
(`<imei>`, `<jwt>`).

## Where it sits

Livesky is the GSM starter on the **river motor** (`device_name: "River
Motor"`, one 3-phase motor, `MOTOR:01`, a SIM7600 4G modem). It pumps river
water to the other farm, whose own motors run on Niagara
([niagara-app.md](niagara-app.md)). One of those feeds the main farm, where
Mobitech DCON takes over ([mobitech-app.md](mobitech-app.md)).

Livesky support was removed from SNOF on 2026-09-23 at the owner's request.
This page is documentation, not a plan to wire it back.

## Host

`https://gsm.liveskytech.com:3001` is the API, with JSON answers, ETags and
`304`s on repeat polls. The user agent is `SSC/1 CFNetwork/… Darwin/…`, and
the app sends version `4.2.8` at login. Everything else seen during the
capture (Zomato, Apple) belongs to other apps on the phone.

## Sign-in: OTP, then a 24-hour JWT

```
GET  /getdialingcode                                    → [{country, a3, dialingcode}] ×247   (no auth)
POST /send_mobile_otp   {"mobile_no":"<10 digits>","dialingcode":"91"}
                        → {"output":"Success","status":"Enter OTP sent to your phone number","usermail":"<email>"}
GET  /otpuserlogin?mobile_no=<10 digits>&dialingcode=91&mobile_otp=<6 digits>&app_version=4.2.8
                        → {"token":"<jwt>","output":"Success","user_id":"…","user_type":"user",
                           "mobile_no","email","name"}
POST /applogout         {"user_id":"…"}  (with the bearer)  → {"output":"Success"}
```

- The token is an **HS256 JWT**. Its claims are `usermail`, `session`,
  `mobile_no`, `iat` and `exp`, with **`exp` = `iat` + 24 h**. Every call
  after sign-in sends `Authorization: Bearer <jwt>`.
- The OTP travels in a GET query string, so it sits in any proxy or server
  access log.
- **Signing out does not revoke anything.** After `applogout` and a fresh
  sign-in, the *old* JWT still read `/getMotors` (200). No token or a fake
  one got `401 {"error":"You must be logged in."}`. The signature is checked
  and `exp` is presumably honoured, but a token stays good for its full 24 h
  whatever the phone does.
- No refresh call was seen. How the app renews an expired token without a
  new OTP is **unknown**, because this session signed in fresh. If it
  can't, unattended use would need an OTP every day.

## Calls (all `?imei=<imei>` + bearer unless noted)

| Call | Answer |
|---|---|
| `GET /getimeis` (no query) | the user's devices: `[{id, device_name, imei, imei_id, status, motor_status, motor, phase, number_of_motors, valve_status, fcm_reg_id, server_key, …}]`. This is the entry point, and the IMEI keys everything else. |
| `GET /getMotors` | **the live state** (below). Polled every 2–5 s while the motor screen is open. |
| `GET /getpowersettings` | protection settings: 3-/1-phase low/high amps and volts, dry-run and overload delays, CT coils, calibrations. Each value is encoded like its keyword (`3PLA06.5`, `DD80`, `OLON`). |
| `GET /getnotifications&page&msg_type=All[&perPage=3]` | the event log: `{id, motor_valve:"M", message, date_time:"06:44 PM . 24 Sep", pageCount}`. For example `MOTOR RUN IN 3 PHASE POWER.ON VIA APPLICATION.`, `…ON BY AUTO START TIMER.`, `MOTOR OFF BY MANUALLY.`, `3 PHASE POWER ON`, `POWER OFF.`, `Oh! SORRY UNABLE TO START MOTOR,…`. |
| `GET /getgraphdata&motor=MOTOR:01&hours=6` | empty here |
| `GET /getsensors`, `/getsensorsettings`, `/getvalves`, `/getvalvesettings` | empty: no sensors or valves on this kit |
| `GET /getwaterlevel` | two level-sensor slots, all `None` |

### `getMotors`: the state record

One row per motor. Most fields hold the controller's own status keyword
verbatim:

| Field | Example | Meaning |
|---|---|---|
| `time`, `timen` | `2026-09-24 21:59:18` | when the controller last reported (farm time) |
| `connection_status` | `connected` | GSM link to the server |
| `motor_status` | `MOTORON` / `MOTOROFF` / `MOTOROFF-inprogress` | running, and whether a command is pending |
| `l1/l2/l3_volt`, `l1/l2/l3_amps` | `475`, `10.2` | phase volts and amps (L3 amps `None`) |
| `runtime`, `stop_timer` | `RUNT:003:16:04`, `STOPT:001:33:10` | time on / time off since the last change, HHH:MM:SS |
| `mode` | `MOBILEMODE` | control mode |
| `auto_status_mobilemode`, `1p_status_mobilemode` | `GAUTOON`, `G1PON` | auto-start on power return; run on single phase |
| `auto_status_manualmode`, `1p_status_manualmode` | `MAUTOON`, `M1POFF` | the same, for manual mode |
| `cyclic_timer_status`, `present/set_cyclic_timer_*` | `CYCLICTIMEROFF`, `S_CYCON:0000` | on/off cycling |
| `run_timer_status`, `present_run_timer`, `set_run_timer` | `RTOFF`, `P_RT:0120`, `S_RT:0060` | run-for timer |
| `dueto_*`, `error_*` | `DLV:0`, `DDL:0`, `DOL:0` | trip reasons: low/high/unbalanced volts, amps, dry load, overload |
| `signal_strength`, `modem_model`, `mobile_network_type` | `25`, `MT:SIM7600`, `NT:4` | modem |
| `updated_by_app` | `0` | |

## Commands: `GET /applychange`

```
GET /applychange?imei=<imei>&keyword=<imei>@motor1@page1@<CMD>@…   (bearer)
→ text: "<account email>\n<imei>@MOTOR:01@<status>@RUNT:…@…"  (the full status line, with the new state marked -inprogress)
```

Observed, in order. Each one waited for the state to settle before the
next:

| When | keyword tail | Immediately | Settled (from `getMotors`) |
|---|---|---|---|
| 22:00:12 | `MOTOROFF` | `MOTOROFF-inprogress` | `MOTOROFF`, amps 0, `runtime` reset, **~20 s** |
| 22:00:54 | `AUTOOFF@AUTOON@AUTOOFF@AUTOOFF@` (the settings page's four toggles, sent together) | `GAUTOOFF-inprogress` | `GAUTOOFF`, ~30 s |
| 22:01:21 | `AUTOON@` | `GAUTOON-inprogress` | the next report still said `GAUTOOFF` |
| 22:01:57 | `AUTOON@` (sent again) | `GAUTOON-inprogress` | `GAUTOON`, and at 22:02:28 **the motor started by itself** (`MOTORON`, 10.1 A) |

So:

- A command is `<imei>@motor1@page1@` followed by one or more `@`-separated
  keywords. `page1` looks like the app screen the keywords came from.
- `-inprogress` on a field means "sent, not yet acknowledged". **The
  confirmation is `getMotors` dropping the suffix**, which took 20–40 s
  here. The `AUTOON` sent at 22:01:21 came back unapplied and had to be
  sent again, so confirm every command before trusting it.
- **Turning auto-start back on while the motor is off, with power
  present, starts the motor.** That is what happened at 22:02:28, with no
  `MOTORON` sent. Treat `AUTOON` as a possible motor start.
- How the four settings-page keywords map to fields is inferred from what
  changed. Only `GAUTO` visibly changed, and the manual-mode pair stayed
  `MAUTOON` / `M1POFF`. `MOTORON` itself was not captured, but the app's
  notification text ("ON VIA APPLICATION") shows it exists.

## Security notes (Livesky's, not ours)

- Every data call is keyed only by IMEI plus a bearer token. Whether the
  server checks that the IMEI belongs to the token's user was **not**
  tested, and must not be tested against anyone else's device.
- `getimeis` hands the app an `fcm_reg_id` and a `server_key` field
  (`None` here).
- `applychange` answers with the account email in plain text.

Raw capture: `.context/mitm/all.jsonl` (hosts `gsm.liveskytech.com:3001`).
It holds live JWTs, OTPs, the IMEI, a phone number and an email. Never
commit it or print from it.
