# 17. LSM 안전성 보강 인수인계

## 문서 목적

이 문서는 이번 코드 리뷰에서 발견하고 수정한 필수 안전성 문제를 다음 작업자에게
전달한다. 프로젝트를 처음 보는 사람도 이해할 수 있도록 최소한의 구조를 먼저 설명하고,
각 변경을 **문제 → 수정 → 결과** 순서로 정리했다.

저장장치와 실패 시나리오를 더 자세히 보고 싶다면
[16-m1-safety-failures-explained](16-m1-safety-failures-explained.md)를 참고한다. 이 문서는
현재 구현과 검증 결과를 빠르게 파악하기 위한 요약본이다.

---

## 1. 한눈에 보기

`dm-zns-base`의 LSM 엔진은 사용자의 덮어쓰기 요청을 ZNS 장치의 빈 위치에 순차
기록하고, `logical block → physical sector` mapping을 MemTable과 SSTable로 관리한다.

이번 작업의 공통 원칙은 다음과 같다.

> 성공하고 검증한 data와 metadata만 신뢰 가능한 상태로 공개한다.

| 영역 | 수정 전 위험 | 수정 후 동작 |
|---|---|---|
| 논리 용량 | metadata zone과 쓸 수 없는 zone tail까지 data 공간으로 계산 | zone별 4 KiB usable capacity를 넘으면 `-ENOSPC` |
| 최초 포맷 | data가 남아 있어도 metadata만 비면 새 장치로 포맷 | dirty data를 발견하면 superblock을 쓰지 않고 `-EUCLEAN` |
| SSTable 복구 | header와 길이만 확인하고 payload를 mapping으로 채택 | CRC, entry 구조, key 범위와 순서, sequence를 모두 검증 |
| metadata 쓰기 실패 | 불완전한 record 뒤에서 append를 재개할 수 있음 | partial write 또는 WP 불확실성이 생기면 현재 instance의 append 차단 |
| 초기화·산술 | 잘못된 data zone을 확인하기 전에 포맷하거나 큰 entry 수에서 overflow 가능 | allocator를 먼저 검증하고 overflow 없는 block 계산 사용 |
| 스크립트·테스트 | 커널과 다른 방식으로 target 크기 계산 | 커널과 같은 zone별 capacity 계산 사용 |

손상 상태를 자동으로 덮어쓰거나 고치지는 않는다. 기존 mapping을 안전하게 복원할 수
없으면 target 생성을 거부하는 **fail-closed** 정책이다.

---

## 2. 필요한 만큼만 보는 구조

### 2.1 ZNS 위에서 덮어쓰기를 처리하는 방법

ZNS의 sequential-write-required zone은 현재 write pointer(WP)부터 순서대로 써야 한다.
따라서 같은 논리 주소를 덮어쓸 때 기존 data를 제자리에서 바꾸지 않는다.

```text
요청: logical block 10에 A 기록 → B로 덮어쓰기

물리 기록: sector 0에 A → 다음 빈 sector 8에 B
최신 mapping: logical block 10 → physical sector 8
```

write는 하위 data write가 성공한 뒤에만 새 mapping을 MemTable에 게시한다. read는 최신
MemTable부터 SSTable 순서로 mapping을 찾고, mapping이 없으면 0으로 채운다.

### 2.2 data와 metadata 배치

마지막 zone 하나는 metadata 전용이며 data allocator가 사용하지 않는다.

```text
data:     [ data zone 0 ][ data zone 1 ] ... [ data zone N-1 ]
metadata: [ superblock ][ SSTable 1 ][ SSTable 2 ] ...
```

| 용어 | 의미 |
|---|---|
| sector | Linux block 주소 단위. 이 프로젝트에서는 512 byte |
| 4 KiB block | sector 8개. mapping과 append의 기본 단위 |
| zone capacity | zone에서 실제로 기록할 수 있는 sector 수 |
| zone length | 다음 zone까지의 주소 범위. capacity보다 클 수 있음 |
| MemTable | 메모리에 있는 최신 mapping의 정렬된 RB-tree |
| SSTable | MemTable을 metadata zone에 영속화한 정렬 mapping |

---

## 3. 필수 수정 사항

### 3.1 논리 target 크기 제한

**문제**

LSM 엔진은 마지막 zone을 metadata로 예약하지만 기존 helper와 수동 실행 스크립트는
하위 장치 전체 크기를 기준으로 DM target을 만들었다. 또한 allocator는 4 KiB 단위로만
쓰므로 각 zone 끝에 8 sector보다 짧게 남은 공간은 사용할 수 없다.

