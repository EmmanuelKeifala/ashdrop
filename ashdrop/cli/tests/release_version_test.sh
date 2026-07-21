#!/bin/sh
set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
cli_dir=$(CDPATH= cd "$test_dir/.." && pwd)
validator=$cli_dir/scripts/release-version.sh
tmp_dir=${TMPDIR:-/tmp}/ashdrop-release-version-test.$$
mkdir "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

command -v awk >/dev/null 2>&1 || fail 'standard awk is required'

expect_success() {
    name=$1
    expected=$2
    shift 2

    if ! "$validator" "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
        fail "$name: expected success"
    fi
    actual=$(cat "$tmp_dir/stdout")
    [ "$actual" = "$expected" ] || fail "$name: expected stdout '$expected', got '$actual'"
    [ ! -s "$tmp_dir/stderr" ] || fail "$name: expected empty stderr"
}

expect_failure() {
    name=$1
    shift

    if "$validator" "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
        fail "$name: expected failure"
    fi
    [ ! -s "$tmp_dir/stdout" ] || fail "$name: expected empty stdout"
    [ -s "$tmp_dir/stderr" ] || fail "$name: expected a stderr diagnostic"
}

printf '.{\n    .version = "1.2.3",\n}\n' >"$tmp_dir/version.zon"
printf '.{\n    .version = "1.2.3",\n}\n' >"$tmp_dir/manifest=version.zon"
printf '.{\n    .name = .ashdrop,\n}\n' >"$tmp_dir/missing.zon"
printf '.{\n    .version = "1.2.3",\n    .version = "1.2.3",\n}\n' >"$tmp_dir/duplicate.zon"

expect_success 'actual package version' '0.1.0' 'cli-v0.1.0'
cd "$tmp_dir"
expect_success 'manifest path containing equals' '1.2.3' 'cli-v1.2.3' 'manifest=version.zon'
expect_failure 'malformed prefix' 'v0.1.0' "$tmp_dir/version.zon"
expect_failure 'version mismatch' 'cli-v1.2.4' "$tmp_dir/version.zon"
expect_failure 'leading zero' 'cli-v01.2.3' "$tmp_dir/version.zon"
expect_failure 'prerelease suffix' 'cli-v1.2.3-rc.1' "$tmp_dir/version.zon"
expect_failure 'missing declaration' 'cli-v1.2.3' "$tmp_dir/missing.zon"
expect_failure 'duplicate declaration' 'cli-v1.2.3' "$tmp_dir/duplicate.zon"
expect_failure 'missing arguments'
expect_failure 'extra arguments' 'cli-v1.2.3' "$tmp_dir/version.zon" 'extra'

busybox_path=$(command -v busybox 2>/dev/null || :)
if [ -n "$busybox_path" ]; then
    mkdir "$tmp_dir/busybox-bin"
    ln -s "$busybox_path" "$tmp_dir/busybox-bin/awk"
    if ! PATH="$tmp_dir/busybox-bin:$PATH" "$validator" 'cli-v1.2.3' "$tmp_dir/version.zon" \
        >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
        fail 'BusyBox awk: expected success'
    fi
    [ "$(cat "$tmp_dir/stdout")" = '1.2.3' ] || fail 'BusyBox awk: unexpected stdout'
    [ ! -s "$tmp_dir/stderr" ] || fail 'BusyBox awk: expected empty stderr'
    printf 'BusyBox awk test passed\n'
fi

printf 'release version tests passed\n'
