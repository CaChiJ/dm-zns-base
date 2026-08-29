#!/usr/bin/env bash
# M3 gate: force physical write demand past data-zone capacity, then verify
# every latest logical version before and after target recreation.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-gc-cycle}
ZNS_REQUIRED_ENGINE=lsm
ZNS_TESTING=1
export ZNS_TESTING
GC_SIZE_MB=${GC_SIZE_MB:-40}
GC_ZONE_MB=${GC_ZONE_MB:-4}
GC_RESERVE_ZONES=${GC_RESERVE_ZONES:-2}
GC_TIMEOUT=${GC_TIMEOUT:-120}
TEST_THRESHOLD=${TEST_THRESHOLD:-1024}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "system/gc-cycle"

require_root
require_commands make modprobe dmsetup blkzone blockdev timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

build_test_tools
create_nullblk_fixture "$GC_SIZE_MB" "$GC_ZONE_MB"
build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones

data_sectors=$(data_zone_capacity_sectors) ||
	die "could not calculate physical data-zone capacity"
one_zone_sectors=$(zone_capacity 0)
[ -n "$one_zone_sectors" ] || die "could not read data-zone capacity"
one_zone_sectors=$(printf '%u' "$one_zone_sectors") ||
	die "invalid data-zone capacity: $one_zone_sectors"
reserve_sectors=$((GC_RESERVE_ZONES * one_zone_sectors))
[ "$data_sectors" -gt "$reserve_sectors" ] ||
	die "GC reserve consumes all physical data capacity"
logical_sectors=$((data_sectors - reserve_sectors))
[ $((logical_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "logical capacity is not 4 KiB aligned"

logical_blocks=$((logical_sectors / BLOCK_SECTORS))
physical_blocks=$((data_sectors / BLOCK_SECTORS))
fill_blocks=$((4 * logical_blocks / 5))
overwrite_operations=$(((6 * logical_blocks + 4) / 5))
[ "$fill_blocks" -gt 0 ] || die "official 80% fill rounded to zero"

create_dm_target "$logical_sectors"
io_errors_save "$tmp_dir/io-errors"

case_capacity_forces_gc() {
	assert_eq "$(blockdev --getsz "$DM_DEV")" "$logical_sectors" \
		"the configured logical capacity was not exposed"
	assert_gt "$((fill_blocks + overwrite_operations))" "$physical_blocks" \
		"the workload can finish without reclaiming physical space"
	assert_eq "$(status_field logical_sectors)" "$logical_sectors" \
		"status reports a different logical capacity"
	assert_eq "$(status_field physical_sectors)" \
		"$(blockdev --getsz "$UNDERLYING")" \
		"status reports target length as physical capacity"
	detail "logical=$logical_blocks physical=$physical_blocks demand=$((fill_blocks + overwrite_operations))"
}

case_gc_observability_contract() {
	local line key value

	line=$(dmsetup status "$TARGET_NAME") || fail "dmsetup status failed"
	for key in free_zones gc_runs gc_moved gc_resets gc_failures; do
		case $line in
		*" $key="*) ;;
		*) fail "dmsetup status has no '$key' field: $line" ;;
		esac
		value=$(status_field "$key")
		[[ $value =~ ^[0-9]+$ ]] || fail "status field $key is not numeric: $value"
		printf '%s\n' "$value" >"$tmp_dir/$key.before"
	done
	detail "gc_runs=$(status_field gc_runs) free_zones=$(status_field free_zones)"
}

case_official_gc_workload() {
	timeout "$GC_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" init \
		"$DM_DEV" "$tmp_dir/versions.bin" "$fill_blocks" ||
		fail "the 80% initialization phase failed or timed out"
	timeout "$GC_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" overwrite \
		"$DM_DEV" "$tmp_dir/versions.bin" "$overwrite_operations" \
		0x4d334743 || fail "the 1.2x overwrite phase failed or timed out"
	touch "$tmp_dir/gc-workload.ready"
	detail "fill=$fill_blocks overwrite=$overwrite_operations"
}

case_gc_counters_advanced() {
	local key before after

	[ -f "$tmp_dir/gc-workload.ready" ] ||
		fail "the GC workload prerequisite did not complete"
	for key in gc_runs gc_moved gc_resets; do
		[ -f "$tmp_dir/$key.before" ] ||
			fail "the GC observability prerequisite did not complete"
		before=$(cat "$tmp_dir/$key.before")
		after=$(status_field "$key")
		assert_gt "$after" "$before" "$key did not advance during forced GC"
	done
	assert_eq "$(status_field gc_failures)" "$(cat "$tmp_dir/gc_failures.before")" \
		"GC reported an internal failure"
	detail "runs=$(status_field gc_runs) moved=$(status_field gc_moved) resets=$(status_field gc_resets)"
}

case_latest_versions_survive_relocation() {
	[ -f "$tmp_dir/gc-workload.ready" ] ||
		fail "the GC workload prerequisite did not complete"
	timeout "$GC_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" verify \
		"$DM_DEV" "$tmp_dir/versions.bin" ||
		fail "a latest logical version was lost or mis-relocated"
}

case_latest_versions_survive_recovery() {
	[ -f "$tmp_dir/gc-workload.ready" ] ||
		fail "the GC workload prerequisite did not complete"
	recreate_dm_target
	timeout "$GC_TIMEOUT" "$ZNS_TOOLS_DIR/versioned-io" verify \
		"$DM_DEV" "$tmp_dir/versions.bin" ||
		fail "a relocated mapping did not survive target recreation"
}

run_case "when capacity reserves space, the M3 workload mathematically requires GC" \
	case_capacity_forces_gc
run_case "when GC is exposed, status provides numeric lifecycle and failure counters" \
	case_gc_observability_contract
run_case "when 80% fill is followed by 1.2x overwrites, the workload completes without ENOSPC" \
	case_official_gc_workload
run_case "when capacity is exceeded, relocation and reset counters advance without failure" \
	case_gc_counters_advanced
run_case "when GC relocates live blocks, every latest logical version remains readable" \
	case_latest_versions_survive_relocation
run_case "when a GC-populated target is recreated, every latest logical version remains readable" \
	case_latest_versions_survive_recovery
run_case "when the forced GC cycle finishes, no kernel I/O errors or zoned rejections appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
