# 05. zoned `null_blk`

본 repo의 모든 로컬 실험은 zoned `null_blk` 위에서 진행한다. 실제 ZNS SSD나 FEMU 없이도 블록 계층 의미론은 동일하게 동작한다.

## 자동 셋업

```bash
sudo bash scripts/nullblk-up.sh
```

기본값: `/dev/nullb0`, 2 GiB, 64 MiB zone × 32 zones. 환경변수로 변경:

```bash
sudo NB_NAME=nullb1 NB_SIZE_MB=4096 NB_ZONE_SIZE_MB=128 bash scripts/nullblk-up.sh
```

## 수동 (configfs)

```bash
sudo modprobe null_blk nr_devices=0
sudo mkdir /sys/kernel/config/nullb/nullb0
echo 1     | sudo tee /sys/kernel/config/nullb/nullb0/zoned
echo 64    | sudo tee /sys/kernel/config/nullb/nullb0/zone_size       # MiB
echo 2048  | sudo tee /sys/kernel/config/nullb/nullb0/size             # MiB
echo 1     | sudo tee /sys/kernel/config/nullb/nullb0/memory_backed
echo 1     | sudo tee /sys/kernel/config/nullb/nullb0/power
```

## 검증

```bash
cat /sys/block/nullb0/queue/zoned          # host-managed
cat /sys/block/nullb0/queue/chunk_sectors  # 131072 (= 64 MiB)
cat /sys/block/nullb0/queue/nr_zones       # 32
sudo blkzone report /dev/nullb0 | head -3
```

## 정리

```bash
sudo bash scripts/nullblk-down.sh
```

## 한계

| 항목 | nullblk | 실제 ZNS SSD / FEMU |
|---|---|---|
| zone 의미론 (SEQ_WRITE_REQUIRED, wp, reset) | 동일 | 동일 |
| NVMe ZNS 명령 (`nvme zns ...`, Zone Append) | 없음 (블록 계층만) | 있음 |
| I/O 지연 | ~0 (메모리 직결) | 플래시 수준 (수 µs ~ 수 ms) |
| fio 결과의 의미 | 무의미 | 의미 있음 |

nullblk는 정확성 검증용이지 성능 비교의 근거가 못 된다. LSM-Tree 매핑 로직이 "잘 동작한다"는 검증은 nullblk에서, "얼마나 효율적이다"는 평가는 FEMU/실 SSD에서.

## 기본값을 64 MiB × 32 zones로 둔 이유

- 2 GiB 총 용량은 ext4 mkfs + 약간의 데이터 쓰기에 충분하고 VM 메모리 부담이 적다.
- 64 MiB zone은 상용 ZNS SSD의 일반적인 zone 크기(수십 ~ 수백 MiB)와 같은 자릿수.
- 32 zones면 GC 시 zone 단위 데이터 이동 시나리오를 충분히 만들 수 있다.

작업 단계에 맞게 자유롭게 조정.
