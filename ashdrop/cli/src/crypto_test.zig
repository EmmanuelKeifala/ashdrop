//! Tests protocol interoperability, malformed input handling, and allocation cleanup.

const std = @import("std");
const crypto = @import("crypto.zig");

const Fixture = struct {
    version: u8,
    recipient_private_jwk: struct {
        d: []const u8,
    },
    recipient_public_sec1: []const u8,
    ephemeral_public_sec1: []const u8,
    iv: []const u8,
    ciphertext: []const u8,
};

fn loadFixture() !std.json.Parsed(Fixture) {
    return std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("../testdata/protocol-v1.json"), .{
        .ignore_unknown_fields = true,
    });
}

fn decodeFixed(comptime len: usize, encoded: []const u8) ![len]u8 {
    var decoded: [len]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&decoded, encoded);
    return decoded;
}

fn scalar(last_byte: u8) [32]u8 {
    var value: [32]u8 = @splat(0);
    value[31] = last_byte;
    return value;
}

fn publicSec1(private_scalar: [32]u8) ![65]u8 {
    var point = try std.crypto.ecc.P256.basePoint.mul(private_scalar, .big);
    defer std.crypto.secureZero(@TypeOf(point), @as([*]volatile @TypeOf(point), @ptrCast(&point))[0..1]);
    return point.toUncompressedSec1();
}

fn referenceInboxProof(recipient_private: [32]u8, server_public: []const u8, limit: u32, at: i64) ![43]u8 {
    const P256 = std.crypto.ecc.P256;
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const server = try P256.fromSec1(server_public);
    var shared_point = try server.mul(recipient_private, .big);
    defer std.crypto.secureZero(@TypeOf(shared_point), @as([*]volatile @TypeOf(shared_point), @ptrCast(&shared_point))[0..1]);
    var coordinates = shared_point.affineCoordinates();
    defer std.crypto.secureZero(@TypeOf(coordinates), @as([*]volatile @TypeOf(coordinates), @ptrCast(&coordinates))[0..1]);
    var shared_x = coordinates.x.toBytes(.big);
    defer std.crypto.secureZero(u8, &shared_x);
    const salt: [32]u8 = @splat(0);
    var prk = std.crypto.kdf.hkdf.HkdfSha256.extract(&salt, &shared_x);
    defer std.crypto.secureZero(u8, &prk);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    std.crypto.kdf.hkdf.HkdfSha256.expand(&key, "ashdrop-inbox-v1", prk);

    const recipient_public = try publicSec1(recipient_private);
    var recipient_encoded: [87]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&recipient_encoded, &recipient_public);
    var request: [192]u8 = undefined;
    const canonical_request = try std.fmt.bufPrint(
        &request,
        "ashdrop-inbox-v1\nGET\n/api/addresses/{s}/inbox\nlimit={d}&at={d}",
        .{ &recipient_encoded, limit, at },
    );
    var mac: [HmacSha256.mac_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &mac);
    HmacSha256.create(&mac, canonical_request, &key);
    var encoded: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &mac);
    return encoded;
}

fn sealAllocationFailure(allocator: std.mem.Allocator, recipient_public: [65]u8) !void {
    var sealed = try crypto.sealForRecipient(allocator, std.testing.io, "allocation cleanup", &recipient_public);
    defer sealed.deinit(allocator);
}

fn openAllocationFailure(
    allocator: std.mem.Allocator,
    private_scalar: [32]u8,
    ciphertext: []const u8,
    iv: []const u8,
    ephemeral_public: []const u8,
) !void {
    const plaintext = try crypto.openForRecipient(allocator, &private_scalar, ciphertext, iv, ephemeral_public);
    defer allocator.free(plaintext);
}

test "recipient protocol decrypts the Node Web Crypto fixture" {
    var fixture = try loadFixture();
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u8, 1), fixture.value.version);

    const private_scalar = try decodeFixed(32, fixture.value.recipient_private_jwk.d);
    const plaintext = try crypto.openForRecipient(
        std.testing.allocator,
        &private_scalar,
        fixture.value.ciphertext,
        fixture.value.iv,
        fixture.value.ephemeral_public_sec1,
    );
    defer std.testing.allocator.free(plaintext);

    try std.testing.expectEqualStrings("DATABASE_URL=postgres://ashdrop\nTOKEN=top-secret\n", plaintext);
}

