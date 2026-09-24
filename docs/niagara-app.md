# The Niagara iOS app (the other farm's two motors), as it actually talks to the server

Captured 2026-09-24 with mitmproxy from the owner's iPhone: sign-out,
sign-in, both motors on and then off (the 7.5 HP one) or on (the zoned
one), the settings menus, and one setting change. About 100 requests. The
screens the app had cached (answered `304`) were fetched again afterwards
with the same read-only GETs so their bodies could be documented.

## Where the water goes

```
river ──[Livesky: "River Motor", 3φ]──▶ other farm
                                         ├─[Niagara "Wellmotor75HP", group "Water 7.5hp"]──▶ main farm ──[Mobitech DCON]──▶ 27 valves
                                         └─[Niagara "Well motor", group "GROUP ONE"]──▶ that farm's own drip zones (programs 1–6, 8 zones)
```

The first leg is in [livesky-app.md](livesky-app.md) and the last in
[mobitech-app.md](mobitech-app.md). Niagara support was removed from SNOF
on 2026-09-23 at the owner's request. This page is documentation only.

## Host and transport

- **Plain HTTP to a bare AWS IP**: `http://<niagara-host>:8080/api/v1/…`,
  an Express server (`X-Powered-By: Express`, weak ETags, lots of `304`s).
  The user agent is `NiagaraDripIrrigation/1 CFNetwork/…`, and every
  request carries a `deviceType: web` header. The host is in the raw
  capture.
- The login answer also hands the app an **MQTT broker** address with a
  username and password that the vendor publishes openly (the app also
  pulls them from a public GitHub file, below). The phone proxy carries
  only HTTP, so any MQTT traffic the app uses for live updates was **not**
  captured. Everything the app displayed came back over HTTP polling.
- On launch it fetches `raw.githubusercontent.com/<a developer's
  repo>/main/json.txt`, the same MQTT settings as remote config, from a
  personal GitHub repo.

## Sign-in: phone number only, no credential afterwards

```
PUT  /api/v1/signout   {"deviceToken":"<fcm>","userId":"<userId>","macAddress":"<ios vendor id>","deviceType":"1"}
                       → {"code":200,"message":"Successfully Logged Out"}
POST /api/v1/verifyUser {"countryCode":"91","mobileNumber":"<10 digits>"}  → {"code":200,"message":"Valid User."}
     (an OTP step happens here, client-side through Firebase: firebaseappcheck / www.googleapis.com, ~30 s)
POST /api/v1/signin1   {"language":"1","mobileNumber","mobileCountryCode":"91","deviceToken":"<fcm>","appId":1}
                       → {"code":200,"message":"Login Success","data":{
                            "regDetails":{userId, userName, mobileNumber, password, userType, macAddress, …},
                            "mqttIPAddress","mqttUserName","mqttPassword",
                            "groupDetails":[{userGroupId, groupName}, …]}}
```

- **`signin1` carries no OTP and no password.** The server accepts a phone
  number and trusts that the app checked the OTP.
- **The login answer includes the account's password as an unsalted MD5**,
  and it is the hash of a trivial, well-known password.
- **No request after sign-in carries any credential**: no `Authorization`,
  no cookie, no token. Every call is addressed only by numeric ids in the
  path (`user/<userId>/…/controller/<controllerId>`), and the server
  answered all of them. Signing out changes nothing about what the API
  will answer.
- The ids are small sequential integers. Whether other accounts' ids are
  answered the same way was **not** tested and must not be. The evidence
  above is enough.

## Reads

| Call | Answer |
|---|---|
| `GET controller/user/<userId>/cluster` | groups: `GROUP ONE`, `Water 7.5hp`. A third group, `Irrigation 5HP`, appears in the login answer, and asking for it gets `{"code":201,"message":"No controllers in group"}`. |
| `GET user/<userId>/cluster/<groupId>/controller` | **the live state** of each controller in the group. Polled every 2–5 s per open group. |
| `GET user/<userId>/subuser/0/controller/<controllerId>/menu/<91\|92>/settings[/<menuSettingId>]` | the settings screens (below) |
| `GET …/controller/<controllerId>/zoneset/<programNo>` | a program's zone set: `zone Set 1`, `ZONE001`…`ZONE008`, each with `Time`/`Liters` and `Time1..6`/`Liters1..6`, pre/post time and flow. All zeros here, so run times live on the controller. |

### The controller record

