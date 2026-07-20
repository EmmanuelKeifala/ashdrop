//! Provides the Ashdrop HTTP client, wire types, response bounds, and error mapping.

const std = @import("std");

pub const max_response_size = 96 * 1024;

pub const CreateInput = struct {
    ciphertext: []const u8,
    iv: []const u8,
    ttl: u64,
    maxViews: u32,
    ephemeralPub: []const u8,
    recipientPub: []const u8,
};

pub const CreateResult = struct {
    id: []u8,
    notifyToken: []u8,
    expiresAt: i64,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.notifyToken);
        self.* = undefined;
    }
};

pub const Metadata = struct {
    recipientKeyed: bool,
    recipientPub: []u8,
    expiresAt: i64,
    viewsLeft: i64,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.recipientPub);
        self.* = undefined;
    }
};

pub const OpenedSecret = struct {
    ciphertext: []u8,
    iv: []u8,
    ephemeralPub: []u8,
    recipientKeyed: bool,

    pub fn deinit(self: *OpenedSecret, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
        allocator.free(self.iv);
        allocator.free(self.ephemeralPub);
        self.* = undefined;
    }
};

pub const InboxItem = struct {
    id: []u8,
    expiresAt: i64,
    viewsLeft: i64,

    pub fn deinit(self: *InboxItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub fn deinitInboxItems(allocator: std.mem.Allocator, items: []InboxItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,

    pub fn create(self: *Client, input: CreateInput) !CreateResult {
        const body = try encodeCreate(self.allocator, input);
        defer self.allocator.free(body);
        const response = try self.request(.POST, "/api/secrets", body);
        defer self.allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            try checkErrorResponse(response.status, response.body);
            return error.RemoteFailure;
        }
        return parseCreateResult(self.allocator, response.body);
    }

    pub fn metadata(self: *Client, id: []const u8) !?Metadata {
        const path = try std.fmt.allocPrint(self.allocator, "/api/secrets/{s}/metadata", .{id});
        defer self.allocator.free(path);
        const response = try self.request(.GET, path, null);
        defer self.allocator.free(response.body);
        if (response.status == 404) return null;
        if (response.status < 200 or response.status >= 300) {
            try checkErrorResponse(response.status, response.body);
            return error.RemoteFailure;
        }
        return try parseMetadata(self.allocator, response.body);
    }

    pub fn open(self: *Client, id: []const u8) !?OpenedSecret {
        const path = try std.fmt.allocPrint(self.allocator, "/api/secrets/{s}/open", .{id});
        defer self.allocator.free(path);
        const response = try self.request(.POST, path, "");
        defer self.allocator.free(response.body);
        if (response.status == 404) return null;
        if (response.status < 200 or response.status >= 300) {
            try checkErrorResponse(response.status, response.body);
            return error.RemoteFailure;
        }
        return try parseOpenedSecret(self.allocator, response.body);
    }

    pub fn inboxKey(self: *Client) ![65]u8 {
        try validateInboxEndpoint(self.base_url);
        const response = try self.request(.GET, "/api/inbox-key", null);
        defer self.allocator.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            try checkErrorResponse(response.status, response.body);
            return error.RemoteFailure;
        }
        return parseInboxKey(self.allocator, response.body);
    }

    pub fn inbox(
        self: *Client,
        recipient_pub: []const u8,
        limit: u32,
        at: i64,
        proof: []const u8,
    ) ![]InboxItem {
        try validateInboxEndpoint(self.base_url);
        _ = parseCanonicalP256Public(recipient_pub) catch return error.InvalidInboxRequest;
        if (limit == 0 or limit > 100 or !isCanonicalInboxProof(proof)) return error.InvalidInboxRequest;
        const response = try self.inboxRequest(recipient_pub, limit, at, proof);
        defer self.allocator.free(response.body);
        if (response.status == 401) return error.InboxUnauthorized;
        if (response.status == 429) return error.InboxRateLimited;
        if (response.status < 200 or response.status >= 300) {
            try checkErrorResponse(response.status, response.body);
            return error.RemoteFailure;
        }
        return parseInboxItems(self.allocator, response.body, limit);
    }

    const Response = struct {
        status: u16,
        body: []u8,
    };

    fn request(self: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Response {
        const url = try endpointUrl(self.allocator, self.base_url, path);
        defer self.allocator.free(url);
        return self.fetch(method, url, payload, &.{});
    }

    fn inboxRequest(self: *Client, recipient_pub: []const u8, limit: u32, at: i64, proof: []const u8) !Response {
        const path = try std.fmt.allocPrint(self.allocator, "/api/addresses/{s}/inbox", .{recipient_pub});
        defer self.allocator.free(path);
        const endpoint = try endpointUrl(self.allocator, self.base_url, path);
        defer self.allocator.free(endpoint);
        const url = try std.fmt.allocPrint(self.allocator, "{s}?limit={d}&at={d}", .{ endpoint, limit, at });
        defer self.allocator.free(url);
        const headers = [_]std.http.Header{
            .{ .name = "x-ashdrop-inbox-proof", .value = proof },
        };
        return self.fetch(.GET, url, null, &headers);
    }

    // All API paths use one bounded, redirect-free fetch implementation.
    fn fetch(
        self: *Client,
        method: std.http.Method,
        url: []const u8,
        payload: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        if (extra_headers.len > 1) return error.InvalidRequestHeaders;
        // Bound untrusted API responses before copying them into allocator-owned memory.
        var response_buffer: [max_response_size]u8 = undefined;
        var response_writer = std.Io.Writer.fixed(&response_buffer);
        var http_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer http_client.deinit();
        var headers: [2]std.http.Header = undefined;
        headers[0] = .{ .name = "content-type", .value = "application/json" };
        if (extra_headers.len == 1) headers[1] = extra_headers[0];
        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            // A configured API must not redirect ciphertext, metadata, or inbox credentials.
            .redirect_behavior = .not_allowed,
            .extra_headers = headers[0 .. 1 + extra_headers.len],
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            error.TooManyHttpRedirects => return error.RemoteFailure,
            else => return err,
        };
        return .{
            .status = @intFromEnum(result.status),
            .body = try self.allocator.dupe(u8, response_writer.buffered()),
        };
    }
};

