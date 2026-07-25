#!/usr/bin/env bash
# Verify that the LSM allocator writes across multiple underlying zones.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zone-boundary}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
BLOCK_SECTORS=8
export TARGET_NAME UNDERLYING
export ZNS_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"

count_io_errors() {
	dmesg | grep -Eic \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' ||
		true
}

zone_write_pointer() {
	local offset=$1

	blkzone report -o "$offset" -c 1 "$UNDERLYING" |
		awk 'NR == 1 {
			for (i = 1; i <= NF; i++)
				if ($i == "wptr") {
					value = $(i + 1)
					gsub(/,/, "", value)
					print value
					exit
				}
		}'
}

require_root
tmp_dir=$(mktemp -d)
cleanup_boundary_test() {
	rm -rf "$tmp_dir"
	cleanup_m1
}
trap cleanup_boundary_test EXIT

[ -b "$UNDERLYING" ] || {
	echo "[FAIL] $UNDERLYING is missing. Create a small zoned null_blk first." >&2
	exit 1
}

zoned=$(cat /sys/block/"$(basename "$UNDERLYING")"/queue/zoned)
[ "$zoned" = "host-managed" ] || {
	echo "[FAIL] $UNDERLYING is not host-managed zoned" >&2
	exit 1
}

zone_sectors=$(cat /sys/block/"$(basename "$UNDERLYING")"/queue/chunk_sectors)
nr_zones=$(cat /sys/block/"$(basename "$UNDERLYING")"/queue/nr_zones)

[ "$nr_zones" -ge 3 ] || {
	echo "[FAIL] at least three zones are required" >&2
	exit 1
}
[ $((zone_sectors % BLOCK_SECTORS)) -eq 0 ] || {
	echo "[FAIL] zone size is not aligned to 4 KiB" >&2
	exit 1
}

echo "[*] building LSM engine"
make -C "$SRC_DIR" clean ZNS_ENGINE=lsm
make -C "$SRC_DIR" ZNS_ENGINE=lsm

remove_dm_target
unload_module
if lsmod | grep -q '^dm_zns_base '; then
	echo "[FAIL] dm-zns-base is still in use by another DM target" >&2
	echo "       Remove the existing target before running this test." >&2
	exit 1
fi

echo "[*] resetting all zones on $UNDERLYING"
blkzone reset "$UNDERLYING"

load_module
create_dm_target

wp0_before=$(zone_write_pointer 0)
wp1_before=$(zone_write_pointer "$zone_sectors")
wp2_before=$(zone_write_pointer "$((2 * zone_sectors))")
[ -n "$wp0_before" ] && [ -n "$wp1_before" ] && [ -n "$wp2_before" ] || {
	echo "[FAIL] could not read initial zone write pointers" >&2
	exit 1
}

blocks_per_zone=$((zone_sectors / BLOCK_SECTORS))
blocks_to_write=$((2 * blocks_per_zone + 1))
errors_before=$(count_io_errors)

echo "[*] writing across two boundaries ($blocks_to_write blocks)"
dd if=/dev/urandom of="$tmp_dir/input.bin" bs=4096 count="$blocks_to_write" \
	status=none
dd if="$tmp_dir/input.bin" of="$DM_DEV" bs=4096 count="$blocks_to_write" \
	oflag=direct status=none

echo "[*] reading back all mapped blocks"
dd if="$DM_DEV" of="$tmp_dir/output.bin" bs=4096 count="$blocks_to_write" \
	iflag=direct status=none
cmp "$tmp_dir/input.bin" "$tmp_dir/output.bin"

wp0_after=$(zone_write_pointer 0)
wp1_after=$(zone_write_pointer "$zone_sectors")
wp2_after=$(zone_write_pointer "$((2 * zone_sectors))")
errors_after=$(count_io_errors)

# blkzone prints wptr as an offset relative to each zone's start.
[ "$((wp0_after))" -eq "$zone_sectors" ] || {
	echo "[FAIL] zone 0 did not stop at its boundary: $wp0_after" >&2
	exit 1
}
[ "$((wp1_after))" -eq "$zone_sectors" ] || {
	echo "[FAIL] zone 1 did not stop at its boundary: $wp1_after" >&2
	exit 1
}
[ "$((wp2_after))" -eq "$BLOCK_SECTORS" ] || {
	echo "[FAIL] zone 2 WP did not advance by one block: $wp2_after" >&2
	exit 1
}
[ "$errors_after" -eq "$errors_before" ] || {
	echo "[FAIL] detected new kernel I/O or zoned write rejection errors" >&2
	exit 1
}

echo "[*] zone write pointers:"
echo "    zone 0: $wp0_before -> $wp0_after"
echo "    zone 1: $wp1_before -> $wp1_after"
echo "    zone 2: $wp2_before -> $wp2_after"
blkzone report -o 0 -c 3 "$UNDERLYING"
echo "Zone boundary rotation test: PASS"
