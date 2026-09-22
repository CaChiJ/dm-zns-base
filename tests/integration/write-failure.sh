#!/usr/bin/env bash
# Simulate a lower data write error after reservation, before submission.
# This verifies the error path, not hardware partial-write behavior.
set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-write-failure}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-64}
WRITE_BYTES=${WRITE_BYTES:-4096}
WRITE_OFFSET=${WRITE_OFFSET:-0}
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/write-failure"
require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
[[ "$WRITE_BYTES" =~ ^[0-9]+$ && "$WRITE_OFFSET" =~ ^[0-9]+$ ]] ||
	die "WRITE_BYTES and WRITE_OFFSET must be decimal integers"
WRITE_BYTES=$((10#$WRITE_BYTES))
WRITE_OFFSET=$((10#$WRITE_OFFSET))
(( WRITE_BYTES > 0 && WRITE_BYTES % 512 == 0 && WRITE_OFFSET % 512 == 0 &&
   WRITE_OFFSET + WRITE_BYTES <= 4096 )) ||
	die "the failed write must be sector-aligned and fit inside one 4 KiB block"
trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold="$TEST_THRESHOLD" fail_data_write_at=2
reset_zones
create_dm_target
require_status_fields writes_stopped

make_pattern_file "$tmp_dir/a" A
make_pattern_file "$tmp_dir/b" B
make_zero_file "$tmp_dir/zero"
dd if="$tmp_dir/a" of="$tmp_dir/expected" bs=4096 count=1 status=none
dd if="$tmp_dir/b" of="$tmp_dir/expected" bs=1 count="$WRITE_BYTES" \
	seek="$WRITE_OFFSET" conv=notrunc status=none
write_block "$tmp_dir/a" 0

# With threshold=1, ensure the old mapping lives only in an SSTable before
# attempting the failed overwrite. Otherwise retain it in the active table.
if [ "$TEST_THRESHOLD" -eq 1 ]; then
	deadline=$((SECONDS + 30))
	while [ "$(status_field sstables)" -lt 1 ] ||
	      [ "$(status_field flushing)" -ne 0 ]; do
		[ "$SECONDS" -lt "$deadline" ] || die "SSTable flush timed out"
		sleep 0.2
	done
fi

expect_write_failure() {
	local lba=$1
	if dd if="$tmp_dir/b" of="$DM_DEV" bs="$WRITE_BYTES" \
		seek="$((lba * 4096 + WRITE_OFFSET))" count=1 \
		oflag=direct,seek_bytes conv=notrunc status=none 2>"$tmp_dir/expected-error"; then
		fail "write unexpectedly succeeded at logical block $lba"
	fi
}

case_failed_overwrite() {
	local wp_before
	assert_block "$tmp_dir/a" 0
	wp_before=$(zone_write_pointer 0)
	expect_write_failure 0
	assert_eq "$(status_field writes_stopped)" 0 "WP resync did not enable writes"
	assert_eq "$(zone_write_pointer 0)" "$wp_before" \
		"injected pre-submission failure advanced the lower WP"
	assert_block "$tmp_dir/a" 0
}

case_next_write() {
	local wp_before wp_after
	wp_before=$(zone_write_pointer 0)
	assert_block "$tmp_dir/zero" 1
	write_block "$tmp_dir/b" 1
	wp_after=$(zone_write_pointer 0)
	assert_eq "$((wp_after))" "$((wp_before + 8))" \
		"resumed write did not consume exactly one block"
	assert_block "$tmp_dir/b" 1
	assert_block "$tmp_dir/a" 0
}

run_case "when an overwrite fails before submission, the old mapping remains readable" \
	case_failed_overwrite
run_case "after WP resync, a new write succeeds without target recreation" \
	case_next_write

case_resumed_write() {
	dd if="$tmp_dir/b" of="$DM_DEV" bs="$WRITE_BYTES" seek="$WRITE_OFFSET" \
		count=1 oflag=direct,seek_bytes conv=notrunc status=none
	assert_block "$tmp_dir/expected" 0
}
run_case "after WP resync, an overwrite succeeds without target recreation" \
	case_resumed_write
# Never reset zones between writes and this clean restart.
recreate_dm_target
run_case "when the target restarts, the successful overwrite survives" \
	assert_block "$tmp_dir/expected" 0
run_case "when the target restarts, the resumed new write survives" \
	assert_block "$tmp_dir/b" 1

# I/O errors are intentional in this suite; the normal regression suites
# continue to enforce that their workloads emit no new I/O errors.
report_summary
