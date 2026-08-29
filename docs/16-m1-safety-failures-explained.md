# 16. M1 안전성 실패를 처음부터 이해하기

이 문서는 저장장치와 ZNS를 처음 접하는 사람을 대상으로 한다. 먼저 sector,
block, zone, write pointer, reset이 무엇인지 설명한 뒤, 현재 우선적으로 보고 있는
네 가지 테스트를 차례대로 해설한다.

- `integration/write-failure`
- `integration/metadata-format-safety`
- `integration/metadata-torn-write`
- `integration/concurrency-lifecycle`

각 절은 다음 네 질문에 답한다. 실패 원인 절의 “현재”는 최초 분석 당시의
구현을 뜻하며, 아래 안전성 수정은 현재 코드와 required 테스트에 반영되어 있다.

1. 테스트가 실제로 무엇을 하는가?
2. 왜 그 조건을 만족해야 하는가?
3. 수정 전 구현은 왜 실패했는가?
4. 어떤 구조로 수정했는가?

이 문서는 실패 재현과 수정 근거를 함께 남기는 설계 기록이다.

## 이 문서를 읽는 방법

처음 읽는다면 1장의 기초 용어를 먼저 읽는다. 그 다음 실제 수정 순서대로
2장 → 3장 → 4장 → 5장을 읽으면 된다.

시간이 부족하다면 각 문제의 `핵심` 인용문과 `수정 완료 기준`만 먼저 읽고,
구현할 때 해당 절의 상세 설명으로 돌아온다.

문서의 표시는 다음 의미다.

| 표시 | 의미 |
|---|---|
| `[수정 전]` | 최초 실패를 재현했을 때 소스 코드의 동작 |
| `[반영]` | 현재 소스 코드와 테스트에 적용된 수정 |
| `[확정]` | 테스트와 소스만으로 원인을 특정할 수 있음 |
| `[추가 확인]` | 상세 실행 로그가 있어야 남은 원인을 특정할 수 있음 |

## 먼저 보는 전체 그림

| 테스트 | 쉽게 말하면 | 수정 전 핵심 문제 | 현재 반영 상태 |
|---|---|---|---|
| `write-failure` | 실패한 새 주소로 주소록을 바꾸지 않았는가? | 실제 write 성공 전에 mapping을 바꿈 | ordered worker에서 완료 후 commit, 안전할 때만 예약 rollback |
| `metadata-format-safety` | 주소록 없는 기존 디스크를 새 디스크로 오인하지 않는가? | 위험을 경고만 하고 새 superblock을 씀 | dirty data와 oversized target을 metadata write 전에 거부 |
| `metadata-torn-write` | 반만 써진 주소록 조각을 정상으로 믿지 않는가? | 저장된 payload CRC를 복구 때 검사하지 않음 | 부분 record 뒤 append 차단, payload/구조/sequence 검증 |
| `concurrency-lifecycle` | 동시 write와 재시작의 순서가 맞는가? | 예약 순서만 보호하고 실제 완료는 추적하지 않음 | 단일 ordered I/O worker로 정확성 확보, zone 간 병렬화는 후속 최적화 |

네 문제를 관통하는 규칙은 하나다.

> **실제로 성공하고 검증된 상태만 mapping과 metadata에 공개한다.**

뒤의 네 장은 이 규칙이 data write, 최초 format, metadata recovery, 동시성에서 각각
어떻게 적용되는지를 설명한다.

---

## 1. 가장 먼저 알아야 할 저장장치 용어

### 1.1 byte, sector, 4 KiB block

저장장치는 아주 긴 바이트 배열처럼 생각할 수 있다. 예를 들어 4 KiB 데이터를
저장하려면 연속된 4,096 byte가 필요하다. 하지만 Linux block layer는 보통 주소를
byte가 아니라 **sector** 단위로 표현한다.

Linux block layer가 이 프로젝트의 주소 계산에 사용하는 logical sector 하나는
512 byte다. SSD 내부의 실제 물리 sector 크기와 혼동하지 않도록 주의한다.

```text
1 sector = 512 byte
8 sectors = 4,096 byte = 4 KiB
```

프로젝트의 기본 mapping 단위는 4 KiB다. 코드의
`ZNS_BASE_BLOCK_SECTORS = 8`이 바로 “한 mapping block은 sector 8개”라는 뜻이다.

```text
sector 번호        0  1  2  3  4  5  6  7 | 8  9 ... 15
4 KiB block 번호   └──────── block 0 ─────┘ └─ block 1 ─┘
```

테스트에서 `logical block 100`이라고 말하면, 상위 DM 장치의 sector로는
`100 × 8 = 800`부터 시작하는 4 KiB 범위를 뜻한다.

### 1.2 logical 주소와 physical 주소

사용자와 파일시스템은 DM 장치의 **logical 주소**를 본다. 실제 ZNS 장치에
기록되는 위치는 **physical 주소**다.

```text
사용자가 보는 주소             실제 ZNS에 기록된 주소

logical block 100  ──mapping──> physical sector 0
logical block 200  ──mapping──> physical sector 8
```

같은 logical block 100을 다시 쓰더라도 ZNS의 기존 sector를 제자리에서 덮어쓰지
않는다. 다음 빈 physical 위치에 새 데이터를 쓰고 mapping만 바꾼다.

```text
처음 A 쓰기
logical block 100 ─────────────> physical sector 0: A

B로 덮어쓰기
logical block 100 ─────────────> physical sector 8: B
                                  physical sector 0: A  (이전 데이터, 더는 최신 아님)
```

이전 A는 즉시 지워지지 않는다. mapping에서 제외되어 **invalid data**가 될 뿐이다.
나중에 GC가 유효한 데이터를 다른 곳으로 옮기고 zone 전체를 reset할 때 공간을
회수한다.

