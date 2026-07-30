#!/usr/bin/env bash
# Final acceptance test for docs/07-milestones.md M1.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TESTS_DIR/.." && pwd)
SRC_DIR="$ROOT_DIR/src"
TARGET_NAME=${TARGET_NAME:-m1-acceptance}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
MEMTABLE_THRESHOLD=${MEMTABLE_THRESHOLD:-1024}
DM_DEV="/dev/mapper/$TARGET_NAME"
KO_PATH="$SRC_DIR/dm-zns-base.ko"

RANDWRITE_BYTES=$((100 * 1024 * 1024))
VERIFY_OFFSET_BYTES=$RANDWRITE_BYTES
VERIFY_BYTES=$((32 * 1024 * 1024))
OVERWRITE_BYTES=$((3 * 4096))
REQUIRED_BYTES=$((RANDWRITE_BYTES + VERIFY_BYTES + OVERWRITE_BYTES))
SECTOR_BYTES=512

fail()
{
	echo "[FAIL] $1" >&2
	exit 1
}

cleanup()
{
	local target

	while read -r target _; do
		[ -n "$target" ] &&
			dmsetup remove "$target" 2>/dev/null || true
	done < <(dmsetup ls --target zns-base 2>/dev/null || true)

	rmmod dm_zns_base 2>/dev/null || true
	[ -z "${tmp_dir:-}" ] || rm -rf "$tmp_dir"
}

require_commands()
{
	local command_name

	for command_name in \
		make fio jq dmsetup blkzone blockdev dmesg insmod rmmod \
		awk dd cmp readlink date
	do
		command -v "$command_name" >/dev/null ||
			fail "required command is missing: $command_name"
	done
}

snapshot_zones()
{
	local device=$1
	local output=$2
	local raw_output="${output}.raw"
	local id start length capacity write_pointer

	blkzone report "$device" |
		awk '
		{
			zone_start = zone_length = zone_capacity = write_pointer = ""
			for (i = 1; i <= NF; i++) {
				key = $i
				value = $(i + 1)
				gsub(/[,:]/, "", key)
				gsub(/[,:]/, "", value)
				if (key == "start")
					zone_start = value
				else if (key == "len")
					zone_length = value
				else if (key == "cap")
					zone_capacity = value
				else if (key == "wptr")
					write_pointer = value
			}
			if (zone_start != "" && zone_length != "" &&
			    zone_capacity != "" && write_pointer != "")
				print count++, zone_start, zone_length, zone_capacity,
				      write_pointer
		}' >"$raw_output" ||
		fail "failed to report zones from $device"

	: >"$output"
	while read -r id start length capacity write_pointer; do
		printf '%u %u %u %u %u\n' \
			"$id" "$start" "$length" "$capacity" "$write_pointer" \
			>>"$output" ||
			fail "failed to normalize zone report values"
	done <"$raw_output"
	rm -f "$raw_output"

	[ -s "$output" ] || fail "zone report contained no usable zones"
}

writable_capacity_bytes()
{
	local snapshot=$1
	local total_sectors=0
	local id start length capacity write_pointer

	while read -r id start length capacity write_pointer; do
		total_sectors=$((total_sectors + capacity))
	done <"$snapshot"

	echo $((total_sectors * SECTOR_BYTES))
}

validate_zone_snapshots()
{
	local before=$1
	local after=$2
	local before_count after_count
	local advanced=0
	local previous_start=-1
	local id_before start_before length_before capacity_before wp_before
	local id_after start_after length_after capacity_after wp_after
	local absolute_before absolute_after

	before_count=$(wc -l <"$before")
	after_count=$(wc -l <"$after")
	[ "$before_count" -eq "$after_count" ] ||
		fail "zone count changed during the test"

	exec 3<"$after"
	while read -r id_before start_before length_before capacity_before wp_before
	do
		read -r id_after start_after length_after capacity_after wp_after <&3 ||
			fail "final zone snapshot ended unexpectedly"

		[ "$id_before" -eq "$id_after" ] &&
			[ "$start_before" -eq "$start_after" ] &&
			[ "$length_before" -eq "$length_after" ] &&
			[ "$capacity_before" -eq "$capacity_after" ] ||
			fail "zone geometry changed during the test"

		[ "$capacity_after" -le "$length_after" ] ||
			fail "zone $id_after capacity exceeds its length"
		[ "$start_after" -gt "$previous_start" ] ||
			fail "zone starts are not strictly increasing"
		previous_start=$start_after

		# util-linux blkzone commonly reports wptr relative to zone start.
		absolute_before=$wp_before
		absolute_after=$wp_after
		if [ "$start_before" -gt 0 ] && [ "$wp_before" -lt "$start_before" ]; then
			absolute_before=$((start_before + wp_before))
		fi
		if [ "$start_after" -gt 0 ] && [ "$wp_after" -lt "$start_after" ]; then
			absolute_after=$((start_after + wp_after))
		fi

		[ "$absolute_after" -ge "$absolute_before" ] ||
			fail "zone $id_after write pointer moved backwards"
		[ "$absolute_after" -le $((start_after + capacity_after)) ] ||
			fail "zone $id_after write pointer exceeded capacity"
		if [ "$absolute_after" -gt "$absolute_before" ]; then
			advanced=1
		fi
	done <"$before"
	exec 3<&-

	[ "$advanced" -eq 1 ] ||
		fail "no underlying zone write pointer advanced"
}

