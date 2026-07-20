# Ashdrop CLI

`ashdrop` encrypts an environment file for a recipient's local receive
identity, stores the encrypted drop through the Ashdrop API, and writes a
received file locally. It does not print environment-file plaintext.

## Build

Run these commands from `ashdrop/cli`. `build.zig.zon` declares stable Zig
`0.16.0` as the minimum and verified version; it does not enforce an exact
toolchain pin.

```sh
# Development build; installs ./zig-out/bin/ashdrop
zig build

# Run without separately invoking the installed executable
zig build run -- address create

# Unit tests
zig build test

# Release-safe build; installs ./zig-out/bin/ashdrop
zig build -Doptimize=ReleaseSafe
```

## Receive Identity and Address

Create a local recipient identity once:

```sh
./zig-out/bin/ashdrop address create
```

This creates `~/.config/ashdrop/identity.json`, with its directory set to mode
`0700` and the identity file set to mode `0600`. The command will not replace
an existing identity. It prints a shareable receive address.

```sh
# Print the existing shareable receive address
./zig-out/bin/ashdrop address

# Print only the base64url P-256 public key
./zig-out/bin/ashdrop address --raw
```

The identity file contains the private key needed to decrypt drops. The CLI has
no private-key export command. Browser and CLI identities are separate; there
is no automatic identity transfer between them.

## Inbox

```sh
./zig-out/bin/ashdrop inbox [--limit <n>] [--api <url>]
```

`inbox` lists up to 20 pending recipient-keyed drops by default. `--limit`
accepts a decimal value from `1` through `100`. Its output contains only the
drop `ID`, `expiresAt`, and `viewsLeft`; it never fetches or prints plaintext.
Use a listed ID with `pull` to receive a drop:

```sh
./zig-out/bin/ashdrop pull <id>
```

The receive address is public and safe to hand to senders. Listing its pending
drops is private: the CLI loads the local receive identity, obtains the API's
public inbox key, and derives an authenticated listing proof through P-256
ECDH, HKDF, and HMAC. The API generates and persists its own inbox key; the
CLI never uploads the recipient private key.

Inbox proofs require HTTPS for non-loopback API endpoints. `http://localhost`,
any `http://127.x.x.x` address, and `http://[::1]` are allowed for local
development.

## Share

```sh
./zig-out/bin/ashdrop share --to <receive-address> --file .env \
  [--ttl 1h|24h|7d] [--views <n>] [--api <url>] [--web <url>]
```

`--to` accepts a receive URL, the raw public key from `address --raw`, or an
Ashdrop receive URI. `--file` must name a UTF-8 file no larger than 64 KiB.
The default TTL is `24h`; valid TTL values are `1h`, `24h`, and `7d`. The
default view limit is `1`. `--views` accepts a non-negative decimal value;
`0` is unlimited in the current API.

The command encrypts the file for the recipient and prints only the resulting
drop reference. It never prints the source plaintext.

## Pull

```sh
./zig-out/bin/ashdrop pull <drop-reference> \
  [-o <path>|--output <path>] [--force] [--api <url>]
```

Standalone smoke example:

```sh
./zig-out/bin/ashdrop pull <drop-url> -o .env.ashdrop
```

`<drop-reference>` may be a drop URL, a 32-character drop ID, or an Ashdrop
drop URI. The default output is `.env.ashdrop`. Existing files are refused
unless `--force` is supplied. The output path and its parent directories must
not be symlinks, a directory cannot be used as the output, and the plaintext is
atomically written with mode `0600`. The destination is reserved before any
metadata or open request, so unsafe or existing output paths do not consume a
drop view.

Pull requires the local `~/.config/ashdrop/identity.json`. Before opening a
drop, the CLI checks its recipient public key against that identity. A drop for
a different identity is not opened. The metadata request does not consume a
view; an API `open` request does. Consequently, with the default one-view
limit, the first permitted `open` burns the server-side ciphertext even if a
later local decrypt or file write fails. Plaintext is written only to the
output file and is never printed to stdout or stderr.

## Managed and Self-Hosted Endpoints

The managed defaults are:

```text
API: https://ashdrop.onrender.com
Web: https://ashdrop.vercel.app
```

`address` and `share` accept `--api` and `--web`. `pull` and `inbox` accept
`--api`.
`ASHDROP_API_URL` provides the API endpoint for all network commands,
including `share`, `pull`, and `inbox` (and is also used when `address` formats
a self-hosted receive reference). `ASHDROP_WEB_URL` affects only the human URLs
emitted by `address` and `share`; `pull` and `inbox` do not use it. An explicit
`--api` takes precedence over an API embedded in an Ashdrop URI, which takes
precedence over `ASHDROP_API_URL`; otherwise the managed API is used. `--web`
takes precedence over `ASHDROP_WEB_URL`; otherwise links using the managed API
use the managed web URL.

For a custom API without a configured web URL, `address` and `share` print
self-contained Ashdrop URIs instead of web URLs:

```text
ashdrop://receive/<public-key>?api=<percent-encoded-api-url>
ashdrop://drop/<drop-id>?api=<percent-encoded-api-url>
```

These URIs preserve the API endpoint when passed to `share --to` or `pull`.
To use a local API and web application directly:

```sh
ASHDROP_API_URL=http://127.0.0.1:8080 \
ASHDROP_WEB_URL=http://127.0.0.1:5173 \
./zig-out/bin/ashdrop address create
```

Use `--api` for a per-command API override. `--web` is available only on
`address` and `share`.
