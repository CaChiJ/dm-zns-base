#!/usr/bin/env bash
# Verify that the immutable MemTable is flushed to an on-disk SSTable, freed
# from memory, and still served correctly by the read path.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-sstable-flush}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
TEST_THRESHOLD=${TEST_THRESHOLD:-64}
NR_BLOCKS=${NR_BLOCKS:-512}
FLUSH_TIMEOUT=${FLUSH_TIMEOUT:-30}
export TARGET_NAME UNDERLYING
export ZNS_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"

fail() {
	echo "[FAIL] $1" >&2
	exit 1
}

count_io_errors() {
	dmesg | grep -Eic \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' ||
		true
}

# The engine status line must carry every counter this test judges on.
# fail() cannot run inside a command substitution, so the fields are checked
# once here rather than on each parse.
require_status_fields() {
	local line
	local key

	line=$(dmsetup status "$TARGET_NAME") ||
		fail "dmsetup status failed"
	for key in active immutable flushing sstables sst_entries meta_used; do
		case "$line" in
		*" $key="*) ;;
		*) fail "dmsetup status has no '$key' field: $line" ;;
		esac
	done
}

# Print one "key=value" field from the engine's dmsetup status line.
status_field() {
	local key=$1

	dmsetup status "$TARGET_NAME" |
		awk -v key="$key" '{
			for (i = 1; i <= NF; i++) {
				split($i, kv, "=")
				if (kv[1] == key) {
					print kv[2]
					exit
				}
			}
		}'
}

# Raw "start wptr" of the last zone. blkzone labels its keys with a trailing
# colon ("start:") and prints hex values that awk cannot parse, so keys are
# normalized here and the values are converted by the caller.
last_zone_raw() {
	blkzone report "$UNDERLYING" | tail -n 1 |
		awk '{
			start = wptr = ""
			for (i = 1; i <= NF; i++) {
				key = $i
				value = $(i + 1)
				gsub(/[,:]/, "", key)
				gsub(/[,:]/, "", value)
				if (key == "start")
					start = value
				else if (key == "wptr")
					wptr = value
			}
			if (start != "" && wptr != "")
				print start, wptr
		}'
}

# Absolute write pointer of the reserved metadata zone.
meta_zone_write_pointer() {
	local raw start wptr

	raw=$(last_zone_raw)
	if [ -z "$raw" ]; then
		echo "could not parse the last zone from: $(blkzone report "$UNDERLYING" | tail -n 1)" >&2
		return 1
	fi

	# shellcheck disable=SC2086
	set -- $raw
	start=$(printf '%u' "$1") || return 1
	wptr=$(printf '%u' "$2") || return 1

	# util-linux commonly reports wptr relative to the zone start.
	if [ "$wptr" -lt "$start" ]; then
		echo $((start + wptr))
	else
		echo "$wptr"
	fi
}

write_block() {
	dd if="$1" of="$DM_DEV" bs=4096 seek="$2" count=1 \
		conv=notrunc oflag=direct status=none
}

read_block() {
	dd if="$DM_DEV" of="$2" bs=4096 skip="$1" count=1 \
		iflag=direct status=none
}

require_root
tmp_dir=$(mktemp -d)
cleanup_sstable_flush_test() {
	rm -rf "$tmp_dir"
	cleanup_m1
}
trap cleanup_sstable_flush_test EXIT

for command_name in make dmsetup blkzone dmesg insmod rmmod awk dd cmp; do
	command -v "$command_name" >/dev/null ||
		fail "required command is missing: $command_name"
done

[ -b "$UNDERLYING" ] ||
	fail "$UNDERLYING is missing. Run scripts/nullblk-up.sh first."

nr_zones=$(blkzone report "$UNDERLYING" | wc -l)
[ "$nr_zones" -ge 2 ] ||
	fail "the underlying device needs at least 2 zones (data + metadata)"

echo "[*] building LSM engine"
make -C "$SRC_DIR" clean ZNS_ENGINE=lsm
make -C "$SRC_DIR" ZNS_ENGINE=lsm

remove_dm_target
unload_module
if lsmod | grep -q '^dm_zns_base '; then
	fail "dm-zns-base is still in use by another DM target"
fi

echo "[*] resetting all zones on $UNDERLYING"
blkzone reset "$UNDERLYING"

