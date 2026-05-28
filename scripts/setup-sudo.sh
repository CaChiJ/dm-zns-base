#!/usr/bin/env bash
# Optional: install /etc/sudoers.d/dm-zns-base so scripts/* can run without
# a password prompt. Uninstall with:  sudo rm /etc/sudoers.d/dm-zns-base

set -euo pipefail

DST=/etc/sudoers.d/dm-zns-base
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if [ "$(id -u)" -ne 0 ]; then
	echo "[!] Run as root:  sudo bash $0" >&2
	exit 1
fi

USER_NAME=${SUDO_USER:-$(logname 2>/dev/null || echo splab)}

cat > "$TMP" <<EOF
# NOPASSWD entries for the dm-zns-base helper scripts.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/bash /home/splab/dm-zns-base/scripts/nullblk-up.sh
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/bash /home/splab/dm-zns-base/scripts/nullblk-down.sh
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/bash /home/splab/dm-zns-base/scripts/test-basic.sh
EOF

if ! visudo -c -f "$TMP"; then
	echo "[!] sudoers syntax check failed; aborting" >&2
	exit 1
fi

install -m 0440 -o root -g root "$TMP" "$DST"
echo "[OK] Installed $DST (for user: $USER_NAME)"
echo "    scripts/*.sh can now be run without a password prompt."
