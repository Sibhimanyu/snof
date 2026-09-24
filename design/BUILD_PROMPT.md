# Build brief: SNOF dark mobile-first operations UI

Use this prompt for the agent implementing the dashboard UI. Read
[`../../DESIGN.md`](../../DESIGN.md) first. It is the normative design and
interaction contract. This document makes the user's preferred visual direction
unambiguous and points to its references.

## Mission

Rework the Firebase-hosted SNOF dashboard into a dark, mobile-first farm
operations interface with the visual discipline of
`concepts/00-approved-mobile-style-reference.png`.

Build a dependable operator tool, not a consumer smart-home app or a marketing
page. A user should immediately see bridge health, urgent exceptions, device
state, and permitted controls.

## Read before editing

1. `DESIGN.md` — requirements and constraints. This wins if any image conflicts
   with it.
2. `docs/dashboard.md` — routes, live-update behaviour, and bugs that must not
   return.
3. `dashboard/preview/README.md` — the hostile production-shaped fixture and
   test commands.
4. `docs/device-control.md` — authorised domains and control boundaries.

## Image pack

The visual references are in `design/concepts/`. They demonstrate hierarchy and
tone only. They are not specifications for real device data, controls, routes,
or availability counts.

| Reference | Use it for |
| --- | --- |
| `00-approved-mobile-style-reference.png` | **Primary taste reference.** Type scale, black/graphite palette, thin borders, compact dark mobile hierarchy, restrained status colour, and bottom navigation. |
| `04-dark-mobile-overview.png` | Mobile overview information order. |
| `05-dark-desktop-overview-approved-style.png` | Desktop translation of the preferred mobile style. |
| `06-dark-mobile-area-detail.png` | Domain grouping and dense but touch-safe device rows. |
| `07-dark-mobile-areas.png` | Area-list rhythm and status summaries. Ignore its contradictory empty state. |
| `08-dark-desktop-all-devices.png` | Search, filters, and inventory scanning pattern. Do not add pagination unless it is implemented and justified. |
| `01-*`, `02-*`, `03-*` | Earlier exploratory options; use only when they support the primary reference. |

## Visual direction

- Default to dark mode. Use a nearly black charcoal canvas and slightly lighter
  graphite panels. Light mode must remain fully supported.
- Use a clean, confident sans-serif with a large page title and compact, highly
  legible body text. No display serif in the product UI.
- Let 1px borders, spacing, labels, and type create structure. Keep surfaces
  flat: no gradients, glow, glassmorphism, or decorative shadows.
- Green means only live/on. Amber means only stale. Muted red means only
  unavailable/error. Never use state colour as decoration or as the sole state
  indicator.
- Use quiet outlined icons and obvious, familiar toggles. Keep every functional
  target at least 44px.
- Mobile should be a first-class layout: persistent bottom navigation for
  Overview, Areas, and Devices; bridge/urgent state before secondary content;
  single-column rows that still scan quickly.
- Desktop should retain the same hierarchy with a left rail and compact top bar.
  Do not simply enlarge the phone layout.

## Product truth and safety constraints

- Keep the existing routes: `#/`, `#/areas`, `#/area/<id>`, and `#/devices`.
  Preserve the irrigation route if it is already present.
- Use actual RTDB fields and existing render helpers. Do not invent animals,
  water, energy, camera, feed, security, or weather data.
- The only potentially controllable domains are `light`, `switch`, `fan`, and
  `input_boolean`, and controls must honour the controller tier and deployed
  control gate. Do not add a control merely because an image depicts one.
- Keep unavailable entities grouped and clear without making red dominate the
  screen. Production has many unavailable items and many unassigned entities.
- Preserve focus, slider drags, scroll position, and pending-command behaviour
  during live updates.

## Screen-by-screen target

### Overview

1. Page identity plus compact bridge-live/stale/offline state.
2. Concise reporting, areas, active, and exception totals.
3. Operable quick controls only. Each control states its device and context.
4. A grouped exception summary that leads to a useful filtered device view.
5. Area summaries with counts and an obvious drill-in path.

### Areas and area detail

- Areas are scanable rows/cards with area name, device count, active count, and
  unavailable count.
- Area detail groups devices by domain, with allowed controllable domains first.
- Rows reveal state, last update, and appropriate control without turning every
  device into a large card.

### All devices

- Provide a clear search field, status segments, and domain filters.
- At desktop widths use compact rows or a table-like list. At phone widths use
  compact stacked rows. Device name, state, area/context, and updated time stay
  readable.
- Design for hostile names, 698+ entities, and hundreds of unavailable devices.

## Execution plan

1. Inspect the current DOM/CSS and retain working data, routing, and control
   logic.
2. Establish shared visual tokens before restyling individual screens.
3. Implement mobile first, then add desktop breakpoints deliberately.
4. Test the real-shaped fixture after every material change:

   ```bash
   cd dashboard/preview
   npm run all
   ```

5. Capture desktop and 375px mobile screenshots for Overview, Areas, one area
   detail page, and All devices. Compare them to the primary reference for tone,
   spacing, hierarchy, and restraint, not literal content.

## Definition of done

- The result clearly resembles the approved dark reference in visual language.
- It does not copy any generated-image fiction into product data or controls.
- Dark and light themes work; keyboard, touch, reduced motion, and 44px hit
  targets are preserved.
- The production-shaped fixture has no overflow, name/state overlap, or
  unusable mobile navigation.
- `npm run all` passes without console errors.
