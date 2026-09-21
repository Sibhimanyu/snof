#!/usr/bin/env bash
# Copy the add-on source onto the Home Assistant NUC's local add-on folder.
#
#   ./scripts/deploy-addon.sh [user@host] [remote_addons_dir]
#
# Requires the "Advanced SSH & Web Terminal" (or SSH) add-on running on HA.
# After it finishes: Settings > Add-ons > Add-on Store > (kebab) > Check for updates,
# then install/restart "SNOF Firebase Bridge" from the Local add-ons section.
set -euo pipefail

HOST="${1:-root@homeassistant.local}"
REMOTE_DIR="${2:-/addons/snof_bridge}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../addon/snof_bridge" && pwd)"

echo "Source : $SRC"
echo "Target : $HOST:$REMOTE_DIR"

if ! ssh -o BatchMode=yes -o ConnectTimeout=6 "$HOST" true 2>/dev/null; then
  echo
  echo "Cannot SSH to $HOST without a password/key."
  echo "Either add your key to the SSH add-on's authorized_keys, or re-run and"
  echo "type the password when prompted."
  echo
fi

# tar-over-ssh rather than rsync: the HA SSH add-on does not always ship rsync.
tar -C "$(dirname "$SRC")" \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' \
    -czf - "$(basename "$SRC")" \
  | ssh "$HOST" "mkdir -p '$(dirname "$REMOTE_DIR")' && tar -C '$(dirname "$REMOTE_DIR")' -xzf -"

echo
echo "Deployed. Next, in the Home Assistant UI:"
echo "  1. Settings > Add-ons > Add-on Store > ... menu > Check for updates"
echo "  2. Open 'SNOF Firebase Bridge' under Local add-ons > Install"
echo "  3. Configuration tab: set firebase_db_url, then Start"
