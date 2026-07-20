//! Resolves and validates managed, environment, embedded, and explicit Ashdrop endpoints.

const std = @import("std");

pub const managed_api = "https://ashdrop.onrender.com";
pub const managed_web = "https://ashdrop.vercel.app";

pub fn resolveApi(flag: ?[]const u8, env: ?[]const u8, embedded: ?[]const u8) error{InvalidEndpoint}![]const u8 {
    // A caller can override an embedded self-hosted endpoint without rewriting a received link.
    return validateEndpoint(flag orelse embedded orelse env orelse managed_api);
}

pub fn resolveWeb(flag: ?[]const u8, env: ?[]const u8) error{InvalidEndpoint}![]const u8 {
    return validateEndpoint(flag orelse env orelse managed_web);
}

pub fn configuredWeb(flag: ?[]const u8, env: ?[]const u8) ?[]const u8 {
    return flag orelse env;
}

fn validateEndpoint(endpoint: []const u8) error{InvalidEndpoint}![]const u8 {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidEndpoint;

    const host = uri.host orelse return error.InvalidEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const raw_host = host.toRaw(&host_buffer) catch return error.InvalidEndpoint;
    // IP literals are valid endpoints even though they are not DNS host names.
    std.Io.net.HostName.validate(raw_host) catch {
        _ = std.Io.net.IpAddress.parseLiteral(raw_host) catch return error.InvalidEndpoint;
    };
    return endpoint;
}

test "ordinary API references prefer explicit flag then environment" {
    try std.testing.expectEqualStrings(
        "https://flag.example",
        try resolveApi("https://flag.example", "https://env.example", null),
    );
    try std.testing.expectEqualStrings(
        "https://env.example",
        try resolveApi(null, "https://env.example", null),
    );
    try std.testing.expectEqualStrings(managed_api, try resolveApi(null, null, null));
}

test "managed endpoints use deployed https services" {
    try std.testing.expectEqualStrings("https://ashdrop.onrender.com", managed_api);
    try std.testing.expectEqualStrings("https://ashdrop.vercel.app", managed_web);
}

test "web endpoint resolves independently" {
    try std.testing.expectEqualStrings(
        "https://flag-web.example",
        try resolveWeb("https://flag-web.example", "https://env-web.example"),
    );
    try std.testing.expectEqualStrings(
        "https://env-web.example",
        try resolveWeb(null, "https://env-web.example"),
    );
    try std.testing.expectEqualStrings(managed_web, try resolveWeb(null, null));
}

test "endpoint configuration rejects a URL without a host" {
    try std.testing.expectError(error.InvalidEndpoint, resolveApi("https:///missing-host", null, null));
    try std.testing.expectError(error.InvalidEndpoint, resolveWeb("http:///missing-host", null));
}

test "endpoint configuration rejects malformed authorities and unsupported schemes" {
    const invalid = [_][]const u8{
        "https://:443",
        "https://[::1",
        "https://example.com:bad",
        "ftp://example.com",
    };
    for (invalid) |endpoint| {
        try std.testing.expectError(error.InvalidEndpoint, resolveApi(endpoint, null, null));
        try std.testing.expectError(error.InvalidEndpoint, resolveWeb(endpoint, null));
    }
}

test "endpoint configuration accepts http and https localhost bases" {
    try std.testing.expectEqualStrings("https://localhost", try resolveApi("https://localhost", null, null));
    try std.testing.expectEqualStrings("http://localhost:8080", try resolveWeb("http://localhost:8080", null));
}
