#!/usr/bin/env bash
# Tear down a null_blk device created by nullblk-up.sh.
# Also unloads the module if no instances remain.

set -uo pipefail

NB_NAME=${NB_NAME:-nullb0}
CONFIG="/sys/kernel/config/nullb/$NB_NAME"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

if [ -d "$CONFIG" ]; then
	echo "[*] Powering off $NB_NAME"
	echo 0 > "$CONFIG/power" 2>/dev/null || true
	rmdir "$CONFIG" 2>/dev/null && echo "[*] Removed $NB_NAME from configfs"
fi

if [ -z "$(ls /sys/kernel/config/nullb/ 2>/dev/null)" ]; then
	if lsmod | grep -q '^null_blk '; then
		echo "[*] No instances left; unloading null_blk"
		rmmod null_blk 2>/dev/null || echo "    (still in use)"
	fi
fi

echo "[OK] Done."