pub fn encodeCreate(allocator: std.mem.Allocator, input: CreateInput) ![]u8 {
    return jsonBody(allocator, input);
}

fn jsonBody(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    var stringify = std.json.Stringify{ .writer = &buffer.writer };
    try stringify.write(value);
    return allocator.dupe(u8, buffer.written());
}

pub fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    var base_end = base_url.len;
    while (base_end > 0 and base_url[base_end - 1] == '/') : (base_end -= 1) {}
    if (base_end == 0 or path.len == 0 or path[0] != '/') return error.InvalidEndpoint;

    var escaped_len: usize = 0;
    for (path) |byte| {
        escaped_len += if (byte == '/' or isUnreserved(byte)) 1 else 3;
    }
    const out = try allocator.alloc(u8, base_end + escaped_len);
    @memcpy(out[0..base_end], base_url[0..base_end]);
    var index = base_end;
    for (path) |byte| {
        if (byte == '/' or isUnreserved(byte)) {
            out[index] = byte;
            index += 1;
        } else {
            out[index] = '%';
            out[index + 1] = hexDigit(byte >> 4);
            out[index + 2] = hexDigit(byte & 0x0f);
            index += 3;
        }
    }
    return out;
}

pub fn checkErrorResponse(status: u16, body: []const u8) !void {
    if (status == 429) return error.RateLimited;
    // Remote error text is untrusted and may contain sensitive data, so never surface it to users.
    const ErrorResponse = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(ErrorResponse, std.heap.page_allocator, body, .{}) catch return error.RemoteFailure;
    defer parsed.deinit();
    if (parsed.value.@"error".len == 0) return error.RemoteFailure;
    return error.RemoteFailure;
}