```text
zone 0 capacity 1,027 sectors → 1,024 sectors 사용 가능
zone 1 capacity 1,028 sectors → 1,024 sectors 사용 가능

raw 합계 2,055 != 실제 usable 합계 2,048
```

서로 다른 zone의 짧은 tail을 합쳐 하나의 block으로 쓸 수 없으므로 전체 합계를 한 번만
내림해서도 안 된다.

**수정**

[`zns_lsm_validate_logical_capacity()`](../src/engines/zns-engine-lsm.c)이 마지막 zone을
제외한 각 data zone에서 다음 값을 합산한다.

```text
zone_usable = capacity - (capacity % sectors_per_block)
```

요청한 `logical_sectors`가 합계를 넘으면 `-ENOSPC`를 반환한다. 같은 계산을
[`device.sh`](../tests/support/lib/device.sh)와
[`build-run.sh`](../scripts/build-run.sh)에도 적용했다.

**결과**

광고한 논리 공간을 allocator가 실제로 감당할 수 있다. 검사는 metadata open보다 먼저
실행되므로 oversized target 생성 실패가 media를 변경하지 않는다.

### 3.2 dirty data를 새 장치로 오인하지 않기

**문제**

data zone의 WP는 전진했지만 metadata zone이 비어 있으면 기존 physical data의 logical
주소를 복원할 수 없다. 기존 구현은 경고만 남기고 새 superblock을 써서 이 상태를 새
장치처럼 열었다. 이는 mapping이 사라진 상태를 정상으로 보이게 만드는 데이터 유실이다.

**수정**

[`zns_lsm_data_zones_dirty()`](../src/engines/zns-engine-lsm.c)이 모든 data zone의 WP를
확인한다. metadata가 비어 있고 data zone 하나라도 비어 있지 않으면
`zns_lsm_open_metadata()`가 `-EUCLEAN`을 반환한다.

**결과**

이 실패 경로에서는 superblock write나 zone reset을 하지 않는다. 관리자가 원본 media를
조사하거나 명시적으로 초기화할 수 있도록 그대로 둔다.

### 3.3 SSTable 전체를 검증한 뒤 복구

SSTable은 `[ header ][ payload ... ]` 구조이며 header에는 entry 수, block 수, sequence,
최소·최대 key와 payload CRC가 들어 있다.

**문제**

기존 복구는 header와 record 길이만 확인했다. header가 주장한 범위가 metadata WP 안에
있으면 payload가 실제 mapping인지 검증하지 않고 다음 SSTable로 넘어갔다. 이 경우
payload 자리에 놓인 임의 block이나 다음 SSTable header를 mapping entry로 오해할 수
있었다.

**수정**

[`zns_sst_load()`](../src/lsm-sstable.c)는 SSTable을 목록에 게시하기 전에 다음을 모두
검증한다.

1. magic과 format version
2. `nr_entries`와 `nr_blocks`의 관계
3. record 전체가 metadata WP 안에 있는지
4. 모든 payload block의 CRC와 실제 entry 수
5. logical key의 엄격한 오름차순
6. 실제 첫·마지막 key와 header의 min/max 일치
7. recovery 전체에서 sequence가 1부터 빠짐없이 증가하는지

**결과**

불완전한 tail은 내부적으로 `-ENODATA`로 식별한 뒤 engine에서 `-EUCLEAN`로 변환한다.
구조나 CRC 손상은 `-EUCLEAN`, 하위 read 실패는 해당 I/O error로 target 생성을 거부한다.
복구 도중 실패하면 앞에서 읽은 일부 SSTable도 공개하지 않고 임시 목록을 해제한다.

### 3.4 metadata partial write 뒤 append 차단

이번 재검토에서 가장 중요하게 보강한 경로다.

**문제**

SSTable은 header를 먼저 쓰고 payload를 쓴다. header write 후 payload write가 실패하면
media에는 불완전한 record가 남는다.

```text
실패 직후: [ super ][ torn H1 ][ 비어 있는 payload 위치 ]

위험한 재시도:
           [ super ][ torn H1 ][ retry H2 ][ retry P2 ]
                                   ^
                                   H1이 H2를 payload로 오인할 수 있음
```

실패 후 읽은 실제 WP가 예상 위치와 같더라도 안전하지 않다. WP 일치 여부는 이미 기록된
header의 존재를 없애 주지 않기 때문이다.

