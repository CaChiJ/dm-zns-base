#!/usr/bin/env bash
# The immutable MemTable must reach an on-disk SSTable, be freed from memory,
# and still be served correctly by the read path.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-sstable-flush}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-64}
NR_BLOCKS=${NR_BLOCKS:-512}
FLUSH_TIMEOUT=${FLUSH_TIMEOUT:-30}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/sstable-flush"

require_root
require_commands make dmsetup blkzone blockdev dd cmp awk
require_host_managed
require_zones 2

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables sst_entries meta_used
io_errors_save "$tmp_dir/io-errors"

# The engine reserves the last zone of the underlying device for SSTables.
meta_wp_before=$(meta_zone_write_pointer) ||
	die "failed to read the metadata zone write pointer"

make_random_file "$tmp_dir/source.bin" "$NR_BLOCKS"

mappings_in_memory() {
	echo $(( $(status_field active) + $(status_field immutable) +
		 $(status_field flushing) ))
}

case_write_and_drain() {
	local deadline

	dd if="$tmp_dir/source.bin" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		count="$NR_BLOCKS" oflag=direct conv=notrunc status=none ||
		fail "failed to write $NR_BLOCKS logical blocks"

	deadline=$((SECONDS + FLUSH_TIMEOUT))
	while [ "$(status_field flushing)" -ne 0 ] ||
	      [ "$(status_field immutable)" -ne 0 ]; do
		[ "$SECONDS" -lt "$deadline" ] ||
			fail "flush did not converge within ${FLUSH_TIMEOUT}s: $(dmsetup status "$TARGET_NAME")"
		sleep 0.2
	done
	detail "blocks=$NR_BLOCKS threshold=$TEST_THRESHOLD"
}

case_sstable_on_disk() {
	local sstables

	sstables=$(status_field sstables)
	detail "sstables=$sstables"
	assert_ge "$sstables" 1 "no SSTable was flushed to disk"
}

case_most_mappings_on_disk() {
	local sst_entries

	sst_entries=$(status_field sst_entries)
	detail "sst_entries=$sst_entries total_blocks=$NR_BLOCKS"
	assert_ge "$sst_entries" $((NR_BLOCKS * 3 / 4)) \
		"too few mappings reached disk"
}

# Without this the suite would pass even if every mapping stayed in RAM.
case_memory_released() {
	local in_memory

	in_memory=$(mappings_in_memory)
	detail "in_memory=$in_memory"
	assert_lt "$in_memory" "$NR_BLOCKS" \
		"all mappings are still resident in memory"
}

case_full_readback() {
	dd if="$DM_DEV" of="$tmp_dir/readback.bin" bs="$ZNS_BLOCK_BYTES" \
		count="$NR_BLOCKS" iflag=direct status=none ||
		fail "failed to read $NR_BLOCKS logical blocks back"
	assert_files_equal "$tmp_dir/source.bin" "$tmp_dir/readback.bin" \
		"the readback differs from what was written"
}

case_oldest_sstable_blocks() {
	local logical_block

	for logical_block in 0 5 63; do
		dd if="$tmp_dir/source.bin" of="$tmp_dir/expect.bin" \
			bs="$ZNS_BLOCK_BYTES" skip="$logical_block" count=1 \
			status=none
		assert_block "$tmp_dir/expect.bin" "$logical_block"
	done
}

case_active_beats_sstable() {
	make_pattern_file "$tmp_dir/newest.bin" Z
	write_block "$tmp_dir/newest.bin" 0
	assert_block "$tmp_dir/newest.bin" 0
}

case_unmapped_reads_zero() {
	make_zero_file "$tmp_dir/zero.bin"
	assert_block "$tmp_dir/zero.bin" $((NR_BLOCKS + 4096))
}

case_metadata_zone_advanced() {
	local meta_wp_after

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "failed to re-read the metadata zone write pointer"
	detail "meta_wptr_before=$meta_wp_before meta_wptr_after=$meta_wp_after"
	assert_gt "$meta_wp_after" "$meta_wp_before" \
		"the reserved metadata zone write pointer did not advance"
}

run_case "when $NR_BLOCKS blocks are written, the flush workqueue drains" \
	case_write_and_drain
run_case "when the flush drains, at least one SSTable is on disk" \
	case_sstable_on_disk
run_case "when the flush drains, most mappings have reached disk" \
	case_most_mappings_on_disk
run_case "when mappings are flushed, they are released from memory" \
	case_memory_released
run_case "when every block is read back, the data matches what was written" \
	case_full_readback
run_case "when a block lives only in the oldest SSTable, its read is not stale" \
	case_oldest_sstable_blocks
run_case "when a flushed block is overwritten, the active MemTable wins" \
	case_active_beats_sstable
run_case "when a logical block was never written, the read zero-fills" \
	case_unmapped_reads_zero
run_case "when SSTables are flushed, the reserved metadata zone advances" \
	case_metadata_zone_advanced
run_case "when the flush workload finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
