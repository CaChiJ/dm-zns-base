#!/usr/bin/env bash
# Opt-in M2 gate: an ext4 filesystem must survive a real unmount/remount, not
# merely return data from the page cache.

set -euo pipefail

TARGET_NAME=${TARGET_NAME:-zns-ext4-roundtrip}
ZNS_REQUIRED_ENGINE=lsm
EXT4_SIZE_MB=${EXT4_SIZE_MB:-512}
EXT4_ZONE_MB=${EXT4_ZONE_MB:-32}
EXT4_TIMEOUT=${EXT4_TIMEOUT:-60}

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../support/lib/init.sh
source "$TESTS_DIR/support/lib/init.sh"

report_init "system/ext4-roundtrip"

require_root
require_commands make modprobe mountpoint dmsetup blkzone blockdev \
	mkfs.ext4 mount umount findmnt e2fsck dd sha256sum find sort xargs \
	readlink stat sync timeout awk

tmp_dir=$(mktemp -d)
mount_dir="$tmp_dir/mnt"
mkdir "$mount_dir"

teardown_ext4() {
	if mountpoint -q "$mount_dir"; then
		timeout "$EXT4_TIMEOUT" umount "$mount_dir" 2>/dev/null || true
	fi
	if mountpoint -q "$mount_dir"; then
		printf 'refusing to remove %s while %s is still mounted\n' \
			"$DM_DEV" "$mount_dir" >&2
		return 0
	fi
	teardown_target
}
trap teardown_ext4 EXIT

create_nullblk_fixture "$EXT4_SIZE_MB" "$EXT4_ZONE_MB"
build_engine
load_module
reset_zones
create_dm_target
io_errors_save "$tmp_dir/io-errors"

mount_ext4() {
	timeout "$EXT4_TIMEOUT" mount -t ext4 -o nodiscard \
		"$DM_DEV" "$mount_dir" ||
		fail "failed to mount ext4 on $DM_DEV"
	findmnt -rn -M "$mount_dir" >/dev/null ||
		fail "$mount_dir is not an active mount"
}

unmount_ext4() {
	timeout "$EXT4_TIMEOUT" umount "$mount_dir" ||
		fail "failed to unmount $mount_dir"
	! mountpoint -q "$mount_dir" || fail "$mount_dir is still mounted"
}

case_data_roundtrip() {
	local before after

	if ! timeout "$EXT4_TIMEOUT" mkfs.ext4 -F -b 4096 \
		-E nodiscard,lazy_itable_init=0,lazy_journal_init=0 \
		"$DM_DEV" >"$tmp_dir/mkfs.log" 2>&1; then
		tail -n 30 "$tmp_dir/mkfs.log" >&2
		fail "mkfs.ext4 failed"
	fi

	mount_ext4
	timeout "$EXT4_TIMEOUT" dd if=/dev/urandom \
		of="$mount_dir/data.bin" bs=1M count=10 \
		conv=fsync status=none || fail "failed to create the 10 MiB test file"
	before=$(sha256sum "$mount_dir/data.bin" | awk '{ print $1 }')
	printf '%s\n' "$before" >"$tmp_dir/data.sha256"
	sync -d "$mount_dir/data.bin"
	sync -f "$mount_dir"
	unmount_ext4

	mount_ext4
	after=$(sha256sum "$mount_dir/data.bin" | awk '{ print $1 }')
	assert_eq "$after" "$before" "the file hash changed across remount"
	unmount_ext4
	touch "$tmp_dir/data-roundtrip.ready"
	detail "sha256=$after bytes=10485760"
}

case_metadata_roundtrip() {
	local i inode_original inode_link

	[ -f "$tmp_dir/data-roundtrip.ready" ] ||
		fail "the data roundtrip prerequisite did not complete"
	mount_ext4
	mkdir -p "$mount_dir/tree/a" "$mount_dir/tree/b"
	for i in $(seq -w 0 63); do
		printf 'file-%s\n' "$i" >"$mount_dir/tree/a/file-$i"
	done
	mv "$mount_dir/tree/a/file-05" "$mount_dir/tree/b/renamed"
	ln "$mount_dir/tree/a/file-06" "$mount_dir/tree/b/hardlink"
	ln -s ../a/file-07 "$mount_dir/tree/b/symlink"
	printf 'appended\n' >>"$mount_dir/tree/a/file-08"
	truncate -s 3 "$mount_dir/tree/a/file-09"
	rm "$mount_dir/tree/a/file-10"

	(
		cd "$mount_dir"
		find tree -type f -print0 | sort -z | xargs -0 sha256sum
	) >"$tmp_dir/metadata.sha256"
	readlink "$mount_dir/tree/b/symlink" >"$tmp_dir/symlink.target"
	sync -f "$mount_dir"
	unmount_ext4

	mount_ext4
	(
		cd "$mount_dir"
		find tree -type f -print0 | sort -z | xargs -0 sha256sum
	) >"$tmp_dir/metadata.actual"
	assert_files_equal "$tmp_dir/metadata.sha256" "$tmp_dir/metadata.actual" \
		"the small-file manifest changed across remount"
	assert_eq "$(readlink "$mount_dir/tree/b/symlink")" \
		"$(cat "$tmp_dir/symlink.target")" \
		"the symbolic-link target changed across remount"
	inode_original=$(stat -c '%i' "$mount_dir/tree/a/file-06")
	inode_link=$(stat -c '%i' "$mount_dir/tree/b/hardlink")
	assert_eq "$inode_link" "$inode_original" \
		"the hard link no longer shares its inode"
	[ ! -e "$mount_dir/tree/a/file-10" ] ||
		fail "a deleted file reappeared after remount"
	unmount_ext4
	touch "$tmp_dir/metadata-roundtrip.ready"
	detail "files=64 rename=1 hardlink=1 symlink=1"
}

case_filesystem_clean() {
	[ -f "$tmp_dir/metadata-roundtrip.ready" ] ||
		fail "the metadata roundtrip prerequisite did not complete"
	if ! timeout "$EXT4_TIMEOUT" e2fsck -fn "$DM_DEV" \
		>"$tmp_dir/e2fsck.log" 2>&1; then
		tail -n 30 "$tmp_dir/e2fsck.log" >&2
		fail "e2fsck found an error after the clean unmount"
	fi
}

run_case "when ext4 writes 10 MiB, the hash survives unmount and remount" \
	case_data_roundtrip
run_case "when ext4 changes directory metadata, every change survives remount" \
	case_metadata_roundtrip
run_case "when ext4 is cleanly unmounted, a read-only fsck reports no errors" \
	case_filesystem_clean
run_case "when the ext4 roundtrip finishes, no new kernel I/O errors appear" \
	assert_no_new_io_errors "$tmp_dir/io-errors"

report_summary
