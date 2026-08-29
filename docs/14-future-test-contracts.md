# Future GC and durability test contracts

The `future` profile is opt-in because the current milestone does not yet
implement GC or crash-durable mapping updates:

```bash
sudo ./test.sh future
```

`gc-cycle.sh` uses separate logical (`L`) and physical data (`P`) capacities.
It reserves whole data zones (`R`) so `L = P - R`, initializes `0.8L`, then
issues `1.2L` random overwrites. The fixture checks that the resulting append
demand exceeds `P`; a pass therefore requires actual relocation and reset, not
an oversized backing device. A version manifest validates every latest block
both before and after target recreation. Summary counters live in
`dmsetup status`; per-zone diagnostics should use a future debugfs/test-message
interface rather than making the status line unbounded.

`fsync-quiesced-recovery.sh` enables a test-build-only hook that skips the LSM
clean-detach flush after Device Mapper has quiesced I/O. It proves that a
successful `fdatasync` did not leave only a volatile mapping, and separately
checks lower FLUSH request/completion counters. It does **not** model in-flight
I/O loss or a real power cut; those require reboot/VM/FEMU CI.

## Required GC fault matrix

Do not add one generic "GC failed safely" assertion. Once deterministic GC
failpoints exist, split the cases by phase:

| Fault point | Required invariant |
|---|---|
| destination write | all old data remains readable; victim is not reset |
| source read | unaffected blocks remain readable; affected read may return EIO; victim is not reset |
| mapping/metadata commit | old mapping remains authoritative; victim is not reset |
| victim reset | relocated mapping remains authoritative; victim is not reused |

Failpoints must record that they were reached, stop later workflow, and return
an error. They must never sleep forever in a workqueue or make `dmsetup remove`
depend on releasing the fault. A failpoint followed by recreate validates
recovery from persistent intermediate state; it is not described as an exact
CPU-instruction crash.

## Metadata corruption order

Expand corruption coverage only against an agreed on-disk format. Required
tests already exercise payload CRC mismatch and a truncated tail. Current
recovery also rejects unsorted entries, sequence gaps, and magic/version
mismatch; add explicit regression cases for those paths, followed by
`nr_blocks`/`nr_entries` disagreement and physical-sector range violation. Do
not invent a header checksum or repair policy before the next format version
defines it.

Long KASAN/KCSAN/lockdep runs and performance measurements belong in dedicated
CI/benchmark jobs outside the correctness-suite hierarchy. Neither is a
`future` pass/fail correctness gate.
