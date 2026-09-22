# SNOF — Home Assistant → Firebase bridge

Mirrors Home Assistant state from the farm's Intel NUC into Firebase Realtime
Database and renders it, room by room, at https://snof-live.web.app.
Architecture, data shape and setup are in README.md — read it first.

## Hard rules

- **Never commit `serviceAccount.json`** or any `*-firebase-adminsdk-*.json`.
  It is a full-admin credential. It lives at `~/.config/snof/serviceAccount.json`
  (mode 0600) and is passed via `GOOGLE_APPLICATION_CREDENTIALS`.
- The dashboard is **read-only by design**. RTDB rules deny all client writes.
  Do not add a `/commands` path without an explicit request — it is a path from
  the internet to farm relays.
- Attribute export is an **allow-list** (`mapper.py::ALLOWED_ATTRS`). Add fields
  there deliberately; never switch it to a deny-list.

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
- macOS tar emits `._AppleDouble` members that busybox tar rejects; the deploy
  script sets `COPYFILE_DISABLE=1` for this.
- Firebase project `snof-live`, RTDB in `asia-southeast1`. Hosting injects
  config via `/__/firebase/init.js`; nothing project-specific is hardcoded.

## Testing

`cd addon/snof_bridge && python3 tests/test_logic.py` — pure-logic tests only
(mapping, filtering, room resolution, dedup stability). They do **not** cover
the async websocket/RTDB orchestration in `main.py`, which is where every real
bug so far has lived. Verify that path against the live NUC.

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
