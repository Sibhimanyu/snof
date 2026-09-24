# SNOF — Home Assistant → Firebase bridge

Mirrors Home Assistant state from the farm's Intel NUC into Firebase Realtime
Database and renders it at https://snof-live.web.app, where lights, switches and
fans can also be operated.

**Read [docs/HANDOFF.md](docs/HANDOFF.md) first** — current state, what is armed
and what is not, and open items. Then the doc for whatever you are touching:

| Touching | Read |
|---|---|
| The NUC or the add-on | [docs/nuc-access-and-deploy.md](docs/nuc-access-and-deploy.md) |
| Anything that can operate hardware | [docs/device-control.md](docs/device-control.md), [docs/irrigation-control.md](docs/irrigation-control.md) |
| `dashboard/public/` | [docs/dashboard.md](docs/dashboard.md) |
| Irrigation reports (Mobitech DCON) | [docs/irrigation.md](docs/irrigation.md) |
| Hosting, rules, the allowlist | [docs/firebase-deploy.md](docs/firebase-deploy.md) |
| Tests or the preview harness | [docs/testing-and-preview.md](docs/testing-and-preview.md) |
| `ios/` (native app) | [docs/ios-app.md](docs/ios-app.md) |
| Anything that calls Mobitech DCON | [docs/dcon-off-the-nuc.md](docs/dcon-off-the-nuc.md) |
| How the Mobitech app signs in and sends commands | [docs/mobitech-app.md](docs/mobitech-app.md) |

Architecture and data shape are in README.md.

## Hard rules

- **SNOF has its own Mobitech session** (owner's decision (c), 2026-09-24;
  rebuilt on docs/mobitech-app.md): sign-in is proved with a dashboard read
  before it is kept, senders record lastOk/lastRejected, admins can sign
  SNOF out. (a) and (b) are still open: commands stay FON/OFF.
- **The Mobitech command session comes from signing in** (2026-09-24):
  admins sign in to Mobitech with an SMS code from Admin (web) or Account
  (iOS); the token goes to `/private/mobitech` (admins write, no client
  reads) and consumers prefer it over the hand-set option. Never show or log
  it. Details: docs/irrigation-control.md.
- **No second valve change until the first is confirmed** (owner,
  2026-09-24): Mobitech accepts anything and its server cannot handle
  conflicts. `irrigation_lock` is taken before sending and held until the
  controller's own state shows the change (≤2 min of 10 s reads); RTDB rules,
  the consumer and the app all refuse while it is live. Never ship a valve
  path without it. Details: docs/irrigation-control.md.
- **The NUC runs the Home Assistant bridge and nothing else** (owner,
  2026-09-24). Every Mobitech DCON call, report reads and valve commands,
  belongs in Firebase Cloud Functions. Mobitech 403s every Google Cloud
  address, so this waits on a static egress IP it allowlists; until then the
  NUC's relay and irrigation_control keep running, and the dormant
  `irrigation_command` function takes over at cut-over. Never add new DCON
  code to the add-on. Plan, state and runbook: docs/dcon-off-the-nuc.md.

- **Never commit `serviceAccount.json`** or any `*-firebase-adminsdk-*.json`.
  It is a full-admin credential. It lives at `~/.config/snof/serviceAccount.json`
  (mode 0600) and is passed via `GOOGLE_APPLICATION_CREDENTIALS`.
- The dashboard can **operate devices**, added deliberately on 2026-09-21. The
  one writable path in the whole tree is `/farms/<slug>/commands`, and it is
  append-only, controller-only, and shape-validated in `database.rules.json`.
  Everything else still denies client writes. Three gates, all of which must
  keep holding:
    1. RTDB rules — only `acl/controllers/<uid> === true` may append, only the
       four domains, only the four services, `at` must equal server `now`.
    2. `bridge/commands.py` — re-checks the same things against its own
       allow-list, drops commands older than `control_max_age_seconds`, and
       deletes every node whether it ran or was refused.
    3. `allow_control` in the add-on options, **off by default**.
  `cover`, `lock` and `alarm_control_panel` are deliberately excluded at every
  layer. Adding one is a security decision, not a config tweak.
