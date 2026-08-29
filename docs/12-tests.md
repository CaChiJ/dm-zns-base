# 12. 테스트 구조와 검증 범위

## 실행

```bash
sudo bash scripts/nullblk-up.sh   # /dev/nullb0 (zoned, host-managed)
sudo ./test.sh                    # required 프로필
sudo ./test.sh extended           # 경계·호환성·stress 확장 프로필
sudo ./test.sh future             # 아직 미지원인 GC/durability 계약
sudo ./test.sh integration        # 테스트 계층 단위
sudo ./test.sh all                # 등록된 모든 suite
sudo ./test.sh sstable-flush      # 단일 suite
./test.sh --list                  # 프로필·계층·suite 목록 (root 불필요)
```

`./test.sh`는 [`tests/run.sh`](../tests/run.sh)에 그대로 위임한다. 어느 단위로 실행하든 **케이스 한 줄 + 합산 요약**이라는 같은 형식으로 결과가 나온다.

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

환경 변수: `VERBOSE=1`(단계 로그와 fio 출력), `NO_COLOR=1`, `UNDERLYING`(기본 `/dev/nullb0`), `ZNS_ENGINE`(기본 `lsm`).

대부분의 테스트가 커널 모듈 적재와 zone reset을 수행하므로 root 권한과 커널 headers가 필요하다. 테스트는 하위 zone의 내용을 지우므로 실제 데이터가 있는 장치를 `UNDERLYING`으로 지정하면 안 된다.

## 테스트 계층

테스트 트리의 상위 디렉터리는 관찰 계층만 표현한다. 개발 우선순위, 현재
지원 여부, 마일스톤은 디렉터리명이 아니라 [`tests/suites.tsv`](../tests/suites.tsv)의
실행 프로필로 표현한다.

| 디렉터리 | 포함 기준 |
|---|---|
| [`tests/unit/`](../tests/unit/) | live DM target 없이 단일 자료구조·알고리즘을 격리 검증 |
| [`tests/integration/`](../tests/integration/) | DM target·engine·block layer·하위 장치 사이의 특정 계약을 집중 검증 |
| [`tests/system/`](../tests/system/) | 파일시스템이나 전체 workload로 사용자 관점의 종단간 동작을 판정 |
| [`tests/support/`](../tests/support/) | 실행 대상이 아닌 공용 shell fixture와 userspace 검증 도구 |

실행 프로필은 계층과 독립적이다.

| 프로필 | 의미 |
|---|---|
| `required` | bare `sudo ./test.sh`가 실행하는 현재 release gate |
| `extended` | 경계값, 호환성, filesystem, 고갈, 짧은 stress 확장 검증 |
| `future` | 아직 구현되지 않은 GC·crash-durable mapping의 실행 가능한 명세 |

runner는 manifest에 없는 `.sh`, 중복 등록, 존재하지 않는 경로와 알 수 없는
계층·프로필을 거부한다. 따라서 새 suite는 계층 디렉터리에 파일을 추가하고
manifest에 실행 정책을 한 줄 등록해야 한다. 여러 프로필을 함께 선택하면
`standard` suite를 일반 모듈로 모두 실행한 다음 모듈을 다시 빌드하고
`testing` suite만 테스트 계측 빌드로 실행한다.

## 규약

**파일명은 검증 대상 명사구.** `test-` 접두사, `-test` 접미사, 우선순위·마일스톤 접두사를 쓰지 않는다. 계층은 디렉터리가 표현한다. 커널 테스트 모듈만 파일명이 곧 모듈명이라 `<component>-test.c`를 유지한다.

**케이스 이름은 `when <조건>, <기대 결과>` 서술문.** 그대로 출력되므로 그 자체로 읽혀야 한다.

**suite는 자기 target을 소유한다.** 필요한 엔진을 빌드하고, 모듈을 적재하고, 자기 `TARGET_NAME`으로 DM target을 만들고, `EXIT` trap으로 둘 다 제거한다. 다른 스크립트가 남긴 target에 의존하는 테스트는 없다.