### 1.3 zone과 write pointer

ZNS 장치는 전체 공간을 여러 개의 큰 **zone**으로 나눈다. zone은 연속된 sector의
범위다. 예를 들어 zone 크기가 64 MiB라면 한 zone에는 다음만큼의 sector가 있다.

```text
64 MiB / 512 byte = 131,072 sectors
```

host-managed sequential zone에는 **write pointer(WP)**가 있다. 다음 write는 WP가
가리키는 위치에서 시작해야 한다.

```text
zone 시작                                           zone 끝
│                                                       │
│ 이미 기록됨 │ 이미 기록됨 │ 다음 빈 공간              │
                              ↑
                              write pointer
```

WP보다 앞은 이미 사용한 공간이다. WP보다 뒤의 임의 위치에 건너뛰어 쓸 수도 없다.

```text
WP에서 쓰기          허용
WP보다 앞에 덮어쓰기  금지
WP보다 뒤에 건너뛰기  금지
```

4 KiB write가 성공하면 WP는 sector 8개만큼 전진한다.

```text
write 전 WP = 1,000
write 범위   = sector 1,000 ... 1,007
write 후 WP = 1,008
```

### 1.4 쓰기의 단위와 지우기의 단위

ZNS 장치가 반드시 4 KiB만 쓸 수 있다는 뜻은 아니다. 장치와 block layer가 허용하는
범위에서는 여러 sector 크기의 write가 가능하다. 다만 현재 `lsm` 엔진은 설계를
단순화하여 다음 요청만 받는다.

```text
크기: 정확히 4 KiB = 8 sectors
주소: 4 KiB 경계에 정렬
```

반면 host가 볼 수 있는 지우기 단위는 sector나 4 KiB block이 아니라 **zone
전체**다. ZNS에서는 이를 zone reset이라고 부른다.

```text
쓰기 단위(현재 프로젝트): 4 KiB
reset 단위:               zone 전체, 예: 64 MiB
```

zone의 중간 4 KiB만 지우는 명령은 없다. zone reset을 하면 그 zone의 모든 데이터가
사라지고 WP가 zone 시작으로 돌아간다.

실제 SSD 내부 NAND에는 별도의 page와 erase block이 있지만, 이 프로젝트가 block
layer에서 직접 다루는 host-visible 단위는 sector, 4 KiB mapping block, zone이다.

### 1.5 data zone과 metadata zone

현재 LSM 엔진은 마지막 zone 하나를 metadata 전용으로 예약하고, 그 앞의 zone들을
사용자 데이터 저장에 쓴다.

```text
[ data zone 0 ][ data zone 1 ] ... [ data zone N-1 ][ metadata zone ]
```

metadata에는 logical 주소가 어느 physical sector를 가리키는지 기록한다. 데이터가
아무리 온전해도 mapping metadata가 없으면 어느 데이터가 어떤 logical block의
최신 버전인지 알 수 없다.

metadata zone의 배치는 다음과 같다.

```text
[ superblock ][ SSTable 1 ][ SSTable 2 ] ...
```

- superblock: 이 장치가 우리 형식인지, zone 수와 크기가 맞는지 식별한다.
- SSTable: logical block → physical sector mapping 묶음을 저장한다.

superblock과 SSTable도 각각 4 KiB block 단위로 순차 append한다.

### 1.6 MemTable과 SSTable

새 mapping은 먼저 RAM의 MemTable에 들어간다.

```text
active MemTable
    ↓ threshold 도달
immutable MemTable
    ↓ background flush 중
flushing MemTable
    ↓ metadata zone에 기록 완료
SSTable
```

각 상태의 의미는 다음과 같다.

| 상태 | 위치 | 의미 |
|---|---|---|
| pending write `[처리 중]` | 하위 I/O 처리 중 | physical write 성공 여부가 아직 확정되지 않음 |
| active | RAM | 성공이 확정된 최신 mapping을 새로 받는 table |
| immutable | RAM | 더는 변경하지 않고 flush를 기다리는 snapshot |
| flushing | RAM + metadata I/O | SSTable로 기록 중인 snapshot |
| SSTable | metadata zone | 정상 재시작 후 복구할 수 있는 mapping |

중요한 규칙은 **pending write를 MemTable에 넣으면 안 된다**는 것이다. MemTable은
하위 write까지 성공하여 읽을 수 있음이 확정된 mapping만 담아야 한다.

여기서 pending은 앞으로 명시적으로 도입해야 할 상태다. 현재 LSM 코드는 별도의
pending 상태 없이 하위 write를 제출하기 전에 mapping을 active에 넣는다. 이것이
`write-failure`의 직접적인 원인이다.

### 1.7 코드와 테스트에서 자주 나오는 용어