**수정**

[`zns_lsm_reconcile_failed_meta_write()`](../src/engines/zns-engine-lsm.c)은 실패 뒤 실제
WP와 이미 소비한 block 수를 함께 판단한다.

| 실패 상태 | 처리 |
|---|---|
| block을 하나도 쓰지 않았고 실제 WP도 시작점과 같음 | 나중에 재시도 가능 |
| header 또는 payload 일부를 씀 | incomplete record로 보고 append 차단 |
| WP report 실패 또는 예상값과 불일치 | 안전한 다음 위치를 모르므로 append 차단 |

append 차단은 메모리의 `meta_wp`를 `meta_end`로 설정해 현재 target instance에서 남은
metadata 공간을 사용하지 못하게 하는 조치다. 실제 장치 WP를 쓰거나 이동시키지 않는다.

**결과**

target을 다시 열 때는 실제 WP를 기준으로 전체 검증을 다시 한다.

- payload가 없으면 incomplete tail로 거부한다.
- 다른 내용이 payload 위치를 채웠으면 CRC 또는 구조 불일치로 거부한다.
- write가 실패로 보고됐더라도 올바른 record 전체가 기록됐다면 검증 후 복구할 수 있다.

현재 구현은 손상된 metadata를 자동 repair하지 않는다. 조사 후 명시적으로
reset/reformat하거나 향후 metadata zone 교체 기능이 필요하다.

### 3.5 초기화 순서와 block 수 overflow

**문제**

기존 초기화 순서는 metadata를 연 뒤 data allocator를 초기화했다. data zone geometry가
잘못됐으면 superblock을 쓴 다음 target 생성이 실패할 수 있었다. 또한
`nr_entries + entries_per_block - 1` 방식의 올림 계산은 `nr_entries`가 `U32_MAX`에
가까울 때 덧셈 overflow가 날 수 있었다.

**수정 및 결과**

초기화 순서를 다음처럼 바꿔 data zone 문제를 최초 metadata write 전에 발견한다.

```text
zone table 읽기
  → logical capacity 검증
  → data allocator 검증·초기화
  → metadata format/recovery
  → MemTable과 workqueue 생성
```

[`zns_sst_nr_blocks()`](../src/lsm-sstable.c)은 header 한 block을 포함해 몫과 나머지로
전체 block 수를 계산한다.

```text
1
  + nr_entries / entries_per_block
  + (nr_entries % entries_per_block != 0)
```

`U32_MAX` 경계도 unit test에 추가했다.

---

## 4. 스크립트와 회귀 테스트

### 4.1 실행 스크립트

[`scripts/build-run.sh`](../scripts/build-run.sh)은 LSM 선택 시 zone report에서 data zone별
usable capacity를 계산한다. 이 계산에 실패하면 기존 target 제거, zone reset, module
교체 전에 종료한다.

```bash
sudo bash scripts/build-run.sh lsm
sudo dmsetup status myzns-base
```

기본 하위 장치는 `/dev/nullb0`, target 이름은 `myzns-base`다. `UNDERLYING`과
`TARGET_NAME` 환경 변수로 바꿀 수 있다. 엔진 기본값은 `append4k`이며 `ZNS_ENGINE` 또는
첫 번째 인자로 선택한다.

### 4.2 테스트별 증명 범위

| 테스트 | 핵심 검증 |
|---|---|
| [`metadata-format-safety`](../tests/integration/metadata-format-safety.sh) | oversized target의 무변경 거부, 정상 최초 포맷, dirty data와 foreign metadata 거부 |
| [`metadata-torn-write`](../tests/integration/metadata-torn-write.sh) | header-only 실패 뒤 append 차단, incomplete tail과 임의 payload의 무변경 거부 |
| [`recovery`](../tests/integration/recovery.sh) | 포맷 당시 논리 길이로 재생성, geometry mismatch 거부 |
| [`sstable-test.c`](../tests/unit/sstable-test.c) | `U32_MAX` entry의 block 수 계산 |
| [`zone-info.sh`](../tests/unit/zone-info.sh) | zone마다 4 KiB 미만 tail을 따로 제외하는 capacity 계산 |

`metadata-torn-write`는 첫 SSTable payload 위치에 `null_blk` badblock을 주입한다. 실패
뒤 추가 write와 target 제거가 metadata WP를 더 전진시키지 않는지 확인하고, payload가
없거나 임의 값으로 채워진 두 경우 모두 reopen이 media를 바꾸지 않고 실패하는지
검증한다.

