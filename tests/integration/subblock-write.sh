#!/usr/bin/env bash
# Check RMW data preservation, holes, crossing ranges and same-block writers.
set -euo pipefail
TARGET_NAME=${TARGET_NAME:-zns-subblock-write}
ZNS_REQUIRED_ENGINE=lsm
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/subblock-write"
require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
trap teardown_target EXIT
tmp_dir=$(mktemp -d)
build_engine
load_module memtable_threshold=64
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

write_bytes() {
	local input=$1 offset=$2 bytes=$3
	dd if="$input" of="$DM_DEV" bs="$bytes" count=1 seek="$offset" \
		oflag=direct,seek_bytes conv=notrunc,fsync status=none
}

assert_image() {
	local lba=${1:-0} blocks=${2:-3}
	dd if="$DM_DEV" of="$tmp_dir/actual" bs=4096 skip="$lba" \
		count="$blocks" iflag=direct status=none
	assert_files_equal "$tmp_dir/expected" "$tmp_dir/actual" \
		"RMW changed bytes outside the requested range or lost written data"
}

case_patch() {
	local offset=$1 bytes=$2
	make_random_file "$tmp_dir/expected" 3
	dd if="$tmp_dir/expected" of="$DM_DEV" bs=4096 count=3 \
		oflag=direct conv=notrunc status=none
	make_random_file "$tmp_dir/patch"
	write_bytes "$tmp_dir/patch" "$offset" "$bytes"
	dd if="$tmp_dir/patch" of="$tmp_dir/expected" bs=1 count="$bytes" \
		seek="$offset" conv=notrunc status=none
	assert_image
}

case_hole() {
	make_zero_file "$tmp_dir/expected" 3
	make_random_file "$tmp_dir/patch"
	# Previously unwritten blocks 64..66; the patch crosses 64 -> 65.
	write_bytes "$tmp_dir/patch" "$((64 * 4096 + 3584))" 2048
	dd if="$tmp_dir/patch" of="$tmp_dir/expected" bs=1 count=2048 \
		seek=3584 conv=notrunc status=none
	assert_image 64
}

case_concurrent() {
	local i j status=0 pid
	local -a pids=()
	make_zero_file "$tmp_dir/expected"
	write_block "$tmp_dir/expected" 0
	# Eight independent writers update disjoint sectors of the SAME block.
	# Every sector has its own stable random payload, so final order is irrelevant.
	for i in {0..7}; do
		make_random_file "$tmp_dir/sector-$i"
		dd if="$tmp_dir/sector-$i" of="$tmp_dir/expected" bs=512 count=1 \
			seek="$i" conv=notrunc status=none
		(
			for j in {1..8}; do
				write_bytes "$tmp_dir/sector-$i" "$((i * 512))" 512
			done
		) &
		pids+=("$!")
	done
	# Always reap every writer, even if one failed, before suite teardown.
	for pid in "${pids[@]}"; do
		wait "$pid" || status=1
	done
	[ "$status" -eq 0 ] || fail "a concurrent partial writer failed"
	assert_image 0 1
}

case_mixed() {
	make_random_file "$tmp_dir/expected"
	write_block "$tmp_dir/expected" 0
	make_random_file "$tmp_dir/patch"
	write_bytes "$tmp_dir/patch" 512 1024
	# A subsequent full-block write must replace all previous partial data.
	write_block "$tmp_dir/expected" 0
	assert_image 0 1
	write_bytes "$tmp_dir/patch" 2048 512
	dd if="$tmp_dir/patch" of="$tmp_dir/expected" bs=1 count=512 seek=2048 \
		conv=notrunc status=none
	assert_image 0 1
}

for spec in 0:512 512:512 1024:1024 512:2048 512:1536 512:3072 \
    3584:1024 3584:4096; do
	run_case "when writing ${spec#*:} bytes at offset ${spec%:*}, surrounding bytes survive" \
		case_patch "${spec%:*}" "${spec#*:}"
done
run_case "when a partial write crosses unwritten blocks, other bytes stay zero" case_hole
run_case "when eight writers update different sectors of one block, all updates survive" \
	case_concurrent
run_case "when full and partial overwrites alternate, reads return the latest bytes" case_mixed
run_case "when RMW finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"
detach_dm_target
report_summary
