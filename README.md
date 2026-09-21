# SNOF — Home Assistant → Firebase bridge

Mirrors live Home Assistant state from the farm's Intel NUC into Firebase
Realtime Database, and renders it room-by-room on a Firebase-hosted dashboard.

```
Home Assistant (NUC, HA OS)
  └─ add-on: SNOF Firebase Bridge        ← runs beside HA, no token to manage
        │  ws://supervisor/core/websocket   (SUPERVISOR_TOKEN, never leaves the box)
        │  filter → group by area → coalesce → rate-limit
        ▼
   Realtime Database   /farms/snof/…      ← service account writes; clients cannot
        ▼
   Firebase Hosting dashboard             ← Google sign-in, UID allowlist, read-only
```

## Layout

| Path | What it is |
|---|---|
| `addon/snof_bridge/` | The Home Assistant add-on (Python). Deploy to `/addons` on the NUC. |
| `dashboard/` | Hosting site + RTDB security rules. |
| `tools/` | `grant-access.js` — manage the viewer allowlist. |
| `scripts/` | `setup-firebase.sh`, `deploy-addon.sh`. |

## This deployment

| | |
|---|---|
| Firebase project | `snof-live` |
| Dashboard | https://snof-live.web.app |
| RTDB URL | `https://snof-live-default-rtdb.asia-southeast1.firebasedatabase.app` |
| RTDB region | `asia-southeast1` (Singapore) |
| HA host | `homeassistant.local` (Intel NUC, HA OS) |

The RTDB URL is the value the add-on's `firebase_db_url` option needs.

## Setup order

1. **Name the Firebase project**, then `./scripts/setup-firebase.sh <project-id>`.
   It creates the project, writes `.firebaserc`, walks you through the three
   console clicks (RTDB, Google auth, service-account key) and deploys rules +
   dashboard.
2. **Deploy the add-on**: `./scripts/deploy-addon.sh root@homeassistant.local`,
   then in HA: Settings → Add-ons → Store → ⋮ → *Check for updates* → install
   **SNOF Firebase Bridge** from *Local add-ons*.
3. **Drop the service-account JSON** at
   `/addon_configs/<prefix>_snof_bridge/serviceAccount.json` (use the File editor
   or Samba add-on), set `firebase_db_url` in the add-on's Configuration tab, Start.
4. **Allowlist yourself**: open the dashboard, sign in once (you'll be refused —
   expected), then:
   ```bash
   cd tools && npm install
   export FIREBASE_DB_URL=https://<db>.firebaseio.com
   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
   npm run grant -- you@example.com     # npm run list / npm run revoke
   ```

## Data shape

```
/farms/snof/
  meta/    name, slug, entityCount, haVersion, updatedAt
           bridge/ { status, lastSeen, heartbeatSeconds, pending, writes }
  areas/   <area_id>/ { name, icon, floor }
  entities/<domain>/<object_id>/
           { entity_id, domain, name, state, area, attrs{}, lastChanged, lastUpdated }
```

`entity_id` is split on the dot because RTDB keys cannot contain `.`, `$`, `#`,
`[`, `]` or `/`. Domains and object IDs are already `[a-z0-9_]`, so the path is
always legal — there is a test pinning this.

Rooms are resolved the way HA itself does: the entity's own `area_id` wins,
otherwise it inherits its device's, otherwise `unassigned`. The dashboard groups
client-side, so there is no second index to keep consistent.

## What is deliberately not exported

The bridge uses an **allow-list** for attributes — a new integration cannot start
exporting fields nobody reviewed. On top of that:

- anything whose name contains `token`, `password`, `secret`, `auth`, `url`,
  `picture`, `mac`, `ssid` … is dropped even if allow-listed
- `device_tracker`, `person` and `geo_location` domains, and lat/long/altitude
  attributes, are off unless you set `expose_location: true`
- strings are capped at 255 chars, lists at 16 items

## Cost and quota

RTDB's free tier is 1 GB stored / 10 GB egress per month. Two guards keep a
chatty farm inside it:

- **coalescing** — every change inside `flush_interval_seconds` (1s) collapses
  into one multi-path PATCH, so 200 simultaneous updates cost one request
- **rate limiting** — `min_interval_seconds` (2s) caps each entity individually,
  always sending its newest value

A power meter emitting 5×/second therefore costs 0.5 writes/second, not 5.
If a specific sensor is still noisy, add it to `exclude_entities`.

## Liveness

The Admin REST API has no `onDisconnect`, so the bridge writes a heartbeat every
`heartbeat_seconds`. The dashboard compares `lastSeen` against
`.info/serverTimeOffset`-corrected time and shows **live / stale / offline** —
correct even on a wall tablet whose clock is wrong.

## Tests

```bash
cd addon/snof_bridge && python3 tests/test_logic.py
```

Covers room resolution, publish gating, the secret/GPS filters, RTDB key
legality and value capping. No network needed.

## Control (phase 2)

Deliberately not built yet. The rules deny all client writes, so nothing on the
internet can actuate farm hardware today. Adding control means a `/commands`
branch, per-UID write rules, and a bridge subscriber that forwards to HA
services — the paths above leave room for it without a rewrite.
