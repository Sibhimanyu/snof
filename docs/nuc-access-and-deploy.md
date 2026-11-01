# Getting into the NUC and deploying the add-on

> Since 2026-11-01 the primary path is section 0 (install from the repo, update
> from the apps). Sections 1 to 6 are the fallback and the original setup; the
> `local_snof_bridge` names in them apply to the local add-on only.

How the bridge was first deployed to the Home Assistant NUC on 2026-09-21, the
things that went wrong, and the procedure that is known to work. Written so the
next person (or session) does not rediscover any of it.

## The setup

| | |
|---|---|
| Host | Intel NUC running **Home Assistant OS** (HA Core 2026.6.x, HA OS 18.x) |
| Address | `homeassistant.local`, `192.168.68.200` on the farm LAN |
| Way in | **Advanced SSH & Web Terminal** add-on, port 22 |
| SSH user | `sibhiorchards` (uid 1000, wheel, **passwordless sudo**) — not `root` |
| SSH alias | `ha-nuc` in `~/.ssh/config`, key `~/.ssh/snof_ha` |
| Add-on source on the NUC | `/addons/snof_bridge/` (root-owned) |
| Supervisor API from SSH | works with `$(cat /run/s6/container_environment/HASSIO_TOKEN)`; see 6a |
| Add-on config/credentials | `/addon_configs/local_snof_bridge/` (root-owned, created on first start) |
| Add-on slug | local copy: `local_snof_bridge`, container `app_local_snof_bridge`. From the repo: `<hash>_snof_bridge` (see section 0); filter containers with `name=snof_bridge` |

Two facts about the SSH add-on drive most of the gotchas below: it has
`sftp: false` (so `scp` does not work), and its **protection mode** blocks the
`ha` CLI from talking to the Supervisor (so installs/updates go through the UI).

## 0. Install from the repo, update from the apps (primary path, from 2026-11-01)

The bridge is installed from this GitHub repo as a custom add-on repository,
and an admin updates it from the web or iOS app. `scripts/deploy-addon.sh`
(sections 2 to 6) stays as the fallback. The add-on still builds on the NUC
from its Dockerfile; nothing is prebuilt or published.

How it works. `repository.yaml` at the repo root makes the repo a Supervisor
repository. The Supervisor finds add-ons by globbing `**/config.*` (yaml, yml,
json) and ignoring any path that has a part starting with `.` or named
`rootfs`. In this repo that finds only `addon/snof_bridge/config.yaml`
(`.impeccable/config.json` is skipped because of its leading dot). Do not add
another `config.json/yaml` outside a dot-folder.

The repo is public (since 2026-11-01), so Home Assistant adds it with the plain
URL `https://github.com/Sibhimanyu/snof`, no token. Because the repo is public,
nothing secret may ever be committed: credentials live only in the add-on
options, Secret Manager, and `~/.config/snof`.

### Install (or the one-time migration from the local add-on)

1. HA > Settings > Apps > App store > menu (three dots) > **Repositories** >
   paste `https://github.com/Sibhimanyu/snof` > Add. Wait for it to clone.
2. Find **SNOF Firebase Bridge** under "SNOF add-ons" and **Install**. It builds
   on the NUC; the first build takes a few minutes.
3. **Migrating only:** open the old (local) add-on's Configuration and copy its
   options across by hand (`firebase_db_url`, `farm_slug`, `allow_control`,
   `dcon_*`, `allow_irrigation_control`, ...). Leave **`allow_remote_update`
   off for now**.
