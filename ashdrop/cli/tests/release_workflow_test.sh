#!/bin/sh
set -eu

test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
cli_dir=$(CDPATH= cd "$test_dir/.." && pwd)
repo_root=$(CDPATH= cd "$cli_dir/../.." && pwd)
workflow=$repo_root/.github/workflows/cli-release.yml
publisher=$cli_dir/scripts/publish-release.sh
promoter=$cli_dir/scripts/promote-channel.sh
tmp_dir=${TMPDIR:-/tmp}/ashdrop-release-workflow-test.$$
mkdir "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

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

if grep -F 'concurrency:' "$workflow" >/dev/null; then
    fail 'release workflow must not cancel or replace pending tag runs'
fi
grep -F 'persist-credentials: false' "$workflow" >/dev/null || fail 'checkout credentials must not persist'
version_test_line=$(line_of 'sh tests/release_version_test.sh')
workflow_test_line=$(line_of 'sh tests/release_workflow_test.sh')
setup_line=$(line_of 'name: Set up Zig')
attest_line=$(line_of 'uses: actions/attest-build-provenance@')
publish_line=$(line_of 'ashdrop/cli/scripts/publish-release.sh')
promote_line=$(line_of 'ashdrop/cli/scripts/promote-channel.sh')
[ "$version_test_line" -lt "$setup_line" ] || fail 'release version tests must run before release builds'
[ "$workflow_test_line" -lt "$setup_line" ] || fail 'release workflow tests must run before release builds'
[ "$workflow_test_line" -lt "$attest_line" ] || fail 'release workflow tests must run before attestation'
[ "$workflow_test_line" -lt "$publish_line" ] || fail 'release workflow tests must run before publication'
[ "$workflow_test_line" -lt "$promote_line" ] || fail 'release workflow tests must run before channel mutation'
[ "$publish_line" -lt "$promote_line" ] || fail 'channel promotion must follow release publication'

grep -F -- '--force' "$promoter" >/dev/null 2>&1 && fail 'channel promotion must never force push'

