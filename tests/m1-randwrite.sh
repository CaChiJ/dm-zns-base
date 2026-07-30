#!/usr/bin/env bash
# Verify 4 KiB random writes through the LSM engine.

set -euo pipefail

DM_NAME=${DM_NAME:-myzns-base}
DM_DEV=${DM_DEV:-/dev/mapper/$DM_NAME}
UNDERLYING=${UNDERLYING:-/dev/nullb0}

require_root() {
	[ "$(id -u)" -eq 0 ] || {
		echo "Run with sudo: sudo bash tests/m1-randwrite.sh" >&2
		exit 1
	}
}

count_io_errors() {
	dmesg | grep -Eic \
		'blk_update_request|I/O error|zone.*(reject|invalid)|write.*(reject|prohibited)' ||
		true
}

zone_write_pointer() {
	blkzone report -o 0 -c 1 "$UNDERLYING" |
		awk 'NR == 1 {
			for (i = 1; i <= NF; i++)
				if ($i == "wptr") {
					value = $(i + 1)
					gsub(/,/, "", value)
					print value
					exit
				}
		}'
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

[ -b "$UNDERLYING" ] || {
	echo "[FAIL] underlying device $UNDERLYING does not exist" >&2
	exit 1
}

fio_log=$(mktemp)
trap 'rm -f "$fio_log"' EXIT

errors_before=$(count_io_errors)
wp_before=$(zone_write_pointer)

[ -n "$wp_before" ] || {
	echo "[FAIL] could not read the underlying zone write pointer" >&2
	exit 1
}

echo "[*] running 4 KiB random writes through $DM_DEV"
if fio --name=m1-randwrite \
		--filename="$DM_DEV" \
		--rw=randwrite \
		--bs=4k \
		--size=4M \
		--ioengine=libaio \
		--iodepth=32 \
		--direct=1 >"$fio_log" 2>&1; then
	fio_status=0
else
	fio_status=$?
fi

errors_after=$(count_io_errors)
wp_after=$(zone_write_pointer)
new_errors=$((errors_after - errors_before))

if [ "$fio_status" -ne 0 ]; then
	cat "$fio_log" >&2
	echo "[FAIL] fio exited with status $fio_status" >&2
	exit 1
fi

if [ "$new_errors" -ne 0 ]; then
	cat "$fio_log" >&2
	echo "[FAIL] detected $new_errors new kernel I/O error(s)" >&2
	exit 1
fi

[ -n "$wp_after" ] || {
	echo "[FAIL] could not read the final underlying zone write pointer" >&2
	exit 1
}

if [ "$((wp_after))" -le "$((wp_before))" ]; then
	cat "$fio_log" >&2
	echo "[FAIL] underlying zone write pointer did not advance" >&2
	exit 1
fi

echo "[*] underlying write pointer: $wp_before -> $wp_after"
echo "M1 4 KiB randwrite: PASS"
