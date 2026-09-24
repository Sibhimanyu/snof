# Dashboard preview harness

Renders every screen of the dashboard headlessly against a mocked Firebase, with
no project, no credentials and no network. This is where the bugs get caught:
every defect found so far was invisible until a state was rendered with hostile
data, and none of them were visible in the source.

```bash
cd dashboard/preview
npm install && npx playwright install chromium   # once
python3 -m http.server 8765 &                    # the harness is plain static files
npm run all                                      # sync + all three suites
```

`sync.sh` copies `../public/{index.html,styles.css,app.js}` in and splices the
Firebase mock over the Hosting-injected SDK. **Run it after every source edit**
or you are testing the previous build.

## The suites

| Command | What it proves |
|---|---|
| `node shoot.mjs` | 17 screenshots into `shots/`, fails on any console error |
| `node verify.mjs` | exactly one view is mounted; viewer vs controller tiers |
| `node qa.mjs` | interaction and hostile-data assertions (below) |

`qa.mjs` is the one that matters. It asserts structurally rather than by
sampling, because sampling is how the truncation bug shipped — it only overlaps
when a name happens to be long enough, so a lucky screenshot proves nothing:

- a drag survives a live entity update mid-gesture, and the held update lands on release
- a filter chip keeps focus when pressed
- an optimistic toggle flips, then settles when the farm agrees, with no false error
- scroll position survives a live update
- a re-render stays under 150 ms at farm scale
- **name and meta boxes are block-level** (`text-overflow` does nothing to an inline box)
- zero name/pill overlaps at wide *and* narrow widths
- zero unavailable devices in Quick Controls
- the status filter isolates all 373 unavailable entities

## Mock URL parameters

Append to `index.html`, e.g. `index.html?real=1#/areas`:

| Param | Effect |
|---|---|
| `?real=1` | the real farm: 698 entities, 373 unavailable, 15 active, Home Assistant naming |
| `?big=1` | 1350 synthetic entities, for render-cost checks |
| `?gate=1` | signed out |
| `?denied=1` | signed in but not on the allowlist |
| `?viewer=1` | viewer tier — no controls anywhere |
| `?nodata=1` | snapshot never arrives — the skeleton state |
| `?stale=1` | bridge heartbeat overdue |
| `?reportsoff=1` | the report kill switch is thrown (`meta/reports.enabled: false`) |
| `?realreports=1` | report cards built by the Cloud Function from real controller payloads, every section kind included. `reports-real.json` is generated locally and gitignored |
| `?controloff=1` | bridge is live but `allow_control` is false — likewise |

Default (no params) is a small clean farm. **Do not trust it alone.** Every bug
in the 2026-09-22 round was invisible on the clean fixture and obvious on
`?real=1`; a tidy mock is why they shipped.

`farm-real.json` mirrors production shape, not production data: same counts,
same unavailable ratio, same naming patterns (apostrophes, `[TV]` prefixes, long
compound names), ~1 entity in 6 assigned to an area.
