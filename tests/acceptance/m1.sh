#!/usr/bin/env bash
# Final acceptance test for the M1 milestone in docs/07-milestones.md.
#
# Unlike the integration suites, this one deliberately re-checks behaviour the
# narrower tests already cover: it is the single run that decides whether M1 is
# met, so it validates the official workload down to the fio JSON.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-m1-acceptance}
ZNS_REQUIRED_ENGINE=lsm
MEMTABLE_THRESHOLD=${MEMTABLE_THRESHOLD:-1024}

RANDWRITE_BYTES=$((100 * 1024 * 1024))
VERIFY_OFFSET_BYTES=$RANDWRITE_BYTES
VERIFY_BYTES=$((32 * 1024 * 1024))
OVERWRITE_BYTES=$((3 * 4096))
REQUIRED_BYTES=$((RANDWRITE_BYTES + VERIFY_BYTES + OVERWRITE_BYTES))
SECTOR_BYTES=512
TEST_LBA=100

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "acceptance/m1"

require_root
require_commands make fio jq dmsetup blkzone blockdev dmesg insmod rmmod \
	awk dd cmp readlink date
require_host_managed

writable_capacity_bytes() {
	local snapshot=$1
	local total_sectors=0
	local id start length capacity write_pointer

	while read -r id start length capacity write_pointer; do
		total_sectors=$((total_sectors + capacity))
	done <"$snapshot"

	echo $((total_sectors * SECTOR_BYTES))
}

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

snapshot_zones "$tmp_dir/zones-capacity" ||
	die "could not read a usable zone report from $UNDERLYING"
writable_bytes=$(writable_capacity_bytes "$tmp_dir/zones-capacity")
[ "$writable_bytes" -ge "$REQUIRED_BYTES" ] ||
	die "insufficient writable capacity: $writable_bytes bytes, $REQUIRED_BYTES required"

build_engine
load_module memtable_threshold="$MEMTABLE_THRESHOLD"
reset_zones
create_dm_target

snapshot_zones "$tmp_dir/zones-before" ||
	die "failed to snapshot the underlying zones"
dmesg_start=$(date '+%Y-%m-%d %H:%M:%S')
sleep 1

# Walk the before/after snapshots in step. Prints the number of zones whose
# write pointer advanced, and fails on any geometry or ordering violation.
compare_zone_snapshots() {
	local before=$1
	local after=$2
	local before_count after_count advanced=0 previous_start=-1
	local id_before start_before length_before capacity_before wp_before
	local id_after start_after length_after capacity_after wp_after
	local absolute_before absolute_after

	before_count=$(wc -l <"$before")
	after_count=$(wc -l <"$after")
	[ "$before_count" -eq "$after_count" ] ||
		fail "the zone count changed during the test"

	exec 3<"$after"
	while read -r id_before start_before length_before capacity_before wp_before
	do
		read -r id_after start_after length_after capacity_after wp_after <&3 ||
			fail "the final zone snapshot ended unexpectedly"

		[ "$id_before" -eq "$id_after" ] &&
			[ "$start_before" -eq "$start_after" ] &&
			[ "$length_before" -eq "$length_after" ] &&
			[ "$capacity_before" -eq "$capacity_after" ] ||
			fail "the zone geometry changed during the test"

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
			advanced=$((advanced + 1))
		fi
	done <"$before"
	exec 3<&-

	echo "$advanced"
}

case_threshold_parameter() {
	local parameter_path=/sys/module/dm_zns_base/parameters/memtable_threshold

	[ -r "$parameter_path" ] ||
		fail "the memtable_threshold parameter is not exposed"
	assert_eq "$(cat "$parameter_path")" "$MEMTABLE_THRESHOLD" \
		"memtable_threshold was not applied"
	detail "threshold=$MEMTABLE_THRESHOLD"
}

case_upper_is_conventional() {
	local dm_name zoned

	dm_name=$(basename "$(readlink -f "$DM_DEV")")
	zoned=$(cat "/sys/block/$dm_name/queue/zoned") ||
		fail "cannot read the zoned attribute of $DM_DEV"
	assert_eq "$zoned" none "the DM device is not conventional"
}

