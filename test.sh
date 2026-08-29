#!/usr/bin/env bash
# Run the project test suite. See tests/README.md for the suite layout.
#
#   sudo ./test.sh              required profile
#   sudo ./test.sh integration  one test layer
#   sudo ./test.sh extended     broader compatibility/stress profile
#   sudo ./test.sh future       not-yet-supported contracts
#   sudo ./test.sh all          every registered suite
#   sudo ./test.sh smoke        one suite
#   ./test.sh --list            profile/layer inventory

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

exec "$SCRIPT_DIR/tests/run.sh" "$@"
