# 15. 마일스톤 결함 우선순위

이 문서는 전체 테스트 결과를 마일스톤 기준으로 해석한다. 실패 개수만으로
우선순위를 정하지 않는다. 같은 미지원 I/O 형태가 matrix에서 여러 case로
반복 보고될 수 있고, M2·M3·durability처럼 의도적으로 뒤 마일스톤에 둔 계약도
있기 때문이다.

저장장치 기초 개념부터 각 테스트의 동작, 수정 전 실패 원인, 반영된 설계를 자세히
보려면 [M1 안전성 실패를 처음부터 이해하기](16-m1-safety-failures-explained.md)를
먼저 읽는다.

## 현재 결론

M1 random-write 변환의 데이터 무결성은 다음 세 `required` suite로 고정되어 있다.
현재 소스에는 각 불변식을 지키는 fail-closed 처리가 반영되었으며, release 전에는
세 suite와 required profile 전체를 실제 장치에서 다시 통과시켜야 한다.

| 우선순위 | 검증 suite | M1에서 지켜야 할 불변식 |
|---|---|---|
| 1 | `integration/write-failure` | 하위 physical write가 실패하면 기존 mapping과 append 위치가 그대로여야 한다. |
| 2 | `integration/metadata-format-safety` | data zone이 사용됐는데 유효한 metadata가 없으면 target 생성을 거부하고 media를 바꾸지 않아야 한다. |
| 2 | `integration/metadata-torn-write` | metadata log 중간의 불완전 SSTable은 recovery가 채택하지 않고 target을 fail-closed로 거부해야 한다. |

## 왜 `write-failure`가 최우선이었는가

수정 전 LSM write 경로는 하위 I/O의 성공이 확정되기 전에 mapping을 공개했다.

```text
수정 전 위험한 순서

logical write
  → physical sector 예약
  → 새 mapping 공개
  → 하위 write 제출
  → write 실패 가능
```

마지막 단계가 실패하면 읽기가 쓰이지 않은 새 sector를 향할 수 있다. 이는
성능이나 확장 기능의 문제가 아니라 M1의 “임의 write를 정확히 읽어낼 수
있다”는 기본 계약을 깨는 데이터 손상 문제다.

현재 구현은 ordered I/O worker에서 아래 순서를 지킨다.

```text
logical write
  → physical sector 예약
  → 하위 write 성공 확인
  → 새 mapping 공개
```

실패하면 실제 zone WP를 다시 읽고, WP가 움직이지 않았을 때만 마지막 allocator
reservation을 되돌린다. 소비 여부를 신뢰할 수 없으면 예약 위치를 재사용하지 않는다.

관련 코드: [`zns_lsm_write()`](../src/engines/zns-engine-lsm.c)와
[`zns_engine_map()`](../src/engines/zns-engine-lsm.c).

## metadata 안전성은 persistence를 제공하는 순간 M1 필수다

M1의 mapping 원본은 메모리지만, 정상 detach와 재시작에는 MemTable을 SSTable로
저장하고 다시 복구한다. 따라서 metadata가 없거나 손상됐을 때 이를 빈 장치나
정상 table로 오인하면 기존 data zone의 mapping을 잃을 수 있다.

### 포맷 경계

`metadata-format-safety`는 다음 상태를 구분한다.

- 완전히 빈 장치: 새 format을 만들어 target 생성 가능
- data zone은 사용됨, metadata zone은 비어 있음: 거부
- metadata 첫 block이 이 프로젝트의 superblock이 아닌 foreign data: 거부

거부 과정은 metadata zone write pointer를 움직여서는 안 된다. 그렇지 않으면
원인 분석이나 이후의 안전한 복구 기회까지 파괴한다.

### Torn SSTable

`metadata-torn-write`는 SSTable header만 쓰고 payload write를 실패시킨 뒤 추가
metadata append가 차단되는지 확인한다. 이어 payload 위치에 임의 block을 직접
append해 길이만으로는 완성돼 보이는 손상 record를 만들고 복구가 거부하는지 본다.

