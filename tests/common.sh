#!/usr/bin/env bash
# Common helpers for dm-zns-base smoke tests.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TESTS_DIR/.." && pwd)
SRC_DIR="$ROOT_DIR/src"
MOD_NAME=${MOD_NAME:-dm-zns-base}
TARGET_NAME=${TARGET_NAME:-m1-smoke}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
DM_DEV="/dev/mapper/$TARGET_NAME"
KO_PATH="$SRC_DIR/$MOD_NAME.ko"

require_root() {
	[ "$(id -u)" -eq 0 ] || {
		echo "Run with sudo: sudo bash tests/m1-smoke.sh" >&2
		return 1
	}
}

build_module() {
	echo "[*] building $MOD_NAME.ko"
	make -C "$SRC_DIR"
	[ -f "$KO_PATH" ] || {
		echo "[!] module was not produced: $KO_PATH" >&2
		return 1
	}
}

remove_dm_target() {
	dmsetup remove "$TARGET_NAME" 2>/dev/null || true
}

unload_module() {
	rmmod "$MOD_NAME" 2>/dev/null || true
}

cleanup_m1() {
	remove_dm_target
	unload_module
}

load_module() {
	# Make repeated runs deterministic when a previous run was interrupted.
	remove_dm_target
	unload_module
	insmod "$KO_PATH"
}

create_dm_target() {
	local sectors
	sectors=$(blockdev --getsz "$UNDERLYING")
	echo "0 $sectors zns-base $UNDERLYING" | dmsetup create "$TARGET_NAME"
	[ -b "$DM_DEV" ]
}
