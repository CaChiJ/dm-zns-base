#!/usr/bin/env bash
# Required integration check for writes smaller than the native 4 KiB mapping
# block. The LSM engine preserves a 4 KiB mapping by rewriting the full block.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-subblock-write}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/subblock-write"

require_root
require_commands make fio dmsetup blkzone blockdev dd cmp cp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target

case_subblock_write() {
	local bs=$1
	local size=${2:-64M}
	local log="$tmp_dir/subblock-$bs.log"

	io_errors_save "$tmp_dir/io-errors-$bs"
	run_fio "$log" "subblock-$bs" \
		--rw=randwrite --bs="$bs" --size="$size" --iodepth=8 \
		--verify=crc32c --verify_fatal=1 --verify_state_save=0
	assert_no_new_io_errors "$tmp_dir/io-errors-$bs"
	detail "size=$size bs=$bs iodepth=8"
}

case_partial_overwrite_preserves_neighbors() {
	local lba=128
	local baseline="$tmp_dir/io-errors-partial"

	make_pattern_file "$tmp_dir/full-a.bin" A
	head -c 1024 /dev/zero | tr '\0' B >"$tmp_dir/partial-b.bin"
	cp "$tmp_dir/full-a.bin" "$tmp_dir/partial-expected.bin"
	dd if="$tmp_dir/partial-b.bin" of="$tmp_dir/partial-expected.bin" \
		bs=512 seek=2 count=2 conv=notrunc status=none

	write_block "$tmp_dir/full-a.bin" "$lba"
	io_errors_save "$baseline"
	dd if="$tmp_dir/partial-b.bin" of="$DM_DEV" bs=512 \
		seek=$((lba * 8 + 2)) count=2 oflag=direct conv=notrunc status=none ||
		fail "failed to overwrite the middle 1 KiB of logical block $lba"
	assert_block "$tmp_dir/partial-expected.bin" "$lba"
	dd if="$DM_DEV" of="$tmp_dir/partial-read.bin" bs=512 \
		skip=$((lba * 8 + 2)) count=2 iflag=direct status=none ||
		fail "failed to read the middle 1 KiB back"
	assert_files_equal "$tmp_dir/partial-b.bin" "$tmp_dir/partial-read.bin" \
		"the partial read returned the wrong byte range"
	assert_no_new_io_errors "$baseline"
	detail "offset=1KiB length=1KiB"
}

case_unmapped_partial_write_zero_fills_neighbors() {
	local lba=384
	local baseline="$tmp_dir/io-errors-unmapped"

	make_zero_file "$tmp_dir/unmapped-expected.bin"
	head -c 512 /dev/zero | tr '\0' E >"$tmp_dir/unmapped-sector.bin"
	dd if="$tmp_dir/unmapped-sector.bin" of="$tmp_dir/unmapped-expected.bin" \
		bs=512 seek=5 count=1 conv=notrunc status=none

	io_errors_save "$baseline"
	dd if="$tmp_dir/unmapped-sector.bin" of="$DM_DEV" bs=512 \
		seek=$((lba * 8 + 5)) count=1 oflag=direct conv=notrunc status=none ||
		fail "failed to write one sector into an unmapped logical block"
	assert_block "$tmp_dir/unmapped-expected.bin" "$lba"
	assert_no_new_io_errors "$baseline"
	detail "offset=2.5KiB length=512B zero_neighbors=3584B"
}

case_cross_block_write_preserves_both_blocks() {
	local lba=256
	local baseline="$tmp_dir/io-errors-cross-block"

	head -c $((2 * ZNS_BLOCK_BYTES)) /dev/zero | tr '\0' C \
		>"$tmp_dir/cross-base.bin"
	head -c 1024 /dev/zero | tr '\0' D >"$tmp_dir/cross-update.bin"
	cp "$tmp_dir/cross-base.bin" "$tmp_dir/cross-expected.bin"
	dd if="$tmp_dir/cross-update.bin" of="$tmp_dir/cross-expected.bin" \
		bs=512 seek=7 count=2 conv=notrunc status=none

	dd if="$tmp_dir/cross-base.bin" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		seek="$lba" count=2 oflag=direct conv=notrunc status=none ||
		fail "failed to prepare two adjacent logical blocks"
	io_errors_save "$baseline"
	dd if="$tmp_dir/cross-update.bin" of="$DM_DEV" bs=512 \
		seek=$((lba * 8 + 7)) count=2 oflag=direct conv=notrunc status=none ||
		fail "failed to write 1 KiB across a 4 KiB boundary"
	dd if="$DM_DEV" of="$tmp_dir/cross-actual.bin" bs="$ZNS_BLOCK_BYTES" \
		skip="$lba" count=2 iflag=direct status=none ||
		fail "failed to read the two updated blocks"
	assert_files_equal "$tmp_dir/cross-expected.bin" "$tmp_dir/cross-actual.bin" \
		"a cross-block partial write damaged neighboring bytes"
	assert_no_new_io_errors "$baseline"
	detail "offset=3.5KiB length=1KiB"
}

run_case "when requests are 512 B, randwrites complete and verify" \
	case_subblock_write 512 16M
run_case "when requests are 1 KiB, randwrites complete and verify" \
	case_subblock_write 1k
run_case "when requests are 2 KiB, randwrites complete and verify" \
	case_subblock_write 2k
run_case "when requests are 1536 B, randwrites complete and verify" \
	case_subblock_write 1536 8M
run_case "when requests are 2560 B, randwrites complete and verify" \
	case_subblock_write 2560 8M
run_case "when requests are 3584 B, randwrites complete and verify" \
	case_subblock_write 3584 8M
run_case "when the middle 1 KiB is overwritten, both neighboring ranges are preserved" \
	case_partial_overwrite_preserves_neighbors
run_case "when one sector is written to an unmapped block, every neighbor remains zero" \
	case_unmapped_partial_write_zero_fills_neighbors
run_case "when 1 KiB crosses a 4 KiB boundary, both logical blocks remain intact" \
	case_cross_block_write_preserves_both_blocks

report_summary
