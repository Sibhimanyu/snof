# SNOF — Home Assistant → Firebase bridge

Mirrors Home Assistant state from the farm's Intel NUC into Firebase Realtime
Database and renders it, room by room, at https://snof-live.web.app.
Architecture, data shape and setup are in README.md — read it first.

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
- Access has two tiers: `acl/viewers` (see) and `acl/controllers` (see + operate).
  `cd tools && npm run grant -- someone@example.com --control` grants both.

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

Dashboard: `.context/preview/` mocks Firebase so every screen — including the
signed-out, denied, viewer-tier and loading states — can be screenshotted
headlessly. `./sync.sh` re-copies the working tree into it; `node shoot.mjs`
shoots all of them and fails on any console error.

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
- Add-on **0.3.0 is deployed and running** on the NUC as of 2026-09-22, verified
  by image tag and by `commands.py` existing inside the container. It starts
  clean: 13 areas, 19 devices, 1366 entities, 698 published across 18 domains.
- Control is **deployed but inert** — the log line to look for is
  `Device control is disabled; not watching the command queue`. It stays that
  way until `allow_control: true` AND someone is granted `--control`. The
  command stream has therefore still never executed against real hardware.
- The SSH add-on had a plaintext `password:` in its options; it was still there
  on 2026-09-22 and should be removed and rotated now that key auth is proven.
