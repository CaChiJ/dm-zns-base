# 00. 과제 개요

목표는 ext4 같은 zone-unaware 파일시스템이 sequential-only ZNS SSD 위에서 동작하도록, 임의 쓰기를 순차 쓰기로 변환하는 LSM-Tree 기반 Device Mapper 타깃을 만드는 것이다.

## 배경

ZNS SSD는 sequential write만 허용하는 zone들의 묶음으로 디스크를 노출한다. 각 zone에는 write pointer(wp)가 있고, wp 위치에서만 쓰기가 가능하며 임의 위치 덮어쓰기는 거절된다. 대신 zone reset으로 통째로 비운다. 장점은 SSD 내부 GC가 사라져 tail latency가 안정되고 WAF가 감소하며 수명이 늘어난다는 점. 단점은 기존 파일시스템들이 임의 쓰기를 전제로 설계됐다는 것.

해결은 두 갈래다. 파일시스템을 zone-aware로 만들거나(F2FS, btrfs zoned mode 등 이미 존재), 블록 계층에서 임의 쓰기를 순차 쓰기로 변환해 파일시스템을 무수정으로 활용하거나. 본 과제는 후자.

## Prior art

| 이름 | 출신 | ZNS 단독 동작 | 한계 |
|---|---|---|---|
| **dm-zoned** | SMR HDD 용 (Linux 4.13+, mainline) | ✗ | conventional zone 의존. ZNS SSD에 적용하려면 conventional namespace나 별도 일반 SSD 동반 필요. |
| **dm-zap** | Western Digital, ZNS 친화 | △ | 연구물, 메인라인 아님, 유지보수 X. |
| **본 과제 산출물** | 졸업프로젝트 | ✓ (목표) | 별도 conventional 디바이스 없이 sequential-only zone만으로 매핑·GC. LSM-Tree 기반. |

## 차별점

- conventional namespace나 별도 일반 SSD를 쓰지 않는다. 메타데이터는 일부 존을 메타데이터 전용 존으로 사용하는 방향으로 구현.
- LBA → physical zone/offset 매핑 자료구조로 LSM-Tree 채택. 컴팩션 정책이 GC와 자연스럽게 결합.
- MVP는 in-memory 매핑 + crash-loss 허용. 영속화·저널링은 동작 골격 이후.

## 학습 경로 (M0 → M4)

상세는 [07-milestones.md](07-milestones.md).

```
M0 (제공)  zoned-aware passthrough     →  blkzone report 정상
M1         random write 변환 (핵심)    →  fio 4K randwrite 100MB raw 통과
M2         ext4 라운드트립             →  mkfs + mount + dd + md5 일치
M3         GC + zone reset 사이클      →  용량 80% + 1.2× overwrite 지속
M4         성능 평가                   →  M3 통과 후 별도 공지
```

## 실험 환경

로컬(본 repo, zoned `null_blk`)은 코드 정확성 검증용. 지연이 ~0이고 NVMe 명령 경로가 없어 성능 비교에는 쓸 수 없다. 서버 단계는 FEMU 기반 가상 ZNS SSD에서 실제 NVMe 명령 경로와 플래시 수준 타이밍으로 fio 벤치마크·베이스라인 비교를 수행한다.

## 참고: `.iterate_devices` 함정

`.features = DM_TARGET_ZONED_HM`는 zoned 디바이스를 받을 수 있다는 허용 플래그일 뿐, underlying의 zone size·zoned 속성이 DM queue로 stack되려면 `.iterate_devices` 콜백이 따로 필요하다. 빠지면 `dm-X/queue/zoned=none`, `chunk_sectors=0`이 되고 `blkzone`이 *"unable to determine zone size"* 로 실패한다. 본 scaffold(`src/dm-zns-base.c`)에는 포함돼 있고, M1 이후 새 코드를 짤 때 queue limits stacking 경로를 따로 점검하는 습관이 같은 함정을 피하게 해준다.
