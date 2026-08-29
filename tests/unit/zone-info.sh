#!/usr/bin/env bash
# Zone discovery against the real underlying device.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "unit/zone-info"
require_root
require_underlying
run_kernel_test_module zone-info-test zone_info_test
report_summary
