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

wait_for_retry() {
	local expected_wp=$1
	local deadline=$((SECONDS + FLUSH_TIMEOUT))
	local wp

	while [ "$SECONDS" -lt "$deadline" ]; do
		wp=$(meta_zone_write_pointer) ||
			die "could not read the metadata write pointer"
		if [ "$(status_field active)" -eq 1 ] &&
		   [ "$(status_field flushing)" -eq 0 ] &&
		   [ "$(status_field immutable)" -eq 0 ] &&
		   [ "$(status_field sstables)" -eq 1 ] &&
		   [ "$wp" -eq "$expected_wp" ]; then
			return 0
		fi
		sleep 0.1
	done

	die "the SSTable retry did not converge at $expected_wp: $(dmsetup status "$TARGET_NAME")"
}

# Build this exact append-only layout:
#
#   [super][torn header][retry header][retry payload]
#            `claims this ^ block as its own payload
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

# Any later write asks the engine to retry the table left in its flushing slot.
write_fixture_block "$tmp_dir/pat-c" 30
retry_end=$((failed_payload + 2 * BLOCK_SECTORS))
wait_for_retry "$retry_end"

# Shutdown appends the remaining active mapping, making the old torn header an
# interior record rather than an incomplete tail.
detach_dm_target
meta_wp_before_reopen=$(meta_zone_write_pointer) ||
	die "could not read the final corrupt-log write pointer"
expected_final_wp=$((retry_end + 2 * BLOCK_SECTORS))
[ "$meta_wp_before_reopen" -eq "$expected_final_wp" ] ||
	die "shutdown did not append exactly one final SSTable: expected WP $expected_final_wp, got $meta_wp_before_reopen"

case_torn_sstable_is_refused() {
	local name="$TARGET_NAME"
	local sectors meta_wp_after

	sectors=$(blockdev --getsz "$UNDERLYING") ||
		fail "failed to read the sector count of $UNDERLYING"
	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target still exists before corrupt-log recovery"
	fi
	if try_create_dm_target "$name" "$sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the corrupt-log target was accepted and could not be removed"
		fail "a torn interior SSTable was accepted during recovery"
	fi

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before_reopen" \
		"a refused recovery modified the metadata log"
	detail "torn_header=$first_header meta_wptr=$meta_wp_after"
}

run_case "when an interior SSTable payload is torn, recovery refuses the target" \
	case_torn_sstable_is_refused
remove_dm_target

report_summary
