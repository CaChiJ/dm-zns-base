#!/usr/bin/env bash
# Physical data-zone exhaustion must fail promptly without damaging mappings
# that were successfully published before append space ran out. The logical
# target is deliberately smaller than physical data capacity: filling the
# advertised range once must not consume the reserve that future GC needs.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-data-exhaustion}
ZNS_REQUIRED_ENGINE=lsm
DATA_EXHAUSTION_SIZE_MB=${DATA_EXHAUSTION_SIZE_MB:-8}
DATA_EXHAUSTION_ZONE_MB=${DATA_EXHAUSTION_ZONE_MB:-2}
DATA_EXHAUSTION_TIMEOUT=${DATA_EXHAUSTION_TIMEOUT:-10}
TEST_THRESHOLD=${TEST_THRESHOLD:-4096}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/data-exhaustion"

require_root
require_commands make modprobe dmsetup blkzone blockdev dd cmp cp awk timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

create_nullblk_fixture "$DATA_EXHAUSTION_SIZE_MB" "$DATA_EXHAUSTION_ZONE_MB"
build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones

data_sectors=$(data_zone_capacity_sectors) ||
	die "could not calculate physical data-zone capacity"
reserve_sectors=$(zone_capacity 0)
[ -n "$reserve_sectors" ] || die "could not read the reserve-zone capacity"
reserve_sectors=$(printf '%u' "$reserve_sectors") ||
	die "invalid reserve-zone capacity: $reserve_sectors"
[ "$data_sectors" -gt "$reserve_sectors" ] ||
	die "fixture has no room for a logical target plus one reserve zone"
