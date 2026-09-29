#!/usr/bin/env bash
# Two independent runs from reset media: unsampled performance, then sampled
# space efficiency. Both use the same fill and overwrite fio settings.
# shellcheck source=tests/lib/init.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${1:?usage: sudo bash scripts/gc-benchmark.sh OUTPUT_DIR [simple|none]}
POLICY=${2:-simple}
case $POLICY in simple|none) ;; *) echo "policy must be simple or none" >&2; exit 2 ;; esac

TARGET_NAME="zns-gc-bench-$$"
# These settings are consumed by the sourced test helpers.
# shellcheck disable=SC2034
ZNS_REQUIRED_ENGINE=lsm
# shellcheck disable=SC2034
ZNS_ENGINE=lsm
# shellcheck disable=SC2034
ZNS_GC_POLICY=$POLICY
source "$ROOT/tests/lib/init.sh"
require_root
require_commands fio jq python3 dmsetup blkzone blockdev
require_host_managed
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
trap teardown_target EXIT

capacity_sectors=$(usable_sectors)
capacity_bytes=$((capacity_sectors * 512))
interval=${SAMPLE_INTERVAL:-0.5}
fio_block_bytes=65536
if [ "$capacity_bytes" -ge $((1024 * 1024 * 1024)) ]; then
	fio_block_bytes=1048576
fi
fio_block_bytes=${FIO_BLOCK_BYTES:-$fio_block_bytes}
range_bytes=$(( (capacity_bytes * 4 / 5 / fio_block_bytes) * fio_block_bytes ))
overwrite_bytes=$(( (capacity_bytes * 6 / 5 / fio_block_bytes) * fio_block_bytes ))

fio_run() {
	local output=$1 rw=$2
	shift 2
	fio --name=gc-benchmark --filename="$DM_DEV" --ioengine=libaio \
		--direct=1 --iodepth=16 --bs="$fio_block_bytes" --rw="$rw" \
		--size="$range_bytes" --norandommap=1 --randrepeat=1 \
		--randseed=314159 --output-format=json \
		--percentile_list=50:95:99:99.9 --output="$output" "$@"
}

run_mode() {
	local mode=$1 dir="$OUT_DIR/$1" result=0 sampler='' stat initial
	mkdir -p "$dir"
	reset_zones
	create_dm_target
	[ "$(status_field gc_policy)" = "$POLICY" ] || die "wrong GC policy"
	stat=$(basename "$(readlink -f "$DM_DEV")")
	initial=$(awk '{print $7}' "/sys/block/$stat/stat")
	fio_run "$dir/fill.json" write
	python3 "$ROOT/scripts/gc-sample.py" --underlying "$UNDERLYING" \
		--target "$TARGET_NAME" --stat "/sys/block/$stat/stat" \
		--initial-sectors "$initial" --once --output "$dir/start.csv"
	if [ "$mode" = space ]; then
		python3 "$ROOT/scripts/gc-sample.py" --underlying "$UNDERLYING" \
			--target "$TARGET_NAME" --stat "/sys/block/$stat/stat" \
			--initial-sectors "$initial" \
			--output "$dir/samples.csv" --interval "$interval" &
		sampler=$!
	fi
	fio_run "$dir/overwrite.json" randwrite --io_size="$overwrite_bytes" || result=$?
	if [ -n "$sampler" ]; then
		kill "$sampler" 2>/dev/null || true
		wait "$sampler" || true
	fi
	python3 "$ROOT/scripts/gc-sample.py" --underlying "$UNDERLYING" \
		--target "$TARGET_NAME" --stat "/sys/block/$stat/stat" \
		--initial-sectors "$initial" --once --output "$dir/end.csv"
	# Summary is produced after fio has stopped; these queries do not enter
	# the unsampled performance run.
	dmsetup status "$TARGET_NAME" >"$dir/final-status.txt"
	blkzone report "$UNDERLYING" >"$dir/final-zones.txt"
	jq -n --arg policy "$POLICY" --arg mode "$mode" \
		--argjson capacity "$capacity_bytes" \
		--argjson range "$range_bytes" \
		--argjson requested "$overwrite_bytes" \
		--argjson exit "$result" \
		--slurpfile fio "$dir/overwrite.json" \
		'{policy:$policy,mode:$mode,capacity_bytes:$capacity,
		  range_bytes:$range,requested_write_bytes:$requested,
		  fio_exit:$exit,actual_write_bytes:$fio[0].jobs[0].write.io_bytes,
		  bw_mib_per_sec:($fio[0].jobs[0].write.bw_bytes / 1048576),
		  iops:$fio[0].jobs[0].write.iops,
		  clat_ns_percentile:$fio[0].jobs[0].write.clat_ns.percentile}' \
		>"$dir/summary.json"
	detach_dm_target
}

build_engine lsm
load_module
run_mode performance
run_mode space
printf 'results: %s\n' "$OUT_DIR"
