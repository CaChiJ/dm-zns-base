#!/usr/bin/env bash
# Parameterized direct-I/O matrix. Request size, operation, offset and queue
# depth are independent axes; every combination gets fresh media so an early
# ENOSPC cannot masquerade as a size-specific failure.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-request-size-matrix}
ZNS_REQUIRED_ENGINE=lsm
CAP_REQUEST_DEFAULT_SIZES="512 1k 1536 2k 2560 3584 4k 4608 8k 64k 1m"
CAP_REQUEST_SIZES=${CAP_REQUEST_SIZES:-$CAP_REQUEST_DEFAULT_SIZES}
CAP_REQUEST_OPERATIONS=${CAP_REQUEST_OPERATIONS:-"read write update randwrite"}
CAP_REQUEST_OFFSETS=${CAP_REQUEST_OFFSETS:-"0 512"}
CAP_REQUEST_IODEPTHS=${CAP_REQUEST_IODEPTHS:-"8"}
CAP_REQUEST_RANGE=${CAP_REQUEST_RANGE:-8m}
CAP_REQUEST_TIMEOUT=${CAP_REQUEST_TIMEOUT:-120}
CAP_REQUEST_DEVICE_MB=${CAP_REQUEST_DEVICE_MB:-256}
CAP_REQUEST_ZONE_MB=${CAP_REQUEST_ZONE_MB:-16}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/request-size-matrix"

require_root
require_commands make fio modprobe mountpoint dmsetup blkzone blockdev \
	timeout dd cmp truncate

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

parameter_list CAP_REQUEST_SIZES "$CAP_REQUEST_DEFAULT_SIZES" request_sizes
parameter_list CAP_REQUEST_OPERATIONS "read write update randwrite" operations
parameter_list CAP_REQUEST_OFFSETS "0 512" offsets
parameter_list CAP_REQUEST_IODEPTHS "8" iodepths

range_bytes=$(require_size_bytes "$CAP_REQUEST_RANGE" "request range")
for request_size in "${request_sizes[@]}"; do
	request_bytes=$(require_size_bytes "$request_size" "request size")
	[ $((request_bytes % 512)) -eq 0 ] ||
		die "direct block request size must be a multiple of 512 bytes: $request_size"
	[ "$request_bytes" -le "$range_bytes" ] ||
		die "request size $request_size exceeds range $CAP_REQUEST_RANGE"
done
for offset in "${offsets[@]}"; do
	offset_bytes=$(require_nonnegative_bytes "$offset" "request offset")
	[ $((offset_bytes % 512)) -eq 0 ] ||
		die "direct block offset must be a multiple of 512 bytes: $offset"
done
for operation in "${operations[@]}"; do
	case $operation in
	read|write|update|randwrite) ;;
	*) die "unsupported CAP_REQUEST_OPERATIONS value: $operation" ;;
	esac
done
for iodepth in "${iodepths[@]}"; do
	[[ $iodepth =~ ^[1-9][0-9]*$ ]] ||
		die "iodepth must be a positive integer: $iodepth"
done

create_nullblk_fixture "$CAP_REQUEST_DEVICE_MB" "$CAP_REQUEST_ZONE_MB"
build_engine
load_module
reset_zones
create_dm_target
target_sectors=$ZNS_TARGET_SECTORS_ACTIVE

fresh_target() {
	detach_dm_target
	reset_zones
	create_dm_target "$target_sectors"
}

run_matrix_fio() {
	local log=$1 job_name=$2
	shift 2

	if timeout "$CAP_REQUEST_TIMEOUT" fio --name="$job_name" \
		--filename="$DM_DEV" --ioengine=libaio --direct=1 "$@" \
		>"$log" 2>&1; then
		return 0
	fi
	tail -n 25 "$log" >&2
	fail "fio job $job_name failed or exceeded ${CAP_REQUEST_TIMEOUT}s"
}

capture_direct_span() {
	local output=$1 start=$2 length=$3

	if ! timeout "$CAP_REQUEST_TIMEOUT" dd if="$DM_DEV" of="$output" \
		bs=4096 skip="$start" count="$length" \
		iflag=direct,skip_bytes,count_bytes status=none; then
		fail "failed to capture direct span start=$start length=$length"
	fi
}

assert_update_neighbors_preserved() {
	local before=$1 after=$2 prefix_bytes=$3 suffix_offset=$4 span_bytes=$5
	local suffix_bytes=$((span_bytes - suffix_offset))

	if [ "$prefix_bytes" -gt 0 ] &&
	   ! cmp -n "$prefix_bytes" "$before" "$after" >/dev/null 2>&1; then
		fail "update damaged $prefix_bytes byte(s) before its requested range"
	fi
	if [ "$suffix_bytes" -gt 0 ] &&
	   ! cmp -i "$suffix_offset" -n "$suffix_bytes" "$before" "$after" \
		>/dev/null 2>&1; then
		fail "update damaged $suffix_bytes byte(s) after its requested range"
	fi
}

