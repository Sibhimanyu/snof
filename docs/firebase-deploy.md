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

RTDB rules cannot match on email — dots are illegal in keys and rules have no
string functions — so the allowlist is keyed by UID. `tools/grant-access.js`
resolves an email to its UID.

```bash
cd tools && npm install
export FIREBASE_DB_URL=https://snof-live-default-rtdb.asia-southeast1.firebasedatabase.app
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/snof/serviceAccount.json

npm run grant  -- someone@example.com            # viewer
npm run grant  -- someone@example.com --control  # viewer + controller
npm run revoke -- someone@example.com --control  # demote only
npm run list
```

The person must have signed in once so a Firebase Auth user exists. Until they
are granted, the dashboard shows them their own email and the exact command the
owner needs to run — that is deliberate, it turns "access denied" into a
one-line fix.

## The service account

`~/.config/snof/serviceAccount.json`, mode 0600. Full-admin on the database and
**never committed**. On the NUC it lives at
`/addon_configs/local_snof_bridge/serviceAccount.json`. Generating a fresh key
from the console does not revoke the old one, so a second machine can get its
own copy without disturbing the running bridge.
