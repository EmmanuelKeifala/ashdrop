#!/bin/sh
set -eu
umask 077
set -f
LC_ALL=C
export LC_ALL

usage() {
	cat <<'EOF'
Usage: install.sh [--version X.Y.Z] [--install-dir PATH] [--system]

Options:
  --version X.Y.Z    Install a specific stable version
  --install-dir PATH Install into PATH
  --system           Install into /usr/local/bin using sudo
  --help             Show this help
EOF
}

die() {
	printf 'ashdrop installer: %s\n' "$1" >&2
	exit 1
}

valid_version() {
	case $1 in
		'' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac

	old_ifs=$IFS
	IFS=.
	set -- $1
	IFS=$old_ifs
	[ "$#" -eq 3 ] || return 1
	for component do
		case $component in
			0 | [1-9] | [1-9][0-9]*) ;;
			*) return 1 ;;
		esac
	done
}

version=
version_set=false
install_dir=
install_dir_set=false
system=false
help=false

while [ "$#" -gt 0 ]; do
	case $1 in
		--version)
			$version_set && die '--version may only be specified once'
			[ "$#" -ge 2 ] || die '--version requires a value'
			case $2 in --*) die '--version requires a value' ;; esac
			version=$2
			version_set=true
			shift 2
			;;
		--install-dir)
			$install_dir_set && die '--install-dir may only be specified once'
			[ "$#" -ge 2 ] || die '--install-dir requires a value'
			case $2 in --*) die '--install-dir requires a value' ;; esac
			[ -n "$2" ] || die '--install-dir requires a value'
			install_dir=$2
			install_dir_set=true
			shift 2
			;;
		--system)
			$system && die '--system may only be specified once'
			system=true
			shift
			;;
		--help)
			$help && die '--help may only be specified once'
			help=true
			shift
			;;
		*) die "unknown argument: $1" ;;
	esac
done

if $help; then
	$version_set && die '--help cannot be combined with other options'
	$install_dir_set && die '--help cannot be combined with other options'
	$system && die '--help cannot be combined with other options'
	usage
	exit 0
fi

$system && $install_dir_set && die '--system cannot be combined with --install-dir'
if $version_set; then
	valid_version "$version" || die "invalid stable version: $version"
fi

os=$(uname -s) || die 'could not detect operating system'
[ "$os" = Linux ] || die "unsupported operating system: $os (Linux required)"

machine=$(uname -m) || die 'could not detect architecture'
case $machine in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) die "unsupported architecture: $machine (x86_64 or aarch64 required)" ;;
esac

tmp_dir=
pending_file=
cleanup() {
	if [ -n "$pending_file" ]; then
		rm -f "$pending_file"
	fi
	if [ -n "$tmp_dir" ]; then
		rm -rf "$tmp_dir"
	fi
}
trap cleanup 0 1 2 3 15
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ashdrop-install.XXXXXX") || die 'could not create temporary directory'

