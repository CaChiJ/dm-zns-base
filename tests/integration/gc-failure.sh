#!/usr/bin/env bash
# Exercise the two destructive boundaries of GC on a temporary three-zone
# null_blk device: copying a live block and resetting its former zone.
set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-gc-failure}
# Used by the sourced test helpers.
# shellcheck disable=SC2034
ZNS_REQUIRED_ENGINE=lsm
# shellcheck disable=SC2034
ZNS_GC_POLICY=simple
TEST_DEVICE_NAME="nullb-gc-$$"
UNDERLYING="/dev/$TEST_DEVICE_NAME"
TEST_DEVICE_CONFIG="/sys/kernel/config/nullb/$TEST_DEVICE_NAME"
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/gc-failure"
require_root
require_commands make dmsetup blkzone blockdev dd cmp

tmp_dir=$(mktemp -d)

cleanup() {
	teardown_target
	if [ -d "$TEST_DEVICE_CONFIG" ]; then
		echo 0 >"$TEST_DEVICE_CONFIG/power" 2>/dev/null || true
		rmdir "$TEST_DEVICE_CONFIG" 2>/dev/null || true
	fi
}
trap cleanup EXIT

create_test_device() {
	[ -d /sys/kernel/config/nullb ] ||
		die "null_blk configfs is unavailable"
	mkdir "$TEST_DEVICE_CONFIG"
	echo 1 >"$TEST_DEVICE_CONFIG/zoned"
	echo 4 >"$TEST_DEVICE_CONFIG/zone_size"
	echo 12 >"$TEST_DEVICE_CONFIG/size"
	echo 1 >"$TEST_DEVICE_CONFIG/memory_backed"
	echo 1 >"$TEST_DEVICE_CONFIG/power"

	local deadline=$((SECONDS + 10))
	while [ ! -b "$UNDERLYING" ]; do
		[ "$SECONDS" -lt "$deadline" ] ||
			die "$UNDERLYING did not appear"
		sleep 0.1
	done
}

create_small_target() {
	echo "0 $logical_sectors zns-base $UNDERLYING" |
		dmsetup create "$TARGET_NAME" ||
		die "failed to create the small GC test target"
	# shellcheck disable=SC2034
	ZNS_TARGET_CREATED=1
}

prepare_failure() {
	local parameter=$1

	load_module "$parameter=1"
	reset_zones
	create_small_target
	require_status_fields writes_stopped reserve_zone valid_blocks gc_runs gc_moved zone_resets

	dd if="$tmp_dir/a" of="$DM_DEV" bs=4096 conv=notrunc oflag=direct status=none
	dd if="$tmp_dir/b" of="$DM_DEV" bs=4096 conv=notrunc oflag=direct status=none
}

expect_gc_failure() {
	if dd if="$tmp_dir/c" of="$DM_DEV" bs=4096 count=1 conv=notrunc \
		oflag=direct status=none 2>"$tmp_dir/expected-error"; then
		fail "the write that triggered GC unexpectedly succeeded"
	fi
}

assert_latest_range() {
	dd if="$DM_DEV" of="$tmp_dir/actual" bs=4096 count="$logical_blocks" iflag=direct status=none
	assert_files_equal "$tmp_dir/b" "$tmp_dir/actual" \
		"latest mappings changed after GC failure"
}

case_move_write_failure() {
	expect_gc_failure
	assert_eq "$(status_field writes_stopped)" 1 \
		"GC failure did not stop later writes"
	assert_eq "$(status_field gc_moved)" 0 \
		"a failed destination write was counted as moved"
	assert_eq "$(status_field zone_resets)" 0 \
		"victim was reset after a failed destination write"
	assert_eq "$(( $(zone_write_pointer 0) ))" "$zone_sectors" \
		"victim write pointer changed after a failed move"
	assert_eq "$(( $(zone_write_pointer "$zone_sectors") ))" 0 \
		"injected pre-submission failure advanced the reserve write pointer"
	assert_latest_range
}

case_zone_reset_failure() {
	expect_gc_failure
	assert_eq "$(status_field writes_stopped)" 1 \
		"reset failure did not stop later writes"
	assert_eq "$(status_field gc_moved)" "$logical_blocks" \
		"GC did not publish every successful move before reset"
	assert_eq "$(status_field gc_runs)" 0 \
		"failed GC was counted as complete"
	assert_eq "$(status_field zone_resets)" 0 \
		"injected reset failure was counted as a successful reset"
	assert_eq "$(status_field reserve_zone)" 1 \
		"reserve rotated even though reset failed"
	assert_eq "$(( $(zone_write_pointer 0) ))" "$zone_sectors" \
		"victim was reset despite the injected failure"
	assert_eq "$(( $(zone_write_pointer "$zone_sectors") ))" \
		"$logical_sectors" "moved blocks did not reach the reserve"
	assert_latest_range
}

create_test_device
require_host_managed
require_zones 3
build_engine lsm

zone_sectors=$(underlying_attr chunk_sectors)
logical_sectors=$((zone_sectors / 2))
logical_blocks=$((logical_sectors / 8))
logical_bytes=$((logical_sectors * 512))
head -c "$logical_bytes" /dev/zero | tr '\0' A >"$tmp_dir/a"
head -c "$logical_bytes" /dev/zero | tr '\0' B >"$tmp_dir/b"
make_pattern_file "$tmp_dir/c" C

prepare_failure fail_gc_move_write_at
run_case "when a GC destination write fails, the victim remains intact and readable" case_move_write_failure
detach_dm_target
unload_module
# shellcheck disable=SC2034
ZNS_MODULE_LOADED=0

prepare_failure fail_gc_zone_reset_at
run_case "when a GC zone reset fails, moved data remains readable without rotating the reserve" case_zone_reset_failure

# These two I/O failures are deliberate; other suites continue to reject
# unexpected kernel I/O errors.
report_summary