case_official_randwrite() {
	run_fio "$tmp_dir/randwrite-run.log" m1-acceptance-randwrite \
		--rw=randwrite --bs=4k --size=100M --iodepth=32 \
		--output-format=json --output="$tmp_dir/randwrite.json"

	jq -e --argjson bytes "$RANDWRITE_BYTES" '
		def text: tostring | ascii_downcase;
		(.jobs | length) == 1 and
		.jobs[0].error == 0 and
		((.jobs[0]["job options"].rw | text) == "randwrite") and
		(((.jobs[0]["job options"].bs | text) == "4k") or
		 ((.jobs[0]["job options"].bs | text) == "4096")) and
		(((.jobs[0]["job options"].size | text) == "100m") or
		 ((.jobs[0]["job options"].size | text) == ($bytes | tostring))) and
		((.jobs[0]["job options"].iodepth | text) == "32") and
		.jobs[0].write.io_bytes == $bytes and
		.jobs[0].write.total_ios == 25600 and
		((.jobs[0].iodepth_level["32"] // 0) > 0)
	' "$tmp_dir/randwrite.json" >/dev/null ||
		fail "the fio JSON does not match the 4 KiB / 100 MiB / iodepth 32 workload"
	detail "io=100MiB writes=25600 iodepth=32"
}

case_crc_verify_range() {
	run_fio "$tmp_dir/verify-run.log" m1-acceptance-verify \
		--rw=randwrite --bs=4k --offset=100M --size=32M --iodepth=8 \
		--verify=crc32c --verify_fatal=1 --verify_state_save=0 \
		--output-format=json --output="$tmp_dir/verify.json"

	jq -e --argjson offset "$VERIFY_OFFSET_BYTES" --argjson bytes "$VERIFY_BYTES" '
		def text: tostring | ascii_downcase;
		(.jobs | length) == 1 and
		.jobs[0].error == 0 and
		(((.jobs[0]["job options"].bs | text) == "4k") or
		 ((.jobs[0]["job options"].bs | text) == "4096")) and
		(((.jobs[0]["job options"].offset | text) == "100m") or
		 ((.jobs[0]["job options"].offset | text) == ($offset | tostring))) and
		(((.jobs[0]["job options"].size | text) == "32m") or
		 ((.jobs[0]["job options"].size | text) == ($bytes | tostring))) and
		((.jobs[0]["job options"].verify | text) == "crc32c")
	' "$tmp_dir/verify.json" >/dev/null ||
		fail "the fio JSON does not match the separate CRC verification workload"
	detail "offset=100MiB size=32MiB verify=crc32c"
}

case_latest_overwrite() {
	local pattern

	make_pattern_file "$tmp_dir/pat-a" A
	make_pattern_file "$tmp_dir/pat-b" B
	make_pattern_file "$tmp_dir/pat-c" C
	for pattern in a b c; do
		write_block "$tmp_dir/pat-$pattern" "$TEST_LBA"
	done
	assert_block "$tmp_dir/pat-c" "$TEST_LBA"
	assert_block_differs "$tmp_dir/pat-a" "$TEST_LBA"
	assert_block_differs "$tmp_dir/pat-b" "$TEST_LBA"
}

case_zone_geometry_stable() {
	snapshot_zones "$tmp_dir/zones-after" ||
		fail "failed to snapshot the underlying zones after the workload"
	compare_zone_snapshots "$tmp_dir/zones-before" "$tmp_dir/zones-after" \
		>/dev/null
}

case_zone_pointer_advanced() {
	local advanced

	advanced=$(compare_zone_snapshots "$tmp_dir/zones-before" \
		"$tmp_dir/zones-after")
	detail "zones advanced=$advanced"
	assert_ge "$advanced" 1 "no underlying zone write pointer advanced"
}

case_no_kernel_errors() {
	dmesg --since "$dmesg_start" >"$tmp_dir/dmesg-test.log" ||
		fail "failed to read the kernel messages for the test interval"
	if grep -Eqi "$ZNS_IO_ERROR_PATTERN" "$tmp_dir/dmesg-test.log"; then
		tail -n 40 "$tmp_dir/dmesg-test.log" >&2
		fail "a kernel I/O error or zoned write rejection was logged"
	fi
}

run_case "when the module is loaded with a threshold, the parameter is applied" \
	case_threshold_parameter
run_case "when the target is created, the upper device is conventional" \
	case_upper_is_conventional
run_case "when the official 100 MiB 4 KiB randwrite runs, fio reports 25,600 writes" \
	case_official_randwrite
run_case "when a separate 32 MiB range is CRC verified, every read matches" \
	case_crc_verify_range
run_case "when block $TEST_LBA is rewritten A->B->C, only C is readable" \
	case_latest_overwrite
run_case "when the workload finishes, the underlying zone geometry is unchanged" \
	case_zone_geometry_stable
run_case "when random writes are translated, an underlying write pointer advances" \
	case_zone_pointer_advanced
run_case "when the whole run is inspected, dmesg holds no I/O error or write reject" \
	case_no_kernel_errors

report_summary
