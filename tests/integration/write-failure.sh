#!/usr/bin/env bash
# A failed physical overwrite must not publish a mapping to unwritten media,
# and allocation must remain consistent with the underlying zone write pointer.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-write-failure}
ZNS_REQUIRED_ENGINE=lsm
TEST_LBA=${TEST_LBA:-100}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/write-failure"

require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
require_nullblk_badblocks

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target

make_pattern_file "$tmp_dir/pat-a" A
make_pattern_file "$tmp_dir/pat-b" B
make_pattern_file "$tmp_dir/pat-c" C

case_failed_overwrite_is_atomic() {
	local failed_sector failed_end wp_after_failure wp_after_recovery

	write_block "$tmp_dir/pat-a" "$TEST_LBA"
	assert_block "$tmp_dir/pat-a" "$TEST_LBA"

	failed_sector=$(zone_absolute_wp 0) ||
		fail "could not read the next physical append sector"
	failed_end=$((failed_sector + BLOCK_SECTORS - 1))
	nullblk_badblock_add "$failed_sector" "$failed_end" ||
		fail "could not inject a badblock at sectors $failed_sector-$failed_end"

	if dd if="$tmp_dir/pat-b" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		seek="$TEST_LBA" count=1 conv=notrunc oflag=direct status=none; then
		fail "the injected physical write failure was reported as success"
	fi

	wp_after_failure=$(zone_absolute_wp 0) ||
		fail "could not read the write pointer after the failed write"
	assert_eq "$wp_after_failure" "$failed_sector" \
		"the underlying write pointer moved after a fully failed write"

	nullblk_badblock_remove "$failed_sector" "$failed_end" ||
		fail "could not remove the injected badblock"

	assert_block "$tmp_dir/pat-a" "$TEST_LBA"
	write_block "$tmp_dir/pat-c" "$TEST_LBA"
	assert_block "$tmp_dir/pat-c" "$TEST_LBA"

	wp_after_recovery=$(zone_absolute_wp 0) ||
		fail "could not read the write pointer after recovery"
	assert_eq "$wp_after_recovery" "$((failed_sector + BLOCK_SECTORS))" \
		"the next write did not reuse the unconsumed append position"
	detail "failed_sector=$failed_sector recovered_wptr=$wp_after_recovery"
}

case_failed_partial_overwrite_is_atomic() {
	local lba=$((TEST_LBA + 1))
	local failed_sector failed_end wp_after_failure wp_after_recovery

	write_block "$tmp_dir/pat-a" "$lba"
	head -c 512 /dev/zero | tr '\0' B >"$tmp_dir/partial-b"
	head -c 512 /dev/zero | tr '\0' C >"$tmp_dir/partial-c"
	cp "$tmp_dir/pat-a" "$tmp_dir/partial-expected"
	dd if="$tmp_dir/partial-c" of="$tmp_dir/partial-expected" \
		bs=512 seek=3 count=1 conv=notrunc status=none

	failed_sector=$(zone_absolute_wp 0) ||
		fail "could not read the append sector before partial overwrite"
	failed_end=$((failed_sector + BLOCK_SECTORS - 1))
	nullblk_badblock_add "$failed_sector" "$failed_end" ||
		fail "could not inject a partial-RMW badblock"

	if dd if="$tmp_dir/partial-b" of="$DM_DEV" bs=512 \
		seek=$((lba * BLOCK_SECTORS + 3)) count=1 \
		conv=notrunc oflag=direct status=none; then
		fail "the failed partial RMW was reported as success"
	fi

	wp_after_failure=$(zone_absolute_wp 0) ||
		fail "could not read the write pointer after failed partial RMW"
	assert_eq "$wp_after_failure" "$failed_sector" \
		"the write pointer moved after a fully failed partial RMW"
	nullblk_badblock_remove "$failed_sector" "$failed_end" ||
		fail "could not remove the partial-RMW badblock"
	assert_block "$tmp_dir/pat-a" "$lba"

	dd if="$tmp_dir/partial-c" of="$DM_DEV" bs=512 \
		seek=$((lba * BLOCK_SECTORS + 3)) count=1 \
		conv=notrunc oflag=direct status=none ||
		fail "partial RMW did not recover after fault removal"
	assert_block "$tmp_dir/partial-expected" "$lba"
	wp_after_recovery=$(zone_absolute_wp 0) ||
		fail "could not read the write pointer after partial RMW recovery"
	assert_eq "$wp_after_recovery" "$((failed_sector + BLOCK_SECTORS))" \
		"partial RMW did not reuse the unconsumed append position"
	detail "failed_sector=$failed_sector recovered_wptr=$wp_after_recovery"
}

run_case "when a physical overwrite fails, the old mapping and append position survive" \
	case_failed_overwrite_is_atomic
run_case "when a partial overwrite fails, all old bytes and the append position survive" \
	case_failed_partial_overwrite_is_atomic

report_summary
