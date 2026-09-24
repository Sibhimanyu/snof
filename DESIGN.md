# SNOF dashboard design brief

Use this document as the visual and interaction contract for the Firebase-hosted
SNOF farm operations dashboard. The product mirrors Home Assistant state; it is
an operational tool for checking the farm at a glance, finding a room or device,
and, only where authorised, sending limited controls.

## Concept references

The generated concepts are deliberately exploratory. They are references for
hierarchy, tone, density, and responsive behaviour, not pixel-perfect screens or
a source of product requirements.

| File | What to borrow | What to avoid copying literally |
| --- | --- | --- |
| `design/concepts/01-dark-overview-with-areas.png` | Overview hierarchy: liveness, totals, controls, areas, unavailable items | Photo banners and controls outside the documented domains |
| `design/concepts/02-dark-overview-editorial.png` | Calm dark dashboard, three-column information grouping, restrained state colour | Serif display typography if it compromises practical scanning |
| `design/concepts/03-light-area-detail.png` | Dense, domain-grouped area view with rows and inline controls | Invented farm telemetry and bulk controls not supported by the backend |
| `design/concepts/04-dark-mobile-overview.png` | Clear mobile priority order, bottom navigation, thumb-friendly control affordances | Consumer smart-home ornamentation and made-up domain categories |

## Product and audience

The primary user is a farm operator or owner who needs a fast answer to three
questions:

1. Is the bridge live and is the dashboard current?
2. What is on, stale, or unavailable, and where is it?
3. Can I safely operate an authorised light, switch, fan, or input boolean?

This is not a marketing page and not a decorative consumer smart-home UI. It must
feel dependable on a laptop, wall tablet, and phone. Scan speed matters more than
visual novelty.

## Information architecture

Keep persistent navigation straightforward:

- **Overview** (`#/`): bridge liveness, status totals, operable quick controls,
  unavailable summary, and area summaries.
- **Areas** (`#/areas`): one card per Home Assistant area, with active and
  unavailable counts.
- **Area detail** (`#/area/<id>`): an area title, status summary, then device
  groups by domain. Put controllable domains before read-only domains.
- **All devices** (`#/devices`): search and filter all published entities by
  state and domain.

The app must always make the current route unmistakable. On nested area pages,
include an obvious back path or breadcrumb. Search belongs on the all-devices
view unless a future product requirement proves a global search is needed.

## Visual direction

### Tone

Near-monochrome, calm, technical, and warm enough to use every day. Let type,
spacing, grouping, and thin borders create hierarchy. A coloured pixel should
communicate state, not decoration.

### Colour semantics

- **"Area workspace"** (design option C), chosen by the owner on 2026-09-24
  and shipped on web and iOS. Light: a cool slate canvas `#f5f7f7`, white
  panels on `#dce4e4` hairlines, ink text `#17252a`, numerals `#25393d`, and
  one tinted surface — the farm pulse, `#eaf0ef` on `#d2e0df`. Dark is
  **Apple's neutral system dark** (owner, 2026-09-24, replacing the
  charcoal-green slate night): a true black canvas `#000000`, graphite
  panels `#1c1c1e` / `#2c2c2e`, `#242426` pulse, white text, `#a1a1a6`
  secondary — no hue in any grey. Cards float on edge, not shadow. Every token is in `styles.css` and
  `ios/SNOF/UI/Theme.swift`, value for value; the reference comp is
  `.context/snof-reviewed-c-desktop.png` / `-mobile.png`.
- Green means live or on only. It is the **brand green** from the Sibhi
  Natural Orchards logo, `#018843`, used exactly for fills (toggles, sliders,
  bars, chart lines, the live dot, primary buttons). Green *text* uses the
  same hue shaded per theme to clear 4.5:1: `#017a3c` light, `#01ae56` dark.
  Tokens: `--brand` / `--accent` on the web, `Theme.brand` / `Theme.on` on iOS.
- **Green is never a background.** No tinted wash behind an icon, pill, tag,
  selected item or chart; those surfaces are neutral, and the green is the
  dot, the text, the toggle or the line. Chosen by the owner on 2026-09-23
  after the washes read as "a greenish background".
- Light is the default look; the OS setting picks dark, and a choice made
  in the account menu (web) or Account sheet (iOS) sticks. The earlier
  Graphite / warm-light palettes are retired.
- Amber means stale only.
- Muted red means unavailable or error only.
- Do not use gradients, glow, neon, or an accent colour without semantic
  meaning. The one exception to "no glass" is the navigation chrome (top bar,
  tab bar, account menu, toasts), which is frosted like iOS system bars.
  Cards and panels stay opaque.

Maintain at least 4.5:1 contrast for secondary text in both themes. Status must
never depend on colour alone: pair it with a label, icon, or readable state.

### Type and layout

- One typeface, **Manrope** (variable, SIL OFL), self-hosted on the web
  (`public/fonts/`) and bundled in the app. Page titles are large and
  tightly tracked ("Your farm, right now."); every page opens with an
  uppercase eyebrow that says where you are. Counts are two-digit and
  tabular ("09/21", "05"). On iOS every size is anchored to a Dynamic Type
  style, so it still scales.
- Favour a compact but breathable operations layout: clear page title, one
  primary status band, then grouped panels or rows.
