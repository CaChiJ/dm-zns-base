# 08. 참고 자료

## Linux 커널: Device Mapper / Block Layer

- **Device Mapper admin guide (공식)**: https://docs.kernel.org/admin-guide/device-mapper/index.html
- **Device Mapper 개념 정리**: https://linuxvox.com/blog/linux-device-mapper/
- **DM target 작성 튜토리얼**: https://gauravmmh1.medium.com/writing-your-own-device-mapper-target-539689d19a89
- **dm-zoned 공식 문서**: https://docs.kernel.org/admin-guide/device-mapper/dm-zoned.html
- Linux kernel source — `drivers/md/dm-zoned-*.c` (dm-zoned 실제 구현, prior art 분석용)

## ZNS / Zoned Block Device

- **NVMe ZNS specification** (TP 4053): https://nvmexpress.org/specifications/
- **Linux zoned block device API**: https://docs.kernel.org/block/zoned.html
- **zonefs** (참고용 zone-per-file FS): https://docs.kernel.org/filesystems/zonefs.html
- **`blkzone(8)` 매뉴얼**: `man blkzone`

## Prior art (직접 코드 읽어볼 만함)

- **dm-zap** (WDC, ZNS 친화 DM target 시도): https://github.com/westerndigitalcorporation/dm-zap
- **F2FS zoned mode** (Linux 메인라인): `fs/f2fs/segment.c` 등

## LSM-Tree

- **서베이 논문 "LSM-based Storage Techniques: A Survey"**: https://link.springer.com/article/10.1007/s00778-019-00555-y
- RocksDB / LevelDB 디자인 문서 (개념 참고용 — 본 과제는 블록 계층이라 *블록 단위* LSM)

## 실험 환경

- **FEMU (Flash Emulator)** — 서버 단계에서 사용: https://github.com/MoatLab/FEMU
  - `hw/femu/zns` 디렉터리가 ZNS 에뮬레이션 구현
- **null_blk** 커널 모듈 문서: https://docs.kernel.org/block/null_blk.html