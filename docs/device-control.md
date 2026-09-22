# Device control

The dashboard can operate lights, switches and fans. This is the only inbound
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
- `domain` must match one of `switch|light|fan|input_boolean` **and** must be the
  domain named in `entity_id`
- `service` must be one of `turn_on|turn_off|toggle|set_percentage`
- `uid` must equal `auth.uid`
- `at` must equal server `now` — cannot be backdated past the staleness check
  nor postdated to fire later
- `data` accepts only `brightness` (0–255) and `percentage` (0–100); `$other`
  is rejected outright

Note: `database.rules.json` accepts `//` line comments but **not** `"//"` keys —
a `"//": "..."` entry fails deploy with `Expected '{'`.

### 2. The bridge — `addon/snof_bridge/bridge/commands.py`

Re-checks all of the above against `ALLOWED_SERVICES`, plus:

- drops anything older than `control_max_age_seconds` (default 120), so a queue
  that built up during an outage does not fire all at once on reconnect
- drops anything more than 60 s in the future (clock skew, not instruction)
- rejects `True` where a number is expected — `bool` is an `int` subclass in
  Python and would otherwise pass a range check
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
# want: "Watching command queue for domains: fan, input_boolean, light, switch"
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