fn parseCreateResult(allocator: std.mem.Allocator, body: []const u8) !CreateResult {
    const Wire = struct {
        id: []const u8,
        notifyToken: []const u8,
        expiresAt: i64,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    if (!isCanonicalDropId(parsed.value.id)) return error.InvalidResponse;
    const id = try allocator.dupe(u8, parsed.value.id);
    errdefer allocator.free(id);
    const notify_token = try allocator.dupe(u8, parsed.value.notifyToken);
    return .{
        .id = id,
        .notifyToken = notify_token,
        .expiresAt = parsed.value.expiresAt,
    };
}

fn parseMetadata(allocator: std.mem.Allocator, body: []const u8) !Metadata {
    const Wire = struct {
        recipientKeyed: bool,
        recipientPub: []const u8,
        expiresAt: i64,
        viewsLeft: i64,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const recipient_pub = try allocator.dupe(u8, parsed.value.recipientPub);
    return .{
        .recipientKeyed = parsed.value.recipientKeyed,
        .recipientPub = recipient_pub,
        .expiresAt = parsed.value.expiresAt,
        .viewsLeft = parsed.value.viewsLeft,
    };
}

fn parseOpenedSecret(allocator: std.mem.Allocator, body: []const u8) !OpenedSecret {
    const Wire = struct {
        ciphertext: []const u8,
        iv: []const u8,
        ephemeralPub: []const u8,
        recipientKeyed: bool,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const ciphertext = try allocator.dupe(u8, parsed.value.ciphertext);
    errdefer allocator.free(ciphertext);
    const iv = try allocator.dupe(u8, parsed.value.iv);
    errdefer allocator.free(iv);
    const ephemeral_pub = try allocator.dupe(u8, parsed.value.ephemeralPub);
    return .{
        .ciphertext = ciphertext,
        .iv = iv,
        .ephemeralPub = ephemeral_pub,
        .recipientKeyed = parsed.value.recipientKeyed,
    };
}

fn parseInboxKey(allocator: std.mem.Allocator, body: []const u8) ![65]u8 {
    const Wire = struct { publicKey: []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    return parseCanonicalP256Public(parsed.value.publicKey) catch error.InvalidResponse;
}

fn parseInboxItems(allocator: std.mem.Allocator, body: []const u8, limit: u32) ![]InboxItem {
    const WireItem = struct {
        id: []const u8,
        expiresAt: i64,
        viewsLeft: i64,
    };
    const Wire = struct { items: []const WireItem };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value.items.len > limit) return error.InvalidResponse;

    const items = try allocator.alloc(InboxItem, parsed.value.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (parsed.value.items, 0..) |wire, index| {
        if (!isCanonicalDropId(wire.id) or wire.viewsLeft < -1) return error.InvalidResponse;
        items[index] = .{
            .id = try allocator.dupe(u8, wire.id),
            .expiresAt = wire.expiresAt,
            .viewsLeft = wire.viewsLeft,
        };
        initialized += 1;
    }
    return items;
}

fn parseCanonicalP256Public(encoded: []const u8) ![65]u8 {
    // A single base64url form prevents alternate inbox identities for the same P-256 key.
    if (encoded.len != 87) return error.InvalidPublicKey;
    var key: [65]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&key, encoded) catch return error.InvalidPublicKey;
    var canonical: [87]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&canonical, &key);
    if (!std.mem.eql(u8, encoded, &canonical) or key[0] != 0x04) return error.InvalidPublicKey;
    _ = std.crypto.ecc.P256.fromSec1(&key) catch return error.InvalidPublicKey;
    return key;
}

fn isCanonicalInboxProof(encoded: []const u8) bool {
    if (encoded.len != 43) return false;
    var proof: [32]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&proof, encoded) catch return false;
    var canonical: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&canonical, &proof);
    return std.mem.eql(u8, encoded, &canonical);
}

