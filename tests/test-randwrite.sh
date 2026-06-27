#!/usr/bin/env bash
# M1 smoke test: 4 KiB random writes must complete without lower block I/O errors.

set -u

DM_NAME=${DM_NAME:-myzns-base}
DM_DEV=${DM_DEV:-/dev/mapper/$DM_NAME}
SIZE=${SIZE:-100M}
BS=${BS:-4k}
IODEPTH=${IODEPTH:-32}

count_blk_errors() {
	sudo dmesg | grep -Ec 'blk_update_request|I/O error' || true
}

if [ ! -b "$DM_DEV" ]; then
	echo "[FAIL] $DM_DEV does not exist. Run ./scripts/build-run.sh first." >&2
	exit 1
fi

before=$(count_blk_errors)

sudo fio --name=randw --filename="$DM_DEV" --rw=randwrite \
	--bs="$BS" --size="$SIZE" --ioengine=libaio \
	--iodepth="$IODEPTH" --direct=1
fio_status=$?

after=$(count_blk_errors)
delta=$((after - before))

echo "dmesg error delta: $delta"

if [ "$fio_status" -ne 0 ]; then
	echo "[FAIL] fio exited with status $fio_status" >&2
	exit 1
fi

if [ "$delta" -ne 0 ]; then
	echo "[FAIL] lower block I/O errors increased during randwrite" >&2
	exit 1
fi

echo "[PASS] M1 randwrite: $SIZE random writes, bs=$BS, iodepth=$IODEPTH"
