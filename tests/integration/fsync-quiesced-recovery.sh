#!/usr/bin/env bash
# Durability gate with a deliberately limited fault model. The test-only hook
# omits clean-detach MemTable serialization after all I/O has quiesced; this is
# useful for exposing volatile-mapping loss, but it is not a power-cut test.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-fsync-quiesced}
ZNS_REQUIRED_ENGINE=lsm
ZNS_TESTING=1
export ZNS_TESTING
FSYNC_RECOVERY_SIZE_MB=${FSYNC_RECOVERY_SIZE_MB:-32}
FSYNC_RECOVERY_ZONE_MB=${FSYNC_RECOVERY_ZONE_MB:-4}
FSYNC_RECOVERY_TIMEOUT=${FSYNC_RECOVERY_TIMEOUT:-60}
TEST_THRESHOLD=${TEST_THRESHOLD:-1024}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/fsync-quiesced-recovery"

require_root
require_commands make modprobe dmsetup blkzone blockdev timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

# A volatile null_blk cache with FUA disabled makes fdatasync emit an observable
# FLUSH instead of being optimized into an uncounted FUA-only write.
ZNS_NULLBLK_CACHE_SIZE_MB=8
ZNS_NULLBLK_FUA=0
export ZNS_NULLBLK_CACHE_SIZE_MB ZNS_NULLBLK_FUA

build_test_tools
create_nullblk_fixture "$FSYNC_RECOVERY_SIZE_MB" "$FSYNC_RECOVERY_ZONE_MB"
build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones

data_sectors=$(data_zone_capacity_sectors) ||
	die "could not calculate physical data-zone capacity"
reserve_sectors=$(zone_capacity 0)
[ -n "$reserve_sectors" ] || die "could not read data-zone capacity"
reserve_sectors=$(printf '%u' "$reserve_sectors") ||
	die "invalid reserve capacity: $reserve_sectors"
logical_sectors=$((data_sectors - reserve_sectors))
[ "$logical_sectors" -gt 0 ] &&
	[ $((logical_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "invalid logical capacity: $logical_sectors sectors"

create_dm_target "$logical_sectors"

case_prepare_persisted_baseline() {
	timeout "$FSYNC_RECOVERY_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" init \
		"$DM_DEV" "$tmp_dir/versions.bin" 16 ||
		fail "failed to initialize the persisted baseline"

	# First detach is intentionally clean so all baseline mappings are on disk.
	detach_dm_target
	unload_module
	ZNS_MODULE_LOADED=0
	load_module memtable_threshold="$TEST_THRESHOLD" test_skip_shutdown_flush=1
	create_dm_target "$logical_sectors"
	timeout "$FSYNC_RECOVERY_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" verify \
		"$DM_DEV" "$tmp_dir/versions.bin" ||
		fail "the clean baseline did not recover before fault injection"
	touch "$tmp_dir/baseline.ready"
	detail "blocks=16 fault_model=quiesced-abort"
}

case_sync_reaches_lower_flush() {
	local requests completed failed

	[ -f "$tmp_dir/baseline.ready" ] ||
		fail "the persisted baseline prerequisite did not complete"
	require_status_fields flush_requests flush_completed flush_failed
	timeout "$FSYNC_RECOVERY_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" overwrite \
		"$DM_DEV" "$tmp_dir/versions.bin" 1 0x4653594e43 ||
		fail "the synchronized overwrite failed"

	requests=$(status_field flush_requests)
	completed=$(status_field flush_completed)
	failed=$(status_field flush_failed)
	assert_gt "$requests" 0 "fdatasync produced no observable lower FLUSH"
	assert_eq "$completed" "$requests" \
		"not every requested lower FLUSH completed successfully"
	assert_eq "$failed" 0 "a lower FLUSH failed"
	assert_gt "$(status_field active)" 0 \
		"the fixture did not leave a volatile mapping for the abort check"
	touch "$tmp_dir/sync-write.ready"
	detail "requests=$requests completed=$completed failed=$failed"
}

case_synced_mapping_survives_quiesced_abort() {
	[ -f "$tmp_dir/sync-write.ready" ] ||
		fail "the synchronized-write prerequisite did not complete"
	recreate_dm_target
	timeout "$FSYNC_RECOVERY_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" verify \
		"$DM_DEV" "$tmp_dir/versions.bin" ||
		fail "fdatasync returned success but its newest mapping was volatile"
}

run_case "when a clean baseline is reopened with the test hook, all old versions remain readable" \
	case_prepare_persisted_baseline
run_case "when fdatasync returns, a lower FLUSH request and successful completion are observable" \
	case_sync_reaches_lower_flush
run_case "when clean-detach serialization is omitted, the synchronized mapping still recovers" \
	case_synced_mapping_survives_quiesced_abort

report_summary
