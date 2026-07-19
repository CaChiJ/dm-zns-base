#!/usr/bin/env bash
# M1 smoke test: null_blk -> module -> device-mapper -> 4 KiB I/O.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"

require_root
trap cleanup_m1 EXIT

echo "[*] checking $UNDERLYING"
[ -b "$UNDERLYING" ] || {
	echo "[!] $UNDERLYING is missing. Run scripts/nullblk-up.sh first." >&2
	exit 1
}

build_module
load_module
create_dm_target

tmp_dir=$(mktemp -d)
cleanup_io() { rm -rf "$tmp_dir"; }
trap 'cleanup_io; cleanup_m1' EXIT

echo "[*] writing and reading 4 KiB"
dd if=/dev/zero of="$tmp_dir/write.bin" bs=4096 count=1 status=none
dd if="$tmp_dir/write.bin" of="$DM_DEV" bs=4096 count=1 oflag=direct status=none
dd if="$DM_DEV" of="$tmp_dir/read.bin" bs=4096 count=1 iflag=direct status=none
cmp "$tmp_dir/write.bin" "$tmp_dir/read.bin"

echo "M1 smoke test: PASS"