case_request_combination() {
	local operation=$1 request_size=$2 offset=$3 iodepth=$4
	local request_bytes offset_bytes case_bytes
	local baseline_start baseline_end baseline_bytes prefix_bytes suffix_offset
	local neighbor_bytes
	local job_name log fio_rw

	request_bytes=$(size_to_bytes "$request_size")
	offset_bytes=$(size_to_bytes "$offset")
	case_bytes=$((range_bytes / request_bytes * request_bytes))
	[ "$case_bytes" -gt 0 ] || fail "range rounded below one request"

	fresh_target
	io_errors_save "$tmp_dir/io-errors"
	job_name="request-${operation}-${request_bytes}-${offset_bytes}-${iodepth}"
	log="$tmp_dir/$job_name.log"

	if [ "$operation" = read ]; then
		truncate -s "$case_bytes" "$tmp_dir/$job_name.expected"
		if ! timeout "$CAP_REQUEST_TIMEOUT" dd if="$DM_DEV" \
			of="$tmp_dir/$job_name.actual" bs="$request_bytes" \
			skip="$offset_bytes" count="$case_bytes" \
			iflag=direct,skip_bytes,count_bytes status=none; then
			fail "direct read failed or exceeded ${CAP_REQUEST_TIMEOUT}s"
		fi
		assert_files_equal "$tmp_dir/$job_name.expected" \
			"$tmp_dir/$job_name.actual" "unmapped range was not zero-filled"
	elif [ "$operation" = update ]; then
		baseline_start=$((offset_bytes / 4096 * 4096))
		baseline_end=$((((offset_bytes + case_bytes + 4095) / 4096) * 4096))
		baseline_bytes=$((baseline_end - baseline_start))
		run_matrix_fio "$tmp_dir/$job_name-baseline.log" \
			"$job_name-baseline" --rw=write --bs=4k \
			--offset="$baseline_start" --size="$baseline_bytes" \
			--iodepth=8 --verify=crc32c --verify_fatal=1 \
			--verify_state_save=0
		prefix_bytes=$((offset_bytes - baseline_start))
		suffix_offset=$((offset_bytes + case_bytes - baseline_start))
		neighbor_bytes=$((prefix_bytes + baseline_bytes - suffix_offset))
		if [ "$neighbor_bytes" -gt 0 ]; then
			capture_direct_span "$tmp_dir/$job_name.before" \
				"$baseline_start" "$baseline_bytes"
		fi
	fi

	if [ "$operation" != read ]; then
		case $operation in
		write) fio_rw=write ;;
		update|randwrite) fio_rw=randwrite ;;
		esac
		run_matrix_fio "$log" "$job_name" --rw="$fio_rw" \
			--bs="$request_bytes" --offset="$offset_bytes" \
			--size="$case_bytes" --iodepth="$iodepth" \
			--verify=crc32c --verify_fatal=1 --verify_state_save=0
	fi
	if [ "$operation" = update ] && [ "$neighbor_bytes" -gt 0 ]; then
		capture_direct_span "$tmp_dir/$job_name.after" \
			"$baseline_start" "$baseline_bytes"
		assert_update_neighbors_preserved "$tmp_dir/$job_name.before" \
			"$tmp_dir/$job_name.after" "$prefix_bytes" "$suffix_offset" \
			"$baseline_bytes"
	fi
	assert_no_new_io_errors "$tmp_dir/io-errors"
	if [ "$operation" = update ]; then
		detail "op=$operation request=$request_bytes range=$case_bytes" \
			"offset=$offset_bytes depth=$iodepth preserved_neighbors=$neighbor_bytes"
	else
		detail "op=$operation request=$request_bytes range=$case_bytes" \
			"offset=$offset_bytes depth=$iodepth"
	fi
}

for operation in "${operations[@]}"; do
	for request_size in "${request_sizes[@]}"; do
		for offset in "${offsets[@]}"; do
			for iodepth in "${iodepths[@]}"; do
				case_name="when op=$operation request=$request_size offset=$offset depth=$iodepth, data verifies"
				[ "$operation" != update ] || \
					case_name="when op=update request=$request_size offset=$offset depth=$iodepth, data and enclosing neighbors verify"
				run_case "$case_name" \
					case_request_combination "$operation" "$request_size" \
					"$offset" "$iodepth"
			done
		done
	done
done

report_summary
