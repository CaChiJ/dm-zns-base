#!/usr/bin/env bash
# Build the dm-zns-base kernel module.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_DIR=$(cd "$SCRIPT_DIR/../src" && pwd)
ZNS_ENGINE=${ZNS_ENGINE:-${1:-append4k}}
ZNS_GC_POLICY=${ZNS_GC_POLICY:-simple}
ZNS_DEVICE=${ZNS_DEVICE:-/dev/nullb0}

lsm_usable_sectors() {
	local nr_zones=$1
	local line capacity index=0 total=0 largest=0

	[ "$nr_zones" -ge 3 ] || return 1
	while IFS= read -r line; do
		if [[ $line =~ cap[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
			capacity=${BASH_REMATCH[1]}
			if [ "$index" -lt "$((nr_zones - 1))" ]; then
				# The engine exposes only complete 4 KiB blocks.
				capacity=$((capacity / 8 * 8))
				total=$((total + capacity))
				[ "$capacity" -le "$largest" ] || largest=$capacity
			fi
			index=$((index + 1))
		fi
	done
	[ "$index" -eq "$nr_zones" ] || return 1
	printf '%s\n' "$((total - largest))"
}

echo "[*] build engine: $ZNS_ENGINE"

# dm-zns-base 모듈 빌드
make -C "$SRC_DIR" clean ZNS_ENGINE="$ZNS_ENGINE" ZNS_GC_POLICY="$ZNS_GC_POLICY"
make -C "$SRC_DIR" ZNS_ENGINE="$ZNS_ENGINE" ZNS_GC_POLICY="$ZNS_GC_POLICY"

# 기존에 로드된 모듈이 있으면 내리기
sudo dmsetup remove myzns-base 2>/dev/null || true
sudo rmmod dm-zns-base 2>/dev/null || true
sudo blkzone reset "$ZNS_DEVICE"

# 커널 모듈 적재
sudo insmod "$SRC_DIR/dm-zns-base.ko"

# 가상 디바이스 생성
if [ "$ZNS_ENGINE" = lsm ]; then
	DEVICE_NAME=$(basename "$(readlink -f "$ZNS_DEVICE")")
	NR_ZONES=$(cat "/sys/block/$DEVICE_NAME/queue/nr_zones")
	SECTORS=$(sudo blkzone report "$ZNS_DEVICE" | lsm_usable_sectors "$NR_ZONES")
else
	SECTORS=$(sudo blockdev --getsz "$ZNS_DEVICE")
fi
echo "0 $SECTORS zns-base $ZNS_DEVICE" | sudo dmsetup create myzns-base
