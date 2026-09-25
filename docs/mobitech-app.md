# The Mobitech DCON iOS app, as it actually talks to the server

Captured 2026-09-24 with mitmproxy between the owner's iPhone and
`dcon.mobitechwireless.com`: sign-out, OTP sign-in, the home screen,
reports, starting two programs, a manual run and its stop. About 340
requests in total; no certificate pinning, so everything was decrypted.
App `com.mobitech.drip`, user agent `DCON/163 CFNetwork/… Darwin/…`, server
version answer `111`. The shapes below are real; values are placeholders
(`<serial>`, `<device_id>`, `<token>`).

Read with [irrigation.md](irrigation.md) (report payloads) and
[irrigation-control.md](irrigation-control.md) (our command path).

## Hosts

| Host | What for |
|---|---|
| `dcon.mobitechwireless.com` | Everything: sign-in, reads, commands. AWS ALB (`AWSALBTG` stickiness cookie, nothing else). |
| `api.openweathermap.org` | Home-screen weather, by the dashboard's `w_location` (a PIN code). The app ships its own key. |
| Firebase (`firebase-settings.crashlytics.com`, `firebaselogging-pa.googleapis.com`, `app-analytics-services.com`) | Crashlytics and analytics. Firebase is also where the push token comes from — see below. |
| `stackpath.bootstrapcdn.com`, `cdnjs.cloudflare.com`, `code.jquery.com`, `cdn.datatables.net` | A web view (Bootstrap + DataTables) the app uses for tabular reports. |

## Sign-in and the "token"

**The token is the phone's Firebase Cloud Messaging registration token with
`@ios` appended** (`<fcm-token>@ios`, 146 characters, the familiar
`xxxx:APA91b…` shape). The app makes it, not Mobitech. Sign-in does not
issue a credential. It *registers* this push token against the user.

```
POST /v1/otp/                     {"mobile": "91<10 digits>"}            → {"message":"Success","mobile":…}
   (SMS arrives)
POST /v1/http/  (form)            action=login&type=otp&otp=<6 digits>&mobile=<10 digits>
                                  &token=<fcm-token>@ios&product=DCON&app_id=com.mobitech.drip
                                  → {"state":"ok","id":"<fcm-token>@ios","user_id":…,"uname":"sibhi",
                                     "level":"11","name","mobile","mail",…,"prod":"DCON","auth":[]}
POST /v1/http/  (form)            action=logout&token_id=<fcm-token>@ios&product=DCON  → {"state":"ok"}
```

- `id` in the login answer is the token that was sent, echoed back.
- Signing out and back in on the same phone gave **the same token** (same
  SHA-1 before logout and after login). A token changes only when Firebase
  rotates the phone's push token, for example after a reinstall, a restore
  or a new phone. That, not a timeout, is the likeliest reason the 2025
  Postman token was dead.
- The server knows the Mobitech *user* from the token. It appends that
  user's slot (`@A8` for `sibhi`) to every command itself (see Commands).
- Before sign-in the app calls `POST /v1/version/`
  `{"app_id":"com.mobitech.drip","device_type":"IOS","app_environment":"prod"}`
  → `{version, is_force_update, update_message, update_url}`.

### Where the token goes

| Call | Carries it as |
|---|---|
| `action=dashboard` | form field `token_id=<token>` (URL-encoded, so `%40ios`) |
| `action=ferti&type=tank_log_web` | form field `token_id` |
| `action=logout` | form field `token_id` |
| `POST /v1/command/` | header `authorization: <token>` — **the app sends it URL-encoded, ending `%40ios`** (148 chars) |
| everything else | nothing |

Probed right after the capture with the harmless status poll `?`. Both
the `%40ios` form and the decoded `@ios` form got `200 "Command has been
sent successfully"`, and a token with its tail changed got `400 Bad
request`. So encoding does not matter, a live token works, and a dead or
unknown one gets the same 400 as a fake. That matches the earlier finding.

**Most reads carry no credential at all.** `dcon_timer`, `dcon_node`,
`logs`, `reports`, `ferti`, `getWliData`, `cmd_status` and the weather call
are answered for anyone who knows the serial number or device id. Only
`dashboard` and commands check the token.

