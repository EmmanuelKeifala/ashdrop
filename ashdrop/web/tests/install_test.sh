#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER=$ROOT/static/install.sh
ORIGINAL_PATH=$PATH
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ashdrop-installer-tests.XXXXXX")
SERVER_PID=

cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

tests=0
failures=0

fail() {
	printf 'not ok %s - %s\n' "$tests" "$1"
	failures=$((failures + 1))
}

begin_test() {
	tests=$((tests + 1))
	FAILURES_BEFORE=$failures
	TEST_NAME=$1
	CASE_DIR=$TEST_ROOT/case-$tests
	mkdir -p "$CASE_DIR/bin" "$CASE_DIR/home" "$CASE_DIR/tmp"
	cat >"$CASE_DIR/bin/uname" <<'EOF'
#!/bin/sh
case ${1-} in
	-s) printf '%s\n' "${TEST_UNAME_S:-Linux}" ;;
	-m) printf '%s\n' "${TEST_UNAME_M:-x86_64}" ;;
	*) exit 2 ;;
esac
EOF
	cat >"$CASE_DIR/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/curl.log"
exit 88
EOF
	chmod +x "$CASE_DIR/bin/uname" "$CASE_DIR/bin/curl"
	PATH=$CASE_DIR/bin:$ORIGINAL_PATH
	HOME=$CASE_DIR/home
	TMPDIR=$CASE_DIR/tmp
	XDG_BIN_HOME=
	TEST_UNAME_S=Linux
	TEST_UNAME_M=x86_64
	unset ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR
	export PATH HOME TMPDIR XDG_BIN_HOME TEST_UNAME_S TEST_UNAME_M CASE_DIR
}

run_installer() {
	set +e
	sh "$INSTALLER" "$@" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
	STATUS=$?
	set -e
}

expect_status() {
	if [ "$STATUS" -ne "$1" ]; then
		fail "$TEST_NAME: expected status $1, got $STATUS: $(tr '\n' ' ' <"$CASE_DIR/stderr")"
		return 1
	fi
}

expect_failure() {
	if [ "$STATUS" -eq 0 ]; then
		fail "$TEST_NAME: expected failure"
		return 1
	fi
}

expect_stderr() {
	if ! grep -F "$1" "$CASE_DIR/stderr" >/dev/null 2>&1; then
		fail "$TEST_NAME: stderr does not contain '$1': $(tr '\n' ' ' <"$CASE_DIR/stderr")"
		return 1
	fi
}

pass() {
	printf 'ok %s - %s\n' "$tests" "$TEST_NAME"
}

ensure_failure() {
	if [ "$failures" -eq "$FAILURES_BEFORE" ]; then
		fail "$1"
	fi
}

