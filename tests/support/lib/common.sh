#!/usr/bin/env bash
# Paths, preconditions, and module builds shared by every dm-zns-base test.
#
# Tests never call sudo themselves. The whole suite runs as root
# (sudo bash tests/run.sh ...) and builds as the invoking user so the build
# tree does not fill up with root-owned objects.

[ -n "${ZNS_COMMON_SOURCED:-}" ] && return 0
ZNS_COMMON_SOURCED=1

ZNS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZNS_SUPPORT_DIR=$(cd "$ZNS_LIB_DIR/.." && pwd)
ZNS_TESTS_DIR=$(cd "$ZNS_SUPPORT_DIR/.." && pwd)
ZNS_ROOT_DIR=$(cd "$ZNS_TESTS_DIR/.." && pwd)
ZNS_SRC_DIR="$ZNS_ROOT_DIR/src"
ZNS_UNIT_DIR="$ZNS_TESTS_DIR/unit"
ZNS_TOOLS_DIR="$ZNS_SUPPORT_DIR/tools"

ZNS_MOD_NAME=${ZNS_MOD_NAME:-dm-zns-base}
ZNS_KO_PATH="$ZNS_SRC_DIR/$ZNS_MOD_NAME.ko"

# Engine the test needs. A test script sets ZNS_REQUIRED_ENGINE before
# sourcing lib/init.sh; the environment still wins so a run can be retargeted.
ZNS_ENGINE=${ZNS_ENGINE:-${ZNS_REQUIRED_ENGINE:-lsm}}

UNDERLYING=${UNDERLYING:-/dev/nullb0}

# Abort the suite before its cases could run. Used only during setup.
die() {
	report_setup_failure "$*"
	exit 1
}

# Run a build step quietly, showing its output only when it fails or when
# VERBOSE=1 asks for it. Kbuild is noisy and its warnings are not results.
run_make() {
	local log status

	log=$(mktemp)
	as_build_user make "$@" >"$log" 2>&1
	status=$?
	if [ "$status" -ne 0 ] || [ "$VERBOSE" = "1" ]; then
		tail -n 30 "$log" >&2
	fi
	rm -f "$log"
	return "$status"
}

# Run a build step as the user behind sudo, so artifacts stay user-owned.
as_build_user() {
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] &&
	   command -v runuser >/dev/null; then
		runuser -u "$SUDO_USER" -- "$@"
	else
		"$@"
	fi
}

require_root() {
	[ "$(id -u)" -eq 0 ] ||
		die "run as root: sudo bash tests/run.sh"
}

require_commands() {
	local command_name

	for command_name in "$@"; do
		command -v "$command_name" >/dev/null ||
			die "required command is missing: $command_name"
	done
}

underlying_kernel_name() {
	basename "$(readlink -f "$UNDERLYING")"
}

underlying_attr() {
	cat "/sys/block/$(underlying_kernel_name)/queue/$1"
}

require_underlying() {
	[ -b "$UNDERLYING" ] ||
		die "$UNDERLYING is missing. Run scripts/nullblk-up.sh first."
}

require_host_managed() {
	local zoned

	require_underlying
	zoned=$(underlying_attr zoned) ||
		die "cannot read the zoned attribute of $UNDERLYING"
	[ "$zoned" = host-managed ] ||
		die "$UNDERLYING is not host-managed zoned"
}

require_zones() {
	local wanted=$1
	local nr_zones

	nr_zones=$(underlying_attr nr_zones) ||
		die "cannot read the zone count of $UNDERLYING"
	[ "$nr_zones" -ge "$wanted" ] ||
		die "$wanted zones are required, $UNDERLYING has $nr_zones"
}

# Build the DM module for one engine. Repeat calls for the same engine are
# free, so run.sh can build once and every child script skips the rebuild.
build_engine() {
	local engine=${1:-$ZNS_ENGINE}
	local build_key="$engine:${ZNS_TESTING:-0}"

	if [ "${ZNS_ENGINE_BUILT:-}" = "$build_key" ] && [ -f "$ZNS_KO_PATH" ]; then
		return 0
	fi

	log_step "building the $engine engine"
	run_make -C "$ZNS_SRC_DIR" clean ZNS_ENGINE="$engine" ||
		die "failed to clean the $engine build"
	run_make -C "$ZNS_SRC_DIR" ZNS_ENGINE="$engine" ||
		die "failed to build the $engine engine"
	[ -f "$ZNS_KO_PATH" ] ||
		die "the module was not produced: $ZNS_KO_PATH"

	ZNS_ENGINE_BUILT=$build_key
	export ZNS_ENGINE_BUILT
	return 0
}

build_test_tools() {
	if [ "${ZNS_TOOLS_BUILT:-}" = 1 ] &&
	   [ -x "$ZNS_TOOLS_DIR/versioned-io" ] &&
	   [ -x "$ZNS_TOOLS_DIR/byte-io" ]; then
		return 0
	fi

	log_step "building userspace test tools"
	run_make -C "$ZNS_TOOLS_DIR" || die "failed to build userspace test tools"
	[ -x "$ZNS_TOOLS_DIR/versioned-io" ] ||
		die "versioned-io was not produced"
	[ -x "$ZNS_TOOLS_DIR/byte-io" ] ||
		die "byte-io was not produced"

	ZNS_TOOLS_BUILT=1
	export ZNS_TOOLS_BUILT
}

# Build the standalone kernel test modules under tests/unit.
build_unit_modules() {
	if [ "${ZNS_UNIT_BUILT:-}" = 1 ]; then
		return 0
	fi

	log_step "building the unit test modules"
	run_make -C "$ZNS_UNIT_DIR" ||
		die "failed to build the unit test modules"

	ZNS_UNIT_BUILT=1
	export ZNS_UNIT_BUILT
	return 0
}

# Load a unit test module and turn its dmesg lines into case results.
#
# The module runs every case at init time and prints one parseable line per
# case. A marker written to /dev/kmsg bounds the region to parse, which is
# exact where "dmesg --since" would only have one-second granularity.
run_kernel_test_module() {
	local module_file=$1
	local module_name=$2
	local ko_path="$ZNS_UNIT_DIR/$module_file.ko"
	local marker insmod_status seen=0
	local status name description

	build_unit_modules
	[ -f "$ko_path" ] || die "missing $ko_path"

	rmmod "$module_name" 2>/dev/null || true

	marker="zns-test-marker-$$-$RANDOM"
	# The braces keep the shell's own redirection error quiet too.
	{ printf '%s\n' "$marker" >/dev/kmsg; } 2>/dev/null ||
		die "cannot write the dmesg marker to /dev/kmsg"

	if insmod "$ko_path" 2>/dev/null; then
		insmod_status=0
	else
		insmod_status=$?
	fi
	rmmod "$module_name" 2>/dev/null || true

	while IFS=$'\t' read -r status name description; do
		[ -n "$status" ] || continue
		seen=1
		if [ "$status" = PASS ]; then
			report_case PASS "$description"
		else
			report_case FAIL "$description" "case=$name"
		fi
	done < <(dmesg |
		awk -v marker="$marker" 'found; index($0, marker) { found = 1 }' |
		sed -n 's/.*case=\([^ ]*\) result=\(PASS\|FAIL\).*desc=\(.*\)$/\2\t\1\t\3/p')

	if [ "$seen" -eq 0 ]; then
		die "the module printed no case results (insmod exit $insmod_status)"
	fi

	return 0
}
