#!/usr/bin/env bash
# Operations outside ordinary 4 KiB READ/WRITE must be advertised consistently.
# This suite does not claim crash durability: fsync is a compatibility check.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-operation-contract}
ZNS_REQUIRED_ENGINE=lsm
OPERATION_SIZE_MB=${OPERATION_SIZE_MB:-32}
OPERATION_ZONE_MB=${OPERATION_ZONE_MB:-4}
OPERATION_TIMEOUT=${OPERATION_TIMEOUT:-10}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/operation-contract"

require_root
require_commands make modprobe dmsetup blkzone blockdev fio blkdiscard dd cmp timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

create_nullblk_fixture "$OPERATION_SIZE_MB" "$OPERATION_ZONE_MB"
build_engine
load_module
reset_zones
create_dm_target
make_pattern_file "$tmp_dir/sentinel.bin" S
io_errors_save "$tmp_dir/io-errors-before-unsupported"

dm_queue_attr() {
	local attr=$1 kernel_name

	kernel_name=$(basename "$(readlink -f "$DM_DEV")")
	cat "/sys/block/$kernel_name/queue/$attr"
}

case_sync_write_compatible() {
	run_fio "$tmp_dir/fsync.log" "operation-fsync" \
		--rw=write --bs=4k --size=64k --offset=1M --iodepth=1 \
		--fsync=1 --verify=crc32c --verify_fatal=1 --verify_state_save=0
	detail "size=64k bs=4k fsync=1"
}

case_unsupported_not_advertised() {
	local discard_max zeroes_max

	discard_max=$(dm_queue_attr discard_max_bytes) ||
		fail "the upper queue has no discard_max_bytes attribute"
	zeroes_max=$(dm_queue_attr write_zeroes_max_bytes) ||
		fail "the upper queue has no write_zeroes_max_bytes attribute"
	assert_eq "$discard_max" 0 "discard is advertised despite having no mapping semantics"
	assert_eq "$zeroes_max" 0 "write zeroes is advertised despite having no mapping semantics"
	detail "discard_max=$discard_max zeroes_max=$zeroes_max"
}

case_discard_fails_safely() {
	local status

	write_block "$tmp_dir/sentinel.bin" 0
	if timeout "$OPERATION_TIMEOUT" blkdiscard -o 0 -l "$ZNS_BLOCK_BYTES" \
		"$DM_DEV" >"$tmp_dir/discard.log" 2>&1; then
		fail "discard succeeded even though the upper queue advertises no support"
	else
		status=$?
	fi
	[ "$status" -ne 124 ] || fail "discard hung instead of failing"
	assert_block "$tmp_dir/sentinel.bin" 0
	detail "exit=$status"
}

case_zeroout_fails_safely() {
	local status

	write_block "$tmp_dir/sentinel.bin" 0
	if timeout "$OPERATION_TIMEOUT" blkdiscard --zeroout -o 0 \
		-l "$ZNS_BLOCK_BYTES" "$DM_DEV" >"$tmp_dir/zeroout.log" 2>&1; then
		fail "zeroout succeeded even though the upper queue advertises no support"
	else
		status=$?
	fi
	[ "$status" -ne 124 ] || fail "zeroout hung instead of failing"
	assert_block "$tmp_dir/sentinel.bin" 0
	detail "exit=$status"
}

run_case "when a synchronous 4 KiB workload runs, fsync requests complete and verify" \
	case_sync_write_compatible
run_case "when the synchronous workload finishes, it adds no kernel I/O errors" \
	assert_no_new_io_errors "$tmp_dir/io-errors-before-unsupported"
run_case "when unsupported operations are queried, the upper queue advertises neither" \
	case_unsupported_not_advertised
run_case "when discard is requested, it fails promptly without changing mapped data" \
	case_discard_fails_safely
run_case "when zeroout is requested, it fails promptly without changing mapped data" \
	case_zeroout_fails_safely

report_summary
