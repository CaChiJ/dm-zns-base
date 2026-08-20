#!/usr/bin/env bash
# Reads must stay correct across MemTable freeze and repeated synchronous
# compaction. A tiny threshold makes every generation transition happen
# within a handful of 4 KiB writes.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-memtable-compaction}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-2}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/memtable-compaction"

require_root
require_commands make dmsetup blkzone blockdev dd cmp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

for name in a b c d e f; do
	make_random_file "$tmp_dir/$name.bin"
done
make_zero_file "$tmp_dir/zero.bin"

case_threshold_parameter() {
	local parameter_path=/sys/module/dm_zns_base/parameters/memtable_threshold

	[ -r "$parameter_path" ] ||
		fail "the memtable_threshold parameter is not exposed"
	assert_eq "$(cat "$parameter_path")" "$TEST_THRESHOLD" \
		"memtable_threshold was not applied"
	detail "threshold=$TEST_THRESHOLD"
}

# Two mappings fill the active MemTable, so the first one is only reachable
# through the frozen immutable generation.
case_read_from_immutable() {
	write_block "$tmp_dir/a.bin" 10
	write_block "$tmp_dir/b.bin" 20
	assert_block "$tmp_dir/a.bin" 10
}

case_read_from_new_active() {
	write_block "$tmp_dir/c.bin" 30
	assert_block "$tmp_dir/c.bin" 30
}

case_active_beats_immutable() {
	write_block "$tmp_dir/d.bin" 10
	assert_block "$tmp_dir/d.bin" 10
}

case_survives_first_compaction() {
	assert_block "$tmp_dir/b.bin" 20
	assert_block "$tmp_dir/c.bin" 30
}

case_survives_repeated_compaction() {
	write_block "$tmp_dir/e.bin" 40
	assert_block "$tmp_dir/e.bin" 40
	write_block "$tmp_dir/f.bin" 50
	assert_block "$tmp_dir/d.bin" 10
	assert_block "$tmp_dir/e.bin" 40
	assert_block "$tmp_dir/f.bin" 50
}

case_unmapped_reads_zero() {
	assert_block "$tmp_dir/zero.bin" 60
}

run_case "when the module is loaded with a threshold, the parameter is exposed" \
	case_threshold_parameter
run_case "when the active MemTable freezes, a mapping only in immutable is still read" \
	case_read_from_immutable
run_case "when a new active MemTable takes over, its own mapping is read" \
	case_read_from_new_active
run_case "when an immutable key is overwritten in active, the read returns the newer value" \
	case_active_beats_immutable
run_case "when the first compaction completes, mappings from both generations survive" \
	case_survives_first_compaction
run_case "when compaction repeats, every mapping written so far is still read" \
	case_survives_repeated_compaction
run_case "when a logical block was never written, the read zero-fills" \
	case_unmapped_reads_zero
run_case "when every generation has been exercised, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
