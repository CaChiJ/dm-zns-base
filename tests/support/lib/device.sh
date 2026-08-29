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
ZNS_BADBLOCK_TRACK_FILE=
ZNS_TARGET_SECTORS_ACTIVE=

ZNS_IO_ERROR_PATTERN='blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)'

remove_dm_target() {
	dmsetup remove "$TARGET_NAME" 2>/dev/null || true
}

unload_module() {
	rmmod "$ZNS_MOD_NAME" 2>/dev/null || true
}

# Undo fault injection before target teardown can flush anything, then release
# the suite's target and module.
teardown_target() {
	clear_injected_badblocks
	[ "$ZNS_TARGET_CREATED" -eq 1 ] && remove_dm_target
	[ "$ZNS_MODULE_LOADED" -eq 1 ] && unload_module
	destroy_nullblk_fixture
	[ -z "${tmp_dir:-}" ] || rm -rf "$tmp_dir"
	[ -z "$ZNS_BADBLOCK_TRACK_FILE" ] || rm -f "$ZNS_BADBLOCK_TRACK_FILE"
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
	local sectors=${1:-${ZNS_TARGET_SECTORS:-}}
	local physical_sectors

	physical_sectors=$(blockdev --getsz "$UNDERLYING") ||
		die "failed to read the sector count of $UNDERLYING"
	if [ -z "$sectors" ]; then
		if [ "$ZNS_ENGINE" = lsm ]; then
			sectors=$(data_zone_capacity_sectors) ||
				die "failed to calculate the LSM data-zone capacity"
		else
			sectors=$physical_sectors
		fi
	fi
	[[ $sectors =~ ^[0-9]+$ ]] && [ "$sectors" -gt 0 ] ||
		die "invalid DM target size: $sectors sectors"
	[ "$sectors" -le "$physical_sectors" ] ||
		die "DM target size $sectors exceeds lower size $physical_sectors"
	echo "0 $sectors zns-base $UNDERLYING" |
		dmsetup create "$TARGET_NAME" ||
		die "failed to create the DM target $TARGET_NAME"
	[ -b "$DM_DEV" ] || die "$DM_DEV was not created"
	ZNS_TARGET_CREATED=1
	ZNS_TARGET_SECTORS_ACTIVE=$sectors
}

# Take this suite's target down and insist that it went. remove_dm_target
# swallows failures because teardown must not mask a real result, but a suite
# that means to restart has to know the old instance is gone -- otherwise the
# next create fails with "already exists" and says nothing about why.
#
# --retry rides out the moment udev still holds the node open after the last
# I/O.
detach_dm_target() {
	dmsetup remove --retry "$TARGET_NAME" ||
		die "failed to remove the target $TARGET_NAME"
	ZNS_TARGET_CREATED=0
}