test "recipient protocol seals and opens a plaintext" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const recipient_public = try decodeFixed(65, fixture.value.recipient_public_sec1);
    const private_scalar = try decodeFixed(32, fixture.value.recipient_private_jwk.d);
    var sealed = try crypto.sealForRecipient(
        std.testing.allocator,
        std.testing.io,
        "DATABASE_URL=postgres://ashdrop\nTOKEN=top-secret\n",
        &recipient_public,
    );
    defer sealed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 16), sealed.iv.len);
    try std.testing.expectEqual(@as(usize, 87), sealed.ephemeral_pub.len);
    const plaintext = try crypto.openForRecipient(
        std.testing.allocator,
        &private_scalar,
        sealed.ciphertext,
        sealed.iv,
        sealed.ephemeral_pub,
    );
    defer std.testing.allocator.free(plaintext);

    try std.testing.expectEqualStrings("DATABASE_URL=postgres://ashdrop\nTOKEN=top-secret\n", plaintext);
}

test "recipient protocol rejects malformed recipient and payload inputs" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const recipient_public = try decodeFixed(65, fixture.value.recipient_public_sec1);
    const private_scalar = try decodeFixed(32, fixture.value.recipient_private_jwk.d);
    var malformed_point: [65]u8 = @splat(0);
    malformed_point[0] = 0x04;
    try std.testing.expectError(
        error.InvalidRecipient,
        crypto.sealForRecipient(std.testing.allocator, std.testing.io, "test", &malformed_point),
    );
    const short_point = [_]u8{0x04};
    try std.testing.expectError(
        error.InvalidRecipient,
        crypto.sealForRecipient(std.testing.allocator, std.testing.io, "test", &short_point),
    );

    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            "AA==",
            fixture.value.iv,
            fixture.value.ephemeral_public_sec1,
        ),
    );
    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            fixture.value.ciphertext,
            "AA",
            fixture.value.ephemeral_public_sec1,
        ),
    );
    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            "AA",
            fixture.value.iv,
            fixture.value.ephemeral_public_sec1,
        ),
    );
    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            fixture.value.ciphertext,
            fixture.value.iv,
            "AA",
        ),
    );
    const ephemeral = try decodeFixed(65, fixture.value.ephemeral_public_sec1);
    var compressed: [33]u8 = undefined;
    compressed[0] = 0x02 + (ephemeral[64] & 1);
    @memcpy(compressed[1..], ephemeral[1..33]);
    var compressed_b64: [44]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&compressed_b64, &compressed);
    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            fixture.value.ciphertext,
            fixture.value.iv,
            &compressed_b64,
        ),
    );

    var sealed = try crypto.sealForRecipient(std.testing.allocator, std.testing.io, "roundtrip", &recipient_public);
    defer sealed.deinit(std.testing.allocator);
    const alphabet = std.base64.url_safe_alphabet_chars;
    var noncanonical = try std.testing.allocator.dupe(u8, sealed.ciphertext);
    defer std.testing.allocator.free(noncanonical);
    const index = std.mem.indexOfScalar(u8, &alphabet, noncanonical[noncanonical.len - 1]).?;
    noncanonical[noncanonical.len - 1] = alphabet[(index & 0b110000) | ((index + 1) & 0b001111)];
    try std.testing.expectError(
        error.InvalidInput,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            noncanonical,
            sealed.iv,
            sealed.ephemeral_pub,
        ),
    );
}

test "recipient protocol rejects zero and noncanonical P-256 private scalars" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const order = [32]u8{
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    };
    const invalid_scalars = [_][32]u8{
        @splat(0),
        order,
        @splat(0xff),
    };
    for (invalid_scalars) |private_scalar| {
        try std.testing.expectError(
            error.InvalidPrivateKey,
            crypto.openForRecipient(
                std.testing.allocator,
                &private_scalar,
                fixture.value.ciphertext,
                fixture.value.iv,
                fixture.value.ephemeral_public_sec1,
            ),
        );
    }
}

