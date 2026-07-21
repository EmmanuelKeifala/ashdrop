# Ashdrop CLI Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish verified Linux x86_64 and ARM64 Ashdrop CLI binaries from `cli-v*` tags and provide a safe first-party shell installer.

**Architecture:** Zig build options inject the CLI version into one executable. A tag-triggered GitHub Actions job validates the package version, builds and smoke-tests both Linux targets, packages immutable archives, creates checksums and OIDC attestations, then publishes a GitHub Release. A POSIX installer served by the web app resolves a stable version, verifies the matching release archive, validates its contents, and performs an atomic user or system installation.

**Tech Stack:** Zig 0.16, POSIX shell, Python 3 fixture server, GitHub Actions, GitHub artifact attestations, SvelteKit static assets.

---

## File Structure

- Modify `ashdrop/cli/build.zig`: define the development/release version build option and expose it to executable and tests.
- Modify `ashdrop/cli/src/main.zig`: implement and test `ashdrop --version` before `HOME` resolution.
- Create `ashdrop/cli/scripts/release-version.sh`: validate `cli-vX.Y.Z` and package-version equality for CI.
- Create `ashdrop/cli/tests/release_version_test.sh`: exercise accepted and rejected release tags without publishing.
- Create `ashdrop/web/static/install.sh`: perform version resolution, verification, archive validation, and atomic installation.
- Create `ashdrop/web/tests/install_test.sh`: build local release fixtures and test installer behavior without external traffic or root.
- Modify `ashdrop/web/package.json`: expose installer tests through the existing package scripts.
- Create `.github/workflows/cli-release.yml`: build, attest, and publish tagged releases.
- Modify `ashdrop/cli/README.md`: document installation, verification, supported platforms, and source builds.

### Task 1: CLI Version Injection

**Files:**
- Modify: `ashdrop/cli/src/main.zig`
- Modify: `ashdrop/cli/build.zig`

- [ ] **Step 1: Add failing dispatch tests**

Append tests in `src/main.zig` that call `runCommand` with `--version`, require stdout to equal `ashdrop <build_options.version>\n`, require empty stderr and status 0, and require `--version extra` to return usage status 2.

```zig
test "--version prints the injected version on stdout" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = std.Io.Dir.cwd(),
        .home = "unused",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const args = [_][]const u8{"--version"};
    try std.testing.expectEqual(@as(u8, 0), runCommand(&args, runtime));
    const expected = try std.fmt.allocPrint(std.testing.allocator, "ashdrop {s}\n", .{build_options.version});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, stdout.written());
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
}
```

- [ ] **Step 2: Run the test and confirm the red state**

Run: `zig build test`

Expected: FAIL because `build_options` and version dispatch do not exist.

- [ ] **Step 3: Expose the Zig build option**

In `build.zig`, define package version `0.1.0`, default to `0.1.0-dev`, validate `-Dversion` with `std.SemanticVersion.parse`, and attach a generated `build_options` module to both the executable and test root modules:

```zig
const package_version = "0.1.0";
const version = b.option([]const u8, "version", "Semantic version reported by ashdrop --version") orelse package_version ++ "-dev";
_ = std.SemanticVersion.parse(version) catch @panic("-Dversion must be a valid semantic version");
const build_options = b.addOptions();
build_options.addOption([]const u8, "version", version);
exe_module.addOptions("build_options", build_options);
test_module.addOptions("build_options", build_options);
```

- [ ] **Step 4: Implement version dispatch**

Import `build_options`, add a `runVersion` helper, call it from `runCommand`, and call it from `main` before reading `HOME`:

```zig
const build_options = @import("build_options");

fn runVersion(args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) ?u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "--version")) return null;
    if (args.len != 1) return writeFailure(stderr, error.Usage);
    stdout.print("ashdrop {s}\n", .{build_options.version}) catch return writeFailure(stderr, error.CommandFailed);
    return 0;
}
```

- [ ] **Step 5: Verify default and injected versions**

Run:

```sh
zig build test
zig build test -Dversion=1.2.3
zig build
test "$(env -u HOME ./zig-out/bin/ashdrop --version)" = "ashdrop 0.1.0-dev"
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit the version feature**

```sh
git add ashdrop/cli/build.zig ashdrop/cli/src/main.zig
git commit -m "feat(cli): report build version"
```

### Task 2: Release Tag Validation

**Files:**
- Create: `ashdrop/cli/scripts/release-version.sh`
- Create: `ashdrop/cli/tests/release_version_test.sh`

- [ ] **Step 1: Write failing shell tests**

Create a harness that copies `build.zig.zon`, invokes the validator, and asserts:

```sh
assert_ok "0.1.0" cli-v0.1.0 "$zon"
assert_fail v0.1.0 "$zon"
assert_fail cli-v0.1.1 "$zon"
assert_fail cli-v01.1.0 "$zon"
assert_fail cli-v0.1.0-rc.1 "$zon"
```

- [ ] **Step 2: Confirm tests fail because the validator is absent**

Run: `sh ashdrop/cli/tests/release_version_test.sh`

Expected: FAIL with the validator path not found.

- [ ] **Step 3: Implement strict tag/package validation**

The validator accepts a tag and optional zon path, validates `cli-vMAJOR.MINOR.PATCH` with no leading zeros, extracts the single `.version = "..."` value from `build.zig.zon`, requires equality, and prints only the normalized version. It must use `set -eu`, quote paths, and exit nonzero with focused diagnostics for malformed tags, missing versions, duplicate versions, and mismatches.

- [ ] **Step 4: Run validation tests**

Run:

```sh
sh -n ashdrop/cli/scripts/release-version.sh
sh -n ashdrop/cli/tests/release_version_test.sh
sh ashdrop/cli/tests/release_version_test.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit tag validation**