# Restart the engine on the same media: the DM instance goes away and a new one
# opens the device again, with no zone reset in between.
recreate_dm_target() {
	local sectors=$ZNS_TARGET_SECTORS_ACTIVE

	detach_dm_target
	create_dm_target "$sectors"
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

# Sum the live capacities of every data zone. The LSM engine reserves the last
# zone for its superblock and SSTables, so its capacity is deliberately omitted.
data_zone_capacity_sectors() {
	local nr_zones zone_sectors zone_id capacity total=0
	local sectors_per_block=8

	nr_zones=$(underlying_attr nr_zones) || return 1
	zone_sectors=$(underlying_attr chunk_sectors) || return 1
	[ "$nr_zones" -ge 2 ] || return 1

	for ((zone_id = 0; zone_id + 1 < nr_zones; zone_id++)); do
		capacity=$(zone_capacity $((zone_id * zone_sectors))) || return 1
		[ -n "$capacity" ] || return 1
		capacity=$(printf '%u' "$capacity") || return 1
		# The allocator cannot place a 4 KiB block in a shorter zone tail.
		capacity=$((capacity - capacity % sectors_per_block))
		total=$((total + capacity))
	done

	[ "$total" -gt 0 ] || return 1
	printf '%u\n' "$total"
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

# Capacity of one zone in sectors, as reported by the live block device rather
# than inferred from its configured zone size.
zone_capacity() {
	local offset=$1

	blkzone report -o "$offset" -c 1 "$UNDERLYING" |
		awk 'NR == 1 {
			for (i = 1; i <= NF; i++) {
				key = $i
				value = $(i + 1)
				gsub(/[,:]/, "", key)
				gsub(/,/, "", value)
				if (key == "cap") {
					print value
					exit
				}
			}
		}'
}

# blkzone commonly reports a write pointer relative to the zone start. Turn
# either representation into an absolute sector so it can be used for direct
# I/O and null_blk badblock injection.
zone_absolute_wp() {
	local zone_start=$1
	local write_pointer

	write_pointer=$(zone_write_pointer "$zone_start") || return 1
	[ -n "$write_pointer" ] || return 1
	if [ "$zone_start" -gt 0 ] && [ "$write_pointer" -lt "$zone_start" ]; then
		write_pointer=$((zone_start + write_pointer))
	fi
	printf '%u\n' "$write_pointer"
}

nullblk_badblocks_path() {
	local kernel_name

	kernel_name=$(underlying_kernel_name) || return 1
	[[ $kernel_name =~ ^nullb[0-9]+$ ]] || return 1

	printf '/sys/kernel/config/nullb/%s/badblocks\n' "$kernel_name"
}

require_nullblk_badblocks() {
	local path existing

	path=$(nullblk_badblocks_path) ||
		die "fault-injection suites require a null_blk UNDERLYING device"
	[ -w "$path" ] ||
		die "null_blk badblock injection is unavailable: $path"
	existing=$(cat "$path") ||
		die "cannot inspect existing null_blk badblocks: $path"
	[ -z "$existing" ] ||
		die "null_blk already has badblocks configured; refusing to modify them: $existing"
	if [ -z "$ZNS_BADBLOCK_TRACK_FILE" ]; then
		ZNS_BADBLOCK_TRACK_FILE=$(mktemp)
		export ZNS_BADBLOCK_TRACK_FILE
	fi
}

# null_blk accepts inclusive sector ranges in +start-end / -start-end form.
# Track only ranges this suite added: teardown must not clear a range owned by
# somebody else using the same test device.
nullblk_badblock_add() {
	local start=$1 end=$2 path

	[ "$start" -ge 0 ] && [ "$end" -ge "$start" ] ||
		return 1
	path=$(nullblk_badblocks_path) || return 1
	# Record first. If the configfs write fails, teardown harmlessly attempts to
	# remove the range; if recording failed after injection there would be no
	# reliable way to clean the device up.
	printf '%s:%s\n' "$start" "$end" >>"$ZNS_BADBLOCK_TRACK_FILE" ||
		return 1
	printf '+%s-%s\n' "$start" "$end" >"$path"
}

nullblk_badblock_remove() {
	local start=$1 end=$2 path

	path=$(nullblk_badblocks_path) || return 1
	printf -- '-%s-%s\n' "$start" "$end" >"$path" || return 1
}

clear_injected_badblocks() {
	local path range start end

	[ -n "$ZNS_BADBLOCK_TRACK_FILE" ] &&
		[ -s "$ZNS_BADBLOCK_TRACK_FILE" ] || return 0
	path=$(nullblk_badblocks_path) || return 0
	while IFS= read -r range; do
		[ -n "$range" ] || continue
		start=${range%%:*}
		end=${range#*:}
		printf -- '-%s-%s\n' "$start" "$end" >"$path" 2>/dev/null || true
	done <"$ZNS_BADBLOCK_TRACK_FILE"
	: >"$ZNS_BADBLOCK_TRACK_FILE"
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
