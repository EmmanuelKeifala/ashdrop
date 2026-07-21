# Ashdrop CLI Release Design

## Goal

Ship installable, versioned Ashdrop CLI binaries from the upstream repository instead of asking users to build the CLI from source. The first release supports Linux x86_64 and ARM64, provides integrity checks and GitHub OIDC provenance, and can be installed without running an entire downloaded script as root.

## Scope

The first release includes:

- Linux x86_64 and ARM64 binaries built with Zig 0.16.0 in `ReleaseSafe` mode.
- Versioned GitHub Release archives triggered by `cli-v*` tags.
- SHA-256 checksums for automatic installer verification.
- GitHub artifact attestations tied to the upstream Ashdrop release workflow.
- A POSIX shell installer served from the Ashdrop web application's static files.
- User-local installation by default and an explicit system-install mode.
- CLI version output, release documentation, and automated release and installer tests.

The first release does not include macOS, Windows, package-manager repositories, automatic updates, or a long-lived signing key.

## Repository And Branch Model

Development starts from `abdullah4tech/ashdrop` `main`, not from the fork's stale and diverged `main`. Work is pushed as a new branch to `EmmanuelKeifala/ashdrop` and proposed upstream through a pull request.

Only a workflow running in `abdullah4tech/ashdrop` can issue official Ashdrop release provenance. Workflow runs in the fork validate the implementation but do not constitute official releases.

## Release Trigger And Versioning

An annotated or lightweight tag matching `cli-v<semver>`, for example `cli-v0.1.0`, triggers the release workflow. Before building, the workflow verifies that:

- The tag uses the required `cli-v` prefix and a valid semantic version.
- The tag version equals the version in `ashdrop/cli/build.zig.zon`.
- The tagged commit passes the CLI test suite.

The CLI exposes `ashdrop --version`, with the release version injected by the Zig build. Development builds use the package version with a development suffix so they cannot be mistaken for tagged release artifacts.

Official tags should be protected in the upstream repository. Tag protection and immutable-release settings are repository administration tasks and are documented separately from the pull request's code changes.

## Build And Packaging

The workflow pins Zig to exactly 0.16.0 and builds with `ReleaseSafe` optimization and baseline CPU features. It produces:

```text
ashdrop-v0.1.0-linux-x86_64.tar.gz
ashdrop-v0.1.0-linux-aarch64.tar.gz
SHA256SUMS
```

Each archive contains one executable named `ashdrop`. Archive paths are fixed and traversal-free. Packaging uses stable ordering and normalized metadata where the available tooling permits it.

The x86_64 binary is smoke-tested natively. The ARM64 binary is smoke-tested through QEMU by executing `ashdrop --version`. Cross-compilation alone is not considered sufficient validation.

## Release Workflow

The release workflow has distinct validation, build, package, and publish responsibilities:

1. Validate the tag and package version.
2. Run `zig build test` on Linux x86_64.
3. Build and smoke-test both target binaries.
4. Package the final binaries and generate `SHA256SUMS` over the final archives.
5. Generate GitHub artifact attestations for each final archive.
6. Publish the archives and checksum manifest in an immutable GitHub Release.

The publishing job receives only the permissions it requires: `contents: write`, `id-token: write`, and `attestations: write`. Other jobs remain read-only. Third-party GitHub Actions are pinned to full commit SHAs.

## Trust Model

The installer automatically verifies that the selected archive's SHA-256 digest matches `SHA256SUMS` from the same immutable, version-specific GitHub Release. This detects corruption, incomplete downloads, and mismatched release assets. It does not independently authenticate the publisher if the release origin is compromised, and documentation must not call a checksum a signature.

Each final archive also receives a keyless GitHub artifact attestation using the release workflow's OIDC identity. Users who need independent publisher and build-provenance verification can run:

```sh
gh attestation verify ashdrop-v0.1.0-linux-x86_64.tar.gz \
  --repo abdullah4tech/ashdrop
```

The installer does not download and trust a signature verifier from the same release origin. A stable Minisign key is deferred until Ashdrop has an offline or hardware-backed key-custody and rotation process.

