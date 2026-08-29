#!/usr/bin/env bash
# Exercise a real null_blk capacity hole. A full zone may report its WP at the
# end of zone length, while the allocator must rotate at the earlier capacity.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-zone-capacity}
ZNS_REQUIRED_ENGINE=lsm
ZONE_CAPACITY_SIZE_MB=${ZONE_CAPACITY_SIZE_MB:-20}
ZONE_CAPACITY_ZONE_MB=${ZONE_CAPACITY_ZONE_MB:-4}
ZONE_CAPACITY_CAPACITY_MB=${ZONE_CAPACITY_CAPACITY_MB:-3}
ZONE_CAPACITY_TIMEOUT=${ZONE_CAPACITY_TIMEOUT:-30}
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/zone-capacity"

require_root
require_commands make modprobe dmsetup blkzone blockdev dd cmp awk timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

create_nullblk_fixture "$ZONE_CAPACITY_SIZE_MB" "$ZONE_CAPACITY_ZONE_MB" \
	"$ZONE_CAPACITY_CAPACITY_MB"
build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

zone_sectors=$(underlying_attr chunk_sectors)
capacity_sectors=$(zone_capacity 0)
[ -n "$capacity_sectors" ] || die "could not read the live zone capacity"
capacity_sectors=$(printf '%u' "$capacity_sectors") ||
	die "invalid live zone capacity: $capacity_sectors"
[ "$capacity_sectors" -lt "$zone_sectors" ] ||
	die "this suite requires zone capacity smaller than zone length"
[ $((capacity_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "zone capacity is not 4 KiB aligned"
blocks_per_capacity=$((capacity_sectors / BLOCK_SECTORS))
blocks_to_write=$((2 * blocks_per_capacity + 1))

case_capacity_holes_are_skipped() {
	make_random_file "$tmp_dir/input.bin" "$blocks_to_write"
	timeout "$ZONE_CAPACITY_TIMEOUT" dd if="$tmp_dir/input.bin" \
		of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		count="$blocks_to_write" oflag=direct status=none ||
		fail "writes failed while crossing real zone-capacity holes"
	timeout "$ZONE_CAPACITY_TIMEOUT" dd if="$DM_DEV" \
		of="$tmp_dir/output.bin" bs="$ZNS_BLOCK_BYTES" \
		count="$blocks_to_write" iflag=direct status=none ||
		fail "readback failed after crossing real zone-capacity holes"
	assert_files_equal "$tmp_dir/input.bin" "$tmp_dir/output.bin" \
		"data changed across zone-capacity holes"
	detail "blocks=$blocks_to_write capacity=$capacity_sectors length=$zone_sectors"
}

case_full_zone_wp() {
	local zone_id=$1 wptr

	wptr=$(zone_write_pointer $((zone_id * zone_sectors)))
	wptr=$(printf '%u' "$wptr") || fail "invalid WP for zone $zone_id"
	assert_eq "$wptr" "$zone_sectors" \
		"full zone $zone_id did not report its write pointer at zone end"
	detail "zone=$zone_id wptr=$wptr capacity=$capacity_sectors"
}

case_third_zone_started() {
	local wptr

	wptr=$(zone_write_pointer $((2 * zone_sectors)))
	wptr=$(printf '%u' "$wptr") || fail "invalid WP for zone 2"
	assert_eq "$wptr" "$BLOCK_SECTORS" \
		"the allocator did not resume at the start of the third zone"
	detail "zone=2 wptr=$wptr"
}

run_case "when zone capacity is smaller than length, writes skip both capacity holes" \
	case_capacity_holes_are_skipped
run_case "when the first partial-capacity zone fills, its reported WP moves to zone end" \
	case_full_zone_wp 0
run_case "when the second partial-capacity zone fills, its reported WP moves to zone end" \
	case_full_zone_wp 1
run_case "when two capacity holes are crossed, the third zone contains exactly one block" \
	case_third_zone_started
run_case "when real capacity holes are crossed, no kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
