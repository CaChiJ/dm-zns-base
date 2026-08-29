#!/usr/bin/env bash
# A short deterministic stress gate: disjoint writers force many flushes while
# status is sampled, then clean detach/recreate cycles verify lifecycle order.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-concurrency}
ZNS_REQUIRED_ENGINE=lsm
CONCURRENCY_SIZE_MB=${CONCURRENCY_SIZE_MB:-128}
CONCURRENCY_ZONE_MB=${CONCURRENCY_ZONE_MB:-4}
CONCURRENCY_TIMEOUT=${CONCURRENCY_TIMEOUT:-60}
LIFECYCLE_CYCLES=${LIFECYCLE_CYCLES:-10}
TEST_THRESHOLD=${TEST_THRESHOLD:-64}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/concurrency-lifecycle"

require_root
require_commands make modprobe dmsetup blkzone blockdev fio dd cmp timeout

tmp_dir=$(mktemp -d)
trap teardown_target EXIT

create_nullblk_fixture "$CONCURRENCY_SIZE_MB" "$CONCURRENCY_ZONE_MB"
build_engine
load_module memtable_threshold="$TEST_THRESHOLD"
reset_zones
create_dm_target
require_status_fields active immutable flushing sstables sst_entries meta_used
io_errors_save "$tmp_dir/io-errors"

wait_for_flush_idle() {
	local deadline=$((SECONDS + CONCURRENCY_TIMEOUT))
	local immutable flushing

	while :; do
		immutable=$(status_field immutable)
		flushing=$(status_field flushing)
		[ "$immutable" -eq 0 ] && [ "$flushing" -eq 0 ] && return 0
		[ "$SECONDS" -lt "$deadline" ] ||
			fail "flush state did not converge: $(dmsetup status "$TARGET_NAME")"
		sleep 0.1
	done
}

case_parallel_writers() {
	local poll_pid status

	: >"$tmp_dir/status.log"
	(
		while [ ! -e "$tmp_dir/fio.done" ]; do
			dmsetup status "$TARGET_NAME" >>"$tmp_dir/status.log" 2>&1 || exit 1
			sleep 0.05
		done
	) &
	poll_pid=$!

	if timeout "$CONCURRENCY_TIMEOUT" fio --name=concurrency-parallel \
		--filename="$DM_DEV" --ioengine=libaio --direct=1 \
		--rw=randwrite --bs=4k --size=8M --numjobs=4 \
		--offset_increment=8M --iodepth=16 --verify=crc32c \
		--verify_fatal=1 --verify_state_save=0 --group_reporting \
		>"$tmp_dir/fio.log" 2>&1; then
		status=0
	else
		status=$?
	fi
	touch "$tmp_dir/fio.done"
	wait "$poll_pid" || fail "dmsetup status polling failed during concurrent I/O"
	if [ "$status" -ne 0 ]; then
		tail -n 30 "$tmp_dir/fio.log" >&2
		[ "$status" -ne 124 ] || fail "parallel fio exceeded ${CONCURRENCY_TIMEOUT}s"
		fail "parallel fio failed with exit $status"
	fi
	[ -s "$tmp_dir/status.log" ] || fail "no status sample was captured during I/O"
	wait_for_flush_idle
	assert_eq "$(status_field immutable)" 0 "an immutable generation remained after fio"
	assert_eq "$(status_field flushing)" 0 "a flushing generation remained after fio"
	assert_lt "$(status_field active)" "$TEST_THRESHOLD" \
		"the residual active generation reached the freeze threshold"
	detail "jobs=4 range=8MiB iodepth=16 active=$(status_field active)"
}

case_repeated_recovery() {
	local cycle previous pattern lba

	for ((cycle = 0; cycle < LIFECYCLE_CYCLES; cycle++)); do
		pattern="$tmp_dir/cycle-$cycle.bin"
		head -c "$ZNS_BLOCK_BYTES" /dev/zero |
			tr '\0' "$(printf '%x' $((cycle % 10)))" >"$pattern"
		lba=$((20000 + cycle))
		write_block "$pattern" "$lba"
		recreate_dm_target
		for ((previous = 0; previous <= cycle; previous++)); do
			assert_block "$tmp_dir/cycle-$previous.bin" $((20000 + previous))
		done
	done

	assert_eq "$(status_field active)" 0 \
		"a clean recreate unexpectedly recovered mappings into the active MemTable"
	assert_eq "$(status_field immutable)" 0 \
		"a clean recreate left an immutable generation"
	assert_eq "$(status_field flushing)" 0 \
		"a clean recreate left a flushing generation"
	detail "cycles=$LIFECYCLE_CYCLES"
}

case_overlapping_partial_writers() {
	local lba=100
	local i pid
	local pids=()

	make_zero_file "$tmp_dir/overlap-base.bin"
	write_block "$tmp_dir/overlap-base.bin" "$lba"
	: >"$tmp_dir/overlap-expected.bin"
	for ((i = 0; i < 8; i++)); do
		head -c 512 /dev/zero | tr '\0' "$(printf '%x' "$i")" \
			>"$tmp_dir/overlap-$i.bin"
		cat "$tmp_dir/overlap-$i.bin" >>"$tmp_dir/overlap-expected.bin"
		dd if="$tmp_dir/overlap-$i.bin" of="$DM_DEV" bs=512 \
			seek=$((lba * 8 + i)) count=1 oflag=direct \
			conv=notrunc status=none &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		wait "$pid" || fail "an overlapping partial writer failed"
	done
	assert_block "$tmp_dir/overlap-expected.bin" "$lba"
	detail "writers=8 sectors=8 logical_block=$lba"
}

run_case "when four disjoint writers run, CRC verification and status polling both complete" \
	case_parallel_writers
run_case "when eight writers update one logical block, no sector update is lost" \
	case_overlapping_partial_writers
run_case "when targets are repeatedly recreated, every prior cycle remains readable" \
	case_repeated_recovery
run_case "when the short stress gate finishes, no kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