**root는 바깥에서 한 번.** suite 내부에서 `sudo`를 호출하지 않는다. 빌드는 `$SUDO_USER`에게 되돌려 실행하므로 빌드 트리가 root 소유 산출물로 오염되지 않는다.

**규칙은 하나 — 제대로 못 돌면 FAIL.** `/dev/nullb0` 부재, zone 개수 부족, `fio` 미설치도 잘못된 readback과 똑같이 `[FAIL]`로 보고한다. 세 번째 상태는 의도적으로 두지 않았다. 검사하지도 않은 것을 조용히 넘어가며 초록으로 끝나는 실행은 빨간 줄보다 나쁘다.

## 1. 커널 단위 테스트

각 모듈은 대상 소스를 직접 include하고, [`tests/unit/zns-test.h`](../tests/unit/zns-test.h)의 케이스 테이블로 **모든 케이스를 끝까지 실행한 뒤** 케이스마다 한 줄씩 dmesg에 남긴다. wrapper `.sh`는 `/dev/kmsg` marker로 구간을 잘라 그 줄들을 셸 테스트와 같은 `[PASS]`/`[FAIL]` 형식으로 다시 출력한다. 하나라도 실패하면 `insmod`도 실패한다.

### Allocator — [`allocator-test.c`](../tests/unit/allocator-test.c)

| case | 검증 내용 |
|---|---|
| `sequential` | linear allocator가 0, 8, … 순서로 4 KiB 위치를 반환하는지 |
| `enospc` | 전체 block 소진 후 다음 호출이 `-ENOSPC`인지 |
| `zoned_boundaries` | capacity 끝에서 다음 zone으로 이동하고 입력 zone 배열을 복사해 소유하는지 |
| `zoned_partial_capacity` | capacity가 block 크기의 배수가 아닐 때 불완전한 꼬리를 쓰지 않는지 |
| `zoned_current_wp` | zone 시작이 아니라 report된 현재 WP에서 이어 쓰는지 |
| `zoned_skips_unwritable` | full/read-only/offline zone을 건너뛰는지 |
| `zoned_invalid_init` | NULL, zone 0개, block 크기 0, capacity > length를 거부하는지 |
| `concurrent` | 두 kthread의 linear 할당 128개가 중복되지 않는지 |
| `zoned_concurrent` | 동시 zoned 할당이 capacity 안에 정렬되고 중복되지 않는지 |

### MemTable — [`memtable-test.c`](../tests/unit/memtable-test.c)

내부 failure-injection helper까지 시험한다.

| 영역 | case |
|---|---|
| 생명주기 | `heap_lifecycle` |
| 기본 CRUD | `insert_lookup_update`, `missing`, `unordered_and_duplicate`, `latest_mapping` |
| compaction | `compact_empty`, `compact_mappings` — newer-wins 병합과 입력 table 불변성 |
| compaction 실패 | `compact_errors` — 잘못된 인자, 중간 allocation 실패 시 부분 결과 정리 |
| threshold 전환 | `threshold_freeze`, `threshold_compaction_failures` |
| 세대 lookup | `active_immutable_lookup` — active 우선, immutable fallback |
| 동시성 | `threshold_freeze_concurrent` |
| 명시적 freeze | `freeze`, `freeze_allocation_failure` |

### SSTable 포맷 — [`sstable-test.c`](../tests/unit/sstable-test.c)

장치 없이 순수 함수만 시험한다.

| case | 검증 내용 |
|---|---|
| `block_geometry` | 4 KiB block당 entry 256개, `zns_sst_nr_blocks()`와 `zns_sst_entries_in_block()`의 경계 |
| `header_roundtrip` | 헤더 encode/decode 왕복, 0으로 채워진 block을 헤더로 오인하지 않는지, `nr_blocks`/`nr_entries` 불일치 거부 |
| `block_find` | 이진 탐색의 첫/마지막/중간 hit, 사이값·범위 밖 miss, 부분만 채워진 꼬리 block의 0 padding, entry 1개, 잘못된 인자 |
| `memtable_scan` | `rb_first()`/`rb_next()` 순회가 정렬되어 있고 scan pass의 entry 수·min/max key가 tree와 일치하는지 |

