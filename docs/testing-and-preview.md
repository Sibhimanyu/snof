# Testing

Three layers. None of them needs the farm, and none of them replaces watching
the real thing.

## Report function

```bash
cd dashboard/functions && python3 tests/test_reports.py
```

35 tests, no dependencies installed. They cover request validation, joining
timer segments into runs, the motor log's HH.MM pairs and meter reset,
pressure aggregated over every sample, electricity labels earned by
cross-check, no 10-digit number in any report, the RTDB rule's type list
matching `REPORT_TYPES`, partial and failed composites, and a static check
that `dcon.py` cannot reach `/v1/command/`. Fixtures are synthetic but in
the live shapes. Never paste a real dashboard payload in: it is the farm's
phone book.

## Bridge logic

```bash
cd addon/snof_bridge && python3 tests/test_logic.py
```

14 tests, no dependencies installed — mapping, attribute filtering, area
resolution, dedup stability, and the command validator's refusal cases. Keep
`aiohttp` imported lazily inside `commands.py` or this stops running clean.

The refusal cases are the point of that file: wrong domain, a service that does
not belong to its domain, out-of-range brightness, stale and postdated
timestamps, and `True` smuggled in where a number is expected (`bool` is an
`int` subclass in Python).

**Not covered:** the async websocket/RTDB orchestration in `main.py` and the
command stream in `commands.py`. That is where every real bug in this project
has lived. Verify it against the live NUC.

## Dashboard

See [../dashboard/preview/README.md](../dashboard/preview/README.md).

```bash
cd dashboard/preview
npm install && npx playwright install chromium   # once
python3 -m http.server 8765 &
npm run all
```

`sync.sh` must run after every source edit or you are testing the last build.
`npm run all` does it for you.

## The lesson that produced the fixture

The dashboard was built and tested against 26 tidy entities. Production has 698
with 373 unavailable and names like `Abhi's AC Display lighting` and
`[TV] Samsung 5 Series (32)`. Every bug in the 2026-09-22 round was invisible on
the clean mock and obvious on the real one.

So: **`?real=1` is the default case for review, not an edge case.** The real
farm shape, for anyone building fixtures:

| | |
|---|---|
| Registry | 1366 entities, 13 areas, 19 devices |
| Published | 698 entities across 18 domains |
| Unavailable | 373 — scattered, not clustered |
| Active | 15 |
| With an area | 117 of 698, in 2 areas; the rest are hidden (unassigned entities do not exist to users) |

Assert structurally, not by sampling. The truncation bug only overlapped when a
name happened to be long enough for a given viewport, so a passing screenshot
proved nothing. `qa.mjs` asserts the computed `display` of the name box instead,
which is true or false regardless of content.

## Replay the real farm (2026-09-25)

`?real=1` is a frozen, older shape. For anything that depends on today's data
(irrigation logs, water, systems), replay a snapshot of production instead:

```bash
firebase database:get /farms/snof --project snof-live > dashboard/preview/replay.local.json   # gitignored
# web:  http://localhost:8765/index.html?replay=1&fresh=1#/irrigation
# iOS:  SNOF_DEMO_TREE=$PWD/dashboard/preview/replay.local.json <Catalyst app> -demo -demo-admin -snapshot out.png [-tab …] [-system security] [-demo-watering]
```

`fresh=1` (and the iOS hook, always) moves the bridge heartbeat to now; every
other timestamp stays real, so ages ("65m ago", "Water readings are old") read
as they would have then. The snapshot never leaves the machine. `qa.mjs` runs
extra checks when the file exists and skips them when it does not.

On iOS the state flags (`-demo-stale`, `-demo-controloff`, `-demo-wateroff`,
`-demo-liveskyexpired`, `-demo-reportsoff`) apply to the replayed tree too,
and `-demo-fresh` moves its water readings to now for reviewing the live look.
For many shots, run the Catalyst binary with the network denied and without
AppKit's window restoration (a crash otherwise leaves every later launch
waiting on "reopen windows?"):

```bash
SNOF_DEMO_TREE=… sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))' \
  build/Build/Products/Debug-maccatalyst/SNOF.app/Contents/MacOS/SNOF -demo -ApplePersistenceIgnoreState YES \
  -demo-viewer -tab irrigation -snapshot /tmp/out.png
```

Build the review binary into its own derived-data path when an agent is
already shooting from `ios/build`.

What the replay caught that fixtures never showed: 83 report cards from
Refresh presses, a run log capped at 32 rows (yesterday's Watered showed 3
runs), a smart fan flagged as a faulty switch module, ACs and a printer shown
as red "offline", a still-running program called "stopped early", and a
background refresh that could stop the page updating.

Independent passes that worked well: a background code-review agent reading
the diff with a controllable clock, and a QA agent driving every mode and
route in the mock at phone width. Both found real bugs the author missed.

## Shell traps that produced false alarms here

- `grep -c pattern file` exits **1** when the count is zero, so
  `cmd && echo ok || echo FAIL` prints FAIL on a clean log.
- `if cmd | head; then` tests **`head`'s** status, which is always 0.
- `sudo find ... | xargs sudo shasum` through a pipe silently produced nothing;
  compare per-file instead.

Capture to a variable and test its length.
