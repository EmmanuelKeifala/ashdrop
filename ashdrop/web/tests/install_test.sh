#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER=$ROOT/static/install.sh
ORIGINAL_PATH=$PATH
POSIX_SH=$(command -v sh)
PYTHON3=$(command -v python3)
REAL_CHMOD=$(command -v chmod)
REAL_CP=$(command -v cp)
REAL_MKTEMP=$(command -v mktemp)
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
REAL_STAT=$(command -v stat)
export POSIX_SH PYTHON3 REAL_CHMOD REAL_CP REAL_MKTEMP REAL_MV REAL_RM REAL_STAT
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
assertions=0
test_active=false
test_passed=false

fail() {
	printf 'not ok %s - %s\n' "$tests" "$1"
	failures=$((failures + 1))
}

begin_test() {
	finish_test
	PATH=$ORIGINAL_PATH
	export PATH
	tests=$((tests + 1))
	FAILURES_BEFORE=$failures
	test_active=true
	test_passed=false
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
	unset ASHDROP_CLI_VERSION_URL ASHDROP_EXECUTION_MARKER ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR
	export PATH HOME TMPDIR XDG_BIN_HOME TEST_UNAME_S TEST_UNAME_M CASE_DIR
}

run_installer() {
	set +e
	"$POSIX_SH" "$INSTALLER" "$@" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
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
	test_passed=true
	printf 'ok %s - %s\n' "$tests" "$TEST_NAME"
}

finish_test() {
	$test_active || return 0
	if ! $test_passed && [ "$failures" -eq "$FAILURES_BEFORE" ]; then
		fail "$TEST_NAME: assertions completed without recording a result"
	fi
	assertions=$((assertions + 1))
	test_active=false
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
    data = b"#!/bin/sh\n[ -z \"${ASHDROP_EXECUTION_MARKER:-}\" ] || : >\"$ASHDROP_EXECUTION_MARKER\"\n"
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

root = pathlib.Path(sys.argv[1])
request_log = pathlib.Path(sys.argv[2])
port_file = pathlib.Path(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path
        with request_log.open("a") as output:
            output.write(path + "\n")
        pointer_responses = {
            "/pointer/version": b"1.2.3\n",
            "/pointer/malformed": b"1.2\n",
            "/pointer/oversized": b"1" * 64,
            "/pointer/extra": b"1.2.3\nextra\n",
            "/pointer/no-response": b"",
            "/pointer/no-newline": b"1.2.3",
            "/pointer/leading-zero": b"01.2.3\n",
            "/pointer/whitespace": b" 1.2.3\n",
        }
        if path in pointer_responses:
            body = pointer_responses[path]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
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
	CLI_VERSION_URL=http://127.0.0.1:$PORT/pointer/version
	TEST_DIGEST=$(awk '{ print $1; exit }' "$FIXTURES/cli-v1.2.3/SHA256SUMS")
	export TEST_DIGEST
}

isolate_installer_path() {
	ISOLATED_TOOLS=$CASE_DIR/tools
	mkdir "$ISOLATED_TOOLS"
	for tool in awk tar gzip wc tr mkdir rm mktemp cp chmod mv curl cat grep; do
		tool_path=$(PATH=$ORIGINAL_PATH command -v "$tool")
		ln -s "$tool_path" "$ISOLATED_TOOLS/$tool"
	done
	rm "$CASE_DIR/bin/curl"
	PATH=$CASE_DIR/bin:$ISOLATED_TOOLS
	export PATH
}

add_digest_tool() {
	case $1 in
		sha256sum)
			cat >"$ISOLATED_TOOLS/sha256sum" <<'EOF'
#!/bin/sh
printf 'sha256sum\n' >>"$CASE_DIR/digest-tools.log"
printf '%s  %s\n' "$TEST_DIGEST" "$1"
EOF
			;;
		sha256sum-fail)
			cat >"$ISOLATED_TOOLS/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "$TEST_DIGEST" "$1"
