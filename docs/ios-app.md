# The iOS app

`ios/` — a native SwiftUI client for the same farm. It is **a second client of
the one database, not a new trust boundary**: same RTDB paths, same writes,
same rules, same three control gates. Nothing in `database.rules.json` or the
add-on changed to support it.

| Screen | Mirrors |
|---|---|
| Overview | `#/` — bridge band, totals, quick controls, not-reporting breakdown, areas |
| Areas / area detail | `#/areas`, `#/area/<id>` |
| Devices | `#/devices` — status segment, domain chips, search |
| Irrigation | `#/irrigation` — report builder, section-kind renderer, last results |

Admin (invites and grants) is deliberately **web-only**. The app still claims
a pending invite on first sign-in and self-registers `acl/directory`, as
`enter()` in `app.js` does, so someone invited from `#/admin` can start on
the phone.

## Layout

| Path | What it is |
|---|---|
| `ios/project.yml` | xcodegen spec. The `.xcodeproj` is generated, not committed. |
| `ios/SNOFCore/` | Swift package: models, the RTDB parser, and every rule (on/offline, bridge gate, command allow-list, report validation). Foundation only. |
| `ios/SNOF/Backend/` | `FirebaseBackend` (the farm) and `DemoBackend` (bundled fixtures). |
| `ios/SNOF/Store/FarmStore.swift` | State, optimistic commands with the 12 s deadline, report waiting. |
| `ios/SNOF/UI/` | Screens and the design tokens from `styles.css`. |
| `ios/SNOF/Resources/mock-farm-*.json` | Exported from `dashboard/preview/stub.html`; `-real` is the 698-entity fixture. |

## Build and test

```bash
cd ios
xcodegen                                   # after adding or removing a file
cd SNOFCore && swift test                  # pure logic, no simulator needed
cd .. && ./scripts/shoot.sh build/shots    # renders every key screen to PNG
```

`shoot.sh` builds the **Mac Catalyst** variant and has the app render its own
window (`Snapshot.swift`, Debug only). It needs no simulator, no Firebase and
no screen-recording permission. Demo launch flags mirror the preview's query
flags: `-demo-real`, `-demo-viewer`, `-demo-controloff`, `-demo-reportsoff`,
`-demo-stale`, `-demo-signedout`, `-demo-denied`.

For the Simulator or a device, Xcode's first-launch components must be
installed once (`sudo xcodebuild -runFirstLaunch`, then
`xcodebuild -downloadPlatform iOS`). On 2026-09-23 the dev Mac's CoreSimulator
was older than Xcode 27 and would not boot a simulator until that was done.

## Demo vs the farm

A build **without** `ios/SNOF/Firebase/GoogleService-Info.plist` runs on
bundled demo data, and every screen shows a `DEMO DATA` badge. A build with it
talks to the farm. `-demo` forces demo mode either way.

**Connected on 2026-09-23.** The Firebase iOS app `SNOF iOS`
(`1:381810561209:ios:78f711adaad98a85380b68`, bundle `com.sibhiorchards.snof`)
is registered in `snof-live`. Its plist carries `DATABASE_URL`, `CLIENT_ID`
and `REVERSED_CLIENT_ID`. On a new machine, run
`ios/scripts/fetch-firebase-config.sh` and then `xcodegen`. Neither generated
file is committed, the same way the web dashboard never hardcodes its config.

## Releasing (SideStore)