| 용어 | 이 문서에서의 뜻 |
|---|---|
| DM(Device Mapper) | 한 block device 위에 변환 계층을 만들어 새 `/dev/mapper/...` 장치를 제공하는 Linux 기능 |
| bio | Linux block layer가 전달하는 한 번의 I/O 요청 객체. 주소, 크기, READ/WRITE 종류를 담는다. |
| allocator | 다음 데이터를 어느 physical sector에 쓸지 예약하는 코드 |
| mapping | logical block과 최신 physical sector의 연결 정보 |
| append | 기존 위치를 덮지 않고 현재 WP 뒤에 이어 쓰는 것 |
| flush | 문맥에 따라 RAM 상태를 디스크에 내리거나, 앞선 I/O의 완료를 장치에 요구하는 동작. 이 문서의 SSTable flush는 전자다. |
| queue depth | 완료를 기다리는 동안 동시에 진행하도록 허용한 I/O 요청 수 |
| workqueue | 당장 처리할 수 없는 커널 작업을 worker thread가 나중에 실행하도록 맡기는 queue |
| ticket | write를 접수한 순서를 나타내는 단조 증가 번호 |
| active zone | 현재 새 data write를 받고 있는 zone |
| badblock | 선택한 sector의 I/O를 실패시키는 `null_blk` 테스트 기능 |
| CRC | 데이터로 계산한 짧은 검사값. 저장한 값과 다시 계산한 값이 다르면 손상을 의심한다. |
| UUID | 이 저장 형식의 한 수명을 구분하는 고유 식별값 |
| dirty zone | WP가 시작 위치보다 앞으로 가서 한 번이라도 write된 흔적이 있는 zone |
| foreign metadata | 이 프로젝트가 만든 superblock으로 해석할 수 없는 다른 데이터 |
| torn write | write 일부만 반영되고 나머지는 빠진 상태 |
| fail-closed | 안전성을 확인할 수 없으면 추측해서 열지 않고 오류로 거부하는 정책 |

테스트 도구도 역할만 알면 읽기 쉽다.

| 도구 | 역할 |
|---|---|
| `dd` | 지정한 크기의 데이터를 block device에 쓰거나 읽는다. |
| `fio` | 크기, 위치, 병렬성 등을 조절해 많은 I/O를 발생시키고 검증한다. |
| `blkzone` | zone 시작, 크기, capacity, WP를 조회하거나 zone을 reset한다. |
| `dmsetup` | DM target을 만들고 제거하며 상태를 조회한다. |

### 1.8 한 번의 write가 지나가는 길

수정이 완료된 뒤의 이상적인 4 KiB write 흐름을 먼저 보면 뒤의 문제들이 쉽게
연결된다.

```text
1. 사용자 또는 파일시스템
   logical block 100에 B 쓰기 요청
        ↓
2. Linux block layer
   주소와 크기를 담은 bio 생성
        ↓
3. DM zns-base target
   logical block 100이라는 원래 주소 확인
        ↓
4. allocator
   data zone의 현재 WP에서 physical sector P1 예약
        ↓
5. 하위 ZNS 장치
   P1에 B를 쓰고 성공 또는 실패를 반환
        ↓
6. 성공한 경우에만 MemTable
   logical block 100 → P1 mapping 공개
        ↓
7. 사용자 bio 완료
   이제부터 B를 최신 데이터로 읽을 수 있음
```

MemTable이 threshold에 도달하면 이 흐름과 별도로 metadata flush가 실행된다.

```text
active → immutable → flushing → metadata zone의 SSTable
```

이 문서의 네 문제는 위 흐름의 서로 다른 경계가 무너진 경우다.

- `write-failure`: 5번 성공을 기다리지 않고 6번을 먼저 수행한다.
- `metadata-format-safety`: 기존 주소록이 없는 media를 새 장치로 잘못 판단한다.
- `metadata-torn-write`: 별도 metadata flush가 저장한 주소록 조각의 완전성을 복구 때 검증하지 않는다.
- `concurrency-lifecycle`: 여러 요청의 4~7번 순서와 종료 시점을 안전하게 조정하지 못한다.

---

## 2. `write-failure`: 실패한 데이터로 mapping이 바뀌면 안 된다

> **핵심:** B 덮어쓰기가 실패했다면, 이전에 성공한 A가 계속 읽혀야 한다.

### 2.1 테스트가 확인하는 것

테스트는 logical block 100에 4 KiB 패턴 A를 먼저 쓴다.

```text
logical block 100 → physical sector P0: A
```

그 다음 zone WP, 즉 다음 write가 갈 physical sector `P1`을 알아내고 `null_blk`의
badblock 기능으로 그 위치만 고장 낸다. badblock은 선택한 sector 범위의 I/O를
강제로 실패시키는 테스트용 장치 기능이다.

이 상태에서 같은 logical block 100에 B를 쓴다.

```text
B overwrite
logical block 100 → physical sector P1: 쓰기 실패
```

테스트는 다음을 차례로 확인한다.

1. B write가 성공으로 보고되지 않고 상위 사용자에게 실패가 전달되는가?
2. 완전히 실패한 write이므로 실제 zone WP가 P1에 그대로 있는가?
3. logical block 100을 읽으면 여전히 이전의 A가 나오는가?
4. badblock을 제거한 뒤 C를 쓰면 소비되지 않은 P1을 재사용하는가?
5. 마지막 읽기에서 C가 나오는가?

이를 한 문장으로 줄이면 다음과 같다.

> 실패한 overwrite는 성공한 최신 버전이 아니므로 기존 mapping을 바꾸면 안 된다.

### 2.2 왜 반드시 만족해야 하는가

사용자에게 write 실패를 반환했는데도 내부 mapping이 바뀌면, 이전에 정상적으로
저장한 A까지 읽을 수 없게 된다. 하나의 실패가 새 데이터 B뿐 아니라 과거의 정상
데이터 A도 파괴하는 셈이다.

```text
허용되는 결과
B write 실패 → A가 계속 읽힘

허용되지 않는 결과
B write 실패 → mapping은 B 위치를 가리킴 → B도 A도 읽을 수 없음
```

이 성질을 write atomicity라고 부를 수 있다. 여기서 atomic은 “mapping 관점에서
write가 성공한 전체 상태 또는 실패 전 상태 중 하나로만 보인다”는 뜻이다.

### 2.3 `[수정 전·확정]` 구현이 실패한 이유

수정 전 `zns_lsm_write()`는 다음 순서로 동작했다.

```text
1. allocator가 P1 예약
2. allocator 내부 WP를 P1 + 8로 미리 전진
3. MemTable mapping을 P1로 변경
4. bio를 P1으로 remap하여 하위 장치에 제출
5. 하위 write가 성공하거나 실패
```

