// Generate with: node ashdrop/cli/testdata/generate-protocol-v1.mjs > ashdrop/cli/testdata/protocol-v1.json
// This uses Node.js Web Crypto via node:crypto webcrypto.subtle.
import { webcrypto } from "node:crypto";

const { subtle } = webcrypto;
const text = new TextEncoder();
const b64url = (value) => Buffer.from(value).toString("base64url");

const recipientPrivateJwk = {
  kty: "EC",
  crv: "P-256",
  d: "UZtCPXFfi11UmhpTs-AbIEzS-ahHhsyUVfPGME1HV4M",
  x: "UwM5XZkcVodU5uKW10zVjhczheXnu9BkXEeU55pnvqk",
  y: "IOBYm6ne2_y4SFHPCjx5F7apZez_KB3UfW6nwKOMD2w"
};
const ephemeralPrivateJwk = {
  kty: "EC",
  crv: "P-256",
  d: "lKG7sUuQamGigPJF-ek8fztOI6gvay2wqPTwxtL057k",
  x: "XZHx0BUzMi6fuqyaJU3xCAlrXqA5h4QT6k1k8FJPhp0",
  y: "uGn_3ZqlZcLWTmvZ1I-3QXST3HAd29HmdCtRESAXqM4"
};
const iv = Uint8Array.from([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb]);
const plaintext = "DATABASE_URL=postgres://ashdrop\nTOKEN=top-secret\n";

const recipientPublicJwk = {
  kty: "EC",
  crv: "P-256",
  x: recipientPrivateJwk.x,
  y: recipientPrivateJwk.y
};
const ephemeralPublicJwk = {
  kty: "EC",
  crv: "P-256",
  x: ephemeralPrivateJwk.x,
  y: ephemeralPrivateJwk.y
};
const recipientPublicSec1 = Buffer.concat([
  Buffer.from([0x04]),
  Buffer.from(recipientPrivateJwk.x, "base64url"),
  Buffer.from(recipientPrivateJwk.y, "base64url")
]);
const ephemeralPublicSec1 = Buffer.concat([
  Buffer.from([0x04]),
  Buffer.from(ephemeralPrivateJwk.x, "base64url"),
  Buffer.from(ephemeralPrivateJwk.y, "base64url")
]);

const recipientPublic = await subtle.importKey("jwk", recipientPublicJwk, { name: "ECDH", namedCurve: "P-256" }, false, []);
const ephemeralPrivate = await subtle.importKey("jwk", ephemeralPrivateJwk, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
const shared = await subtle.deriveBits({ name: "ECDH", public: recipientPublic }, ephemeralPrivate, 256);
const hkdf = await subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
const aes = await subtle.deriveKey(
  {
    name: "HKDF",
    hash: "SHA-256",
    salt: new Uint8Array(32),
    info: text.encode("ashdrop-ecdh-v1")
  },
  hkdf,
  { name: "AES-GCM", length: 256 },
  false,
  ["encrypt"]
);
const ciphertext = await subtle.encrypt({ name: "AES-GCM", iv }, aes, text.encode(plaintext));

const fixture = {
  version: 1,
  generated_by: "Node.js Web Crypto",
  recipient_private_jwk: recipientPrivateJwk,
  recipient_public_sec1: b64url(recipientPublicSec1),
  ephemeral_private_jwk: ephemeralPrivateJwk,
  ephemeral_public_sec1: b64url(ephemeralPublicSec1),
  iv: b64url(iv),
  ciphertext: b64url(ciphertext),
  plaintext
};

process.stdout.write(`${JSON.stringify(fixture, null, 2)}\n`);
