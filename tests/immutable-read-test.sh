#!/usr/bin/env bash
# Verify LSM reads across freeze and repeated synchronous compaction.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-immutable-read}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
TEST_THRESHOLD=2
export TARGET_NAME UNDERLYING
export ZNS_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"

count_io_errors() {
	dmesg | grep -Eic \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' ||
		true
}

write_block() {
	local input=$1
	local logical_block=$2

	dd if="$input" of="$DM_DEV" bs=4096 seek="$logical_block" count=1 \
		conv=notrunc oflag=direct status=none
}

read_block() {
	local logical_block=$1
	local output=$2

	dd if="$DM_DEV" of="$output" bs=4096 skip="$logical_block" count=1 \
		iflag=direct status=none
}

assert_block() {
	local expected=$1
	local logical_block=$2
	local label=$3
	local output="$tmp_dir/read-$label.bin"

	read_block "$logical_block" "$output"
	cmp "$expected" "$output" || {
		echo "[FAIL] $label read returned unexpected data" >&2
		exit 1
	}
}

require_root
tmp_dir=$(mktemp -d)
cleanup_immutable_read_test() {
	rm -rf "$tmp_dir"
	cleanup_m1
}
trap cleanup_immutable_read_test EXIT

[ -b "$UNDERLYING" ] || {
	echo "[FAIL] $UNDERLYING is missing. Run scripts/nullblk-up.sh first." >&2
	exit 1
}

echo "[*] building LSM engine"
make -C "$SRC_DIR" clean ZNS_ENGINE=lsm
make -C "$SRC_DIR" ZNS_ENGINE=lsm

remove_dm_target
unload_module
if lsmod | grep -q '^dm_zns_base '; then
	echo "[FAIL] dm-zns-base is still in use by another DM target" >&2
	echo "       Remove the existing target before running this test." >&2
	exit 1
fi

echo "[*] resetting all zones on $UNDERLYING"
blkzone reset "$UNDERLYING"

insmod "$KO_PATH" memtable_threshold="$TEST_THRESHOLD"
create_dm_target

parameter_path=/sys/module/dm_zns_base/parameters/memtable_threshold
[ -r "$parameter_path" ] &&
	[ "$(cat "$parameter_path")" -eq "$TEST_THRESHOLD" ] || {
	echo "[FAIL] MemTable threshold module parameter was not applied" >&2
	exit 1
}

dd if=/dev/urandom of="$tmp_dir/a.bin" bs=4096 count=1 status=none
dd if=/dev/urandom of="$tmp_dir/b.bin" bs=4096 count=1 status=none
dd if=/dev/urandom of="$tmp_dir/c.bin" bs=4096 count=1 status=none
dd if=/dev/urandom of="$tmp_dir/d.bin" bs=4096 count=1 status=none
dd if=/dev/urandom of="$tmp_dir/e.bin" bs=4096 count=1 status=none
dd if=/dev/urandom of="$tmp_dir/f.bin" bs=4096 count=1 status=none
dd if=/dev/zero of="$tmp_dir/zero.bin" bs=4096 count=1 status=none

errors_before=$(count_io_errors)

echo "[*] filling active MemTable to trigger freeze"
write_block "$tmp_dir/a.bin" 10
write_block "$tmp_dir/b.bin" 20

echo "[*] reading a mapping that exists only in immutable"
assert_block "$tmp_dir/a.bin" 10 immutable

echo "[*] writing and reading from the new active MemTable"
write_block "$tmp_dir/c.bin" 30
assert_block "$tmp_dir/c.bin" 30 active

echo "[*] overwriting an immutable mapping in active"
write_block "$tmp_dir/d.bin" 10
assert_block "$tmp_dir/d.bin" 10 latest

echo "[*] verifying mappings after the first compaction"
assert_block "$tmp_dir/b.bin" 20 compacted-old
assert_block "$tmp_dir/c.bin" 30 compacted-new

echo "[*] triggering and verifying repeated compaction"
write_block "$tmp_dir/e.bin" 40
assert_block "$tmp_dir/e.bin" 40 repeat-active
write_block "$tmp_dir/f.bin" 50
assert_block "$tmp_dir/d.bin" 10 repeat-latest
assert_block "$tmp_dir/e.bin" 40 repeat-first
assert_block "$tmp_dir/f.bin" 50 repeat-second

echo "[*] checking zero-fill for an unmapped logical block"
assert_block "$tmp_dir/zero.bin" 60 unmapped

errors_after=$(count_io_errors)
[ "$errors_after" -eq "$errors_before" ] || {
	echo "[FAIL] detected new kernel I/O or zoned write rejection errors" >&2
	exit 1
}

echo "Synchronous MemTable compaction read test: PASS"