exit 98
EOF
			;;
		shasum)
			cat >"$ISOLATED_TOOLS/shasum" <<'EOF'
#!/bin/sh
printf 'shasum\n' >>"$CASE_DIR/digest-tools.log"
[ "$1" = -a ] && [ "$2" = 256 ] || exit 97
shift 2
printf '%s  %s\n' "$TEST_DIGEST" "$1"
EOF
			;;
		shasum-fail)
			cat >"$ISOLATED_TOOLS/shasum" <<'EOF'
#!/bin/sh
[ "$1" = -a ] && [ "$2" = 256 ] || exit 97
shift 2
printf '%s  %s\n' "$TEST_DIGEST" "$1"
exit 98
EOF
			;;
		openssl)
			cat >"$ISOLATED_TOOLS/openssl" <<'EOF'
#!/bin/sh
printf 'openssl\n' >>"$CASE_DIR/digest-tools.log"
[ "$1" = dgst ] && [ "$2" = -sha256 ] || exit 97
printf 'SHA2-256(%s)= %s\n' "$3" "$TEST_DIGEST"
EOF
			;;
	esac
	case $1 in
		sha256sum-fail) digest_tool_path=$ISOLATED_TOOLS/sha256sum ;;
		shasum-fail) digest_tool_path=$ISOLATED_TOOLS/shasum ;;
		*) digest_tool_path=$ISOLATED_TOOLS/$1 ;;
	esac
	chmod +x "$digest_tool_path"
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
	'--unknown|unknown argument' \
	'--version|requires a value' \
	'--version 1.2.3 --version 1.2.4|only be specified once' \
	'--install-dir|requires a value' \
	'--install-dir /tmp/a --install-dir /tmp/b|only be specified once' \
	'--system --system|only be specified once' \
	'--system --install-dir /tmp/a|cannot be combined' \
	'--version 1.2|invalid stable version' \
	'--version 1.2.3-alpha|invalid stable version' \
	'--version 01.2.3|invalid stable version' \
	'--version 1.02.3|invalid stable version' \
	'--version 1.2.03|invalid stable version'
