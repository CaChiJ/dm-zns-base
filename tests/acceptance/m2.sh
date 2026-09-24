#!/usr/bin/env bash
# ext4 roundtrip on one continuously live DM target (docs/07-milestones.md).
set -euo pipefail
TARGET_NAME=${TARGET_NAME:-zns-m2-acceptance}
ZNS_REQUIRED_ENGINE=lsm
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TESTS_DIR/lib/init.sh"

report_init "acceptance/m2"
require_root
require_commands make dmsetup blkzone blockdev mkfs.ext4 mount umount \
	mountpoint dd md5sum stat sync dmesg insmod rmmod readlink
require_host_managed

# Never remove the temporary directory (or target) while ext4 is mounted.
# Mounts survive run_case's subshell, so inspect the actual mount state.
cleanup_m2() {
	local status=$?
	if [ -n "${mount_dir:-}" ] && mountpoint -q "$mount_dir"; then
		if ! umount "$mount_dir"; then
			report_case FAIL "when cleaning up M2, ext4 unmount succeeds" \
				"retained mount=$mount_dir target=$TARGET_NAME tmp=$tmp_dir"
			exit 1
		fi
	fi
	teardown_target
	exit "$status"
}
trap cleanup_m2 EXIT
tmp_dir=$(mktemp -d)
mount_dir="$tmp_dir/mnt"
mkdir "$mount_dir"

build_engine
load_module memtable_threshold=1024
reset_zones
create_dm_target

checkpoint() {
	run_case "$@"
	[ "$ZNS_FAILED" -eq 0 ] || { report_summary; exit 1; }
}

case_conventional() {
	local dm_name
	dm_name=$(basename "$(readlink -f "$DM_DEV")")
	assert_eq "$(cat "/sys/block/$dm_name/queue/zoned")" none \
		"ext4 requires a conventional upper device"
}

case_roundtrip() {
	local before after
	# Keep the journal. Disable unsupported discard and finish initialization
	# during mkfs rather than adding deferred inode/journal initialization I/O.
	mkfs.ext4 -F -b 4096 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 \
		"$DM_DEV" >"$tmp_dir/mkfs.log" 2>&1 || {
		cat "$tmp_dir/mkfs.log" >&2
		fail "mkfs.ext4 failed"
	}
	log_step "mounting fresh ext4"
	mount -t ext4 -o nodiscard "$DM_DEV" "$mount_dir"
	dd if=/dev/urandom of="$mount_dir/data" bs=1M count=10 status=none
	assert_eq "$(stat -c %s "$mount_dir/data")" 10485760 \
		"the file is not exactly 10 MiB"
	before=$(md5sum "$mount_dir/data")
	before=${before%% *}
	sync
	umount "$mount_dir"
	# No target recreation, module reload, or zone reset between mounts.
	log_step "remounting the same ext4 filesystem and comparing its hash"
	mount -t ext4 -o nodiscard "$DM_DEV" "$mount_dir"
	assert_eq "$(stat -c %s "$mount_dir/data")" 10485760 \
		"the remounted file is not exactly 10 MiB"
	after=$(md5sum "$mount_dir/data")
	after=${after%% *}
	assert_eq "$after" "$before" "file hash changed after unmount/remount"
	umount "$mount_dir"
	detail "size=10MiB md5=$after"
}

case_no_errors() {
	local before after
	dmesg >"$tmp_dir/dmesg-after"
	before=$(grep -Eic "$error_pattern" "$tmp_dir/dmesg-before" || true)
	after=$(grep -Eic "$error_pattern" "$tmp_dir/dmesg-after" || true)
	if [ "$before" -ne "$after" ]; then
		grep -Ei "$error_pattern" "$tmp_dir/dmesg-after" | tail -n 30 >&2
		fail "kernel I/O, ext4, or journal error count changed ($before -> $after)"
	fi
}

error_pattern="$ZNS_IO_ERROR_PATTERN|EXT4-fs.*(error|warning|unable|abort)|JBD2.*(error|abort)"
# Read explicitly: an inaccessible kernel log must not look like zero errors.
dmesg >"$tmp_dir/dmesg-before"
checkpoint "when the M2 target is created, the upper device is conventional" case_conventional
checkpoint "when ext4 writes 10 MiB and unmounts/remounts, the file hash matches" case_roundtrip
checkpoint "when M2 finishes, the unmounted target can be removed" detach_dm_target
# detach_dm_target ran in the case subshell; mirror its successful ownership
# change in the parent before EXIT cleanup.
ZNS_TARGET_CREATED=0
checkpoint "when the ext4 roundtrip finishes, no new kernel errors appear" case_no_errors
report_summary
