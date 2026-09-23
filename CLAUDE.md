# SNOF — Home Assistant → Firebase bridge

Mirrors Home Assistant state from the farm's Intel NUC into Firebase Realtime
Database and renders it at https://snof-live.web.app, where lights, switches and
fans can also be operated.

**Read [docs/HANDOFF.md](docs/HANDOFF.md) first** — current state, what is armed
and what is not, and open items. Then the doc for whatever you are touching:

| Touching | Read |
|---|---|
| The NUC or the add-on | [docs/nuc-access-and-deploy.md](docs/nuc-access-and-deploy.md) |
| Anything that can operate hardware | [docs/device-control.md](docs/device-control.md) |
| `dashboard/public/` | [docs/dashboard.md](docs/dashboard.md) |
| Irrigation reports (Mobitech DCON) | [docs/irrigation.md](docs/irrigation.md) |
| Hosting, rules, the allowlist | [docs/firebase-deploy.md](docs/firebase-deploy.md) |
| Tests or the preview harness | [docs/testing-and-preview.md](docs/testing-and-preview.md) |
| `ios/` (native app) | [docs/ios-app.md](docs/ios-app.md) |

Architecture and data shape are in README.md.

## Hard rules

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
  have an area in HA. Fixing that is an HA-side task; it flows through live.
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
- Reports are **armed and proven against the real controller** (add-on 0.7.4):
  `irrigation_enabled: true`, `dcon_token_id` and `dcon_serial` set through the
  Supervisor API. Verified live: controller (SibhiSump, 16 valves), power and
  pressure now, valve runtime against pressure (23h 4m over 11 valves,
  1.0–2.9 bar), session log (32 entries). The DCON token is a credential and
  lives only in the add-on options.
- **The first live pull leaked.** `normalize_dcon_dashboard()` used to mirror a
  scrubbed dump of the whole node; the DCON dashboard payload carries the
  farm's phone book and the modem IMEI, and eleven numbers reached Firebase
  before being purged the same hour. Two defences now: the parser is a
  five-field allow-list, and `scrub()` redacts any run of ten or more digits
  anywhere in a string. Never widen a vendor parser to "everything else".
- Every parser was rewritten against real payloads on 2026-09-23 — all of them
  were wrong when written blind. `docs/irrigation.md` has the actual shapes.
  A snapshot query needs a `dt` in the past: the controller returns samples at
  or after it and stores one every ~11 seconds.
- Control is **armed** as of 2026-09-23: `allow_control: true`, the log says
  `Watching command queue for domains: fan, input_boolean, light, switch` and
  `Command queue stream open`, and `meta/bridge.control` is true. Set through
  the Supervisor API by merging the one key into the existing options object —
  never POST a partial options dict, the omitted keys revert to defaults.
  `commandsRun` was still 0 at the moment of arming, so the first real press is
  the first time this code has moved physical hardware. To disarm: set
  `allow_control` false the same way and restart.
- The dashboard reads `meta/bridge.control` and `meta/bridge.irrigation.enabled`
  (one helper, `bridgeGate()` in `app.js`). A capability switched off on the
  bridge now renders its controls disabled with the reason, instead of
  accepting a press and blaming the farm twelve seconds later. Both consumers
  also drain their queue at startup when they are off — `/commands` and
  `irrigation_requests` are client-writable and only their consumer deletes
  from them.
- The SSH add-on had a plaintext `password:` in its options; it was still there
  on 2026-09-22 and should be removed and rotated now that key auth is proven.
- **iOS app released** on 2026-09-23: `0.1.2 (202609231646)` (first: 0.1.0) at
  https://snof-ios.web.app (its own Hosting site, separate from the
  dashboard), installed through SideStore from `source.json`. `snof-live` is
  on **Blaze**, because Spark refuses `.ipa` files on Hosting. Release with
  `ios/scripts/release.sh "notes"`. **Proven on the owner's iPhone** (2026-09-23): Google sign-in works
  under SideStore's renamed bundle ID (`com.sibhiorchards.snof.<TEAMID>`),
  confirmed in Firebase Auth and by a fresh `acl/directory` write. (An earlier
  check found no sign-in only because none had been attempted yet.) Still
  untried from the phone: a device toggle and an irrigation report.
- **Brand** (2026-09-23): the logo green `#018843` is the brand colour and
  SNOF's only green, used on the web (deployed, commit `e741322`) and on iOS
  0.1.2. Fill with `--brand`/`Theme.brand`, and write green text with
  `--accent`/`Theme.on` (contrast-shaded). The logo and farm illustrations come from the
  DCON design-asset export; see DESIGN.md "Brand artwork" and `design/brand/`.
