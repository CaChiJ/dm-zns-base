#!/usr/bin/env bash
# Device-mapper target lifecycle and zoned-device inspection helpers.
#
# Every integration test owns its target: it creates one under its own
# TARGET_NAME and removes it from an EXIT trap, so tests never depend on a
# target somebody else left behind.

[ -n "${ZNS_DEVICE_SOURCED:-}" ] && return 0
ZNS_DEVICE_SOURCED=1

TARGET_NAME=${TARGET_NAME:-zns-test}
DM_DEV="/dev/mapper/$TARGET_NAME"

# Teardown only undoes what this suite actually did, so a refused run never
# destroys a target somebody created by hand with scripts/build-run.sh.
ZNS_MODULE_LOADED=0
ZNS_TARGET_CREATED=0

ZNS_IO_ERROR_PATTERN='blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)'

remove_dm_target() {
	dmsetup remove "$TARGET_NAME" 2>/dev/null || true
}

unload_module() {
	rmmod "$ZNS_MOD_NAME" 2>/dev/null || true
}

# Undo this suite's own target and module load, in that order.
teardown_target() {
	[ "$ZNS_TARGET_CREATED" -eq 1 ] && remove_dm_target
	[ "$ZNS_MODULE_LOADED" -eq 1 ] && unload_module
	[ -z "${tmp_dir:-}" ] || rm -rf "$tmp_dir"
	return 0
}

# Names of the zns-base targets that are currently live.
live_targets() {
	local names

	names=$(dmsetup ls --target zns-base 2>/dev/null |
		awk 'NF { print $1 }' | paste -sd' ' -)
	printf '%s' "${names:-<could not list targets>}"
}

# Load the module, first clearing anything a previous interrupted run left.
load_module() {
	remove_dm_target
	unload_module

	if lsmod | grep -q "^${ZNS_MOD_NAME//-/_} "; then
		die "$ZNS_MOD_NAME is in use by another target: $(live_targets); remove it first"
	fi

	insmod "$ZNS_KO_PATH" "$@" ||
		die "failed to load $ZNS_KO_PATH $*"
	ZNS_MODULE_LOADED=1
}

create_dm_target() {
	local sectors

	sectors=$(blockdev --getsz "$UNDERLYING") ||
		die "failed to read the sector count of $UNDERLYING"
	echo "0 $sectors zns-base $UNDERLYING" |
		dmsetup create "$TARGET_NAME" ||
		die "failed to create the DM target $TARGET_NAME"
	[ -b "$DM_DEV" ] || die "$DM_DEV was not created"
	ZNS_TARGET_CREATED=1
}

# Recreate this suite's target on the same underlying device without touching
# the zones. That is exactly what a restart looks like to the engine: the DM
# instance goes away and a new one opens the same media.
recreate_dm_target() {
	remove_dm_target
	ZNS_TARGET_CREATED=0
	create_dm_target
}

# Attempt a target of an arbitrary size and report whether dmsetup accepted it.
# Unlike create_dm_target this never aborts the suite, because a refused
# creation is the expected result for some cases.
try_create_dm_target() {
	local name=$1
	local sectors=$2

	echo "0 $sectors zns-base $UNDERLYING" |
		dmsetup create "$name" 2>/dev/null
}

reset_zones() {
	blkzone reset "$UNDERLYING" ||
		die "failed to reset the zones of $UNDERLYING"
}

# Reset only the first zone, for suites that write a single block and have no
# reason to wipe the rest of the device.
reset_zone_zero() {
	blkzone reset -o 0 -c 1 "$UNDERLYING" ||
		die "failed to reset zone 0 of $UNDERLYING"
}

# Value of one "key=value" field on the target's dmsetup status line.
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

require_status_fields() {
	local line key

	line=$(dmsetup status "$TARGET_NAME") ||
		die "dmsetup status failed"
	for key in "$@"; do
		case $line in
		*" $key="*) ;;
		*) die "dmsetup status has no '$key' field: $line" ;;
		esac
	done
}

count_io_errors() {
	dmesg | grep -Eic "$ZNS_IO_ERROR_PATTERN" || true
}

# Cases run in subshells, so the baseline travels through a file.
io_errors_save() {
	count_io_errors >"$1"
}

assert_no_new_io_errors() {
	local baseline_file=$1
	local before after

	before=$(cat "$baseline_file")
	after=$(count_io_errors)
	[ "$after" -eq "$before" ] ||
		fail "$((after - before)) new kernel I/O error(s) or zoned write rejection(s)"
}

# blkzone reports wptr relative to the zone start; both helpers below keep
# that convention, and zone_absolute_wp converts when a caller needs it.
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

# Absolute "start wptr" pair for the last zone, which the LSM engine reserves
# for its superblock and SSTables. Both values are decimal.
meta_zone_geometry() {
	local raw start wptr

	raw=$(blkzone report "$UNDERLYING" | tail -n 1 |
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
		}')
	[ -n "$raw" ] || return 1

	# shellcheck disable=SC2086
	set -- $raw
	start=$(printf '%u' "$1") || return 1
	wptr=$(printf '%u' "$2") || return 1

	if [ "$wptr" -lt "$start" ]; then
		wptr=$((start + wptr))
	fi
	printf '%u %u\n' "$start" "$wptr"
}

meta_zone_start() {
	local geometry

	geometry=$(meta_zone_geometry) || return 1
	printf '%s\n' "${geometry% *}"
}

meta_zone_write_pointer() {
	local geometry

	geometry=$(meta_zone_geometry) || return 1
	printf '%s\n' "${geometry#* }"
}

# One "id start length capacity wptr" row per zone, values normalized to
# decimal so later comparisons are plain integer arithmetic.
snapshot_zones() {
	local output=$1
	local raw="$output.raw"
	local id start length capacity write_pointer

	blkzone report "$UNDERLYING" |
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
				print count++, zone_start, zone_length,
				      zone_capacity, write_pointer
		}' >"$raw" || return 1

	: >"$output"
	while read -r id start length capacity write_pointer; do
		printf '%u %u %u %u %u\n' \
			"$id" "$start" "$length" "$capacity" "$write_pointer" \
			>>"$output" || return 1
	done <"$raw"
	rm -f "$raw"

	[ -s "$output" ] || return 1
}
