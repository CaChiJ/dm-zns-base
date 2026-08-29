#!/usr/bin/env bash
# Per-suite null_blk fixtures for tests that need a specific device geometry.
#
# The ordinary required suites use UNDERLYING (normally /dev/nullb0). Extended
# and future suites create private configfs devices instead, keeping small or
# filesystem-destructive fixtures away from a device supplied by the user.

[ -n "${ZNS_NULLBLK_SOURCED:-}" ] && return 0
ZNS_NULLBLK_SOURCED=1

ZNS_NULLBLK_OWNED=0
ZNS_NULLBLK_CONFIG=
ZNS_NULLBLK_DEV=
ZNS_NULLBLK_PREVIOUS_UNDERLYING=

destroy_nullblk_fixture() {
	local attempt

	[ "$ZNS_NULLBLK_OWNED" -eq 1 ] || return 0

	if [ -n "$ZNS_NULLBLK_CONFIG" ] && [ -d "$ZNS_NULLBLK_CONFIG" ]; then
		printf '0\n' >"$ZNS_NULLBLK_CONFIG/power" 2>/dev/null || true
		for attempt in $(seq 1 50); do
			[ ! -b "$ZNS_NULLBLK_DEV" ] && break
			sleep 0.1
		done
		if [ -b "$ZNS_NULLBLK_DEV" ]; then
			printf 'null_blk fixture is still live: %s\n' \
				"$ZNS_NULLBLK_DEV" >&2
			return 0
		fi
		rmdir "$ZNS_NULLBLK_CONFIG" 2>/dev/null ||
			printf 'null_blk fixture config remains: %s\n' \
				"$ZNS_NULLBLK_CONFIG" >&2
	fi

	if [ -n "$ZNS_NULLBLK_PREVIOUS_UNDERLYING" ]; then
		UNDERLYING=$ZNS_NULLBLK_PREVIOUS_UNDERLYING
		export UNDERLYING
	fi
	ZNS_NULLBLK_OWNED=0
	ZNS_NULLBLK_CONFIG=
	ZNS_NULLBLK_DEV=
}

# create_nullblk_fixture <size MiB> <zone-size MiB> [zone-capacity MiB]
create_nullblk_fixture() {
	local size_mb=$1 zone_size_mb=$2 zone_capacity_mb=${3:-}
	local config_root=/sys/kernel/config/nullb
	local fixture_name index attempt named_dev indexed_dev

	[ "$(id -u)" -eq 0 ] || die "creating a null_blk fixture requires root"
	require_commands modprobe mountpoint mount lsmod grep
	[ "$ZNS_NULLBLK_OWNED" -eq 0 ] ||
		die "this suite already owns a null_blk fixture"
	[ "$size_mb" -gt 0 ] && [ "$zone_size_mb" -gt 0 ] ||
		die "null_blk size and zone size must be positive"
	[ $((size_mb % zone_size_mb)) -eq 0 ] ||
		die "null_blk size must be a multiple of its zone size"
	if [ -n "$zone_capacity_mb" ]; then
		[ "$zone_capacity_mb" -gt 0 ] &&
			[ "$zone_capacity_mb" -le "$zone_size_mb" ] ||
			die "zone capacity must be in 1..zone-size MiB"
	fi

	if ! lsmod | grep -q '^null_blk '; then
		modprobe null_blk nr_devices=0 || die "failed to load null_blk"
	fi
	if ! mountpoint -q /sys/kernel/config; then
		mount -t configfs none /sys/kernel/config ||
			die "failed to mount configfs"
	fi
	[ -d "$config_root" ] || die "null_blk configfs is unavailable"

	for attempt in $(seq 1 20); do
		fixture_name="zns-test-$$-$RANDOM"
		ZNS_NULLBLK_CONFIG="$config_root/$fixture_name"
		mkdir "$ZNS_NULLBLK_CONFIG" 2>/dev/null && break
		ZNS_NULLBLK_CONFIG=
	done
	[ -n "$ZNS_NULLBLK_CONFIG" ] ||
		die "failed to allocate a unique null_blk configfs group"

	# Take ownership before configuring it. A failed write must still be cleaned
	# up by the suite's EXIT trap.
	ZNS_NULLBLK_OWNED=1
	ZNS_NULLBLK_PREVIOUS_UNDERLYING=$UNDERLYING

	printf '1\n' >"$ZNS_NULLBLK_CONFIG/zoned" ||
		die "failed to enable zoned mode on the null_blk fixture"
	printf '%s\n' "$zone_size_mb" >"$ZNS_NULLBLK_CONFIG/zone_size" ||
		die "failed to set the null_blk zone size"
	printf '%s\n' "$size_mb" >"$ZNS_NULLBLK_CONFIG/size" ||
		die "failed to set the null_blk size"
	printf '1\n' >"$ZNS_NULLBLK_CONFIG/memory_backed" ||
		die "failed to make the null_blk fixture memory-backed"
	if [ -n "$zone_capacity_mb" ]; then
		printf '%s\n' "$zone_capacity_mb" >"$ZNS_NULLBLK_CONFIG/zone_capacity" ||
			die "failed to set the null_blk zone capacity"
	fi
	if [ -n "${ZNS_NULLBLK_CACHE_SIZE_MB:-}" ]; then
		printf '%s\n' "$ZNS_NULLBLK_CACHE_SIZE_MB" >"$ZNS_NULLBLK_CONFIG/cache_size" ||
			die "failed to set the null_blk cache size"
	fi
	if [ -n "${ZNS_NULLBLK_FUA:-}" ]; then
		printf '%s\n' "$ZNS_NULLBLK_FUA" >"$ZNS_NULLBLK_CONFIG/fua" ||
			die "failed to set null_blk FUA support"
	fi
	printf '1\n' >"$ZNS_NULLBLK_CONFIG/power" ||
		die "failed to power on the null_blk fixture"

	index=$(cat "$ZNS_NULLBLK_CONFIG/index") ||
		die "failed to discover the null_blk fixture index"
	[[ $index =~ ^[0-9]+$ ]] || die "invalid null_blk fixture index: $index"

	# Configfs-backed null_blk instances are named after their configfs group on
	# current kernels. Older kernels used the numeric instance name instead, so
	# retain that form only as a compatibility fallback.
	named_dev="/dev/$fixture_name"
	indexed_dev="/dev/nullb$index"
	ZNS_NULLBLK_DEV=

	for attempt in $(seq 1 50); do
		if [ -b "$named_dev" ]; then
			ZNS_NULLBLK_DEV=$named_dev
			break
		fi
		if [ -b "$indexed_dev" ]; then
			ZNS_NULLBLK_DEV=$indexed_dev
			break
		fi
		sleep 0.1
	done
	[ -n "$ZNS_NULLBLK_DEV" ] ||
		die "neither $named_dev nor $indexed_dev appeared after the fixture was powered on"

	UNDERLYING=$ZNS_NULLBLK_DEV
	export UNDERLYING
	require_host_managed
	detail "underlying=$UNDERLYING size=${size_mb}MiB zone=${zone_size_mb}MiB capacity=${zone_capacity_mb:-$zone_size_mb}MiB"
}
