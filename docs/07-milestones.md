# 07. 마일스톤 (M0 → M4)

각 마일스톤에 관찰 가능한 성공 기준을 명시한다. 학생들은 자기 환경에서 그 기준이 통과하는지 직접 확인한 다음 다음 단계로 넘어간다.

MVP 우선. crash 복구, 메타데이터 영속화, fsync 정확성, 성능 최적화 같은 항목은 stretch.

---

## M0 — 제공된 scaffold

산출물은 `src/dm-zns-base.c`. zoned-aware pass-through DM 타깃으로, underlying ZNS 디바이스의 zone들을 위로 그대로 노출만 한다. 임의→순차 변환 로직은 없다.

성공 기준 (`sudo bash scripts/test-basic.sh`):
- `blkzone report /dev/mapper/X`가 zone 정보를 출력.
- `/sys/block/dm-X/queue/zoned` = `host-managed`.
- `/sys/block/dm-X/queue/chunk_sectors`가 underlying과 동일.
- zone 0 reset 후 sector 0에 4 KiB 순차 쓰기 통과.
- 쓰기 후 wp가 sector 8로.

---

## M1 — random write 변환 (핵심 작업)

본 과제의 알맹이. DM 타깃을 위에서는 conventional 블록 디바이스로 보이게 하되, underlying의 sequential-only 제약은 *우리가 떠안는다*. 임의 LBA로 들어온 쓰기는 활성 zone의 wp에 순차로 append되고, LBA → (zone, offset) 매핑 테이블이 그 위치를 기억한다. 읽기는 매핑 테이블 lookup.

### 왜 위쪽엔 zoned를 안 보여주나

DM 타깃은 위와 아래에 동시에 면을 가진다. **이 두 면이 서로 달라야** 본 과제의 의미가 생긴다.

```
ext4              ← 위쪽 면: conventional (임의 쓰기 가능)
  ↓ 임의 LBA write
[/dev/mapper/X]   ← DM 타깃 — 위는 conventional, 아래는 zoned
  ↓ 활성 zone의 wp에 sequential write
[/dev/nullb0]     ← 아래쪽 면: host-managed zoned
```

ext4는 ZNS 의미론을 모르기 때문에, 위쪽을 zoned로 광고하면(= M0 상태) `mkfs.ext4`부터 거절·실패한다. 반대로 광고만 conventional로 바꾸고 처리 경로(`.map`)는 M0 그대로 두면, ext4의 임의 위치 쓰기가 그대로 underlying ZNS에 내려가서 SEQ_WRITE_REQUIRED 위반으로 reject(`blk_update_request: I/O error`). **위쪽 광고와 아래쪽 처리 둘 다** 같이 바꿔야 한다 — 그 사이를 메우는 LSM-Tree 매핑이 본 과제의 결과물이다.

같은 패턴의 prior art: `dm-zoned` 자체가 zoned 하드웨어를 conventional 디바이스로 보이게 해서 ext4를 받아주는 모듈이다. 본 과제는 *별도 conventional 영역 없이* 그 일을 해내는 것이 차별점.

### 구현 포인트

- `.features`에서 `DM_TARGET_ZONED_HM` 제거, `.report_zones` 제거 (위쪽엔 zone이 없으므로). queue limits에서 zone size 제약을 위로 노출하지 않는다.
- `.map`에서 임의 LBA 쓰기를 활성 zone wp에 sequential append하고 매핑 테이블 갱신. 읽기는 매핑 lookup 후 underlying 좌표로 다시 매핑.
- LSM-Tree(또는 sorted log + 컴팩션 비스무리한 구조)로 매핑 테이블 구성.
- 매핑은 in-memory만. 영속화·crash recovery 없음 (stretch).

### 성공 기준 (FS 없이 raw block device에 직접)

```bash
before=$(sudo dmesg | grep -c blk_update_request)
fio --name=randw --filename=/dev/mapper/X --rw=randwrite \
    --bs=4k --size=100M --ioengine=libaio --iodepth=32 --direct=1
after=$(sudo dmesg | grep -c blk_update_request)
echo "delta: $((after - before))"          # 0 이어야 함
```

`blk_update_request: I/O error ...` 는 underlying이 쓰기를 reject할 때 찍히는 로그. fio가 임의 위치 쓰기를 25,600개 보낼 동안 *단 한 건도* reject가 없어야 변환이 빈 구멍 없이 동작하는 것.

---

## M2 — ext4 라운드트립

M1 단계에 FS 레이어를 얹어 검증하는 단계이다.

성공 기준 — 데이터가 쓴 그대로 다시 읽혀야 한다:
```bash
mkfs.ext4 /dev/mapper/X
mount /dev/mapper/X /mnt/x
dd if=/dev/urandom of=/mnt/x/data bs=1M count=10
md5sum /mnt/x/data            # hash A
sync && umount /mnt/x         # 페이지 캐시 비우기
mount /dev/mapper/X /mnt/x
md5sum /mnt/x/data            # hash B  — A와 같아야 함
```

umount/remount 사이에 검증하는 이유는 페이지 캐시 우회. 안 그러면 DM 레이어를 거치지 않고 RAM에서 곧장 읽혀서 "정상 동작한다"는 잘못된 결론이 난다.

---

## M3 — GC + zone reset 사이클

zone들이 차면 valid 데이터를 다른 zone으로 옮기고 빈 zone을 reset해 재사용한다.

구현 포인트:
- 각 zone의 valid/invalid 비율 추적.
- victim zone 선정 정책(greedy / cost-benefit 등).
- 활성 zone 풀 관리.
- LSM 컴팩션과 GC 결합 (컴팩션이 자연히 GC가 되도록).

성공 기준:
```bash
# 용량의 80%까지 채운 뒤
fio --rw=randwrite --size=<용량의 80%> ...
# 같은 영역에 1.2배 분량의 random overwrite
fio --rw=randwrite --size=<용량의 1.2배> ...
# "no space left" 없이 완료. 내부적으로 GC가 돈다.
```

---

## M4 — 성능 평가 (추후 정의)

M1–M3까지 동작 골격이 잡힌 다음에 평가 축을 확정한다. 비교 대상·메트릭·환경은 그 시점에 서버(FEMU) 상황과 학생들의 구현 특성을 반영해 결정. 후보 베이스라인:

- raw sequential write to underlying — 하드웨어 상한
- `dm-zoned` + ext4 — conventional 보조 디바이스를 동반한 동종 비교
- F2FS multi-device (conventional + zoned) — zone-aware FS의 best case (참고용)
- ext4 on 일반 SSD — ZNS로 가는 비용

> 본 항목은 M3 통과 후 별도 공지로 업데이트 예정.