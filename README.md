# SNOF — Home Assistant → Firebase bridge

Mirrors live Home Assistant state from the farm's Intel NUC into Firebase
Realtime Database, and renders it room-by-room on a Firebase-hosted dashboard.

```
Home Assistant (NUC, HA OS)
  └─ add-on: SNOF Firebase Bridge        ← runs beside HA, no token to manage
        │  ws://supervisor/core/websocket   (SUPERVISOR_TOKEN, never leaves the box)
        │  filter → group by area → coalesce → rate-limit
        ▼
   Realtime Database   /farms/snof/…      ← service account writes the mirror
        ▼                ▲
   Firebase Hosting dashboard             ← Google sign-in, UID allowlist
                         │
                  /farms/snof/commands    ← the one client-writable path:
                                            append-only, controllers only,
                                            four domains, four services
```

The dashboard is an app, not a page: **Overview** (live totals, quick controls,
anything unavailable), **Areas** (a card per room), an **area detail** view
grouped by domain with toggles and brightness/speed sliders, and **All devices**
for search across everything.

## Controlling devices

Off by default, and gated three times over:

1. `allow_control: true` in the add-on options (plus `control_domains`).
2. `npm run grant -- someone@example.com --control` — a tier above `viewers`.
3. RTDB rules and `bridge/commands.py` both allow-list the same four domains
   (`switch`, `light`, `fan`, `input_boolean`) and four services
   (`turn_on`, `turn_off`, `toggle`, `set_percentage`).

`cover`, `lock` and `alarm_control_panel` are excluded on purpose. The dashboard
never reaches Home Assistant itself — it appends a command, and the bridge on the
NUC is the only thing holding a credential that can act on one. Commands older
than `control_max_age_seconds` (default 120) are dropped rather than run, so a
queue that builds up while the bridge is down does not fire all at once when it
returns.

## Documentation

| Document | Covers |
|---|---|
| [docs/HANDOFF.md](docs/HANDOFF.md) | **Start here** — current state and open items |
| [docs/nuc-access-and-deploy.md](docs/nuc-access-and-deploy.md) | SSH to the NUC; §6a deploys the add-on with no UI |
| [docs/device-control.md](docs/device-control.md) | The command path, its three gates, arming it |
| [docs/irrigation.md](docs/irrigation.md) | Vendor motor/valve mirror (Mobitech, Livesky, Niagara) and the Irrigation view |
| [docs/dashboard.md](docs/dashboard.md) | Front-end architecture and design system |
| [docs/firebase-deploy.md](docs/firebase-deploy.md) | Hosting, rules, the two-tier allowlist |
| [docs/testing-and-preview.md](docs/testing-and-preview.md) | Every suite and the fixture that matters |

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

## Getting into the NUC

The first-time access path, every failure hit along the way, and the deploy
procedure that is proven to work are in
[docs/nuc-access-and-deploy.md](docs/nuc-access-and-deploy.md).

## Working from a second machine

Everything here is in git except one file, deliberately: the Firebase service
account key. It is a full-admin credential for the database, so it is never
committed. Get it onto the new machine yourself:

1. Copy it from the machine that has it (`~/.config/snof/serviceAccount.json`),
   or download a fresh one from
   [the console](https://console.firebase.google.com/project/snof-live/settings/serviceaccounts/adminsdk).
   Generating a new key does not revoke the old one, so the running add-on
   keeps working either way.

   ```bash
   mkdir -p ~/.config/snof && chmod 700 ~/.config/snof
   # ...place the JSON at ~/.config/snof/serviceAccount.json...
   chmod 600 ~/.config/snof/serviceAccount.json
   ```

2. Tooling:

   ```bash
   cd tools && npm install
   firebase login          # same Google account that owns snof-live
   ```

3. To deploy the add-on you also need SSH to the NUC. Either copy
   `~/.ssh/snof_ha` across, or generate a new key and add its public half to
   the Advanced SSH & Web Terminal add-on's `authorized_keys`, then add to
   `~/.ssh/config`:

   ```
   Host ha-nuc
       HostName homeassistant.local
       User sibhiorchards
       IdentityFile ~/.ssh/snof_ha
       IdentitiesOnly yes
   ```

### Deploying a change to the add-on

```bash
./scripts/deploy-addon.sh ha-nuc /addons/snof_bridge
```

Then in Home Assistant: **Settings > Apps > Check for updates**, open
**SNOF Firebase Bridge**, press **Update**, and press **Update again in the
confirmation dialog**. That dialog is easy to miss - the first click only
opens it, and skipping the confirm silently leaves the old image running.
Bump `version:` in `addon/snof_bridge/config.yaml` or Supervisor will not
offer the update at all.

Verify the new code really landed rather than trusting the button:

```bash
ssh ha-nuc 'sudo docker ps --filter name=app_local_snof_bridge --format "{{.Image}}"'
```

### Deploying the dashboard

```bash
cd dashboard && firebase deploy --only hosting,database
```

## Data shape

```
/farms/snof/
  meta/    name, slug, entityCount, haVersion, updatedAt
            bridge/ { status, lastSeen, heartbeatSeconds, pending, writes }
  areas/   <area_id>/ { name, icon, floor }
  entities/<domain>/<object_id>/
            { entity_id, domain, name, state, area, attrs{}, lastChanged, lastUpdated }
  irrigation/  vendor motor/valve mirror (read-only, only when enabled):
            { motors[], controllers[], dcon{}, valves[], timerLog[], motorLog[],
              electricity[], pressure[], weather{}, meta{ sources{}, error } }
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

A power meter emitting 5x/second therefore costs 0.5 writes/second, not 5.
If a specific sensor is still noisy, add it to `exclude_entities`.

Writes also pass `?print=silent`, so RTDB answers 204 with an empty body
instead of echoing back everything just written. The bridge never reads that
echo and every byte of it is billed download.

Measured on this farm (698 entities, 13 areas):

| | |
|---|---|
| Stored tree | 207 KB (0.02% of the 1 GB limit) |
| Write rate | 0.083/sec, ~7,200/day (40% of that is the heartbeat) |
| Download per always-on dashboard viewer | ~60 MB/month |

RTDB bills storage and download only - there is no per-operation charge, so
the write count is not itself a quota item. Spark has no overage billing: if
a limit is hit the database stops serving until the month rolls over.

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
