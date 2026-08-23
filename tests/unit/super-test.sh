#!/usr/bin/env bash
# In-kernel unit tests for the metadata zone superblock.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

report_init "unit/super"
require_root
run_kernel_test_module super-test super_test
report_summary
