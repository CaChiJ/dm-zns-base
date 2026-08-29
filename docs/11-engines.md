# 11. 엔진별 전략

## 비교표

| 엔진 | 매핑 구조 | 물리 위치 선택 | 허용 쓰기 | zone 인식 | 주 용도 |
|---|---|---|---|---|---|
| [`append4k`](../src/engines/zns-engine-append4k.c) | 논리 block 크기의 flat array | sector 0부터 선형 증가 | 정렬된 4 KiB | 없음 | 가장 단순한 기준 구현 |
| [`append4k-alloc`](../src/engines/zns-engine-append4k-alloc.c) | flat array | linear allocator | 정렬된 4 KiB | 없음 | 매핑과 할당 책임 분리 |
| [`lsm`](../src/engines/zns-engine-lsm.c) | 3세대 RB-tree + on-disk SSTable | zone-aware allocator (마지막 zone 예약) | sector 정렬 I/O, 내부 4 KiB RMW | 있음 | 현재 M1 LSM 경로 |

모든 엔진은 `zns_engine_status()`를 제공해야 한다. `lsm` 외의 엔진은 엔진 이름만 출력한다.

## 공통 I/O 의미

엔진은 read, write, flush만 처리하고 discard, write zeroes, zone command 등은 지원하지 않는다. `append4k` 계열은 가능한 bio를 remap하지만, `lsm`은 read/write를 ordered workqueue에서 처리하고 flush는 `blkdev_issue_flush()`로 하위 장치에 전달한다. 한 번도 쓰지 않은 논리 block은 0으로 읽힌다.

상위 큰 요청은 공통 계층의 최대 I/O 길이 설정 때문에 4 KiB 조각으로 분할될 수 있다. 그러나 1 KiB나 2 KiB처럼 4 KiB보다 작은 bio는 자동 확대되지 않으므로 부분 쓰기 지원 여부는 엔진에 달려 있다.

## 1. append4k

구현: [`zns-engine-append4k.c`](../src/engines/zns-engine-append4k.c)

가장 단순한 log-structured mapping이다.