- **Irrigation control** (added deliberately on 2026-09-24, owner's request)
  is a second writable path, `/farms/<slug>/irrigation_commands`, with the
  same three gates plus more: **admins only** in the rules; the NUC
  (`bridge/irrigation_control.py`, not the read-only relay) re-validates,
  reads the controller first, allows only *Irrigation*-type valves (≤5),
  1–60 minutes, and spells the command from a fixed template; and
  `allow_irrigation_control` in the add-on options is **off by default**.
  Two actions only: `run` (Mobitech `FON …@A8`, Manual Mode, the controller
  ends it itself) and `stop` (`OFF@A8`, only while a Manual Mode run is
  active). Stopping or pausing a scheduled program (`@U` slots mean *pause*
  to Mobitech) and starting a program (`ET01-…`) are **not** offered — each
  is a separate decision. The format is in docs/irrigation-control.md.
  **Armed on 2026-09-24** (add-on 0.10.0, iOS 0.3.0): the four options were
  merged into the Supervisor options and the log says `Watching irrigation
  commands (run up to 60 min, stop manual runs) as A8`. `sent` was 0 at
  arming — the owner's first press is the first command this code sends.
  Disarm with `allow_irrigation_control: false` (merge, restart).
- **Unassigned entities do not exist to users** (add-on 0.9.0; since 0.9.2
  the owner's rule is "only devices with assigned rooms" — the entity's
  *device* must be in a room; an entity-level area alone does not count). An
  entity failing that is never published (`mapper.should_publish` →
  `registry.is_assigned`), `unassigned` is never written to `areas`, the RTDB
  rules refuse a command whose target is not under `entities/`, the bridge
  refuses it again (`is_visible`), and web/iOS drop any entity whose area is
  not a current room. Don't reintroduce an "Unassigned" group anywhere.
- **Counts are in devices, not entities** (add-on 0.9.3, web, iOS 0.1.7).
  The bridge puts `device` on every entity and publishes `devices/<id>/name`;
  the Overview tiles, area cards and "Not reporting" group by device
  (`byDevice()` in app.js, `Sorting.byDevice` in SNOFCore). A device is
  offline only when *every* entity on it is unavailable. Nav "All devices"
  and the device list still show entities.
- Attribute export and control are both **allow-lists**. Never invert either.
- Attribute export is an **allow-list** (`mapper.py::ALLOWED_ATTRS`). Add fields
  there deliberately; never switch it to a deny-list.
- Access has three tiers: `acl/viewers` (see), `acl/controllers` (see +
  operate), `acl/admins` (all of the above + add people and grant/revoke the
  other two tiers for anyone else, from the dashboard's `#/admin` page).
  Each implies the ones below it. An admin adds a viewer/controller by
  email from `#/admin` — that writes `acl/invites`, which the invited
  person's own first sign-in claims automatically (`enter()` in `app.js`).
  `npm run grant -- someone@example.com --control` still works and is the
  bootstrap/fallback path, but is no longer the day-to-day one.
- `acl/admins` is the one tier the dashboard can never hand out — RTDB rules
  refuse a client write to it no matter who is asking. Promoting an admin is
  always a command-line, service-account action
  (`npm run grant -- someone@example.com --admin`), never a click.

## Deploying the add-on (easy to get silently wrong)

Full runbook with every failure mode: `docs/nuc-access-and-deploy.md`. Summary:

1. Bump `version:` in `addon/snof_bridge/config.yaml` — Supervisor will not offer
   an update otherwise.
2. `./scripts/deploy-addon.sh ha-nuc /addons/snof_bridge`
3. HA UI → Settings → **Apps** → *Check for updates* → SNOF Firebase Bridge →
   **Update** → **Update again in the confirmation dialog**. The first click only
   opens the dialog. Skipping the confirm leaves the old image running with no
   error anywhere. This cost four hours once.
4. Verify inside the container, do not trust the button:
   `ssh ha-nuc 'sudo docker ps --filter name=app_local_snof_bridge --format "{{.Image}}"'`

Bridge logs: `ssh ha-nuc 'sudo docker logs app_local_snof_bridge 2>&1 | tail -30'`

## Environment facts

- HA is **HA OS** on an Intel NUC at `homeassistant.local` (192.168.68.200),
  HA Core 2026.6.x. Add-ons are called **Apps** in this version; URLs are
  `/config/apps` and `/config/app/<slug>/info|config|log`. `/hassio/*` 404s.
- SSH alias `ha-nuc` → user `sibhiorchards` (passwordless sudo), key
  `~/.ssh/snof_ha`. The SSH add-on has `sftp: false`, so **`scp` fails** —
  stream files with `cat f | ssh ha-nuc 'sudo tee dest'`.
- **Not every machine has that key or alias.** Check before assuming a deploy
  can run: `ls ~/.ssh/snof_ha` and `ssh -G ha-nuc`. See "Working from a second
  machine" in the README.
- Some machines carry a managed, host-wildcard `ProxyCommand` in `~/.ssh/config`
  (0Helper, `nc -X connect -x 127.0.0.1:3128`). It cannot reach a LAN address
  and fails with `nc: Proxy error: HTTP/1.0 503`. Work around it per-command
  with `-o ProxyCommand=none`, or `SSH_OPTS="-o ProxyCommand=none"` for
  `deploy-addon.sh`. Do not edit that config file; it is generated.
- macOS tar emits `._AppleDouble` members that busybox tar rejects; the deploy
  script sets `COPYFILE_DISABLE=1` for this.
- Firebase project `snof-live`, RTDB in `asia-southeast1`. Hosting injects
  config via `/__/firebase/init.js`; nothing project-specific is hardcoded.

## Testing

`cd addon/snof_bridge && python3 tests/test_logic.py` — pure-logic tests only
(mapping, filtering, room resolution, dedup stability, and the command
validator's refusal cases). They run with no dependencies installed, so keep
`aiohttp` imported lazily inside `commands.py`. They do **not** cover the async
websocket/RTDB orchestration in `main.py` or the command stream, which is where
every real bug so far has lived. Verify that path against the live NUC.

Dashboard: `dashboard/preview/` mocks Firebase so every screen renders
headlessly with no credentials. `cd dashboard/preview && npm run all`.
**Review with `?real=1`** — 698 entities, 373 unavailable, real Home Assistant
naming. Every bug found on 2026-09-22 was invisible on the clean 26-entity mock
and obvious on the real one.

When writing verification shell, remember `grep -c` exits 1 on zero matches and
`if cmd | head` tests `head`'s status — both produced false alarms here.

## Known state / open items

- Bridge dedups per entity (SHA-1 fingerprint) and resyncs incrementally on
  registry events. The resync path is verified present in the container but had
  not yet fired in production as of 2026-09-21.
- Most entities are `unassigned` because only ~19 of ~1366 registry entities
  have an area in HA, so from 0.9.0 they are hidden from the app entirely.
  Fixing that is an HA-side task; it flows through live.
- The SSH add-on config had a plaintext `password:`; the owner was advised to
  clear it now that key auth works. Confirm before assuming it was done.
- Add-on **0.6.0 is deployed and running** on the NUC as of 2026-09-23,
  verified by image tag (`local/amd64-addon-snof_bridge:0.6.0`) and by
  `REPORT_TYPES` reporting all fifteen types inside the container. It starts
  clean: 16 areas, 21 devices, 1380 entities, 713 published across 18 domains.
  0.4.x/0.5.0 were never actually updated in Supervisor — the box ran 0.3.0
  until this jump, which is exactly the silent-stale failure the deploy
  runbook warns about.
- Supervisor can be driven without the UI, which avoids the two-click trap:
  `sudo docker exec hassio_cli ha store reload` then
  `... ha apps update local_snof_bridge`, then re-read `ha apps info`. The
  host's own `/usr/bin/ha` has no token and answers "unauthorized"; the
  `hassio_cli` container is the one that works. `ha addons` is deprecated in
  favour of `ha apps`.
- This machine has **no `ha-nuc` alias** — `ssh -G ha-nuc` falls through to the
  managed wildcard `ProxyCommand`. Use
  `ssh -o ProxyCommand=none -i ~/.ssh/snof_ha sibhiorchards@192.168.68.200`,
  or the same via `SSH_OPTS` for `deploy-addon.sh`.
- Irrigation is **Mobitech DCON only** as of 2026-09-23. Livesky, Niagara and
  OpenWeather were removed at the owner's request — parsers, add-on options,
  report types and RTDB allow-list entries all deleted, not left dormant. Ten
  report types remain, three of them combining two controller calls.
- **Reports moved off the NUC on 2026-09-23** into a Python Cloud Function,
  `irrigation_report` in `dashboard/functions/` (codebase `reports`,
  asia-southeast1). It is triggered by a create on `irrigation_requests`, and
  the DCON token and serial are Secret Manager secrets `DCON_TOKEN_ID` /
  `DCON_SERIAL`. Add-on 0.8.0 removes `irrigation.py`, `vendors.py` and every
  `irrigation_enabled`/`dcon_*` option. Its heartbeat nulls
  `meta/bridge.irrigation`. Kill switch: `meta/reports/enabled: false`,
  service account only. Tests:
  `cd dashboard/functions && python3 tests/test_reports.py`.
- **Deployed 2026-09-24:** the Function, rules and hosting, plus add-on 0.9.1
  on the NUC (image tag verified). **Mobitech 403s every Google Cloud
  address**, so the Function cannot call it directly. Add-on 0.9.1 relays the
  eight named reads through `/relay/jobs` → `/relay/results` (`bridge/relay.py`,
  option `dcon_relay: true`, set by merging into the Supervisor options).
  Parsing and report building stay in the Function. Reports therefore need
  the NUC up again. Proven end to end: session_log and power_range both came
  back Ready from the live controller, and `/relay` refuses unauthenticated
  access. `DCON_TRANSPORT=direct` in `dashboard/functions/.env` (per machine,
  gitignored) switches back to direct calls.
- **The first live pull leaked.** `normalize_dcon_dashboard()` used to mirror a
  scrubbed dump of the whole node; the DCON dashboard payload carries the
  farm's phone book and the modem IMEI, and eleven numbers reached Firebase
  before being purged the same hour. Two defences now: the parser is a
  five-field allow-list, and `scrub()` redacts any run of ten or more digits
  anywhere in a string. Never widen a vendor parser to "everything else".
- Every parser was rewritten against real payloads on 2026-09-23 — all of them
  were wrong when written blind. `docs/irrigation.md` has the actual shapes
  and the full endpoint survey. The ones that bite: a timer_log `run_time` is
  *remaining*-planned, and one run is logged in pieces around a backwash every
  ~15 min (`join_runs()`). motor_log `ph3_runtime` is HH.MM supply-pump. The
  energy meter reset on 2026-09-10. Pressure is only sampled while the pump
  runs. Snapshot stamps must be farm time (+05:30), not the function's UTC.
  Aggregate over the whole response and cap only what is drawn — the old
  parsers capped at 32 rows first.
- Control is **armed** as of 2026-09-23: `allow_control: true`, the log says
  `Watching command queue for domains: fan, input_boolean, light, switch` and
  `Command queue stream open`, and `meta/bridge.control` is true. Set through
  the Supervisor API by merging the one key into the existing options object —
  never POST a partial options dict, the omitted keys revert to defaults.
  `commandsRun` was still 0 at the moment of arming, so the first real press is
  the first time this code has moved physical hardware. To disarm: set
  `allow_control` false the same way and restart.
- The dashboard reads `meta/bridge.control` (`bridgeGate()` in `app.js`) and
  `meta/reports.enabled` (`reportsGate()`). A capability that is switched off
  renders its controls disabled with the reason, instead of accepting a press
  and blaming the farm twelve seconds later. Reports no longer need a live
  bridge. The iOS app mirrors both in `Gate.evaluate`. The bridge still
  drains `/commands` at startup when control is off. The function deletes
  every `irrigation_requests` node it is handed.
- The SSH add-on had a plaintext `password:` in its options; it was still there
  on 2026-09-22 and should be removed and rotated now that key auth is proven.
- **iOS app released** on 2026-09-24: `0.1.9 (202609240755)` (reports as a
  list, each opening in its own sheet); before it `0.1.8 (202609240541)` (the
  "Area workspace" redesign), and before that `0.1.7 (202609240500)` (device counts), and `0.1.6 (202609240428)`, with the report charts (lines, stack, grid, matrix) and the reports gate; earlier `0.1.2 (202609231646)` (first: 0.1.0) at
  https://snof-ios.web.app (its own Hosting site, separate from the
  dashboard), installed through SideStore from `source.json`. `snof-live` is
  on **Blaze**, because Spark refuses `.ipa` files on Hosting. Release with
  `ios/scripts/release.sh "notes"`. **Proven on the owner's iPhone** (2026-09-23): Google sign-in works
  under SideStore's renamed bundle ID (`com.sibhiorchards.snof.<TEAMID>`),
  confirmed in Firebase Auth and by a fresh `acl/directory` write. (An earlier
  check found no sign-in only because none had been attempted yet.) Still
  untried from the phone: a device toggle and an irrigation report.
- **Design: "Area workspace"** (2026-09-24, owner's pick of option C): cool
  slate light theme + its dark complement, Manrope, eyebrow + large title on
  every page, tinted farm-pulse panel, device-level counts, All devices as a
  list of devices. Web deployed and iOS 0.1.8 released, both 2026-09-24. DESIGN.md and docs/dashboard.md
  describe it; `Theme.swift` mirrors `styles.css` value for value.
  **Softened to an iOS feel** the same day (owner): 22px cards on a soft
  shadow, 12px controls, iOS segmented nav, UISwitch-size toggles, frosted
  bars, press-scale, and iOS haptics (`Haptics` in Theme.swift). Web deployed,
  iOS 0.4.0. See DESIGN.md "Soft, iOS-like shape and depth". Dark mode is
  Apple's neutral dark (black / #1c1c1e / #2c2c2e), not the old
  charcoal-green — owner disliked it (iOS 0.4.1).
- **Brand** (2026-09-23): the logo green `#018843` is the brand colour and
  SNOF's only green, used on the web (deployed, commit `e741322`) and on iOS
  0.1.2. Fill with `--brand`/`Theme.brand`, and write green text with
  `--accent`/`Theme.on` (contrast-shaded). The logo and farm illustrations come from the
  DCON design-asset export; see DESIGN.md "Brand artwork" and `design/brand/`.
