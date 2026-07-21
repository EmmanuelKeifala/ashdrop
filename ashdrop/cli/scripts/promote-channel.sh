#!/bin/bash
set -euo pipefail

fail() {
    printf 'CLI channel promotion: %s\n' "$1" >&2
    exit 1
}

: "${VERSION:?VERSION is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

stable_version='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ $VERSION =~ $stable_version ]] || fail "invalid release version: $VERSION"

compare_versions() {
    local left=$1 right=$2
    local left_parts right_parts index left_part right_part
    IFS=. read -r -a left_parts <<<"$left"
    IFS=. read -r -a right_parts <<<"$right"
    for index in 0 1 2; do
        left_part=${left_parts[$index]}
        right_part=${right_parts[$index]}
        if ((${#left_part} > ${#right_part})); then
            VERSION_ORDER=1
            return
        elif ((${#left_part} < ${#right_part})); then
            VERSION_ORDER=-1
            return
        elif [[ $left_part > $right_part ]]; then
            VERSION_ORDER=1
            return
        elif [[ $left_part < $right_part ]]; then
            VERSION_ORDER=-1
            return
        fi
    done
    VERSION_ORDER=0
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
askpass=$tmp_dir/askpass.sh
cat >"$askpass" <<'EOF'
#!/bin/sh
case $1 in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) printf '%s\n' "$GH_TOKEN" ;;
    *) exit 1 ;;
esac
EOF
chmod 0700 "$askpass"

git_auth() {
    GIT_ASKPASS=$askpass GIT_TERMINAL_PROMPT=0 git "$@"
}

channel_ref=refs/heads/cli-channel
check_ref=refs/ashdrop-channel-check/current
attempt=1
max_attempts=5
push_error=$tmp_dir/push-error
: >"$push_error"
while ((attempt <= max_attempts)); do
    set +e
    git_auth ls-remote --exit-code --heads origin "$channel_ref" >/dev/null
    channel_status=$?
    set -e

    case $channel_status in
        0)
            git update-ref -d "$check_ref"
            if ! git_auth fetch --quiet --no-tags origin "$channel_ref:$check_ref"; then
                ((attempt++))
                continue
            fi
            channel_base=$check_ref
            pointer_file=$tmp_dir/current-version
            git show "$check_ref:cli-version" >"$pointer_file" || fail 'existing CLI channel has no cli-version pointer'
            pointer_size=$(wc -c <"$pointer_file")
            if ! IFS= read -r current_version <"$pointer_file"; then
                fail 'existing CLI channel pointer is malformed'
            fi
            expected_size=$((${#current_version} + 1))
            [[ $current_version =~ $stable_version ]] && ((pointer_size == expected_size)) ||
                fail 'existing CLI channel pointer is malformed'
            compare_versions "$current_version" "$VERSION"
            if ((VERSION_ORDER >= 0)); then
                exit 0
            fi
            ;;
        2) channel_base=$GITHUB_SHA ;;
        *) fail "could not inspect CLI channel (git status $channel_status)" ;;
    esac

    pointer_file=$tmp_dir/new-version
    printf '%s\n' "$VERSION" >"$pointer_file"
    index_file=$tmp_dir/index
    rm -f "$index_file"
    GIT_INDEX_FILE=$index_file git read-tree "$channel_base"
    pointer_blob=$(git hash-object -w "$pointer_file")
    GIT_INDEX_FILE=$index_file git update-index --add --cacheinfo 100644 "$pointer_blob" cli-version
    channel_tree=$(GIT_INDEX_FILE=$index_file git write-tree)
    channel_commit=$(printf 'chore: promote CLI channel to v%s\n' "$VERSION" | \
        git -c user.name='github-actions[bot]' \
            -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
            commit-tree "$channel_tree" -p "$channel_base")

    if git_auth push --quiet origin "$channel_commit:$channel_ref" 2>"$push_error"; then
        exit 0
    fi
    ((attempt++))
done

cat "$push_error" >&2
fail "could not advance CLI channel after $max_attempts attempts"