mock_bin=$tmp_dir/mock-bin
dist=$tmp_dir/dist
release_assets=$tmp_dir/release-assets
mkdir "$mock_bin" "$dist" "$release_assets"
printf 'x86 archive\n' >"$dist/ashdrop-v1.2.3-linux-x86_64.tar.gz"
printf 'arm archive\n' >"$dist/ashdrop-v1.2.3-linux-aarch64.tar.gz"
printf 'checksums\n' >"$dist/SHA256SUMS"
cp "$dist"/* "$release_assets/"

cat >"$mock_bin/curl" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
    case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '{}\n' >"$output"
printf '%s' "$RELEASE_STATUS"
EOF

cat >"$mock_bin/git" <<'EOF'
#!/bin/sh
printf 'git:%s\n' "$1" >>"$CALL_LOG"
case $1 in
    update-ref | fetch) exit 0 ;;
    rev-parse)
        count=0
        [ ! -f "$REV_COUNT" ] || count=$(cat "$REV_COUNT")
        count=$((count + 1))
        printf '%s\n' "$count" >"$REV_COUNT"
        if [ "${FAIL_POST_GUARD:-false}" = true ] && [ "$count" -eq 2 ]; then
            printf '%s\n' deadbeef
        else
            printf '%s\n' "$GITHUB_SHA"
        fi
        ;;
    *) exit 97 ;;
esac
EOF

cat >"$mock_bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = release ] || exit 97
case $2 in
    create)
        printf 'gh:create\n' >>"$CALL_LOG"
        ;;
    view)
        printf 'gh:view\n' >>"$CALL_LOG"
        case " $* " in
            *isDraft*) printf '%s\n' "$RELEASE_STATE" ;;
            *) printf '%s\n' "$RELEASE_ASSET_NAMES" ;;
        esac
        [ "${FAIL_RELEASE_VIEW:-false}" != true ] || exit 96
        ;;
    download)
        printf 'gh:download\n' >>"$CALL_LOG"
        pattern=
        destination=
        shift 2
        while [ "$#" -gt 0 ]; do
            case $1 in
                --pattern) pattern=$2; shift 2 ;;
                --dir) destination=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        cp "$RELEASE_ASSETS/$pattern" "$destination/$pattern"
        ;;
    *) exit 97 ;;
esac
EOF
chmod +x "$mock_bin/curl" "$mock_bin/git" "$mock_bin/gh"

expected_assets='SHA256SUMS
ashdrop-v1.2.3-linux-aarch64.tar.gz
ashdrop-v1.2.3-linux-x86_64.tar.gz'
call_log=$tmp_dir/calls
rev_count=$tmp_dir/rev-count

run_publisher() {
    RELEASE_STATUS=$1
    RELEASE_ASSET_NAMES=${2-}
    RELEASE_STATE=${3-'false false'}
    CALL_LOG=$call_log
    REV_COUNT=$rev_count
    RELEASE_ASSETS=$release_assets
    VERSION=1.2.3
    GITHUB_REF_NAME=cli-v1.2.3
    GITHUB_SHA=0123456789012345678901234567890123456789
    GITHUB_REPOSITORY=abdullah4tech/ashdrop
    GITHUB_API_URL=https://api.github.test
    GH_TOKEN=test-token
    export RELEASE_STATUS RELEASE_ASSET_NAMES RELEASE_STATE CALL_LOG REV_COUNT RELEASE_ASSETS VERSION
    export GITHUB_REF_NAME GITHUB_SHA GITHUB_REPOSITORY GITHUB_API_URL GH_TOKEN
    PATH=$mock_bin:$PATH "$publisher" "$dist"
}

: >"$call_log"
rm -f "$rev_count"
run_publisher 404
[ "$(grep -c '^git:rev-parse$' "$call_log")" -eq 2 ] || fail 'new release must have pre/post tag guards'
first_guard=$(grep -n '^git:rev-parse$' "$call_log" | cut -d: -f1 | sed -n '1p')
create_call=$(grep -n '^gh:create$' "$call_log" | cut -d: -f1)
second_guard=$(grep -n '^git:rev-parse$' "$call_log" | cut -d: -f1 | sed -n '2p')
[ "$first_guard" -lt "$create_call" ] && [ "$create_call" -lt "$second_guard" ] ||
    fail 'gh release create must be enclosed by immediate tag guards'

: >"$call_log"
rm -f "$rev_count"
run_publisher 200 "$expected_assets"
! grep -F 'gh:create' "$call_log" >/dev/null || fail 'matching release retry attempted to overwrite assets'
[ "$(grep -c '^gh:download$' "$call_log")" -eq 3 ] || fail 'matching release retry did not compare every asset'
[ "$(grep -c '^git:rev-parse$' "$call_log")" -eq 2 ] || fail 'existing release must have pre/post tag guards'

for invalid_state in 'true false' 'false true' '' 'malformed'; do
    : >"$call_log"
    rm -f "$rev_count"
    if run_publisher 200 "$expected_assets" "$invalid_state" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
        fail "invalid existing release state was accepted: ${invalid_state:-missing}"
    fi
done

printf 'different archive\n' >"$release_assets/ashdrop-v1.2.3-linux-x86_64.tar.gz"
: >"$call_log"
rm -f "$rev_count"
if run_publisher 200 "$expected_assets" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'differing existing release asset was accepted'
fi
cp "$dist/ashdrop-v1.2.3-linux-x86_64.tar.gz" "$release_assets/"

: >"$call_log"
rm -f "$rev_count"
FAIL_RELEASE_VIEW=true
export FAIL_RELEASE_VIEW
if run_publisher 200 "$expected_assets" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'failed existing release lookup was accepted'
fi
unset FAIL_RELEASE_VIEW

: >"$call_log"
rm -f "$rev_count"
if run_publisher 200 "$expected_assets
unexpected.txt" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'extra existing release asset was accepted'
fi

: >"$call_log"
rm -f "$rev_count"
if run_publisher 200 'SHA256SUMS
ashdrop-v1.2.3-linux-x86_64.tar.gz' >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'missing existing release asset was accepted'
fi

: >"$call_log"
rm -f "$rev_count"
FAIL_POST_GUARD=true
export FAIL_POST_GUARD
if run_publisher 404 >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'post-publication tag movement was accepted'
fi
unset FAIL_POST_GUARD

real_git=$(command -v git)
source_repo=$tmp_dir/source
remote_repo=$tmp_dir/remote.git
mkdir "$source_repo"
"$real_git" -C "$source_repo" init -q
"$real_git" -C "$source_repo" config user.name tester
"$real_git" -C "$source_repo" config user.email tester@example.com
printf 'source\n' >"$source_repo/README"
"$real_git" -C "$source_repo" add README
"$real_git" -C "$source_repo" commit -qm initial
base_sha=$("$real_git" -C "$source_repo" rev-parse HEAD)
"$real_git" clone -q --bare "$source_repo" "$remote_repo"
"$real_git" -C "$source_repo" remote add origin "$remote_repo"

run_promoter() {
    VERSION=$1 GITHUB_SHA=$base_sha GH_TOKEN=test-token "$promoter"
}

channel_version() {
    "$real_git" --git-dir="$remote_repo" show refs/heads/cli-channel:cli-version
}

(cd "$source_repo" && run_promoter 1.2.3)
[ "$(channel_version)" = 1.2.3 ] || fail 'first channel creation failed'
equal_commit=$("$real_git" --git-dir="$remote_repo" rev-parse refs/heads/cli-channel)
(cd "$source_repo" && run_promoter 1.2.3)
[ "$("$real_git" --git-dir="$remote_repo" rev-parse refs/heads/cli-channel)" = "$equal_commit" ] ||
    fail 'equal version changed the channel'
(cd "$source_repo" && run_promoter 1.1.9)
[ "$(channel_version)" = 1.2.3 ] || fail 'older release downgraded the channel'
(cd "$source_repo" && run_promoter 1.3.0)
[ "$(channel_version)" = 1.3.0 ] || fail 'newer release did not advance the channel'
(cd "$source_repo" && run_promoter 1.10.0)
[ "$(channel_version)" = 1.10.0 ] || fail 'semantic version comparison used lexical ordering'

"$real_git" -C "$source_repo" fetch -q origin cli-channel
"$real_git" -C "$source_repo" checkout -q --detach FETCH_HEAD
printf '1.11.0\n' >"$source_repo/cli-version"
"$real_git" -C "$source_repo" add cli-version
"$real_git" -C "$source_repo" commit -qm race
race_commit=$("$real_git" -C "$source_repo" rev-parse HEAD)
"$real_git" -C "$source_repo" checkout -q --detach "$base_sha"

race_bin=$tmp_dir/race-bin
mkdir "$race_bin"
cat >"$race_bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = push ] && [ ! -e "$RACE_MARKER" ]; then
    : >"$RACE_MARKER"
    "$REAL_GIT" push -q origin "$RACE_COMMIT:refs/heads/cli-channel"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$race_bin/git"
RACE_MARKER=$tmp_dir/raced
REAL_GIT=$real_git
RACE_COMMIT=$race_commit
export RACE_MARKER REAL_GIT RACE_COMMIT
(cd "$source_repo" && PATH=$race_bin:$PATH run_promoter 2.0.0)
[ -e "$RACE_MARKER" ] || fail 'push race fixture did not run'
[ "$(channel_version)" = 2.0.0 ] || fail 'promotion did not recover from non-fast-forward race'

"$real_git" -C "$source_repo" fetch -q origin cli-channel
"$real_git" -C "$source_repo" checkout -q --detach FETCH_HEAD
printf '2.0.0\nextra\n' >"$source_repo/cli-version"
"$real_git" -C "$source_repo" add cli-version
"$real_git" -C "$source_repo" commit -qm malformed-pointer
"$real_git" -C "$source_repo" push -q origin HEAD:refs/heads/cli-channel
"$real_git" -C "$source_repo" checkout -q --detach "$base_sha"
if (cd "$source_repo" && run_promoter 3.0.0) >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    fail 'malformed existing channel pointer was accepted'
fi

printf 'release workflow tests passed\n'