### 슈퍼블록 — [`super-test.c`](../tests/unit/super-test.c)

역시 장치 없이 버퍼만 다룬다.

| case | 검증 내용 |
|---|---|
| `fits_one_block` | `struct zns_super_disk`가 metadata block 하나에 들어가는지 |
| `roundtrip` | encode/decode 왕복으로 geometry가 그대로 돌아오고, 그 결과가 자기 자신과 match하는지 |
| `rejects_foreign_blocks` | 0으로 채워진 block, 남의 데이터, version 불일치, 필드 한 개 변조, padding 1바이트 변조를 모두 거부하는지 |
| `matches_each_field` | geometry 필드가 하나라도 다르면 `-EINVAL`, uuid만 다르면 통과하는지 |

### Zone discovery — [`zone-info-test.c`](../tests/unit/zone-info-test.c)

유일하게 실제 장치가 필요한 커널 테스트라 `/dev/nullb0`가 없으면 FAIL이다. `/dev/nullb0`를 read-only로 열어 [`zns_zone_table_init()`](../src/zns-zone.c)을 호출하고 zone 개수, id-index 일치, `capacity <= length`, WP가 `[start, start + capacity]` 범위, zone start의 엄격한 증가, destroy 후 초기화를 검사한다.

## 2. 통합 테스트

### [`smoke.sh`](../tests/integration/smoke.sh)

최소 경로. 4 KiB 왕복 write/read와 상위 DM 장치가 conventional인지를 본다. block 하나만 쓰므로 zone 0만 reset하고 나머지 zone은 건드리지 않는다. 전체 실행에서 가장 먼저 돌아 기본적인 고장을 즉시 드러낸다.

### [`randwrite.sh`](../tests/integration/randwrite.sh)

4 MiB, 4 KiB, iodepth 32 `fio randwrite`. 판정은 **하위 zone 0 WP 전진**과 커널 I/O 오류 0. data readback은 하지 않는다 — 그건 `overwrite.sh`의 몫이다.

### [`overwrite.sh`](../tests/integration/overwrite.sh)

최신 mapping 판정을 한곳에 모았다(옛 `m1-verify.sh`를 흡수). 범위는 32 MiB로, matrix에서 덜어낸 CRC·overwrite 케이스의 커버리지를 그대로 이어받는다. `WORKLOAD_SIZE`로 조정한다.

1. 32 MiB `fio --verify=crc32c` read-after-write
2. 같은 범위 `--loops=3` 재작성 후에도 CRC 통과
3. 논리 block 100에 A → B → C를 쓰고 C가 읽히는지
4. 같은 block이 A도 B도 아닌지

### [`memtable-compaction.sh`](../tests/integration/memtable-compaction.sh)

`memtable_threshold=2`로 적재해 적은 I/O로 모든 세대 전환을 만든다. threshold 파라미터 적용 → immutable에만 있는 mapping read → 새 active mapping read → active가 immutable을 이기는지 → 첫 compaction 후 양 세대 생존 → 반복 compaction 후 전부 생존 → unmapped block zero-fill → I/O 오류 0.

### [`sstable-flush.sh`](../tests/integration/sstable-flush.sh)

`memtable_threshold=64`로 4 KiB 논리 block 512개를 써서 freeze를 여러 번 만들고, `flushing`과 `immutable`이 0이 될 때까지 `dmsetup status`를 폴링한 뒤 판정한다.

1. `sstables >= 1` — 실제로 디스크로 갔는지
2. `sst_entries`가 전체의 3/4 이상
3. `active + immutable + flushing < 512` — 메모리에서 실제로 내려갔는지. 이 케이스가 없으면 매핑이 전부 RAM에 남아 있어도 통과한다
4. 512개 전체 readback 일치
5. 가장 오래된 SSTable에만 있는 block 0, 5, 63 개별 확인
6. block 0 덮어쓰기에서 active MemTable이 flush된 SSTable을 이기는지
7. unmapped block zero-fill
8. 예약된 마지막 zone의 WP 전진
9. I/O 오류 0

