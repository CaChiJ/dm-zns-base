#!/usr/bin/env bash
# Simulate a lower data write error after reservation, before submission.
# This verifies the error path, not hardware partial-write behavior.
set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-write-failure}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-64}
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/write-failure"
require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
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
	if dd if="$tmp_dir/b" of="$DM_DEV" bs=4096 seek="$lba" count=1 \
		oflag=direct conv=notrunc status=none 2>"$tmp_dir/expected-error"; then
		fail "write unexpectedly succeeded at logical block $lba"
	fi
}

case_failed_overwrite() {
	local wp_before
	assert_block "$tmp_dir/a" 0
	wp_before=$(zone_write_pointer 0)
	expect_write_failure 0
	assert_eq "$(status_field writes_stopped)" 1 "data writes did not stop"
	assert_eq "$(zone_write_pointer 0)" "$wp_before" \
		"injected pre-submission failure advanced the lower WP"
	assert_block "$tmp_dir/a" 0
}

case_stopped_writes() {
	local wp_before
	wp_before=$(zone_write_pointer 0)
	expect_write_failure 1
	assert_eq "$(zone_write_pointer 0)" "$wp_before" "lower WP changed"
	assert_block "$tmp_dir/zero" 1
	assert_block "$tmp_dir/a" 0
}

run_case "when an overwrite fails before submission, the old mapping remains readable" \
	case_failed_overwrite
run_case "when writes are stopped, new writes fail without advancing the lower WP" \
	case_stopped_writes

# Lifecycle changes stay outside run_case's subshell, so cleanup owns the
# correct target even if recreation fails. Never reset zones between restarts.
recreate_dm_target
run_case "when the target restarts after a failed overwrite, the old data survives" \
	assert_block "$tmp_dir/a" 0
run_case "when the target restarts, data writes are enabled again" \
	assert_eq "$(status_field writes_stopped)" 0

case_resumed_write() {
	write_block "$tmp_dir/b" 0
	assert_block "$tmp_dir/b" 0
}
run_case "when writing resumes from the reported WP, an overwrite succeeds" \
	case_resumed_write
recreate_dm_target
run_case "when the target restarts again, the successful overwrite survives" \
	assert_block "$tmp_dir/b" 0

# I/O errors are intentional in this suite; the normal regression suites
# continue to enforce that their workloads emit no new I/O errors.
report_summary