```sh
git add ashdrop/cli/scripts/release-version.sh ashdrop/cli/tests/release_version_test.sh
git commit -m "build(cli): validate release tags"
```

### Task 3: Verified Installer

**Files:**
- Create: `ashdrop/web/static/install.sh`
- Create: `ashdrop/web/tests/install_test.sh`
- Modify: `ashdrop/web/package.json`

- [ ] **Step 1: Create failing installer argument and platform tests**

The test harness creates isolated `HOME`, `TMPDIR`, `PATH`, and output files per case. Add initial tests for `--help`, unknown arguments, `--system --install-dir`, unsupported OS/architecture, and normalization of `x86_64`, `amd64`, `aarch64`, and `arm64` through fake `uname` commands.

- [ ] **Step 2: Confirm the harness fails because the installer is absent**

Run: `sh ashdrop/web/tests/install_test.sh`

Expected: FAIL because `ashdrop/web/static/install.sh` does not exist.

- [ ] **Step 3: Implement argument parsing, platform mapping, and temporary cleanup**

Create a POSIX `sh` script with `set -eu`, `umask 077`, cleanup traps, and these public options:

```text
--version X.Y.Z
--install-dir PATH
--system
--help
```

Default the destination to `${XDG_BIN_HOME:-$HOME/.local/bin}`. Reject prereleases, leading-zero components, empty values, repeated values, unknown arguments, and `--system` combined with `--install-dir`.

- [ ] **Step 4: Add failing release-resolution tests**

Extend the harness with a loopback Python server. `/releases/latest` redirects to `/releases/tag/cli-v1.2.3`; tagged asset paths serve generated fixtures. Assert latest resolution requests `/latest` exactly once and pinned `--version 1.1.0` never requests `/latest`.

- [ ] **Step 5: Implement release resolution and HTTPS download policy**

Use `https://github.com/abdullah4tech/ashdrop/releases` by default. Resolve latest through curl's `%{url_effective}`, require a final `cli-vX.Y.Z` tag, then use only version-specific download URLs. Permit loopback HTTP only when the undocumented `ASHDROP_RELEASES_BASE_URL` test seam is set; production curl calls must enforce `--proto '=https' --proto-redir '=https' --tlsv1.2`.

- [ ] **Step 6: Add failing checksum and archive-safety tests**

Generate valid and malicious tarballs with Python `tarfile`. Cover digest mismatch, missing/duplicate manifest entries, absolute paths, `../` traversal, symlinks, hard links, extra entries, and a non-executable `ashdrop`. Every malicious archive except checksum cases receives a valid checksum so archive validation is exercised.

- [ ] **Step 7: Implement checksum and archive verification**

Require exactly one manifest line for the expected archive and one 64-character hexadecimal digest. Calculate SHA-256 using `sha256sum`, `shasum -a 256`, or `openssl dgst -sha256`. Before extraction, require `tar -tzf` to list exactly `ashdrop` and `tar -tvzf` to identify exactly one regular file. Extract into a private directory and require a regular, non-symlink executable.

- [ ] **Step 8: Add failing atomic user/system installation tests**

Assert default, XDG, and custom installs land at the expected path with mode `0755`; validation failures preserve an existing sentinel binary; successful replacement uses a destination-adjacent temporary file. Use a fake sudo wrapper and temporary system directory to assert `--system` elevates exactly once and only after all downloads and verification.

- [ ] **Step 9: Implement atomic installation**

For user installs, reject a symlink destination directory, create a pending file with `mktemp "$install_dir/.ashdrop.XXXXXX"`, copy, chmod, then `mv -f` over the destination. For `--system`, pass the verified source and fixed destination to one quoted `sudo sh -c` operation that creates the pending file and performs only copy, chmod, and rename.

- [ ] **Step 10: Expose and run installer tests**

Add to `ashdrop/web/package.json`:

```json
"test:installer": "sh tests/install_test.sh"
```

Run:

```sh
sh -n ashdrop/web/static/install.sh
sh -n ashdrop/web/tests/install_test.sh
pnpm run test:installer
pnpm run check
```

If `shellcheck` is installed, also run `shellcheck -s sh` on both scripts. Expected: all available checks pass and no test contacts a non-loopback address.

