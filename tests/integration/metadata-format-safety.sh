#!/usr/bin/env bash
# Opening media without trustworthy metadata must fail without modifying it.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-metadata-format-safety}
ZNS_REQUIRED_ENGINE=lsm
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/metadata-format-safety"

require_root
require_commands make dmsetup blkzone blockdev dd
require_host_managed
require_zones 2

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module

logical_sectors=$(data_zone_capacity_sectors) ||
	die "failed to calculate the LSM data-zone capacity"
physical_sectors=$(blockdev --getsz "$UNDERLYING") ||
	die "failed to read the lower-device sector count"
make_pattern_file "$tmp_dir/data.bin" D
make_pattern_file "$tmp_dir/foreign.bin" F

case_oversized_target_is_refused() {
	local name="$TARGET_NAME"
	local meta_wp_before meta_wp_after

	meta_wp_before=$(meta_zone_write_pointer) ||
		fail "could not read the empty metadata write pointer"
	if try_create_dm_target "$name" "$physical_sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the oversized target was accepted and could not be removed"
		fail "a target larger than the usable data zones was accepted"
	fi
	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before" \
		"rejecting an oversized target modified the metadata zone"
	detail "requested=$physical_sectors usable=$logical_sectors"
}

case_clean_media_is_accepted() {
	local name="$TARGET_NAME"

	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target already exists before the control case"
	fi
	try_create_dm_target "$name" "$logical_sectors" ||
		fail "a clean device was refused, so the rejection cases would prove nothing"
	dmsetup remove --retry "$name" 2>/dev/null ||
		fail "the clean control target could not be removed"
}

reset_zones
run_case "when target length includes the reserved metadata zone, creation is refused" \
	case_oversized_target_is_refused
run_case "when both data and metadata zones are empty, the target is accepted" \
	case_clean_media_is_accepted
remove_dm_target

# The control case formatted the metadata zone. Reset it before constructing
# the first refusal fixture.
reset_zones

case_dirty_data_without_metadata_is_refused() {
	local name="$TARGET_NAME"
	local meta_start meta_wp_before meta_wp_after data_wp

	dd if="$tmp_dir/data.bin" of="$UNDERLYING" bs="$ZNS_BLOCK_BYTES" \
		seek=0 count=1 conv=notrunc oflag=direct status=none ||
		fail "could not seed the first data zone"
	data_wp=$(zone_absolute_wp 0) ||
		fail "could not read the data-zone write pointer"
	assert_eq "$data_wp" "$BLOCK_SECTORS" \
		"the dirty-data fixture did not advance the first zone"

	meta_start=$(meta_zone_start) ||
		fail "could not find the metadata zone"
	meta_wp_before=$(meta_zone_write_pointer) ||
		fail "could not read the metadata write pointer"
	assert_eq "$meta_wp_before" "$meta_start" \
		"the metadata zone was not empty before the test"

	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target already exists before the dirty-data case"
	fi
	if try_create_dm_target "$name" "$logical_sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the unsafe target was accepted and could not be removed"
		fail "a target was created even though data exists without metadata"
	fi

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before" \
		"a refused open modified the metadata zone"
	detail "data_wptr=$data_wp meta_wptr=$meta_wp_after"
}

run_case "when data zones are dirty but metadata is empty, the target is refused" \
	case_dirty_data_without_metadata_is_refused
remove_dm_target

# The first case intentionally dirties the device. Give the foreign-superblock
# scenario a separate, fully empty format lifetime.
reset_zones

case_foreign_metadata_is_refused() {
	local name="$TARGET_NAME"
	local meta_start meta_wp_before meta_wp_after

	meta_start=$(meta_zone_start) ||
		fail "could not find the metadata zone"
	dd if="$tmp_dir/foreign.bin" of="$UNDERLYING" bs="$ZNS_BLOCK_BYTES" \
		seek=$((meta_start / BLOCK_SECTORS)) count=1 conv=notrunc \
		oflag=direct status=none ||
		fail "could not seed a foreign metadata block"
	meta_wp_before=$(meta_zone_write_pointer) ||
		fail "could not read the foreign metadata write pointer"

	if dmsetup info "$name" >/dev/null 2>&1; then
		fail "the probe target already exists before the foreign-metadata case"
	fi
	if try_create_dm_target "$name" "$logical_sectors"; then
		dmsetup remove --retry "$name" 2>/dev/null ||
			fail "the foreign-metadata target was accepted and could not be removed"
		fail "a foreign metadata block was accepted as a superblock"
	fi

	meta_wp_after=$(meta_zone_write_pointer) ||
		fail "could not re-read the metadata write pointer"
	assert_eq "$meta_wp_after" "$meta_wp_before" \
		"a refused open appended behind foreign metadata"
	detail "meta_wptr=$meta_wp_after"
}

run_case "when the metadata zone starts with a foreign block, the target is refused" \
	case_foreign_metadata_is_refused
remove_dm_target

report_summary
