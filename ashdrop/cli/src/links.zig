//! Parses and formats Ashdrop receive addresses, drop references, web URLs, and portable URIs.

const std = @import("std");
const config = @import("config.zig");

pub const ReceiveRef = struct {
    key: [65]u8,
    api: ?[]u8 = null,

    pub fn deinit(self: *ReceiveRef, allocator: std.mem.Allocator) void {
        if (self.api) |api| allocator.free(api);
        self.* = undefined;
    }
};

pub const DropRef = struct {
    id: []const u8,
    api: ?[]const u8 = null,
    api_owned: ?[]u8 = null,

    pub fn deinit(self: *DropRef, allocator: std.mem.Allocator) void {
        if (self.api_owned) |api| allocator.free(api);
        self.* = undefined;
    }
};

pub fn formatRawReceive(key: [65]u8) [87]u8 {
    var encoded: [87]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &key);
    return encoded;
}

pub fn parseReceive(allocator: std.mem.Allocator, input: []const u8) !ReceiveRef {
    if (std.mem.startsWith(u8, input, "ashdrop://receive/")) {
        const parts = try parseAshdropUri(allocator, input, "ashdrop://receive/", error.InvalidReceiveReference);
        errdefer allocator.free(parts.api);
        return .{
            .key = try decodeReceiveKey(parts.value),
            .api = parts.api,
        };
    }

    if (webPath(input)) |path| {
        const prefix = "/drop-for/";
        const route_index = std.mem.lastIndexOf(u8, path, prefix) orelse return error.InvalidReceiveReference;
        return .{ .key = try decodeReceiveKey(path[route_index + prefix.len ..]) };
    }

    return .{ .key = try decodeReceiveKey(input) };
}

pub fn parseDrop(allocator: std.mem.Allocator, input: []const u8) !DropRef {
    if (std.mem.startsWith(u8, input, "ashdrop://drop/")) {
        const parts = try parseAshdropUri(allocator, input, "ashdrop://drop/", error.InvalidDropReference);
        errdefer allocator.free(parts.api);
        if (!isDropId(parts.value)) return error.InvalidDropReference;
        return .{ .id = parts.value, .api = parts.api, .api_owned = parts.api };
    }

    if (webPath(input)) |path| {
        const prefix = "/s/";
        const route_index = std.mem.lastIndexOf(u8, path, prefix) orelse return error.InvalidDropReference;
        const id = path[route_index + prefix.len ..];
        if (!isDropId(id)) return error.InvalidDropReference;
        return .{ .id = id };
    }

    if (!isDropId(input)) return error.InvalidDropReference;
    return .{ .id = input };
}

pub fn formatReceive(
    allocator: std.mem.Allocator,
    key: [65]u8,
    api: []const u8,
    web: ?[]const u8,
) ![]u8 {
    _ = try config.resolveApi(null, null, api);
    try validateReceiveKey(key);
    const raw = formatRawReceive(key);
    return formatLink(allocator, "drop-for", &raw, "receive", api, web);
}

pub fn formatDrop(
    allocator: std.mem.Allocator,
    id: []const u8,
    api: []const u8,
    web: ?[]const u8,
) ![]u8 {
    _ = try config.resolveApi(null, null, api);
    if (!isDropId(id)) return error.InvalidDropReference;
    return formatLink(allocator, "s", id, "drop", api, web);
}

fn formatLink(
    allocator: std.mem.Allocator,
    web_path: []const u8,
    value: []const u8,
    uri_kind: []const u8,
    api: []const u8,
    web: ?[]const u8,
) ![]u8 {
    const selected_web: ?[]const u8 = web orelse if (std.mem.eql(u8, api, config.managed_api)) config.managed_web else null;
    if (selected_web) |base| {
        const valid_base = try config.resolveWeb(base, null);
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ trimTrailingSlashes(valid_base), web_path, value });
    }

    // A self-hosted API without a web app remains usable by carrying its endpoint in the URI.
    const prefix = try std.fmt.allocPrint(allocator, "ashdrop://{s}/{s}?api=", .{ uri_kind, value });
    defer allocator.free(prefix);
    const encoded_api_len = percentEncodedLen(api);
    const output = try allocator.alloc(u8, prefix.len + encoded_api_len);
    @memcpy(output[0..prefix.len], prefix);
    var out_index = prefix.len;
    for (api) |byte| {
        if (isUnreserved(byte)) {
            output[out_index] = byte;
            out_index += 1;
        } else {
            output[out_index] = '%';
            output[out_index + 1] = hexDigit(byte >> 4);
            output[out_index + 2] = hexDigit(byte & 0x0f);
            out_index += 3;
        }
    }
    return output;
}

