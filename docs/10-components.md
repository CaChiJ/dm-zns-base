# 10. 구성요소와 상호작용

## 1. 빌드 조합

[`src/Makefile`](../src/Makefile#L1-L14)은 다음 파일들을 `dm-zns-base.ko` 하나로 묶는다.

```text
dm-zns-base-main.o
zns-allocator.o
zns-zone.o
lsm-memtable.o
lsm-sstable.o
lsm-super.o
engines/zns-engine-${ZNS_ENGINE}.o
```

공통 구성요소는 어느 엔진을 선택해도 링크된다. 다만 실제 호출 관계는 엔진별로 다르며, 예를 들어 `append4k`는 zone table이나 MemTable을 사용하지 않는다.

## 2. Device Mapper 어댑터

인터페이스는 Linux Device Mapper의 `target_type`, 구현은 [`dm-zns-base-main.c`](../src/dm-zns-base-main.c)다.

### 소유 상태

[`struct zns_base_c`](../src/dm-zns-base-main.c#L15-L18)는 두 객체를 소유한다.

- `dm_dev *dev`: DM core를 통해 연 하위 블록 장치
- `zns_engine engine`: 선택된 엔진의 private 상태를 가리키는 얇은 wrapper

### 생명주기

[`zns_base_ctr()`](../src/dm-zns-base-main.c#L20-L65)는 다음 순서로 target을 만든다.

1. 하위 장치 경로 하나만 인자로 받는다.
2. [`dm_get_device()`](../src/dm-zns-base-main.c#L36)로 하위 장치를 연다.
3. 논리·물리 sector 수와 4 KiB block 크기를 [`zns_engine_init()`](../src/dm-zns-base-main.c#L43)에 전달한다.
4. 최대 I/O 길이를 8 sectors로 설정한다. 큰 요청은 DM 계층에서 4 KiB 단위로 분할될 수 있다.
5. flush bio가 하위 장치 한 곳으로 전달된다고 선언한다.

반대 방향의 [`zns_base_dtr()`](../src/dm-zns-base-main.c#L67-L75)는 엔진, 장치 참조, context 순서로 정리한다.

### I/O 전달

[`zns_base_map()`](../src/dm-zns-base-main.c#L77-L82)은 정책을 갖지 않는다. 모든 bio를 현재 링크된 엔진에 위임한다. [`target_type`](../src/dm-zns-base-main.c#L84-L91)에 zoned 속성이 없으므로 상위 DM 장치는 conventional로 노출된다.

## 3. 엔진 인터페이스

공개 계약은 [`zns-engine.h`](../src/zns-engine.h)다.

| 함수 | 역할 |
|---|---|
| [`zns_engine_init`](../src/zns-engine.h#L15-L18) | 엔진별 상태와 매핑 자료구조를 준비한다. |
| [`zns_engine_map`](../src/zns-engine.h#L23-L24) | bio를 하위 위치로 remap하거나, 직접 완료하거나, 실패시킨다. |
| [`zns_engine_exit`](../src/zns-engine.h#L20-L21) | private 상태와 비동기 작업을 정리한다. |
| [`zns_engine_status`](../src/zns-engine.h#L26-L28) | `dmsetup status`의 INFO 줄에 엔진별 상태를 채운다. |
| [`zns_engine_name`](../src/zns-engine.h#L30-L31) | 로그에 표시할 빌드된 엔진 이름을 반환한다. |

[`struct zns_engine`](../src/zns-engine.h#L11-L13)은 `void *private`만 갖는다. 각 엔진 구현 파일이 같은 네 함수의 심볼을 제공하며 Makefile이 그중 하나만 링크한다. 따라서 이는 함수 포인터 기반 런타임 다형성이 아니라 링크 타임 교체 인터페이스다.

엔진이 `zns_engine_map()`에서 반환하는 주요 결과는 다음과 같다.

- `DM_MAPIO_REMAPPED`: `bio->bi_iter.bi_sector`와 장치를 바꿨으니 DM이 하위 I/O를 제출한다.
- `DM_MAPIO_SUBMITTED`: 엔진이 bio를 직접 완료했거나 비동기 작업으로 넘겼다.
- `DM_MAPIO_KILL`: 지원하지 않거나 잘못된 요청이므로 실패시킨다.

## 4. Zone 정보 계층

인터페이스는 [`zns-zone.h`](../src/zns-zone.h), 구현은 [`zns-zone.c`](../src/zns-zone.c)다.

### 데이터 모델

[`struct zns_zone`](../src/zns-zone.h#L9-L17)은 zone id, 시작 sector, 길이, 실제 writable capacity, write pointer, condition, active 여부를 저장한다. [`struct zns_zone_table`](../src/zns-zone.h#L19-L22)은 이 배열과 개수를 소유한다.

### 초기화 과정

[`zns_zone_table_init()`](../src/zns-zone.c#L41-L81)은 다음을 수행한다.

1. `bdev_is_zoned()`로 zoned 장치인지 확인한다.
2. `bdev_nr_zones()`로 배열 크기를 정한다.
3. `blkdev_report_zones()`를 호출한다.
4. [`zns_zone_report_cb()`](../src/zns-zone.c#L20-L39)이 커널의 `struct blk_zone`을 프로젝트의 `struct zns_zone`으로 복사한다.
5. 일부만 report된 경우도 오류로 처리하고 할당을 되돌린다.

이 계층은 장치 상태의 초기 snapshot을 만든다. 이후 allocator가 자기 복사본의 write pointer를 전진시키며, 매 쓰기마다 장치에 다시 report하지 않는다.

## 5. 물리 append allocator

인터페이스는 [`zns-allocator.h`](../src/zns-allocator.h), 구현은 [`zns-allocator.c`](../src/zns-allocator.c)다.

allocator는 [`ZNS_ALLOCATOR_LINEAR`와 `ZNS_ALLOCATOR_ZONED`](../src/zns-allocator.h#L9-L12) 두 모드를 제공한다. 공통 API인 [`zns_allocator_alloc()`](../src/zns-allocator.c#L131-L153)은 spinlock으로 할당을 직렬화하므로 동시에 호출되어도 같은 sector를 두 번 내주지 않는다.

### Linear 모드

[`zns_allocator_init()`](../src/zns-allocator.c#L27-L43)으로 시작한다. sector 0부터 `sectors_per_block`씩 증가하고 전체 물리 sector 끝에서 `-ENOSPC`를 반환한다. zone의 시작, capacity, condition은 모른다.

### Zoned 모드

[`zns_allocator_init_zoned()`](../src/zns-allocator.c#L66-L94)은 zone table을 검증하고 독립된 복사본을 소유한다. [`zns_allocator_alloc_zoned()`](../src/zns-allocator.c#L105-L129)은 현재 zone의 write pointer에서 블록 하나를 예약한 뒤 다음 규칙으로 전진한다.

- `FULL`, `READONLY`, `OFFLINE` zone은 건너뛴다.
- `length`가 아니라 `capacity` 끝을 쓰기 한계로 사용한다.
- 초기 장치 write pointer부터 이어 쓴다.
- 남은 공간이 4 KiB 미만이면 다음 zone으로 이동한다.
- 사용할 zone이 없으면 `-ENOSPC`다.

allocator는 sector를 예약할 뿐 실제 bio를 제출하지 않으며, 실패한 하위 쓰기를 일반적으로 rollback하지 않는다. 또한 invalidation, free list, zone reset, GC는 담당하지 않는다.

## 6. LSM MemTable

인터페이스는 [`lsm-memtable.h`](../src/lsm-memtable.h), 구현은 [`lsm-memtable.c`](../src/lsm-memtable.c)다.

### 단일 table

[`struct lsm_entry`](../src/lsm-memtable.h#L10-L15)는 논리 block, 최신 물리 sector, 갱신 sequence를 Linux RB-tree node에 담는다. [`struct lsm_memtable`](../src/lsm-memtable.h#L17-L22)은 RB-tree, 다음 sequence, 고유 key 수, spinlock을 갖는다.

- [`memtable_lookup()`](../src/lsm-memtable.c#L359-L380): 논리 block을 찾고 없으면 `-ENODATA`를 반환한다.
- [`memtable_insert()`](../src/lsm-memtable.c#L382-L428): 새 key만 넣고 중복은 `-EEXIST`다.
- [`memtable_update()`](../src/lsm-memtable.c#L430-L450): 기존 key만 갱신한다.
- [`memtable_put()`](../src/lsm-memtable.c#L452-L500): insert-or-update이며 덮어써도 entry 수는 늘지 않는다.

### active와 immutable 세대

LSM 엔진은 active와 immutable 두 table을 사용한다.

- 쓰기는 항상 active에 들어간다.
- 읽기는 [`memtable_lookup_active_immutable()`](../src/lsm-memtable.c#L204-L230)에서 active를 먼저 찾아 최신 값을 우선하고, 없을 때 immutable을 찾는다.
- active의 고유 key 수가 threshold에 도달하고 immutable이 없으면 [`memtable_freeze_prepared_locked()`](../src/lsm-memtable.c#L133-L149)이 기존 active를 immutable로 옮기고 빈 active를 게시한다.
- immutable이 이미 있으면 [`memtable_compact()`](../src/lsm-memtable.c#L126-L131)이 `immutable(older) + active(newer)`를 새 table로 병합한다. newer를 나중에 복사하므로 중복 key는 최신 값이 이긴다.
- [`memtable_put_active_with_ops()`](../src/lsm-memtable.c#L232-L312)은 table pointer 교체를 `table_lock` 아래에서 원자적으로 게시한다. 유지보수용 allocation이나 compaction이 실패해도 이미 기록한 최신 mapping은 보존하고 성공을 반환한다.

`lsm-memtable.c`는 메모리 안에서만 세대를 관리한다. 디스크로 내리는 일은 아래 SSTable 계층이 맡으며, 다단계 level과 WAL은 아직 없다.

## 7. On-disk SSTable

인터페이스는 [`lsm-sstable.h`](../src/lsm-sstable.h), 구현은 [`lsm-sstable.c`](../src/lsm-sstable.c)다. 얼어붙은 MemTable을 하위 장치의 예약 zone에 append하고, 그 mapping을 메모리 대신 디스크에서 조회하게 만드는 계층이다.

### 디스크 배치

한 SSTable은 헤더 block 1개와 논리 block 오름차순으로 정렬된 entry block N개로 이루어진다.

```text
[header][entry 0..255][entry 256..511] ... [tail, 0 padding]
```

- [`struct zns_sst_disk_header`](../src/lsm-sstable.h#L27-L37): magic, version, entry 수, block 수, payload CRC, flush 순번, min/max key.
- [`struct zns_sst_disk_entry`](../src/lsm-sstable.h#L39-L42): 논리 block과 물리 sector 각각 8 byte. 4 KiB block마다 256개가 들어간다.

모든 필드는 little-endian이다. 재시작 복구는 magic, version, 순번뿐 아니라 payload 전체 CRC, entry 수, key 순서와 min/max 범위를 확인한 뒤 SSTable을 채택한다.

### 쓰기

[`zns_sst_write()`](../src/lsm-sstable.c#L241)은 RB-tree를 두 번 순회한다. zone은 순차 쓰기만 허용해서 헤더가 payload보다 먼저 나가야 하는데, 헤더가 담을 CRC는 payload에서 나오기 때문이다.

1. entry 수와 min/max key를 센다.
2. payload block을 조립하며 CRC만 계산한다(쓰기 없음).
3. 헤더 block을 쓴다.
4. payload block을 다시 조립해 실제로 append한다.

`rb_first()`/`rb_next()` 순회가 이미 논리 block 오름차순이므로 별도 정렬은 없다. 쓰기는 4 KiB block 하나를 재사용하며 block마다 `submit_bio_wait()`를 반복한다.

`*consumed`는 **실패했을 때에도** 실제로 zone에 나간 sector 수를 돌려준다. 그 sector들은 이미 zone WP를 전진시켰으므로 다음 flush가 재사용하면 순차 쓰기 위반이 된다.

### 조회

[`zns_sst_lookup()`](../src/lsm-sstable.c) 은 두 단계 이진 탐색이다.

1. in-memory index의 `[min_key, max_key]` 밖이면 block을 하나도 읽지 않고 `-ENODATA`.
2. 각 payload block의 첫 key로 이진 탐색해 후보 block 하나를 고른다.
3. 그 block 안에서 [`zns_sst_block_find()`](../src/lsm-sstable.c#L95-L122)로 다시 이진 탐색한다.

직전에 읽은 block을 하나 캐시하므로 2단계 마지막 probe와 3단계가 같은 block이면 재차 읽지 않는다. entry 16,384개(block 65개)짜리 SSTable의 최악 조회 비용은 block read 7회다.

### 엔진이 들고 있는 index

[`struct zns_sstable`](../src/lsm-sstable.h#L45-L53)은 디스크 위치, entry 수, block 수, min/max key, 순번만 갖는 가벼운 구조체다. entry 자체는 메모리에 남지 않는다.

## 8. 예약 zone 슈퍼블록

인터페이스는 [`lsm-super.h`](../src/lsm-super.h), 구현은 [`lsm-super.c`](../src/lsm-super.c)다. 예약 zone의 첫 block 하나를 차지하며, 그 zone이 아직 비어 있을 때 **딱 한 번** 쓰이고 이후로는 읽히기만 한다.

```text
[superblock][SSTable 0][SSTable 1] ... [SSTable n]
```

[`struct zns_super_disk`](../src/lsm-super.h)는 magic, version, crc32, uuid와 포맷 당시의 `logical_sectors`, `zone_size_sectors`, `nr_zones`, `meta_zone_id`, `sectors_per_block`을 담는다. sequential-only zone은 block을 제자리에서 고쳐 쓸 수 없으므로, 포맷 수명 내내 변하지 않는 값만 넣는다.

- `zns_super_encode()` / `zns_super_decode()` — 버퍼만 다루는 순수 함수. decode는 magic, version, CRC를 확인한다.
- `zns_super_matches()` — 기록된 geometry와 지금 장치를 필드 단위로 비교하고, 처음 어긋난 필드를 로그에 남긴 뒤 `-EINVAL`. uuid는 포맷을 식별할 뿐이라 비교하지 않는다.
- `zns_super_write()` / `zns_super_read()` — 두 함수 모두 block I/O에서 잠들므로 `.map()`에서 부를 수 없다. SSTable과 같은 예약 zone에 있으므로 같은 헬퍼 [`zns_meta_block_rw()`](../src/lsm-sstable.c)를 쓴다.

존재 이유는 하나다. 검증이 없으면 zone 개수가 바뀌었을 때 "마지막 zone"이 다른 곳으로 옮겨가고, 옛 SSTable이 평범한 data 영역으로 편입되어 mapping이 전부 사라지는데도 에러가 한 줄도 남지 않는다.

## 9. LSM 엔진에서의 결합

[`struct zns_lsm`](../src/engines/zns-engine-lsm.c#L38-L65)이 하위 장치, zone table, zoned allocator, 세 MemTable 세대, SSTable 목록, 예약 zone의 append pointer, workqueue 두 개를 한데 묶는다.

초기화는 `zns_engine_init()`에서 다음 순서로 진행된다.

```text
하위 zoned 장치
  -> zone table snapshot
  -> 마지막 zone을 metadata 전용으로 예약
       비어 있으면  -> 슈퍼블록 기록
       포맷돼 있으면 -> 슈퍼블록 대조 -> SSTable 로그 스캔
  -> 앞쪽 nr_zones - 1개로 zone-aware allocator 초기화
  -> 빈 active MemTable 생성
  -> flush / read workqueue 생성
```

`zns_engine_exit()`은 역순으로 내려가되, 두 workqueue를 destroy한 **다음에** 남은 세대를 flushing → immutable → active 순서로 SSTable에 기록하고 나서 해제한다. 그 시점에는 device-mapper가 이미 target을 drain했고 workqueue도 없어서 엔진을 건드리는 스레드가 하나뿐이다.

`zns_lsm_write()`는 논리 sector를 논리 block으로 바꾸고, allocator에서 append 위치를 받아 active에 기록한 뒤 flush가 필요한지 확인한다. 읽기는 `zns_lsm_lookup_memtables()`가 active → immutable → flushing 순으로 찾고, 셋 다 없으면 read workqueue로 넘어가 SSTable을 최신순으로 조회한다.

### 왜 workqueue인가

`submit_bio_wait()`는 DM `.map()` 컨텍스트에서 호출할 수 없다. 그래서 flush는 물론 **MemTable을 모두 miss한 read도** workqueue로 넘어간다. worker가 조회를 끝낸 뒤 bio를 직접 remap해 `submit_bio_noacct()`하거나, 어디에도 없으면 zero-fill 후 `bio_endio()`한다. MemTable에서 바로 찾은 read는 종전대로 `.map()`에서 즉시 `DM_MAPIO_REMAPPED`다.

### 세 번째 세대 슬롯

flush 도중 threshold가 다시 걸리면 `memtable_put_active()`가 immutable을 병합 결과로 교체하며 **기존 것을 free**한다. flush 대상이 발밑에서 사라지는 것을 막기 위해, flush worker는 시작할 때 `table_lock` 아래에서 immutable을 `flushing` 슬롯으로 옮기고 immutable을 비운다. 그러면 `memtable_put_active()`는 빈 슬롯을 보고 단순 freeze만 하며, 결과적으로 in-memory compaction 경로는 안전망으로만 남는다.

SSTable을 목록에 게시한 **다음에** flushing MemTable을 해제하므로, mapping이 메모리와 디스크 어느 쪽에도 없는 순간은 생기지 않는다.

### 여전한 주의점

LSM write는 ordered I/O workqueue에서 하위 4 KiB write 성공을 확인한 뒤 mapping을 갱신한다. 실패 시 실제 zone WP가 움직이지 않았을 때만 allocator 예약을 되돌리고 기존 mapping을 유지한다. SSTable flush가 header 이후 실패하면 불완전한 record 뒤에 새 metadata를 붙이지 않도록 해당 target instance의 metadata append를 차단하며, MemTable은 `flushing` 슬롯에 남아 read가 계속 조회한다.

## 10. 실행 환경 구성요소

- [`scripts/nullblk-up.sh`](../scripts/nullblk-up.sh): configfs로 기본 2 GiB, zone 크기 64 MiB인 memory-backed host-managed `/dev/nullb0`를 만든다.
- [`scripts/nullblk-down.sh`](../scripts/nullblk-down.sh): 해당 null_blk instance를 끄고 가능한 경우 모듈도 내린다.
- [`scripts/build-run.sh`](../scripts/build-run.sh): 엔진을 선택해 clean build하고, 기존 target을 제거하고, 하위 zone을 reset한 뒤 `myzns-base` target을 만든다.
- [`tests/support/lib/init.sh`](../tests/support/lib/init.sh): 테스트가 공유하는 build/load/create/reset/cleanup helper를 한 번에 불러온다.
