#!/usr/bin/env bash
# Put a fresh Mobitech app command token in place — from the clipboard, never
# printed, never on a command line.
#
#   1. Capture the `authorization` header ("…@ios") of any request the
#      Mobitech iOS app sends to dcon.mobitechwireless.com, and copy it.
#   2. ./scripts/set-mobitech-command-token.sh
#
# Why this exists: valve commands need the Mobitech app's *session* token,
# and sessions end (signing in to the app again, or time). A dead token is
# answered "400 Bad request" — exactly like a fake one — while a missing one
# is "Unauthorized access". Proven 2026-09-24; see docs/irrigation-control.md.
#
# It updates both consumers: the add-on option dcon_command_auth on the NUC
# (merged into the existing options through the Supervisor API — a partial
# options object would reset every other key) and the Cloud Function secret
# DCON_COMMAND_AUTH (then redeploys, because a deploy pins the secret
# version). Last, a harmless status poll ("?@A8") proves the token works.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH_OPTS="${SSH_OPTS:--o ProxyCommand=none -o IdentitiesOnly=yes -i $HOME/.ssh/snof_ha}"
NUC="${NUC:-sibhiorchards@192.168.68.200}"

TOKEN="$(pbpaste | tr -d '\r\n\t ')"
# The app sends the header URL-encoded ("…%40ios"); Mobitech takes either form.
TOKEN="${TOKEN/%%40ios/@ios}"
if [[ "$TOKEN" != *@ios || ${#TOKEN} -lt 40 ]]; then
  echo "The clipboard does not hold a Mobitech app token (it should end in @ios)." >&2
  exit 1
fi
echo "Token on the clipboard: ${#TOKEN} characters, ends in @ios."

echo "==> NUC: merging dcon_command_auth into the add-on options and restarting"
# shellcheck disable=SC2086
printf '%s' "$TOKEN" | ssh $SSH_OPTS "$NUC" 'python3 -c "
import json, sys, urllib.request
tok = sys.stdin.read().strip()
T = open(\"/run/s6/container_environment/HASSIO_TOKEN\").read().strip()
H = {\"Authorization\": \"Bearer \" + T, \"Content-Type\": \"application/json\"}
def call(method, path, body=None):
    req = urllib.request.Request(\"http://supervisor\" + path, method=method, headers=H,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read() or b\"{}\")
opts = call(\"GET\", \"/addons/local_snof_bridge/info\")[\"data\"][\"options\"]
opts[\"dcon_command_auth\"] = tok
call(\"POST\", \"/addons/local_snof_bridge/options\", {\"options\": opts})
call(\"POST\", \"/addons/local_snof_bridge/restart\")
print(\"   options merged, add-on restarted\")
"'

echo "==> Cloud Function: secret DCON_COMMAND_AUTH, then redeploy to pin it"
printf '%s' "$TOKEN" | firebase functions:secrets:set DCON_COMMAND_AUTH --data-file=- \
  --project snof-live --force 2>&1 | grep -E "Created|Error" || true
(cd dashboard && firebase deploy --only functions:reports --project snof-live --force 2>&1 \
  | grep -E "Successful|Error" || true)

echo "==> Proving it: a status poll (?@A8) from the NUC with the new token"
sleep 20
# shellcheck disable=SC2086
ssh $SSH_OPTS "$NUC" 'sudo docker exec -i app_local_snof_bridge python3 -c "
import json, urllib.request
o = json.load(open(\"/data/options.json\"))
req = urllib.request.Request(\"https://dcon.mobitechwireless.com/v1/command/\", method=\"POST\",
    data=json.dumps({\"command\": \"?@A8\", \"device_id\": o[\"dcon_device_id\"].strip()}).encode(),
    headers={\"accept\": \"*/*\", \"content-type\": \"application/json\",
             \"authorization\": o[\"dcon_command_auth\"].strip()})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(\"   status poll ->\", r.status, r.read()[:120].decode())
except urllib.error.HTTPError as e:
    print(\"   status poll ->\", e.code, e.read()[:120].decode(\"utf-8\", \"replace\"))
"'
echo "A 200 means valve commands will go through. 400 Bad request: the token is still not a live session."
