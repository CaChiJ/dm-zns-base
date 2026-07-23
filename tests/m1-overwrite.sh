#!/usr/bin/env bash
# Verify reads return the latest data after repeated logical overwrites.

set -euo pipefail

DM_NAME=${DM_NAME:-myzns-base}
DM_DEV=${DM_DEV:-/dev/mapper/$DM_NAME}
TEST_LBA=${TEST_LBA:-100}

require_root() {
	[ "$(id -u)" -eq 0 ] || {
		echo "Run with sudo: sudo bash tests/m1-overwrite.sh" >&2
		exit 1
	}
}

count_io_errors() {
	dmesg | grep -Eic \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' ||
		true
}

require_root

command -v fio >/dev/null || {
	echo "[FAIL] fio is not installed" >&2
	exit 1
}

[ -b "$DM_DEV" ] || {
	echo "[FAIL] $DM_DEV does not exist. Run scripts/build-run.sh lsm first." >&2
	exit 1
}

fio_log=$(mktemp)
test_dir=$(mktemp -d)
trap 'rm -f "$fio_log"; rm -rf "$test_dir"' EXIT

errors_before=$(count_io_errors)

echo "[*] verifying latest mappings after repeated overwrites through $DM_DEV"
if fio --name=m1-overwrite \
		--filename="$DM_DEV" \
		--rw=randwrite \
		--bs=4k \
		--size=4M \
		--loops=3 \
		--ioengine=libaio \
		--iodepth=8 \
		--direct=1 \
		--verify=crc32c \
		--verify_fatal=1 >"$fio_log" 2>&1; then
	fio_status=0
else
	fio_status=$?
fi

if [ "$fio_status" -ne 0 ]; then
	cat "$fio_log" >&2
	echo "[FAIL] fio overwrite verification exited with status $fio_status" >&2
	exit 1
fi

head -c 4096 /dev/zero | tr '\0' 'A' >"$test_dir/a.bin"
head -c 4096 /dev/zero | tr '\0' 'B' >"$test_dir/b.bin"
head -c 4096 /dev/zero | tr '\0' 'C' >"$test_dir/c.bin"

echo "[*] overwriting logical block $TEST_LBA with A, B, then C"
dd if="$test_dir/a.bin" of="$DM_DEV" bs=4096 seek="$TEST_LBA" count=1 \
	conv=notrunc oflag=direct status=none
dd if="$test_dir/b.bin" of="$DM_DEV" bs=4096 seek="$TEST_LBA" count=1 \
	conv=notrunc oflag=direct status=none
dd if="$test_dir/c.bin" of="$DM_DEV" bs=4096 seek="$TEST_LBA" count=1 \
	conv=notrunc oflag=direct status=none

dd if="$DM_DEV" of="$test_dir/result.bin" bs=4096 skip="$TEST_LBA" count=1 \
	iflag=direct status=none

if ! cmp -s "$test_dir/c.bin" "$test_dir/result.bin"; then
	echo "[FAIL] logical block $TEST_LBA did not return the latest data" >&2
	exit 1
fi

if cmp -s "$test_dir/a.bin" "$test_dir/result.bin" ||
   cmp -s "$test_dir/b.bin" "$test_dir/result.bin"; then
	echo "[FAIL] logical block $TEST_LBA returned stale data" >&2
	exit 1
fi

errors_after=$(count_io_errors)
new_errors=$((errors_after - errors_before))
if [ "$new_errors" -ne 0 ]; then
	cat "$fio_log" >&2
	echo "[FAIL] detected $new_errors new kernel I/O error(s)" >&2
	exit 1
fi

echo "M1 latest mapping after overwrite: PASS"
