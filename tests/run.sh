#!/usr/bin/env bash
# Single entry point for the dm-zns-base test suite.
#
#   sudo bash tests/run.sh                 required profile
#   sudo bash tests/run.sh extended        broader compatibility/stress gates
#   sudo bash tests/run.sh future          not-yet-supported contracts
#   sudo bash tests/run.sh integration     every integration-layer suite
#   sudo bash tests/run.sh all             every registered suite
#   sudo bash tests/run.sh sstable-flush   one suite by name
#   bash tests/run.sh --list               profile, layer, and suite inventory
#
# Env: UNDERLYING (default /dev/nullb0), ZNS_ENGINE (default lsm),
#      VERBOSE=1 for per-step logs, NO_COLOR to drop the colours.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZNS_MANIFEST="$TESTS_DIR/suites.tsv"
# shellcheck source=support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

ZNS_LAYERS=(unit integration system)
ZNS_PROFILES=(required extended future)
ZNS_SUITES=()
declare -A ZNS_SUITE_PROFILE=()
declare -A ZNS_SUITE_BUILD=()

usage() {
	sed -n '2,11p' "$TESTS_DIR/run.sh" | sed 's/^# \{0,1\}//'
}

runner_error() {
	printf 'test runner: %s\n' "$*" >&2
	exit 1
}

known_value() {
	local wanted=$1
	shift
	local value

	for value in "$@"; do
		[ "$value" = "$wanted" ] && return 0
	done
	return 1
}

load_manifest() {
	local profile build relative extra layer path
	local -A registered=()

	[ -f "$ZNS_MANIFEST" ] || runner_error "missing manifest: $ZNS_MANIFEST"
	while read -r profile build relative extra; do
		case ${profile:-} in
		""|\#*) continue ;;
		esac
		[ -z "${extra:-}" ] || runner_error "invalid manifest row: $profile $build $relative $extra"
		known_value "$profile" "${ZNS_PROFILES[@]}" ||
			runner_error "unknown profile '$profile' for $relative"
		case $build in
		standard|testing) ;;
		*) runner_error "unknown build mode '$build' for $relative" ;;
		esac
		layer=${relative%%/*}
		known_value "$layer" "${ZNS_LAYERS[@]}" ||
			runner_error "suite is outside a test layer: $relative"
		case $relative in
		"$layer"/*.sh) ;;
		*) runner_error "suite must be one shell file below its layer: $relative" ;;
		esac
		path="$TESTS_DIR/$relative"
		[ -f "$path" ] || runner_error "manifest suite is missing: $relative"
		[ -z "${registered[$relative]:-}" ] ||
			runner_error "duplicate manifest suite: $relative"

		registered[$relative]=1
		ZNS_SUITES+=("$relative")
		ZNS_SUITE_PROFILE[$relative]=$profile
		ZNS_SUITE_BUILD[$relative]=$build
	done <"$ZNS_MANIFEST"

	for layer in "${ZNS_LAYERS[@]}"; do
		while IFS= read -r path; do
			relative=${path#"$TESTS_DIR/"}
			[ -n "${registered[$relative]:-}" ] ||
				runner_error "unregistered suite: $relative"
		done < <(find "$TESTS_DIR/$layer" -maxdepth 1 -type f -name '*.sh' | sort)
	done
}

suite_label() {
	local path=$1
	local relative=${path#"$TESTS_DIR/"}

	printf '%s\n' "${relative%.sh}"
}

list_inventory() {
	local relative layer

	printf '%-10s %-12s %s\n' PROFILE LAYER SUITE
	for relative in "${ZNS_SUITES[@]}"; do
		layer=${relative%%/*}
		printf '%-10s %-12s %s\n' \
			"${ZNS_SUITE_PROFILE[$relative]}" "$layer" "${relative%.sh}"
	done
}

list_profile() {
	local wanted=$1 relative

	for relative in "${ZNS_SUITES[@]}"; do
		[ "${ZNS_SUITE_PROFILE[$relative]}" = "$wanted" ] || continue
		printf '%s\n' "$TESTS_DIR/$relative"
	done
}

list_layer() {
	local wanted=$1 relative

	for relative in "${ZNS_SUITES[@]}"; do
		[ "${relative%%/*}" = "$wanted" ] || continue
		printf '%s\n' "$TESTS_DIR/$relative"
	done
}

list_all() {
	local relative

	for relative in "${ZNS_SUITES[@]}"; do
		printf '%s\n' "$TESTS_DIR/$relative"
	done
}

# Resolve a profile, layer, suite name, or registered path into suite paths.
resolve_argument() {
	local argument=$1 relative path matches=0

	if known_value "$argument" "${ZNS_PROFILES[@]}"; then
		list_profile "$argument"
		return 0
	fi
	if known_value "$argument" "${ZNS_LAYERS[@]}"; then
		list_layer "$argument"
		return 0
	fi
	if [ "$argument" = all ]; then
		list_all
		return 0
	fi

	if [ -f "$argument" ]; then
		path=$(cd "$(dirname "$argument")" && pwd)/$(basename "$argument")
		relative=${path#"$TESTS_DIR/"}
		[ -n "${ZNS_SUITE_PROFILE[$relative]:-}" ] || return 1
		printf '%s\n' "$path"
		return 0
	fi

	for relative in "${ZNS_SUITES[@]}"; do
		case ${relative%.sh} in
		"$argument"|*/"$argument")
			printf '%s\n' "$TESTS_DIR/$relative"
			matches=$((matches + 1))
			;;
		esac
	done
	[ "$matches" -gt 0 ]
}