echo "[*] loading LSM module with memtable_threshold=$TEST_THRESHOLD"
insmod "$KO_PATH" memtable_threshold="$TEST_THRESHOLD"
create_dm_target

require_status_fields

# The engine reserves the last zone of the underlying device for SSTables.
meta_wp_before=$(meta_zone_write_pointer) ||
	fail "failed to read the metadata zone write pointer"

errors_before=$(count_io_errors)

echo "[*] writing $NR_BLOCKS distinct 4 KiB logical blocks"
dd if=/dev/urandom of="$tmp_dir/source.bin" bs=4096 count="$NR_BLOCKS" status=none
dd if="$tmp_dir/source.bin" of="$DM_DEV" bs=4096 count="$NR_BLOCKS" \
	oflag=direct conv=notrunc status=none

echo "[*] waiting for the flush workqueue to drain"
deadline=$((SECONDS + FLUSH_TIMEOUT))
while [ "$(status_field flushing)" -ne 0 ] || [ "$(status_field immutable)" -ne 0 ]; do
	[ "$SECONDS" -lt "$deadline" ] ||
		fail "flush did not converge within ${FLUSH_TIMEOUT}s: $(dmsetup status "$TARGET_NAME")"
	sleep 0.2
done

echo "[*] status: $(dmsetup status "$TARGET_NAME")"

sstables=$(status_field sstables)
sst_entries=$(status_field sst_entries)
in_memory=$(( $(status_field active) + $(status_field immutable) +
	      $(status_field flushing) ))

[ "$sstables" -ge 1 ] ||
	fail "no SSTable was flushed to disk"
[ "$sst_entries" -ge $((NR_BLOCKS * 3 / 4)) ] ||
	fail "only $sst_entries of $NR_BLOCKS mappings reached disk"
[ "$in_memory" -lt "$NR_BLOCKS" ] ||
	fail "all $NR_BLOCKS mappings are still resident in memory ($in_memory)"

echo "[*] reading every block back through the on-disk SSTable path"
dd if="$DM_DEV" of="$tmp_dir/readback.bin" bs=4096 count="$NR_BLOCKS" \
	iflag=direct status=none
cmp "$tmp_dir/source.bin" "$tmp_dir/readback.bin" ||
	fail "readback differs from what was written"

echo "[*] reading individual blocks that only exist in the oldest SSTable"
for logical_block in 0 5 63; do
	dd if="$tmp_dir/source.bin" of="$tmp_dir/expect.bin" bs=4096 \
		skip="$logical_block" count=1 status=none
	read_block "$logical_block" "$tmp_dir/actual.bin"
	cmp "$tmp_dir/expect.bin" "$tmp_dir/actual.bin" ||
		fail "block $logical_block read back stale data from the SSTable"
done

echo "[*] verifying that the active MemTable beats a flushed SSTable"
head -c 4096 /dev/zero | tr '\0' 'Z' >"$tmp_dir/newest.bin"
write_block "$tmp_dir/newest.bin" 0
read_block 0 "$tmp_dir/actual.bin"
cmp "$tmp_dir/newest.bin" "$tmp_dir/actual.bin" ||
	fail "overwrite of block 0 returned the stale SSTable mapping"

echo "[*] verifying that an unmapped logical block still zero-fills"
dd if=/dev/zero of="$tmp_dir/zero.bin" bs=4096 count=1 status=none
read_block $((NR_BLOCKS + 4096)) "$tmp_dir/actual.bin"
cmp "$tmp_dir/zero.bin" "$tmp_dir/actual.bin" ||
	fail "unmapped logical block did not zero-fill"

echo "[*] verifying that the reserved metadata zone was written"
meta_wp_after=$(meta_zone_write_pointer) ||
	fail "failed to re-read the metadata zone write pointer"
[ "$meta_wp_after" -gt "$meta_wp_before" ] ||
	fail "the metadata zone write pointer did not advance"

errors_after=$(count_io_errors)
[ "$errors_after" -eq "$errors_before" ] ||
	fail "detected new kernel I/O or zoned write rejection errors"

echo
echo "SSTable flush test: PASS"
echo "  memtable threshold:   $TEST_THRESHOLD"
echo "  logical blocks:       $NR_BLOCKS"
echo "  SSTables on disk:     $sstables"
echo "  mappings on disk:     $sst_entries"
echo "  mappings in memory:   $in_memory"
echo "  metadata zone WP:     $meta_wp_before -> $meta_wp_after"
