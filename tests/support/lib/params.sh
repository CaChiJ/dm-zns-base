#!/usr/bin/env bash
# Small, reusable parameter helpers for matrix-style shell suites.

[ -n "${ZNS_PARAMS_SOURCED:-}" ] && return 0
ZNS_PARAMS_SOURCED=1

# Read a comma- or whitespace-separated environment variable into a bash array.
# Usage: parameter_list VARIABLE "default values" output_array
parameter_list() {
	local variable_name=$1 default_values=$2 output_name=$3
	local raw=${!variable_name:-$default_values}
	local -n output=$output_name

	raw=${raw//,/ }
	raw=${raw//$'\n'/ }
	read -r -a output <<<"$raw"
	[ "${#output[@]}" -gt 0 ] ||
		die "$variable_name resolved to an empty parameter list"
}

# Convert an integer byte count with an optional IEC suffix into bytes. fio's
# familiar k/K, m/M and g/G spellings are accepted, with optional iB/B.
size_to_bytes() {
	local input=$1 digits number suffix factor

	if [[ $input =~ ^([0-9]+)([bBkKmMgG]([iI]?[bB])?)?$ ]]; then
		digits=${BASH_REMATCH[1]}
		[ "${#digits}" -le 18 ] || return 1
		number=$((10#$digits))
		suffix=${BASH_REMATCH[2]:-}
	else
		return 1
	fi

	case ${suffix:0:1} in
	""|b|B) factor=1 ;;
	k|K) factor=1024 ;;
	m|M) factor=$((1024 * 1024)) ;;
	g|G) factor=$((1024 * 1024 * 1024)) ;;
	*) return 1 ;;
	esac

	[ "$number" -le $(( (9223372036854775807 / factor) )) ] || return 1
	printf '%u\n' "$((number * factor))"
}

require_size_bytes() {
	local input=$1 label=${2:-size} bytes

	bytes=$(size_to_bytes "$input") || die "invalid $label: $input"
	[ "$bytes" -gt 0 ] || die "$label must be positive: $input"
	printf '%u\n' "$bytes"
}

require_nonnegative_bytes() {
	local input=$1 label=${2:-offset} bytes

	bytes=$(size_to_bytes "$input") || die "invalid $label: $input"
	printf '%u\n' "$bytes"
}
