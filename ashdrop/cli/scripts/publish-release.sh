#!/bin/sh
set -eu

fail() {
    printf 'release publication: %s\n' "$1" >&2
    exit 1
}

: "${VERSION:?VERSION is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_API_URL:?GITHUB_API_URL is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

dist_dir=${1:-dist}
x86_archive=ashdrop-v$VERSION-linux-x86_64.tar.gz
arm_archive=ashdrop-v$VERSION-linux-aarch64.tar.gz
for asset in "$x86_archive" "$arm_archive" SHA256SUMS; do
    [ -f "$dist_dir/$asset" ] || fail "missing built asset: $dist_dir/$asset"
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
response=$tmp_dir/release-response

verify_remote_tag() {
    tag_ref=refs/tags/$GITHUB_REF_NAME
    check_ref=refs/ashdrop-release-check/current
    git update-ref -d "$check_ref"
    git fetch --no-tags --force origin "$tag_ref:$check_ref"
    current_commit=$(git rev-parse --verify "$check_ref^{commit}")
    [ "$current_commit" = "$GITHUB_SHA" ] ||
        fail "release tag $GITHUB_REF_NAME moved: expected $GITHUB_SHA, found $current_commit"
}

status=$(curl --silent --show-error --location \
    --output "$response" \
    --write-out '%{http_code}' \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/tags/$GITHUB_REF_NAME") ||
    fail 'could not query existing release'

verify_remote_tag
case $status in
    404)
        gh release create "$GITHUB_REF_NAME" \
            "$dist_dir/$x86_archive" \
            "$dist_dir/$arm_archive" \
            "$dist_dir/SHA256SUMS" \
            --repo "$GITHUB_REPOSITORY" \
            --verify-tag \
            --title "Ashdrop CLI v$VERSION" \
            --notes "Linux x86_64 and ARM64 binaries for Ashdrop CLI v$VERSION. Verify downloads with SHA256SUMS and GitHub artifact attestations."
        ;;
    200)
        release_state=$(gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" \
            --json isDraft,isPrerelease --jq '"\(.isDraft) \(.isPrerelease)"') ||
            fail 'could not inspect existing release state'
        [ "$release_state" = 'false false' ] || fail 'existing release is not a published stable release'

        expected_names=$tmp_dir/expected-assets
        unsorted_names=$tmp_dir/unsorted-assets
        actual_names=$tmp_dir/actual-assets
        printf '%s\n' SHA256SUMS "$arm_archive" "$x86_archive" | LC_ALL=C sort >"$expected_names"
        gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" \
            --json assets --jq '.assets[].name' >"$unsorted_names" || fail 'could not inspect existing release assets'
        LC_ALL=C sort <"$unsorted_names" >"$actual_names"
        cmp -s "$expected_names" "$actual_names" || fail 'existing release asset set differs from built release'

        downloaded=$tmp_dir/downloaded
        mkdir "$downloaded"
        for asset in SHA256SUMS "$arm_archive" "$x86_archive"; do
            gh release download "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" \
                --pattern "$asset" --dir "$downloaded"
            cmp -s "$dist_dir/$asset" "$downloaded/$asset" ||
                fail "existing release asset differs from built asset: $asset"
        done
        ;;
    *)
        cat "$response" >&2
        fail "could not establish release state (GitHub API HTTP $status)"
        ;;
esac
verify_remote_tag
