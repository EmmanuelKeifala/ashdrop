//! Implements the recipient-keyed P-256, HKDF, and AES-GCM protocol used by Ashdrop.

const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const P256 = std.crypto.ecc.P256;

const hkdf_info = "ashdrop-ecdh-v1";
const inbox_hkdf_info = "ashdrop-inbox-v1";

const RandomSource = struct {
    context: ?*anyopaque,
    fill: *const fn (context: ?*anyopaque, output: []u8) void,
};

pub const Sealed = struct {
    ciphertext: []u8,
    iv: []u8,
    ephemeral_pub: []u8,

    pub fn deinit(self: *Sealed, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
        allocator.free(self.iv);
        allocator.free(self.ephemeral_pub);
        self.* = undefined;
    }
};

/// Encrypts plaintext using an ephemeral P-256 private key and a recipient SEC1 point.
pub fn sealForRecipient(
    allocator: std.mem.Allocator,
    io: std.Io,
    plaintext: []const u8,
    recipient_sec1: []const u8,
) !Sealed {
    var source_io = io;
    return sealForRecipientWithRandomness(allocator, plaintext, recipient_sec1, .{
        .context = &source_io,
        .fill = fillFromIo,
    });
}

fn sealForRecipientWithRandomness(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    recipient_sec1: []const u8,
    random: RandomSource,
) !Sealed {
    const recipient = parseRecipientPoint(recipient_sec1) catch return error.InvalidRecipient;
    var ephemeral_private: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &ephemeral_private);
    // Each drop samples a new sender key, making reuse for the same recipient negligibly likely.
    randomPrivateScalar(random, &ephemeral_private);
    var ephemeral_public = P256.basePoint.mul(ephemeral_private, .big) catch unreachable;
    defer secureZeroValue(P256, &ephemeral_public);
    const ephemeral_sec1 = ephemeral_public.toUncompressedSec1();
    var key: [Aes256Gcm.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    // The versioned ECDH/HKDF derivation keeps browser and CLI ciphertext interoperable.
    deriveKey(&ephemeral_private, recipient, &key) catch return error.InvalidRecipient;

    var iv: [Aes256Gcm.nonce_length]u8 = undefined;
    random.fill(random.context, &iv);

    var encrypted = try allocator.alloc(u8, plaintext.len + Aes256Gcm.tag_length);
    defer allocator.free(encrypted);
    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(
        encrypted[0..plaintext.len],
        &tag,
        plaintext,
        "",
        iv,
        key,
    );
    @memcpy(encrypted[plaintext.len..], &tag);

    const ciphertext = try encodeB64url(allocator, encrypted);
    errdefer allocator.free(ciphertext);
    const encoded_iv = try encodeB64url(allocator, &iv);
    errdefer allocator.free(encoded_iv);
    const encoded_ephemeral = try encodeB64url(allocator, &ephemeral_sec1);
    return .{
        .ciphertext = ciphertext,
        .iv = encoded_iv,
        .ephemeral_pub = encoded_ephemeral,
    };
}

/// Decrypts a protocol v1 recipient payload using a big-endian P-256 scalar.
pub fn openForRecipient(
    allocator: std.mem.Allocator,
    private_scalar: *const [32]u8,
    ciphertext_b64: []const u8,
    iv_b64: []const u8,
    ephemeral_b64: []const u8,
) ![]u8 {
    try validatePrivateScalar(private_scalar);

    const ciphertext = decodeB64url(allocator, ciphertext_b64) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidInput,
    };
    defer allocator.free(ciphertext);
    if (ciphertext.len < Aes256Gcm.tag_length) return error.InvalidInput;

    const encoded_iv = decodeB64url(allocator, iv_b64) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidInput,
    };
    defer allocator.free(encoded_iv);
    if (encoded_iv.len != Aes256Gcm.nonce_length) return error.InvalidInput;
    const iv: [Aes256Gcm.nonce_length]u8 = encoded_iv[0..Aes256Gcm.nonce_length].*;

    const ephemeral_sec1 = decodeB64url(allocator, ephemeral_b64) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidInput,
    };
    defer allocator.free(ephemeral_sec1);
    const ephemeral = parseEphemeralPoint(ephemeral_sec1) catch return error.InvalidInput;
    var key: [Aes256Gcm.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    deriveKey(private_scalar, ephemeral, &key) catch return error.InvalidInput;

    const encrypted_len = ciphertext.len - Aes256Gcm.tag_length;
    const plaintext = try allocator.alloc(u8, encrypted_len);
    errdefer allocator.free(plaintext);
    const tag: [Aes256Gcm.tag_length]u8 = ciphertext[encrypted_len..][0..Aes256Gcm.tag_length].*;
    // Authentication must succeed before plaintext becomes available to callers.
    Aes256Gcm.decrypt(plaintext, ciphertext[0..encrypted_len], tag, "", iv, key) catch return error.AuthenticationFailed;
    return plaintext;
}

