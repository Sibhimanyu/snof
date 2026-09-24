# Deploying the dashboard and rules

Project `snof-live`, RTDB in `asia-southeast1`, hosted at
https://snof-live.web.app. Requires `firebase login` as the account that owns
the project.

```bash
cd dashboard
firebase deploy --only hosting             # the dashboard
firebase deploy --only database            # the security rules
firebase deploy --only hosting,database    # both
```

Both are fast and safe to repeat. Hosting keeps previous versions, so a bad
deploy is a rollback in the console, not an outage.

## Report function

Irrigation reports are a Python Cloud Function, `irrigation_report`, in
`dashboard/functions/`, codebase `reports`, region `asia-southeast1`.
[irrigation.md](irrigation.md) covers what it does and what it costs.

Once per machine, the CLI needs a venv to read the function definitions:

```bash
cd dashboard/functions
python3.11 -m venv venv && ./venv/bin/pip install -r requirements.txt
python3 tests/test_reports.py            # pure, needs none of that
```

Once per project, set the two secrets. Paste the values, and never put them
in a file in the repo:

```bash
cd dashboard
firebase functions:secrets:set DCON_TOKEN_ID
firebase functions:secrets:set DCON_SERIAL
```

A non-interactive deploy also needs the two plain parameters in
`dashboard/functions/.env`. The repo's `.gitignore` keeps every `.env` out
of git on purpose, so create it on each machine (neither value is secret):

```bash
printf 'DCON_BASE=https://dcon.mobitechwireless.com\nFARM_SLUG=snof\n' \
  > dashboard/functions/.env
```

Then deploy:

```bash
firebase deploy --only functions:reports
```

The first 2nd-gen deploy on a project fails with "Permission denied while
using the Eventarc Service Agent". Eventarc's permissions are still
propagating. Wait about three minutes and run the same command again.

The first deploy enables Cloud Functions, Cloud Build, Artifact Registry,
Eventarc and Secret Manager on the project. That needs Blaze, which
`snof-live` already has. Verify the function end to end by pressing Generate
on a live report and reading its log:

```bash
firebase functions:log --only irrigation_report | tail -20
```

Look for `Irrigation report <id> (<type>): ok in 1.4s`. To stop all vendor
calls without a deploy, set `/farms/snof/meta/reports/enabled` to `false`
with the service account.

## Verify, do not assume

`index.html` is served `no-cache`, but `styles.css` and `app.js` are cached
hard. After deploying, confirm what is actually being served:

```bash
for f in app.js styles.css; do
  live=$(curl -s https://snof-live.web.app/$f | shasum | cut -c1-12)
  local=$(shasum dashboard/public/$f | cut -c1-12)
  [ "$live" = "$local" ] && echo "$f MATCH" || echo "$f DIFFER"
done
```

A browser that still shows the old UI after a matching hash needs a hard
refresh, not another deploy.

## The rules gotcha

`database.rules.json` accepts `//` line comments — but **not** `"//"` object
keys. Firebase parses those as rule names and the deploy fails with:

```
Error: Syntax error in database rules:
13:19: Expected '{'.
```

Use line comments. The rules are heavily commented on purpose; the `/commands`
path is the only client-writable location in the tree and the reasoning belongs
next to it.

## The allowlist

Three tiers: **viewer** (sees the farm), **controller** (viewer + can operate
lights/switches/fans and run irrigation reports), **admin** (controller +
can add people and grant/revoke the other two tiers for anyone else, from
the dashboard's `#/admin` page). Each tier implies the ones below it.

### Day to day: the dashboard, not the command line

An admin adds and manages everyone from `#/admin` — no terminal, no service
account:

- **Add a person** — type an email, pick View or View + control, press Add.
  This writes `acl/invites/<email key>` (RTDB keys cannot contain `.`, so the
  key is the lowercased email with `.` swapped for `,`). The invite sits
  there, cancellable, until that person signs in with that Google account for
  the first time — `enter()` in `app.js` then claims it automatically
  (writes `acl/viewers`/`acl/controllers` for their new uid, deletes the
  invite) before the dashboard even finishes loading for them. They never see
  a denied screen.
- **Grant / Revoke** on an existing row — for someone who already signed in
  at least once (so `acl/directory/$uid` exists) without an invite, or to
  change or remove someone's tier later.

Both paths are enforced by `database.rules.json`, not just the UI: an admin's
write to `acl/viewers`/`acl/controllers` must be `true` or a delete, granting
control requires the target already be a viewer, and the invited person's own
self-claim is gated on `auth.token.email` matching the invite key — they
cannot claim someone else's invite or invite themselves.

### Admin is command-line only, on purpose

`acl/admins/$uid` has `.write: false` in the rules regardless of who is
asking — an admin's dashboard session cannot create another admin, the same
way the report builder cannot operate a pump. Promoting someone to admin
always comes back through `tools/grant-access.js` with the service account
credential:

```bash
cd tools && npm install
export FIREBASE_DB_URL=https://snof-live-default-rtdb.asia-southeast1.firebasedatabase.app
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/snof/serviceAccount.json

npm run grant  -- someone@example.com --admin    # viewer + controller + admin
npm run revoke -- someone@example.com --admin    # demote to controller
npm run list
```

The same script still works for plain viewer/controller grants (`npm run
grant -- someone@example.com [--control]`) — it is the bootstrap path for the
very first admin (who by definition has no admin dashboard yet to add
themselves from) and a fallback if the database is ever unreachable from a
browser. It is no longer the day-to-day path once at least one admin exists.

## The service account

`~/.config/snof/serviceAccount.json`, mode 0600. Full-admin on the database and
**never committed**. On the NUC it lives at
`/addon_configs/local_snof_bridge/serviceAccount.json`. Generating a fresh key
from the console does not revoke the old one, so a second machine can get its
own copy without disturbing the running bridge.

## Cache headers: why a deploy did not reach the browser

Hosting matches `headers` against the **request path**, not the file the
rewrite resolves to. The app is served at `/`, which has no extension, so a
rule like `**/*.@(html|js|css)` never applies to it and the bare root fell back
to the default `max-age=3600`. On 2026-09-23 that put an hour-old bundle in
front of a fix that had already shipped: the page still offered a button the
new code disables, and the press wrote two requests nothing would answer.

There is no build step and no content hashing here, so a long max-age is wrong
for every file the app is made of. `/`, and anything ending in `.html`, `.js`
or `.css`, are all `no-cache` now — the browser still revalidates with an ETag
and still gets a 304 when nothing changed, so the cost is one conditional
request per load, not a re-download.

Check it after any hosting change, because a wrong answer here is invisible
until someone reports a fix that "did not work":

```bash
for u in / /app.js /styles.css; do
  printf "%-12s " "$u"; curl -sI "https://snof-live.web.app$u" | grep -i "^cache-control"
done
```