### [`recovery.sh`](../tests/integration/recovery.sh)

매핑이 재시작을 건너 살아남는지 본다. zone은 한 번도 reset하지 않고 target만 `dmsetup remove` → `create`로 다시 세우며, 중간에 한 번은 모듈 자체를 rmmod/insmod한다. 논리 범위를 단계마다 겹치지 않게 나눠 써서 한 단계가 다른 단계의 block을 덮지 않는다.

1. 갓 포맷된 metadata zone의 WP가 `start + 8` — 슈퍼블록이 실제로 쓰였는지
2. threshold(64) 미만인 16개 block만 쓰고 재시작 — **종료 flush**만으로 살아남는 경로. `sstables == 0`, `active == 16`을 함께 확인해 fixture가 우연히 flush되지 않았음을 보장한다
3. 512개를 써서 flush를 낸 뒤 재시작 — **복구 스캔** 경로, 전체 readback 일치
4. 재시작 후 `sstables >= 1` — 스캔이 실제로 무언가를 주웠는지
5. 재시작 후에도 unmapped block zero-fill
6. SSTable로 내려간 block을 재시작 직전에 덮어쓰면 새 값이 읽히고 옛 값은 안 읽히는지 — **나이순 보장**. 종료 flush가 세대 순서대로 append하고 스캔이 그 순서를 유지해야만 통과한다
7. 모듈 reload 후에도 앞의 모든 데이터가 그대로인지
8. 재시작 후 이어 쓴 데이터가 두 번째 재시작 후에도 읽히는지 — `meta_wp`와 seq가 이어 붙는지
9. DM table 길이가 슈퍼블록과 다르면 target 생성이 거절되는지
10. I/O 오류 0

### [`write-failure.sh`](../tests/integration/write-failure.sh)

`null_blk`의 badblock 주입으로 overwrite의 하위 물리 쓰기 한 건만 실패시킨다. 실패가 상위에 전달되는지, 하위 WP가 움직이지 않는지, 이전 mapping이 보존되는지, fault 해제 후 다음 쓰기가 아직 소비되지 않은 append 위치에서 정상 재개되는지를 한 시나리오로 판정한다.

### [`metadata-format-safety.sh`](../tests/integration/metadata-format-safety.sh)

먼저 완전히 빈 장치에서 같은 모듈과 geometry로 target 생성이 성공하는 control을 확인한다. 그 뒤 두 가지 fail-closed 포맷 경계를 검사한다. data zone은 이미 사용됐는데 metadata zone만 비어 있으면 target 생성을 거부해야 하며, metadata zone 첫 block이 프로젝트 superblock이 아닌 foreign data여도 거부해야 한다. 두 경우 모두 거부 과정이 metadata WP를 움직이지 않아야 한다. control 덕분에 생성자가 전반적으로 고장 난 상태를 올바른 거부로 오인하지 않는다.

### [`metadata-torn-write.sh`](../tests/integration/metadata-torn-write.sh)

첫 SSTable payload 위치에 badblock을 넣어 header만 기록하고 payload를 실패시킨다. 이후 write와 정상 종료가 손상 header 뒤에 새 metadata를 append하지 않는지 먼저 확인하고, target을 내린 뒤 payload 위치에 임의 block을 직접 append한다. 복구는 불완전 tail과, 길이는 맞지만 CRC·구조가 다른 payload를 각각 fail-closed로 거부해야 한다.

### [`zone-boundary.sh`](../tests/integration/zone-boundary.sh)

zone 3개 이상인 장치에서 `2 * blocks_per_zone + 1`개 block을 연속으로 쓴다. 전체 readback 일치, zone 0·1의 WP가 경계에서 멈췄는지, zone 2의 WP가 정확히 한 block 전진했는지를 각각 별도 케이스로 판정한다. LSM 엔진이 linear 주소가 아니라 zone capacity를 따라가는지를 본다.

