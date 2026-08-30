# 06. 빌드 / 적재 / 테스트

기본 흐름:

```bash
sudo bash scripts/nullblk-up.sh    # 백킹 디바이스
cd src && make && cd ..            # dm-zns-base.ko
sudo bash scripts/test-basic.sh    # 적재 + smoke test
# ... 수정 후 ...
cd src && make && cd ..
sudo bash scripts/test-basic.sh    # 잔재는 스크립트가 알아서 정리
# 정리
sudo bash scripts/nullblk-down.sh
cd src && make clean
```

## 빌드

```bash
cd src && make
```

`/lib/modules/$(uname -r)/build`의 커널 빌드 시스템으로 위임된다. 산출물은 `dm-zns-base.ko`.

빌드가 실패할 때:
- `linux-headers-$(uname -r) 없음` → `sudo apt install linux-headers-$(uname -r)`
- 커널 업그레이드 직후 → 재부팅 또는 헤더 재설치
- 다른 커널 버전으로 빌드 → `KDIR=/lib/modules/<버전>/build make`

## `test-basic.sh`가 검증하는 4단계

1. `blkzone report` — DM 타깃이 zoned로 노출되는가 (`.iterate_devices` + `.report_zones`).
2. `zone 0 reset` — wp를 0으로 (반복 실행 시 SEQ_WRITE_REQUIRED 위반 방지).
3. 4 KiB 순차 쓰기 — `dd ... seek=0` 통과.
4. wp 증가 — wptr이 sector 8(= 4 KiB)로.

`ALL CHECKS PASSED`까지 가면 성공.

## 수동으로 `dmsetup` 다루기

```bash
sudo insmod src/dm-zns-base.ko

SECTORS=$(sudo blockdev --getsz /dev/nullb0)
echo "0 $SECTORS zns-base /dev/nullb0" | sudo dmsetup create myzns

sudo dmsetup ls
sudo blkzone report /dev/mapper/myzns | head -3
cat /sys/block/dm-0/queue/zoned       # host-managed

sudo dmsetup remove myzns
sudo rmmod dm-zns-base
```

## 진단

### `blkzone report ... unable to determine zone size`

DM queue로 zoned 속성이 stack되지 않은 상태.

```bash
cat /sys/block/dm-X/queue/zoned         # none 이면 문제
cat /sys/block/dm-X/queue/chunk_sectors # 0 이면 문제
```

원인:
- `.iterate_devices` 콜백 누락 → scaffold의 `zns_base_iterate_devices` 패턴 참고.
- `.features = DM_TARGET_ZONED_HM` 누락.

### `dd ... 0 bytes copied` + dmesg `blk_update_request: I/O error sector X op 0x1:(WRITE)`

해당 zone의 wp가 sector X가 아닌 위치라 SEQ_WRITE_REQUIRED 위반:

```bash
sudo blkzone reset -o 0 -c 1 /dev/mapper/myzns
sudo blkzone report /dev/mapper/myzns | head -1
```

### `insmod`: Invalid module format

빌드한 커널 헤더와 실행 커널 mismatch. `uname -r`와 `modinfo dm-zns-base.ko | grep vermagic` 비교.

### `dmsetup create ... device-mapper: reload ioctl ... failed`

`sudo dmesg | tail -20`에 ctr 거부 이유가 나온다. (예: underlying이 zoned가 아닌데 `DM_TARGET_ZONED_HM` 타깃을 쓰려 한 경우.)

### `make`는 통과하는데 `.ko`가 안 보임

```bash
cd src && make clean && make 2>&1 | tee /tmp/build.log
```

## 자주 쓰는 dmesg 필터

```bash
sudo dmesg | grep -E 'zns-base|device-mapper|null_blk|blk_update_request' | tail -30
```