4. **Migrating only:** the slug changes from `local_snof_bridge` to
   `<hash>_snof_bridge` (the hash is 8 hex chars of the repo URL, so it can
   never be guessed; read it from `ha apps list` or the add-on's URL), and the
   config folder with it. `serviceAccount.json` is **not** copied for you. Find
   the new folder and stream the key in:
   ```bash
   ssh ha-nuc 'ls -d /addon_configs/*snof_bridge*'
   cat ~/.config/snof/serviceAccount.json \
     | ssh ha-nuc 'sudo tee /addon_configs/<hash>_snof_bridge/serviceAccount.json > /dev/null'
   ssh ha-nuc 'sudo chmod 600 /addon_configs/<hash>_snof_bridge/serviceAccount.json'
   ```
5. Start the new add-on and read its log (`Streaming live state changes`, and
   with the options on, the `Watching ...` lines):
   `ssh ha-nuc 'sudo docker logs $(sudo docker ps -q --filter name=snof_bridge | head -1) 2>&1 | tail -30'`
   (while both exist, `--filter name=snof_bridge` matches both; pick the one
   whose name is not `*_local_snof_bridge`).
6. **Migrating only:** once the new one is healthy, **stop and uninstall the
   local add-on** so two bridges never run at once (two bridges would both
   consume the command and irrigation queues; the stale one could act on a
   command the other already ran, and the `/relay` and heartbeat would flap).
   Then delete `/addons/snof_bridge` on the NUC so the local copy cannot come
   back, and check `ha apps list` shows only the repo one.
7. In the new add-on's Configuration set `allow_remote_update: true` if you
   want the apps to be able to update it, and restart. It needs `hassio_api`
   (already in `config.yaml`, role **manager**: the least role that may
   reload the store and update an add-on; the Supervisor's default role gets
   `/info` only, and `/addons/self/update` is excluded from the self-access
   bypass).

### Update from the apps

Push to `main` with a bumped `version:` in `addon/snof_bridge/config.yaml`.
The bridge asks the Supervisor to reload the store at most every 6 h and reads
its own version at most every 10 min, so within hours the apps show the farm
box row (web: account menu > Admin > Farm box; iOS: Account > Farm box) with
"Update to X". An admin presses it:

1. The app appends `{uid, at}` to `farms/<slug>/addon_update_requests` (rules:
   admins only, `at` = server time, nothing else).
2. The bridge re-checks admin, age (120 s), `allow_remote_update`, and that the
   Supervisor says an update exists; one update per 10 min. Every request node
   is deleted whether it ran or not.
3. It writes `meta/bridge/update = {state: "updating", from, to, at, by}` and
   calls `POST /store/addons/<slug>/update`. The Supervisor stops the container
   mid-update; that is expected and the apps show "Updating...".
4. On the next start the bridge settles the node: `done` if it is now running
   `to`, otherwise `failed`. Refusals and failures write `refused` / `failed`
   with a reason.

To update by hand instead: HA > Settings > Apps > SNOF Firebase Bridge >
Update (confirm in the dialog).

## 1. First-time SSH access

The Mac started with **no SSH keys at all** and the NUC's host key unpinned.

```bash
# Pin the NUC's host key (ed25519 only) under both names it answers to.
ssh-keyscan -T 6 -t ed25519 homeassistant.local  >> ~/.ssh/known_hosts
ssh-keyscan -T 6 -t ed25519 192.168.68.200       >> ~/.ssh/known_hosts

# A dedicated key so farm-deploy access can be revoked on its own.
ssh-keygen -t ed25519 -N "" -C "snof-bridge-deploy" -f ~/.ssh/snof_ha

cat >> ~/.ssh/config <<'CFG'
Host homeassistant.local ha-nuc
    HostName homeassistant.local
    User sibhiorchards
    IdentityFile ~/.ssh/snof_ha
    IdentitiesOnly yes
CFG
```

Then the public half (`cat ~/.ssh/snof_ha.pub`) goes into the add-on:

**Settings → Apps → Advanced SSH & Web Terminal → Configuration → ⋮ Menu →
Edit in YAML.** Change `authorized_keys: []` to a one-line flow sequence:

```yaml
authorized_keys: ["ssh-ed25519 AAAA... snof-bridge-deploy"]
```

Save, then **Restart** the add-on. Test with `ssh ha-nuc 'id'`.

Notes from doing this through browser automation: the YAML editor is
CodeMirror inside shadow DOM (`document.querySelector` cannot reach it), and
typing multi-line YAML gets auto-indented into garbage. The editor's own
**Find-and-replace** button with a single-line replacement avoids both.

Logging in as `root` fails with `Permission denied (publickey,password)` even
with a valid key: the add-on only accepts the username configured in its
`ssh.username` option.

## 2. Copying the add-on source

```bash
./scripts/deploy-addon.sh ha-nuc /addons/snof_bridge
```

The script is tar-over-ssh; rsync is not guaranteed on the add-on. The first
attempt failed two ways at once, both now handled in the script:

| Symptom | Cause | Fix in script |
|---|---|---|
| `tar: can't open '._snof_bridge': Permission denied` on the NUC | macOS tar emits AppleDouble `._*` members; busybox tar rejects them | `COPYFILE_DISABLE=1` and `--exclude='._*'` |
| Nothing extracted, `/addons/snof_bridge` missing | `/addons` is root-owned; `sibhiorchards` cannot write | Detects `sudo -n true` and extracts with `sudo tar` |

Verify: `ssh ha-nuc 'find /addons/snof_bridge -type f | sort'` (12 files).

## 3. Making the Supervisor see it

`ssh ha-nuc 'ha addons reload'` returns
`Error: unauthorized: missing or invalid API token` — the SSH add-on's
protection mode. Use the UI instead:

1. **Settings → Apps → Check for updates.** This is what reloads the local
   add-on store; nothing appears until you do it.
2. **Install app**, search `snof`, the add-on is listed under **Local apps**,
   or go straight to `/config/app/local_snof_bridge/info`.
3. **Install.** The image build takes ~100 s (pip installs aiohttp, google-auth,
   requests).

In this HA version add-ons are called **Apps**. `/config/addons` renders an
empty panel and `/hassio/*` returns 404.

## 4. Placing the service-account key

The key lives on the Mac at `~/.config/snof/serviceAccount.json` and must end
up at `/addon_configs/local_snof_bridge/serviceAccount.json`.

```bash
ssh ha-nuc 'sudo mkdir -p /addon_configs/local_snof_bridge'

# scp fails with "Connection closed" because the add-on has sftp: false.
# Stream the file through a pipe instead.
cat ~/.config/snof/serviceAccount.json \
  | ssh ha-nuc 'sudo tee /addon_configs/local_snof_bridge/serviceAccount.json > /dev/null'
ssh ha-nuc 'sudo chmod 600 /addon_configs/local_snof_bridge/serviceAccount.json'

# Do not trust the transfer; compare checksums.
shasum -a256 ~/.config/snof/serviceAccount.json | cut -c1-32
ssh ha-nuc 'sudo sha256sum /addon_configs/local_snof_bridge/serviceAccount.json' | cut -c1-32
```

The folder does not exist before the add-on's first start, hence the `mkdir`.

## 5. Configure and start

**Configuration** tab → set `firebase_db_url` to
`https://snof-live-default-rtdb.asia-southeast1.firebasedatabase.app` → Save.
**Info** tab → Start.

Logs: `ssh ha-nuc 'sudo docker logs app_local_snof_bridge 2>&1 | tail -30'`

A healthy start looks like:

```
Authenticated with Home Assistant 2026.6.4
Registry loaded: 13 areas, 19 devices, 1366 entities
Published snapshot: 698 entities across 18 domains
Streaming live state changes
```

## 6a. Deploying a change without touching the UI (preferred)

Confirmed working 2026-09-22. The `ha` CLI is blocked by protection mode, but
the SSH add-on holds its own Supervisor token at
`/run/s6/container_environment/HASSIO_TOKEN`, and the Supervisor **does**
authorize add-on management with it. That removes the UI entirely, along with
the confirmation dialog that has silently eaten an update before.

```bash
SSH_OPTS="-o ProxyCommand=none -o IdentitiesOnly=yes -i ~/.ssh/snof_ha"

# 1. Bump version: in addon/snof_bridge/config.yaml first, or Supervisor will
#    not consider it an update.
SSH_OPTS="$SSH_OPTS" ./scripts/deploy-addon.sh sibhiorchards@192.168.68.200 /addons/snof_bridge

# 2. Reload the local store, confirm the new version is seen, update, verify.
ssh $SSH_OPTS sibhiorchards@192.168.68.200 'T=$(cat /run/s6/container_environment/HASSIO_TOKEN)
  curl -s -X POST -H "Authorization: Bearer $T" http://supervisor/store/reload
  curl -s -H "Authorization: Bearer $T" http://supervisor/addons/local_snof_bridge/info \
    | python3 -c "import json,sys;d=json.load(sys.stdin)[\"data\"];print(d[\"version\"],d[\"version_latest\"],d[\"update_available\"])"
  curl -s --max-time 600 -X POST -H "Authorization: Bearer $T" http://supervisor/addons/local_snof_bridge/update'
```

`/store/reload` is the API equivalent of **Check for updates**; without it the
Supervisor keeps reporting the old `version_latest` and the update is a no-op.

Same thing through the CLI container, if you prefer words to curl (used for the
0.3.0 → 0.6.0 update on 2026-09-23):

```bash
ssh $SSH_OPTS sibhiorchards@192.168.68.200 '
  sudo docker exec hassio_cli ha store reload
  sudo docker exec hassio_cli ha apps info local_snof_bridge | grep -E "^(version|version_latest|update_available):"
  sudo docker exec hassio_cli ha apps update local_snof_bridge'
```

It must be `docker exec hassio_cli ha` — the host's own `/usr/bin/ha` carries no
Supervisor token and answers `unauthorized: missing or invalid API token`. And
it is `ha apps`, not `ha addons`, on this HA version; the old spelling warns and
still runs.

Verify at the destination regardless of which route was used:

```bash
ssh $SSH_OPTS sibhiorchards@192.168.68.200 \
  'sudo docker ps --filter name=app_local_snof_bridge --format "{{.Image}} | {{.Status}}"
   sudo docker exec app_local_snof_bridge ls /app/bridge/'
```

Checking that a *new file* exists inside the container beats grepping an old
one: a stale image fails the check outright instead of matching a line that
happens to be present in both versions.

## 6b. Deploying a change through the UI (fallback)

1. Bump `version:` in `addon/snof_bridge/config.yaml`. Without this the
   Supervisor never offers an update.
2. `./scripts/deploy-addon.sh ha-nuc /addons/snof_bridge`
3. **Settings → Apps → Check for updates.**
4. Open **SNOF Firebase Bridge** → **Update** → a confirmation dialog opens →
   **Update again inside the dialog.** The first click only opens the dialog.
   Walking away from it leaves the old image running with no error anywhere.
5. Verify at the destination, not at the button:

   ```bash
   ssh ha-nuc 'sudo docker ps --filter name=app_local_snof_bridge --format "{{.Image}} | {{.Status}}"'
   ssh ha-nuc 'sudo docker exec app_local_snof_bridge grep -c "<something only the new code has>" /app/bridge/main.py'
   ```

An unverified assumption, recorded honestly: the **Rebuild** menu item also
worked for several early redeploys, then one did not, and it was not checked at
the time. Whether Rebuild has its own confirmation step is unknown. Update
with the confirmed dialog is the path that has been proven end to end.

## Troubleshooting

| Symptom | Meaning | Do |
|---|---|---|
| `Host key verification failed` | NUC not in `known_hosts` | Step 1, `ssh-keyscan` |
| `Permission denied (publickey,password)` as `root` | Wrong user | Use `sibhiorchards` / alias `ha-nuc` |
| `scp: Connection closed` | `sftp: false` on the add-on | Pipe through `ssh ... sudo tee` |
| `ha ...` → `unauthorized: missing or invalid API token` | Protection mode | Use the UI |
| Add-on not in store | Local store not reloaded | Apps → Check for updates |
| Version bump not offered | Same | Same, then check `version:` was actually changed |
| Clicked Update, image tag unchanged | Confirmation dialog not confirmed | Step 6.4, then verify with `docker ps` |
| `ModuleNotFoundError: requests` on start | Old image | Requirements pin `requests`; rebuild |
| `Bridge connection error:` (blank) after 30 s, reconnect loop | Old image with the websocket deadlock | Fixed in 0.1.2+; verify image tag |

## Verification patterns that produced false alarms

Two shell idioms reported failures that were not real during this work:

- `grep -c pattern file` exits **1 when the count is zero**, so
  `cmd && echo ok || echo FAIL` prints FAIL on a clean log.
- `if cmd | head; then ...` tests **`head`'s** exit status, which is always 0,
  so the "found" branch runs regardless.

Capture output to a variable or file and test its length instead.
