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

## M2 step 3: sub-block reads

Reads now accept non-empty 512-byte multiples, including offsets inside a
4 KiB logical block. Full aligned 4 KiB reads retain the existing clone path;
other reads fetch each mapped 4 KiB block into a bounce buffer and copy the
requested bytes into the original bio. Unmapped portions return zeros.
Writes still require full aligned 4 KiB requests; sub-block RMW is step 4.

Run on the disposable test-server device (the suites reset its zones):

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh \
    smoke subblock-read ordered-io overwrite sstable-flush recovery m1
```

`subblock-read` compares direct reads against a random reference image for
512 B, 1 KiB, 2 KiB and other sector-multiple sizes, plus full-block reads.
It checks unaligned starts, crossing between independently mapped blocks,
mapped-to-unmapped boundaries, and entirely unwritten reads. The same matrix
runs with resident mappings, SSTable-only mappings, and after clean target
recreation. DM may split a cross-boundary userspace read into multiple bios.

This checkpoint can be used to retry the original 1 KiB read and investigate
ext4 mount, but it is not ext4 roundtrip acceptance: partial writes are still
unsupported. No local kernel or block-device experiments are required.

## M2 step 4: sub-block writes (RMW)

Sector-aligned partial writes now read the existing 4 KiB block (or start from
zeros for a hole), merge only the requested range, append a full block, and
publish its mapping after success. Full-block and partial writes share the
same ordered queue, append helper, and stop-on-write-error policy. Original
write flags including PREFLUSH/FUA are passed to the lower write. This does
not add durable mapping fsync or crash recovery.

Cross-block writes are handled per block. They are not atomic transactions:
if a later fragment fails, earlier successful fragments remain published.

Run on the disposable test-server device; each suite resets its zones:

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh \
    smoke subblock-read subblock-write ordered-io overwrite \
    sstable-flush recovery write-failure m1

# Fail a 1 KiB overwrite inside a mapped block, preserving all 4 KiB.
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm WRITE_BYTES=1024 WRITE_OFFSET=1024 \
    bash tests/run.sh write-failure

# Repeat when the old mapping exists only in an SSTable.
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm TEST_THRESHOLD=1 \
    WRITE_BYTES=1024 WRITE_OFFSET=1024 bash tests/run.sh write-failure
```

`subblock-write` compares whole reference images after partial updates,
including cross-block requests and unwritten holes. It also checks eight
concurrent 512 B writers on disjoint sectors of the same block, and alternating
full/partial overwrites. The failure suite defaults to its previous 4 KiB
workload; WRITE_BYTES/WRITE_OFFSET select a single-block partial write instead.
The injected error remains a simulated pre-submission failure, not a real
device error. A successful retry after recreation verifies the new bytes and
all untouched bytes again, including after a further restart.

The existing `randwrite-matrix` suite can now exercise successful 1 KiB and
2 KiB writes as well, but workload completion alone does not verify untouched
bytes; use the reference-image tests above for that property.

## M2 step 5: sub-block mapping lifecycle

Run on the disposable test-server device; these suites reset all its zones:

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh \
    smoke subblock-read subblock-write subblock-lifecycle ordered-io \
    overwrite sstable-flush recovery write-failure m1
```

`subblock-lifecycle` maintains one random reference image across partial
updates in the MemTable, a threshold-triggered flush, overlapping RMW updates
whose originals exist only in SSTables, and a second flush. It checks resident
mapping precedence and newest-SSTable precedence, then recreates the target
without resetting zones. Further partial updates remain resident until another
clean restart exercises shutdown flushing. Each checkpoint compares the whole
image (including untouched bytes and a hole) and direct sub-block reads.
Status checks confirm the intended mapping location; flush waits are bounded.
DM may split cross-block requests, so these checks do not prove that a single
bio crossed a mapping boundary inside the engine.

This is clean target recovery, not crash recovery or ext4 roundtrip acceptance.
Step 6 remains the ext4 mount/write/unmount/remount/hash checkpoint.

## M2 step 6: ext4 roundtrip acceptance

Run on the test server after step 5 passes. `/dev/nullb0` must already exist
(create it with `sudo bash scripts/nullblk-up.sh` if needed). This suite resets
all zones on `UNDERLYING` and formats its own DM target; use disposable media.

```bash
sudo env UNDERLYING=/dev/nullb0 ZNS_ENGINE=lsm bash tests/run.sh m2
```

`m2` checks a conventional upper device, creates journaled ext4 with 4 KiB
blocks, writes exactly 10 MiB of random data, records its MD5, runs `sync`,
unmounts, mounts again, and compares the file size and MD5. The same DM target
stays live between mounts: there is no target recreation, module reload, or
zone reset in that interval. It then unmounts, removes the target, and checks
for new kernel I/O, ext4, and journal errors. All four cases must pass.

The suite uses `nodiscard` because discard is unsupported, and disables lazy
inode-table/journal initialization during mkfs for a bounded initialization
phase. The journal and default mount barriers remain enabled. It requires
`mkfs.ext4` (e2fsprogs), mount/umount, and the standard test tools. Cleanup
unmounts before removing the target or temporary directory; if unmount fails,
it reports and preserves those resources for inspection.

This verifies the M2 filesystem roundtrip, not crash recovery, durable mapping
fsync, or filesystem recovery after target recreation.

## Layout

| Path | What lives there |
|---|---|
| `lib/` | Shared fixtures: reporting, preconditions, DM target lifecycle, assertions |
| `unit/` | In-kernel tests. Each module includes the source file under test directly |
| `integration/` | One DM target per suite, driven through real block I/O including sub-block ranges |
| `acceptance/` | Milestone judgement: `m1.sh` checks raw random writes; `m2.sh` checks the ext4 roundtrip |

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

Crash consistency, SSTable payload CRC
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