### [`randwrite-matrix.sh`](../tests/integration/randwrite-matrix.sh)

**필수 M1 파라미터 스윕.** 각 조합에서 workload 완료뿐 아니라 최종 데이터를 CRC로 검증한다. WP 전진과 명시적인 A → B → C 순서는 위의 전용 suite가 담당한다.

- 범위: 4 / 32 / 100 MiB
- request 크기: 4, 8, 16, 64 KiB
- iodepth: 1, 8, 32, 64

8 KiB 이상 요청은 공통 max-I/O 설정으로 4 KiB bio로 분할된다.

512 B·1 KiB·2 KiB와 부분 덮어쓰기의 주변 byte 보존은 [`integration/subblock-write.sh`](../tests/integration/subblock-write.sh)가 기본 `lsm`의 required gate로 검증한다. 더 다양한 크기, offset과 cross-block 조합은 extended matrix에서 다룬다.

고정된 다섯 case만으로는 크기 경계를 일반화할 수 없으므로 다음 parametric
suite도 같은 선택형 그룹에 둔다.

- [`request-size-matrix.sh`](../tests/integration/request-size-matrix.sh): direct
  block I/O의 `read/write/update/randwrite × request size × byte offset ×
  iodepth` Cartesian product. 기본 request에는 512B부터 1MiB까지와
  1536/2560/3584/4608B 경계를 포함한다. `update`는 fio 데이터 검증과 별도로
  enclosing 4KiB span의 전후 snapshot을 비교해 요청 범위 밖의 모든 byte가
  보존됐는지 확인한다.
- [`payload-size-matrix.sh`](../tests/integration/payload-size-matrix.sh): 정확한
  application payload 1B부터 256MiB까지를 buffered write로 표현하고 enclosing
  4KiB 범위를 direct read로 검증한다. write/update/randwrite를 분리한다.

raw block 주소는 sector 단위라 1B bio 자체는 만들 수 없다. 따라서
`payload=1B`의 성공은 kernel writeback이 정렬된 bio로 변환한 end-to-end 결과이고,
engine이 1B bio를 받았다는 뜻이 아니다. 파라미터 예시와 아직 남은 축은
[`13-io-size-test-matrix.md`](13-io-size-test-matrix.md)에 정리했다.

## 3. 시스템 테스트 — [`system/random-write-acceptance.sh`](../tests/system/random-write-acceptance.sh)

M1 충족 여부를 결정하는 단 하나의 실행이라, 좁은 테스트가 이미 다루는 동작도 의도적으로 다시 검사한다. 항상 `ZNS_ENGINE=lsm`으로 clean build하고, 하위 장치가 host-managed이며 필요한 writable capacity가 있는지 먼저 확인한다(부족하면 FAIL — 인수 테스트가 안 돌았는데 전체 실행이 초록으로 끝나서는 안 된다).

1. `memtable_threshold` module parameter 적용
2. 상위 DM queue의 `zoned` 속성이 `none`(conventional)
3. 공식 workload — 100 MiB / 4 KiB / iodepth 32 random write 25,600건의 최종 데이터를 CRC로 검증하고 설정·완료 건수를 **fio JSON으로** 검사
4. 겹치지 않는 32 MiB 범위에서 CRC read-after-write, 역시 JSON 검사
5. 논리 block 100의 A → B → C에서 C만 읽히는지
6. 전후 zone geometry 동일, WP가 뒤로 가지 않고 capacity를 넘지 않는지
7. 최소 한 zone의 WP가 전진했는지
8. 테스트 시간대 dmesg에 I/O error나 zoned write rejection이 없는지

M1의 random-write translation과 mapping 정확성을 강하게 검증하지만, 재부팅/모듈 reload 복구, filesystem mount, GC 후 재사용은 검증하지 않는다.