print_summary() {
	local result_file=$1 layer passed failed total_failed=0 total=0

	printf '\n%s=== summary ===%s\n' "$ZNS_BOLD" "$ZNS_RESET"

	for layer in "${ZNS_LAYERS[@]}"; do
		passed=$(grep -c $'^PASS\t'"$layer/" "$result_file" || true)
		failed=$(grep -c $'^FAIL\t'"$layer/" "$result_file" || true)
		total=$((passed + failed))
		[ "$total" -eq 0 ] && continue
		total_failed=$((total_failed + failed))
		printf '%-14s %s%3d passed%s  %s%3d failed%s\n' \
			"$layer" \
			"$ZNS_GREEN" "$passed" "$ZNS_RESET" \
			"$ZNS_RED" "$failed" "$ZNS_RESET"
	done

	if [ "$total_failed" -eq 0 ]; then
		printf '\n%s[PASS]%s every case passed\n' "$ZNS_GREEN" "$ZNS_RESET"
		return 0
	fi

	printf '\n%s[FAIL]%s %d case(s) failed:\n' \
		"$ZNS_RED" "$ZNS_RESET" "$total_failed"
	awk -F'\t' '$1 == "FAIL" { printf "  %-32s %s\n", $2, $3 }' "$result_file"
	return 1
}

run_selected_suite() {
	local suite_path=$1 label before after status

	label=$(suite_label "$suite_path")
	before=$(wc -l <"$ZNS_RESULT_FILE")

	bash "$suite_path"
	status=$?

	after=$(wc -l <"$ZNS_RESULT_FILE")
	if [ "$status" -ne 0 ] && [ "$after" -eq "$before" ]; then
		printf '%s[FAIL]%s %s | reason=suite_aborted exit=%d\n' \
			"$ZNS_RED" "$ZNS_RESET" "$label" "$status"
		printf 'FAIL\t%s\tsuite aborted\texit=%d\n' "$label" "$status" \
			>>"$ZNS_RESULT_FILE"
	fi
}

# A standard suite must never inherit the compile-time testing instrumentation
# merely because the same command also selected a future suite. Run each build
# mode as its own phase and let build_engine() rebuild at the mode boundary.
run_build_phase() {
	local build_mode=$1
	shift
	local phase_suites=("$@")
	local suite_path relative layer
	local needs_engine=0 needs_unit=0

	[ "${#phase_suites[@]}" -gt 0 ] || return 0
	case $build_mode in
	standard) ZNS_TESTING=0 ;;
	testing) ZNS_TESTING=1 ;;
	*) runner_error "cannot run unknown build mode: $build_mode" ;;
	esac
	export ZNS_TESTING
	ZNS_SUITE="run/$build_mode"

	for suite_path in "${phase_suites[@]}"; do
		relative=${suite_path#"$TESTS_DIR/"}
		layer=${relative%%/*}
		[ "$layer" = unit ] && needs_unit=1 || needs_engine=1
	done

	if [ "$build_mode" = testing ]; then
		build_test_tools
	fi
	if [ "$needs_engine" -eq 1 ]; then
		build_engine "$ZNS_ENGINE"
	fi
	if [ "$needs_unit" -eq 1 ]; then
		build_unit_modules
	fi

	for suite_path in "${phase_suites[@]}"; do
		run_selected_suite "$suite_path"
	done
}

load_manifest

case "${1:---help}" in
--list|-l)
	list_inventory
	exit 0
	;;
--help|-h)
	usage
	printf '\nprofiles: required, extended, future\n'
	printf 'layers:   unit, integration, system\n'
	exit 0
	;;
esac

selected=()
declare -A selected_seen=()
if [ "$#" -eq 0 ]; then
	mapfile -t selected < <(list_profile required)
else
	for argument in "$@"; do
		matches=$(resolve_argument "$argument") || {
			printf 'unknown profile, layer, or suite: %s\n' "$argument" >&2
			printf 'run "bash tests/run.sh --list" to see what is available\n' >&2
			exit 1
		}
		while IFS= read -r match; do
			[ -n "$match" ] || continue
			[ -z "${selected_seen[$match]:-}" ] || continue
			selected_seen[$match]=1
			selected+=("$match")
		done <<<"$matches"
	done
fi

[ "$(id -u)" -eq 0 ] || {
	printf '%s[FAIL]%s run as root: sudo bash tests/run.sh %s\n' \
		"$ZNS_RED" "$ZNS_RESET" "$*" >&2
	exit 1
}

ZNS_RESULT_FILE=$(mktemp)
export ZNS_RESULT_FILE
trap 'rm -f "$ZNS_RESULT_FILE"' EXIT

standard_selected=()
testing_selected=()
for suite_path in "${selected[@]}"; do
	relative=${suite_path#"$TESTS_DIR/"}
	case ${ZNS_SUITE_BUILD[$relative]} in
	standard) standard_selected+=("$suite_path") ;;
	testing) testing_selected+=("$suite_path") ;;
	esac
done

run_build_phase standard "${standard_selected[@]}"
run_build_phase testing "${testing_selected[@]}"

print_summary "$ZNS_RESULT_FILE"
