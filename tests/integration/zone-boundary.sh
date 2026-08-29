#!/usr/bin/env bash
# The allocator must follow zone capacity across zone boundaries instead of
# treating the underlying device as one linear address space.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-zone-boundary}
ZNS_REQUIRED_ENGINE=lsm
BLOCK_SECTORS=8

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/zone-boundary"

require_root
require_commands make dmsetup blkzone blockdev dd cmp awk
require_host_managed
require_zones 3

zone_sectors=$(underlying_attr chunk_sectors)
[ $((zone_sectors % BLOCK_SECTORS)) -eq 0 ] ||
	die "the zone size is not 4 KiB aligned: $zone_sectors sectors"

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

for zone_id in 0 1 2; do
	[ -n "$(zone_write_pointer $((zone_id * zone_sectors)))" ] ||
		die "could not read the initial write pointer of zone $zone_id"
done

blocks_per_zone=$((zone_sectors / BLOCK_SECTORS))
blocks_to_write=$((2 * blocks_per_zone + 1))

case_write_across_boundaries() {
	make_random_file "$tmp_dir/input.bin" "$blocks_to_write"
	dd if="$tmp_dir/input.bin" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" \
		count="$blocks_to_write" oflag=direct status=none ||
		fail "failed to write $blocks_to_write blocks"
	dd if="$DM_DEV" of="$tmp_dir/output.bin" bs="$ZNS_BLOCK_BYTES" \
		count="$blocks_to_write" iflag=direct status=none ||
		fail "failed to read $blocks_to_write blocks back"
	assert_files_equal "$tmp_dir/input.bin" "$tmp_dir/output.bin" \
		"the readback across zone boundaries differs"
	detail "blocks=$blocks_to_write"
}

# blkzone reports wptr relative to each zone's start, so a filled zone reads
# back as its own length.
case_zone_filled() {
	local zone_id=$1
	local wptr

	wptr=$(zone_write_pointer $((zone_id * zone_sectors)))
	detail "zone=$zone_id wptr=$wptr"
	assert_eq "$((wptr))" "$zone_sectors" \
		"zone $zone_id did not stop at its boundary"
}

case_next_zone_started() {
	local wptr

	wptr=$(zone_write_pointer $((2 * zone_sectors)))
	detail "zone=2 wptr=$wptr"
	assert_eq "$((wptr))" "$BLOCK_SECTORS" \
		"zone 2 did not advance by exactly one block"
}

run_case "when writes cross two zone boundaries, every block reads back intact" \
	case_write_across_boundaries
run_case "when zone 0 reaches capacity, its write pointer stops at the boundary" \
	case_zone_filled 0
run_case "when zone 1 reaches capacity, its write pointer stops at the boundary" \
	case_zone_filled 1
run_case "when the third zone opens, its write pointer advances by one block" \
	case_next_zone_started
run_case "when writes rotate across zones, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
