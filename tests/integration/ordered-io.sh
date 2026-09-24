#!/usr/bin/env bash
# Exercise the ordered data queue with concurrent writers and explicit flushes.
# Each writer owns a disjoint logical range so CRC verification is unambiguous.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-ordered-io}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/ordered-io"

require_root
require_commands make fio dmsetup blkzone blockdev dd cmp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold=1024
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

case_unwritten_read() {
	make_zero_file "$tmp_dir/zero.bin"
	assert_block "$tmp_dir/zero.bin" 0
}

case_concurrent_writes_and_flushes() {
	run_fio "$tmp_dir/concurrent.log" ordered-io \
		--rw=randwrite --bs=4k --size=8M --offset_increment=8M \
		--numjobs=4 --iodepth=16 --fsync=32 --end_fsync=1 \
		--verify=crc32c --verify_fatal=1 --verify_state_save=0
	detail "4 disjoint writers, 4 KiB I/O, fsync every 32 writes, CRC readback"
}

case_overwrite_after_flush() {
	make_pattern_file "$tmp_dir/a.bin" A
	make_pattern_file "$tmp_dir/b.bin" B
	write_block "$tmp_dir/a.bin" 0
	dd if="$tmp_dir/b.bin" of="$DM_DEV" bs=4096 count=1 \
		oflag=direct conv=notrunc,fsync status=none
	assert_block "$tmp_dir/b.bin" 0
}

run_case "when an unwritten block is queued for reading, it returns zeros" \
	case_unwritten_read
run_case "when concurrent writers issue flushes, all ranges pass CRC readback" \
	case_concurrent_writes_and_flushes
run_case "when an overwrite is followed by fsync, direct read returns the new data" \
	case_overwrite_after_flush
run_case "when ordered I/O finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