## 4. `extended` 프로필

`sudo ./test.sh extended`로 실행한다. 아직 M2를 현재 필수 마일스톤으로
승격하지 않았으므로 기본 `sudo ./test.sh`에는 포함하지 않는다. 각 suite는
[`support/lib/nullblk.sh`](../tests/support/lib/nullblk.sh)로 필요한 geometry의 전용 null_blk를
만들며 사용자가 준비한 `/dev/nullb0`는 재구성하지 않는다. DM target과
모듈을 먼저 내린 뒤 자신이 만든 configfs group만 제거한다.

- [`ext4-roundtrip.sh`](../tests/system/ext4-roundtrip.sh): 4 KiB ext4 format,
  10 MiB hash와 작은 파일·rename·link·truncate의 unmount/remount 보존,
  read-only `e2fsck`. subblock 지원을 선행 가정하지 않고 실제 실패가 작은
  bio를 가리킬 때 `integration/subblock-write`로 좁힌다.
- [`data-exhaustion.sh`](../tests/integration/data-exhaustion.sh): 물리 data capacity에서
  한 zone을 예약한 더 작은 논리 target을 만들고, 논리 범위를 한 번 채운 뒤
  overwrite로 예약 공간까지 소비한다. 그 다음 in-range overwrite의 bounded
  failure, 최신 mapping과 zone 상태 보존, 재시작 복구를 검증한다.
- [`metadata-exhaustion.sh`](../tests/integration/metadata-exhaustion.sh): SSTable 크기와
  zone capacity를 맞춰 예약 zone을 정확히 채운 뒤 다음 flush가 남긴
  `flushing` 세대의 read와 full metadata log 재개방을 검증한다.
- [`operation-contract.sh`](../tests/integration/operation-contract.sh): `fsync=1` workload
  호환성만 확인한다. crash durability를 주장하지 않는다. discard와 zeroout은
  queue에서 미지원으로 광고하고 기존 mapping을 바꾸지 않은 채 실패해야 한다.
- [`zone-capacity.sh`](../tests/integration/zone-capacity.sh): 실제 null_blk에서
  `zone_capacity < zone_size`로 두 capacity hole을 건너도 전체 readback과 WP가
  맞는지 확인한다.
- [`concurrency-lifecycle.sh`](../tests/integration/concurrency-lifecycle.sh): 서로 겹치지
  않는 네 writer와 status polling, `immutable=flushing=0` 수렴,
  `active < threshold`, 반복 detach/recreate 복구를 짧고 결정적으로 검사한다.

ext4 gate가 통과 가능한 제품 계약이 되면 같은 `system/` 계층에서
`required` 프로필로 승격한다. 그 전까지 red인 `extended` 항목은 미래
마일스톤 때문에 현재 M1 결과를 오염시키지 않는다.

## 5. `future` 프로필

`sudo ./test.sh future`로 실행한다. 이 프로필은 `ZNS_TESTING=1` 빌드에서만 존재하는
테스트 훅을 쓸 수 있지만 기본 M1 실행에는 포함되지 않는다.

### [`gc-cycle.sh`](../tests/system/gc-cycle.sh)

물리 data capacity를 `P`, whole-zone reserve를 `R`, 상위 논리 capacity를
`L = P - R`로 분리한다. `L`의 80%를 version 1로 초기화하고 `L`의 1.2배 횟수로
그 범위를 random overwrite한다. suite 자체가 `0.8L + 1.2L > P`를 먼저
판정하므로 backing device를 크게 잡아 GC 없이 통과할 수 없다.

[`versioned-io`](../tests/support/tools/versioned-io.c)가 logical block별 최신 version
manifest를 유지하고 전체 block 내용을 생성·검증한다. workload 완료,
`gc_runs`/`gc_moved`/`gc_resets` 증가, `gc_failures` 불변, relocation 후 전체
readback, target recreate 후 전체 readback을 각각 독립 case로 판정한다.
`dmsetup status`에는 bounded summary만 두며 per-zone 진단은 향후 debugfs 또는
test-only message 인터페이스로 분리한다.

