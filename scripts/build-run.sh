#!/usr/bin/env bash
# Build the dm-zns-base kernel module.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_DIR=$(cd "$SCRIPT_DIR/../src" && pwd)
ZNS_ENGINE=${ZNS_ENGINE:-${1:-append4k}}
UNDERLYING=${UNDERLYING:-/dev/nullb0}
TARGET_NAME=${TARGET_NAME:-myzns-base}
BLOCK_SECTORS=8

lsm_data_sectors() {
	local kernel_name nr_zones zone_sectors zone_id capacity total=0

	kernel_name=$(basename "$(readlink -f "$UNDERLYING")")
	nr_zones=$(cat "/sys/block/$kernel_name/queue/nr_zones")
	zone_sectors=$(cat "/sys/block/$kernel_name/queue/chunk_sectors")
	[ "$nr_zones" -ge 2 ]

	for ((zone_id = 0; zone_id + 1 < nr_zones; zone_id++)); do
		capacity=$(sudo blkzone report \
			-o "$((zone_id * zone_sectors))" -c 1 "$UNDERLYING" |
			awk 'NR == 1 {
				for (i = 1; i <= NF; i++) {
					key = $i
					value = $(i + 1)
					gsub(/[,:]/, "", key)
					gsub(/,/, "", value)
					if (key == "cap") {
						print value
						exit
					}
				}
			}')
		[ -n "$capacity" ]
		capacity=$(printf '%u' "$capacity")
		capacity=$((capacity - capacity % BLOCK_SECTORS))
		total=$((total + capacity))
	done

	[ "$total" -gt 0 ]
	printf '%u\n' "$total"
}

echo "[*] build engine: $ZNS_ENGINE"

# dm-zns-base 모듈 빌드
make -C "$SRC_DIR" clean ZNS_ENGINE="$ZNS_ENGINE"
make -C "$SRC_DIR" ZNS_ENGINE="$ZNS_ENGINE"

# Resolve the target length before changing the live module or media state.
if [ "$ZNS_ENGINE" = lsm ]; then
	SECTORS=$(lsm_data_sectors)
else
	SECTORS=$(sudo blockdev --getsz "$UNDERLYING")
fi

# 기존에 로드된 모듈이 있으면 내리기
sudo dmsetup remove "$TARGET_NAME" 2>/dev/null || true
sudo rmmod dm-zns-base 2>/dev/null || true
sudo blkzone reset "$UNDERLYING"

# 커널 모듈 적재
sudo insmod "$SRC_DIR/dm-zns-base.ko"

# LSM reserves the last zone and rounds every data-zone tail down to 4 KiB.
echo "0 $SECTORS zns-base $UNDERLYING" |
	sudo dmsetup create "$TARGET_NAME"

echo "[*] created /dev/mapper/$TARGET_NAME ($SECTORS sectors)"