## Installer Interface

The installer is committed at `ashdrop/web/static/install.sh` and is expected to be served from the deployed Ashdrop web origin, for example:

```sh
curl -fsSL https://ashdrop.vercel.app/install.sh | sh
```

Supported arguments are:

```text
--version <version>     Install a specific stable version.
--install-dir <path>   Install into an explicit user-writable directory.
--system               Install into /usr/local/bin using sudo only for the final copy.
--help                 Print usage without modifying the system.
```

The default destination is `${XDG_BIN_HOME:-$HOME/.local/bin}`. The installer never invokes `sudo` during network access, checksum verification, or extraction. `--system` performs all preparation as the current user and elevates only the final atomic installation into `/usr/local/bin`.

For deterministic testing, an undocumented environment override may replace the GitHub Releases base URL. The override is intended only for the test harness and is not presented as a user-facing endpoint feature.

## Installer Flow

The installer performs these steps in order:

1. Parse arguments and reject unknown or conflicting options.
2. Require Linux and map `x86_64` or `amd64` to `x86_64`, and `aarch64` or `arm64` to `aarch64`.
3. Resolve the latest stable release once, or normalize an explicit version, then use only version-specific asset URLs.
4. Create a private temporary directory under `umask 077` and register cleanup traps.
5. Download the selected archive and `SHA256SUMS` with HTTPS-only curl options.
6. Locate exactly one checksum entry matching the expected archive name and verify it with an available SHA-256 utility.
7. Validate that the archive contains only the expected executable path and no absolute paths, parent traversal, links, or extra entries.
8. Extract as the current user and verify the result is a regular executable file.
9. Create the destination directory when safe and install atomically with mode `0755`.
10. Print the installed version and a PATH hint when the destination is not currently discoverable.

The installer never executes the downloaded binary before checksum and archive validation. Existing installations are replaced only after all verification succeeds.

## Failure Handling

The installer exits nonzero with a focused diagnostic for unsupported platforms, missing tools, release lookup failures, failed downloads, missing checksum entries, digest mismatches, unsafe archives, permission failures, and installation failures. Temporary files are removed on normal exit and handled signals.

Release publication is fail-closed. A failed test, build, smoke test, packaging step, checksum generation, or attestation prevents GitHub Release creation. Rerunning the workflow for an existing immutable release does not overwrite published artifacts.

## Testing

Automated coverage includes:

- Unit coverage for CLI `--version` parsing and output.
- Tag-to-package-version validation.
- Existing `zig build test` coverage.
- `ReleaseSafe` builds for Linux x86_64 and ARM64.
- Native x86_64 and QEMU ARM64 `--version` smoke tests.
- Shell syntax and static analysis for the installer.
- Installer platform and architecture mapping.
- Explicit version selection and latest stable version resolution.
- Default user destination, custom destination, and system-install command construction.
- Checksum mismatch and missing checksum rejection.
- Absolute path, parent traversal, link, and unexpected archive entry rejection.
- End-to-end installation against a local fixture server without live GitHub dependencies.

## Documentation And Launch

`ashdrop/cli/README.md` will lead with binary installation, then document pinned installation, system installation, checksum behavior, GitHub attestation verification, supported platforms, and source builds.

The landing-page CLI announcement should point to installation instructions only after the upstream repository has merged the release workflow and published the first official release. Until then, source-only links should be labeled as source builds rather than installations.

## Acceptance Criteria

- A `cli-v0.1.0` tag matching the package version can produce both Linux archives, `SHA256SUMS`, attestations, and a GitHub Release from the upstream repository.
- Both release binaries report the tagged version.
- The installer installs a verified x86_64 or ARM64 artifact into a user-local directory without root.
- `--system` uses privilege escalation only for the final installation operation.
- A checksum mismatch or unsafe archive leaves any existing binary untouched.
- Release and installer behavior can be tested without publishing a real release.
- Documentation distinguishes checksum integrity from OIDC-backed provenance.