### [`fsync-quiesced-recovery.sh`](../tests/integration/fsync-quiesced-recovery.sh)

volatile cache를 켜고 FUA를 꺼 둔 전용 null_blk에서 `fdatasync`를 실행해
`flush_requests`와 `flush_completed`가 실제 증가했는지 확인한다. 그 다음
`test_skip_shutdown_flush=1` 훅으로 clean-detach MemTable 직렬화만 생략하고
target을 다시 열어 동기화된 최신 mapping을 검증한다.

이 훅은 DM이 I/O를 quiesce한 뒤 실행되므로 **진짜 power loss나 mid-I/O
crash가 아니다**. VM/FEMU/reboot 기반 power-cut 검증은 외부 CI가 필요하다.
GC phase별 fault 기대값, metadata corruption 추가 순서, soak/benchmark 분리는
[`14-future-test-contracts.md`](14-future-test-contracts.md)에 고정했다.

## 6. 새 suite 추가

[`tests/README.md`](../tests/README.md)에 그대로 복사해 쓸 수 있는 골격이 있다. 요약하면 계층을 고르고 [`tests/suites.tsv`](../tests/suites.tsv)에 프로필을 등록한 뒤, `TARGET_NAME`과 `ZNS_REQUIRED_ENGINE`을 정하고 [`support/lib/init.sh`](../tests/support/lib/init.sh)를 source한다. 이어 `report_init` → 전제조건 → setup → `run_case` 나열 → `report_summary` 순서다. 케이스는 `errexit`가 켜진 subshell에서 돌므로 첫 실패 명령에서 그 케이스만 끝나고 나머지 suite는 계속 진행된다. 케이스는 `0`으로 통과, `fail "<사유>"`로 실패, `detail "key=value"`로 결과 줄에 짧은 필드를 덧붙인다.

## 7. 환경 준비 스크립트

[`scripts/nullblk-up.sh`](../scripts/nullblk-up.sh)는 configfs로 memory-backed, host-managed zoned null block device를 만든다. 기본값 2 GiB, 64 MiB zone. `NB_NAME`, `NB_SIZE_MB`, `NB_ZONE_SIZE_MB`로 조정한다. [`scripts/nullblk-down.sh`](../scripts/nullblk-down.sh)가 제거한다.

[`tests/support/lib/nullblk.sh`](../tests/support/lib/nullblk.sh)는 특정 size·zone size·zone
capacity나 volatile-cache 설정이 필요한 `extended`/`future` suite 전용 fixture다. configfs의 `index`를 읽어 실제
`/dev/nullbN`을 찾고, suite가 만든 장치만 추적해 정리한다.

[`scripts/build-run.sh`](../scripts/build-run.sh)는 엔진을 골라 빌드하고 `myzns-base` target을 만들어 두는 수동 실험용 도구다. 이제 어떤 테스트도 여기에 의존하지 않는다.

[`scripts/test-basic.sh`](../scripts/test-basic.sh)는 최초 M0 pass-through 테스트다. 상위 DM 장치가 zoned라는 전제가 conventional 노출로 바뀌면서 깨졌고, 역사적 기록으로만 남겨 두었다. `run.sh`는 실행하지 않는다.

## 8. 현재 테스트가 다루지 않는 범위

- 실제 power-loss/mid-I/O crash consistency — `future` 프로필은 quiesced-abort까지만 다룬다
- 다양한 SSTable payload byte corruption 단위 테스트. 중간 torn-write의 end-to-end fail-closed 동작은 `metadata-torn-write.sh`가 다룬다
- discard, write zeroes의 실제 지원 의미론. `extended` 프로필은 현재 미지원 계약만 검사한다
- GC source/destination/commit/reset 단계별 fault injection
- 장시간 동시 read/write race와 성능·latency 평가. `extended`는 짧은 결정적 stress만 다루고 `future` correctness gate는 수치를 합격 조건으로 삼지 않는다