문제는 3번이 5번보다 먼저라는 점이다. 엔진은 write가 실제로 성공했는지 알기
전에 mapping을 공개한다. 하위 write가 실패해도 이를 되돌리는 callback이 없다.

또한 allocator의 WP는 **소프트웨어가 예상하는 WP**다. badblock write가 완전히
실패하면 실제 장치 WP는 움직이지 않지만 allocator의 복사본은 이미 8 sectors
전진했다. 이 때문에 다음 write가 아직 쓸 수 없는 뒤쪽 위치로 건너뛰어 ZNS
순차 쓰기 규칙까지 위반할 수 있다.

```text
실제 장치 WP:     P1
allocator 예상 WP: P1 + 8
                   ↑ 서로 불일치
```

관련 코드:

- [`zns_lsm_write()`](../src/engines/zns-engine-lsm.c)
- [`zns_allocator_alloc()`](../src/zns-allocator.c)

### 2.4 `[반영]` 수정 방향

write를 두 단계로 나눈다.

```text
prepare
  → 요청 ticket 발급
  → zone과 physical 위치 예약
  → 하위 write 제출

commit
  → 하위 write 성공 확인
  → 최신 ticket인지 확인
  → 그때 MemTable mapping 공개
  → 원본 bio 성공 완료
```

실패하면 commit을 하지 않는다.

```text
abort
  → 기존 mapping 유지
  → 실제 zone WP 확인
  → WP가 그대로면 reservation 반환
  → WP가 전진했거나 불명확하면 해당 위치를 소비된 invalid block으로 처리
  → 원본 bio 실패 완료
```

성능을 위해 모든 write를 하나의 mutex로 직렬화할 필요는 없다. 권장 구조는
**zone별 ordered queue + 여러 active zone**이다.

```text
zone 0 queue: A → B → C             같은 zone은 제출 순서 보장
zone 1 queue: D → E                 서로 다른 zone은 병렬
zone 2 queue: F → G
```

같은 logical block에 여러 write가 겹치면 완료 순서가 뒤집힐 수 있으므로 요청
접수 시 단조 증가 ticket을 발급한다.

```text
A: logical 100, ticket 10
B: logical 100, ticket 11

B가 먼저 성공한 뒤 A가 성공해도
10 < latest_committed_ticket[100]이므로 A는 mapping을 되돌리지 않는다.
```

ticket 확인, MemTable 삽입, latest ticket 갱신은 logical block별 lock 아래 하나의
commit으로 처리한다. 순서는 다음과 같아야 한다.

```text
ticket이 현재 최신인지 확인
→ MemTable 삽입
→ 삽입 성공 뒤 latest ticket 갱신
```

latest ticket을 먼저 바꾸고 MemTable 삽입에 실패하면, 더 오래된 정상 mapping까지
최신 후보에서 제외되어 mapping이 사라질 수 있다.

### 2.5 MemTable flush와 pending write의 관계

pending write가 있는 동안 기존 active가 freeze되어도 괜찮다. flush는 그 시점까지
**성공이 확정된 mapping의 snapshot**만 가져간다.

```text
처음
active:  X, Y, Z
pending: A

freeze 후
flushing: X, Y, Z
active:   비어 있음
pending:  A

A 성공 후
flushing: X, Y, Z
active:   A
```

A는 완료 시점의 새 active에 들어간다. 같은 LBA의 더 최신 mapping이 이미
SSTable로 이동했다면 logical-block ticket이 늦게 완료된 오래된 write를 거부한다.

일반 background flush는 pending write를 기다릴 필요가 없다. 다만 target 제거는
모든 data write queue를 먼저 drain하고, 성공한 mapping이 모두 publish된 뒤 남은
MemTable을 SSTable로 내려야 한다.

```text
새 요청 중단
→ zone write queue drain
→ mapping commit 완료
→ background SSTable flush queue drain
→ 남은 MemTable 종료 flush
→ 자료구조 해제
```

### 2.6 수정 완료 기준

다음이 모두 성립해야 이 문제를 해결한 것으로 본다.

- 하위 write가 실패하면 원본 bio도 실패로 끝난다.
- 실패한 write의 mapping은 active, immutable, flushing, SSTable 어디에도 공개되지 않는다.
- 같은 logical block의 이전 성공 데이터가 계속 읽힌다.
- 실제 WP가 움직이지 않은 완전 실패에서는 다음 write가 그 위치를 안전하게 재사용한다.
- 실제 WP가 움직였거나 불명확한 실패에서는 그 위치를 재사용하지 않는다.
- 같은 LBA write의 완료 순서가 뒤집혀도 큰 ticket의 mapping이 최종 승자가 된다.

---

## 3. `metadata-format-safety`: 기존 데이터 위에 새 빈 형식을 만들면 안 된다

> **핵심:** data가 남아 있는데 주소록만 없다고 해서 새 빈 장치로 format하면 안 된다.

### 3.1 테스트가 확인하는 것

이 suite에는 세 시나리오가 있다.

#### 시나리오 A: 완전히 빈 장치

모든 zone을 reset한 뒤 target 생성을 시도한다.

```text
data zones:     비어 있음
metadata zone: 비어 있음
```

이 경우에는 새 superblock을 쓰고 format을 시작해도 안전하다. 테스트는 target
생성이 성공하는지 확인한다. 뒤의 거부 테스트들이 “target 생성 기능 자체가
고장 나서 우연히 실패한 것”이 아님을 보장하는 control case이기도 하다.

#### 시나리오 B: data는 있는데 metadata는 없음

첫 data zone에 4 KiB를 직접 쓴 뒤 metadata zone은 빈 상태로 둔다.

