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

    const Response = struct {
        status: u16,
        body: []u8,
    };

    fn request(self: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Response {
        const url = try endpointUrl(self.allocator, self.base_url, path);
        defer self.allocator.free(url);

        var response_buffer: [max_response_size]u8 = undefined;
        var response_writer = std.Io.Writer.fixed(&response_buffer);
        var http_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer http_client.deinit();
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };
        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .redirect_behavior = .not_allowed,
            .extra_headers = &headers,
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