- [ ] **Step 11: Commit the installer**

```sh
git add ashdrop/web/static/install.sh ashdrop/web/tests/install_test.sh ashdrop/web/package.json
git commit -m "feat(cli): add verified installer"
```

### Task 4: Tag-Triggered Release Workflow

**Files:**
- Create: `.github/workflows/cli-release.yml`

- [ ] **Step 1: Add a workflow with a deliberately failing version check**

Create the `cli-v*` tag trigger and call `ashdrop/cli/scripts/release-version.sh "$GITHUB_REF_NAME"`. Test the same command locally with an invalid tag to establish the failure path:

```sh
! sh ashdrop/cli/scripts/release-version.sh cli-v9.9.9 ashdrop/cli/build.zig.zon
```

- [ ] **Step 2: Implement the complete release job**

Use Ubuntu, default read-only permissions, and grant only `contents: write`, `id-token: write`, and `attestations: write` to the release job. Pin every action to a full commit SHA. Steps must:

```sh
zig build test -Dversion="$VERSION"
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion="$VERSION" --prefix zig-out/release/linux-x86_64
zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion="$VERSION" --prefix zig-out/release/linux-aarch64
```

Then natively smoke-test x86_64, QEMU smoke-test ARM64, package one `ashdrop` member per archive with normalized tar metadata, generate `SHA256SUMS`, attest both final archives, and run `gh release create "$GITHUB_REF_NAME"` with all three assets. Refuse to overwrite an existing release.

- [ ] **Step 3: Validate workflow syntax and local build commands**

Run:

```sh
ruby -e "require 'yaml'; YAML.parse_file('.github/workflows/cli-release.yml')"
sh ashdrop/cli/tests/release_version_test.sh
zig build test -Dversion=0.1.0
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion=0.1.0 --prefix zig-out/release/linux-x86_64
zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion=0.1.0 --prefix zig-out/release/linux-aarch64
```

Expected: YAML parses, tests pass, and both binaries are produced.

- [ ] **Step 4: Commit the release workflow**

```sh
git add .github/workflows/cli-release.yml
git commit -m "ci: publish attested CLI releases"
```

### Task 5: Installation And Verification Documentation

**Files:**
- Modify: `ashdrop/cli/README.md`

- [ ] **Step 1: Add a documentation acceptance check**

Before editing, verify the required content is absent:

```sh
! grep -q "ashdrop.vercel.app/install.sh" ashdrop/cli/README.md
! grep -q "gh attestation verify" ashdrop/cli/README.md
```

- [ ] **Step 2: Rewrite the opening installation sections**

Lead with:

```sh
curl -fsSL https://ashdrop.vercel.app/install.sh | sh
curl -fsSL https://ashdrop.vercel.app/install.sh | sh -s -- --version 0.1.0
curl -fsSL https://ashdrop.vercel.app/install.sh | sh -s -- --system
```

Document Linux x86_64/ARM64 support, default and system destinations, PATH behavior, SHA-256 integrity semantics, manual GitHub attestation verification, rollback through `--version`, and source builds. Explicitly state that checksum verification is not an independent publisher signature.

- [ ] **Step 3: Verify all required documentation is present**

Run:

```sh
grep -q "ashdrop.vercel.app/install.sh" ashdrop/cli/README.md
grep -q "gh attestation verify" ashdrop/cli/README.md
grep -q "Linux x86_64" ashdrop/cli/README.md
grep -q -- "--system" ashdrop/cli/README.md
grep -q "Zig 0.16.0" ashdrop/cli/README.md
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit documentation**

```sh
git add ashdrop/cli/README.md
git commit -m "docs(cli): document binary installation"
```

### Task 6: End-To-End Verification And Fork Branch

**Files:**
- Verify all files changed by Tasks 1-5.

- [ ] **Step 1: Run the complete local verification suite**

```sh
(cd ashdrop/cli && zig build test)
(cd ashdrop/api && go test ./...)
(cd ashdrop/web && pnpm run test:installer && pnpm run check && pnpm run build)
sh ashdrop/cli/tests/release_version_test.sh
git diff --check origin/main...
```

Expected: every command exits 0.

- [ ] **Step 2: Inspect release artifacts**

Build both release targets, package them using the workflow commands, verify `SHA256SUMS`, require each archive to list only `ashdrop`, and smoke-test the native x86_64 binary with `HOME` unset.

- [ ] **Step 3: Review branch scope**

Run:

```sh
git status --short
git log --oneline origin/main..
git diff --stat origin/main...
git diff origin/main... -- . ':!docs/superpowers'
```

Expected: only the release design, plan, version support, release scripts/workflow, installer/tests, and CLI documentation are changed.

- [ ] **Step 4: Push the new branch to Emmanuel's fork**

```sh
git push -u fork release/cli-distribution
```

Expected: `EmmanuelKeifala/ashdrop` contains the new branch based on upstream `main`. Do not create the upstream pull request until branch checks and a final code review complete.
