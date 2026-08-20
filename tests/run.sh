#!/usr/bin/env bash
# Single entry point for the dm-zns-base test suite.
#
#   sudo bash tests/run.sh                 every suite
#   sudo bash tests/run.sh unit            one group
#   sudo bash tests/run.sh sstable-flush   one suite by name
#   bash tests/run.sh --list               what is available
#
# Env: UNDERLYING (default /dev/nullb0), ZNS_ENGINE (default lsm),
#      VERBOSE=1 for per-step logs, NO_COLOR to drop the colours.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/init.sh
source "$TESTS_DIR/lib/init.sh"

ZNS_GROUPS=(unit integration acceptance)

usage() {
	sed -n '2,10p' "$TESTS_DIR/run.sh" | sed 's/^# \{0,1\}//'
}

# Every runnable suite, in the order a full run should execute them:
# unit tests first, then integration, then acceptance.
list_suites() {
	local group files

	for group in "${ZNS_GROUPS[@]}"; do
		files=$(find "$TESTS_DIR/$group" -maxdepth 1 -name '*.sh' \
			-type f | sort)
		[ -n "$files" ] || continue
		# Smoke runs first so an obvious breakage shows up immediately.
		printf '%s\n' "$files" | grep '/smoke\.sh$' || true
		printf '%s\n' "$files" | grep -v '/smoke\.sh$' || true
	done
}

suite_label() {
	local path=$1
	local relative=${path#"$TESTS_DIR/"}

	printf '%s\n' "${relative%.sh}"
}

# Resolve one argument into suite paths: a group name, a suite name, or a path.
resolve_argument() {
	local argument=$1
	local group path matches

	for group in "${ZNS_GROUPS[@]}"; do
		if [ "$argument" = "$group" ]; then
			list_suites | grep "/$group/"
			return 0
		fi
	done

	if [ -f "$argument" ]; then
		printf '%s\n' "$(cd "$(dirname "$argument")" && pwd)/$(basename "$argument")"
		return 0
	fi

	matches=$(list_suites | grep -E "/($argument|$argument-test)\.sh$" || true)
	if [ -z "$matches" ]; then
		printf 'unknown suite: %s\n' "$argument" >&2
		printf 'run "bash tests/run.sh --list" to see what is available\n' >&2
		return 1
	fi
	printf '%s\n' "$matches"
}

print_summary() {
	local result_file=$1
	local group passed failed total_failed=0 total=0

	printf '\n%s=== summary ===%s\n' "$ZNS_BOLD" "$ZNS_RESET"

	for group in "${ZNS_GROUPS[@]}"; do
		passed=$(grep -c "^PASS	$group/" "$result_file" || true)
		failed=$(grep -c "^FAIL	$group/" "$result_file" || true)
		total=$((passed + failed))
		[ "$total" -eq 0 ] && continue
		total_failed=$((total_failed + failed))
		printf '%-14s %s%3d passed%s  %s%3d failed%s\n' \
			"$group" \
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

selected=()
case "${1:---help}" in
--list|-l)
	list_suites | while read -r path; do suite_label "$path"; done
	exit 0
	;;
--help|-h)
	usage
	printf '\nsuites:\n'
	list_suites | while read -r path; do printf '  %s\n' "$(suite_label "$path")"; done
	exit 0
	;;
esac

if [ "$#" -eq 0 ] || [ "$1" = all ]; then
	mapfile -t selected < <(list_suites)
else
	for argument in "$@"; do
		matches=$(resolve_argument "$argument") || exit 1
		while IFS= read -r match; do
			[ -n "$match" ] || continue
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

# Build once up front so the suites do not repeat a clean rebuild each.
ZNS_SUITE="run"
build_engine "$ZNS_ENGINE"
if printf '%s\n' "${selected[@]}" | grep -q '/unit/'; then
	build_unit_modules
fi

for suite_path in "${selected[@]}"; do
	label=$(suite_label "$suite_path")
	before=$(wc -l <"$ZNS_RESULT_FILE")

	bash "$suite_path"
	status=$?

	after=$(wc -l <"$ZNS_RESULT_FILE")
	if [ "$status" -ne 0 ] && [ "$after" -eq "$before" ]; then
		printf '%s[FAIL]%s %s exited with status %d before reporting a case\n' \
			"$ZNS_RED" "$ZNS_RESET" "$label" "$status"
		printf 'FAIL\t%s\tsuite aborted\texit=%d\n' "$label" "$status" \
			>>"$ZNS_RESULT_FILE"
	fi
done

print_summary "$ZNS_RESULT_FILE"