```text
data zone 0:    데이터 존재, WP 전진
metadata zone: 비어 있음
```

테스트는 target 생성을 거부하고, 거부 과정에서 metadata WP도 전혀 움직이지
않기를 요구한다.

#### 시나리오 C: metadata 첫 block이 우리 superblock이 아님

metadata zone 첫 4 KiB에 `F` 패턴을 직접 쓴다. 형식상 foreign data다.

```text
metadata zone: [ FFFF... ][ 빈 공간 ... ]
```

테스트는 이를 우리 superblock으로 받아들이지 않고 target 생성을 거부하는지,
그 뒤에 새 metadata를 덧붙여 원본을 더 훼손하지 않는지 확인한다.

수정 전 실행 결과에서는 시나리오 B만 실패했다. 현재는 foreign superblock뿐 아니라
“dirty data + empty metadata”도 media를 변경하기 전에 거부한다.

### 3.2 왜 반드시 만족해야 하는가

data zone의 physical block만 보고는 logical 주소를 복원할 수 없다. 예를 들어
physical sector 1,000에 데이터가 있어도 그것이 logical block 5의 최신 버전인지,
logical block 900의 오래된 버전인지 알 수 없다.

이 상태에서 빈 metadata zone에 새 superblock을 쓰면 시스템은 기존 데이터의
mapping을 복구할 방법이 없다는 사실을 숨기고 새 장치처럼 동작한다.

```text
실제 상태: 기존 데이터가 있으나 mapping을 잃음
잘못된 판단: 새 빈 장치임
결과: 기존 데이터는 조용히 유실되고 새 쓰기와 섞임
```

이런 경우는 자동으로 고쳐 쓸 대상이 아니라 관리자에게 “이 장치는 안전하게 열 수
없다”고 알려야 한다. 이것이 fail-closed다.

### 3.3 `[수정 전·확정]` 구현이 실패한 이유

수정 전 `zns_lsm_open_metadata()`는 metadata zone이 비어 있을 때 data zone의 WP를
검사한다. 하지만 dirty data를 찾더라도 오류를 반환하지 않고 경고만 출력한다.

```text
dirty data 발견
→ DMWARN 로그 출력
→ 계속 진행
→ 새 UUID 생성
→ metadata zone에 superblock 기록
→ target 생성 성공
```

코드의 경고 문구도 mappings are unrecoverable이라고 정확히 말하지만, 실제 동작은
그 위험한 format을 계속 수행한다.

관련 코드: [`zns_lsm_open_metadata()`](../src/engines/zns-engine-lsm.c).

### 3.4 `[반영]` 수정 방향

metadata가 비었을 때는 어떠한 write도 하기 전에 모든 data zone이 정말 비었는지
확인한다.

```text
metadata 비어 있음?
  ├─ 아니요 → 기존 superblock 검증 후 recovery
  └─ 예
       ├─ 모든 data zone도 비어 있음 → 새 format 허용
       └─ 하나라도 dirty → -EUCLEAN 등으로 target 생성 거부
```

최소 수정은 경고 뒤에 계속 진행하는 대신 즉시 오류를 반환하는 것이다. 이 검사와
오류 반환은 `zns_super_write()`보다 반드시 앞에 있어야 한다.

거부 경로의 불변식은 다음과 같다.

- data zone에 write하지 않는다.
- metadata zone에 superblock을 쓰지 않는다.
- 어떤 zone도 reset하지 않는다.
- 사용자가 명시적으로 장치를 초기화하기 전까지 원본 상태를 보존한다.

사용자가 정말 새 장치로 초기화하려면 자동 복구가 아니라 명시적인 format/reset
절차를 실행해야 한다. “target을 열어 본다”는 동작 자체가 기존 media를 바꾸면 안
된다.

### 3.5 수정 완료 기준

- 완전히 빈 장치에서는 target 생성과 최초 superblock 기록이 성공한다.
- metadata가 비고 data zone 하나라도 dirty이면 target 생성을 거부한다.
- foreign metadata를 우리 superblock으로 받아들이지 않는다.
- 모든 거부 경로에서 data WP와 metadata WP가 그대로 유지된다.
- 단순 target open은 zone reset이나 자동 복구 write를 수행하지 않는다.

---

## 4. `metadata-torn-write`: header만 남은 SSTable을 정상으로 믿으면 안 된다

> **핵심:** header가 그럴듯해도 payload가 완전하다는 증거가 없으면 SSTable을 채택하면 안 된다.

### 4.1 SSTable의 구조

현재 SSTable은 header 4 KiB 하나와 payload 4 KiB 여러 개로 구성된다.

```text
[ header ][ payload 0 ][ payload 1 ] ...
```

header에는 다음 정보가 들어 있다.

- magic과 version
- entry 개수
- 전체 block 개수
- 최소/최대 logical key
- SSTable 순번
- payload CRC

CRC는 payload 전체로 계산한 짧은 검사값이다. 복구할 때 실제 payload로 다시 CRC를
계산하여 header의 값과 다르면 데이터가 누락되거나 변조됐음을 알 수 있다.

ZNS zone은 앞 위치로 돌아가 header를 고칠 수 없으므로, 구현은 payload를 RAM에서
먼저 한 번 훑어 CRC를 계산한 다음 header부터 순서대로 쓴다.

### 4.2 테스트가 만드는 고장

테스트는 MemTable threshold를 2로 낮춰 mapping 두 개만으로 SSTable flush가
일어나게 한다. 그리고 첫 SSTable의 payload 위치에 badblock을 설치한다.

```text
1. header H1 write 성공
2. payload P1 write 실패

metadata zone:
[ super ][ H1 ][ 빈/실패 위치 ... ]
```

