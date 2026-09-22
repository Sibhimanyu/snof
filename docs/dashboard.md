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

## Design system

Near-monochrome, chosen deliberately after a first attempt was rejected as neon.
Greys carry the layout; colour appears only where it means something — green for
on, red for unavailable, amber for a stale bridge. A coloured pixel is always
worth looking at.

Token pairs live in three blocks at the top of `styles.css`: `:root` (dark),
the `prefers-color-scheme: light` block for "follow the OS", and
`:root[data-theme="light"]` for an explicit choice. The light palette is
duplicated across the last two by necessity — keep them in sync.

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
