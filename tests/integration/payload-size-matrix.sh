#!/usr/bin/env bash
# Exact-byte application payload matrix. Buffered writes make 1-byte payloads
# expressible even though the raw block layer cannot carry a sub-sector bio;
# verification reopens the encompassing 4 KiB range with O_DIRECT.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-payload-size-matrix}
ZNS_REQUIRED_ENGINE=lsm
CAP_PAYLOAD_DEFAULT_SIZES="1 2 7 255 511 512 513 1023 1k 1536 2k 3584 4095 4k 4097 8k 64k 1m 16m 100m 256m"
CAP_PAYLOAD_SIZES=${CAP_PAYLOAD_SIZES:-$CAP_PAYLOAD_DEFAULT_SIZES}
CAP_PAYLOAD_OPERATIONS=${CAP_PAYLOAD_OPERATIONS:-"write update randwrite"}
CAP_PAYLOAD_OFFSETS=${CAP_PAYLOAD_OFFSETS:-"1"}
CAP_PAYLOAD_EXACT_REQUEST_MAX=${CAP_PAYLOAD_EXACT_REQUEST_MAX:-1m}
CAP_PAYLOAD_RANDOM_REQUEST_MAX=${CAP_PAYLOAD_RANDOM_REQUEST_MAX:-64k}
CAP_PAYLOAD_TIMEOUT=${CAP_PAYLOAD_TIMEOUT:-300}
CAP_PAYLOAD_DEVICE_MB=${CAP_PAYLOAD_DEVICE_MB:-1024}
CAP_PAYLOAD_ZONE_MB=${CAP_PAYLOAD_ZONE_MB:-64}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/payload-size-matrix"

require_root
require_commands make modprobe mountpoint dmsetup blkzone blockdev timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

parameter_list CAP_PAYLOAD_SIZES "$CAP_PAYLOAD_DEFAULT_SIZES" payload_sizes
parameter_list CAP_PAYLOAD_OPERATIONS "write update randwrite" operations
parameter_list CAP_PAYLOAD_OFFSETS "1" offsets

exact_request_max=$(require_size_bytes "$CAP_PAYLOAD_EXACT_REQUEST_MAX" \
	"exact request maximum")
random_request_max=$(require_size_bytes "$CAP_PAYLOAD_RANDOM_REQUEST_MAX" \
	"random request maximum")
for payload_size in "${payload_sizes[@]}"; do
	require_size_bytes "$payload_size" "payload size" >/dev/null
done
for offset in "${offsets[@]}"; do
	require_nonnegative_bytes "$offset" "payload offset" >/dev/null
done
for operation in "${operations[@]}"; do
	case $operation in
	write|update|randwrite) ;;
	*) die "unsupported CAP_PAYLOAD_OPERATIONS value: $operation" ;;
	esac
done

create_nullblk_fixture "$CAP_PAYLOAD_DEVICE_MB" "$CAP_PAYLOAD_ZONE_MB"
build_test_tools
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

case_payload_combination() {
	local operation=$1 payload_size=$2 offset=$3
	local payload_bytes offset_bytes range_bytes request_bytes
	local seed=0x5041594c4f4144

	payload_bytes=$(size_to_bytes "$payload_size")
	offset_bytes=$(size_to_bytes "$offset")
	fresh_target
	io_errors_save "$tmp_dir/io-errors"

	case $operation in
	write|update)
		request_bytes=$payload_bytes
		[ "$request_bytes" -le "$exact_request_max" ] ||
			request_bytes=$exact_request_max
		timeout "$CAP_PAYLOAD_TIMEOUT" "$ZNS_TOOLS_DIR/byte-io" \
			"$operation" "$DM_DEV" "$offset_bytes" "$payload_bytes" \
			"$request_bytes" "$seed" ||
			fail "$operation payload failed or timed out"
		range_bytes=$payload_bytes
		;;
	randwrite)
		range_bytes=$payload_bytes
		[ "$range_bytes" -ge 4096 ] || range_bytes=4096
		request_bytes=$payload_bytes
		[ "$request_bytes" -le "$random_request_max" ] ||
			request_bytes=$random_request_max
		timeout "$CAP_PAYLOAD_TIMEOUT" "$ZNS_TOOLS_DIR/byte-io" \
			randwrite "$DM_DEV" "$offset_bytes" "$range_bytes" \
			"$request_bytes" "$payload_bytes" "$seed" ||
			fail "randwrite payload failed or timed out"
		;;
	esac

	assert_no_new_io_errors "$tmp_dir/io-errors"
	detail "op=$operation payload=$payload_bytes request_max=$request_bytes" \
		"range=$range_bytes offset=$offset_bytes"
}

for operation in "${operations[@]}"; do
	for payload_size in "${payload_sizes[@]}"; do
		for offset in "${offsets[@]}"; do
			case_name="when op=$operation payload=$payload_size offset=$offset, exact bytes and neighbors verify"
			run_case "$case_name" \
				case_payload_combination "$operation" "$payload_size" \
				"$offset"
		done
	done
done

report_summary
