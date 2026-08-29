# 졸업프로젝트 월간 보고서 (8월) — 초안

> *이동혁(2021086917)*

> *최현준(2021037401)*

## 요약

7월에는 상위 장치의 random logical write를 ZNS 장치의 sequential physical write로 변환하고, 그 변환 관계를 MemTable에서 관리하는 LSM 엔진을 구현하였다.

8월에는 메모리에만 존재하던 logical-to-physical mapping을 ZNS 장치에 영속화하는 작업을 진행하였다. MemTable의 mapping을 SSTable로 변환하여 별도의 metadata zone에 순차 기록하고, Device Mapper target을 정상적으로 제거한 뒤 다시 생성하거나 커널 모듈을 재적재한 이후에도 기존 mapping을 복구할 수 있도록 구조를 확장하였다.

이를 통해 기존의 인메모리 중심 LSM 엔진을 정상 종료와 재시작을 지원하는 지속 가능한 mapping 관리 구조로 발전시켰다.

## 목적

기존 LSM 엔진은 실제 사용자 데이터를 ZNS 장치에 기록했지만, 해당 데이터가 어느 physical sector에 저장되었는지를 나타내는 mapping은 MemTable에만 보관하였다.

이 구조에서는 Device Mapper target이 제거되면 MemTable도 함께 사라진다. 물리 데이터가 장치에 남아 있더라도 logical block과 연결할 수 없으므로, 재시작 이후에는 기존 데이터를 정상적으로 읽을 수 없었다. 또한 영속화된 mapping을 메모리에서 회수하는 경로가 없어, 서로 다른 logical block의 mapping 수가 늘어날수록 메모리 사용량도 함께 증가하였다.

따라서 8월에는 다음 목표를 중심으로 개발을 진행하였다.

- MemTable의 mapping을 ZNS 장치에 영속적으로 저장
- 영속화가 끝난 MemTable의 메모리 회수
- 메모리와 디스크에 분산된 mapping의 통합 조회
- 정상 종료 시 남아 있는 mapping 보존
- target 재생성 및 모듈 재적재 이후 mapping 복구
- 현재 장치 구성이 기존 metadata와 호환되는지 검증

## 전체 설계

ZNS 장치에서는 이미 기록한 위치를 일반 블록 장치처럼 덮어쓸 수 없다. 따라서 하나의 mapping table을 제자리에서 갱신하는 대신, 변경된 mapping을 새로운 SSTable로 만들어 순차적으로 추가하는 방식을 사용하였다.

하위 ZNS 장치의 마지막 zone 하나를 metadata 전용으로 예약하고, 나머지 zone은 실제 데이터 저장에 사용하도록 영역을 분리하였다. 상위 Device Mapper 장치가 노출하는 논리 주소 범위는 유지되지만, 실제 데이터를 append할 수 있는 하위 공간은 metadata zone 하나만큼 감소한다.

```text
ZNS device
├── data zone 0
├── data zone 1
├── ...
└── metadata zone
    ├── superblock
    ├── SSTable 0
    ├── SSTable 1
    └── ...
```

메모리에서 생성된 mapping은 다음 단계를 거쳐 디스크에 저장된다.

```text
active MemTable
→ immutable MemTable
→ flushing MemTable
→ on-disk SSTable
```

이 구조를 통해 최근 mapping은 메모리에서 빠르게 처리하면서, 일정량 이상 쌓인 mapping은 ZNS의 순차 쓰기 제약을 지키며 디스크로 내릴 수 있도록 하였다.

## SSTable 기반 Mapping 영속화

MemTable에 저장된 mapping을 logical block 순서로 정렬된 SSTable 형태로 변환하였다. MemTable이 사용하는 RB-tree가 이미 key 순서를 유지하므로, 별도의 정렬 과정 없이 tree를 순회하여 SSTable을 생성할 수 있다.

SSTable은 하나의 header와 여러 mapping block으로 구성된다.

```text
[SSTable header][mapping block 0][mapping block 1] ...
```

Header에는 SSTable의 크기와 entry 수, logical block 범위, 생성 순서 및 향후 payload 무결성 검증에 사용할 CRC를 기록한다. Mapping block에는 logical block과 physical sector의 대응 관계를 저장한다.

새로운 SSTable은 metadata zone의 현재 write pointer에 append한다. 기존 SSTable을 수정하지 않으므로 ZNS의 sequential write 제약을 위반하지 않는다.

## MemTable Flush와 수명 관리

Active MemTable이 설정된 threshold에 도달하면 더 이상 변경되지 않는 immutable 상태로 전환한다. 이후 순서가 보장되는 background workqueue가 immutable MemTable을 flushing 상태로 옮기고 SSTable로 기록한다.

Flushing 상태를 별도로 둔 이유는 디스크 기록이 진행되는 동안 해당 MemTable이 변경되거나 해제되는 것을 막기 위해서이다. Flush 중에도 읽기 요청이 기존 mapping을 찾을 수 있도록 flushing MemTable을 조회 대상에 포함하였다.

Flush가 성공하면 새 SSTable을 조회 목록에 먼저 등록한 뒤 기존 MemTable을 해제한다. 따라서 mapping이 메모리와 디스크 양쪽에서 동시에 보이지 않는 구간이 발생하지 않는다.

Flush가 중간에 실패하면 해당 MemTable은 flushing 상태에 남겨 읽기 경로에서 계속 사용할 수 있게 한다. 실제 장치의 write pointer가 이미 전진한 구간은 다음 flush에서 재사용하지 않는다.

