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
