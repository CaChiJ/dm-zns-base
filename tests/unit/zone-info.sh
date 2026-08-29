#!/usr/bin/env bash
# Zone discovery against the real underlying device.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "unit/zone-info"
require_root

case_data_capacity_rounds_each_zone() {
	local capacity

	underlying_attr() {
		case $1 in
		nr_zones) printf '3\n' ;;
		chunk_sectors) printf '4096\n' ;;
		*) return 1 ;;
		esac
	}
	zone_capacity() {
		case $1 in
		0) printf '1027\n' ;;
		4096) printf '1028\n' ;;
		*) return 1 ;;
		esac
	}

	capacity=$(data_zone_capacity_sectors) ||
		fail "could not calculate mocked data-zone capacity"
	assert_eq "$capacity" 2048 \
		"data-zone capacity did not round each partial 4 KiB tail"
	detail "raw=2055 usable=$capacity"
}

run_case "when zone capacities are not block-aligned, each unusable tail is omitted" \
	case_data_capacity_rounds_each_zone

require_underlying
run_kernel_test_module zone-info-test zone_info_test
report_summary
