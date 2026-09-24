# Where this was left — 2026-09-25 (overnight)

Start here. Everything below links to a document that goes deeper.

## State of play

| Piece | Status |
|---|---|
| Dashboard | **Live** at https://snof-live.web.app. Four tabs: Home (Needs a look, the water chain drawn from current readings only, the irrigation ring, Solar, Security, switches, the farm's systems with their own pages), Irrigation (Now with Run/Stop for admins, Pump & power, Watered by crop, reports), Water (read-only), Rooms. |
| iOS app | **0.10.0** on SideStore (https://snof-ios.web.app), the same screens and rules as the web (SNOFCore holds the shared logic and its tests). |
| RTDB rules | **Live**, with the two write paths `/commands` and `/irrigation_commands`. |
| Add-on | **0.10.5** on the NUC (image tag checked 2026-09-25 02:30, up since the 23:41 reboot): Home Assistant bridge, switch control, valve control, and the DCON read relay (`dcon_relay`). |
| Device control | **Armed** since 2026-09-23 (`allow_control: true`). `commandsRun` was 1 at 02:27 on 2026-09-25 (counted since the bridge's last start, after the 23:41 reboot). Disarm: merge `allow_control: false` into the Supervisor options and restart. |
| Irrigation control | **Armed** since 2026-09-24 (`allow_irrigation_control: true`), one change at a time under `irrigation_lock`. Run proven twice on 2026-09-24 ("started by A8" in the log); a Stop was refused mid-run — see [irrigation-control.md](irrigation-control.md). |
| Irrigation reads | Cloud Function `irrigation_report`; reads go through the NUC's relay until the function has a static egress IP Mobitech allowlists ([dcon-off-the-nuc.md](dcon-off-the-nuc.md)). The apps close Refresh with the reason while the bridge is quiet. |
| Water chain | **Live, read-only**: river motor (Livesky) and the other farm's two motors (Niagara) via Cloud Functions. Control is not built and waits on owner answers ([water.md](water.md)). |
| Git | `main` is the truth; work lands by PR and squash merge. After each merge reset the work branch, local and remote, to `origin/main`. |

## What changed overnight (2026-09-24 → 25)

Owner's brief: a best-in-class daily app, no bugs, every element earning its
place. Shipped in PRs #24–#31; iOS 0.9.0 → 0.10.0. The rules that came out of
it, each written down where it lives:

- Home answers "does anything need me?" first (*Needs a look*), then the
  systems as pictures, then controls as tiles ([dashboard.md](dashboard.md)).
- Appliances off at the wall (ACs, TVs, the printer, a fan) are "Off", never
  red; offline vs off is decided per device, everywhere.
- Nothing stale looks live: ages everywhere from one formatter; water is
  drawn as flowing only on a current reading ([water.md](water.md)); a run the
  log caught part-way is "so far", not "cut short"
  ([irrigation.md](irrigation.md)).
- Devices Home Assistant names by serial number are tidied for display
  ("P1S printer", "Goats") — rename them in HA to fix it at the source.
- Every screen was reviewed against a replay of the real farm, on web and on
  iOS (Catalyst snapshots), and by independent review/QA agents
  ([testing-and-preview.md](testing-and-preview.md)). Web QA: 69 checks.

## Open items

- **Rotate the SSH password.** The Advanced SSH add-on's options still carry a
  plaintext `password:`. It was exposed in screenshots during this session. Key
  auth is proven; delete the line and change the password.
- **Two deploy keys are authorized**: the original
  `snof-bridge-deploy@Sibhimanyus-MacBook-Pro-2` and
  `snof-bridge-deploy-20260922` added for this machine. Remove whichever is not
  wanted; do not remove both.
- **Most entities have no area, and are therefore invisible.** Since add-on
  0.9.0 an entity with no room is not published, not shown, and not operable
  (bridge, rules, web and iOS all enforce it). With 19 of 1366 registry
  entities in an area, the app shows only a small fraction of the farm until
  rooms are assigned in Home Assistant. Assigning one flows through live.
- **Rename the serial-named devices in Home Assistant**: `P1S_01P09C510500118`
  (and its `_AMS_1`, `_ExternalSpool`) and `T8400P202040124D` (the Goats
  camera station). The apps tidy them for display; the source still says it.
- **Livesky / Niagara motor control is not built.** It needs the owner's
  answers to the questions in [water.md](water.md).
- **Deploy `functions:reports` once iOS 0.10.0 is on the phone** (not done
  overnight on purpose): it writes runs caught part-way as "so far", which
  iOS 0.9.3 would misread as a valve list. `cd dashboard && firebase deploy
  --only functions:reports --project snof-live --force`. It also stamps
  `timerLogAt` and keeps `meta/reports.transport` current from `water_poll`.
- **Static egress IP for DCON**, so reads and valve commands can leave the NUC
  ([dcon-off-the-nuc.md](dcon-off-the-nuc.md)).
- **A Stop was refused mid-run** on 2026-09-24 (the controller's clock ran
  ~4 min behind the NUC's check). Documented, not changed.
- **Do not deploy from the main `brasilia` checkout**: it sits on an old
  branch (`irrigation-pull-to-refresh`) with uncommitted dashboard edits from
  2026-09-24 20:23 that predate every change since. Deploy from `main`.

## Map

| Document | Covers |
|---|---|
| [nuc-access-and-deploy.md](nuc-access-and-deploy.md) | SSH to the NUC, deploying the add-on, **§6a scripts it with no UI** |
| [device-control.md](device-control.md) | The command path, its three gates, and how to arm it |
| [dashboard.md](dashboard.md) | Front-end architecture, design system, bugs that must not return |
| [firebase-deploy.md](firebase-deploy.md) | Hosting, rules, and the two-tier allowlist |
| [testing-and-preview.md](testing-and-preview.md) | Every suite, and the fixture that matters |
| [irrigation.md](irrigation.md) | The report function, every DCON endpoint, and the real response shapes |
| [water.md](water.md) | The river → other farm → main farm chain, its functions, secrets, and the open control questions |
