#!/usr/bin/env bash
# One-time Firebase setup, once you have decided on a project ID.
#
#   ./scripts/setup-firebase.sh <project-id> [region]
#
# Creates the project, enables Realtime Database + Hosting, deploys the rules
# and the dashboard, and prints the two values the add-on needs.
set -euo pipefail

PROJECT="${1:-}"
REGION="${2:-asia-southeast1}"
DASH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../dashboard" && pwd)"

if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project-id> [region]"
  echo "Project IDs are permanent, lowercase, 6-30 chars, globally unique."
  exit 1
fi

echo "==> Creating Firebase project '$PROJECT'"
firebase projects:create "$PROJECT" --display-name "SNOF" || \
  echo "    (project may already exist - continuing)"

echo "==> Pointing the local config at it"
printf '{\n  "projects": {\n    "default": "%s"\n  }\n}\n' "$PROJECT" > "$DASH/.firebaserc"

cat <<'NOTE'

==> Manual steps the CLI cannot do (each is one click in the console):

  1. Realtime Database:  https://console.firebase.google.com/project/PROJECT/database
     "Create Database" -> pick your region -> start in LOCKED mode.
     (Locked is correct; the rules we deploy next replace the defaults.)

  2. Authentication:     https://console.firebase.google.com/project/PROJECT/authentication/providers
     Enable the Google sign-in provider.

  3. Service account:    https://console.firebase.google.com/project/PROJECT/settings/serviceaccounts/adminsdk
     "Generate new private key" -> save the JSON. This is the bridge's credential.

Press Enter once those three are done.
NOTE
read -r _

echo "==> Deploying database rules and dashboard"
( cd "$DASH" && firebase deploy --only database,hosting --project "$PROJECT" )

DB_URL="$(firebase database:instances:list --project "$PROJECT" 2>/dev/null | grep -o 'https://[^ ]*' | head -1 || true)"
echo
echo "==================================================================="
echo " Dashboard : https://${PROJECT}.web.app"
echo " DB URL    : ${DB_URL:-<check the console - Realtime Database page>}"
echo "==================================================================="
echo
echo "Now put the DB URL into the add-on's Configuration tab, drop the service"
echo "account JSON at /addon_configs/*_snof_bridge/serviceAccount.json, and Start."
