#!/usr/bin/env bash
# Parameter sweep for random writes: workload size, request size, and queue
# depth. Behaviour that deserves its own judgement (write pointer progress,
# CRC read-after-write, overwrite ordering) lives in the dedicated suites,
# so every case here only asks whether the workload completes cleanly.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-randwrite-matrix}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "integration/randwrite-matrix"

require_root
require_commands make fio dmsetup blkzone blockdev
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target

# One fio run plus the kernel error delta it caused.
case_sweep() {
	local size=$1
	local bs=$2
	local iodepth=$3
	local job_name="matrix-${size}-${bs}-${iodepth}"

	io_errors_save "$tmp_dir/io-errors"
	run_fio "$tmp_dir/$job_name.log" "$job_name" \
		--rw=randwrite --bs="$bs" --size="$size" --iodepth="$iodepth"
	assert_no_new_io_errors "$tmp_dir/io-errors"
	detail "size=$size bs=$bs iodepth=$iodepth"
}

run_case "when 4 KiB randwrites cover 4 MiB, they complete" \
	case_sweep 4M 4k 32
run_case "when 4 KiB randwrites cover 32 MiB, the append continues" \
	case_sweep 32M 4k 32
run_case "when 4 KiB randwrites cover 100 MiB, the append continues" \
	case_sweep 100M 4k 32

# Sub-4 KiB requests are a real capability question, not an environment one:
# only rmw4k merges them, so append4k and lsm fail these two cases and say so.
run_case "when requests are 1 KiB, randwrites complete" \
	case_sweep 64M 1k 8
run_case "when requests are 2 KiB, randwrites complete" \
	case_sweep 64M 2k 8
run_case "when requests are 4 KiB, the native mapping size is used" \
	case_sweep 64M 4k 8
run_case "when requests are 8 KiB, DM splits them into 4 KiB writes" \
	case_sweep 64M 8k 8
run_case "when requests are 16 KiB, DM splits them into 4 KiB writes" \
	case_sweep 64M 16k 8
run_case "when requests are 64 KiB, DM splits them into 4 KiB writes" \
	case_sweep 64M 64k 8

run_case "when the queue depth is 1, serial 4 KiB writes complete" \
	case_sweep 64M 4k 1
run_case "when the queue depth is 32, concurrent 4 KiB writes complete" \
	case_sweep 64M 4k 32
run_case "when the queue depth is 64, concurrent 4 KiB writes complete" \
	case_sweep 64M 4k 64

report_summary
