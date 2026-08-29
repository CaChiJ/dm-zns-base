#!/usr/bin/env bash
# Fill the reserved metadata zone exactly with valid SSTables, then verify that
# the next flush fails in a bounded and readable state.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-metadata-exhaustion}
ZNS_REQUIRED_ENGINE=lsm
METADATA_EXHAUSTION_SIZE_MB=${METADATA_EXHAUSTION_SIZE_MB:-96}
METADATA_EXHAUSTION_ZONE_MB=${METADATA_EXHAUSTION_ZONE_MB:-1}
METADATA_EXHAUSTION_TIMEOUT=${METADATA_EXHAUSTION_TIMEOUT:-30}
TEST_THRESHOLD=${TEST_THRESHOLD:-257}
BLOCK_SECTORS=8
ENTRIES_PER_PAYLOAD_BLOCK=256

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/metadata-exhaustion"

require_root
require_commands make modprobe dmsetup blkzone blockdev dd cmp awk timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

create_nullblk_fixture "$METADATA_EXHAUSTION_SIZE_MB" "$METADATA_EXHAUSTION_ZONE_MB"
build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables sst_entries meta_used

meta_start=$(meta_zone_start) || die "failed to read the metadata-zone start"
meta_capacity_sectors=$(zone_capacity "$meta_start")
[ -n "$meta_capacity_sectors" ] || die "failed to read metadata capacity"
meta_capacity_sectors=$(printf '%u' "$meta_capacity_sectors") ||
	die "invalid metadata capacity: $meta_capacity_sectors"