fn parseAshdropUri(
    allocator: std.mem.Allocator,
    input: []const u8,
    prefix: []const u8,
    comptime invalid_error: anyerror,
) !struct { value: []const u8, api: []u8 } {
    const remaining = input[prefix.len..];
    const query_index = std.mem.indexOfScalar(u8, remaining, '?') orelse return invalid_error;
    const value = remaining[0..query_index];
    const query = remaining[query_index + 1 ..];
    // Accept one endpoint parameter only so the receiving client has unambiguous routing.
    if (value.len == 0 or !std.mem.startsWith(u8, query, "api=") or std.mem.indexOfScalar(u8, query[4..], '&') != null) {
        return invalid_error;
    }
    const api = decodeEmbeddedApi(allocator, query[4..]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidEmbeddedApi => return invalid_error,
    };
    return .{ .value = value, .api = api };
}

fn decodeReceiveKey(input: []const u8) error{InvalidReceiveReference}![65]u8 {
    if (input.len != 87) return error.InvalidReceiveReference;
    var key: [65]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&key, input) catch return error.InvalidReceiveReference;
    if (key[0] != 0x04) return error.InvalidReceiveReference;
    const canonical = formatRawReceive(key);
    if (!std.mem.eql(u8, input, &canonical)) return error.InvalidReceiveReference;
    _ = std.crypto.ecc.P256.fromSec1(&key) catch return error.InvalidReceiveReference;
    return key;
}

fn validateReceiveKey(key: [65]u8) error{InvalidReceiveReference}!void {
    if (key[0] != 0x04) return error.InvalidReceiveReference;
    _ = std.crypto.ecc.P256.fromSec1(&key) catch return error.InvalidReceiveReference;
}

fn decodeEmbeddedApi(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0) return error.InvalidEmbeddedApi;
    var decoded = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(decoded);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        const byte = encoded[input_index];
        if (isUnreserved(byte)) {
            decoded[output_index] = byte;
            input_index += 1;
            output_index += 1;
            continue;
        }
        if (byte != '%' or input_index + 2 >= encoded.len) return error.InvalidEmbeddedApi;
        const high = hexValue(encoded[input_index + 1]) orelse return error.InvalidEmbeddedApi;
        const low = hexValue(encoded[input_index + 2]) orelse return error.InvalidEmbeddedApi;
        decoded[output_index] = (high << 4) | low;
        input_index += 3;
        output_index += 1;
    }
    decoded = try allocator.realloc(decoded, output_index);
    _ = config.resolveApi(null, null, decoded) catch return error.InvalidEmbeddedApi;
    return decoded;
}

fn webPath(input: []const u8) ?[]const u8 {
    const scheme_len = if (std.mem.startsWith(u8, input, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, input, "http://"))
        "http://".len
    else
        return null;
    _ = config.resolveWeb(input, null) catch return null;
    const host_and_path = input[scheme_len..];
    const path_index = std.mem.indexOfScalar(u8, host_and_path, '/') orelse return null;
    if (path_index == 0) return null;
    return host_and_path[path_index..];
}

fn trimTrailingSlashes(url: []const u8) []const u8 {
    var end = url.len;
    while (end > "https://".len and url[end - 1] == '/') : (end -= 1) {}
    return url[0..end];
}