현재 구현은 첫 번째 방법을 채택하고, 부분 record가 생긴 instance의 append도
차단한다. 나머지는 향후 format을 바꿀 때 선택할 수 있는 대안이다.

- recovery scan에서 SSTable payload CRC를 실제로 재계산하고 일치하지 않으면 거부
- 실패한 table의 예약 구간을 recovery가 명확히 건너뛸 수 있는 padding/commit record 기록
- append-only 쓰기에 적합한 footer 또는 commit marker 형식 도입

어느 방법이든 손상 metadata를 부분적으로 채택하는 대신 target 전체를
fail-closed로 거부해야 한다.

## 다음 순서: concurrent lifecycle

`integration/concurrency-lifecycle`은 `extended` 프로필이다. 네 writer의
동시 I/O, flush 상태 polling, 반복 target recreation 이후 CRC readback을
검사한다.

이는 M1의 기본 인수 workload보다 강한 안정성 검사다. 기본 random-write
경로가 통과하더라도 아래가 깨질 수 있음을 뜻한다.

- mapping 공개와 하위 write 완료의 순서
- active / immutable / flushing MemTable 세대 전환
- target detach 시 workqueue 종료와 flush 순서
- 재생성 직전/직후 metadata 순서

따라서 write failure와 metadata 안전성을 먼저 해결한 뒤, `VERBOSE=1` 로그로
이 suite의 첫 실패 원인을 좁힌다.

```bash
sudo VERBOSE=1 ./test.sh concurrency-lifecycle
```

## 지금 우선순위가 아닌 실패

아래 실패는 중요하지만, 현재 문서에서 더 뒤 마일스톤 또는 명시적인 확장
계약으로 분류한다. matrix가 같은 원인을 여러 case로 보여 주므로 실패 수가
많아도 위의 M1 결함보다 먼저 처리하지 않는다.

| 실패군 | 이유 | 마일스톤 / 프로필 |
|---|---|---|
| `request-size-matrix` | LSM은 sector 정렬 partial I/O를 4 KiB RMW로 처리한다. 더 넓은 크기·offset 조합은 extended 회귀 검사다. | extended |
| `operation-contract`의 zeroout | discard/write-zeroes 의미론은 기본 READ/WRITE mapping 밖의 계약이다. | extended |
| `zone-capacity` | partial-capacity zone의 경계 처리 강화 검사다. | extended |
| `ext4-roundtrip` | filesystem format, mount, remount 보존은 M2다. | M2 / extended |
| `fsync-quiesced-recovery` | 실제 mapping durability 경계를 검사하는 test-build 전용 계약이다. | future |
| `gc-cycle` | relocation, zone reset, free-zone 관리가 필요한 M3다. | M3 / future |

## 다음 작업 순서

1. `write-failure`, `metadata-format-safety`, `metadata-torn-write`를 실제 null_blk에서 재검증한다.
2. 기본 `required` 프로필 전체를 green으로 만든다.
3. `concurrency-lifecycle`을 통과시키고 단일 ordered queue의 성능 한계를 측정한다.
4. M2 `ext4-roundtrip`을 green으로 만든다.
5. 마지막으로 M3 GC와 crash-durable mapping을 구현한다.

## 점검 명령

먼저 M1의 안전성 결함만 재현한다.

```bash
sudo VERBOSE=1 ./test.sh write-failure
sudo VERBOSE=1 ./test.sh metadata-format-safety
sudo VERBOSE=1 ./test.sh metadata-torn-write
```

세 case가 통과한 뒤 기본 release gate를 실행한다.

```bash
sudo ./test.sh
```

`extended`, `future`, `all`은 아직 미지원 계약을 포함할 수 있으므로, M1 완료
판정에는 기본 `required` 프로필의 결과를 사용한다. profile 분류는
[`tests/suites.tsv`](../tests/suites.tsv)와 [마일스톤 문서](07-milestones.md)를
함께 따른다.