- [`addr_mapping`](../src/engines/zns-engine-append4k.c#L16-L24)은 논리 4 KiB block마다 최신 물리 sector 하나를 저장한다.
- [`zns_append4k_write()`](../src/engines/zns-engine-append4k.c#L56-L80)은 `next_append_sector`를 8 sectors씩 증가시키고 mapping을 새 위치로 교체한다.
- [`zns_append4k_read()`](../src/engines/zns-engine-append4k.c#L34-L54)은 flat array를 조회한다.
- 하나의 spinlock이 append pointer와 mapping 접근을 보호한다.

장점은 경로가 짧고 이해하기 쉽다는 점이다. 하지만 zone의 실제 write pointer, capacity hole, full/offline condition을 모르므로 장치가 완전히 reset되어 있고 sector 0부터 모든 zone을 빈틈없이 이어 쓸 수 있다는 가정에 의존한다. 덮어쓰기는 새 위치를 소비하며 이전 위치는 회수하지 않는다.

## 2. append4k-alloc

구현: [`zns-engine-append4k-alloc.c`](../src/engines/zns-engine-append4k-alloc.c)

`append4k`와 같은 flat mapping을 유지하되 위치 선택을 공통 allocator로 분리한 단계다.

- [`zns_append4k_alloc_write()`](../src/engines/zns-engine-append4k-alloc.c#L57-L80)이 [`zns_allocator_alloc()`](../src/zns-allocator.c#L131-L153)을 호출한다.
- mapping array는 별도의 `mapping_lock`으로 보호한다.
- 초기화에서 [`zns_allocator_init()`](../src/engines/zns-engine-append4k-alloc.c#L108-L115)을 사용하므로 allocator는 linear 모드다.

책임 분리 구조를 시험하는 엔진이지만 이름과 달리 현재 하위 zone metadata를 사용하지 않는다. 따라서 실제 zone capacity와 condition을 반영하는 엔진은 아니다.

## 3. lsm

구현: [`zns-engine-lsm.c`](../src/engines/zns-engine-lsm.c)

현재 M1 목표에 가장 가까운 엔진이다. flat array 대신 RB-tree MemTable 세대를 쓰고, 하위 장치에서 조회한 zone metadata로 append 위치를 정하며, 얼어붙은 MemTable을 예약 zone에 SSTable로 내려보낸다.

### zone 배치

하위 장치의 **마지막 zone 하나를 metadata 전용으로 예약**한다. allocator에는 앞쪽 `nr_zones - 1`개만 넘기므로 data 쓰기가 그 zone에 닿지 않는다. zone이 2개 미만이면 `zns_engine_init()`이 `-EINVAL`이다. DM target 길이는 metadata zone을 제외하고, 각 data zone capacity를 4 KiB 단위로 내린 값의 합 이하여야 한다. 이를 넘는 target은 metadata를 쓰기 전에 `-ENOSPC`로 거부한다.

예약 zone의 배치는 이렇다.

```text
[superblock][SSTable 0][SSTable 1]...[SSTable n]   <- append only, WP까지
```

### 슈퍼블록과 포맷

[`zns_lsm_open_metadata()`](../src/engines/zns-engine-lsm.c)가 예약 zone의 WP를 보고 두 갈래로 갈린다.

- **WP == zone start** — 처음 보는 장치다. 모든 data zone도 비어 있을 때만 [`zns_super_write()`](../src/lsm-super.c)로 첫 block에 슈퍼블록을 쓴다. data zone이 이미 쓰였다면 mapping을 복원할 수 없으므로 media를 변경하지 않고 `-EUCLEAN`로 생성을 거부한다.
- **WP != zone start** — 이미 포맷된 장치다. 슈퍼블록을 읽어 지금 장치와 대조하고, 다르면 어느 필드가 움직였는지 남기고 `-EINVAL`로 ctr을 실패시킨다.

슈퍼블록은 포맷 당시의 `logical_sectors`, `zone_size_sectors`, `nr_zones`, `meta_zone_id`, `sectors_per_block`과 uuid를 담는다. zoned 장치는 제자리 갱신이 안 되므로 **한 번 쓰고 다시 쓰지 않으며**, 그래서 포맷 수명 내내 변하지 않는 값만 넣는다.

검증이 없으면 zone 개수가 바뀌었을 때 "마지막 zone"이 이동해서, 옛 SSTable이 그냥 data 영역으로 편입되고 mapping이 전부 사라지는데도 에러가 한 줄도 안 남는다. 그 조용한 손실을 막는 것이 슈퍼블록의 유일한 목적이다.

### 재시작 복구

포맷된 장치를 열면 [`zns_lsm_recover_sstables()`](../src/engines/zns-engine-lsm.c)가 슈퍼블록 다음 block부터 `meta_wp`까지 로그를 앞으로 훑는다. append-only 로그라 이 순서가 곧 flush 순서이고, `list_add()`로 head에 넣으므로 읽기 경로가 먼저 보는 자리에 최신 SSTable이 온다.

[`zns_sst_load()`](../src/lsm-sstable.c)는 header가 주장하는 전체 payload가 `meta_wp` 안에 있는지 확인한 뒤 payload block을 모두 읽는다. 저장된 CRC, entry 수, key 오름차순, min/max 범위를 검증하고 sequence가 1부터 빠짐없이 이어지는 SSTable만 목록에 게시한다. 불완전한 tail, 잘못된 header와 payload, sequence gap은 모두 target 생성을 fail-closed로 거부한다.

읽기 경로 자체는 바뀌지 않는다. SSTable이 있으면 MemTable miss가 read workqueue로 넘어가 최신순으로 훑는 기존 흐름 그대로다.

### 종료

`dtr` 경로의 [`zns_engine_exit()`](../src/engines/zns-engine-lsm.c)이 두 workqueue를 destroy한 뒤 남아 있는 세대를 **flushing → immutable → active 순서로** 각각 SSTable로 내려보낸다.

순서가 정확성을 결정한다. 읽기는 목록 앞쪽을 이긴 것으로 취급하므로 어린 세대가 늙은 세대 **뒤에** append되어야 하고, 뒤집히면 종료 직전에 덮어쓴 값이 옛 값에 진다. 중간에 쓰기가 실패하면 건너뛰지 않고 거기서 멈춘다 — 구멍을 남기면 stale mapping이 최신 mapping을 이길 수 있기 때문이다.

### 쓰기

```text
I/O workqueue
  -> 요청 범위를 4 KiB logical block 단위로 분해
  -> 부분 block이면 기존 mapping을 읽어 RMW
  -> zoned allocator에서 현재 WP 예약
  -> 하위 장치에 4 KiB 동기 write
  -> 성공한 뒤 active MemTable에 mapping 게시
  -> threshold에 도달하면 metadata flush 큐잉
```

같은 논리 block을 다시 쓰면 새 물리 위치를 받고 active의 mapping만 최신 위치로 바뀐다. 이전 물리 block은 invalid가 되지만 별도로 표시하거나 회수하지 않는다.

### 읽기

모든 LSM read는 I/O workqueue에서 요청 범위를 4 KiB block 단위로 처리한다. `zns_lsm_lookup_memtables()`가 **active → immutable → flushing** 순으로 찾고, miss면 SSTable을 최신순으로 조회한다. mapping이 있으면 해당 물리 block 전체를 읽어 요청 fragment만 bio에 복사하고, 어디에도 없으면 그 fragment를 0으로 채운다.

같은 논리 block이 여러 SSTable에 있으면 목록 앞쪽, 즉 더 최근에 flush된 쪽이 이긴다.

### freeze, flush, compaction

모듈 parameter `memtable_threshold`의 기본값은 16,384개 고유 mapping이다.

1. threshold 도달 → 기존 active가 immutable이 되고 새 active가 생성된다.
2. 쓰기 경로가 flush workqueue를 깨운다.
3. flush worker가 immutable을 `flushing` 슬롯으로 옮기고 immutable을 비운다.
4. SSTable을 예약 zone에 append하고, 목록에 게시한 뒤, flushing MemTable을 해제한다.

3번이 핵심이다. flush 중에 threshold가 또 걸려도 `memtable_put_active()`는 빈 immutable 슬롯만 보므로 flush 대상을 병합·해제하지 않는다. 그 결과 in-memory compaction은 flush가 밀렸을 때만 도는 안전망이 되었다.

flush가 어떤 block도 쓰기 전에 실패하면 MemTable은 `flushing` 슬롯에 남고 다음 write가 재시도할 수 있다. header 또는 payload 일부가 기록된 뒤 실패하면 불완전 record를 건너뛰어 append하지 않도록 남은 metadata capacity를 해당 instance에서 전부 차단한다. 실제 WP가 보고값과 다르거나 WP를 다시 읽을 수 없는 경우도 같은 방식으로 fail-closed 처리한다.

여기서 compaction은 여전히 mapping metadata를 합치는 작업일 뿐, 실제 data block을 이동하거나 zone을 reset하는 GC는 아니다.

### 상태 관측

`dmsetup status`가 세대별 entry 수와 SSTable 현황을 보여준다.

```text
$ dmsetup status m1-smoke
0 4194304 zns-base lsm active=137 immutable=0 flushing=0 sstables=8 sst_entries=512 meta_used=72
```

### 한계

- sector 정렬 I/O를 4 KiB mapping 단위 RMW로 처리하지만 모든 LSM I/O가 하나의 ordered workqueue를 지나므로 병렬성이 제한된다.
- **크래시 복구가 없다.** 정상 종료(`dmsetup remove`, 모듈 reload)는 mapping을 보존하지만, 전원이 끊기면 MemTable에 있던 mapping은 사라진다. 매 쓰기를 기록하는 WAL이 있어야 닫힌다.
- `REQ_OP_FLUSH`는 `blkdev_issue_flush()`로 하위 장치까지 전달하지만 mapping은 MemTable에 남으므로 fsync 이후 crash recovery를 보장하지 않는다.
- metadata record가 일부라도 쓰인 뒤 I/O error가 나면 현재 instance는 metadata append를 중단하고, 다음 open은 불완전 record를 감지해 거부한다. 자동 repair나 metadata zone 교체는 아직 없다.
- SSTable 간 compaction과 level 구조가 없어, 조회는 SSTable 목록을 선형으로 훑는다. flush가 쌓일수록 miss한 read가 느려진다.
- 조회 전 구간에 `sst_lock`을 걸어 SSTable read를 직렬화한다.
- flush는 4 KiB block마다 동기 `submit_bio_wait()`를 반복한다. threshold 16,384이면 한 번에 65회다.
- allocator가 예약한 뒤 MemTable 기록이 실패하면 예약 공간을 되돌리지 않는다.
- GC가 없어 전체 writable capacity를 소비하면 `-ENOSPC`다. 예약 zone이 차면 flush가 `-ENOSPC`로 실패하고 mapping이 메모리에 계속 쌓인다.

## 전략 선택 가이드

- 공통 DM/매핑 흐름을 가장 빨리 이해하려면 `append4k`
- allocator 분리의 효과를 보려면 `append4k-alloc`
- zone capacity, 4 KiB RMW, MemTable 세대 전환, on-disk SSTable flush를 포함한 M1 동작을 보려면 `lsm`