logical_sectors=$((data_sectors - reserve_sectors))
[ $((data_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "data-zone capacity is not 4 KiB aligned: $data_sectors sectors"
[ $((logical_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "logical capacity is not 4 KiB aligned: $logical_sectors sectors"
[ $((reserve_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "reserve capacity is not 4 KiB aligned: $reserve_sectors sectors"
logical_blocks=$((logical_sectors / BLOCK_SECTORS))
reserve_blocks=$((reserve_sectors / BLOCK_SECTORS))

create_dm_target "$logical_sectors"
require_status_fields active immutable flushing sstables sst_entries meta_used \
	logical_sectors physical_sectors

make_random_file "$tmp_dir/initial.bin" "$logical_blocks"
make_random_file "$tmp_dir/overwrite.bin" "$reserve_blocks"
cp "$tmp_dir/initial.bin" "$tmp_dir/expected.bin"
dd if="$tmp_dir/overwrite.bin" of="$tmp_dir/expected.bin" \
	bs="$ZNS_BLOCK_BYTES" count="$reserve_blocks" conv=notrunc status=none
make_pattern_file "$tmp_dir/extra.bin" X
io_errors_save "$tmp_dir/io-errors-before-fill"

case_advertised_capacity() {
	local advertised

	advertised=$(blockdev --getsz "$DM_DEV") ||
		fail "failed to read the DM target size"
	assert_eq "$advertised" "$logical_sectors" \
		"the DM target did not expose the configured logical capacity"
	assert_eq "$((advertised + reserve_sectors))" "$data_sectors" \
		"the logical target does not leave exactly one physical data zone reserved"
	assert_eq "$(status_field logical_sectors)" "$logical_sectors" \
		"status reports a different logical size"
	assert_eq "$(status_field physical_sectors)" \
		"$(blockdev --getsz "$UNDERLYING")" \
		"status confuses target length with lower-device size"
	detail "logical=$advertised physical_data=$data_sectors reserve=$reserve_sectors"
}

case_fill_data_zones() {
	# First fill only the advertised range. Then consume the reserve with
	# overwrites, which is the correct way to reach physical exhaustion when
	# logical and physical capacity are intentionally different.
	timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$tmp_dir/initial.bin" of="$DM_DEV" \
		bs="$ZNS_BLOCK_BYTES" \
		count="$logical_blocks" oflag=direct status=none ||
		fail "failed while filling the advertised logical range"
	timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$tmp_dir/overwrite.bin" of="$DM_DEV" \
		bs="$ZNS_BLOCK_BYTES" count="$reserve_blocks" \
		oflag=direct conv=notrunc status=none ||
		fail "failed while consuming the physical reserve with valid overwrites"
	timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$DM_DEV" \
		of="$tmp_dir/all-data.actual" bs="$ZNS_BLOCK_BYTES" \
		count="$logical_blocks" iflag=direct status=none ||
		fail "failed to read the filled data range"
	assert_files_equal "$tmp_dir/expected.bin" "$tmp_dir/all-data.actual" \
		"data changed while the writable zones were filled"
	blkzone report "$UNDERLYING" >"$tmp_dir/zones-before-enospc"
	touch "$tmp_dir/data-full.ready"
	detail "initial=$logical_blocks overwrites=$reserve_blocks physical_blocks=$((data_sectors / BLOCK_SECTORS))"
}

case_next_write_fails() {
	local status

	[ -f "$tmp_dir/data-full.ready" ] ||
		fail "the data-zone fill prerequisite did not complete"
	if timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$tmp_dir/extra.bin" of="$DM_DEV" \
		bs="$ZNS_BLOCK_BYTES" seek="$reserve_blocks" count=1 \
		oflag=direct conv=notrunc status=none 2>"$tmp_dir/enospc.log"; then
		fail "an in-range overwrite after physical exhaustion unexpectedly succeeded"
	else
		status=$?
	fi
	[ "$status" -ne 124 ] || fail "the write hung instead of reporting no space"
	detail "exit=$status timeout=${DATA_EXHAUSTION_TIMEOUT}s"
}

case_failed_write_preserves_state() {
	[ -f "$tmp_dir/data-full.ready" ] ||
		fail "the data-zone fill prerequisite did not complete"
	blkzone report "$UNDERLYING" >"$tmp_dir/zones-after-enospc"
	assert_files_equal "$tmp_dir/zones-before-enospc" \
		"$tmp_dir/zones-after-enospc" \
		"a rejected allocation changed lower-zone state"
	timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$DM_DEV" \
		of="$tmp_dir/after-enospc.actual" bs="$ZNS_BLOCK_BYTES" \
		count="$logical_blocks" iflag=direct status=none ||
		fail "existing mappings became unreadable after exhaustion"
	assert_files_equal "$tmp_dir/expected.bin" "$tmp_dir/after-enospc.actual" \
		"existing mappings changed after exhaustion"
}

case_persisted_prefix_recovers() {
	[ -f "$tmp_dir/data-full.ready" ] ||
		fail "the data-zone fill prerequisite did not complete"
	recreate_dm_target
	timeout "$DATA_EXHAUSTION_TIMEOUT" dd if="$DM_DEV" \
		of="$tmp_dir/recovered.actual" bs="$ZNS_BLOCK_BYTES" \
		count="$logical_blocks" iflag=direct status=none ||
		fail "the persisted full-device prefix could not be read after restart"
	assert_files_equal "$tmp_dir/expected.bin" "$tmp_dir/recovered.actual" \
		"the persisted prefix changed across restart"
	assert_ge "$(status_field sstables)" 1 \
		"the restart recovered no SSTable for the filled data zones"
}

run_case "when the target is created, logical capacity leaves one physical data zone reserved" \
	case_advertised_capacity
run_case "when fill plus overwrites consume physical capacity, every latest version reads back" \
	case_fill_data_zones
run_case "when writable data capacity is filled, no premature I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors-before-fill"
run_case "when data zones are full, an in-range overwrite fails without hanging" \
	case_next_write_fails
run_case "when allocation fails, zone state and earlier mappings remain unchanged" \
	case_failed_write_preserves_state

# The failed write is expected to produce a block-layer error. Start a fresh
# baseline so the recovery case only judges errors that happen after it.
io_errors_save "$tmp_dir/io-errors-after-enospc"
run_case "when a full target is recreated, its persisted prefix still reads back" \
	case_persisted_prefix_recovers
run_case "when recovery from data exhaustion finishes, no further I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors-after-enospc"

report_summary