| Field | Example | Meaning |
|---|---|---|
| `userDeviceId`, `deviceName`, `model_Id` | `…`, `Well motor`, `5` | controller. The zoned one is model 5; the 7.5 HP one, `Wellmotor75HP`, is model 4 and sends no `liveMessage`. |
| `status` | `1` / `0` | **what the app last asked for** (on/off). It flips the moment a command is sent, so it is not the motor's state. |
| `msgcode`, `msgDesc` | `001` `MOTOR ON III PHASE`, `020` `MOTOR OFF III PHASE`, `045` zone open, `044` zone changed, `114` `ZONE SKIPPED BECAUSE OF NO FEEDBACK` | **the controller's own last report**: this is the state to trust |
| `ctrlLatestMsg` | `P1 ZONE=004 CLOSE ZONE=003 OPEN … Pout=21.90 … VRB=404;C1:08.6,C2:00.0,C3:08.4, DATE=… TIME=… M TIM=00:01:44` | the last message in full: zone change, pressure out, line voltage, phase currents, motor time |
| `liveMessage` (zoned controller) | `1,1,$L,  MOTOR ON III  ,VRB:404 AMP:08.9 ,233,232,234,402,403,404,08.9,116.3,08.9,Timer Mode 1,program1,003,V3:…,01:05:00,01:04:00,…` | CSV: motor text, phase-neutral and phase-phase volts, amps, mode, program, zone, valve, set/remaining time, … firmware `F2.9.6N` |
| `programNo`, `zoneNo`, `ZoneRunTime`, `zoneRemainingTime` | `P1`, `ZONE 003`, `00:00:32`, `01:04:28` | active program and zone |
| `Power`, `motorStatus` | `1`, `3 PHASE` | supply |
| `livesyncDate/Time` | `24/9/2026`, `22:12:14` | last live packet |
| `programList` | JSON string of six programs | names |
| `simNumber`, `deviceId` (IMEI), `ctrlLatestMsg … OPERATED BY:<phone>` | | personal data. Never mirror any of it. |

## Commands

### Motor on / off

```
PUT user/<userId>/subuser/0/controller/<controllerId>/manualstatus
    {"status":"1","sentSms":"MTRON,iPhone"}     → {"code":200,"message":"Controller status updated successfully"}
    {"status":"0","sentSms":"MTROF,iPhone"}
```

The server relays `sentSms` to the controller over its GPRS link, and the
phone sends no SMS itself. What happened:

| When | Controller | Sent | `status` | Controller's report |
|---|---|---|---|---|
| 22:08:48 | Wellmotor75HP | `MTRON` | 1 at once | `001 MOTOR ON III PHASE` within ~40 s |
| 22:09:30 | Wellmotor75HP | `MTROF` | 0 at once | `020 MOTOR OFF`, seen on the next read (the report said motor time `00:00:27`; the controller's clock runs ~2 min ahead of the server) |
| 22:10:02 | Well motor | `MTRON` | 1 at once | `SDDL` start delay counting down, then `MOTOR ON III` ~20 s later. Program 1 then **started by itself on zone 004**, which was skipped (`114 … NO FEEDBACK`), and the controller moved to zone 003 (`044`, 1 h 05 set). |

**Confirm through `msgcode`/`msgDesc`/`ctrlLatestMsg`, never through
`status`.** `status` only echoes the request.

**Starting the zoned motor starts its program.** Here Program 1 began
immediately, and the zones are the controller's to choose.

### Settings

```
GET  …/controller/<controllerId>/menu/92/settings/<menuSettingId>   → {menuItem, templateJson, smsFormat, sendData (current values), …}
POST …/controller/<controllerId>/menu/92/settings
     {"menuSettingId":486,"sendData":"{…changeFromValue:\"3\"…}","sentSms":"CHANGEFROM003","receivedData":""}  → {"code":200,"message":"SUCCESS"}
```

Every settings screen is described by the server as a template:
`templateJson` for the form, `smsFormat` for the controller keywords the
form can emit, and `sendData` for the saved values. Saving sends a keyword
the same way the motor buttons do. The one change captured was **CHANGE
FROM → 3** (`CHANGEFROM003`) on the zoned controller at 22:11:09. It
matches the program moving to zone 003 after zone 004 was skipped, which
suggests "resume the program from zone N". That reading is inferred, not
proven.

The two menus list the controller's whole keyword vocabulary:

- **91, the motor**: current settings (dry run, overload, auto restart),
  delay timers, voltage protection, timers (cyclic, RTC, max run), SMS,
  communication (APN, server IP/port, Wi-Fi), status checks (`STAT`,
  `CSQ`, `GETDATA`, …), number registration (`REG01`–`REG14`), view
  settings, other settings (CT, double pump, calibration), 2-phase, and
  sump/tank control.
- **92, drip**: common drip settings (valve feedback, cyclic restart,
  calculated flow, last zone, valve/feedback/fertiliser/mixer delays,
  pressure), day-count RTC and cycle queue, program common settings
  (fertigation modes), serial set, calibration, pump change-over
  (`MOTOR2..4`), backwash, drip sump, change-from, pump configuration,
  flow deviation, pH/EC and flow alarms.

Many of these change protection behaviour (dry-run, overload, voltage) or
the controller's server address. None should ever be sent casually.

## Raw data

`.context/mitm/all.jsonl` (the Niagara host's entries start at 22:07:20)
and `.context/mitm/niagara/fetched.json` (the re-fetched menus). They hold
the phone number, IMEIs, SIM numbers, the FCM token, the password hash and
the MQTT credentials. Never commit them or print from them.