fn isDropId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |byte| {
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn isUnreserved(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn percentEncodedLen(input: []const u8) usize {
    var length = input.len;
    for (input) |byte| {
        if (!isUnreserved(byte)) length += 2;
    }
    return length;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

fn hexValue(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

fn basePoint() [65]u8 {
    return std.crypto.ecc.P256.basePoint.toUncompressedSec1();
}

test "raw receive key parses and formats canonically" {
    const key = basePoint();
    const raw = formatRawReceive(key);
    var parsed = try parseReceive(std.testing.allocator, &raw);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &key, &parsed.key);
}

test "web receive and drop links parse and format" {
    const key = basePoint();
    const receive = try formatReceive(std.testing.allocator, key, config.managed_api, null);
    defer std.testing.allocator.free(receive);
    var parsed_receive = try parseReceive(std.testing.allocator, receive);
    defer parsed_receive.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &key, &parsed_receive.key);

    const id = "0123456789abcdef0123456789abcdef";
    const drop = try formatDrop(std.testing.allocator, id, config.managed_api, null);
    defer std.testing.allocator.free(drop);
    var parsed_drop = try parseDrop(std.testing.allocator, drop);
    defer parsed_drop.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(id, parsed_drop.id);
    try std.testing.expect(parsed_drop.api == null);
}

test "managed, localhost, and path-prefixed web links round trip" {
    const key = basePoint();
    const id = "0123456789abcdef0123456789abcdef";
    const web_bases = [_][]const u8{
        "https://ashdrop.dev",
        "http://localhost:8080",
        "http://localhost:8080/app",
    };

    for (web_bases) |web| {
        const receive = try formatReceive(std.testing.allocator, key, config.managed_api, web);
        defer std.testing.allocator.free(receive);
        var parsed_receive = try parseReceive(std.testing.allocator, receive);
        defer parsed_receive.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, &key, &parsed_receive.key);

        const drop = try formatDrop(std.testing.allocator, id, config.managed_api, web);
        defer std.testing.allocator.free(drop);
        var parsed_drop = try parseDrop(std.testing.allocator, drop);
        defer parsed_drop.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(id, parsed_drop.id);
    }

    const prefixed = try formatReceive(std.testing.allocator, key, config.managed_api, "http://localhost:8080/app");
    defer std.testing.allocator.free(prefixed);
    try std.testing.expect(std.mem.startsWith(u8, prefixed, "http://localhost:8080/app/drop-for/"));
}

test "Ashdrop receive and drop URIs preserve embedded APIs" {
    const key = basePoint();
    const receive = try formatReceive(std.testing.allocator, key, "https://self.example/api", null);
    defer std.testing.allocator.free(receive);
    var parsed_receive = try parseReceive(std.testing.allocator, receive);
    defer parsed_receive.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://self.example/api", parsed_receive.api.?);

    const drop = try formatDrop(
        std.testing.allocator,
        "0123456789abcdef0123456789abcdef",
        "https://self.example/api",
        null,
    );
    defer std.testing.allocator.free(drop);
    var parsed_drop = try parseDrop(std.testing.allocator, drop);
    defer parsed_drop.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://self.example/api", parsed_drop.api.?);
}

test "parsed Ashdrop URI API takes precedence over environment" {
    var drop = try parseDrop(
        std.testing.allocator,
        "ashdrop://drop/0123456789abcdef0123456789abcdef?api=https%3A%2F%2Furi.example",
    );
    defer drop.deinit(std.testing.allocator);
    try std.testing.expect(@TypeOf(drop.api) == ?[]const u8);

    try std.testing.expectEqualStrings(
        "https://uri.example",
        try config.resolveApi(null, "https://env.example", drop.api),
    );
    try std.testing.expectEqualStrings(
        "https://flag.example",
        try config.resolveApi("https://flag.example", "https://env.example", drop.api),
    );
    try std.testing.expectEqualStrings(config.managed_api, try config.resolveApi(null, null, null));
}

test "custom web endpoint formats web links" {
    const key = basePoint();
    const receive = try formatReceive(
        std.testing.allocator,
        key,
        "https://self.example/api",
        "https://web.example",
    );
    defer std.testing.allocator.free(receive);
    try std.testing.expectEqualStrings("https://web.example/drop-for/", receive[0..29]);
}

test "link parser rejects malformed and noncanonical references" {
    const key = basePoint();
    var raw = formatRawReceive(key);
    const alphabet = std.base64.url_safe_alphabet_chars;
    const index = std.mem.indexOfScalar(u8, &alphabet, raw[raw.len - 1]).?;
    raw[raw.len - 1] = alphabet[index | 1];
    try std.testing.expectError(error.InvalidReceiveReference, parseReceive(std.testing.allocator, &raw));
    try std.testing.expectError(error.InvalidReceiveReference, parseReceive(std.testing.allocator, "https://ashdrop.dev/drop-for/nope/extra"));
    try std.testing.expectError(error.InvalidReceiveReference, parseReceive(std.testing.allocator, "ashdrop://receive/nope?api=https%3A%2F%2Fself.example&x=1"));
    try std.testing.expectError(error.InvalidDropReference, parseDrop(std.testing.allocator, "https://ashdrop.dev/s/0123456789ABCDEF0123456789ABCDEF"));
    try std.testing.expectError(error.InvalidDropReference, parseDrop(std.testing.allocator, "ashdrop://drop/0123456789abcdef0123456789abcdef?x=1"));
    try std.testing.expectError(error.InvalidDropReference, parseDrop(std.testing.allocator, "ashdrop://drop/0123456789abcdef0123456789abcdef?api=%ZZ"));
}

test "Ashdrop URI parsing preserves allocator failures" {
    try std.testing.expectError(
        error.OutOfMemory,
        parseDrop(
            std.testing.failing_allocator,
            "ashdrop://drop/0123456789abcdef0123456789abcdef?api=https%3A%2F%2Fself.example",
        ),
    );
}
