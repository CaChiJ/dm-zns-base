# Greedy GC victim selection benchmark (2026-10-13)

## Change

The `greedy` policy uses the same safety filters as `simple`, then selects the
eligible full zone with the fewest valid blocks. Ties keep the lower zone
number. With the equal-size data zones used by this project, this is equivalent
to selecting the zone containing the most garbage.

The engine's relocation, mapping publication, reset, and reserve rotation paths
are unchanged.

## Environment

- Kernel: Linux 6.8.0-138-generic
- fio: 3.36
- Device: memory-backed zoned `null_blk`, 2 GiB
- Geometry: 32 zones, 64 MiB per zone
- Exposed logical capacity: 1.875 GiB
- fio workload: fill 0.8C, then random-overwrite 1.2C inside the filled range
- fio settings: 1 MiB, iodepth 16, libaio, direct I/O, seed 314159
- Each policy started from reset media.
- Performance and space sampling were separate runs.

Commands:

```bash
sudo bash scripts/gc-benchmark.sh /tmp/dm-zns-gc-benchmark-20261013/simple simple
sudo bash scripts/gc-benchmark.sh /tmp/dm-zns-gc-benchmark-20261013/greedy greedy
sudo bash scripts/gc-benchmark.sh /tmp/dm-zns-gc-benchmark-20261013/none none
```

## Results

Both policies completed the full 2.25 GiB overwrite with `fio_exit=0` and
ended with 393,216 valid 4 KiB blocks.

| Metric | `simple` | `greedy` | Change |
|---|---:|---:|---:|
| Throughput | 7.88 MiB/s | 106.11 MiB/s | 13.46x |
| Runtime | 292.3 s | 21.7 s | -92.6% |
| Completion latency p50 | 2.164 s | 208.7 ms | -90.4% |
| Completion latency p95 | 4.597 s | 278.9 ms | -93.9% |
| Completion latency p99 | 4.865 s | 308.3 ms | -93.7% |
| Completion latency p99.9 | 5.067 s | 329.3 ms | -93.5% |
| GC moved blocks | 15,576,064 | 834,048 | -94.6% |
| GC moved data | 59.42 GiB | 3.18 GiB | -94.6% |
| Zone resets | 981 | 81 | -91.7% |
| Average garbage in each victim | 3.09% | 37.15% | +34.06 pp |
| Overwrite-phase WAF | 27.41 | 2.41 | -91.2% |

Overwrite-phase WAF is `(2.25 GiB user overwrite + GC moved bytes) / 2.25 GiB`.
The initial 1.5 GiB fill is excluded because it causes no GC in either policy.

The final written-block utilization was similar (`simple` 0.8084, `greedy`
0.8025), so the throughput gain came from collecting better victims rather
than retaining less live data.

## Comparison with GC disabled

The `none` policy completed only 384 MiB of the requested 2.25 GiB overwrite,
then returned `ENOSPC`. Before that failure it delivered 404.64 MiB/s with
p50/p95/p99 completion latency of 38.0/42.7/48.0 ms. Greedy completed the full
workload, but its aggregate 106.11 MiB/s and 208.7/278.9/308.3 ms latency still
show the foreground-GC cost.

These are not equivalent completion intervals: `none` measures only the
GC-free prefix, while `greedy` includes all collections needed to sustain the
remaining 1.875 GiB. The valid conclusion is that greedy enables continued
writes at about 26% of the no-GC-prefix throughput in this implementation; it
is not a full-workload slowdown comparison because `none` cannot complete that
workload at all.

## Validation

The full suite was run with `ZNS_GC_POLICY=greedy`:

```text
unit          39 passed, 0 failed
integration  131 passed, 0 failed
acceptance     14 passed, 0 failed
```

M3 completed the same workload, verified every block, recreated the target,
verified the data again, and restored the expected valid-block count. The
GC move-write and zone-reset failure injection cases also passed with the new
policy.

## Interpretation limits

This is one run per policy on memory-backed `null_blk`. It demonstrates the
relative effect of victim selection in the current serialized engine, but it
does not estimate physical ZNS SSD performance or run-to-run variance. Repeat
the performance run and report dispersion before using the numbers as final
evaluation results.
