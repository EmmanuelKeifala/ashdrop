#!/bin/sh
set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$test_dir/../../.." && pwd)
workflow=$repo_root/.github/workflows/cli-release.yml

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

line_of() {
    line=$(grep -nF "$1" "$workflow" | cut -d: -f1)
    [ -n "$line" ] || fail "workflow is missing: $1"
    [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "workflow repeats: $1"
    printf '%s\n' "$line"
}

[ ! -e "$repo_root/ashdrop/web/static/cli-version" ] || fail 'web static CLI pointer must not exist'
grep -F 'group: cli-release' "$workflow" >/dev/null || fail 'release workflow is not serialized'
grep -F 'cancel-in-progress: false' "$workflow" >/dev/null || fail 'release workflow may cancel an active publication'
grep -F 'persist-credentials: false' "$workflow" >/dev/null || fail 'checkout credentials must not persist through release builds'

guard_line=$(line_of 'name: Final release tag guard')
release_line=$(line_of 'gh release create "$GITHUB_REF_NAME"')
push_line=$(line_of 'git push origin "$channel_commit:refs/heads/cli-channel"')

[ "$guard_line" -lt "$release_line" ] || fail 'final tag guard must precede release creation'
[ "$release_line" -lt "$push_line" ] || fail 'release creation must precede channel publication'

push_command=$(grep -F 'git push origin "$channel_commit:refs/heads/cli-channel"' "$workflow")
case $push_command in
    *--force*) fail 'channel publication must never force push' ;;
esac

if grep -F 'ashdrop/web/static/cli-version' "$workflow" >/dev/null; then
    fail 'release workflow still validates the removed web static pointer'
fi

printf 'release workflow tests passed\n'