fn validateInboxEndpoint(base_url: []const u8) error{InsecureInboxEndpoint}!void {
    // Inbox proofs require HTTPS outside explicitly local loopback development endpoints.
    const uri = std.Uri.parse(base_url) catch return error.InsecureInboxEndpoint;
    if (std.mem.eql(u8, uri.scheme, "https")) return;
    if (!std.mem.eql(u8, uri.scheme, "http")) return error.InsecureInboxEndpoint;
    const host_component = uri.host orelse return error.InsecureInboxEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buffer) catch return error.InsecureInboxEndpoint;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]")) return;
    if (std.Io.net.IpAddress.parseLiteral(host)) |address| {
        if (address == .ip4 and address.ip4.bytes[0] == 127) return;
    } else |_| {}
    return error.InsecureInboxEndpoint;
}

fn isUnreserved(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn isCanonicalDropId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |byte| {
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

test "create JSON retains recipient public key and encrypted fields" {
    const body = try encodeCreate(std.testing.allocator, .{
        .ciphertext = "ciphertext-value",
        .iv = "nonce-value",
        .ttl = 86400,
        .maxViews = 1,
        .ephemeralPub = "ephemeral-key",
        .recipientPub = "recipient-key",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"recipientPub\":\"recipient-key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ciphertext\":\"ciphertext-value\"") != null);
}

test "URL joining escapes secret identifiers and avoids duplicate slashes" {
    const url = try endpointUrl(std.testing.allocator, "http://127.0.0.1:18080/", "/api/secrets/a b/metadata");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080/api/secrets/a%20b/metadata", url);
}

test "API error JSON maps to a safe generic failure" {
    try std.testing.expectError(error.RemoteFailure, checkErrorResponse(400, "{\"error\":\"ciphertext leaked\"}"));
    try std.testing.expectError(error.RateLimited, checkErrorResponse(429, "{\"error\":\"slow down\"}"));
    try std.testing.expectError(error.RateLimited, checkErrorResponse(429, "not JSON"));
}

test "HTTP client uses the create metadata and open API contract" {
    const test_server = @import("test_server.zig");
    const id = "0123456789abcdef0123456789abcdef";
    const expected = [_]test_server.ExpectedRequest{
        .{
            .method = .POST,
            .target = "/api/secrets",
            .json_body = true,
            .response_status = @enumFromInt(201),
            .response_body = "{\"id\":\"0123456789abcdef0123456789abcdef\",\"notifyToken\":\"notify\",\"expiresAt\":1}",
        },
        .{
            .method = .GET,
            .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata",
            .response_status = .ok,
            .response_body = "{\"recipientKeyed\":true,\"recipientPub\":\"recipient\",\"expiresAt\":1,\"viewsLeft\":1}",
        },
        .{
            .method = .POST,
            .target = "/api/secrets/0123456789abcdef0123456789abcdef/open",
            .response_status = .ok,
            .response_body = "{\"ciphertext\":\"ciphertext\",\"iv\":\"iv\",\"ephemeralPub\":\"ephemeral\",\"recipientKeyed\":true}",
        },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(base_url);
    var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };

    var created = try client.create(.{
        .ciphertext = "ciphertext",
        .iv = "iv",
        .ttl = 86400,
        .maxViews = 1,
        .ephemeralPub = "ephemeral",
        .recipientPub = "recipient",
    });
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(id, created.id);
    var metadata = (try client.metadata(id)).?;
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expect(metadata.recipientKeyed);
    var opened = (try client.open(id)).?;
    defer opened.deinit(std.testing.allocator);
    try std.testing.expect(opened.recipientKeyed);
    try server.deinit();
    server_live = false;
}

test "HTTP client maps missing rate-limited error and capped responses safely" {
    const test_server = @import("test_server.zig");
    const id = "0123456789abcdef0123456789abcdef";
    {
        const expected = [_]test_server.ExpectedRequest{
            .{ .method = .GET, .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata", .response_status = .not_found, .response_body = "{\"error\":\"gone\"}" },
            .{ .method = .POST, .target = "/api/secrets/0123456789abcdef0123456789abcdef/open", .response_status = .not_found, .response_body = "{\"error\":\"gone\"}" },
        };
        var server: test_server.Server = undefined;
        try server.init(std.testing.io, &expected);
        var server_live = true;
        defer if (server_live) server.deinit() catch {};
        const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
        defer std.testing.allocator.free(base_url);
        var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };
        try std.testing.expect((try client.metadata(id)) == null);
        try std.testing.expect((try client.open(id)) == null);
        try server.deinit();
        server_live = false;
    }
    {
        const expected = [_]test_server.ExpectedRequest{
            .{ .method = .GET, .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata", .response_status = .too_many_requests, .response_body = "{\"error\":\"slow down\"}" },
        };
        var server: test_server.Server = undefined;
        try server.init(std.testing.io, &expected);
        var server_live = true;
        defer if (server_live) server.deinit() catch {};
        const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
        defer std.testing.allocator.free(base_url);
        var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };
        try std.testing.expectError(error.RateLimited, client.metadata(id));
        try server.deinit();
        server_live = false;
    }
    {
        const expected = [_]test_server.ExpectedRequest{
            .{ .method = .GET, .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata", .response_status = .bad_request, .response_body = "{\"error\":\"TOKEN=never-print-this\"}" },
        };
        var server: test_server.Server = undefined;
        try server.init(std.testing.io, &expected);
        var server_live = true;
        defer if (server_live) server.deinit() catch {};
        const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
        defer std.testing.allocator.free(base_url);
        var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };
        try std.testing.expectError(error.RemoteFailure, client.metadata(id));
        try server.deinit();
        server_live = false;
    }
    {
        var oversized: [max_response_size + 1]u8 = undefined;
        @memset(&oversized, 'x');
        const expected = [_]test_server.ExpectedRequest{
            .{ .method = .GET, .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata", .response_status = .ok, .response_body = &oversized },
        };
        var server: test_server.Server = undefined;
        try server.init(std.testing.io, &expected);
        var server_live = true;
        defer if (server_live) server.deinit() catch {};
        const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
        defer std.testing.allocator.free(base_url);
        var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };
        try std.testing.expectError(error.ResponseTooLarge, client.metadata(id));
        try server.deinit();
        server_live = false;
    }
}

test "HTTP client rejects redirects without following their location" {
    const test_server = @import("test_server.zig");
    const id = "0123456789abcdef0123456789abcdef";
    var location_header = [_]std.http.Header{.{ .name = "location", .value = undefined }};
    var expected = [_]test_server.ExpectedRequest{
        .{
            .method = .GET,
            .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata",
            .response_status = @enumFromInt(302),
            .response_body = "",
            .response_headers = &location_header,
        },
        .{
            .method = .GET,
            .target = "/follow-up",
            .response_status = .ok,
            .response_body = "{\"recipientKeyed\":true,\"recipientPub\":\"recipient\",\"expiresAt\":1,\"viewsLeft\":1}",
        },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(base_url);
    var location_buffer: [128]u8 = undefined;
    location_header[0].value = try std.fmt.bufPrint(&location_buffer, "{s}/follow-up", .{base_url});
    var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };

    try std.testing.expectError(error.RemoteFailure, client.metadata(id));
    try std.testing.expectError(error.TestServerMissedRequest, server.deinit());
    server_live = false;
}

fn testInboxPublicKey() [65]u8 {
    return std.crypto.ecc.P256.basePoint.toUncompressedSec1();
}

fn testInboxPublicKeyB64() [87]u8 {
    const key = testInboxPublicKey();
    var encoded: [87]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &key);
    return encoded;
}

test "inbox client requests the key and authenticated item endpoint" {
    const test_server = @import("test_server.zig");
    const public_key = testInboxPublicKey();
    const recipient = testInboxPublicKeyB64();
    const proof = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const key_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"publicKey\":\"{s}\"}}", .{&recipient});
    defer std.testing.allocator.free(key_body);
    const inbox_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/api/addresses/{s}/inbox?limit=2&at=1700000000",
        .{&recipient},
    );
    defer std.testing.allocator.free(inbox_target);
    const inbox_headers = [_]std.http.Header{.{ .name = "x-ashdrop-inbox-proof", .value = proof }};
    const expected = [_]test_server.ExpectedRequest{
        .{ .method = .GET, .target = "/api/inbox-key", .response_status = .ok, .response_body = key_body },
        .{
            .method = .GET,
            .target = inbox_target,
            .required_headers = &inbox_headers,
            .response_status = .ok,
            .response_body = "{\"items\":[{\"id\":\"0123456789abcdef0123456789abcdef\",\"expiresAt\":1700003600,\"viewsLeft\":1}]}",
        },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(base_url);
    var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };

    try std.testing.expectEqualSlices(u8, &public_key, &(try client.inboxKey()));
    const items = try client.inbox(&recipient, 2, 1_700_000_000, proof);
    defer deinitInboxItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", items[0].id);
    try std.testing.expectEqual(@as(i64, 1_700_003_600), items[0].expiresAt);
    try std.testing.expectEqual(@as(i64, 1), items[0].viewsLeft);
    try server.deinit();
    server_live = false;
}