이 과정을 통해 mapping을 장치에 보존하면서, 이미 영속화된 MemTable이 계속 메모리를 차지하지 않도록 하였다.

## 통합 Mapping 조회

영속화 이후에는 최신 mapping이 메모리 또는 디스크 중 어느 곳에든 존재할 수 있다. 이에 따라 read path가 다음 순서로 mapping을 조회하도록 확장하였다.

```text
active MemTable
→ immutable MemTable
→ flushing MemTable
→ SSTable 최신순
→ mapping이 없으면 zero-fill
```

항상 최신 세대부터 조회하기 때문에 동일한 logical block의 mapping이 여러 계층에 존재하더라도 가장 최근 write의 physical 위치를 선택한다.

MemTable에서 mapping을 찾으면 기존과 같이 바로 데이터를 읽는다. MemTable에 없으면 metadata zone에 저장된 SSTable을 확인하여 physical sector를 찾는다.

## Superblock과 장치 형식 검증

Metadata zone의 첫 block에는 해당 metadata가 어떤 장치 구성을 기준으로 생성되었는지를 나타내는 superblock을 저장하였다.

Superblock에는 logical device 크기, zone 크기와 개수, metadata zone 위치, mapping block 크기 등 재시작 시 필요한 고정 정보를 기록한다.

Target을 다시 생성할 때는 superblock의 값과 현재 장치 구성을 비교한다. 서로 호환되지 않으면 기존 mapping을 잘못 해석하지 않도록 target 생성을 거부한다.

## 정상 종료와 재시작 복구

Target이 제거될 때 threshold에 도달하지 않은 active MemTable이 남아 있을 수 있다. 이를 그대로 해제하면 마지막 flush 이후의 mapping이 유실되므로, 정상 종료 과정에서 메모리에 남아 있는 모든 MemTable을 오래된 세대부터 SSTable로 저장하도록 하였다.

Target을 다시 생성할 때는 다음 순서로 mapping을 복구한다.

```text
하위 장치의 zone 정보 조회
→ metadata zone의 superblock 검증
→ metadata zone에 기록된 SSTable 순차 탐색
→ SSTable 위치와 logical block 범위 복원
→ 최신 SSTable 우선 조회 구조 재구성
```

복구 시에는 각 SSTable의 header를 읽어 메모리상의 인덱스를 다시 구성하고, 실제 mapping payload는 이후 read path에서 필요할 때 조회한다. 이 과정을 통해 정상적으로 target을 제거한 뒤 다시 생성한 경우와 커널 모듈을 재적재한 경우에도 기존 logical-to-physical mapping을 다시 사용할 수 있도록 하였다.

## 기능 검증

8월 구현은 mapping이 실제로 디스크에 저장되는지와 재시작 후에도 동일하게 조회되는지를 중심으로 검증하였다.

주요 검증 항목은 다음과 같다.

- MemTable threshold 도달 후 SSTable 생성
- SSTable 생성 이후 MemTable 메모리 회수
- SSTable에만 남아 있는 mapping 조회
- Flush 전후 동일한 데이터 반환
- 여러 세대에 같은 logical block이 있을 때 최신 mapping 선택
- Target 제거 및 재생성 이후 기존 데이터 유지
- 커널 모듈 재적재 이후 mapping 복구
- 재시작 전후 overwrite 시 최신 데이터 유지
- Superblock과 현재 장치 구성이 다를 경우 target 생성 거부
- SSTable flush 이후 예약된 metadata zone의 write pointer 증가 확인

세부 실행 결과와 테스트 환경은 최종 보고서에서 표와 실행 결과를 추가하여 정리할 예정이다.

## 결과 및 의의

이번 달 작업을 통해 MemTable에만 존재하던 mapping을 SSTable 형태로 ZNS 장치에 영속화할 수 있게 되었다. 영속화가 끝난 MemTable은 메모리에서 해제할 수 있으며, 필요한 mapping은 on-disk SSTable에서 다시 조회할 수 있다.

또한 정상적인 target 종료 과정에서 남은 mapping을 저장하고, 재시작 시 metadata zone을 탐색하여 이전 상태를 복구하는 흐름을 구현하였다. 그 결과 LSM 엔진은 실행 중에만 유효했던 인메모리 구조에서 벗어나, 정상 종료와 재시작을 지원하는 mapping 관리 구조를 갖추게 되었다.

7월에 random logical write를 ZNS의 sequential physical write로 변환하는 기반을 마련했다면, 8월에는 그 변환 관계를 지속적으로 보존하는 계층을 추가했다는 점에 의미가 있다.

## 현재 한계

8월에 병합된 구현이 보장하는 범위는 정상적인 target 제거 이후의 재시작 복구이다. 전원 차단이나 커널 패닉처럼 정상 종료 과정이 수행되지 않는 상황에서는 아직 MemTable에만 존재하는 mapping이 유실될 수 있다.

또한 다음 기능은 아직 구현 범위에 포함되지 않는다.

- WAL 기반 crash consistency
- `fsync`와 mapping 영속성의 연계
- SSTable compaction
- Data 및 metadata zone garbage collection
- 손상된 metadata zone의 자동 repair 또는 교체
- zone 간 병렬 I/O 최적화

## 향후 계획

후속 개발에서는 비정상 종료 상황에서도 mapping을 복구할 수 있도록 metadata 기록 순서와 완료 여부를 명확히 하는 구조를 설계할 예정이다.

이후 ext4 연동과 fsync 이후 mapping durability를 검증하고, 장기적으로는 SSTable compaction과 zone garbage collection을 통해 공간을 재사용할 수 있는 구조로 확장할 계획이다.