현재 구현은 H1이 기록된 뒤 payload write가 실패하면 metadata append를 즉시
차단한다. 다음 write와 정상 종료도 H1 뒤에 새 record를 붙이지 않는다.

```text
[ super ][ H1 ][ 빈/실패 위치 ... ]
             ↑ 이후 append 금지
```

CRC 검증도 별도로 증명하기 위해 테스트는 target을 내린 뒤, 손상된 payload 위치에
임의 block 하나를 하위 장치로 직접 append한다. 그러면 H1의 길이 범위는 겉보기에
완성되지만 내용은 header가 계산한 payload와 다르다.

```text
[ super ][ H1 ][ corrupt payload ]
```

테스트는 runtime append 차단과 재생성 시 CRC 기반 거부를 모두 확인하며, 거부
과정에서 metadata WP가 더 움직이지 않는지도 검사한다.

### 4.3 왜 반드시 만족해야 하는가

H1의 `nr_blocks`만 보면 뒤에 충분한 block이 존재한다. 하지만 H1 바로 뒤의 H2는
H1의 payload가 아니라 다음 SSTable의 header다.

이를 mapping entry 배열로 해석하면 header의 magic, version, CRC 같은 숫자가
logical block과 physical sector처럼 보일 수 있다. 결과적으로 읽기가 전혀 관계없는
sector를 향하거나, 뒤의 정상 SSTable까지 잘못된 경계로 건너뛸 수 있다.

```text
구조가 맞는가?        겉보기에는 block 수가 충분함
내용이 맞는가?        아님. H2를 P1로 오인
안전한가?             아님. 잘못된 mapping 채택 가능
```

metadata는 data의 주소록이므로, 의심스러운 주소록을 일부라도 채택하는 것보다
장치 열기를 거부하는 편이 안전하다.

### 4.4 `[수정 전·확정]` 구현이 실패한 이유

write 시에는 payload CRC를 계산해 header에 저장한다. 그러나 `zns_sst_load()`는
header decode를 호출할 때 CRC 출력 인자로 `NULL`을 넘긴다. 저장된 CRC를 받지
않으며 payload를 읽어 재계산하지도 않는다.

수정 전 load가 확인하는 것은 사실상 다음뿐이었다.

1. header의 magic/version과 기본 필드가 decode되는가?
2. header가 주장하는 `nr_blocks`가 현재 metadata WP 안에 들어가는가?

뒤에 H2와 P2가 붙어 WP가 전진한 상태에서는 두 번째 길이 검사도 통과한다. 그래서
손상 H1이 정상 SSTable로 채택된다.

또한 recovery loop는 `zns_sst_load()`의 `-EINVAL`을 “여기서 log가 끝났다”로
간주하고 성공으로 종료한다. 실제 corruption과 정상적인 tail 종료를 같은 오류로
표현하면 손상을 조용히 무시할 수 있다.

관련 코드:

- [`zns_sst_write()`](../src/lsm-sstable.c)
- [`zns_sst_load()`](../src/lsm-sstable.c)
- [`zns_lsm_recover_sstables()`](../src/engines/zns-engine-lsm.c)

### 4.5 `[반영]` 수정 방향

현재 format을 유지하는 최소 수정은 recovery 시 payload 전체를 검증하는 것이다.

```text
header 읽기
→ 저장된 payload CRC 확보
→ nr_blocks만큼 payload block 전부 읽기
→ 실제 CRC 재계산
→ header CRC와 비교
→ 일치할 때만 SSTable publish
```

함께 검증하면 좋은 항목은 다음과 같다.

- `nr_entries`와 `nr_blocks` 관계가 맞는가?
- entry가 logical block 오름차순인가?
- logical block과 physical sector가 장치 범위 안인가?
- entry가 채우지 않은 나머지 padding 영역이 정해진 값과 크기를 따르는가?
- SSTable sequence가 허용되는 순서인가?

오류 종류도 구분해야 한다.

| 상황 | 권장 결과 |
|---|---|
| 명시적으로 정의한 빈 tail 또는 end marker | 정상적인 scan 종료 |
| decodable header인데 payload CRC 불일치 | `-EUCLEAN`, target 생성 거부 |
| log 중간의 잘못된 magic/version/구조 | corruption, target 생성 거부 |
| 하위 read 자체가 실패 | I/O error, target 생성 거부 |

`zns_lsm_recover_sstables()`는 corruption을 단순 `break`로 삼으면 안 된다. 명시적인
정상 tail만 종료로 취급하고, 나머지는 생성자까지 오류를 전달해야 한다.

더 강한 새 format을 설계한다면 payload 뒤에 footer 또는 commit marker를 append할
수 있다.

```text
[ header ][ payload ... ][ commit footer ]
```

footer까지 정상 기록된 table만 복구하는 방식이다. 다만 이는 on-disk format version
변경과 기존 media migration 정책이 필요하므로, 현재 테스트를 먼저 통과시키는 데는
payload CRC 검증이 더 작은 수정이다.

### 4.6 수정 완료 기준

- recovery가 header에 저장된 CRC와 실제 payload CRC를 비교한다.
- CRC가 다르면 해당 SSTable을 publish하지 않는다.
- corruption과 정상적인 log 종료를 서로 다른 결과로 구분한다.
- corruption은 생성자까지 전달되어 target 생성 전체를 fail-closed로 거부한다.
- 거부 과정에서 metadata zone에 어떤 block도 추가로 쓰지 않는다.
- 정상 SSTable 여러 개의 clean restart recovery는 계속 통과한다.

---

## 5. `concurrency-lifecycle`: 예약 순서만 지켜서는 ZNS 동시 쓰기가 안전하지 않다