test "recipient protocol reports AES authentication failures" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const recipient_public = try decodeFixed(65, fixture.value.recipient_public_sec1);
    const private_scalar = try decodeFixed(32, fixture.value.recipient_private_jwk.d);
    var sealed = try crypto.sealForRecipient(std.testing.allocator, std.testing.io, "authenticated", &recipient_public);
    defer sealed.deinit(std.testing.allocator);

    const alphabet = std.base64.url_safe_alphabet_chars;
    var tampered = try std.testing.allocator.dupe(u8, sealed.ciphertext);
    defer std.testing.allocator.free(tampered);
    const index = std.mem.indexOfScalar(u8, &alphabet, tampered[0]).?;
    tampered[0] = alphabet[(index + 1) % alphabet.len];
    try std.testing.expectError(
        error.AuthenticationFailed,
        crypto.openForRecipient(
            std.testing.allocator,
            &private_scalar,
            tampered,
            sealed.iv,
            sealed.ephemeral_pub,
        ),
    );
}

test "inbox proof agrees with the P-256 HKDF-HMAC protocol" {
    const recipient_private = scalar(1);
    const server_public = try publicSec1(scalar(2));
    const expected = try referenceInboxProof(recipient_private, &server_public, 25, 1_700_000_000);
    const proof = try crypto.inboxProof(
        std.testing.allocator,
        &recipient_private,
        &server_public,
        25,
        1_700_000_000,
    );
    defer std.testing.allocator.free(proof);

    try std.testing.expectEqualStrings(&expected, proof);
}

test "inbox proof binds the recipient limit and timestamp" {
    const first_recipient = scalar(1);
    const second_recipient = scalar(3);
    const server_public = try publicSec1(scalar(2));
    const base = try crypto.inboxProof(std.testing.allocator, &first_recipient, &server_public, 25, 1_700_000_000);
    defer std.testing.allocator.free(base);
    const changed_recipient = try crypto.inboxProof(std.testing.allocator, &second_recipient, &server_public, 25, 1_700_000_000);
    defer std.testing.allocator.free(changed_recipient);
    const changed_limit = try crypto.inboxProof(std.testing.allocator, &first_recipient, &server_public, 26, 1_700_000_000);
    defer std.testing.allocator.free(changed_limit);
    const changed_time = try crypto.inboxProof(std.testing.allocator, &first_recipient, &server_public, 25, 1_700_000_001);
    defer std.testing.allocator.free(changed_time);

    try std.testing.expect(!std.mem.eql(u8, base, changed_recipient));
    try std.testing.expect(!std.mem.eql(u8, base, changed_limit));
    try std.testing.expect(!std.mem.eql(u8, base, changed_time));
}

test "inbox proof supports full width signed timestamps" {
    const recipient_private = scalar(1);
    const server_public = try publicSec1(scalar(2));
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |timestamp| {
        const proof = try crypto.inboxProof(std.testing.allocator, &recipient_private, &server_public, 100, timestamp);
        defer std.testing.allocator.free(proof);
        try std.testing.expectEqual(@as(usize, 43), proof.len);
    }
}

test "inbox proof rejects malformed server keys and private scalars" {
    const valid_private = scalar(1);
    const server_public = try publicSec1(scalar(2));
    const short_key = [_]u8{0x04};
    var malformed_key: [65]u8 = @splat(0);
    malformed_key[0] = 0x04;
    const order = [32]u8{
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    };

    try std.testing.expectError(error.InvalidInboxKey, crypto.inboxProof(std.testing.allocator, &valid_private, &short_key, 1, 1));
    try std.testing.expectError(error.InvalidInboxKey, crypto.inboxProof(std.testing.allocator, &valid_private, &malformed_key, 1, 1));
    const zero: [32]u8 = @splat(0);
    try std.testing.expectError(error.InvalidPrivateKey, crypto.inboxProof(std.testing.allocator, &zero, &server_public, 1, 1));
    try std.testing.expectError(error.InvalidPrivateKey, crypto.inboxProof(std.testing.allocator, &order, &server_public, 1, 1));
}

test "recipient protocol cleans up every sealing allocation failure" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const recipient_public = try decodeFixed(65, fixture.value.recipient_public_sec1);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        sealAllocationFailure,
        .{recipient_public},
    );
}

test "recipient protocol cleans up every opening allocation failure" {
    var fixture = try loadFixture();
    defer fixture.deinit();

    const private_scalar = try decodeFixed(32, fixture.value.recipient_private_jwk.d);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openAllocationFailure,
        .{
            private_scalar,
            fixture.value.ciphertext,
            fixture.value.iv,
            fixture.value.ephemeral_public_sec1,
        },
    );
}
