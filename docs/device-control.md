# Device control

The dashboard can operate lights, switches, fans and (since 2026-09-25, add-on
0.10.6) the ACs. This is the only inbound
path to farm hardware that exists, so it is worth understanding completely
before changing any part of it.

**Currently deployed and inert.** See [HANDOFF.md](HANDOFF.md) for why.

## How a command travels

```
dashboard  --append-->  /farms/snof/commands/<pushId>   (RTDB, the only writable path)
                              |
bridge on the NUC  <--stream--+   REST event-stream, Admin credential
     |
     +-- re-validate against its own allow-list
     +-- HA websocket call_service
     +-- DELETE the node (ran or refused, either way)
```

The browser never talks to Home Assistant. It appends a node and waits. The
bridge holds the only credential that can act on one.

## The three gates

Each is independently sufficient to stop a bad command. Keep it that way.

### 1. RTDB rules — `dashboard/database.rules.json`

- writer must be `acl/controllers/<uid> === true`
- append only: `!data.exists()`, so a queued command cannot be edited
- `domain` must match one of `switch|light|fan|input_boolean|climate` **and** must be the
  domain named in `entity_id`
- `service` must be one of `turn_on|turn_off|toggle|set_percentage`, or, for
  `climate` only, `set_temperature|set_hvac_mode|set_fan_mode|set_preset_mode`
- `uid` must equal `auth.uid`
- `at` must equal server `now` — cannot be backdated past the staleness check
  nor postdated to fire later
- `data` accepts only `brightness` (0–255), `percentage` (0–100),
  `temperature` (10–35 °C), `hvac_mode` (Home Assistant's seven modes) and
  `fan_mode` / `preset_mode` (plain `[a-z0-9_]{1,32}` tokens); `$other` is
  rejected outright
- the target must exist at `farms/<slug>/entities/<domain>/<object_id>` — and
  the bridge publishes only entities that are in a room, so a command for an
  unassigned, excluded or invented entity id is refused before it is queued

Note: `database.rules.json` accepts `//` line comments but **not** `"//"` keys —
a `"//": "..."` entry fails deploy with `Expected '{'`.

### 2. The bridge — `addon/snof_bridge/bridge/commands.py`

Re-checks all of the above against `ALLOWED_SERVICES`, plus:

- drops anything older than `control_max_age_seconds` (default 120), so a queue
  that built up during an outage does not fire all at once on reconnect
- drops anything more than 60 s in the future (clock skew, not instruction)
- rejects `True` where a number is expected — `bool` is an `int` subclass in
  Python and would otherwise pass a range check
- refuses any entity that is not in a room (`is_visible`, which is the
  mapper's own `should_publish`), so what cannot be seen cannot be switched
- holds each data key to its domain (brightness for lights, percentage for
  fans, the AC keys for climate), and each AC `set_*` service to exactly its
  one value (`DOMAIN_DATA`, `SERVICE_DATA`); `turn_on`/`turn_off` on an AC
  carry nothing. Home Assistant then refuses a mode or temperature the AC
  itself does not offer (16–30 °C on the farm's Samsungs)
- deletes every node whether it ran or was refused, so a bad command cannot loop
- `_seen` is bounded; it only needs to cover one stream's lifetime

### 3. `allow_control` — off by default

In `addon/snof_bridge/config.yaml`. With it false, `CommandConsumer.run()` logs
and returns without ever opening the stream.

## Deliberately excluded

`cover`, `lock` and `alarm_control_panel` are absent at **every** layer: the
dashboard's `CONTROLLABLE` set, the RTDB rules regex, and the bridge's
`ALLOWED_SERVICES`. Opening a gate or unlocking a door from a browser tab is a
different risk conversation. Adding one is a security decision requiring all
three layers to change, not a config tweak.

## Two access tiers

| Path | Grants |
|---|---|
| `acl/viewers/<uid>` | see the farm |
| `acl/controllers/<uid>` | see **and** operate |

```bash
cd tools
npm run grant  -- someone@example.com            # view
npm run grant  -- someone@example.com --control  # view + operate
npm run revoke -- someone@example.com --control  # demote, keeps view
npm run revoke -- someone@example.com            # remove both
npm run list                                     # shows tier per user
```

Handing someone the dashboard is not the same as handing them the pumps.

## Arming it

Do these one at a time, and watch the log between them.

```bash
SSH_OPTS="-o ProxyCommand=none -o IdentitiesOnly=yes -i ~/.ssh/snof_ha"

# 1. allow_control: true in the add-on Configuration, then restart. Confirm:
ssh $SSH_OPTS sibhiorchards@192.168.68.200 \
  'sudo docker logs app_local_snof_bridge 2>&1 | grep -i "command queue" | tail -2'
# want: "Watching command queue for domains: climate, fan, input_boolean, light, switch"
# not:  "Device control is disabled"

# 2. grant yourself the controller tier
cd tools && npm run grant -- you@example.com --control
```

Then reload the dashboard: the account chip should read **Controller** and
toggles should appear. Flip one while tailing the log.

## What the UI does with a command

Optimistic with a deadline. The control snaps to the requested position, and
`pending` holds a 12 s timer. Reconciliation runs **before** the view is drawn,
and clears on agreement rather than on a state *transition* — if the entity
already reports what was asked for, the command is settled. Waiting for an edge
that never arrives would time out and blame the farm for the dashboard's own
bookkeeping. On timeout the control returns to truth and says so.

## Unproven

The validator has unit tests (`tests/test_logic.py`, 11 refusal cases). The
stream parsing, `call_service`, and the delete path have never run against real
hardware. Treat the first live command as a test, not a routine action.

## When control is switched off

`allow_control` is gate 3, and the bridge publishes its state as
`meta/bridge.control` on every heartbeat. The dashboard reads it: with control
off — or the bridge stale or offline — toggles and sliders render disabled,
with one line saying which it is, and `sendCommand()` refuses regardless of
what the last render painted.

That guard is new on 2026-09-23. Before it, a toggle flipped optimistically,
wrote a command nothing was watching, and snapped back twelve seconds later
saying the farm had not responded — a switched-off feature that read as broken
hardware. Three unexecuted `switch.turn_on` commands were sitting in the live
queue when it was found.

The consumer now also drains `/commands` once at startup when control is off.
Only it ever deletes from that path and clients can append to it, so with the
consumer not running the queue grew without bound. Those commands could never
have run in any case: they are long past `control_max_age_seconds` by the time
anyone arms control, and would be refused as stale.

## The ACs (2026-09-25)

Owner: "I should be able to control devices like the AC … temperature, on
off and everything". A `climate` entity gets a card on web (`acCard()`) and
iOS (`ACCard`): power, the set temperature between − and + (taps settle for
0.7 s and send once), mode, fan speed and preset, each from what the AC
itself publishes (`hvac_modes`, `fan_modes`, `preset_modes`, `min_temp`,
`max_temp`, `target_temp_step`, exported since 0.10.6). Swing, humidity and
schedules are not offered. Every change shows at once and is held until the
AC reports it, like a toggle, or reset after 12 s. `climate` is **not** in the
apps' `CONTROLLABLE` set: that set also decides what is a switch (Home's
tiles, the Lights & switches system), and an AC is neither.

Arming: `climate` in the add-on's `control_domains` (merged into the
Supervisor options, like `allow_control`). Disarm by removing it.
