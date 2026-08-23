#!/usr/bin/env bash
# In-kernel unit tests for the in-memory LSM MemTable.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "unit/memtable"
require_root
run_kernel_test_module memtable-test memtable_test
report_summary
