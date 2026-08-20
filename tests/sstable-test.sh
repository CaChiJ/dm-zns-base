#!/usr/bin/env bash
# Build and run the standalone in-kernel SSTable format tests.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
KO_PATH="$TESTS_DIR/sstable-test.ko"

[ "$(id -u)" -eq 0 ] || {
	echo "Run with sudo: sudo bash tests/sstable-test.sh" >&2
	exit 1
}

make -C "$TESTS_DIR"
trap 'rmmod sstable_test 2>/dev/null || true' EXIT

insmod "$KO_PATH"
echo "SSTable unit test: PASS"
