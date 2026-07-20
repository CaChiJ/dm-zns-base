#!/usr/bin/env bash
# Build and run the standalone in-kernel allocator tests.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
KO_PATH="$TESTS_DIR/zns-allocator-test.ko"

[ "$(id -u)" -eq 0 ] || {
	echo "Run with sudo: sudo bash tests/allocator-test.sh" >&2
	exit 1
}

make -C "$TESTS_DIR"
trap 'rmmod zns_allocator_test 2>/dev/null || true' EXIT

insmod "$KO_PATH"
echo "Allocator unit test: PASS"
