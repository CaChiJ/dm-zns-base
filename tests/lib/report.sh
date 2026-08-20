#!/usr/bin/env bash
# Case-level result reporting shared by every dm-zns-base test.
#
# A test script calls report_init once, then run_case for each case,
# then report_summary. Cases run in a subshell with errexit enabled, so a case
# aborts on the first failing command just like a plain script would.
#
# Case contract: return 0 to pass, anything else to fail (use the fail helper,
# or just let a command fail). There is no third state on purpose -- a suite
# that could not run properly is a failure, not something to pass over.
# A case reports its reason on stderr and may write one extra "key=value"
# detail line to $ZNS_DETAIL_FILE.

[ -n "${ZNS_REPORT_SOURCED:-}" ] && return 0
ZNS_REPORT_SOURCED=1

ZNS_SUITE=""
ZNS_PASSED=0
ZNS_FAILED=0
ZNS_FAILED_CASES=()

VERBOSE=${VERBOSE:-0}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	ZNS_GREEN=$(printf '\033[32m')
	ZNS_RED=$(printf '\033[31m')
	ZNS_BOLD=$(printf '\033[1m')
	ZNS_DIM=$(printf '\033[2m')
	ZNS_RESET=$(printf '\033[0m')
else
	ZNS_GREEN=
	ZNS_RED=
	ZNS_BOLD=
	ZNS_DIM=
	ZNS_RESET=
fi

# Name the suite and print its header. Called once per test script.
report_init() {
	ZNS_SUITE=$1
	printf '\n%s=== %s ===%s\n' "$ZNS_BOLD" "$ZNS_SUITE" "$ZNS_RESET"
}

# Progress line for the steps inside a case. Quiet unless VERBOSE=1.
log_step() {
	[ "$VERBOSE" = "1" ] || return 0
	printf '%s[*] %s%s\n' "$ZNS_DIM" "$*" "$ZNS_RESET"
}

# Fail the current case with a reason.
fail() {
	printf '%s\n' "$*" >&2
	return 1
}

# Attach one short "key=value" detail to the current case's result line.
detail() {
	[ -n "${ZNS_DETAIL_FILE:-}" ] || return 0
	printf '%s\n' "$*" >"$ZNS_DETAIL_FILE"
}

# Append a machine-readable row when a runner is collecting results.
zns_record() {
	[ -n "${ZNS_RESULT_FILE:-}" ] || return 0
	printf '%s\t%s\t%s\t%s\n' "$1" "$ZNS_SUITE" "$2" "${3:-}" \
		>>"$ZNS_RESULT_FILE"
}

# Print one result line and count it. status is PASS or FAIL.
report_case() {
	local status=$1
	local name=$2
	local detail_text=${3:-}
	local color

	case $status in
	PASS)
		color=$ZNS_GREEN
		ZNS_PASSED=$((ZNS_PASSED + 1))
		;;
	FAIL)
		color=$ZNS_RED
		ZNS_FAILED=$((ZNS_FAILED + 1))
		ZNS_FAILED_CASES+=("$name")
		;;
	esac

	if [ -n "$detail_text" ]; then
		printf '%s[%s]%s %-68s %s\n' \
			"$color" "$status" "$ZNS_RESET" "$name" "$detail_text"
	else
		printf '%s[%s]%s %s\n' "$color" "$status" "$ZNS_RESET" "$name"
	fi

	zns_record "$status" "$name" "$detail_text"
	return 0
}

# Run one case function and report its result.
run_case() {
	local name=$1
	shift

	local status errexit=0
	local reason_file detail_file detail_text status_label

	case $- in
	*e*) errexit=1 ;;
	esac

	[ "$VERBOSE" = "1" ] &&
		printf '%s[RUN] %s%s\n' "$ZNS_DIM" "$name" "$ZNS_RESET"

	reason_file=$(mktemp)
	detail_file=$(mktemp)

	set +e
	(
		set -e
		ZNS_DETAIL_FILE=$detail_file
		export ZNS_DETAIL_FILE
		"$@"
	) 2>"$reason_file"
	status=$?
	[ "$errexit" -eq 1 ] && set -e

	detail_text=$(head -n 1 "$detail_file" 2>/dev/null || true)

	if [ "$status" -eq 0 ]; then
		status_label=PASS
	else
		status_label=FAIL
		# The reason lines below carry the explanation; the exit status
		# is only worth showing when the case said nothing at all.
		if [ -z "$detail_text" ] && [ ! -s "$reason_file" ]; then
			detail_text="ret=$status"
		fi
	fi

	report_case "$status_label" "$name" "$detail_text"

	if [ "$status_label" = FAIL ] || [ "$VERBOSE" = "1" ]; then
		sed -e '/^[[:space:]]*$/d' -e 's/^/        /' "$reason_file"
	fi

	rm -f "$reason_file" "$detail_file"
	return 0
}

# Report that the suite could not reach its cases at all.
report_setup_failure() {
	report_case FAIL "setup" "$1"
}

# Print the per-suite totals and return non-zero when a case failed.
# A runner that collects $ZNS_RESULT_FILE prints its own combined summary,
# so the per-suite block is suppressed there.
report_summary() {
	local name

	if [ -z "${ZNS_RESULT_FILE:-}" ]; then
		printf '\n%s--- %s ---%s\n' "$ZNS_BOLD" "$ZNS_SUITE" "$ZNS_RESET"
		printf '%s%d passed%s  %s%d failed%s\n' \
			"$ZNS_GREEN" "$ZNS_PASSED" "$ZNS_RESET" \
			"$ZNS_RED" "$ZNS_FAILED" "$ZNS_RESET"

		if [ "$ZNS_FAILED" -ne 0 ]; then
			printf '\n%s[FAIL]%s %d case(s) failed:\n' \
				"$ZNS_RED" "$ZNS_RESET" "$ZNS_FAILED"
			for name in "${ZNS_FAILED_CASES[@]}"; do
				printf '  %s\n' "$name"
			done
		fi
	fi

	[ "$ZNS_FAILED" -eq 0 ]
}
