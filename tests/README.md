# Tests

The directory hierarchy answers one question only: **at what layer does this
test observe the product?** Execution priority and feature readiness are kept in
[`suites.tsv`](suites.tsv), not encoded in directory names.

## Running tests

```bash
sudo bash scripts/nullblk-up.sh   # prepare /dev/nullb0 for required suites
sudo ./test.sh                    # required profile
sudo ./test.sh extended           # broader compatibility and stress coverage
sudo ./test.sh future             # not-yet-supported GC/durability contracts
sudo ./test.sh integration        # every suite in one test layer
sudo ./test.sh all                # every registered suite
sudo ./test.sh sstable-flush      # one suite
./test.sh --list                  # profile, layer, and suite inventory
```

`extended`, `future`, a whole layer, and `all` can contain expected-red tests.
The default invocation runs only the `required` profile. `VERBOSE=1` adds step
and fio logs; `NO_COLOR=1` disables colours. `UNDERLYING` defaults to
`/dev/nullb0`, and `ZNS_ENGINE` defaults to `lsm`.

## Classification standard

| Layer | Inclusion rule | Examples |
|---|---|---|
| [`unit/`](unit/) | Isolates one data structure or algorithm without a live DM target | allocator, MemTable, SSTable, superblock, zone parsing |
| [`integration/`](integration/) | Verifies one focused contract across the DM target, engine, block layer, and lower device | mapping, recovery, error handling, geometry, request sizes, durability boundary |
| [`system/`](system/) | Drives an end-to-end user workload or filesystem and judges the complete device | M1 random-write acceptance, ext4 roundtrip, forced GC cycle |
| [`support/`](support/) | Non-test implementation shared by suites; never selected as a suite | shell fixtures in `lib/`, userspace verifiers in `tools/` |

Top-level test directories must be one of these four. A new test does not get a
directory named after a milestone, priority, feature status, or team plan.

### Execution profiles

Profiles are orthogonal to layers and live in [`suites.tsv`](suites.tsv):

| Profile | Meaning |
|---|---|
| `required` | Current release gate; used by bare `sudo ./test.sh` |
| `extended` | Broader compatibility, boundary, filesystem, exhaustion, and stress coverage |
| `future` | Executable specification for deliberately unsupported future behaviour |

The manifest also records whether a suite needs the test-instrumented kernel
build. The runner rejects missing files, duplicate rows, unknown layers or
profiles, and runnable shell files that were not registered. Mixed selections
run in two phases: every `standard` suite completes against the standard module
before the module is rebuilt and only `testing` suites run with instrumentation.

## Current suite inventory

### Unit

- `allocator`, `memtable`, `sstable`, `super`, and `zone-info` are `required`.

### Integration

- `required`: smoke, overwrite ordering, random-write verification, sub-block
  RMW, request splitting, zone boundary handling, MemTable/SSTable lifecycle,
  recovery, lower-write atomicity, and metadata format/torn-write safety.
- `extended`: request-size and exact-byte payload matrices,
  data/metadata exhaustion, operation advertisement, partial zone capacity, and
  short concurrent lifecycle stress. Direct update cases snapshot the enclosing
  aligned span and compare every byte outside the requested range after fio
  verification.
- `future`: synchronized mapping recovery when clean-detach serialization is
  omitted.

### System

- `required`: `random-write-acceptance`, the complete M1 workload.
- `extended`: `ext4-roundtrip`.
- `future`: `gc-cycle`, whose workload mathematically requires relocation and
  zone reset.

Run `./test.sh --list` for the authoritative per-suite mapping.

## Writing a new suite

1. Choose the observation layer using the table above.
2. Name the file after the behaviour it verifies, without priority or milestone
   prefixes.
3. Add one row to [`suites.tsv`](suites.tsv) with its execution profile and
   build mode.
4. Use the shared fixture from `support/lib`.

```bash
#!/usr/bin/env bash
# One line describing the focused contract.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-example}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "integration/example"

require_root
require_commands make dmsetup blkzone dd cmp
require_host_managed

trap teardown_target EXIT
tmp_dir=$(mktemp -d)

build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

case_example() {
	make_random_file "$tmp_dir/block.bin"
	write_block "$tmp_dir/block.bin" 0
	assert_block "$tmp_dir/block.bin" 0
}

run_case "when a block is written, it reads back unchanged" case_example
run_case "when the workload finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
```

Cases run in a subshell with `errexit` enabled. A case returns zero to pass,
calls `fail "reason"` to fail, and may call `detail "key=value"` for one compact
result detail. Setup failure is a failure, never an implicit skip.

## Expected-red contracts

`integration/write-failure`, `integration/metadata-format-safety`, and
`integration/metadata-torn-write` are required because they expose production
data-safety defects. They are not optional merely because the current code is
red.

The broad size matrices remain `extended`: they report every configured
operation/size/offset combination independently. The focused sub-block RMW
contract is part of the `required` profile.

The future profile contains the forced GC cycle and synchronized mapping
recovery contract.

## Not covered

Real power-loss or in-flight crash consistency, GC phase-specific fault
injection, every SSTable corruption shape, supported discard/write-zeroes
semantics, and long-running race or performance measurements remain uncovered.
`integration/recovery` is a clean target recreation, not a crash.