do
	expected_error=${bad_args##*|}
	bad_args=${bad_args%|*}
	begin_test "rejects arguments: $bad_args"
	# The cases contain only controlled words and paths; splitting is intentional.
	# shellcheck disable=SC2086
	run_installer $bad_args
	if expect_failure && expect_stderr "$expected_error" && [ ! -e "$CASE_DIR/curl.log" ]; then
		pass
	fi
done

begin_test 'production curl enforces HTTPS protocols and TLS 1.2'
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'failed to download' &&
	grep -F -- '--proto =https' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--proto-redir =https' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--tlsv1.2' "$CASE_DIR/curl.log" >/dev/null; then
	pass
fi

begin_test 'creates a private temporary directory before download'
cat >"$CASE_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = --output ]; then
		output=$2
		break
	fi
	shift
done
[ -n "$output" ] || exit 96
"$REAL_STAT" -c %a "${output%/*}" >"$CASE_DIR/temp-mode"
exit 88
EOF
chmod +x "$CASE_DIR/bin/curl"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'failed to download' && [ "$(cat "$CASE_DIR/temp-mode")" = 700 ]; then
	pass
fi

begin_test 'production default uses bounded HTTPS CLI version pointer'
run_installer --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'failed to fetch CLI version pointer' &&
	grep -F 'https://ashdrop.vercel.app/cli-version' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--max-filesize 32' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--proto =https' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--proto-redir =https' "$CASE_DIR/curl.log" >/dev/null &&
	grep -F -- '--tlsv1.2' "$CASE_DIR/curl.log" >/dev/null; then
	pass
fi

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

begin_test 'fetches the CLI version pointer once and uses immutable assets'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_CLI_VERSION_URL=$CLI_VERSION_URL
export ASHDROP_RELEASES_BASE_URL ASHDROP_CLI_VERSION_URL
: >"$REQUEST_LOG"
run_installer --install-dir "$CASE_DIR/install"
pointer_count=$(grep -c '^/pointer/version$' "$REQUEST_LOG" || true)
if expect_status 0 && [ "$pointer_count" -eq 1 ] && ! grep -F '/releases/latest' "$REQUEST_LOG" >/dev/null &&
	grep -F '/releases/download/cli-v1.2.3/ashdrop-v1.2.3-linux-x86_64.tar.gz' "$REQUEST_LOG" >/dev/null &&
	grep -F '/releases/download/cli-v1.2.3/SHA256SUMS' "$REQUEST_LOG" >/dev/null; then
	pass
else
	ensure_failure "$TEST_NAME: expected one pointer request and immutable asset requests"
fi

for pointer_case in \
	'malformed malformed' \
	'oversized fetch' \
	'extra malformed' \
	'no-response malformed' \
	'no-newline malformed' \
	'leading-zero malformed' \
	'whitespace malformed'
do
	set -- $pointer_case
	begin_test "rejects $1 CLI version pointer response"
	rm "$CASE_DIR/bin/curl"
	ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
	ASHDROP_CLI_VERSION_URL=http://127.0.0.1:$PORT/pointer/$1
	export ASHDROP_RELEASES_BASE_URL ASHDROP_CLI_VERSION_URL
	run_installer --install-dir "$CASE_DIR/install"
	if expect_failure && expect_stderr "$2"; then
		pass
	fi
done

begin_test 'rejects non-loopback HTTP CLI version pointer override'
ASHDROP_CLI_VERSION_URL=http://example.com/cli-version
export ASHDROP_CLI_VERSION_URL
run_installer --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'pointer override must use a loopback host' &&
	[ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

begin_test 'rejects disguised non-loopback HTTP CLI version pointer override'
ASHDROP_CLI_VERSION_URL=http://127.0.0.1:80@evil.example/cli-version
export ASHDROP_CLI_VERSION_URL
run_installer --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'pointer override must use a loopback host' &&
	[ ! -e "$CASE_DIR/curl.log" ]; then
	pass
fi

begin_test 'pinned version bypasses pointer and latest lookup'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_CLI_VERSION_URL=$CLI_VERSION_URL
export ASHDROP_RELEASES_BASE_URL ASHDROP_CLI_VERSION_URL
: >"$REQUEST_LOG"
run_installer --version 1.1.0 --install-dir "$CASE_DIR/install"
if expect_status 0 && ! grep -F '/pointer/' "$REQUEST_LOG" >/dev/null &&
	! grep -F '/releases/latest' "$REQUEST_LOG" >/dev/null &&
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

begin_test 'selects sha256sum before other digest tools'
isolate_installer_path
add_digest_tool sha256sum
add_digest_tool shasum
add_digest_tool openssl
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_status 0 && [ "$(grep -c '^sha256sum$' "$CASE_DIR/digest-tools.log")" -eq 2 ] &&
	[ "$(wc -l <"$CASE_DIR/digest-tools.log")" -eq 2 ]; then
	pass
fi

begin_test 'falls back to shasum when sha256sum is unavailable'
isolate_installer_path
add_digest_tool shasum
add_digest_tool openssl
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_status 0 && [ "$(grep -c '^shasum$' "$CASE_DIR/digest-tools.log")" -eq 2 ] &&
	[ "$(wc -l <"$CASE_DIR/digest-tools.log")" -eq 2 ]; then
	pass
fi

begin_test 'falls back to openssl when sum tools are unavailable'
isolate_installer_path
add_digest_tool openssl
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_status 0 && [ "$(grep -c '^openssl$' "$CASE_DIR/digest-tools.log")" -eq 2 ] &&
	[ "$(wc -l <"$CASE_DIR/digest-tools.log")" -eq 2 ]; then
	pass
fi

begin_test 'fails when no SHA-256 utility is available'
isolate_installer_path
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'required SHA-256 tool' && [ ! -e "$CASE_DIR/install/ashdrop" ]; then
	pass
fi

begin_test 'rejects digest output from a failing SHA-256 utility'
isolate_installer_path
add_digest_tool sha256sum-fail
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'SHA-256 calculation failed' &&
	[ ! -e "$CASE_DIR/install/ashdrop" ]; then
	pass
fi

begin_test 'rejects digest output from a failing shasum utility'
isolate_installer_path
add_digest_tool shasum-fail
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
run_installer --version 1.2.3 --install-dir "$CASE_DIR/install"
if expect_failure && expect_stderr 'SHA-256 calculation failed' &&
	[ ! -e "$CASE_DIR/install/ashdrop" ]; then
	pass
fi

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
set -- "$TMPDIR"/ashdrop-install.*
if expect_failure && expect_stderr 'checksum mismatch' &&
	[ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ] &&
	[ ! -s "$CASE_DIR/stdout" ] && [ ! -e "$1" ]; then
	pass
else
	ensure_failure "$TEST_NAME: existing binary or success output changed"
fi

begin_test 'download failure cleans temporary files and preserves destination'
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
set -- "$TMPDIR"/ashdrop-install.*
if expect_failure && expect_stderr 'failed to download' &&
	[ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ] && [ ! -e "$1" ]; then
	pass
fi

begin_test 'copy failure removes pending file and preserves destination'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/cp" <<'EOF'
#!/bin/sh
exit 93
EOF
chmod +x "$CASE_DIR/bin/cp"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
set -- "$CASE_DIR/custom-bin"/.ashdrop.*
pending_path=$1
set -- "$TMPDIR"/ashdrop-install.*
if expect_failure && expect_stderr 'could not copy' && [ ! -e "$pending_path" ] &&
	[ ! -e "$1" ] && [ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ]; then
	pass
fi

begin_test 'chmod failure removes pending file and preserves destination'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/chmod" <<'EOF'
#!/bin/sh
exit 95
EOF
"$REAL_CHMOD" +x "$CASE_DIR/bin/chmod"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
set -- "$CASE_DIR/custom-bin"/.ashdrop.*
pending_path=$1
set -- "$TMPDIR"/ashdrop-install.*
if expect_failure && expect_stderr 'could not set executable permissions' &&
	[ ! -e "$pending_path" ] && [ ! -e "$1" ] &&
	[ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ] &&
	[ ! -s "$CASE_DIR/stdout" ]; then
	pass
fi

begin_test 'move failure removes pending file and preserves destination'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/mv" <<'EOF'
#!/bin/sh
exit 94
EOF
chmod +x "$CASE_DIR/bin/mv"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
export ASHDROP_RELEASES_BASE_URL
mkdir "$CASE_DIR/custom-bin"
printf 'sentinel\n' >"$CASE_DIR/custom-bin/ashdrop"
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
set -- "$CASE_DIR/custom-bin"/.ashdrop.*
pending_path=$1
set -- "$TMPDIR"/ashdrop-install.*
if expect_failure && expect_stderr 'atomically replace' && [ ! -e "$pending_path" ] &&
	[ ! -e "$1" ] && [ "$(cat "$CASE_DIR/custom-bin/ashdrop")" = sentinel ]; then
	pass
fi

begin_test 'never executes the downloaded binary'
rm "$CASE_DIR/bin/curl"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_EXECUTION_MARKER=$CASE_DIR/executed
export ASHDROP_RELEASES_BASE_URL ASHDROP_EXECUTION_MARKER
run_installer --version 1.2.3 --install-dir "$CASE_DIR/custom-bin"
if expect_status 0 && [ ! -e "$ASHDROP_EXECUTION_MARKER" ]; then
	pass
fi

begin_test 'atomically replaces through a destination-adjacent temporary file'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/mv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/mv.log"
exec "$REAL_MV" "$@"
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

begin_test 'system install rejects a source swapped before privileged copy'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf 'tampered\n' >"$5"
exec "$@"
EOF
chmod +x "$CASE_DIR/bin/sudo"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_SYSTEM_INSTALL_DIR=$CASE_DIR/system-bin
export ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR
mkdir "$ASHDROP_SYSTEM_INSTALL_DIR"
printf 'sentinel\n' >"$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop"
run_installer --version 1.2.3 --system
set -- "$ASHDROP_SYSTEM_INSTALL_DIR"/.ashdrop.*
if expect_failure && expect_stderr 'verified binary changed before system installation' &&
	[ "$(cat "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop")" = sentinel ] && [ ! -e "$1" ]; then
	pass
fi

begin_test 'system privileged rehash falls back to shasum'
rm "$CASE_DIR/bin/curl"
ROOT_TOOLS=$CASE_DIR/root-tools
mkdir "$ROOT_TOOLS"
ln -s "$REAL_CHMOD" "$ROOT_TOOLS/chmod"
ln -s "$REAL_CP" "$ROOT_TOOLS/cp"
ln -s "$REAL_MKTEMP" "$ROOT_TOOLS/mktemp"
ln -s "$REAL_MV" "$ROOT_TOOLS/mv"
ln -s "$REAL_RM" "$ROOT_TOOLS/rm"
cat >"$ROOT_TOOLS/shasum" <<'EOF'
#!/bin/sh
[ "$1" = -a ] && [ "$2" = 256 ] || exit 97
file=$3
digest=$("$PYTHON3" - "$file" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
) || exit 98
printf 'shasum\n' >>"$CASE_DIR/root-digest.log"
printf '%s  %s\n' "$digest" "$file"
EOF
cat >"$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/sh
modified_script=$("$PYTHON3" - "$3" "$ROOT_TOOLS" <<'PY'
import shlex
import sys
script, root = sys.argv[1:]
for line in script.splitlines():
    if line.strip().startswith("PATH="):
        print("\t\tPATH=" + shlex.quote(root))
    else:
        print(line)
PY
) || exit 96
shift 3
exec "$POSIX_SH" -c "$modified_script" "$@"
EOF
"$REAL_CHMOD" +x "$ROOT_TOOLS/shasum" "$CASE_DIR/bin/sudo"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
ASHDROP_SYSTEM_INSTALL_DIR=$CASE_DIR/system-bin
export ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR ROOT_TOOLS
mkdir "$ASHDROP_SYSTEM_INSTALL_DIR"
run_installer --version 1.2.3 --system
if expect_status 0 && [ "$(cat "$CASE_DIR/root-digest.log")" = shasum ] &&
	[ -x "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop" ]; then
	pass
fi

begin_test 'rejects a symlink system install directory before sudo'
rm "$CASE_DIR/bin/curl"
cat >"$CASE_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$CASE_DIR/sudo.log"
exit 99
EOF
chmod +x "$CASE_DIR/bin/sudo"
ASHDROP_RELEASES_BASE_URL=$RELEASES_BASE
mkdir "$CASE_DIR/real-system-bin"
ln -s "$CASE_DIR/real-system-bin" "$CASE_DIR/link-system-bin"
ASHDROP_SYSTEM_INSTALL_DIR=$CASE_DIR/link-system-bin
export ASHDROP_RELEASES_BASE_URL ASHDROP_SYSTEM_INSTALL_DIR
run_installer --version 1.2.3 --system
if expect_failure && expect_stderr 'symlink' && [ ! -e "$CASE_DIR/sudo.log" ] &&
	[ ! -e "$CASE_DIR/real-system-bin/ashdrop" ]; then
	pass
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
if expect_failure && expect_stderr 'checksum mismatch' && [ ! -e "$CASE_DIR/sudo.log" ] &&
	[ "$(cat "$ASHDROP_SYSTEM_INSTALL_DIR/ashdrop")" = sentinel ]; then
	pass
else
	ensure_failure "$TEST_NAME: sudo ran or destination changed before verification"
fi

finish_test
printf '%s tests, %s assertions, %s failures\n' "$tests" "$assertions" "$failures"
[ "$assertions" -eq "$tests" ]
[ "$failures" -eq 0 ]
