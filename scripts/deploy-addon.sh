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

# Some machines carry a company-wide ProxyCommand in ~/.ssh/config that applies
# to every host. The NUC is on the LAN, so that proxy answers 503 and the deploy
# dies with an unhelpful "Proxy error". SSH_OPTS lets you punch through without
# editing a managed config file:
#     SSH_OPTS="-o ProxyCommand=none" ./scripts/deploy-addon.sh ha-nuc
SSH_OPTS="${SSH_OPTS:-}"
# shellcheck disable=SC2086   # deliberate: SSH_OPTS is a list of flags.
ssh_() { ssh $SSH_OPTS "$@"; }

echo "Source : $SRC"
echo "Target : $HOST:$REMOTE_DIR"

if ! ssh_ -o BatchMode=yes -o ConnectTimeout=6 "$HOST" true 2>/dev/null; then
  echo
  echo "Cannot SSH to $HOST without a password/key."
  echo "Either add your key to the SSH add-on's authorized_keys, or re-run and"
  echo "type the password when prompted."
  echo "If the error mentions a proxy, retry with SSH_OPTS=\"-o ProxyCommand=none\"."
  echo
fi

# /addons is root-owned; the SSH add-on's user is usually not root, so extract
# through sudo when it is available and fall back to a plain extract otherwise.
if ssh_ "$HOST" 'sudo -n true' 2>/dev/null; then
  SUDO="sudo "
  echo "Using passwordless sudo on the remote."
else
  SUDO=""
fi

# COPYFILE_DISABLE stops macOS tar emitting ._AppleDouble members, which busybox
# tar on HA OS refuses with "can't open '._name': Permission denied".
# tar-over-ssh rather than rsync: the HA SSH add-on does not always ship rsync.
COPYFILE_DISABLE=1 tar -C "$(dirname "$SRC")" \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' --exclude='._*' \
    -czf - "$(basename "$SRC")" \
  | ssh_ "$HOST" "${SUDO}mkdir -p '$(dirname "$REMOTE_DIR")' && ${SUDO}tar -C '$(dirname "$REMOTE_DIR")' -xzf -"

echo
echo "Deployed. Next, in the Home Assistant UI:"
echo "  1. Settings > Apps > (kebab) Check for updates"
echo "  2. Open 'SNOF Firebase Bridge' > Update > Update AGAIN in the dialog."
echo "     The first click only opens the dialog; skipping the confirm leaves"
echo "     the old image running with no error anywhere."
echo
echo "Then verify what is actually running, rather than trusting the button:"
echo "  ssh \$SSH_OPTS $HOST 'sudo docker ps --filter name=app_local_snof_bridge --format \"{{.Image}}\"'"
