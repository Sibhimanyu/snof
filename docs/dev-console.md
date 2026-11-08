# Developer console (owner only, reads only)

Owner decision 2026-11-08. A third documented exception to "no new DCON code
on the NUC" (see [dcon-off-the-nuc.md](dcon-off-the-nuc.md)); it moves to Cloud
Functions at cut-over. Mobitech only.

```
app --append--> /farms/<farm>/dev_requests/<id>  {uid, at, method, path, query, body, bodyType, auth}
NUC <--stream--  validate, fill placeholders, send to the fixed host
NUC --result--> /private/dev_results/<farm>/<id>   {uid, at, status, ms, json, body, truncated, error?, request}
```

Code: `addon/snof_bridge/bridge/dev_console.py`. Tests: `test_dev_console_*` in
`addon/snof_bridge/tests/test_logic.py`.

## Gates (all must hold)

1. **RTDB rules** (`dev_requests`): the writer's verified email equals
   `acl/owner/email`; `meta/bridge/devConsole` is true (only the NUC writes it);
   `uid == auth.uid`, `at == now`, fixed shapes, `$other` false, path
   `/v1/http/` or `/v1/weather/cumulative/` only. `private/dev_results/<farm>`:
   the owner may read and delete, nobody may write.
2. **The NUC** re-checks everything. It cannot verify a Google ID token, so its
   owner check is `acl/admins/<uid> === true` (service-account-only, not
   grantable from a client) **and** `acl/directory/<uid>/email` equal to
   `acl/owner/email` (service-account-only). The directory entry is written by
   the user themselves, so it proves nothing alone; the verified-email proof is
   the rules' job. Also: request id `^[-_A-Za-z0-9]{1,64}$` (else only deleted,
   by its quoted id), age <= 60 s, one request per 3 s, 300 per day, GET/POST
   only, host always `dcon_base`, no redirects, 20 s timeout, and the
   **allow-list** below, applied to the request as written and again after the
   placeholders are filled. Commands, sign-in and sign-out are not on it (a
   login or logout would end the one Mobitech session SNOF and the phone share).
3. **`allow_dev_console`** in the add-on options, off by default. Needs
   `dcon_serial` and a token (`/private/mobitech` or the options).

## The allow-list (the apps mirror it)

Source of truth: `ALLOWED_REQUESTS` in `bridge/dev_console.py`; the same table
as JSON is `docs/dev-console-allowlist.json` (a test keeps them equal).

| Path | `action` (required) | `method` / `type` allowed |
|---|---|---|
| `/v1/http/` | `dashboard` | none |
| | `dcon_node_details` | `type=get` |
| | `dcon_node` | `method` = `get_node`, `get_all_valve` |
| | `dcon_timer` | `method=select` |
| | `logs` | `method` = `motor_log`, `timer_log`, `valve_log`, `flow_log` |
| | `reports` | `type` any |
| | `ferti` | `type` = `tank_get`, `inj_get`, `get`, `tank_log_web` |
| | `fertiSett` | `type=get` |
| | `getWliData`, `cmd_status` | none |
| `/v1/weather/cumulative/` (slash optional) | none | `type=rain` required |

Rules: `action`/`method`/`type` are read from the query and the body together
(form pairs, or the top level of a JSON object); a duplicate, a key with odd
case, `%`, `=` or `&`, a `;` separator, or an `action`/`method`/`type` nested
inside JSON is refused; a parameter an action does not list is refused; a JSON
body must be an object. Other parameters (ids, dates) are free.

## Secrets and redaction

The client writes placeholders; the NUC fills them (query/form values
percent-encoded, JSON values escaped). `auth: true` sends the session token as
the `authorization` header. Every answer is redacted before it is written:
JSON keys `users`, `sim`, `mobile`, `mobile_no`, `email`, `mail`, `uname`,
`user_id`, `imei`, `phone` dropped anywhere;
packets 1, 4, 5, 8 under any `packets` dropped; then the token (whole, its core between `:` and `@`, and its
URL-, JSON- and HTML-escaped forms), serial and device id become their
placeholders, and phone-like runs (10+ digits with spaces, dashes or
brackets; an ISO date is exempt) and any run of 10+ digits become
`<redacted>`. Errors are scrubbed the same way (non-JSON text gets the same string passes). Capped at 256 KB
(`truncated: true`); a response over 2 MB is not returned at all, because it
cannot be redacted structurally with confidence.

Answers live at `/private/dev_results/<farm>/<id>`, outside `/farms`, so the
viewer read grant cannot reach them; `/private` has no read rule of its own and
the owner alone may read or delete a result. Requests (placeholders only) stay
under `farms/<farm>/dev_requests` and are deleted at once. The client should
delete its result as soon as it shows it.

## Arming and disarming

Merge the one key into the existing Supervisor options (never POST a partial
options object: omitted keys revert to defaults) and restart the add-on:

```
allow_dev_console: true     # log: "Watching developer console (reads only)"
```

`meta/bridge.devConsole` becomes true on the next heartbeat (30 s); the apps
enable the console on it. Disarm with `allow_dev_console: false` (merge,
restart): the log says "Developer console is off", the queue is purged, and
the heartbeat flag goes false, which the rules also honour at once.
Add-on version 0.12.0.