[ $((meta_capacity_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "metadata capacity is not 4 KiB aligned"
meta_capacity_blocks=$((meta_capacity_sectors / BLOCK_SECTORS))
sst_blocks=$((1 + (TEST_THRESHOLD + ENTRIES_PER_PAYLOAD_BLOCK - 1) / ENTRIES_PER_PAYLOAD_BLOCK))
available_sst_blocks=$((meta_capacity_blocks - 1)) # one block is the superblock
[ "$available_sst_blocks" -gt 0 ] || die "metadata zone only fits its superblock"
[ $((available_sst_blocks % sst_blocks)) -eq 0 ] ||
	die "fixture cannot fill metadata exactly: $available_sst_blocks blocks remain in groups of $sst_blocks"
nr_flushes=$((available_sst_blocks / sst_blocks))

nr_zones=$(underlying_attr nr_zones)
zone_sectors=$(underlying_attr chunk_sectors)
data_capacity_sectors=0
for ((zone_id = 0; zone_id + 1 < nr_zones; zone_id++)); do
	capacity=$(zone_capacity $((zone_id * zone_sectors)))
	[ -n "$capacity" ] || die "failed to read capacity for data zone $zone_id"
	capacity=$(printf '%u' "$capacity") ||
		die "invalid capacity for data zone $zone_id: $capacity"
	data_capacity_sectors=$((data_capacity_sectors + capacity))
done
[ $((data_capacity_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "data capacity is not 4 KiB aligned"
data_capacity_blocks=$((data_capacity_sectors / BLOCK_SECTORS))
required_data_blocks=$(((nr_flushes + 1) * TEST_THRESHOLD))
[ "$data_capacity_blocks" -ge "$required_data_blocks" ] ||
	die "fixture has $data_capacity_blocks data blocks but the workload needs $required_data_blocks"

head -c $((TEST_THRESHOLD * ZNS_BLOCK_BYTES)) /dev/zero | tr '\0' P \
	>"$tmp_dir/persisted.bin"
head -c $((TEST_THRESHOLD * ZNS_BLOCK_BYTES)) /dev/zero | tr '\0' Z \
	>"$tmp_dir/resident.bin"
make_pattern_file "$tmp_dir/persisted-block.bin" P
make_pattern_file "$tmp_dir/resident-block.bin" Z
io_errors_save "$tmp_dir/io-errors-before-full"

wait_for_flush_idle() {
	local deadline=$((SECONDS + METADATA_EXHAUSTION_TIMEOUT))
	local immutable flushing

	while :; do
		immutable=$(status_field immutable)
		flushing=$(status_field flushing)
		[ "$immutable" -eq 0 ] && [ "$flushing" -eq 0 ] && return 0
		[ "$SECONDS" -lt "$deadline" ] ||
			fail "flush did not become idle: $(dmsetup status "$TARGET_NAME")"
		sleep 0.1
	done
}

wait_for_failed_flush() {
	local deadline=$((SECONDS + METADATA_EXHAUSTION_TIMEOUT))
	local flushing

	while :; do
		flushing=$(status_field flushing)
		[ "$flushing" -gt 0 ] && return 0
		[ "$SECONDS" -lt "$deadline" ] ||
			fail "no failed flush became observable: $(dmsetup status "$TARGET_NAME")"
		sleep 0.1
	done
}

case_fill_metadata_exactly() {
	local generation

	for ((generation = 1; generation <= nr_flushes; generation++)); do
		timeout "$METADATA_EXHAUSTION_TIMEOUT" dd if="$tmp_dir/persisted.bin" \
			of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
			count="$TEST_THRESHOLD" oflag=direct conv=notrunc status=none ||
			fail "data write failed while preparing metadata generation $generation"
		wait_for_flush_idle
	done

	assert_eq "$(status_field sstables)" "$nr_flushes" \
		"the expected number of SSTables was not published"
	assert_eq "$(status_field meta_used)" "$meta_capacity_sectors" \
		"the metadata status did not reach exact capacity"
	assert_eq "$(meta_zone_write_pointer)" \
		"$((meta_start + meta_capacity_sectors))" \
		"the metadata-zone write pointer did not reach capacity"
	touch "$tmp_dir/metadata-full.ready"
	detail "sstables=$nr_flushes sst_blocks=$sst_blocks meta_blocks=$meta_capacity_blocks"
}

case_next_flush_stays_readable() {
	[ -f "$tmp_dir/metadata-full.ready" ] ||
		fail "the exact-fill prerequisite did not complete"
	timeout "$METADATA_EXHAUSTION_TIMEOUT" dd if="$tmp_dir/resident.bin" \
		of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		seek="$TEST_THRESHOLD" count="$TEST_THRESHOLD" \
		oflag=direct conv=notrunc status=none ||
		fail "data writes failed before the metadata flush was attempted"
	wait_for_failed_flush
	assert_eq "$(status_field immutable)" 0 \
		"the failed generation was not claimed by the flush worker"
	assert_eq "$(status_field flushing)" "$TEST_THRESHOLD" \
		"the failed generation is not retained in the flushing slot"
	assert_block "$tmp_dir/resident-block.bin" "$TEST_THRESHOLD"
	touch "$tmp_dir/flush-failed.ready"
	detail "flushing=$(status_field flushing) meta_used=$(status_field meta_used)"
}

case_persisted_mapping_recovers() {
	[ -f "$tmp_dir/flush-failed.ready" ] ||
		fail "the metadata ENOSPC prerequisite did not complete"
	recreate_dm_target
	assert_block "$tmp_dir/persisted-block.bin" 0
	assert_ge "$(status_field sstables)" "$nr_flushes" \
		"the full metadata log was not recovered"
	detail "recovered=$(status_field sstables)"
}

run_case "when valid SSTables exactly fill metadata, its write pointer reaches capacity" \
	case_fill_metadata_exactly
run_case "when metadata reaches capacity, no premature I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors-before-full"
run_case "when the next SSTable cannot fit, its mappings remain readable in memory" \
	case_next_flush_stays_readable
run_case "when a full metadata log is reopened, its persisted mappings are recovered" \
	case_persisted_mapping_recovers

report_summary