### Consequences for SNOF

1. The NUC and the Cloud Function share the owner's phone session. Signing
   out in the app, or anything that rotates the phone's push token, kills
   our valve control, and the only sign is the 400.
2. The alternative is a session of our own: run `otp` + `login` once with a
   token of our own (any `…@ios` string), then use that token as
   `authorization`. It would outlive whatever the phone does. **Untried.**
   Nobody knows whether Mobitech accepts a string that isn't a real FCM
   token, or whether one user can hold two sessions. Trying it needs an OTP
   on the owner's phone, and it might sign the phone out. That decision is
   the owner's.

3. **One session per account, and the relay holds a copy** (2026-09-25).
   The NUC relay reads the dashboard with the add-on's `dcon_token_id`.
   Signing in anywhere else — the Mobitech phone app, or SNOF's own
   Mobitech sign-in — displaces it, and the dashboard then answers
   `{"state":"failed","message":"Your account has been sign-in on other
   mobile devices…"}`. That once read as "Not watering" (fixed: it is now an
   error, and the cache keeps the last good program). After any re-sign-in,
   set the add-on's `dcon_token_id` to the session in `/private/mobitech/token`
   (merge into the Supervisor options, restart — nuc-access-and-deploy.md 6a),
   or reads of "what is running" stop.

## Screens and their calls

### Home (polled every ~5–15 s while open)

| Call | Form | Answer |
|---|---|---|
| dashboard | `action=dashboard&p=app&token_id&product=DCON` (+`&serial_no` once a controller is chosen) | `{<serial>: {…}}`: `packets` (live, 1, 2, 4, 5, 6, 8, `users`), `timers.previous/current/next`, `valve_details`, `server_time`, `time_zone`, `sim`, `expiry_dt`, `w_location`, `emergency_shutdown_*`, `version` |
| dcon_node_details | `action=dcon_node_details&type=get&serial_no` | `{"data":[],"status":"success"}` here |
| tank | `action=ferti&type=tank_get&serial_no` | tank 1: nutrients, capacities |
| injector | `action=ferti&type=inj_get&serial_no` | injector 1 |
| fertigation | `action=ferti&type=get&serial_no` | empty |
| programs | `action=dcon_timer&method=select&serial_no` | every saved program (below) |
| valves today | `action=dcon_node&method=get_all_valve&from&to&serial_no` | per-valve runtime for the day |
| water level | `action=getWliData&serial_no&dt=` | three placeholder `1970-01-01` rows (no sensor) |
| rain | `GET /v1/weather/cumulative/?device_id&type=rain` | `{today,last24hrs,yesterday,week}`. The app first calls it without the trailing slash and follows the 301. |

`packets.users` is `A1`…`A9`, each `{name, image, mobile}`. It is the
controller's phone book, the one that leaked once (irrigation.md). Never
mirror it.

The dashboard lags the controller. The `live` packet's own timestamp ran
about 4 minutes behind `server_time` during the capture, and changes took
40–50 s to show up.

### Programs (`dcon_timer select`)

`{"action":"dcon_timer","1":{"<timer_no>":{group_name, valve_details, on_time,
off_time, on_days, backwash, motor_status, timer_status, data}}}`.
`valve_details` is ten dash-separated valve numbers. `on_time` is HH:MM.
`timer_status` 1/0 is enabled/disabled. On this farm: 25 programs, numbered
1–26 with no 5, including duplicate names (three `Coconut`, two `House`).
The number, not the name, identifies a program.

### Reports

| Report | Call |
|---|---|
| Electricity, live window | `GET /v1/http/?action=reports&type=electricity&serial_no&dt=<now−1h>&product=DCON` |
| **Electricity, whole day** (new) | `GET …&type=electricity_day&serial_no&product=DCON`: packet 6 every minute since 00:00 |
| Pressure, live window | `GET …&type=pressure_cond&dt=<datetime>` |
| **Pressure, whole day** (new) | `GET …&type=pressure_day&dt=<date>`: `{dt, pressure "a-b", flow_rate}` every ~11 s while the pump runs |
| Motor | `POST action=logs&method=motor_log&serial_no&from&to` |
| Timer log | `POST action=logs&method=timer_log&serial_no&from&to` |
| Fertiliser settings | `GET action=fertiSett&type=get&serial_no&product=DCON` |
| Tank log | `POST action=ferti&type=tank_log_web&…&p=app&from&to&token_id`, per tank per day |

