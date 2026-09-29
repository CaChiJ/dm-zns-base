#!/usr/bin/env bash
# M3: fill 80% of usable logical capacity, then overwrite the same range by
# 120% of capacity. Run the identical fio workload for both build policies.
# shellcheck source=tests/lib/init.sh
set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-m3-acceptance}
# Used by the sourced test helpers.
# shellcheck disable=SC2034
ZNS_REQUIRED_ENGINE=lsm
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "acceptance/m3"
require_root
require_commands make dmsetup blkzone blockdev fio jq
require_host_managed
require_zones 3

trap teardown_target EXIT
tmp_dir=$(mktemp -d)
capacity_sectors=$(usable_sectors)
capacity_bytes=$((capacity_sectors * 512))
fio_block_bytes=65536
if [ "$capacity_bytes" -ge $((1024 * 1024 * 1024)) ]; then
	fio_block_bytes=1048576
fi
fio_block_bytes=${FIO_BLOCK_BYTES:-$fio_block_bytes}
range_bytes=$(( (capacity_bytes * 4 / 5 / fio_block_bytes) * fio_block_bytes ))
overwrite_bytes=$(( (capacity_bytes * 6 / 5 / fio_block_bytes) * fio_block_bytes ))
[ "$range_bytes" -gt 0 ] || die "usable capacity is too small"

fio_job() {
	local name=$1 output=$2
	shift 2
	fio --name="$name" --filename="$DM_DEV" --ioengine=libaio \
		--direct=1 --iodepth=16 --bs="$fio_block_bytes" --size="$range_bytes" \
		--verify=crc32c --verify_fatal=1 --verify_state_save=0 \
		--output-format=json --output="$output" "$@" \
		2>"$tmp_dir/$name.stderr"
}

prepare_policy() {
	ZNS_GC_POLICY=$1
	export ZNS_GC_POLICY
	build_engine lsm
	load_module
	reset_zones
	create_dm_target
	[ "$(blockdev --getsize64 "$DM_DEV")" -eq "$capacity_bytes" ] ||
		fail "DM capacity does not exclude metadata and reserve zones"
	[ "$(status_field gc_policy)" = "$1" ] ||
		fail "wrong GC policy is loaded"
}

check_fio_success() {
	local output=$1 expected=$2
	jq -e --argjson expected "$expected" \
		'.jobs[0].error == 0 and .jobs[0].write.io_bytes >= $expected' \
		"$output" >/dev/null ||
		fail "fio did not complete $expected bytes: $(jq -c '{error: .jobs[0].error, write: .jobs[0].write.io_bytes}' "$output")"
}

check_fio_read_success() {
	local output=$1
	jq -e --argjson expected "$range_bytes" \
		'.jobs[0].error == 0 and .jobs[0].read.io_bytes >= $expected' \
		"$output" >/dev/null || fail "fio readback was incomplete"
}

case_simple() {
	fio_job simple-fill "$tmp_dir/simple-fill.json" --rw=write ||
		fail "simple fill failed"
	check_fio_success "$tmp_dir/simple-fill.json" "$range_bytes"
	fio_job simple-overwrite "$tmp_dir/simple-overwrite.json" \
		--rw=randwrite --io_size="$overwrite_bytes" \
		--norandommap=1 --randrepeat=1 --randseed=314159 ||
		fail "simple overwrite or latest-data verification failed"
	check_fio_success "$tmp_dir/simple-overwrite.json" "$overwrite_bytes"
	fio_job simple-readback "$tmp_dir/simple-readback.json" --rw=read --verify_only=1 ||
		fail "simple readback failed"
	check_fio_read_success "$tmp_dir/simple-readback.json"
	[ "$(status_field gc_moved)" -gt 0 ] || fail "GC moved no valid data"
	[ "$(status_field zone_resets)" -gt 0 ] || fail "GC reset no data zone"
	[ "$(status_field valid_blocks)" -eq "$((range_bytes / 4096))" ] ||
		fail "live block count changed during GC"
	detail "policy=simple capacity=$capacity_bytes range=$range_bytes overwrite=$overwrite_bytes moved=$(status_field gc_moved) resets=$(status_field zone_resets)"
	detach_dm_target
	# shellcheck disable=SC2034
	ZNS_TARGET_CREATED=0
	create_dm_target
	# Every block in the range carries a fio CRC header. Re-read after the
	# normal detach/reattach to exercise reconstructed GC validity state.
	fio_job simple-restart-read "$tmp_dir/simple-restart-read.json" \
		--rw=read --verify_only=1 || fail "readback after restart failed"
	check_fio_read_success "$tmp_dir/simple-restart-read.json"
	[ "$(status_field valid_blocks)" -eq "$((range_bytes / 4096))" ] ||
		fail "validity map was not restored"
}

case_none() {
	fio_job none-fill "$tmp_dir/none-fill.json" --rw=write ||
		fail "none fill failed"
	check_fio_success "$tmp_dir/none-fill.json" "$range_bytes"
	if fio_job none-overwrite "$tmp_dir/none-overwrite.json" \
		--rw=randwrite --io_size="$overwrite_bytes" \
		--norandommap=1 --randrepeat=1 --randseed=314159 \
		--do_verify=0; then
		fail "GC-disabled control completed the overwrite"
	fi
	if ! jq -e '.jobs[0].error == 28' "$tmp_dir/none-overwrite.json" >/dev/null; then
		tail -n 20 "$tmp_dir/none-overwrite.stderr" >&2
		head -n 8 "$tmp_dir/none-overwrite.json" >&2
		fail "control did not report ENOSPC"
	fi
	[ "$(status_field gc_moved)" -eq 0 ] || fail "none policy moved data"
	[ "$(status_field zone_resets)" -eq 0 ] || fail "none policy reset a zone"
	detail "policy=none error=ENOSPC capacity=$capacity_bytes"
}

prepare_policy simple
run_case "simple GC completes 0.8C fill plus 1.2C random overwrite, verifies data, moves blocks and resets zones" case_simple
[ "$ZNS_FAILED" -eq 0 ] || { report_summary; exit 1; }
detach_dm_target
unload_module
# shellcheck disable=SC2034
ZNS_MODULE_LOADED=0
prepare_policy none
run_case "the same engine with policy none ends the same overwrite at ENOSPC" case_none
report_summary
