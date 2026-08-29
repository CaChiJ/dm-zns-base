#!/usr/bin/env bash
# Block I/O helpers and assertions used inside test cases.
#
# Every assertion reports its reason on stderr and returns non-zero, which
# ends the enclosing case because run_case runs cases with errexit on.

[ -n "${ZNS_ASSERT_SOURCED:-}" ] && return 0
ZNS_ASSERT_SOURCED=1

ZNS_BLOCK_BYTES=4096

write_block() {
	local input=$1
	local logical_block=$2

	dd if="$input" of="$DM_DEV" bs="$ZNS_BLOCK_BYTES" seek="$logical_block" \
		count=1 conv=notrunc oflag=direct status=none ||
		fail "failed to write logical block $logical_block"
}

read_block() {
	local logical_block=$1
	local output=$2

	dd if="$DM_DEV" of="$output" bs="$ZNS_BLOCK_BYTES" \
		skip="$logical_block" count=1 iflag=direct status=none ||
		fail "failed to read logical block $logical_block"
}

# Read one logical block and compare it against an expected image.
assert_block() {
	local expected=$1
	local logical_block=$2
	local actual="$tmp_dir/assert-block-$logical_block.bin"

	read_block "$logical_block" "$actual"
	cmp -s "$expected" "$actual" ||
		fail "logical block $logical_block does not match $(basename "$expected")"
}

# Read one logical block and require that it differs from an image.
assert_block_differs() {
	local unexpected=$1
	local logical_block=$2
	local actual="$tmp_dir/assert-block-$logical_block.bin"

	read_block "$logical_block" "$actual"
	cmp -s "$unexpected" "$actual" &&
		fail "logical block $logical_block returned stale $(basename "$unexpected")"
	return 0
}

assert_files_equal() {
	cmp -s "$1" "$2" ||
		fail "${3:-contents differ: $1 vs $2}"
}

assert_eq() {
	[ "$1" = "$2" ] ||
		fail "${3:-value mismatch}: got '$1', expected '$2'"
}

assert_gt() {
	[ "$(($1))" -gt "$(($2))" ] ||
		fail "${3:-value is not greater}: got '$1', expected > '$2'"
}

assert_ge() {
	[ "$(($1))" -ge "$(($2))" ] ||
		fail "${3:-value is too small}: got '$1', expected >= '$2'"
}

assert_lt() {
	[ "$(($1))" -lt "$(($2))" ] ||
		fail "${3:-value is not smaller}: got '$1', expected < '$2'"
}

# A 4 KiB block filled with one repeated character.
make_pattern_file() {
	local path=$1
	local character=$2

	head -c "$ZNS_BLOCK_BYTES" /dev/zero | tr '\0' "$character" >"$path"
}

make_random_file() {
	local path=$1
	local blocks=${2:-1}

	dd if=/dev/urandom of="$path" bs="$ZNS_BLOCK_BYTES" count="$blocks" \
		status=none
}

make_zero_file() {
	local path=$1
	local blocks=${2:-1}

	dd if=/dev/zero of="$path" bs="$ZNS_BLOCK_BYTES" count="$blocks" \
		status=none
}

# Run fio against the target under test. The shared flags live here; the
# workload axes stay at the call site because that is what each case is about.
run_fio() {
	local log=$1
	local job_name=$2
	shift 2

	if fio --name="$job_name" --filename="$DM_DEV" --ioengine=libaio \
		--direct=1 "$@" >"$log" 2>&1; then
		return 0
	fi

	tail -n 20 "$log" >&2
	fail "fio job $job_name failed"
}
