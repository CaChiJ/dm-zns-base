#!/usr/bin/env bash
# Mappings must survive a restart. The engine has to persist whatever is still
# resident when the target goes away, and find it again when a new target opens
# the same media, without any zone being reset in between.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-recovery}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-64}
NR_BLOCKS=${NR_BLOCKS:-512}
FLUSH_TIMEOUT=${FLUSH_TIMEOUT:-30}

# Disjoint logical ranges, so no phase overwrites the blocks another one is
# still asserting on.
SMALL_LBA=${SMALL_LBA:-0}		# fewer blocks than the freeze threshold
SMALL_BLOCKS=16
BULK_LBA=${BULK_LBA:-1024}		# large enough to reach an SSTable
REWRITE_LBA=${REWRITE_LBA:-2048}
LATE_LBA=${LATE_LBA:-3072}
FILLER_LBA=${FILLER_LBA:-4096}		# only there to force a freeze
UNWRITTEN_LBA=${UNWRITTEN_LBA:-8192}

# One 4 KiB block, in 512-byte sectors.
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/recovery"

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

meta_start=$(meta_zone_start) ||
	die "failed to read the metadata zone start of $UNDERLYING"
meta_wp_fresh=$(meta_zone_write_pointer) ||
	die "failed to read the metadata zone write pointer of $UNDERLYING"

# Setup helpers abort the suite, because a restart that does not happen means
# the suite never ran. Assertions inside cases use fail instead.
wait_for_flush() {
	local deadline=$((SECONDS + FLUSH_TIMEOUT))

	while [ "$(status_field flushing)" -ne 0 ] ||
	      [ "$(status_field immutable)" -ne 0 ]; do
		[ "$SECONDS" -lt "$deadline" ] ||
			die "flush did not converge within ${FLUSH_TIMEOUT}s: $(dmsetup status "$TARGET_NAME")"
		sleep 0.2
	done
}

write_range() {
	local input=$1 lba=$2 blocks=$3

	dd if="$input" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" seek="$lba" \
		count="$blocks" oflag=direct conv=notrunc status=none ||
		die "failed to write $blocks block(s) at logical block $lba"
}

assert_range() {
	local expected=$1 lba=$2 blocks=$3
	local actual="$tmp_dir/readback-$lba.bin"

	dd if="$DM_DEV" of="$actual" bs="$ZNS_BLOCK_BYTES" skip="$lba" \
		count="$blocks" iflag=direct status=none ||
		fail "failed to read $blocks block(s) at logical block $lba"
	assert_files_equal "$expected" "$actual" \
		"logical blocks $lba..$((lba + blocks - 1)) differ from what was written"
}

# --- a freshly formatted device must carry a superblock ---------------------

case_superblock_written() {
	detail "meta start=$meta_start wptr=$meta_wp_fresh"
	assert_eq "$meta_wp_fresh" "$((meta_start + BLOCK_SECTORS))" \
		"the metadata zone holds no superblock after formatting"
}

run_case "when the metadata zone is formatted, a superblock is written to it" \
	case_superblock_written

# --- mappings that never left the MemTable ----------------------------------

make_random_file "$tmp_dir/small.bin" "$SMALL_BLOCKS"
write_range "$tmp_dir/small.bin" "$SMALL_LBA" "$SMALL_BLOCKS"
small_active=$(status_field active)
small_sstables=$(status_field sstables)
recreate_dm_target

case_memtable_only_survives() {
	detail "blocks=$SMALL_BLOCKS active=$small_active sstables=$small_sstables"
	# Guard the fixture: the point of this case is the shutdown flush, so
	# nothing may have reached disk on its own.
	assert_eq "$small_sstables" 0 \
		"the fixture flushed on its own, so this case proves nothing"
	assert_eq "$small_active" "$SMALL_BLOCKS" \
		"the mappings were not all resident before the restart"
	assert_range "$tmp_dir/small.bin" "$SMALL_LBA" "$SMALL_BLOCKS"
}

run_case "when mappings only ever reached the MemTable, a restart still reads them back" \
	case_memtable_only_survives

# --- mappings that reached an SSTable ---------------------------------------

make_random_file "$tmp_dir/bulk.bin" "$NR_BLOCKS"
write_range "$tmp_dir/bulk.bin" "$BULK_LBA" "$NR_BLOCKS"
wait_for_flush
sstables_before=$(status_field sstables)
recreate_dm_target
sstables_after=$(status_field sstables)

