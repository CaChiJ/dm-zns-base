# dm-zns-base

졸업프로젝트 *"엣지 컴퓨팅을 위한 동적 플랫폼(Apache Kafka)과 ZNS(Zoned Namespace) SSD 호환을 위한 리눅스 커널 블록 계층 개발"* 의 학생용 base repo.

목표는 sequential-only ZNS SSD 위에서 ext4 같은 zone-unaware 파일시스템이 동작하도록 임의 쓰기를 순차 쓰기로 변환하는 LSM-Tree 기반 Device Mapper 타깃을 만드는 것이다. 현재 repo에는 zone-aware allocator, MemTable/SSTable 매핑, 정상 종료 후 metadata 복구와 안전성 테스트가 포함되어 있다. GC와 power-loss 안전성을 위한 WAL은 아직 구현 범위 밖이다.

## Quickstart

| 호스트 | 게스트 | 자세히 |
|---|---|---|
| 네이티브 Linux | 불필요 | [docs/01](docs/01-setup-linux.md) |
| Windows | `vagrant up` (자동) | [docs/04](docs/04-setup-windows.md) |
| Mac (Apple Silicon / Intel) | UTM + Ubuntu | [docs/02](docs/02-setup-mac.md) |

Linux 게스트가 준비되면 동일:

```bash
sudo bash scripts/nullblk-up.sh   # /dev/nullb0 (zoned, 2GB, 64MB × 32 zones)
sudo ./test.sh                    # required 프로필 (빌드 포함)
./test.sh --list                  # 프로필·계층별 테스트 목록
```

## 문서

| 문서 | 내용 |
|---|---|
| [00-overview](docs/00-overview.md) | 과제 배경, dm-zoned / dm-zap 비교, 본 과제의 차별점 |
| [01-setup-linux](docs/01-setup-linux.md) | 네이티브 Linux |
| [02-setup-mac](docs/02-setup-mac.md) | Mac (UTM) |
| [04-setup-windows](docs/04-setup-windows.md) | Windows (Vagrant + VirtualBox) |
| [05-nullblk-zoned](docs/05-nullblk-zoned.md) | zoned `null_blk` 사용법과 한계 |
| [06-build-and-run](docs/06-build-and-run.md) | 빌드 / 적재 / 테스트 / 진단 |
| [07-milestones](docs/07-milestones.md) | M0 → M4 마일스톤과 성공 기준 |
| [08-references](docs/08-references.md) | 공식 문서, prior art, 참고 자료 |
| [09-code-guide](docs/09-code-guide.md) | 코드 읽는 순서와 규약 |
| [10-components](docs/10-components.md) | 구성 요소별 책임 |
| [11-engines](docs/11-engines.md) | 엔진(append4k / append4k-alloc / lsm) 비교 |
| [12-tests](docs/12-tests.md) | 테스트 계층, 실행 프로필, 검증 범위 |
| [13-io-size-test-matrix](docs/13-io-size-test-matrix.md) | request/payload 크기 매트릭스 |
| [14-future-test-contracts](docs/14-future-test-contracts.md) | GC·durability 미래 계약 |
| [15-milestone-gap-priorities](docs/15-milestone-gap-priorities.md) | 테스트 실패를 마일스톤별 우선순위로 해석 |
| [16-m1-safety-failures-explained](docs/16-m1-safety-failures-explained.md) | 저장장치 기초부터 M1 안전성 실패와 수정 설계까지 설명 |

## 구조

```
dm-zns-base/
├── src/         커널 모듈 소스 + Makefile
├── tests/       테스트 계층 (unit / integration / system) + support
├── test.sh      테스트 엔트리포인트 → tests/run.sh
├── scripts/     nullblk 셋업, 수동 실험용 빌드 스크립트
├── docs/        셋업·마일스톤·참고자료
├── Vagrantfile  Windows용 자동 VM
└── provision.sh
```

GPL-2.0. 각 소스 파일의 SPDX 헤더 참고.