/// Derives the canonical proof required to list inbox entries for a local recipient identity.
pub fn inboxProof(
    allocator: std.mem.Allocator,
    recipient_private: *const [32]u8,
    server_inbox_sec1: []const u8,
    limit: u32,
    at: i64,
) ![]u8 {
    try validatePrivateScalar(recipient_private);
    if (limit == 0 or limit > 100) return error.InvalidInboxRequest;
    const server_public = parseInboxServerPoint(server_inbox_sec1) catch return error.InvalidInboxKey;

    var recipient_point = P256.basePoint.mul(recipient_private.*, .big) catch return error.InvalidPrivateKey;
    defer secureZeroValue(P256, &recipient_point);
    const recipient_sec1 = recipient_point.toUncompressedSec1();
    var recipient_pub: [87]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&recipient_pub, &recipient_sec1);

    var hmac_key: [HmacSha256.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &hmac_key);
    deriveKeyWithInfo(recipient_private, server_public, inbox_hkdf_info, &hmac_key) catch return error.InvalidInboxKey;

    var request_buffer: [192]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buffer,
        "ashdrop-inbox-v1\nGET\n/api/addresses/{s}/inbox\nlimit={d}&at={d}",
        .{ &recipient_pub, limit, at },
    ) catch unreachable;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &mac);
    HmacSha256.create(&mac, request, &hmac_key);
    return encodeB64url(allocator, &mac);
}

fn validatePrivateScalar(private: *const [32]u8) error{InvalidPrivateKey}!void {
    P256.scalar.rejectNonCanonical(private.*, .big) catch return error.InvalidPrivateKey;
    if (std.mem.allEqual(u8, private, 0)) return error.InvalidPrivateKey;
}

fn parseRecipientPoint(sec1: []const u8) error{InvalidRecipient}!P256 {
    if (sec1.len != 65 or sec1[0] != 0x04) return error.InvalidRecipient;
    return P256.fromSec1(sec1) catch error.InvalidRecipient;
}

fn parseEphemeralPoint(sec1: []const u8) error{InvalidInput}!P256 {
    if (sec1.len != 65 or sec1[0] != 0x04) return error.InvalidInput;
    return P256.fromSec1(sec1) catch error.InvalidInput;
}

fn parseInboxServerPoint(sec1: []const u8) error{InvalidInboxKey}!P256 {
    if (sec1.len != 65 or sec1[0] != 0x04) return error.InvalidInboxKey;
    return P256.fromSec1(sec1) catch error.InvalidInboxKey;
}

fn deriveKey(private: *const [32]u8, peer_public: P256, key: *[Aes256Gcm.key_length]u8) error{InvalidInput}!void {
    deriveKeyWithInfo(private, peer_public, hkdf_info, key) catch return error.InvalidInput;
}

fn deriveKeyWithInfo(private: *const [32]u8, peer_public: P256, info: []const u8, key: *[Aes256Gcm.key_length]u8) !void {
    var shared_point = try peer_public.mul(private.*, .big);
    defer secureZeroValue(P256, &shared_point);
    // Protocol v1 feeds the ECDH x-coordinate, not a serialized point, into HKDF.
    var shared_coordinates = shared_point.affineCoordinates();
    defer secureZeroValue(@TypeOf(shared_coordinates), &shared_coordinates);
    var shared_x = shared_coordinates.x.toBytes(.big);
    defer std.crypto.secureZero(u8, &shared_x);
    const salt: [32]u8 = @splat(0);
    var prk = HkdfSha256.extract(&salt, &shared_x);
    defer std.crypto.secureZero(u8, &prk);
    HkdfSha256.expand(key, info, prk);
}