- **Soft, iOS-like shape and depth** (owner, 2026-09-24, replacing the
  earlier 3px sharp corners). Cards (panels, lists, area cards, stats,
  report cards) are 22px continuous rounds (16px for the compact phone
  grid), with a near-invisible edge (`--edge` / `Theme.edge`) and a soft
  two-layer shadow (`--shadow-card` / `Card` modifier). Buttons, fields and
  inner tiles are 12px; row icons are 8px filled squircles. Fields,
  search and chips are filled and borderless, like UIKit's. The top nav and
  every segment are iOS segmented controls (grey track, raised white
  thumb); toggles are drawn at UISwitch proportions (51×31). List
  separators are inset to where the text starts. Presses scale slightly
  (0.96 on controls, 0.985 on cards) instead of nudging down.
- **Haptics (iOS)** come from the press, never from a live state change:
  `Haptics.select` for tabs, chips, segments and valve picks;
  `Haptics.toggle` (firmer on than off); a light tick every 10% of a
  slider; a rigid `commit` thump when valves are opened; a warning on
  "Stop watering"; success/error with toasts.
- **Count devices, not entities.** A switched-off printer is one thing
  offline, not 67 readings. Tiles, area cards, the attention card and the
  All devices list all group by the bridge's `device` id.
- Make device names the dominant row text. Support long Home Assistant names:
  list rows truncate safely; cards allow a two-line clamp when room permits.
- Avoid large charts. Direct state, counts, names, timestamps, and controls are
  more useful for this product.

## Component guidance

### Bridge status

Bridge liveness is primary operational information. Display a labelled live,
stale, or offline state and a last-seen/updated time. The live indicator may
subtly pulse when reduced motion is not requested; it is a functional signal,
not decoration.

### Status totals

Use compact tiles for meaningful totals such as published devices, active,
unavailable, and stale. The totals should be instantly scannable and link to a
useful filtered destination only if that interaction exists.

### Device rows and controls

- Rows show icon/domain, device name, area or context when helpful, state, and
  last update. Unknown domains use a reliable default icon.
- Only `light`, `switch`, `fan`, and `input_boolean` may expose control
  affordances, and only for controller-authorised users when control is armed.
- Use familiar toggles for on/off. Show brightness or percentage sliders only
  when the entity supports the documented service and attributes.
- Pending commands are optimistic but visibly pending. Reconcile to live truth;
  after timeout, return the control to truth and explain the failure concisely.
- Disabled, unavailable, and non-controller states must be obvious and must not
  imitate a usable control.
- Disabled keeps the words at full strength (2026-09-25): a tile that cannot be
  pressed goes flat (no shadow) with its icon dimmed; a disabled primary button
  is grey on grey. Never fade the whole control: at 55% the name was 2.2:1 and
  a viewer lost the very state they came to read. On iOS use
  `TileButtonStyle`, not `.plain`, which dims a disabled label by itself.
- Say why something is disabled, once, next to it ("One manual run at a
  time."; one line when a quiet bridge closes both reads and valve control).

### Brand artwork

The logo roundel and the farm illustrations come from the DCON design assets
(`design/brand/`, and `dashboard/public/art/` / the iOS asset catalog at
display sizes). The roundel's centre is transparent, so it always sits on a
white disc. Crop and motor illustrations appear only beside irrigation valves
and log rows, where they say what a valve waters. They are content, never a
state signal; the tag beside them carries state. The DCON app's own tokens
(glass, glow, gradients, Outfit/Inter) are deliberately **not** adopted.

### Areas and unavailable state

Area cards should prioritise the area name and active/unavailable counts. Do not
invent photography or sensor categories. Inside a room, sections are named for
what things are (Lights, Switches, Detectors, Readings, Alarm, TVs & speakers),
never Home Assistant's domains, and settings entities (power-on behaviour,
timers, firmware notices) stay out unless searched for. Search sits under the
page title, never in the bar above it. Devices Home Assistant names by serial
number read as what they are ("P1S printer", "Goats"); the fix at the source
is renaming them in Home Assistant. The unavailable section should state
what is not reporting, where it belongs, and when it was last seen, without
letting failure colour dominate the whole screen.

## Responsive behaviour and accessibility

- Design desktop around grouped panels and rows, not a fixed screenshot layout.
- On mobile, show the bridge state and urgent exceptions first. Collapse grids
  to a single column and use a persistent bottom navigation for Overview, Areas,
  and Devices.
- Every functional interactive element has at least a 44px hit area. Keep
  visible affordances; do not rely on hover.
- Respect `prefers-reduced-motion`. Never destroy focus or an in-progress slider
  drag when a live update arrives.
- Escape externally sourced device names and use safe selectors for entity keys.

## States to implement before polish

The real dataset is not tidy: it contains many long names, 373 unavailable
entities, and a majority of entities without an assigned area. Build and test:

- signed out and access denied;
- loading, live, stale, and offline bridge;
- no controllable devices;
- controller vs viewer permissions;
- empty area, unassigned area, unavailable device, and no-search-results;
- a long device name alongside a state pill;
- live data updates while a toggle or slider has focus;
- narrow mobile screens and reduced motion.

## Implementation guardrails

The dashboard is vanilla HTML, CSS, and JavaScript in `dashboard/public/`.
Preserve the existing hash routes and rebuild-safe interaction behaviour. Keep
the UI informed by the actual RTDB shape, rather than adding a second index or
inventing fixture-only fields. Do not make a control UI imply that client access
to Home Assistant is direct: commands travel through the restricted Firebase
queue and may be disabled in deployment.

## Definition of done for UI work

An implementation is ready for review when it matches this hierarchy, works in
both dark and light themes, remains readable under the production-shaped fixture,
is usable with keyboard and touch, and passes the existing dashboard preview QA.