`electricity_day` and `pressure_day` weren't in the 2026-09-23 survey, which
tried other names. Each returns a whole day in one call.

## Commands

All commands go to `POST /v1/command/` with the body sent as JSON (although
the content type says form) `{"device_id":"<device_id>","command":"…"}` and
header `authorization: <token>`. The answer is always
`200 {"message":"Command has been sent successfully","trans_id":<10 digits>}`.
That only means the command was accepted, not that it was carried out.

What the app sent, and what the controller then showed:

| Pressed | Command sent | Server stored as | Controller showed (`timers.current`) |
|---|---|---|---|
| (opening a screen, refresh) | `?` | — | a fresh `live` packet: a status poll, sent often |
| Start program *Coconut* (#2, 1 h) | `ET01-002-01 00` | `ET01-002-01 00@A8` | *Coconut*, valves 12-15, `start_control: A8`, ~40 s later |
| Manual run, valves 8 + 9, 10 min | `V008,009ON 00 10@A8` | `V008,009ON 00 10@A8@A8` | *Manual Mode*, `8-9`, `run_time 00:10`, `start_control: MM`, ~45 s later. It displaced the running program. |
| Stop the manual run | `MOFF` | `MOFF@A8` | Manual Mode ended and the interrupted *Coconut* resumed (`start_control: TM`). |
| Start program *Mango1* (#8, 1 h) | `ET01-008-01 00` | `ET01-008-01 00@A8` | *Mango1*, valve 16, `start_control: A8` |

So:

- **Start a program:** `ET01-<timer_no, 3 digits>-<HH MM>`. The duration
  the app sends is the program's own `on_time`.
- **Manual run:** `V<valves, 3 digits each, comma-separated>ON <HH> <MM>`.
- **Stop a manual run:** `MOFF`. After it, a program that the manual run
  interrupted carries on.
- The server appends `@<slot>` from the token's user, which is how the app
  can send the `@A8` suffix or leave it off. A doubled `@A8@A8` was still
  carried out.

**This is not what our code sends.** `irrigation_control.py` sends
`FON …-HH MM-<tail>!0--@A8` to run and `OFF@A8` to stop. Both appear in the
controller's command history and so were accepted at some point, but the
app itself uses `V…ON` and `MOFF`. Moving to the app's forms is the safer
choice. That is a change to the valve path and goes through the usual
review.

### Confirmation: `cmd_status`

After every real command (not after `?`) the app polls, every 5–15 s:

```
POST /v1/http/  action=cmd_status&random_no=<trans_id>&serial_no=<serial>
→ {sno, device_type, serial_no, dt, cmd: "DATA=<trans_id>$<command>@A8$A8!<serial>!$",
   sent: "1" | "2", device_id, user_id, platform: "ios", action}
```

`sent` went from `1` to `2` at the moment the change showed in the
dashboard, for both `ET01` (42 s) and `V…ON` (47 s). `2` therefore reads
as "the controller acknowledged it". `MOFF` stayed at `1` for the 51 s the
app kept polling, although the dashboard showed it had worked by then. So
`sent: 2` confirms faster than the dashboard, but its absence doesn't prove
failure. Our 2-minute confirmation should keep reading `timers.current`
and may accept `sent: 2` as an earlier yes.

## Reproducing the capture

mitmproxy (Homebrew) with the addon in `.context/mitm/capture.py`:
`mitmweb --listen-port 8888 -s capture.py -w flows.mitm`. On the iPhone, set
a manual Wi-Fi proxy to the Mac's port 8888, install the profile from
`http://mitm.it`, and turn on full trust under General → About →
Certificate Trust Settings. Afterwards remove the proxy and the profile.
The capture files hold a live token, the OTP and phone numbers, and stay
in `.context/` (gitignored).
