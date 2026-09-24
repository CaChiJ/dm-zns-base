#!/usr/bin/env bash
# Direct reads of byte ranges from non-contiguous mapped blocks and holes.
set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-subblock-read}
ZNS_REQUIRED_ENGINE=lsm
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/subblock-read"
require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold=4
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables
io_errors_save "$tmp_dir/io-errors"

# Blocks 0 and 1 contain random bytes; block 2 is an unmapped hole. Rewrite
# block 0 after block 1 so adjacent logical blocks are not physically adjacent
# in increasing order. Wrong offsets must not pass due to a uniform pattern.
make_random_file "$tmp_dir/data" 2
make_zero_file "$tmp_dir/expected" 3
dd if="$tmp_dir/data" of="$tmp_dir/expected" bs=4096 count=2 \
    conv=notrunc status=none
dd if="$tmp_dir/data" of="$DM_DEV" bs=4096 count=2 \
    oflag=direct conv=notrunc status=none
write_block "$tmp_dir/data" 0

case_range() {
	local offset=$1 bytes=$2
	dd if="$tmp_dir/expected" of="$tmp_dir/slice" bs=1 \
		skip="$offset" count="$bytes" status=none
	# skip_bytes decouples the starting offset from the request size.
	# count=1 asks dd for one request; DM may split it at mapping boundaries.
	dd if="$DM_DEV" of="$tmp_dir/actual" bs="$bytes" skip="$offset" \
		count=1 iflag=direct,skip_bytes status=none
	assert_files_equal "$tmp_dir/slice" "$tmp_dir/actual" \
		"range offset=$offset bytes=$bytes differs"
}

run_ranges() {
	local phase=$1 spec offset bytes
	for spec in 0:512 512:512 1024:1024 512:1024 2048:2048 \
		512:2048 512:1536 512:3072 3584:1024 3584:4096 \
		7680:1024 8192:2048 4096:4096 0:8192; do
		offset=${spec%:*}
		bytes=${spec#*:}
		run_case "when $phase reads $bytes bytes at offset $offset, data matches" \
			case_range "$offset" "$bytes"
	done
}

assert_eq "$(status_field active)" 2 "expected two resident mappings"
assert_eq "$(status_field sstables)" 0 "unexpected early SSTable"
run_ranges "MemTable"

# Force the four distinct mappings into an SSTable without touching block 2.
write_block "$tmp_dir/data" 8
write_block "$tmp_dir/data" 9
deadline=$((SECONDS + 30))
while [ "$(status_field sstables)" -lt 1 ] ||
      [ "$(status_field active)" -ne 0 ] ||
      [ "$(status_field immutable)" -ne 0 ] ||
      [ "$(status_field flushing)" -ne 0 ]; do
	[ "$SECONDS" -lt "$deadline" ] || die "SSTable flush timed out"
	sleep 0.2
done
run_ranges "SSTable"

recreate_dm_target
run_ranges "recovered SSTable"
run_case "when sub-block reads finish, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

# Surface removal failures here instead of silently leaving this suite's
# target behind for the next suite. EXIT still handles module/temp cleanup.
detach_dm_target
report_summary
