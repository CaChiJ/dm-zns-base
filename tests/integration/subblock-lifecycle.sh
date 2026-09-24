#!/usr/bin/env bash
# Preserve partial updates across MemTable, SSTable and clean target restarts.
set -euo pipefail
TARGET_NAME=${TARGET_NAME:-zns-subblock-lifecycle}
ZNS_REQUIRED_ENGINE=lsm
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "integration/subblock-lifecycle"
require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed
trap teardown_target EXIT
tmp_dir=$(mktemp -d)
build_engine
load_module memtable_threshold=8
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables
io_errors_save "$tmp_dir/io-errors"

patch_range() {
	local offset=$1 bytes=$2
	make_random_file "$tmp_dir/patch"
	dd if="$tmp_dir/patch" of="$DM_DEV" bs="$bytes" count=1 seek="$offset" \
		oflag=direct,seek_bytes conv=notrunc,fsync status=none
	dd if="$tmp_dir/patch" of="$tmp_dir/expected" bs=1 count="$bytes" \
		seek="$offset" conv=notrunc status=none
}

assert_image() {
	local spec offset bytes
	# Include untouched bytes and the still-unmapped fifth block.
	dd if="$DM_DEV" of="$tmp_dir/actual" bs=4096 count=5 \
		iflag=direct status=none
	assert_files_equal "$tmp_dir/expected" "$tmp_dir/actual" \
		"lifecycle readback lost updates or changed surrounding bytes"
	for spec in 512:1536 3584:1024 7680:4096 11776:2048 15872:1024 16384:2048; do
		offset=${spec%:*}
		bytes=${spec#*:}
		dd if="$tmp_dir/expected" of="$tmp_dir/slice" bs=1 skip="$offset" \
			count="$bytes" status=none
		dd if="$DM_DEV" of="$tmp_dir/actual" bs="$bytes" skip="$offset" \
			count=1 iflag=direct,skip_bytes status=none
		assert_files_equal "$tmp_dir/slice" "$tmp_dir/actual" \
			"partial read offset=$offset bytes=$bytes differs"
	done
}

assert_resident() {
	local active=$1 tables=$2
	assert_eq "$(status_field active)" "$active" "unexpected active mappings"
	assert_eq "$(status_field immutable)" 0 "unexpected immutable mappings"
	assert_eq "$(status_field flushing)" 0 "unexpected flushing mappings"
	assert_eq "$(status_field sstables)" "$tables" "unexpected SSTable count"
	assert_image
}

flush_generation() {
	local first=$1 tables=$2 lba deadline
	# Four data mappings plus four distinct filler mappings reach threshold 8.
	# Keep block 4 untouched so mapped-to-hole reads remain covered.
	for ((lba=first; lba<first+4; lba++)); do
		write_block "$tmp_dir/seed" "$lba"
	done
	deadline=$((SECONDS + 30))
	while [ "$(status_field sstables)" -lt "$tables" ] ||
	      [ "$(status_field active)" -ne 0 ] ||
	      [ "$(status_field immutable)" -ne 0 ] ||
	      [ "$(status_field flushing)" -ne 0 ]; do
		[ "$SECONDS" -lt "$deadline" ] || fail "SSTable flush timed out"
		sleep 0.2
	done
	assert_resident 0 "$tables"
}

# This is one dependent scenario: stop at a failed checkpoint rather than
# running later phases against an unverified state. Lifecycle changes stay
# in the parent shell so EXIT cleanup retains accurate target ownership.
checkpoint() {
	run_case "$@"
	[ "$ZNS_FAILED" -eq 0 ] || { report_summary; exit 1; }
}

make_random_file "$tmp_dir/seed" 3
make_zero_file "$tmp_dir/expected" 5
dd if="$tmp_dir/seed" of="$tmp_dir/expected" bs=4096 count=3 conv=notrunc status=none
dd if="$tmp_dir/seed" of="$DM_DEV" bs=4096 count=3 oflag=direct conv=notrunc status=none
patch_range 512 1024
patch_range 7680 2048
patch_range 11776 2048
checkpoint "when resident mappings receive partial updates, all bytes match" assert_resident 4 0
checkpoint "when partial updates flush, SSTable-only reads preserve them" flush_generation 8 1

# Each original mapping now comes from the first SSTable. Overlapping patches
# must preserve bytes from the previous generation as well as original data.
patch_range 1024 1536
patch_range 3584 1024
patch_range 7680 4096
patch_range 12800 512
checkpoint "when SSTable data is partially overwritten, resident mappings win" assert_resident 4 1
checkpoint "when a second generation flushes, newer SSTable mappings win" flush_generation 12 2

recreate_dm_target
checkpoint "when the target restarts, latest SSTable updates survive" assert_resident 0 2
patch_range 3584 1024
checkpoint "when recovered data is partially overwritten, surrounding bytes survive" assert_resident 2 2
# Leave these two mappings resident: normal destruction must flush them.
recreate_dm_target
checkpoint "when resident updates undergo a clean restart, shutdown flush preserves them" assert_resident 0 3
detach_dm_target
checkpoint "when the lifecycle finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"
report_summary
