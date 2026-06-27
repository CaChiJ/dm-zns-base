#!/usr/bin/env bash
# Randwrite regression suite.
# Default output is one PASS/FAIL line per case. Set VERBOSE=1 to show fio logs.

set -u

DM_NAME=${DM_NAME:-myzns-base}
DM_DEV=${DM_DEV:-/dev/mapper/$DM_NAME}
VERBOSE=${VERBOSE:-0}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	GREEN=$(printf '\033[32m')
	RED=$(printf '\033[31m')
	RESET=$(printf '\033[0m')
else
	GREEN=
	RED=
	RESET=
fi

count_blk_errors() {
	sudo dmesg | grep -Ec 'blk_update_request|I/O error' || true
}

run_fio_case() {
	local case_name=$1
	local size=$2
	local bs=$3
	local iodepth=$4
	local filename=$5
	shift 5

	local before after delta fio_status log fio_name

	fio_name=$(printf '%s' "$case_name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '_')

	before=$(count_blk_errors)
	log=$(mktemp)

	if [ "$VERBOSE" = "1" ]; then
		echo
		echo "[RUN] $case_name"
		echo "fio: name=$fio_name size=$size bs=$bs iodepth=$iodepth filename=$filename $*"
		sudo fio --name="$fio_name" --filename="$filename" --rw=randwrite \
			--bs="$bs" --size="$size" --ioengine=libaio \
			--iodepth="$iodepth" --direct=1 "$@" 2>&1 | tee "$log"
		fio_status=${PIPESTATUS[0]}
	else
		sudo fio --name="$fio_name" --filename="$filename" --rw=randwrite \
			--bs="$bs" --size="$size" --ioengine=libaio \
			--iodepth="$iodepth" --direct=1 "$@" >"$log" 2>&1
		fio_status=$?
	fi

	after=$(count_blk_errors)
	delta=$((after - before))
	rm -f "$log"

	if [ "$fio_status" -eq 0 ] && [ "$delta" -eq 0 ]; then
		printf '%s[PASS]%s %-64s size=%-6s bs=%-4s iodepth=%-2s delta=%s\n' \
			"$GREEN" "$RESET" "$case_name" "$size" "$bs" "$iodepth" "$delta"
		return 0
	fi

	printf '%s[FAIL]%s %-64s fio_status=%s delta=%s\n' \
		"$RED" "$RESET" "$case_name" "$fio_status" "$delta"
	return 1
}

if [ ! -b "$DM_DEV" ]; then
	printf '%s[FAIL]%s %s does not exist. Run ./scripts/build-run.sh first.\n' \
		"$RED" "$RESET" "$DM_DEV" >&2
	exit 1
fi

failures=0

run_fio_case "when 4KiB randwrites cover 4MiB, they complete" 4M 4k 32 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when 4KiB randwrites cover 32MiB, append continues" 32M 4k 32 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when 4KiB randwrites cover 100MiB, append continues" 100M 4k 32 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 1KiB, randwrites complete" 64M 1k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 2KiB, randwrites complete" 64M 2k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 4KiB, native mapping is used" 64M 4k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 8KiB, DM splits them into 4KiB writes" 64M 8k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 16KiB, DM splits them into 4KiB writes" 64M 16k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when requests are 64KiB, DM splits them into 4KiB writes" 64M 64k 8 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when queue depth is 1, serial 4KiB writes complete" 64M 4k 1 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when queue depth is 32, concurrent 4KiB writes complete" 64M 4k 32 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when queue depth is 64, concurrent 4KiB writes complete" 64M 4k 64 "$DM_DEV" || failures=$((failures + 1))
run_fio_case "when logical blocks are overwritten, latest mapping wins" 32M 4k 8 "$DM_DEV" --loops=3 || failures=$((failures + 1))
run_fio_case "when randwrites are verified, reads return latest data" 32M 4k 8 "$DM_DEV" --verify=crc32c --verify_fatal=1 --verify_state_save=0 || failures=$((failures + 1))

if [ "$failures" -eq 0 ]; then
	echo
	printf '%s[PASS]%s test-randwrite: all cases passed\n' "$GREEN" "$RESET"
	exit 0
fi

echo
printf '%s[FAIL]%s test-randwrite: %s case(s) failed\n' "$RED" "$RESET" "$failures" >&2
exit 1