test_http=false
if [ "${ASHDROP_RELEASES_BASE_URL+x}" = x ]; then
	releases_base=${ASHDROP_RELEASES_BASE_URL%/}
	case $releases_base in
		https://*) ;;
		http://*)
			http_authority=${releases_base#http://}
			http_authority=${http_authority%%/*}
			case $http_authority in
				127.0.0.1 | localhost | '[::1]') ;;
				127.0.0.1:* | localhost:*)
					http_port=${http_authority#*:}
					case $http_port in '' | *[!0-9]*) die 'HTTP release override must use a loopback host' ;; esac
					;;
				'[::1]:'*)
					http_port=${http_authority#'[::1]:'}
					case $http_port in '' | *[!0-9]*) die 'HTTP release override must use a loopback host' ;; esac
					;;
				*) die 'HTTP release override must use a loopback host' ;;
			esac
			test_http=true
			;;
		*) die 'release override must be an HTTPS URL' ;;
	esac
else
	releases_base=https://github.com/abdullah4tech/ashdrop/releases
fi

curl_download() {
	_download_output=$1
	_download_url=$2
	if $test_http; then
		curl --fail --location --silent --show-error \
			--proto '=http' --proto-redir '=http' \
			--output "$_download_output" "$_download_url"
	else
		curl --fail --location --silent --show-error \
			--proto '=https' --proto-redir '=https' --tlsv1.2 \
			--output "$_download_output" "$_download_url"
	fi
}

if ! $version_set; then
	api_test_http=false
	if [ "${ASHDROP_RELEASES_API_URL+x}" = x ]; then
		releases_api_url=${ASHDROP_RELEASES_API_URL%/}
		case $releases_api_url in
			http://*)
				api_authority=${releases_api_url#http://}
				api_authority=${api_authority%%/*}
				case $api_authority in
					127.0.0.1 | localhost | '[::1]') ;;
					127.0.0.1:* | localhost:*)
						api_port=${api_authority#*:}
						case $api_port in '' | *[!0-9]*) die 'HTTP releases API override must use a loopback host' ;; esac
						;;
					'[::1]:'*)
						api_port=${api_authority#'[::1]:'}
						case $api_port in '' | *[!0-9]*) die 'HTTP releases API override must use a loopback host' ;; esac
						;;
					*) die 'HTTP releases API override must use a loopback host' ;;
				esac
				api_test_http=true
				;;
			*) die 'releases API override must use a loopback host' ;;
		esac
	else
		releases_api_url='https://api.github.com/repos/abdullah4tech/ashdrop/releases?per_page=100'
	fi

	api_response=$tmp_dir/releases.json
	if $api_test_http; then
		curl --fail --silent --show-error --max-filesize 8388608 \
			--proto '=http' --proto-redir '=http' \
			--output "$api_response" "$releases_api_url" || die 'failed to query releases API'
	else
		curl --fail --silent --show-error --max-filesize 8388608 \
			--proto '=https' --proto-redir '=https' --tlsv1.2 \
			--header 'Accept: application/vnd.github+json' \
			--header 'X-GitHub-Api-Version: 2022-11-28' \
			--output "$api_response" "$releases_api_url" || die 'failed to query releases API'
	fi
	api_size=$(wc -c <"$api_response")
	[ "$api_size" -le 8388608 ] || die 'releases API response exceeds size limit'
	command -v awk >/dev/null 2>&1 || die 'required command not found: awk'

	if version=$(awk '
		function bad() { exit 2 }
		function ws(    c) {
			while (p <= n) {
				c = substr(json, p, 1)
				if (c !~ /[ \t\r\n]/) break
				p++
			}
		}
		function string(    c, e, h, s) {
			if (substr(json, p, 1) != "\"") bad()
			p++; s = ""
			while (p <= n) {
				c = substr(json, p++, 1)
				if (c == "\"") { value = s; return }
				if (c == "\\") {
					if (p > n) bad()
					e = substr(json, p++, 1)
					if (e == "\"" || e == "\\" || e == "/") s = s e
					else if (e ~ /^[bfnrt]$/) s = s "?"
					else if (e == "u") {
						h = substr(json, p, 4)
						if (length(h) != 4 || h !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) bad()
						p += 4; s = s "?"
					} else bad()
				} else {
					if (c ~ /[[:cntrl:]]/) bad()
					s = s c
				}
			}
			bad()
		}
		function number(    c) {
			if (substr(json, p, 1) == "-") p++
			c = substr(json, p, 1)
			if (c == "0") { p++; if (substr(json, p, 1) ~ /[0-9]/) bad() }
			else if (c ~ /[1-9]/) { while (substr(json, p, 1) ~ /[0-9]/) p++ }
			else bad()
			if (substr(json, p, 1) == ".") {
				p++; if (substr(json, p, 1) !~ /[0-9]/) bad()
				while (substr(json, p, 1) ~ /[0-9]/) p++
			}
			c = substr(json, p, 1)
			if (c == "e" || c == "E") {
				p++; c = substr(json, p, 1); if (c == "+" || c == "-") p++
				if (substr(json, p, 1) !~ /[0-9]/) bad()
				while (substr(json, p, 1) ~ /[0-9]/) p++
			}
			type = "number"
		}
		function array(    c) {
			p++; ws(); if (substr(json, p, 1) == "]") { p++; return }
			while (1) {
				item(); ws(); c = substr(json, p++, 1)
				if (c == "]") return
				if (c != ",") bad()
				ws()
			}
		}
		function object(    c) {
			p++; ws(); if (substr(json, p, 1) == "}") { p++; return }
			while (1) {
				string(); ws(); if (substr(json, p++, 1) != ":") bad()
				ws(); item(); ws(); c = substr(json, p++, 1)
				if (c == "}") return
				if (c != ",") bad()
				ws()
			}
		}
		function item(    c) {
			ws(); c = substr(json, p, 1)
			if (c == "\"") { string(); type = "string" }
			else if (c == "{") { object(); type = "object" }
			else if (c == "[") { array(); type = "array" }
			else if (substr(json, p, 4) == "true") { p += 4; type = "bool"; value = "true" }
			else if (substr(json, p, 5) == "false") { p += 5; type = "bool"; value = "false" }
			else if (substr(json, p, 4) == "null") { p += 4; type = "null"; value = "null" }
			else if (c == "-" || c ~ /[0-9]/) number()
			else bad()
		}
		function release(    c, key, tag, draft, pre, tag_n, draft_n, pre_n) {
			if (substr(json, p++, 1) != "{") bad()
			ws(); if (substr(json, p, 1) == "}") bad()
			while (1) {
				string(); key = value; ws(); if (substr(json, p++, 1) != ":") bad()
				ws(); item()
				if (key == "tag_name") { if (++tag_n != 1 || type != "string") bad(); tag = value }
				else if (key == "draft") { if (++draft_n != 1 || type != "bool") bad(); draft = value }
				else if (key == "prerelease") { if (++pre_n != 1 || type != "bool") bad(); pre = value }
				ws(); c = substr(json, p++, 1)
				if (c == "}") break
				if (c != ",") bad()
				ws()
			}
			if (tag_n != 1 || draft_n != 1 || pre_n != 1) bad()
			if (!found && draft == "false" && pre == "false" &&
				tag ~ /^cli-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
				selected = substr(tag, 6); found = 1
			}
		}
		function root(    c) {
			ws(); if (substr(json, p++, 1) != "[") bad()
			ws(); if (substr(json, p, 1) == "]") { p++; return }
			while (1) {
				release(); ws(); c = substr(json, p++, 1)
				if (c == "]") break
				if (c != ",") bad()
				ws()
			}
			ws(); if (p <= n) bad()
		}
		{ json = json $0 "\n" }
		END {
			n = length(json); p = 1; root()
			if (!found) exit 3
			print selected
		}
	' "$api_response"); then
		valid_version "$version" || die 'malformed releases API response'
	else
		api_parse_status=$?
		case $api_parse_status in
			3) die 'no stable CLI release found in releases API response' ;;
			*) die 'malformed releases API response' ;;
		esac
	fi
fi

archive_name=ashdrop-v$version-linux-$arch.tar.gz
archive_url=$releases_base/download/cli-v$version/$archive_name
checksums_url=$releases_base/download/cli-v$version/SHA256SUMS

curl_download "$tmp_dir/$archive_name" "$archive_url" || die "failed to download $archive_name"
curl_download "$tmp_dir/SHA256SUMS" "$checksums_url" || die 'failed to download SHA256SUMS'

command -v awk >/dev/null 2>&1 || die 'required command not found: awk'
command -v tar >/dev/null 2>&1 || die 'required command not found: tar'

awk -v archive="$archive_name" \
	'NF == 2 && ($2 == archive || $2 == "*" archive) { print $1 }' \
	"$tmp_dir/SHA256SUMS" >"$tmp_dir/matching-digests"
match_count=$(wc -l <"$tmp_dir/matching-digests")
[ "$match_count" -eq 1 ] || die "checksum manifest must contain exactly one entry for $archive_name"
IFS= read -r expected_digest <"$tmp_dir/matching-digests" || die 'could not read checksum manifest entry'
case $expected_digest in
	*[!0-9A-Fa-f]* | '') die "checksum entry for $archive_name is not a SHA-256 digest" ;;
esac
[ "${#expected_digest}" -eq 64 ] || die "checksum entry for $archive_name is not a SHA-256 digest"

archive_path=$tmp_dir/$archive_name
if command -v sha256sum >/dev/null 2>&1; then
	sha256_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
	sha256_tool=shasum
elif command -v openssl >/dev/null 2>&1; then
	sha256_tool=openssl
else
	die 'required SHA-256 tool not found (sha256sum, shasum, or openssl)'
fi

calculate_sha256() {
	_digest_path=$1
	case $sha256_tool in
		sha256sum) _digest_output=$(sha256sum "$_digest_path") || return 1 ;;
		shasum) _digest_output=$(shasum -a 256 "$_digest_path") || return 1 ;;
		openssl)
			_digest_output=$(openssl dgst -sha256 "$_digest_path") || return 1
			_digest_output=$(printf '%s\n' "$_digest_output" | awk '{ print $NF }') || return 1
			;;
	esac
	set -- $_digest_output
	[ "$#" -ge 1 ] || return 1
	printf '%s\n' "$1"
}

actual_digest=$(calculate_sha256 "$archive_path") || die "SHA-256 calculation failed with $sha256_tool"

expected_digest=$(printf '%s' "$expected_digest" | tr 'A-F' 'a-f')
actual_digest=$(printf '%s' "$actual_digest" | tr 'A-F' 'a-f')
[ "$actual_digest" = "$expected_digest" ] || die "checksum mismatch for $archive_name"

tar -tzf "$archive_path" >"$tmp_dir/archive-names" || die 'unsafe archive: could not list contents'
name_count=$(wc -l <"$tmp_dir/archive-names")
[ "$name_count" -eq 1 ] || die 'unsafe archive: expected exactly one entry named ashdrop'
IFS= read -r archive_member <"$tmp_dir/archive-names" || die 'unsafe archive: empty member name'
[ "$archive_member" = ashdrop ] || die 'unsafe archive: only a top-level ashdrop file is allowed'

tar -tvzf "$archive_path" >"$tmp_dir/archive-details" || die 'unsafe archive: could not inspect entry type'
detail_count=$(wc -l <"$tmp_dir/archive-details")
[ "$detail_count" -eq 1 ] || die 'unsafe archive: expected exactly one entry'
IFS= read -r archive_detail <"$tmp_dir/archive-details" || die 'unsafe archive: missing entry details'
archive_type=${archive_detail%"${archive_detail#?}"}
[ "$archive_type" = '-' ] || die 'unsafe archive: ashdrop must be a regular file'

mkdir "$tmp_dir/extracted" || die 'could not create private extraction directory'
tar -xzf "$archive_path" -C "$tmp_dir/extracted" || die 'unsafe archive: extraction failed'
verified_binary=$tmp_dir/extracted/ashdrop
[ -f "$verified_binary" ] && [ ! -L "$verified_binary" ] || die 'unsafe archive: ashdrop is not a regular file'
[ -x "$verified_binary" ] || die 'extracted ashdrop is not executable'
verified_digest=$(calculate_sha256 "$verified_binary") || die "SHA-256 calculation failed with $sha256_tool"
case $verified_digest in
	*[!0-9A-Fa-f]* | '') die 'verified binary digest is not a SHA-256 digest' ;;
esac
[ "${#verified_digest}" -eq 64 ] || die 'verified binary digest is not a SHA-256 digest'

if $system; then
	system_install_dir=${ASHDROP_SYSTEM_INSTALL_DIR:-/usr/local/bin}
	while [ "$system_install_dir" != / ] && [ "${system_install_dir%/}" != "$system_install_dir" ]; do
		system_install_dir=${system_install_dir%/}
	done
	case $system_install_dir in
		/*) ;;
		*) die 'system install directory must be an absolute path' ;;
	esac
	[ ! -L "$system_install_dir" ] || die 'system install directory must not be a symlink'
	command -v sudo >/dev/null 2>&1 || die 'required command not found: sudo'
	sudo /bin/sh -c '
		set -eu
		set -f
		umask 077
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin
		export PATH
		source_file=$1
		install_dir=$2
		expected_digest=$3
		[ -d "$install_dir" ] || {
			printf "%s\n" "ashdrop installer: system install directory does not exist" >&2
			exit 1
		}
		[ ! -d "$install_dir/ashdrop" ] || {
			printf "%s\n" "ashdrop installer: destination is a directory" >&2
			exit 1
		}
		pending=$(mktemp "$install_dir/.ashdrop.XXXXXX")
		trap '\''rm -f "$pending"'\'' 0 1 2 3 15
		cp "$source_file" "$pending"
		digest_failed() {
			printf "%s\n" "ashdrop installer: could not verify privileged copy" >&2
			exit 1
		}
		if command -v sha256sum >/dev/null 2>&1; then
			digest_output=$(sha256sum "$pending") || digest_failed
			set -- $digest_output
			[ "$#" -ge 1 ] || digest_failed
			copied_digest=$1
		elif command -v shasum >/dev/null 2>&1; then
			digest_output=$(shasum -a 256 "$pending") || digest_failed
			set -- $digest_output
			[ "$#" -ge 1 ] || digest_failed
			copied_digest=$1
		elif command -v openssl >/dev/null 2>&1; then
			digest_output=$(openssl dgst -sha256 "$pending") || digest_failed
			set -- $digest_output
			[ "$#" -ge 1 ] || digest_failed
			for copied_digest do :; done
		else
			digest_failed
		fi
		[ "$copied_digest" = "$expected_digest" ] || {
			printf "%s\n" "ashdrop installer: verified binary changed before system installation" >&2
			exit 1
		}
		chmod 0755 "$pending"
		mv -f "$pending" "$install_dir/ashdrop"
		pending=
	' sh "$verified_binary" "$system_install_dir" "$verified_digest" || die 'system installation failed'
	install_dir=$system_install_dir
else
	if ! $install_dir_set; then
		if [ -n "${XDG_BIN_HOME:-}" ]; then
			install_dir=$XDG_BIN_HOME
		else
			[ -n "${HOME:-}" ] || die 'HOME is not set and XDG_BIN_HOME was not provided'
			install_dir=$HOME/.local/bin
		fi
	fi
	[ -n "$install_dir" ] || die 'install directory must not be empty'
	while [ "$install_dir" != / ] && [ "${install_dir%/}" != "$install_dir" ]; do
		install_dir=${install_dir%/}
	done
	case $install_dir in
		/*) ;;
		*) install_dir=$PWD/$install_dir ;;
	esac
	[ ! -L "$install_dir" ] || die 'install directory must not be a symlink'
	if [ -e "$install_dir" ]; then
		[ -d "$install_dir" ] || die 'install path exists and is not a directory'
	else
		mkdir -p "$install_dir" || die 'could not create install directory'
	fi
	[ ! -L "$install_dir" ] || die 'install directory must not be a symlink'
	destination=$install_dir/ashdrop
	[ ! -d "$destination" ] || die 'destination is a directory'
	pending_file=$(mktemp "$install_dir/.ashdrop.XXXXXX") || die 'could not create pending installation file'
	cp "$verified_binary" "$pending_file" || die 'could not copy verified binary'
	chmod 0755 "$pending_file" || die 'could not set executable permissions'
	mv -f "$pending_file" "$destination" || die 'could not atomically replace destination'
	pending_file=
fi

printf 'Installed Ashdrop %s to %s/ashdrop\n' "$version" "$install_dir"
case :${PATH:-}: in
	*":$install_dir:"*) ;;
	*) printf 'Add %s to your PATH.\n' "$install_dir" ;;
esac
