# I/O size inventory and parametric integration tests

The LSM engine stores mappings in 4 KiB blocks but accepts any non-empty,
sector-aligned bio inside the logical target. It splits the request across
mapping blocks and uses read-modify-write for partial fragments:

```text
bio_sectors > 0
logical_sector + bio_sectors <= logical_sectors
```

The required sub-block suite fixes the basic 512 B–4 KiB contract. The extended
matrices broaden it across sizes, offsets, operations, and queue depths so a
regression is attributed to one combination instead of one large fio failure.

| Dimension | Previously covered | Added parametric coverage | Current LSM expectation |
|---|---|---|---|
| direct request below 4 KiB | 512B, 1KiB, 2KiB randwrite | 512B, 1KiB, 1536B, 2KiB, 2560B, 3584B | PASS through 4 KiB RMW |
| direct 4 KiB-unaligned LBA | two hard-coded 1KiB updates | every configured operation/size at 512B-offset steps | PASS when sector-aligned and in range |
| request with partial 4KiB tail | none | 4608B and any configured non-4KiB multiple | PASS; each edge fragment uses RMW |
| aligned large request | 8/16/64KiB only | configurable through MiB-sized requests | PASS after DM splits it into 4KiB bios |
| operation type | randwrite and two updates | unmapped read, sequential write, update, randwrite | PASS for supported sector-aligned requests |
| direct update neighbors | two fixed 1KiB updates | every configured update size/offset snapshots and compares the enclosing aligned span | bytes outside the request must remain unchanged |
| exact application payload | none | 1B through 256MiB defaults | PASS end-to-end through buffered writeback |
| payload boundary neighbors | two fixed updates | every byte payload verifies the enclosing aligned range | must remain unchanged |
| random byte updates | none | exact total payload with bounded random request chunks | PASS with final byte-for-byte verification |

`request-size-matrix.sh` exercises actual direct block requests. Linux block
I/O is sector-addressed, so a raw 1-byte bio is not a valid engine capability;
the direct matrix intentionally starts at 512 bytes. `payload-size-matrix.sh`
expresses 1-byte and other sub-sector application writes through buffered I/O,
then drops that cache view and verifies the enclosing range with `O_DIRECT`.
A buffered 1-byte PASS therefore does not mean the engine accepted a 1-byte
bio—the direct matrix remains the authoritative block-request result.

## Parameters

All lists accept commas or whitespace. Defaults are deliberately broad but can
be narrowed for development:

```bash
sudo CAP_REQUEST_SIZES='512,1k,1536,4k,4608,64k,1m' \
  CAP_REQUEST_OPERATIONS='read update randwrite' \
  CAP_REQUEST_OFFSETS='0,512,4k' \
  CAP_REQUEST_IODEPTHS='1,8,32' \
  CAP_REQUEST_RANGE=32m \
  ./test.sh request-size-matrix

sudo CAP_PAYLOAD_SIZES='1,7,511,512,513,4095,4k,4097,1m,100m,256m' \
  CAP_PAYLOAD_OPERATIONS='write update randwrite' \
  CAP_PAYLOAD_OFFSETS='1,511,4095' \
  CAP_PAYLOAD_EXACT_REQUEST_MAX=1m \
  CAP_PAYLOAD_RANDOM_REQUEST_MAX=64k \
  ./test.sh payload-size-matrix
```

Each Cartesian combination gets a reset device and a newly formatted target.
This makes size-specific results reproducible and prevents the append-only
engine from reaching ENOSPC merely because earlier matrix cases consumed the
same zones. Both suites create private null_blk fixtures; their size and zone
geometry can be changed with `CAP_REQUEST_DEVICE_MB`/`CAP_REQUEST_ZONE_MB` and
`CAP_PAYLOAD_DEVICE_MB`/`CAP_PAYLOAD_ZONE_MB`.

## Still not modeled

These remain separate work rather than being mislabeled as another size value:

- raw requests below 512 bytes (not representable by the Linux sector API),
- multi-iovec and `io_uring` buffer segmentation with the same total length,
- requests ending exactly at and one sector beyond the logical device end,
- mixed `randrw` read/write ratios and concurrent overlapping byte updates,
- synchronized byte updates followed by a real power cut,
- GiB-scale/long-duration sweeps; the same parameters support them, but they
  belong in dedicated soak jobs rather than the default extended profile.
