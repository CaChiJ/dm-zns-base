#!/usr/bin/env bash
# In-kernel unit tests for the on-disk SSTable format helpers.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "unit/sstable"
require_root
run_kernel_test_module sstable-test sstable_test
report_summary
