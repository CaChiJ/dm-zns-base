#!/usr/bin/env bash
# Run the project test suite. See tests/README.md for the suite layout.
#
#   sudo ./test.sh              every suite
#   sudo ./test.sh unit         one group
#   sudo ./test.sh smoke        one suite
#   ./test.sh --list            what is available

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

exec "$SCRIPT_DIR/tests/run.sh" "$@"
