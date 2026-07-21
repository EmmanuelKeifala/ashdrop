#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

case $# in
    1)
        script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        zon_path=$script_dir/../build.zig.zon
        ;;
    2)
        zon_path=$2
        ;;
    *)
        fail "usage: $0 cli-vMAJOR.MINOR.PATCH [build.zig.zon]"
        ;;
esac

tag=$1
case $tag in
    cli-v*) version=${tag#cli-v} ;;
    *) fail "invalid release tag: expected cli-vMAJOR.MINOR.PATCH" ;;
esac

case $version in
    '' | *[!0-9.]* | .* | *. | *..*)
        fail "invalid release tag: expected cli-vMAJOR.MINOR.PATCH"
        ;;
esac

old_ifs=$IFS
IFS=.
set -- $version
IFS=$old_ifs
[ "$#" -eq 3 ] || fail "invalid release tag: expected cli-vMAJOR.MINOR.PATCH"

for component do
    case $component in
        0 | [1-9] | [1-9][0-9]*) ;;
        *) fail "invalid release tag: numeric components must not have leading zeros" ;;
    esac
done

[ -f "$zon_path" ] && [ -r "$zon_path" ] || fail "cannot read package manifest: $zon_path"

declaration_count=$(awk '
    /^[[:space:]]*[.]version[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*([/][/].*)?$/ { count++ }
    END { print count + 0 }
' "$zon_path")

case $declaration_count in
    0) fail "package manifest has no .version declaration: $zon_path" ;;
    1) ;;
    *) fail "package manifest has multiple .version declarations: $zon_path" ;;
esac

package_version=$(awk '
    /^[[:space:]]*[.]version[[:space:]]*=[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*([/][/].*)?$/ {
        line = $0
        sub(/^[[:space:]]*[.]version[[:space:]]*=[[:space:]]*"/, "", line)
        sub(/"[[:space:]]*,?[[:space:]]*([/][/].*)?$/, "", line)
        print line
    }
' "$zon_path")

[ "$version" = "$package_version" ] || fail "release tag version $version does not match package version $package_version"

printf '%s\n' "$version"