> **핵심:** 같은 zone은 WP 순서대로 처리하되, 서로 다른 zone은 동시에 처리해야 한다.

### 5.1 테스트가 확인하는 것

첫 번째 case는 4개의 `fio` job을 실행한다. 각 job은 서로 겹치지 않는 8 MiB logical
범위에 4 KiB random write를 보내며, job마다 최대 16개 I/O를 동시에 outstanding
상태로 둔다.

```text
job 0: logical range  0 MiB ...  8 MiB
job 1: logical range  8 MiB ... 16 MiB
job 2: logical range 16 MiB ... 24 MiB
job 3: logical range 24 MiB ... 32 MiB
```

logical 범위가 겹치지 않으므로 같은 LBA overwrite 경쟁을 일부러 만들지는 않는다.
대신 다음을 검사한다.

- 여러 writer의 데이터가 CRC 검증을 통과하는가?
- 동시에 `dmsetup status`를 읽어도 상태 조회가 실패하거나 멈추지 않는가?
- I/O가 끝난 뒤 immutable/flushing MemTable이 정상적으로 drain되는가?
- active MemTable이 threshold 이상으로 방치되지 않는가?

두 번째 case는 한 block을 쓰고 target을 제거·재생성하는 작업을 10회 반복한다.
매 cycle마다 이전 cycle의 모든 데이터를 다시 읽는다.

```text
cycle 0: block A 쓰기 → recreate → A 확인
cycle 1: block B 쓰기 → recreate → A, B 확인
...
cycle 9: block J 쓰기 → recreate → A ... J 확인
```

마지막 case는 이 시간 동안 새로운 kernel I/O error나 zoned write rejection이
생기지 않았는지 확인한다.

### 5.2 왜 반드시 만족해야 하는가

실제 파일시스템과 애플리케이션은 write 하나가 끝날 때까지 기다렸다가 다음 write를
보내지 않는다. queue depth를 높이고 여러 CPU에서 동시에 I/O를 보낸다. M1 공식
workload도 `iodepth=32`를 사용한다.

따라서 단일 `dd` write가 성공하는 것만으로는 random-write 변환기가 안전하다고 할
수 없다. 최소한 다음이 성립해야 한다.

- 서로 다른 요청에 같은 physical sector를 배정하지 않는다.
- 한 zone에 명시적 sector write를 보낼 때 실제 제출 순서가 WP 순서와 맞는다.
- 하위 write가 성공한 뒤에만 mapping을 공개한다.
- MemTable freeze와 lookup이 서로 해제된 table을 참조하지 않는다.
- target 종료 시 모든 성공 write를 metadata에 반영하고 나서 자료구조를 해제한다.

### 5.3 `[수정 전]` 구조에서 확인된 위험

현재 allocator는 spinlock 아래에서 sector를 배정하므로 같은 sector를 두 번 반환하는
문제는 막는다.

```text
요청 A → sector 0 예약
요청 B → sector 8 예약
요청 C → sector 16 예약
```

하지만 lock은 **예약 순서**만 보호한다. `zns_engine_map()`이 각 bio를
`DM_MAPIO_REMAPPED`로 반환한 뒤 실제 하위 block layer가 어느 순서로 제출하고
완료할지는 보장하지 않는다.

```text
예약 순서: A(0) → B(8) → C(16)
실제 도착: A(0) → C(16) → B(8) 가능
```

WP가 8인데 sector 16 write가 먼저 도착하면 host-managed zone은 이를 거부할 수
있다. allocator의 spinlock만으로는 이 문제를 해결할 수 없다.

여기에 `write-failure`와 같은 조기 mapping 공개 문제가 결합된다. 거부된 write도
MemTable에는 성공한 것처럼 남고, allocator의 예상 WP와 실제 WP가 달라진다. 첫
parallel case가 media/mapping 상태를 깨뜨리면 뒤의 repeated recovery와 I/O error
case도 연쇄적으로 실패할 수 있다.

`[추가 확인]` 최초 제공된 summary에는 `fio.log`의 첫 실제 오류가 포함되어 있지
않다. 따라서 concurrency suite의 모든 실패가 이 한 원인이라고 단정할 수는 없다.
다만 다음 두 구조적 결함은 코드에서 확인된다.

- 명시적 sequential write의 zone별 제출 순서를 보장하지 않는다.
- 하위 write 완료 전에 mapping과 allocator 예상 WP를 확정한다.

MemTable 세대 교체 자체는 `table_lock`과 table 내부 spinlock을 사용한다. 따라서
상세 로그 없이 MemTable race라고 단정하지 않고, 위 두 문제를 먼저 고친 뒤 남는
실패를 다시 분석해야 한다.

### 5.4 `[후속 최적화]` zone별 순서, zone 사이 병렬성

전체 write를 하나의 queue로 직렬화하면 정확하지만 느리다. 권장 방식은 여러 data
zone을 동시에 active로 두고, 같은 zone 안에서만 ordered queue를 사용하는 것이다.

```text
상위 concurrent writes
        │
        ├─ data zone 0 ordered queue: A → B → C
        ├─ data zone 1 ordered queue: D → E
        ├─ data zone 2 ordered queue: F → G
        └─ data zone 3 ordered queue: H
```

zone 0의 B는 A가 끝난 뒤 제출하지만, zone 0의 A와 zone 1의 D는 동시에 실행할 수
있다. 단, 장치가 동시에 유지할 수 있는 active/open zone 수에는 한계가 있다.
구현은 장치가 알리는 `zone_max_active`와 `zone_max_open` 값을 넘지 않아야 한다.

필요한 주요 구조는 다음과 같다.

```text
zns_lsm
├─ global write ticket counter
├─ logical-block latest committed ticket index
├─ logical-block hash locks
└─ data zone writers[]
   ├─ zone id / start / capacity
   ├─ reserved WP와 committed WP
   └─ ordered workqueue
```

