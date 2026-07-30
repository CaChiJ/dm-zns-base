#!/usr/bin/env bash
# Build and run the underlying zone discovery test on /dev/nullb0.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
KO_PATH="$TESTS_DIR/zone-info-test.ko"

[ "$(id -u)" -eq 0 ] || {
	echo "Run with sudo: sudo bash tests/zone-info-test.sh" >&2
	exit 1
}

[ -b /dev/nullb0 ] || {
	echo "/dev/nullb0 is not available" >&2
	exit 1
}

make -C "$TESTS_DIR"
trap 'rmmod zone_info_test 2>/dev/null || true' EXIT

insmod "$KO_PATH"
echo "Zone info test: PASS"