---

## 5. 검증 결과와 재실행 방법

이번 작업 환경에서 다음 검사를 실제로 통과했다.

```text
make -C src W=1                                PASS
make -C tests/unit W=1                         PASS
userspace tools: -Wall -Wextra -Werror         PASS
모든 scripts/tests shell 파일: bash -n         PASS
tests/run.sh --list                            PASS
git diff --check                               PASS
```

GCC patch version 차이와 `vmlinux` 부재로 BTF 생성을 생략한다는 경고는 있었지만 빌드는
성공했다. 실제 kernel module 기반 테스트는 작업 환경에 passwordless `sudo`가 없어
실행하지 못했다. root 권한이 있는 Linux 환경에서 다음 순서로 확인해야 한다.

```bash
sudo bash scripts/nullblk-up.sh

sudo VERBOSE=1 ./test.sh metadata-format-safety
sudo VERBOSE=1 ./test.sh metadata-torn-write
sudo VERBOSE=1 ./test.sh recovery
sudo VERBOSE=1 ./test.sh zone-info

sudo ./test.sh            # 기본 release gate
sudo ./test.sh extended   # capacity·concurrency·request-size 확장 검사
```

실패 시 summary와 함께 `dmesg`, `dmsetup status`, `blkzone report`를 확인한다.

```bash
sudo dmesg | grep -E 'zns-base|blk_update_request|I/O error' | tail -100
sudo dmsetup status <target-name>
sudo blkzone report /dev/nullb0
```

---

## 6. 현재 범위와 한계

### 6.1 현재 보장하려는 범위

- 4 KiB mapping 단위의 정렬·부분 block read/write
- 하위 data write 성공 후 mapping 게시
- zone capacity hole을 건너뛰는 append
- 정상적인 target 제거 시 resident MemTable flush
- 정상 종료 후 target 재생성과 module reload recovery
- 손상되거나 불완전한 metadata의 fail-closed 거부
- 포맷 geometry와 다른 target 길이의 재사용 거부

### 6.2 아직 없는 기능

- WAL 기반 power-loss/crash consistency와 `fsync` 연계
- SSTable compaction과 level 구조
- data/metadata garbage collection과 zone 재사용
- 손상 metadata의 자동 repair 또는 교체
- 여러 data zone 사이의 병렬 write 최적화
- 장시간 KASAN/KCSAN/lockdep 및 실제 SSD 검증

정상적인 `dmsetup remove` 뒤의 복구와 전원 차단 뒤의 복구는 다르다. 현재 shutdown
flush는 정상 종료 경로에 의존한다.

---

## 7. 다음 작업자를 위한 읽기 순서

| 순서 | 파일 | 확인할 내용 |
|---|---|---|
| 1 | [`zns-engine-lsm.c`](../src/engines/zns-engine-lsm.c) | `zns_engine_init()`, metadata open/recovery, failed-write reconciliation |
| 2 | [`lsm-sstable.c`](../src/lsm-sstable.c) | `zns_sst_write()`와 `zns_sst_load()`의 write/recovery 계약 |
| 3 | [`metadata-format-safety.sh`](../tests/integration/metadata-format-safety.sh) | 용량·최초 포맷의 fail-closed 조건 |
| 4 | [`metadata-torn-write.sh`](../tests/integration/metadata-torn-write.sh) | partial metadata write 재현과 판정 |
| 5 | [10-components](10-components.md), [11-engines](11-engines.md), [12-tests](12-tests.md) | 전체 구성 요소, 엔진 차이, 테스트 구조 |
| 6 | [16-m1-safety-failures-explained](16-m1-safety-failures-explained.md) | 저장장치 기초와 상세 실패 시나리오 |

---

## 8. 브랜치와 커밋

작업 브랜치는 `feat/lsm-rmw`, 원격 브랜치는 `origin/feat/lsm-rmw`다.

| 커밋 | 내용 |
|---|---|
| `2555578` | LSM recovery·capacity·fail-closed 처리와 회귀 테스트 |
| `e5af358` | 수동 실행 스크립트의 LSM usable capacity 계산 |
| `020a7f7` | 코드·엔진·테스트·안전성 설계 문서 |
| `27df7fe` | 8월 월간 보고서와 초안 |

이 문서는 위 변경의 배경, 현재 동작, 검증 범위와 다음 작업 순서를 한곳에서 설명하는
후속 인수인계 문서다.
