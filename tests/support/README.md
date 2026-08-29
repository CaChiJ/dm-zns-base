# Test support

This directory contains implementation used by test suites, not runnable test
cases.

- `lib/` provides reporting, assertions, build helpers, DM lifecycle handling,
  parameter parsing, and private null_blk fixtures.
- `tools/` builds deterministic userspace I/O generators and verifiers.

Neither directory is registered in `tests/suites.tsv`; the runner only executes
shell suites directly below `unit/`, `integration/`, and `system/`.