test "inbox client rejects a noncanonical server public key" {
    const test_server = @import("test_server.zig");
    var encoded = testInboxPublicKeyB64();
    const alphabet = std.base64.url_safe_alphabet_chars;
    const index = std.mem.indexOfScalar(u8, &alphabet, encoded[encoded.len - 1]).?;
    encoded[encoded.len - 1] = alphabet[index | 1];
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"publicKey\":\"{s}\"}}", .{&encoded});
    defer std.testing.allocator.free(body);
    const expected = [_]test_server.ExpectedRequest{
        .{ .method = .GET, .target = "/api/inbox-key", .response_status = .ok, .response_body = body },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(base_url);
    var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };

    try std.testing.expectError(error.InvalidResponse, client.inboxKey());
    try server.deinit();
    server_live = false;
}

test "inbox client maps authorization rate limits response caps and insecure HTTP" {
    const test_server = @import("test_server.zig");
    const recipient = testInboxPublicKeyB64();
    const proof = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/api/addresses/{s}/inbox?limit=2&at=1700000000",
        .{&recipient},
    );
    defer std.testing.allocator.free(target);
    const inbox_headers = [_]std.http.Header{.{ .name = "x-ashdrop-inbox-proof", .value = proof }};
    var oversized: [max_response_size + 1]u8 = undefined;
    @memset(&oversized, 'x');
    const expected = [_]test_server.ExpectedRequest{
        .{ .method = .GET, .target = target, .required_headers = &inbox_headers, .response_status = .unauthorized, .response_body = "{\"error\":\"do not disclose\"}" },
        .{ .method = .GET, .target = target, .required_headers = &inbox_headers, .response_status = .too_many_requests, .response_body = "{\"error\":\"slow down\"}" },
        .{ .method = .GET, .target = target, .required_headers = &inbox_headers, .response_status = .ok, .response_body = &oversized },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(base_url);
    var client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = base_url };

    try std.testing.expectError(error.InboxUnauthorized, client.inbox(&recipient, 2, 1_700_000_000, proof));
    try std.testing.expectError(error.InboxRateLimited, client.inbox(&recipient, 2, 1_700_000_000, proof));
    try std.testing.expectError(error.ResponseTooLarge, client.inbox(&recipient, 2, 1_700_000_000, proof));
    try server.deinit();
    server_live = false;

    var insecure_client = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .base_url = "http://api.example" };
    try std.testing.expectError(error.InsecureInboxEndpoint, insecure_client.inboxKey());
}

test "inbox client permits every IPv4 loopback address" {
    try validateInboxEndpoint("http://127.0.0.2");
}
