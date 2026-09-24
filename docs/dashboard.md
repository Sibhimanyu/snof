# The dashboard

`dashboard/public/` — three files, no framework, no build step. `index.html`
(markup + an SVG icon sprite), `styles.css` (the whole design system),
`app.js` (state, router, render). Firebase Hosting injects config at
`/__/firebase/init.js`; nothing project-specific is committed.

## Structure

`<body data-view="boot|gate|app">` mounts exactly one screen. Inside the app
shell, a hash router picks the view:

| Route | View |
|---|---|
| `#/` | Overview — status tiles, quick controls, what is not reporting, areas |
| `#/areas` | a card per area, with active and offline counts |
| `#/area/<id>` | one area, grouped by domain, operable domains first |
| `#/devices` | everything, with status segment and domain chips |
| `#/irrigation` | report builder + results: ten reports on demand from the DCON controller (three of them combining two calls into one card), sectioned results, last-results cache — see [irrigation.md](irrigation.md) |
| `#/admin` | admin-only: grant/revoke view and control for other accounts — see [firebase-deploy.md](firebase-deploy.md#the-allowlist) |

`render()` rebuilds `#view` wholesale on every RTDB delta. At ~1366 registry
entities that costs ~80 ms and is fine; the guards below exist because "fine"
was not the same as "safe".

## Four bugs that must not come back

Each shipped, each was invisible in source review, each is now asserted in
`dashboard/preview/qa.mjs`. If a change makes one of those assertions fail, the
assertion is right and the change is wrong.

### 1. The sign-in page stacked above the dashboard

`app.js` set `gate.hidden = true` correctly, but `.gate { display: grid }` is a
class rule and **outranks the UA stylesheet's `[hidden]` rule**. The gate kept
laying out at full viewport height and the dashboard rendered below it, so the
way in was to scroll past your own login form.

Fixed structurally: `data-view` on `<body>` is the single source of truth, plus
`[hidden]{display:none!important}`. Never gate a screen on the `hidden`
attribute alone while a class rule sets `display`.

### 2. Truncation never engaged

`.dev-name` set `text-overflow: ellipsis`, but it was an **inline box** — its
parent was a flex *item*, not a flex *container*, so blockification stopped one
level short. `text-overflow` does nothing to an inline box. Every long Home
Assistant name ran straight under the state pill.

Fixed: `.dev-text` and `.row-main` are flex columns; names and meta are block
boxes. Card names get two lines (`-webkit-line-clamp: 2`) because the back half
of an HA name is usually the half that identifies it.

### 3. Live updates stole the control you were using

A full view rebuild every second destroyed any in-progress slider drag and
dropped focus to `<body>`. On this farm that is once a second, from any sensor
anywhere.

Fixed: `interacting` / `viewDirty` hold the rebuild while a control is in use
and apply it on release; `focusToken()` / `restoreFocus()` carry focus across
the rebuild.

### 4. A control panel full of things you cannot control

Quick Controls ordered active-first then everything else alphabetically. With 15
active out of 698, the slots filled with alphabetically-early **unavailable**
devices. Unavailable devices are now excluded outright, and the section shows an
explicit empty state if nothing is operable.

## Shell chrome

- `.topbar` is one bar on every width: wordmark, `.topnav` (the five
  destinations, green underline on the current one), theme button, account.
  Below 900px `.topnav` hides, the bridge pill `#m-bridge` takes its place,
  and `.tabbar` (text-only, fixed to the bottom) carries the destinations.
- The theme switch is in the account menu on every width (`#theme-menu`),
  plus an icon button on wide screens (`#theme-btn`).
- `#searchbar` lives **outside** `#view`, because `#view` is rebuilt on every
  live update and an input inside it would lose focus mid-word. It shows
  only where it filters (`body[data-route]` = areas, area, devices); on wide
  screens it sits in the empty right end of the title row.
- `.tabbar` and `.topnav` both use `data-nav`,
  and the active-state loop in `render()` selects `[data-nav]` — not
  `.nav-item` — so both stay in sync. A new route must be added to both.
- Admin is the one nav item that is not always shown: both copies carry
  `.nav-admin` and a `hidden` attribute, and `render()` clears `hidden` only
  once `isAdmin` resolves true. The route itself is still guarded
  server-side by RTDB rules, so a hidden link is convenience, not the
  security boundary.
- The bridge pill exists twice: `#m-bridge` (top bar, phones) and
  `#head-bridge` (the Overview's page head, wide screens). Both come from
  `bridgeStatus()`, and `renderBridgeStatus()` runs after every view build
  and every 5 s so the "· 28s ago" stays true.
- Pages open with `head(title, sub, right, eyebrow)`; panels with a title row
  use `panelHead(title, [href, label], count)`.

## The Overview

Left column: the **farm pulse** (`pulsePanel()` — one sentence chosen by how
much is offline, with the bridge going quiet outranking everything; mirrored
by `Pulse.summary` in SNOFCore, keep the wording in step), three tiles
(reporting / active / unavailable devices, each a link into All devices), and
**Areas at a glance**. Right column: the **attention card** (devices fully
offline, worst first, each row opening its room) and **Quick controls** (rows,
never tiles; unavailable devices excluded). Below 900px it is one column in
the order you need it: attention, pulse, tiles, controls, areas.

**All devices** lists devices, not readings: one line per device with its
room and status, opening to its readings. A filter or search opens the
matching devices by itself.

## Design system
"Area workspace", chosen by the owner on 2026-09-24 (see DESIGN.md): cool slate,
white panels, one tinted pulse panel, Manrope, big tabular numerals.
Near-monochrome, chosen deliberately after a first attempt was rejected as neon.
Greys carry the layout; colour appears only where it means something — green for
on, red for unavailable, amber for a stale bridge. A coloured pixel is always
worth looking at.

The green is the **brand green** (`#018843`, the logo's). `--brand` is that
exact value for fills. `--accent` is green text, shaded per theme for contrast
(`#01ae56` dark, `#017a3c` light). Fill with `--brand`, write with `--accent`.
`--accent-soft` and `--accent-line` are now the *neutral* panel and line
tones, not green: green is never a background (DESIGN.md).
Farm illustrations live in `public/art/` (96 px, ~40 KB in total) and are
picked by `valveArt()`, which mirrors `ios/SNOFCore/.../ValveArt.swift`.

Token pairs live in three blocks at the top of `styles.css`: `:root` (light,
the "Area workspace" comp), the `prefers-color-scheme: dark` block for
"follow the OS", and `:root[data-theme="dark"]` for an explicit choice. The
dark palette is duplicated across the last two by necessity — keep them in
sync, and keep both in step with `ios/SNOF/UI/Theme.swift`.

Hard-won constraints:

- **No gradients, no glow.** `--accent-2` was deleted; it existed only to feed
  them. Emphasis comes from weight and size.
- **Contrast floors.** Secondary text clears 4.5:1 on both panel and bg in both
  themes. `--faint` failed at 3.5:1 in dark before it was caught — check dark,
  not just light.
- **Text size floor.** Nothing functional below 11px; the body-adjacent tier is
  12px.
- **44px hit targets.** Chips keep a 32px look by folding a 6px transparent
  border into their own box, so the hit area is the element — a pseudo-element
  would not extend hit testing.
- Motion yields to `prefers-reduced-motion`. The heartbeat dot pulse stays: it
  is bridge liveness, not decoration.

## Conventions worth keeping

- Escape everything from RTDB through `escapeHtml`, including into `title`.
- `CSS.escape` any entity key used in a selector.
- The auth listener is registered **last** in `app.js`: `onAuthStateChanged` can
  fire synchronously, and `enter()`/`leave()` touch helpers defined throughout
  the file. Registering it early hits the temporal dead zone.
- Domain icons resolve via `getElementById('i-' + domain)` and fall back to
  `i-default`, so an unknown domain degrades rather than breaking.
