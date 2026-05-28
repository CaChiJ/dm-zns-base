# 01. 셋업 — 네이티브 Linux

Ubuntu 22.04 LTS 또는 24.04 LTS 권장 (커널 5.15+ / 6.x). Fedora 39+ 도 무방하지만 본 문서 명령은 Debian/Ubuntu 기준.

## 패키지

```bash
sudo apt update
sudo apt install -y \
  build-essential \
  git \
  linux-headers-$(uname -r) \
  linux-modules-extra-$(uname -r) \
  dmsetup \
  util-linux \
  nvme-cli \
  fio
```

- `linux-headers-$(uname -r)`: 모듈 빌드. 커널 업데이트 후엔 새 헤더 패키지를 다시 설치한다.
- `linux-modules-extra-$(uname -r)`: `null_blk.ko`가 여기 있다. 누락 시 `modprobe null_blk` 실패.
- `util-linux`: `blkzone`, `blockdev`.
- `nvme-cli` / `fio`: M3 이후 단계에서 사용.

## configfs

`null_blk` 동적 생성에는 `/sys/kernel/config`가 마운트돼 있어야 한다(대부분 자동). 안 돼 있으면 `scripts/nullblk-up.sh`가 알아서 마운트한다.

```bash
mountpoint /sys/kernel/config
```

## 검증

```bash
git clone https://github.com/wnsah814/dm-zns-base.git
cd dm-zns-base

sudo bash scripts/nullblk-up.sh
cd src && make && cd ..
sudo bash scripts/test-basic.sh    # ALL CHECKS PASSED
```

문제가 생기면 [06-build-and-run.md](06-build-and-run.md)의 진단 섹션 참고.

## NOPASSWD sudo (선택)

`scripts/` 명령들만 비밀번호 없이 쓰고 싶다면:

```bash
sudo visudo -f /etc/sudoers.d/dm-zns-base
```
```
<your-username> ALL=(root) NOPASSWD: /usr/sbin/insmod, /usr/sbin/rmmod, /usr/sbin/dmsetup, /usr/sbin/blkzone, /usr/bin/dmesg, /usr/sbin/modprobe
```

회수는 `sudo rm /etc/sudoers.d/dm-zns-base`.
