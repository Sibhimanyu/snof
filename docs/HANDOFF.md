# Where this was left — 2026-09-22

Start here. Everything below links to a document that goes deeper.

## State of play

| Piece | Status |
|---|---|
| Dashboard | **Live** at https://snof-live.web.app, rebuilt as an app shell |
| RTDB rules | **Live**, including the `/commands` write path |
| Add-on 0.3.0 | **Running** on the NUC, verified by image tag and container contents |
| Device control | **Deployed but asleep.** Two independent switches still off |
| Git | 5 feature commits + 2 doc commits on `dashboard-design-review`, **not pushed** |

The branch has never been pushed and no PR exists. `origin/main` was merged in
(commit `a6157fa`) so the branch contains everything on main.

## What "asleep" means, precisely

Control is fully built and deployed, and cannot do anything. Three reasons, any
one of which is sufficient:

1. `allow_control: false` in the add-on options — the bridge logs
   `Device control is disabled; not watching the command queue` at startup and
   never opens the command stream.
2. `acl/controllers` in RTDB is empty, so no client can write a command.
3. RTDB rules reject any write that is not a valid command from a controller.

Arming it is two deliberate steps, described in [device-control.md](device-control.md).

## The honest risk

**The command path has never executed against real hardware.** Unit tests cover
the validator's refusal cases; the websocket `call_service`, the RTDB stream
parsing, and the delete-after-handling path have run zero times outside the
author's head. CLAUDE.md's own note — that every real bug in this project has
lived in the async orchestration, not the pure logic — applies squarely here.

When it is armed, watch the bridge log while the first switch is flipped:

```bash
ssh $SSH_OPTS sibhiorchards@192.168.68.200 \
  'sudo docker logs -f app_local_snof_bridge 2>&1 | tail -30'
```

Expect `Ran switch.turn_on on switch.x`. Anything else is the bug this project
has been reliably producing in exactly this layer.

## Open items

- **Rotate the SSH password.** The Advanced SSH add-on's options still carry a
  plaintext `password:`. It was exposed in screenshots during this session. Key
  auth is proven; delete the line and change the password.
- **Two deploy keys are authorized**: the original
  `snof-bridge-deploy@Sibhimanyus-MacBook-Pro-2` and
  `snof-bridge-deploy-20260922` added for this machine. Remove whichever is not
  wanted; do not remove both.
- **Most entities have no area.** 1366 registry entities, 19 with an area, so
  ~85% of the dashboard groups under "Unassigned". That is a Home Assistant
  hygiene task and it flows through to the dashboard automatically.
- **373 of 698 published entities are unavailable.** The dashboard now groups
  these by domain rather than listing them, but the underlying integrations are
  presumably genuinely broken and worth a look.
- The dashboard is not pushed to `origin`; decide whether to PR or merge.

## Map

| Document | Covers |
|---|---|
| [nuc-access-and-deploy.md](nuc-access-and-deploy.md) | SSH to the NUC, deploying the add-on, **§6a scripts it with no UI** |
| [device-control.md](device-control.md) | The command path, its three gates, and how to arm it |
| [dashboard.md](dashboard.md) | Front-end architecture, design system, bugs that must not return |
| [firebase-deploy.md](firebase-deploy.md) | Hosting, rules, and the two-tier allowlist |
| [testing-and-preview.md](testing-and-preview.md) | Every suite, and the fixture that matters |