Phones install through [SideStore](https://docs.sidestore.io), with a free
Apple ID and no App Store. `ios/scripts/release.sh "notes"` does all of it:

1. Runs the SNOFCore tests and builds an unsigned Release `.ipa` (SideStore
   re-signs it on the phone).
2. Refuses to publish unless the bundle has the Firebase plist and the
   Google sign-in URL scheme, and does not contain the real-name fixture, a
   service account, or the Debug snapshot hook.
3. Writes `ios/dist/`: the `.ipa`, `source.json` (a SideStore/AltStore
   source), `index.html` (an "Add to SideStore" link) and the icon.
4. Deploys `ios/dist/` to the separate Hosting site **`snof-ios`**
   (`ios/firebase.json`). The dashboard site is never touched.

The build number is a UTC timestamp (`YYYYMMDDHHMM`), so it always increases
with no state to sync. The marketing version is `MARKETING_VERSION` in
`project.yml`.

**Updates.** SideStore reads `https://snof-ios.web.app/source.json`, sees a
newer `buildVersion`, and shows **Update** under My Apps. It does not install
it silently; someone taps Update. `UpdateCheck.swift` reads the same file on
foreground (at most hourly) and shows a one-line banner that opens SideStore,
so an update does not sit unnoticed.

**Blaze is required for this.** Spark refuses `.ipa` uploads ("Executable
files are forbidden on the Spark billing plan"), so `snof-live` was moved to
Blaze on 2026-09-23 for exactly this. Blaze keeps Spark's no-cost Hosting
allowance (10 GB stored, 360 MB/day transferred); one 2.4 MB `.ipa` per
install or update is far inside it. `release.sh` deletes the previous `.ipa`
from `dist/` each time, so storage stays at one build. Do not rename the file
to get around the rule on some other Spark project.

**Live since 2026-09-23:** `0.1.0 (202609231510)` at
<https://snof-ios.web.app>. Its `source.json`, `.ipa` hash, size and bundle
ID were verified against the served files.

**SideStore renames the bundle ID** to `com.sibhiorchards.snof.<TEAMID>` on a
free account (`FetchProvisioningProfilesOperation.swift` in SideStore). The
iOS API key has no bundle-ID allow-list (`iosKeyRestrictions: {}`, checked
2026-09-23), so Firebase calls still work. If anyone restricts that key
later, add the renamed ID too, or sideloaded installs stop reading the farm.
Google sign-in with the renamed bundle had not been tried on a device at the
time of writing.

**Free-account limits:** 3 sideloaded apps including SideStore, 10 new app
IDs a week, and a 7-day signature that SideStore refreshes in the background.
Refreshing needs LocalDevVPN on and Wi-Fi.

## Decisions worth keeping

- **RTDB disk persistence stays off.** With it on, a command written with no
  signal would be kept on disk and replayed on a later launch. The rules'
  `at === now` check would accept it, because `now` is when the write reaches
  the server, not when the button was pressed.
- **A control that times out purges unsent writes**
  (`purgeOutstandingWrites`). Otherwise a toggle pressed in a dead zone fires
  whenever the phone reconnects, long after the UI said it had been reset.
  Controls also refuse outright while `.info/connected` is false.
- **The invite claim finishes before the farm listeners attach.** Attached
  concurrently, the reads are refused and a first-time invitee lands on
  "not on the allowlist".
- **The bridge gate is checked before the optimistic flip**, as on the web, so
  a switched-off capability reads as switched off rather than as broken
  hardware.
- **Sliders hold a local draft** while dragging and until the farm reports the
  new level. Live updates can never yank a slider (bug 3 in
  [dashboard.md](dashboard.md)).
- `cover`, `lock` and `alarm_control_panel` are excluded in
  `SNOFCore/Logic.swift` as at every other layer, and the command builder
  re-applies the rules' `entity_id` regex and domain-prefix check. That makes
  the app a fourth refusal, not a replacement for any of the three gates.

## Cost shape

The same as one more open browser tab per phone: value listeners on `meta`,
`areas`, `entities`, `irrigation` and the last 20 reports. The initial sync is
the whole mirror, and deltas follow. iOS suspends the socket in the
background, so a backgrounded phone costs nothing, but each return to the
foreground re-syncs. Nothing polls, and no vendor call happens without a press
of Generate.

## Distribution

SideStore for now (above). TestFlight and the App Store both need the Apple Developer
Program (US$99/year). A public App Store listing for a single-farm tool
risks rejection. Unlisted App Distribution or a Custom App (Apple Business
Manager) are the usual routes. Replace the placeholder app icon before any of
them.