case_sstables_survive() {
	detail "blocks=$NR_BLOCKS"
	assert_range "$tmp_dir/bulk.bin" "$BULK_LBA" "$NR_BLOCKS"
}

case_sstables_recovered() {
	detail "sstables $sstables_before -> $sstables_after"
	assert_ge "$sstables_after" 1 \
		"no SSTable was picked up from the metadata zone"
}

case_unmapped_reads_zero() {
	make_zero_file "$tmp_dir/zero.bin"
	assert_block "$tmp_dir/zero.bin" "$UNWRITTEN_LBA"
}

run_case "when mappings reached an SSTable, a restart reads every block back" \
	case_sstables_survive
run_case "when the target is recreated, the SSTables on disk are picked up" \
	case_sstables_recovered
run_case "when a logical block was never written, a read after the restart zero-fills" \
	case_unmapped_reads_zero

# --- the newer of two generations must still win across a restart -----------
#
# A is pushed down to an SSTable by the filler writes, B then lands in a fresh
# active MemTable. Only a shutdown flush that appends in age order, and a scan
# that keeps that order, can return B here.

make_pattern_file "$tmp_dir/pat-a" A
make_pattern_file "$tmp_dir/pat-b" B
make_random_file "$tmp_dir/filler.bin" $((TEST_THRESHOLD * 2))

write_range "$tmp_dir/pat-a" "$REWRITE_LBA" 1
write_range "$tmp_dir/filler.bin" "$FILLER_LBA" $((TEST_THRESHOLD * 2))
wait_for_flush
write_range "$tmp_dir/pat-b" "$REWRITE_LBA" 1
recreate_dm_target

case_newer_generation_wins() {
	assert_block "$tmp_dir/pat-b" "$REWRITE_LBA"
}

case_no_stale_generation() {
	assert_block_differs "$tmp_dir/pat-a" "$REWRITE_LBA"
}

run_case "when a flushed block is rewritten before the restart, the newer value is read" \
	case_newer_generation_wins
run_case "when a flushed block is rewritten before the restart, the older value is gone" \
	case_no_stale_generation

# --- a full module reload, not just a new target ----------------------------

remove_dm_target
ZNS_TARGET_CREATED=0
load_module memtable_threshold="$TEST_THRESHOLD"
create_dm_target

case_survives_module_reload() {
	assert_range "$tmp_dir/small.bin" "$SMALL_LBA" "$SMALL_BLOCKS"
	assert_range "$tmp_dir/bulk.bin" "$BULK_LBA" "$NR_BLOCKS"
	assert_block "$tmp_dir/pat-b" "$REWRITE_LBA"
}

run_case "when the module itself is reloaded, the mappings still come back" \
	case_survives_module_reload

# --- writes made after a restart must survive the next one ------------------

make_pattern_file "$tmp_dir/pat-c" C
write_range "$tmp_dir/pat-c" "$LATE_LBA" 1
recreate_dm_target

case_second_cycle() {
	assert_block "$tmp_dir/pat-c" "$LATE_LBA"
	# The second cycle must append behind the recovered SSTables rather
	# than write over them.
	assert_range "$tmp_dir/bulk.bin" "$BULK_LBA" "$NR_BLOCKS"
}

run_case "when writes continue after a restart, a second restart returns them too" \
	case_second_cycle

# --- the superblock has to guard the geometry it was written with -----------
#
# The live target goes first, so that a refusal can only come from the
# superblock and not from the device already being claimed.

remove_dm_target
ZNS_TARGET_CREATED=0

case_length_mismatch_refused() {
	local name="${TARGET_NAME}-short"
	local sectors half

	sectors=$(blockdev --getsz "$UNDERLYING") ||
		fail "failed to read the sector count of $UNDERLYING"
	half=$(( (sectors / 2 / BLOCK_SECTORS) * BLOCK_SECTORS ))

	if try_create_dm_target "$name" "$half"; then
		dmsetup remove "$name" 2>/dev/null || true
		fail "a $half sector target was accepted on media formatted for $sectors sectors"
	fi
	detail "refused len=$half formatted=$sectors"
	return 0
}

run_case "when the table length disagrees with the superblock, the target is refused" \
	case_length_mismatch_refused

run_case "when the restart workload finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
