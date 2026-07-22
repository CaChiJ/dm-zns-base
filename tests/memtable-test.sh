#!/usr/bin/env bash
# Build and run the standalone in-kernel memtable tests.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
KO_PATH="$TESTS_DIR/memtable-test.ko"

[ "$(id -u)" -eq 0 ] || {
	echo "Run with sudo: sudo bash tests/memtable-test.sh" >&2
	exit 1
}

make -C "$TESTS_DIR"
trap 'rmmod memtable_test 2>/dev/null || true' EXIT

insmod "$KO_PATH"
echo "MemTable unit test: PASS"