write context에는 적어도 원본 bio, logical block, ticket, 선택한 zone, 예약 sector가
필요하다. worker는 하위 write 성공 뒤 logical-block lock을 잡고 ticket을 확인한 후
현재 active MemTable에 mapping을 넣는다.

### 5.5 같은 LBA write의 완료 순서 뒤집힘

테스트의 첫 workload는 logical 범위가 겹치지 않지만, 실제 시스템은 같은 logical
block을 연달아 덮어쓸 수 있다.

```text
A(ticket 10) 제출
B(ticket 11) 제출
B 먼저 완료
A 나중 완료
```

완료 순서대로 무조건 mapping을 갱신하면 마지막에 A가 B를 덮어써 logical 시간이
거꾸로 간다. 따라서 다음 조건부 publish가 필요하다.

```text
if ticket > latest_committed_ticket[logical_block]:
    active MemTable에 mapping 삽입
    latest_committed_ticket 갱신
else:
    물리 write는 성공했지만 더 오래된 버전이므로 mapping에는 반영하지 않음
```

오래된 성공 write의 physical block은 invalid data가 되며 미래 GC가 회수한다.

### 5.6 종료와 recreate 순서

background SSTable flush는 pending data write를 기다리지 않아도 된다. 완료된
mapping만 snapshot으로 가져가면 된다. 하지만 target 제거에서는 다음 순서를
지켜야 한다.

```text
DM이 새 요청 차단
→ 모든 per-zone data queue drain
→ 성공 write의 MemTable commit 완료
→ SSTable flush queue drain
→ active/immutable/flushing을 오래된 세대부터 종료 flush
→ allocator와 table 해제
```

data queue보다 SSTable queue를 먼저 없애면, 늦게 성공한 data write가 새 immutable을
만든 뒤 이를 flush할 worker가 없는 상태가 될 수 있다.

### 5.7 Zone Append는 후속 최적화

장치가 `REQ_OP_ZONE_APPEND`를 지원하면 같은 zone에 여러 append를 동시에 요청하고
장치가 실제 기록 위치를 반환하게 할 수 있다. 그러면 host가 같은 zone의 sector
순서를 직접 맞추는 부담이 줄어든다.

다만 zone append 최대 크기, 실패 시 capacity reservation, completion에서 반환된
sector 처리, 실제 장치 지원 여부를 검증해야 한다. 첫 구현은 per-zone ordered queue로
정확성을 확보하고, 이후 zone append를 성능 최적화로 도입하는 편이 단계적이다.

### 5.8 수정 완료 기준

- 같은 physical sector를 두 write에 중복 배정하지 않는다.
- 명시적 sector write는 같은 zone 안에서 WP 순서대로 하위 장치에 도착한다.
- 서로 다른 active zone의 write는 병렬로 진행할 수 있다.
- 하위 write 성공 전에는 mapping을 공개하지 않는다.
- 네 `fio` job의 CRC 검증과 동시 status 조회가 모두 완료된다.
- I/O 종료 뒤 immutable/flushing이 drain되고 active가 threshold 아래에 남는다.
- 반복 recreate 뒤 이전 cycle의 모든 데이터가 읽힌다.
- 실행 구간에 새로운 zoned rejection이나 kernel I/O error가 없다.

---

## 6. 네 문제의 관계

네 테스트는 서로 독립적으로 보이지만 하나의 원칙으로 연결된다.

> 성공이 확인되지 않은 상태를 영구적이고 신뢰할 수 있는 상태로 공개하지 않는다.

| 문제 | 너무 일찍 신뢰하는 것 | 필요한 commit 조건 |
|---|---|---|
| write failure | 아직 성공하지 않은 data write의 mapping | 하위 data write 성공 |
| format safety | mapping이 없는 dirty media를 새 빈 장치로 판단 | 모든 data zone도 비어 있음 |
| torn SSTable | header만 온전한 metadata record | payload CRC와 구조 검증 성공 |
| concurrency | sector 예약 순서를 실제 write 순서로 간주 | zone 순서와 completion 확인 |

수정 순서도 이 의존성을 따른다.

1. data write completion 뒤 mapping을 publish하는 비동기 commit 경로를 만든다.
2. per-zone ordered queue와 logical-block ticket으로 동시성을 안전하게 만든다.
3. dirty data + empty metadata를 read-only 검사 후 거부한다.
4. recovery에서 SSTable payload CRC와 구조를 검증한다.
5. clean detach 시 data queue → metadata queue → resident table 순으로 drain한다.

---

## 7. 구현 후 확인할 테스트

각 수정은 좁은 테스트부터 확인한다.

```bash
sudo VERBOSE=1 ./test.sh write-failure
sudo VERBOSE=1 ./test.sh metadata-format-safety
sudo VERBOSE=1 ./test.sh metadata-torn-write
sudo VERBOSE=1 ./test.sh concurrency-lifecycle
```

그 다음 M1 required profile 전체를 실행한다.

```bash
sudo ./test.sh
```

concurrency 실패를 다시 조사할 때는 summary만 보지 말고 suite가 출력한 `fio`의
첫 I/O error, 해당 시간의 kernel log, 실패 직전 `dmsetup status`, 실제 zone WP를
함께 비교해야 한다. 첫 오류가 이후 실패의 원인일 수 있으므로 가장 먼저 발생한
오류부터 고친다.

M2 ext4, partial/sub-block I/O, fsync crash durability, M3 GC는 이 네 가지 M1
안전성 문제를 해결한 뒤 진행한다. 전체 우선순위는
[마일스톤 결함 우선순위](15-milestone-gap-priorities.md)를 참고한다.
