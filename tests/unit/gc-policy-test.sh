#!/usr/bin/env bash
# In-kernel regression tests for GC victim selection.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "unit/gc-policy"
require_root
run_kernel_test_module gc-policy-test gc_policy_test
report_summary
