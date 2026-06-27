#!/usr/bin/env bash
# Build the dm-zns-base kernel module.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_DIR=$(cd "$SCRIPT_DIR/../src" && pwd)

# dm-zns-base.c 빌드
make -C "$SRC_DIR" clean
make -C "$SRC_DIR"

# 기존에 로드된 모듈이 있으면 내리기
sudo dmsetup remove myzns-base 2>/dev/null || true
sudo rmmod dm-zns-base 2>/dev/null || true
sudo blkzone reset /dev/nullb0

# 커널 모듈 적재
sudo insmod "$SRC_DIR/dm-zns-base.ko"

# 가상 디바이스 생성
SECTORS=$(sudo blockdev --getsz /dev/nullb0)
echo "0 $SECTORS zns-base /dev/nullb0" | sudo dmsetup create myzns-base