validate_randwrite_json()
{
	local json_file=$1

	jq -e --argjson bytes "$RANDWRITE_BYTES" '
		def text: tostring | ascii_downcase;
		(.jobs | length) == 1 and
		.jobs[0].error == 0 and
		((.jobs[0]["job options"].rw | text) == "randwrite") and
		(((.jobs[0]["job options"].bs | text) == "4k") or
		 ((.jobs[0]["job options"].bs | text) == "4096")) and
		(((.jobs[0]["job options"].size | text) == "100m") or
		 ((.jobs[0]["job options"].size | text) ==
		  ($bytes | tostring))) and
		((.jobs[0]["job options"].iodepth | text) == "32") and
		.jobs[0].write.io_bytes == $bytes and
		.jobs[0].write.total_ios == 25600 and
		((.jobs[0].iodepth_level["32"] // 0) > 0)
	' "$json_file" >/dev/null ||
		fail "fio JSON does not match the 4 KiB/100 MiB/iodepth 32 workload"
}

validate_verify_json()
{
	local json_file=$1

	jq -e \
		--argjson offset "$VERIFY_OFFSET_BYTES" \
		--argjson bytes "$VERIFY_BYTES" '
		def text: tostring | ascii_downcase;
		(.jobs | length) == 1 and
		.jobs[0].error == 0 and
		(((.jobs[0]["job options"].bs | text) == "4k") or
		 ((.jobs[0]["job options"].bs | text) == "4096")) and
		(((.jobs[0]["job options"].offset | text) == "100m") or
		 ((.jobs[0]["job options"].offset | text) ==
		  ($offset | tostring))) and
		(((.jobs[0]["job options"].size | text) == "32m") or
		 ((.jobs[0]["job options"].size | text) ==
		  ($bytes | tostring))) and
		((.jobs[0]["job options"].verify | text) == "crc32c")
	' "$json_file" >/dev/null ||
		fail "fio JSON does not match the separate CRC verification workload"
}

check_test_dmesg()
{
	local start_time=$1
	local log_file=$2

	dmesg --since "$start_time" >"$log_file" ||
		fail "failed to read kernel messages for the test interval"

	if grep -Eqi \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' \
		"$log_file"; then
		tail -n 100 "$log_file" >&2
		fail "detected kernel I/O error or zoned write rejection"
	fi
}

[ "${EUID:-$(id -u)}" -eq 0 ] ||
	fail "run this test as root"
require_commands

tmp_dir=
cleanup
trap cleanup EXIT
tmp_dir=$(mktemp -d) || fail "failed to create a temporary directory"

echo "[*] building LSM engine"
make -C "$SRC_DIR" clean ZNS_ENGINE=lsm ||
	fail "failed to clean the LSM build"
make -C "$SRC_DIR" ZNS_ENGINE=lsm ||
	fail "failed to build the LSM engine"
[ -f "$KO_PATH" ] || fail "LSM kernel module was not created"

[ -b "$UNDERLYING" ] || fail "$UNDERLYING is not a block device"
underlying_name=$(basename "$(readlink -f "$UNDERLYING")")
underlying_zoned=$(cat "/sys/block/$underlying_name/queue/zoned") ||
	fail "failed to read underlying zoned attribute"
[ "$underlying_zoned" = "host-managed" ] ||
	fail "underlying device is not host-managed"

nr_zones=$(cat "/sys/block/$underlying_name/queue/nr_zones") ||
	fail "failed to read underlying zone count"
[ "$nr_zones" -gt 0 ] || fail "underlying device has no zones"

snapshot_zones "$UNDERLYING" "$tmp_dir/zones-capacity"
writable_bytes=$(writable_capacity_bytes "$tmp_dir/zones-capacity")
total_bytes=$(blockdev --getsize64 "$UNDERLYING") ||
	fail "failed to read underlying device capacity"
[ "$writable_bytes" -ge "$REQUIRED_BYTES" ] ||
	fail "insufficient underlying writable zone capacity: ${writable_bytes} bytes available, ${REQUIRED_BYTES} required"
[ "$total_bytes" -ge "$REQUIRED_BYTES" ] ||
	fail "insufficient underlying device capacity: ${total_bytes} bytes available, ${REQUIRED_BYTES} required"

echo "[*] resetting all zones on $UNDERLYING"
blkzone reset "$UNDERLYING" ||
	fail "failed to reset underlying zones"
blkzone report "$UNDERLYING" >/dev/null ||
	fail "failed to report underlying zones after reset"

echo "[*] loading LSM module with memtable_threshold=$MEMTABLE_THRESHOLD"
insmod "$KO_PATH" memtable_threshold="$MEMTABLE_THRESHOLD" ||
	fail "failed to load the LSM module"

parameter_path=/sys/module/dm_zns_base/parameters/memtable_threshold
[ -r "$parameter_path" ] ||
	fail "memtable_threshold parameter is not exposed"
actual_threshold=$(cat "$parameter_path")
[ "$actual_threshold" -eq "$MEMTABLE_THRESHOLD" ] ||
	fail "memtable_threshold was not applied"

sectors=$(blockdev --getsz "$UNDERLYING") ||
	fail "failed to read underlying sector count"
echo "0 $sectors zns-base $UNDERLYING" |
	dmsetup create "$TARGET_NAME" ||
	fail "failed to create the M1 acceptance DM target"
[ -b "$DM_DEV" ] || fail "$DM_DEV was not created"

dm_name=$(basename "$(readlink -f "$DM_DEV")")
[ -n "$dm_name" ] || fail "failed to resolve the DM kernel device name"
zoned_attr=$(cat "/sys/block/$dm_name/queue/zoned") ||
	fail "failed to read DM zoned attribute"
[ "$zoned_attr" = "none" ] || fail "DM device is not conventional"

snapshot_zones "$UNDERLYING" "$tmp_dir/zones-before"
dmesg_start=$(date '+%Y-%m-%d %H:%M:%S')

echo "[*] running the official 100 MiB 4 KiB random-write workload"
fio \
	--name=m1-acceptance-randwrite \
	--filename="$DM_DEV" \
	--rw=randwrite \
	--bs=4k \
	--size=100M \
	--ioengine=libaio \
	--iodepth=32 \
	--direct=1 \
	--output-format=json \
	--output="$tmp_dir/randwrite.json" ||
	fail "100 MiB random write failed"
validate_randwrite_json "$tmp_dir/randwrite.json"

echo "[*] verifying CRCs in a separate 32 MiB logical range"
fio \
	--name=m1-acceptance-verify \
	--filename="$DM_DEV" \
	--rw=randwrite \
	--bs=4k \
	--offset=100M \
	--size=32M \
	--ioengine=libaio \
	--iodepth=8 \
	--direct=1 \
	--verify=crc32c \
	--verify_fatal=1 \
	--verify_state_save=0 \
	--output-format=json \
	--output="$tmp_dir/verify.json" ||
	fail "CRC read-after-write verification failed"
validate_verify_json "$tmp_dir/verify.json"

echo "[*] verifying the latest mapping after repeated overwrites"
head -c 4096 /dev/zero | tr '\0' 'A' >"$tmp_dir/pat-a"
head -c 4096 /dev/zero | tr '\0' 'B' >"$tmp_dir/pat-b"
head -c 4096 /dev/zero | tr '\0' 'C' >"$tmp_dir/pat-c"
for pattern in "$tmp_dir/pat-a" "$tmp_dir/pat-b" "$tmp_dir/pat-c"; do
	dd if="$pattern" of="$DM_DEV" bs=4096 seek=100 count=1 \
		conv=notrunc oflag=direct status=none ||
		fail "failed to overwrite logical block 100"
done
dd if="$DM_DEV" of="$tmp_dir/readback" bs=4096 skip=100 count=1 \
	iflag=direct status=none ||
	fail "failed to read overwritten logical block 100"
cmp -s "$tmp_dir/pat-c" "$tmp_dir/readback" ||
	fail "overwrite returned stale data"
if cmp -s "$tmp_dir/pat-a" "$tmp_dir/readback" ||
   cmp -s "$tmp_dir/pat-b" "$tmp_dir/readback"; then
	fail "overwrite returned an older mapping"
fi

snapshot_zones "$UNDERLYING" "$tmp_dir/zones-after"
validate_zone_snapshots "$tmp_dir/zones-before" "$tmp_dir/zones-after"
check_test_dmesg "$dmesg_start" "$tmp_dir/dmesg-test.log"

echo
echo "M1 acceptance test: PASS"
echo "  upper device: conventional"
echo "  underlying device: host-managed"
echo "  memtable threshold: $MEMTABLE_THRESHOLD"
echo "  4 KiB random writes: 25,600"
echo "  official random-write range: 100 MiB"
echo "  separate CRC range: 32 MiB"
echo "  read-after-write CRC: PASS"
echo "  mapping lookup correctness: indirectly verified by CRC"
echo "  latest overwrite mapping: PASS"
echo "  underlying zone WP advanced: PASS"
echo "  zone capacity boundaries: PASS"
echo "  new kernel I/O errors: 0"
echo "  zone write rejects: 0"
