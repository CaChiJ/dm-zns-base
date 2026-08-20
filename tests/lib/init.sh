#!/usr/bin/env bash
# Single entry point for the test libraries. A test script sources this one
# file after setting TARGET_NAME and ZNS_REQUIRED_ENGINE.

ZNS_INIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=report.sh
source "$ZNS_INIT_DIR/report.sh"
# shellcheck source=common.sh
source "$ZNS_INIT_DIR/common.sh"
# shellcheck source=device.sh
source "$ZNS_INIT_DIR/device.sh"
# shellcheck source=assert.sh
source "$ZNS_INIT_DIR/assert.sh"
