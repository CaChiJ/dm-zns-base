#!/usr/bin/env bash
# 4 KiB random writes must land as sequential appends on the underlying zones.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-randwrite}
ZNS_REQUIRED_ENGINE=lsm
WORKLOAD_SIZE=${WORKLOAD_SIZE:-4M}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/randwrite"

require_root
require_commands make fio dmsetup blkzone blockdev dd
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

wp_before=$(zone_write_pointer 0)
[ -n "$wp_before" ] || die "could not read the initial zone write pointer"

case_fio_randwrite() {
	run_fio "$tmp_dir/fio.log" randwrite \
		--rw=randwrite --bs=4k --size="$WORKLOAD_SIZE" --iodepth=32
	detail "size=$WORKLOAD_SIZE bs=4k iodepth=32"
}

case_write_pointer_advanced() {
	local wp_after

	wp_after=$(zone_write_pointer 0)
	[ -n "$wp_after" ] || fail "could not read the final zone write pointer"
	detail "wptr_before=$wp_before wptr_after=$wp_after"
	assert_gt "$wp_after" "$wp_before" \
		"the underlying zone write pointer did not advance"
}

run_case "when 4 KiB random writes cover $WORKLOAD_SIZE, fio completes" \
	case_fio_randwrite
run_case "when random writes are translated, the underlying write pointer advances" \
	case_write_pointer_advanced
run_case "when the random writes finish, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