start_server() {
	FIXTURES=$TEST_ROOT/fixtures
	REQUEST_LOG=$TEST_ROOT/requests.log
	PORT_FILE=$TEST_ROOT/port
	mkdir -p "$FIXTURES"
	python3 - "$FIXTURES" <<'PY'
import hashlib
import io
import pathlib
import tarfile
import sys

root = pathlib.Path(sys.argv[1])

def add_member(output, name, kind="file", mode=0o755):
    data = b"#!/bin/sh\necho ashdrop\n"
    member = tarfile.TarInfo(name)
    member.mode = mode
    if kind == "file":
        member.size = len(data)
        output.addfile(member, io.BytesIO(data))
    elif kind == "symlink":
        member.type = tarfile.SYMTYPE
        member.linkname = "target"
        output.addfile(member)
    elif kind == "hardlink":
        member.type = tarfile.LNKTYPE
        member.linkname = "target"
        output.addfile(member)
    elif kind == "directory":
        member.type = tarfile.DIRTYPE
        output.addfile(member)
    elif kind == "device":
        member.type = tarfile.CHRTYPE
        output.addfile(member)

fixtures = {
    "1.2.3": [("ashdrop", "file", 0o755)],
    "1.1.0": [("ashdrop", "file", 0o755)],
    "2.0.0": [("ashdrop", "file", 0o755)],
    "2.0.1": [("ashdrop", "file", 0o755)],
    "2.0.2": [("ashdrop", "file", 0o755)],
    "2.0.3": [("/ashdrop", "file", 0o755)],
    "2.0.4": [("../ashdrop", "file", 0o755)],
    "2.0.5": [("ashdrop", "symlink", 0o755)],
    "2.0.6": [("ashdrop", "hardlink", 0o755)],
    "2.0.7": [("ashdrop", "file", 0o755), ("README", "file", 0o644)],
    "2.0.8": [("ashdrop", "file", 0o644)],
    "2.0.9": [("bin/ashdrop", "file", 0o755)],
    "2.0.10": [("./ashdrop", "file", 0o755)],
    "2.0.11": [("ashdrop", "directory", 0o755)],
    "2.0.12": [("ashdrop", "device", 0o755)],
    "2.0.13": [("ashdrop", "file", 0o755)],
}

for version, members in fixtures.items():
    release = root / f"cli-v{version}"
    release.mkdir()
    archive_name = f"ashdrop-v{version}-linux-x86_64.tar.gz"
    archive = release / archive_name
    with tarfile.open(archive, "w:gz") as output:
        for member in members:
            add_member(output, *member)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = f"{digest}  {archive_name}\n"
    if version == "2.0.0":
        manifest = f"{'0' * 64}  {archive_name}\n"
    elif version == "2.0.1":
        manifest = f"{digest}  another-file.tar.gz\n"
    elif version == "2.0.2":
        manifest = manifest + manifest
    elif version == "2.0.13":
        manifest = f"not-a-sha256  {archive_name}\n"
    (release / "SHA256SUMS").write_text(manifest)
PY
	cat >"$TEST_ROOT/server.py" <<'PY'
import http.server
import pathlib
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1])
request_log = pathlib.Path(sys.argv[2])
port_file = pathlib.Path(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with request_log.open("a") as output:
            output.write(path + "\n")
        if path == "/releases/latest":
            self.send_response(302)
            self.send_header("Location", "/releases/tag/cli-v1.2.3")
            self.end_headers()
            return
        if path == "/releases/tag/cli-v1.2.3":
            self.send_response(200)
            self.end_headers()
            return
        prefix = "/releases/download/"
        if path.startswith(prefix):
            relative = pathlib.PurePosixPath(path[len(prefix):])
            if ".." not in relative.parts and not relative.is_absolute():
                asset = root.joinpath(*relative.parts)
                if asset.is_file():
                    self.send_response(200)
                    self.send_header("Content-Length", str(asset.stat().st_size))
                    self.end_headers()
                    self.wfile.write(asset.read_bytes())
                    return
        self.send_error(404)

    def log_message(self, _format, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
PY
	python3 "$TEST_ROOT/server.py" "$FIXTURES" "$REQUEST_LOG" "$PORT_FILE" &
	SERVER_PID=$!
	wait_count=0
	while [ ! -s "$PORT_FILE" ]; do
		wait_count=$((wait_count + 1))
		[ "$wait_count" -lt 100 ] || {
			fail 'fixture server did not start'
			return 1
		}
		sleep 0.05
	done
	PORT=$(cat "$PORT_FILE")
	RELEASES_BASE=http://127.0.0.1:$PORT/releases
}

begin_test 'help exits without side effects'
run_installer --help
if expect_status 0 && grep -F 'Usage:' "$CASE_DIR/stdout" >/dev/null 2>&1 &&
	[ ! -e "$CASE_DIR/curl.log" ] && [ ! -e "$HOME/.local/bin/ashdrop" ]; then
	pass
else
	ensure_failure "$TEST_NAME"
fi

for bad_args in \
	'--unknown' \
	'--version' \
	'--version 1.2.3 --version 1.2.4' \
	'--install-dir' \
	'--install-dir /tmp/a --install-dir /tmp/b' \
	'--system --system' \
	'--system --install-dir /tmp/a' \
	'--version 1.2' \
	'--version 1.2.3-alpha' \
	'--version 01.2.3' \
	'--version 1.02.3' \
	'--version 1.2.03'
do
	begin_test "rejects arguments: $bad_args"
	# The cases contain only controlled words and paths; splitting is intentional.
	# shellcheck disable=SC2086
	run_installer $bad_args
	if expect_failure && [ ! -e "$CASE_DIR/curl.log" ]; then
		pass
	fi
done

begin_test 'rejects an empty install directory before network access'
run_installer --version 1.2.3 --install-dir ''
if expect_failure && expect_stderr 'requires a value' && [ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

begin_test 'rejects unsupported operating system'
TEST_UNAME_S=Darwin
export TEST_UNAME_S
run_installer --version 1.2.3
if expect_failure && expect_stderr 'unsupported operating system' && [ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

begin_test 'rejects unsupported architecture'
TEST_UNAME_M=riscv64
export TEST_UNAME_M
run_installer --version 1.2.3
if expect_failure && expect_stderr 'unsupported architecture' && [ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

for alias_mapping in 'x86_64 x86_64' 'amd64 x86_64' 'aarch64 aarch64' 'arm64 aarch64'
do
	set -- $alias_mapping
	begin_test "maps $1 to $2"
	TEST_UNAME_M=$1
	export TEST_UNAME_M
	run_installer --version 1.2.3
	if expect_failure && grep -F "ashdrop-v1.2.3-linux-$2.tar.gz" "$CASE_DIR/curl.log" >/dev/null 2>&1; then
		pass
	else
		ensure_failure "$TEST_NAME: expected mapped archive request"
	fi
done

start_server

begin_test 'resolves latest exactly once and uses immutable assets'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
: >"$REQUEST_LOG"
run_installer --install-dir "$CASE_DIR/install"
latest_count=$(grep -c '^/releases/latest$' "$REQUEST_LOG" || true)
if expect_status 0 && [ "$latest_count" -eq 1 ] &&
	grep -F '/releases/download/cli-v1.2.3/ashdrop-v1.2.3-linux-x86_64.tar.gz' "$REQUEST_LOG" >/dev/null &&
	grep -F '/releases/download/cli-v1.2.3/SHA256SUMS' "$REQUEST_LOG" >/dev/null; then
	pass
else
	ensure_failure "$TEST_NAME: expected one latest request and immutable asset requests"
fi

begin_test 'pinned version bypasses latest'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
: >"$REQUEST_LOG"
run_installer --version 1.1.0 --install-dir "$CASE_DIR/install"
if expect_status 0 && ! grep -F '/releases/latest' "$REQUEST_LOG" >/dev/null &&
	grep -F '/releases/download/cli-v1.1.0/ashdrop-v1.1.0-linux-x86_64.tar.gz' "$REQUEST_LOG" >/dev/null &&
	grep -F '/releases/download/cli-v1.1.0/SHA256SUMS' "$REQUEST_LOG" >/dev/null; then
	pass
else
	ensure_failure "$TEST_NAME: pinned request did not use immutable assets"
fi

begin_test 'rejects non-loopback HTTP release override'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=http://example.com/releases
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3
if expect_failure && expect_stderr 'loopback'; then
	pass
fi

begin_test 'rejects disguised non-loopback HTTP release override'
ASHDROP_RELEASES_BASE_URL=http://127.0.0.1:80@evil.example/releases
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3
if expect_failure && expect_stderr 'loopback' && [ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

for verification_case in \
	'2.0.0 checksum' \
	'2.0.1 checksum' \
	'2.0.2 checksum' \
	'2.0.3 unsafe' \
	'2.0.4 unsafe' \
	'2.0.5 unsafe' \
	'2.0.6 unsafe' \
	'2.0.7 unsafe' \
	'2.0.8 executable' \
	'2.0.9 unsafe' \
	'2.0.10 unsafe' \
	'2.0.11 unsafe' \
	'2.0.12 unsafe' \
	'2.0.13 checksum'
do
	set -- $verification_case
	begin_test "rejects invalid release fixture $1"
	rm "$CASE_DIR/bin/curl"
	ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
	export ASHDROP_RELEASES_BASE_URL
	run_installer --version "$1" --install-dir "$CASE_DIR/install"
	if expect_failure && expect_stderr "$2"; then
		pass
	fi
done

begin_test 'installs into the default user directory'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3
installed=$HOME/.local/bin/ashdrop
if expect_status 0 && [ -f "$installed" ] && [ -x "$installed" ] &&
	[ "$(stat -c %a "$installed")" = 755 ] &&
	grep -F '1.2.3' "$CASE_DIR/stdout" >/dev/null && grep -F 'PATH' "$CASE_DIR/stdout" >/dev/null; then
	pass
else
	ensure_failure "$TEST_NAME: default installation is incomplete"
fi

begin_test 'installs into XDG_BIN_HOME'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
XDG_BIN_HOME=$CASE_DIR/xdg-bin
export ASHDROP_RELEASES_BASE_URL XDG_BIN_HOME
run_installer --version 1.2.3
if expect_status 0 && [ -x "$XDG_BIN_HOME/ashdrop" ] && [ ! -e "$HOME/.local/bin/ashdrop" ]; then
	pass
else
	ensure_failure "$TEST_NAME: XDG installation is incomplete"
fi

begin_test 'installs into a custom directory'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
custom_dir=$CASE_DIR/custom-bin
run_installer --version 1.2.3 --install-dir "$custom_dir"
if expect_status 0 && [ -x "$custom_dir/ashdrop" ] && [ "$(stat -c %a "$custom_dir/ashdrop")" = 755 ]; then
	pass
else
	ensure_failure "$TEST_NAME: custom installation is incomplete"
fi

begin_test 'rejects a symlink install directory'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/real-bin"
ln -s "$CASE_DIR/real-bin" "$CASE_DIR/link-bin"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/link-bin"
if expect_failure && expect_stderr 'symlink' && [ ! -e "$CASE_DIR/real-bin/ashdrop" ]; then
	pass
fi

begin_test 'rejects a symlink install directory with a trailing slash'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/real-bin"
ln -s "$CASE_DIR/real-bin" "$CASE_DIR/link-bin"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/link-bin/"
if expect_failure && expect_stderr 'symlink' && [ ! -e "$CASE_DIR/real-bin/ashdrop" ]; then
	pass
fi

begin_test 'rejects a directory at the destination'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir -p "$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
if expect_failure && expect_stderr 'directory' && [ -d "$CASE_DIR/custom-bin/ashdrop" ]; then
	pass
fi

begin_test 'validation failure preserves an existing binary'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 2.0.0 --install-dir "$CASE_DIR/custom-bin"
if expect_failure && [ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ] &&
	[ ! -s "$CASE_DIR/stdout" ]; then
	pass
else
	ensure_failure "$TEST_NAME: existing binary or success output changed"
fi

begin_test 'atomically replaces through a destination-adjacent temporary file'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/mv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/mv.log"
exec /bin/mv "$@"
EOF
chmod +x "$CASE_DIR/bin/mv"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
if expect_status 0 && [ "$(cat "$CASE_DIR/custom-bin/ashdrop")" != sentinel ] &&
	grep -F "$CASE_DIR/custom-bin/.ashdrop." "$CASE_DIR/mv.log" >/dev/null &&
	grep -F "$CASE_DIR/custom-bin/ashdrop" "$CASE_DIR/mv.log" >/dev/null; then
	pass
else
	ensure_failure "$TEST_NAME: replacement was not destination-adjacent and atomic"
fi

begin_test 'removes private temporary files after success'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
set -- "$TMPDIR"/ashdrop-install.*
if expect_status 0 && [ ! -e "$1" ]; then
	pass
else
	ensure_failure "$TEST_NAME: temporary directory remains"
fi

begin_test 'system install invokes sudo once after verification'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/cp" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$CASE_DIR/privileged-tool.log"
exit 92
EOF
cat >"$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf 'call\n' >>"$CASE_DIR/sudo.log"
case $1 in sh | /bin/sh) ;; *) exit 90 ;; esac
[ "$2" = -c ] && [ -x "$5" ] || exit 90
grep -F '/SHA256SUMS' "$REQUEST_LOG" >/dev/null || exit 91
exec "$@"
EOF
chmod +x "$CASE_DIR/bin/cp" "$CASE_DIR/bin/sudo"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_SYSTEM_INSTALL_DIR=$CASE_DIR/system-bin
REQUEST_LOG=$REQUEST_LOG
export ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR REQUEST_LOG
mkdir "$ASHDROP_SYSTEM_INSTALL_DIR"
: >"$REQUEST_LOG"
run_installer --version 1.2.3 --system
if [ -f "$CASE_DIR/sudo.log" ]; then
	sudo_count=$(wc -l <"$CASE_DIR/sudo.log")
else
	sudo_count=0
fi
if expect_status 0 && [ "$sudo_count" -eq 1 ] && [ ! -e "$CASE_DIR/privileged-tool.log" ] &&
	[ -x "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop" ] &&
	[ "$(stat -c %a "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop")" = 755 ]; then
	pass
else
	ensure_failure "$TEST_NAME: system installation did not use one verified sudo call"
fi

begin_test 'failed system verification never invokes sudo or replaces destination'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$CASE_DIR/sudo.log"
exit 99
EOF
chmod +x "$CASE_DIR/bin/sudo"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_SYSTEM_INSTALL_DIR=$CASE_DIR/system-bin
export ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR
mkdir "$ASHDROP_SYSTEM_INSTALL_DIR"
printf 'sentinel\n' >"$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop"
run_installer --version 2.0.0 --system
if expect_failure && [ ! -e "$CASE_DIR/sudo.log" ] &&
	[ "$(cat "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop")" = sentinel ]; then
	pass
else
	ensure_failure "$TEST_NAME: sudo ran or destination changed before verification"
fi

printf '%s tests, %s failures\n' "$tests" "$failures"
[ "$failures" -eq 0 ]
