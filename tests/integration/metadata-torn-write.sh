#!/usr/bin/env bash
# A torn SSTable in the middle of the metadata log must never be adopted as a
# valid mapping table merely because later writes pushed the zone WP past it.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-metadata-torn-write}
ZNS_REQUIRED_ENGINE=lsm
TEST_THRESHOLD=${TEST_THRESHOLD:-2}
FLUSH_TIMEOUT=${FLUSH_TIMEOUT:-30}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/metadata-torn-write"

require_root
require_commands make dmsetup blkzone blockdev dd
require_host_managed
require_zones 2
require_nullblk_badblocks

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables sst_entries meta_used

make_pattern_file "$tmp_dir/pat-a" A
make_pattern_file "$tmp_dir/pat-b" B
make_pattern_file "$tmp_dir/pat-c" C

write_fixture_block() {
	local input=$1 logical_block=$2

	dd if="$input" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" seek="$logical_block" \
		count=1 conv=notrunc oflag=direct status=none ||
		die "failed to write fixture block $logical_block"
}

wait_for_torn_flush() {
	local expected_wp=$1
	local deadline=$((SECONDS + FLUSH_TIMEOUT))
	local wp

	while [ "$SECONDS" -lt "$deadline" ]; do
		wp=$(meta_zone_write_pointer) ||
			die "could not read the metadata write pointer"
		if [ "$(status_field flushing)" -eq "$TEST_THRESHOLD" ] &&
		   [ "$(status_field sstables)" -eq 0 ] &&
		   [ "$wp" -eq "$expected_wp" ]; then
			return 0
		fi
		sleep 0.1
	done

	die "the injected SSTable flush did not stop at $expected_wp: $(dmsetup status "$TARGET_NAME")"
}

wait_for_metadata_disable() {
	local expected_wp=$1
	local deadline=$((SECONDS + FLUSH_TIMEOUT))
	local wp

	while [ "$SECONDS" -lt "$deadline" ]; do
		wp=$(meta_zone_write_pointer) ||
			die "could not read the metadata write pointer"
		if [ "$(status_field active)" -eq 1 ] &&
		   [ "$(status_field flushing)" -eq "$TEST_THRESHOLD" ] &&
		   [ "$(status_field immutable)" -eq 0 ] &&
		   [ "$(status_field sstables)" -eq 0 ] &&
		   [ "$wp" -eq "$expected_wp" ]; then
			return 0
		fi
		sleep 0.1
	done

	die "metadata appends were not disabled at $expected_wp: $(dmsetup status "$TARGET_NAME")"
}

# First leave a header whose payload write fails.
first_header=$(meta_zone_write_pointer) ||
	die "could not read the first SSTable position"
failed_payload=$((first_header + BLOCK_SECTORS))
failed_payload_end=$((failed_payload + BLOCK_SECTORS - 1))

nullblk_badblock_add "$failed_payload" "$failed_payload_end" ||
	die "could not inject the metadata payload failure"
write_fixture_block "$tmp_dir/pat-a" 10
write_fixture_block "$tmp_dir/pat-b" 20
wait_for_torn_flush "$failed_payload"

nullblk_badblock_remove "$failed_payload" "$failed_payload_end" ||
	die "could not remove the metadata payload failure"

# A later write asks the worker to retry, but a partial metadata record must
# disable every further append in this target instance.
write_fixture_block "$tmp_dir/pat-c" 30
wait_for_metadata_disable "$failed_payload"

# Shutdown must not append either generation after the torn header.
detach_dm_target
meta_wp_before_reopen=$(meta_zone_write_pointer) ||
	die "could not read the torn-log write pointer"
[ "$meta_wp_before_reopen" -eq "$failed_payload" ] ||
	die "metadata append continued after a torn record: expected WP $failed_payload, got $meta_wp_before_reopen"

case_incomplete_sstable_is_refused() {
	local name="$TARGET_NAME"
	local sectors meta_wp_after

	sectors=$ZNS_TARGET_SECTORS_ACTIVE
	[ -n "$sectors" ] || fail "the formatted target size was not retained"
	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target still exists before incomplete-log recovery"
	fi
	if try_create_dm_target "$name" "$sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the incomplete-log target was accepted and could not be removed"
		fail "an SSTable with no payload was accepted during recovery"
	fi

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before_reopen" \
		"refusing an incomplete SSTable modified the metadata log"
	detail "incomplete_header=$first_header meta_wptr=$meta_wp_after"
}

run_case "when an SSTable payload is incomplete, recovery refuses the target" \
	case_incomplete_sstable_is_refused

# Simulate a later writer or an older implementation advancing the physical WP
# over the missing payload. Bounds now look complete, so recovery must reject
# the table by validating its payload CRC and structure.
dd if="$tmp_dir/pat-c" of="$UNDERLYING" bs=512 seek="$failed_payload" \
	count="$BLOCK_SECTORS" conv=notrunc oflag=direct status=none ||
	die "could not append a corrupt replacement payload"
meta_wp_before_reopen=$(meta_zone_write_pointer) ||
	die "could not read the corrupt-log write pointer"
expected_final_wp=$((failed_payload + BLOCK_SECTORS))
[ "$meta_wp_before_reopen" -eq "$expected_final_wp" ] ||
	die "corrupt payload did not advance metadata WP to $expected_final_wp: got $meta_wp_before_reopen"

case_corrupt_sstable_is_refused() {
	local name="$TARGET_NAME"
	local sectors meta_wp_after

	sectors=$ZNS_TARGET_SECTORS_ACTIVE
	[ -n "$sectors" ] || fail "the formatted target size was not retained"
	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target still exists before corrupt-log recovery"
	fi
	if try_create_dm_target "$name" "$sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the corrupt-log target was accepted and could not be removed"
		fail "an SSTable with a corrupt payload was accepted during recovery"
	fi

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before_reopen" \
		"a refused recovery modified the metadata log"
	detail "torn_header=$first_header meta_wptr=$meta_wp_after"
}

run_case "when a torn SSTable payload is later occupied, recovery refuses the target" \
	case_corrupt_sstable_is_refused
remove_dm_target

report_summary
