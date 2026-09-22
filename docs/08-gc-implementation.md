# M3 GC 구현과 실행

설계 기준은 [gc-design-draft.md](gc-design-draft.md)이다. LSM 엔진은 마지막 존을
SSTable 메타데이터용으로, 빈 데이터 존 하나를 GC 예비 존으로 사용한다. DM 상위
용량은 메타데이터 존을 제외한 데이터 존의 capacity 합계에서 가장 큰 데이터
존 하나의 capacity를 뺀 값이다. 생성할 때 이 용량을 넘는
DM table은 거부한다. 기존 디스크를 다시 열 때는 SSTable을 최신 순으로 읽어
논리 블록당 최신 물리 위치와 존별 유효 블록 수를 재구성한다.

## 정책 선택

```bash
make -C src ZNS_ENGINE=lsm ZNS_GC_POLICY=simple
make -C src ZNS_ENGINE=lsm ZNS_GC_POLICY=none
```

정책을 바꿔 빌드하면 `src/Makefile`이 이전 빌드 산출물을 정리한다. `simple`은
일반 할당 공간이 없어졌을 때 낮은 번호부터 가득 찬 데이터 존을 찾고, 무효
블록이 있으며 유효 블록 전체가 예비 존에 들어가는 첫 존을 정리한다. `none`은
같은 예비 존과 매핑 계측을 유지하되 GC를 실행하지 않는다. `dmsetup status`에
`gc_policy`, `reserve_zone`, `valid_blocks`, `gc_runs`, `gc_moved`,
`zone_resets`, `meta_used`가 표시된다. `valid_blocks`는 최신 매핑이 가리키는
4 KiB 데이터 블록 수다.

기본 MemTable 임계치는 논리 블록 수보다 하나 크게 잡되 최대 1,048,576개로
제한한다. 반복 GC 이동이 메타데이터 존의 SSTable 로그를 너무 빨리 채우지
않도록 최신 매핑을 정상 target 제거 때까지 메모리에 유지하기 위한 설정이다.
`memtable_threshold`를 기본값 외의 값으로 지정하면 그 값을 그대로 사용한다. 큰 장치나
작은 임계치에서는 메타데이터 존이 소진될 수 있으므로 별도의 SSTable
compaction과 메타데이터 공간 재사용이 필요하다.

GC 복사, 매핑 갱신 또는 reset이 실패하면 해당 target의 쓰기를 중단한다.
복사에 성공한 매핑은 유지하고 victim을 reset하지 않는다. 재시작할 때 빈
예비 존을 찾지 못하면 target 생성을 거부한다. 갑작스러운 전원 차단 복구는
보장하지 않는다.

## M3 기능 검증

기본 32존 `null_blk` 장치를 준비한 뒤 다음을 실행한다.

```bash
sudo bash tests/run.sh m3
```

테스트는 사용 가능 용량 `C`의 80% 범위를 채우고, 같은 범위에 `1.2C`만큼
`fio` random overwrite한다. `--size=0.8C`, `--io_size=1.2C`,
`--norandommap=1`을 사용하고 CRC readback을 확인한다. 기본 32존 장치의
요청 크기는 1 MiB이고, 1 GiB 미만의 개발용 장치는 64 KiB다. `simple`에서 유효 블록
이동과 data zone reset, 정상 재시작 후 readback을 확인하고, 새 장치 상태에서
`none`으로 같은 workload를 다시 실행해 `ENOSPC`를 확인한다. 개발 중 빠른
재현에는 별도 3존 `null_blk`를 `UNDERLYING=/dev/nullb1`로 지정할 수 있다.

## 벤치마크

```bash
sudo bash scripts/gc-benchmark.sh /tmp/gc-simple simple
sudo bash scripts/gc-benchmark.sh /tmp/gc-none none
```

각 명령은 80% fill 뒤 동일한 random overwrite를 두 번 수행한다. 매번 하위
존을 reset해 같은 초기 상태를 만든다. `performance/` 실행 중에는 조회하지
않고 `fio` JSON에서 bandwidth, IOPS, completion latency percentile과 성공한
쓰기량을 기록한다. `space/` 실행 중에는 0.5초 간격으로 `blkzone report`,
`dmsetup status`, 상위 장치의 누적 쓰기 섹터 수를 조회해 `samples.csv`로
남긴다. 시작 전과 종료 후에도 I/O 없는 상태의 스냅샷을 기록한다. 샘플의
`valid_ratio`는 `valid_blocks / data_written_blocks`이며 메타데이터 존은
제외한다. 두 조회는 원자적이지 않아 중간값은 근사치다. 공간 실행의 `fio`
성능 수치는 성능 실행과 직접 비교하지 않는다. `none`에서 공간 부족이 나면
실제 성공한 쓰기량과 오류를 JSON에 남긴다.

`null_blk` 결과는 기능·회귀 검증용이다. 처리량과 지연 시간에 관한 평가는
FEMU 또는 실제 ZNS 장치에서 반복해야 한다.