fn fillFromIo(context: ?*anyopaque, output: []u8) void {
    const io: *const std.Io = @ptrCast(@alignCast(context.?));
    io.random(output);
}

fn randomPrivateScalar(random: RandomSource, private: *[32]u8) void {
    var entropy: [48]u8 = undefined;
    defer std.crypto.secureZero(u8, &entropy);
    while (true) {
        random.fill(random.context, &entropy);
        var scalar = P256.scalar.Scalar.fromBytes48(entropy, .little);
        const is_zero = scalar.isZero();
        if (!is_zero) private.* = scalar.toBytes(.big);
        secureZeroValue(@TypeOf(scalar), &scalar);
        if (!is_zero) return;
    }
}

fn secureZeroValue(comptime T: type, value: *T) void {
    std.crypto.secureZero(T, @as([*]volatile T, @ptrCast(value))[0..1]);
}

fn encodeB64url(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

fn decodeB64url(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidInput;
    // One canonical encoding prevents alternate links or payloads from representing the same bytes.
    if (!hasCanonicalTrailingBits(encoded)) return error.InvalidInput;

    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch return error.InvalidInput;
    return decoded;
}

fn hasCanonicalTrailingBits(encoded: []const u8) bool {
    if (encoded.len == 0 or encoded.len % 4 == 0) return true;
    const index = std.mem.indexOfScalar(u8, &std.base64.url_safe_alphabet_chars, encoded[encoded.len - 1]) orelse return false;
    return switch (encoded.len % 4) {
        2 => index & 0x0f == 0,
        3 => index & 0x03 == 0,
        else => false,
    };
}

const ProtocolFixture = struct {
    recipient_private_jwk: struct {
        d: []const u8,
    },
    recipient_public_sec1: []const u8,
    ephemeral_private_jwk: struct {
        d: []const u8,
    },
    ephemeral_public_sec1: []const u8,
    iv: []const u8,
    ciphertext: []const u8,
    plaintext: []const u8,
};

const FixedRandom = struct {
    bytes: [48 + Aes256Gcm.nonce_length]u8,
    offset: usize = 0,

    fn init(ephemeral_private: [32]u8, iv: [Aes256Gcm.nonce_length]u8) FixedRandom {
        var bytes: [48 + Aes256Gcm.nonce_length]u8 = undefined;
        for (ephemeral_private, 0..) |byte, index| {
            bytes[31 - index] = byte;
        }
        @memset(bytes[32..48], 0);
        @memcpy(bytes[48..], &iv);
        return .{ .bytes = bytes };
    }

    fn fill(context: ?*anyopaque, output: []u8) void {
        const self: *FixedRandom = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.offset + output.len <= self.bytes.len);
        @memcpy(output, self.bytes[self.offset..][0..output.len]);
        self.offset += output.len;
    }
};

test "recipient sealing matches the fixed Node Web Crypto fixture" {
    var fixture = try std.json.parseFromSlice(ProtocolFixture, std.testing.allocator, @embedFile("../testdata/protocol-v1.json"), .{
        .ignore_unknown_fields = true,
    });
    defer fixture.deinit();

    var recipient_public: [65]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&recipient_public, fixture.value.recipient_public_sec1);
    var ephemeral_private: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &ephemeral_private);
    try std.base64.url_safe_no_pad.Decoder.decode(&ephemeral_private, fixture.value.ephemeral_private_jwk.d);
    var iv: [Aes256Gcm.nonce_length]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&iv, fixture.value.iv);
    var fixed_random = FixedRandom.init(ephemeral_private, iv);
    defer std.crypto.secureZero(u8, &fixed_random.bytes);

    var sealed = try sealForRecipientWithRandomness(
        std.testing.allocator,
        fixture.value.plaintext,
        &recipient_public,
        .{ .context = &fixed_random, .fill = FixedRandom.fill },
    );
    defer sealed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(fixture.value.ciphertext, sealed.ciphertext);
    try std.testing.expectEqualStrings(fixture.value.iv, sealed.iv);
    try std.testing.expectEqualStrings(fixture.value.ephemeral_public_sec1, sealed.ephemeral_pub);
    try std.testing.expectEqual(fixed_random.bytes.len, fixed_random.offset);
}
