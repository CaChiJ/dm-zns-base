# 02. 셋업 — Mac (UTM)

Apple Silicon / Intel 공통. macOS는 커널 모듈 개발 환경이 아니므로 Linux VM 안에서 작업한다. UTM 기반으로 통일(Apple Silicon에서 VirtualBox가 developer preview라 사용하지 않을 예정).

## 환경

| 항목 | 값 |
|---|---|
| 가상화 도구 | UTM ([mac.getutm.app](https://mac.getutm.app/), 무료) |
| 백엔드 | Virtualize (Emulate 아님). Apple Silicon은 Apple Virtualization Framework, Intel은 Hypervisor.framework — 둘 다 네이티브 가상화 |
| 배포판 | Ubuntu Server 22.04 LTS |

### ISO

| Mac | ISO |
|---|---|
| Apple Silicon (M1–M4) | Ubuntu Server 22.04 LTS **arm64** ([download](https://ubuntu.com/download/server/arm)) |
| Intel | Ubuntu Server 22.04 LTS **amd64** ([download](https://ubuntu.com/download/server)) |

코드는 아키텍처 독립적이라 어느 쪽이든 동작한다. 서버(FEMU)는 x86_64.

## VM 생성

UTM → Create a New Virtual Machine → Virtualize → Linux → ISO 지정.

| 항목 | 권장 |
|---|---|
| RAM | 4096 MB (커널 빌드용. 2 GB는 빠듯) |
| CPU | 4 코어 (Mac 코어 수의 절반 정도) |
| 디스크 | 40 GB |
| Display | 기본 (콘솔만 쓰면 SSH 권장) |
| Network | 기본 (Shared Network) |

마법사 중 "Use Apple Virtualization" 체크박스를 켠다. Rosetta는 안 씀.

## Ubuntu 설치

표준 절차. OpenSSH server 설치 체크박스 켜기. 끝나면 ISO 분리 후 재부팅.

## SSH 진입

UTM으로 VM을 띄워두고 별도 터미널에서 ssh로 접속해 쓰는 방식을 권장한다.


VM 콘솔에서 IP 확인:
```bash
ip a    # 보통 192.168.64.x 또는 192.168.205.x
```

Mac 터미널:
```bash
ssh <username>@<vm-ip>
```


## 게스트 패키지

```bash
sudo apt update
sudo apt install -y \
  build-essential git \
  linux-headers-$(uname -r) linux-modules-extra-$(uname -r) \
  dmsetup util-linux nvme-cli fio
```

`linux-modules-extra-$(uname -r)`가 빠지면 `modprobe null_blk`가 실패한다.

## 검증

```bash
git clone https://github.com/wnsah814/dm-zns-base.git
cd dm-zns-base
sudo bash scripts/nullblk-up.sh
cd src && make && cd ..
sudo bash scripts/test-basic.sh    # ALL CHECKS PASSED
```

## 트러블슈팅

- **`linux-headers-...` 없음**: `sudo apt update` 후 다시. 그래도 없으면 커널 업데이트와 헤더가 어긋난 상태 → `sudo apt full-upgrade && sudo reboot`.
- **`make`의 "modpost: missing MODULE_LICENSE"**: `MODULE_LICENSE("GPL")` 또는 SPDX 헤더 확인. scaffold엔 있음.
- **`insmod`: Invalid module format**: 헤더와 실행 커널 mismatch. `uname -r`와 `modinfo ...ko | grep vermagic` 비교.
- **VM이 느림**: Virtualize(네이티브) 모드인지 확인. Apple Silicon에서 Emulate(x86_64) ISO를 쓰면 매우 느리다 — arm64 ISO로 재생성.
