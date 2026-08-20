#!/usr/bin/env bash
# Smallest end-to-end path: null_blk -> module -> device-mapper -> 4 KiB I/O.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-smoke}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/smoke"

require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zone_zero
create_dm_target
io_errors_save "$tmp_dir/io-errors"

case_roundtrip() {
	make_random_file "$tmp_dir/write.bin"
	write_block "$tmp_dir/write.bin" 0
	assert_block "$tmp_dir/write.bin" 0
}

case_upper_is_conventional() {
	local dm_name zoned

	dm_name=$(basename "$(readlink -f "$DM_DEV")")
	zoned=$(cat "/sys/block/$dm_name/queue/zoned") ||
		fail "cannot read the zoned attribute of $DM_DEV"
	assert_eq "$zoned" none "the DM device is not conventional"
}

run_case "when 4 KiB is written and read back, the data matches" \
	case_roundtrip
run_case "when the target is created, the upper device is conventional" \
	case_upper_is_conventional
run_case "when the smoke workload finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
