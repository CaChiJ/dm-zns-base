#!/usr/bin/env bash
# Reads must return the newest mapping after a logical block is rewritten.
# Covers both the CRC read-after-write check and an explicit A -> B -> C
# rewrite of a single block.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-overwrite}
ZNS_REQUIRED_ENGINE=lsm
WORKLOAD_SIZE=${WORKLOAD_SIZE:-32M}
TEST_LBA=${TEST_LBA:-100}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/overwrite"

require_root
require_commands make fio dmsetup blkzone blockdev dd cmp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

make_pattern_file "$tmp_dir/pat-a" A
make_pattern_file "$tmp_dir/pat-b" B
make_pattern_file "$tmp_dir/pat-c" C

case_crc_read_after_write() {
	run_fio "$tmp_dir/verify.log" overwrite-verify \
		--rw=randwrite --bs=4k --size="$WORKLOAD_SIZE" --iodepth=8 \
		--verify=crc32c --verify_fatal=1 --verify_state_save=0
	detail "size=$WORKLOAD_SIZE verify=crc32c"
}

case_crc_after_repeated_loops() {
	run_fio "$tmp_dir/loops.log" overwrite-loops \
		--rw=randwrite --bs=4k --size="$WORKLOAD_SIZE" --iodepth=8 \
		--loops=3 --verify=crc32c --verify_fatal=1 --verify_state_save=0
	detail "loops=3"
}

case_latest_pattern_wins() {
	write_block "$tmp_dir/pat-a" "$TEST_LBA"
	write_block "$tmp_dir/pat-b" "$TEST_LBA"
	write_block "$tmp_dir/pat-c" "$TEST_LBA"
	assert_block "$tmp_dir/pat-c" "$TEST_LBA"
}

case_no_stale_pattern() {
	assert_block_differs "$tmp_dir/pat-a" "$TEST_LBA"
	assert_block_differs "$tmp_dir/pat-b" "$TEST_LBA"
}

run_case "when a $WORKLOAD_SIZE range is randwritten, CRC verify reads back the latest data" \
	case_crc_read_after_write
run_case "when the same range is rewritten three times, CRC verify still passes" \
	case_crc_after_repeated_loops
run_case "when block $TEST_LBA is rewritten A->B->C, a read returns C" \
	case_latest_pattern_wins
run_case "when block $TEST_LBA is rewritten A->B->C, a read returns neither A nor B" \
	case_no_stale_pattern
run_case "when the overwrite workload finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
