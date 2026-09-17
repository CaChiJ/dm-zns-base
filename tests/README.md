# tests

```bash
sudo bash scripts/nullblk-up.sh   # /dev/nullb0 (zoned, host-managed)
sudo ./test.sh                    # every suite
sudo ./test.sh unit               # one group
sudo ./test.sh sstable-flush      # one suite
./test.sh --list                  # what is available
```

Every run prints one line per case and a combined summary, whichever way it
was started:

```
=== integration/overwrite ===
[PASS] when a 32M range is randwritten, CRC verify reads back the latest data
[FAIL] when block 100 is rewritten A->B->C, a read returns C
        logical block 100 does not match pat-c

=== summary ===
integration     11 passed    1 failed

[FAIL] 1 case(s) failed:
  integration/overwrite   when block 100 is rewritten A->B->C, a read returns C
```

`VERBOSE=1` adds the per-step logs and the fio output. `NO_COLOR=1` drops the
colours. `UNDERLYING` (default `/dev/nullb0`) and `ZNS_ENGINE` (default `lsm`)
select the device and the engine under test.

## M2 step 1: ordered I/O regression

Run this checkpoint on the test server after copying the updated source tree.
These suites reset all zones on `UNDERLYING`, so use the disposable test
device, with any existing filesystem unmounted and existing zns-base targets
removed first. Do not use a device containing data you need to keep.

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh \
    smoke ordered-io overwrite sstable-flush recovery m1
```

Every selected case must pass. `ordered-io` checks unwritten reads, four
concurrent writers on disjoint ranges with periodic fsync and CRC verification,
and direct readback after an overwrite and fsync. These are functional
regressions; they do not prove every possible interleaving or crash durability.

At step 1 only full aligned 4 KiB data I/O is supported. Sub-block
reads/writes and ext4 mounting are still expected to fail. Data mappings are
still published before the lower write completes; changing that policy is the
next checkpoint. Block-layer flushes share the data queue, but SSTable flushes
retain their separate metadata queue. A successful fsync does not guarantee
mapping persistence across a crash.

## M2 step 2: publish after successful writes

Data mappings are now published only after the lower write succeeds. On a
lower data write error the old mapping stays readable and `writes_stopped=1`
appears in target status. Further data writes fail until normal target
recreation reloads actual zone write pointers. Reads and metadata shutdown
flushing remain available. This deliberately avoids guessing whether a failed
write consumed its reserved sectors.

If data succeeds but MemTable insertion fails, the write returns an error and
the old mapping remains. The consumed physical block is not reclaimed, and
later writes can continue because the physical WP is known to have advanced.

Run on the disposable test-server device (these suites reset its zones):

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh \
    smoke ordered-io overwrite sstable-flush recovery write-failure m1
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm TEST_THRESHOLD=1 \
    bash tests/run.sh write-failure
```

`write-failure` loads the module with `fail_data_write_at=2`, a read-only module
parameter disabled by default. It simulates failure of the second allocated
data write per target, before lower submission; metadata I/O is unaffected.
It checks the old mapping, rejection of subsequent writes, and recovery and
successful overwrite across clean target restarts. The second command repeats
the test with the old mapping in an SSTable instead of the active MemTable.
Expected I/O errors are not counted as failures in this injection suite.

This injection does not test actual device errors, partially advanced WPs, or
MemTable allocation failures. Neither this change nor normal target restart
provides crash recovery or durable fsync semantics.

## Layout

| Path | What lives there |
|---|---|
| `lib/` | Shared fixtures: reporting, preconditions, DM target lifecycle, assertions |
| `unit/` | In-kernel tests. Each module includes the source file under test directly |
| `integration/` | One DM target per suite, driven through real 4 KiB block I/O |
| `acceptance/` | Milestone judgement. `m1.sh` decides whether M1 in `docs/07-milestones.md` is met |

## Conventions

**Naming.** A file is named after what it verifies — no `test-` prefix, no
`-test` suffix, no milestone prefix; the directory already says which layer it
belongs to. Two exceptions: a kernel test module keeps `<component>-test.c`
because the file name is the module name, and an acceptance suite is named
after its milestone because that is its scope.

**Case names** read as a sentence: `when <condition>, <expected result>`. They
are the output, so they have to be readable on their own.

**Every suite owns its target.** A suite builds the engine it needs, loads the
module, creates its own DM target under its own `TARGET_NAME`, and removes both
from an `EXIT` trap. No suite depends on a target another script left behind.

**Root once, at the outside.** Suites never call `sudo` themselves; the whole
run is started with `sudo`. Builds are handed back to `$SUDO_USER` so the build
tree does not fill up with root-owned objects.

**One rule: if a suite cannot run properly, that is a failure.** A missing
`/dev/nullb0`, a device with too few zones, a missing `fio` -- all of it reports
`[FAIL]`, the same as a wrong readback would. There is deliberately no third
state: a run that quietly passes over what it never checked is worse than a
loud red line.

## Writing a new suite

```bash
#!/usr/bin/env bash
# One line on what this suite verifies.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-example}
ZNS_REQUIRED_ENGINE=lsm

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/init.sh
source "$TESTS_DIR/lib/init.sh"

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

Cases run in a subshell with `errexit` on, so the first failing command ends
the case and the rest of the suite keeps going. A case returns `0` to pass,
calls `fail "<reason>"` to fail, and `detail "key=value"` to add one short
field to its result line. `run.sh` picks the new
file up automatically.

## Not covered

ext4 mkfs/mount round trips, crash consistency, SSTable payload CRC
verification, the reserved-zone `-ENOSPC` path, discard and write-zeroes,
allocator rollback after a failed physical write, real GC and zone reuse, and
long-running read/write races or performance numbers.

`integration/recovery` covers a clean restart -- the target is removed and
recreated, and once the module is reloaded, without a zone being reset. It does
not cover a crash. It also cannot reach the case the recovery scan does not
catch: an SSTable torn in the middle of the metadata zone by a write error
passes the length check once a later table pushes the write pointer past it,
and a lookup into it can return a wrong physical sector.

`scripts/test-basic.sh` is the original M0 pass-through check. It expects the
upper DM device to be zoned, which stopped being true when the target began
exposing a conventional device, so it is kept as history and is not part of a
run.
