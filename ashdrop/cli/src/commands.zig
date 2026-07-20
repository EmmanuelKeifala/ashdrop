//! Parses share and pull commands and coordinates local files, crypto, links, and the API.

const std = @import("std");
const api = @import("api.zig");
const config = @import("config.zig");
const crypto = @import("crypto.zig");
const files = @import("files.zig");
const identity = @import("identity.zig");
const links = @import("links.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    home_base: std.Io.Dir,
    home: []const u8,
    api_env: ?[]const u8 = null,
    web_env: ?[]const u8 = null,
    inbox_now: ?i64 = null,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const ShareOptions = struct {
    to: []const u8 = "",
    file: []const u8 = "",
    ttl: u64 = 24 * 60 * 60,
    views: u32 = 1,
    api: ?[]const u8 = null,
    web: ?[]const u8 = null,
};

pub const PullOptions = struct {
    drop: []const u8,
    output: []const u8 = ".env.ashdrop",
    force: bool = false,
    api: ?[]const u8 = null,
};

pub const InboxOptions = struct {
    limit: u32 = 20,
    api: ?[]const u8 = null,
};

pub const ResolvedPull = struct {
    options: PullOptions,
    endpoint: []const u8,
    drop: links.DropRef,

    pub fn deinit(self: *ResolvedPull, allocator: std.mem.Allocator) void {
        self.drop.deinit(allocator);
        self.* = undefined;
    }
};

pub const EncodedCreate = struct {
    body: []u8,
};

pub const PullRemote = struct {
    context: ?*anyopaque,
    metadata: *const fn (context: ?*anyopaque, id: []const u8) anyerror!?api.Metadata,
    open: *const fn (context: ?*anyopaque, id: []const u8) anyerror!?api.OpenedSecret,
};

pub fn parseShareArgs(args: []const []const u8) error{Usage}!ShareOptions {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "share")) return error.Usage;

    var to: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var options = ShareOptions{};
    var ttl_set = false;
    var views_set = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--to") or std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "--ttl") or std.mem.eql(u8, arg, "--views") or std.mem.eql(u8, arg, "--api") or std.mem.eql(u8, arg, "--web")) {
            index += 1;
            if (index == args.len or args[index].len == 0) return error.Usage;
            const value = args[index];
            if (std.mem.eql(u8, arg, "--to")) {
                if (to != null) return error.Usage;
                to = value;
            } else if (std.mem.eql(u8, arg, "--file")) {
                if (file != null) return error.Usage;
                file = value;
            } else if (std.mem.eql(u8, arg, "--ttl")) {
                if (ttl_set) return error.Usage;
                options.ttl = parseTtl(value) catch return error.Usage;
                ttl_set = true;
            } else if (std.mem.eql(u8, arg, "--views")) {
                if (views_set) return error.Usage;
                options.views = parseViews(value) catch return error.Usage;
                views_set = true;
            } else if (std.mem.eql(u8, arg, "--api")) {
                if (options.api != null) return error.Usage;
                options.api = value;
            } else {
                if (options.web != null) return error.Usage;
                options.web = value;
            }
            continue;
        }
        return error.Usage;
    }
    return .{
        .to = to orelse return error.Usage,
        .file = file orelse return error.Usage,
        .ttl = options.ttl,
        .views = options.views,
        .api = options.api,
        .web = options.web,
    };
}

pub fn parsePullArgs(args: []const []const u8) error{Usage}!PullOptions {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "pull")) return error.Usage;

    var drop: ?[]const u8 = null;
    var options = PullOptions{ .drop = undefined };
    var output_set = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--force")) {
            if (options.force) return error.Usage;
            options.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "--api")) {
            index += 1;
            if (index == args.len or args[index].len == 0) return error.Usage;
            const value = args[index];
            if (std.mem.eql(u8, arg, "--api")) {
                if (options.api != null) return error.Usage;
                options.api = value;
            } else {
                if (output_set) return error.Usage;
                options.output = value;
                output_set = true;
            }
            continue;
        }
        if (drop != null or std.mem.startsWith(u8, arg, "-")) return error.Usage;
        drop = arg;
    }
    options.drop = drop orelse return error.Usage;
    return options;
}

pub fn parseInboxArgs(args: []const []const u8) error{Usage}!InboxOptions {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "inbox")) return error.Usage;

    var options = InboxOptions{};
    var limit_set = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!std.mem.eql(u8, arg, "--limit") and !std.mem.eql(u8, arg, "--api")) return error.Usage;
        index += 1;
        if (index == args.len or args[index].len == 0) return error.Usage;
        const value = args[index];
        if (std.mem.eql(u8, arg, "--limit")) {
            if (limit_set) return error.Usage;
            options.limit = parseInboxLimit(value) catch return error.Usage;
            limit_set = true;
        } else {
            if (options.api != null) return error.Usage;
            options.api = value;
        }
    }
    return options;
}

pub fn resolvePull(allocator: std.mem.Allocator, args: []const []const u8, api_env: ?[]const u8) !ResolvedPull {
    var options = try parsePullArgs(args);
    var drop = try links.parseDrop(allocator, options.drop);
    errdefer drop.deinit(allocator);
    const endpoint = try config.resolveApi(options.api, api_env, drop.api);
    options.drop = drop.id;
    return .{
        .options = options,
        .endpoint = endpoint,
        .drop = drop,
    };
}

pub fn buildCreateRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    plaintext: []const u8,
    recipient_sec1: [65]u8,
    options: ShareOptions,
) !EncodedCreate {
    var sealed = try crypto.sealForRecipient(allocator, io, plaintext, &recipient_sec1);
    defer sealed.deinit(allocator);
    const body = try api.encodeCreate(allocator, .{
        .ciphertext = sealed.ciphertext,
        .iv = sealed.iv,
        .ttl = options.ttl,
        .maxViews = options.views,
        .ephemeralPub = sealed.ephemeral_pub,
        .recipientPub = &links.formatRawReceive(recipient_sec1),
    });
    errdefer allocator.free(body);
    try files.requireApiBodySize(body);
    return .{ .body = body };
}

pub fn share(args: []const []const u8, runtime: Runtime) !void {
    const options = try parseShareArgs(args);
    var recipient = try links.parseReceive(runtime.allocator, options.to);
    defer recipient.deinit(runtime.allocator);
    const endpoint = try config.resolveApi(options.api, runtime.api_env, recipient.api);
    _ = try config.resolveWeb(options.web, runtime.web_env);

    const plaintext = files.readEnv(runtime.allocator, runtime.io, runtime.cwd, options.file) catch |err| switch (err) {
        error.FileNotFound => return error.InputFileMissing,
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, plaintext);
        runtime.allocator.free(plaintext);
    }
    const encoded = try buildCreateRequest(runtime.allocator, runtime.io, plaintext, recipient.key, options);
    defer runtime.allocator.free(encoded.body);
    var request = try std.json.parseFromSlice(api.CreateInput, runtime.allocator, encoded.body, .{});
    defer request.deinit();

    var client = api.Client{
        .allocator = runtime.allocator,
        .io = runtime.io,
        .base_url = endpoint,
    };
    var result = try client.create(request.value);
    defer result.deinit(runtime.allocator);
    const drop = try links.formatDrop(
        runtime.allocator,
        result.id,
        endpoint,
        config.configuredWeb(options.web, runtime.web_env),
    );
    defer runtime.allocator.free(drop);
    try runtime.stdout.print("{s}\n", .{drop});
}

pub fn pull(args: []const []const u8, runtime: Runtime) !void {
    var target = try resolvePull(runtime.allocator, args, runtime.api_env);
    defer target.deinit(runtime.allocator);
    var client = api.Client{
        .allocator = runtime.allocator,
        .io = runtime.io,
        .base_url = target.endpoint,
    };
    try pullWithRemote(target.options, runtime, .{
        .context = &client,
        .metadata = metadataFromClient,
        .open = openFromClient,
    });
}

pub fn inbox(args: []const []const u8, runtime: Runtime) !void {
    const options = try parseInboxArgs(args);
    const endpoint = try config.resolveApi(options.api, runtime.api_env, null);
    var config_dir = try identity.openConfigDirAt(runtime.io, runtime.home_base, runtime.home);
    defer config_dir.close(runtime.io);
    const local_identity = try identity.load(runtime.allocator, runtime.io, config_dir, "identity.json");
    const recipient = links.formatRawReceive(local_identity.publicSec1());
    var client = api.Client{
        .allocator = runtime.allocator,
        .io = runtime.io,
        .base_url = endpoint,
    };
    const server_key = try client.inboxKey();
    const at = runtime.inbox_now orelse std.Io.Clock.real.now(runtime.io).toSeconds();
    const proof = try crypto.inboxProof(runtime.allocator, &local_identity.d, &server_key, options.limit, at);
    defer {
        std.crypto.secureZero(u8, proof);
        runtime.allocator.free(proof);
    }
    const items = try client.inbox(&recipient, options.limit, at, proof);
    defer api.deinitInboxItems(runtime.allocator, items);

    try runtime.stdout.writeAll("ID\texpiresAt\tviewsLeft\n");
    for (items) |item| {
        try runtime.stdout.print("{s}\t{d}\t{d}\n", .{ item.id, item.expiresAt, item.viewsLeft });
    }
}

pub fn pullWithRemote(options: PullOptions, runtime: Runtime, remote: PullRemote) !void {
    // Validate the destination before opening because a consumed one-view drop cannot be restored.
    var output = files.prepareOutput(runtime.allocator, runtime.io, runtime.cwd, options.output, options.force) catch |err| switch (err) {
        error.OutputExists,
        error.OutputIsDirectory,
        error.UnsafeOutputPath,
        => return err,
        else => return error.OutputPreparationFailed,
    };
    defer output.deinit(runtime.allocator, runtime.io);

    var config_dir = try identity.openConfigDirAt(runtime.io, runtime.home_base, runtime.home);
    defer config_dir.close(runtime.io);
    const local_identity = try identity.load(runtime.allocator, runtime.io, config_dir, "identity.json");
    const local_public = links.formatRawReceive(local_identity.publicSec1());

    // Metadata is non-consuming, so reject a wrong recipient before `open` spends a view.
    var metadata = (try remote.metadata(remote.context, options.drop)) orelse return error.DropUnavailable;
    defer metadata.deinit(runtime.allocator);
    if (!metadata.recipientKeyed or !std.mem.eql(u8, metadata.recipientPub, &local_public)) return error.RecipientMismatch;

    var opened = (try remote.open(remote.context, options.drop)) orelse return error.DropUnavailable;
    defer opened.deinit(runtime.allocator);
    if (!opened.recipientKeyed) return error.InvalidResponse;
    const plaintext = try crypto.openForRecipient(
        runtime.allocator,
        &local_identity.d,
        opened.ciphertext,
        opened.iv,
        opened.ephemeralPub,
    );
    defer {
        std.crypto.secureZero(u8, plaintext);
        runtime.allocator.free(plaintext);
    }
    if (!std.unicode.utf8ValidateSlice(plaintext)) return error.InvalidUtf8;
    // Publish plaintext only after recipient matching, authentication, and content validation succeed.
    files.writeAtomically(runtime.io, &output, plaintext) catch |err| switch (err) {
        error.OutputExists => return err,
        else => return error.OutputWriteFailed,
    };
    try runtime.stderr.print("{s}\n", .{options.output});
}

fn metadataFromClient(context: ?*anyopaque, id: []const u8) anyerror!?api.Metadata {
    const client: *api.Client = @ptrCast(@alignCast(context.?));
    return client.metadata(id);
}

fn openFromClient(context: ?*anyopaque, id: []const u8) anyerror!?api.OpenedSecret {
    const client: *api.Client = @ptrCast(@alignCast(context.?));
    return client.open(id);
}

fn parseTtl(value: []const u8) error{InvalidTtl}!u64 {
    if (std.mem.eql(u8, value, "1h")) return 60 * 60;
    if (std.mem.eql(u8, value, "24h")) return 24 * 60 * 60;
    if (std.mem.eql(u8, value, "7d")) return 7 * 24 * 60 * 60;
    return error.InvalidTtl;
}

fn parseViews(value: []const u8) error{InvalidViews}!u32 {
    if (value.len == 0) return error.InvalidViews;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidViews;
    }
    return std.fmt.parseInt(u32, value, 10) catch error.InvalidViews;
}

fn parseInboxLimit(value: []const u8) error{InvalidInboxLimit}!u32 {
    if (value.len == 0) return error.InvalidInboxLimit;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidInboxLimit;
    }
    const limit = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInboxLimit;
    if (limit == 0 or limit > 100) return error.InvalidInboxLimit;
    return limit;
}

test "share parser accepts defaults and endpoint flags" {
    const args = [_][]const u8{
        "share",
        "--to",
        "recipient",
        "--file",
        ".env",
        "--api",
        "http://127.0.0.1:18080",
        "--web",
        "https://web.example",
    };
    const options = try parseShareArgs(&args);
    try std.testing.expectEqual(@as(u64, 24 * 60 * 60), options.ttl);
    try std.testing.expectEqual(@as(u32, 1), options.views);
    try std.testing.expectEqualStrings("recipient", options.to);
    try std.testing.expectEqualStrings(".env", options.file);
}

test "pull parser accepts default output and force flag" {
    const defaults = [_][]const u8{ "pull", "0123456789abcdef0123456789abcdef" };
    const default_options = try parsePullArgs(&defaults);
    try std.testing.expectEqualStrings(".env.ashdrop", default_options.output);
    try std.testing.expect(!default_options.force);

    const forced = [_][]const u8{ "pull", "0123456789abcdef0123456789abcdef", "-o", "received.env", "--force" };
    const forced_options = try parsePullArgs(&forced);
    try std.testing.expectEqualStrings("received.env", forced_options.output);
    try std.testing.expect(forced_options.force);
}

test "inbox parser accepts defaults limits and API overrides" {
    const defaults = [_][]const u8{"inbox"};
    const default_options = try parseInboxArgs(&defaults);
    try std.testing.expectEqual(@as(u32, 20), default_options.limit);
    try std.testing.expect(default_options.api == null);

    const overridden = [_][]const u8{
        "inbox",
        "--limit",
        "100",
        "--api",
        "https://api.example",
    };
    const options = try parseInboxArgs(&overridden);
    try std.testing.expectEqual(@as(u32, 100), options.limit);
    try std.testing.expectEqualStrings("https://api.example", options.api.?);
}

test "inbox parser rejects invalid limits and repeated flags" {
    const invalid_limits = [_][]const []const u8{
        &.{ "inbox", "--limit", "0" },
        &.{ "inbox", "--limit", "101" },
        &.{ "inbox", "--limit", "nope" },
    };
    for (invalid_limits) |args| {
        try std.testing.expectError(error.Usage, parseInboxArgs(args));
    }

    const repeated_limit = [_][]const u8{ "inbox", "--limit", "2", "--limit", "3" };
    const repeated_api = [_][]const u8{ "inbox", "--api", "https://one.example", "--api", "https://two.example" };
    try std.testing.expectError(error.Usage, parseInboxArgs(&repeated_limit));
    try std.testing.expectError(error.Usage, parseInboxArgs(&repeated_api));
}

test "command parsers reject repeated flags even at default values" {
    const repeated_share = [_][]const u8{
        "share",
        "--to",
        "recipient",
        "--file",
        ".env",
        "--ttl",
        "24h",
        "--ttl",
        "24h",
    };
    try std.testing.expectError(error.Usage, parseShareArgs(&repeated_share));

    const repeated_pull = [_][]const u8{
        "pull",
        "0123456789abcdef0123456789abcdef",
        "--output",
        ".env.ashdrop",
        "-o",
        ".env.ashdrop",
    };
    try std.testing.expectError(error.Usage, parsePullArgs(&repeated_pull));
}

test "share serializes recipientPub and never includes plaintext" {
    const recipient = @import("identity.zig").generate(std.testing.io);
    const request = try buildCreateRequest(
        std.testing.allocator,
        std.testing.io,
        "TOKEN=top-secret\n",
        recipient.publicSec1(),
        .{},
    );
    defer std.testing.allocator.free(request.body);

    try std.testing.expect(std.mem.indexOf(u8, request.body, "recipientPub") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body, "TOKEN=top-secret") == null);
}

const PullSpy = struct {
    metadata_calls: usize = 0,
    open_calls: usize = 0,
    metadata_value: ?api.Metadata = null,
    open_value: ?api.OpenedSecret = null,
    metadata_id: ?[]const u8 = null,
    open_id: ?[]const u8 = null,

    fn metadata(context: ?*anyopaque, id: []const u8) anyerror!?api.Metadata {
        const self: *PullSpy = @ptrCast(@alignCast(context.?));
        self.metadata_calls += 1;
        self.metadata_id = id;
        if (self.metadata_value) |value| {
            self.metadata_value = null;
            return value;
        }
        return null;
    }

    fn open(context: ?*anyopaque, id: []const u8) anyerror!?api.OpenedSecret {
        const self: *PullSpy = @ptrCast(@alignCast(context.?));
        self.open_calls += 1;
        self.open_id = id;
        if (self.open_value) |value| {
            self.open_value = null;
            return value;
        }
        return null;
    }
};

test "existing output fails before metadata or open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.ashdrop", .data = "KEEP=yes\n" });

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var spy = PullSpy{};
    const options = PullOptions{ .drop = "0123456789abcdef0123456789abcdef" };
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expectError(error.OutputExists, pullWithRemote(options, runtime, .{
        .context = &spy,
        .metadata = PullSpy.metadata,
        .open = PullSpy.open,
    }));
    try std.testing.expectEqual(@as(usize, 0), spy.metadata_calls);
    try std.testing.expectEqual(@as(usize, 0), spy.open_calls);
}

test "recipient mismatch never calls open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try @import("identity.zig").openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    _ = try @import("identity.zig").create(std.testing.io, config_dir, "identity.json");

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var spy = PullSpy{ .metadata_value = .{
        .recipientKeyed = true,
        .recipientPub = try std.testing.allocator.dupe(u8, "different-recipient"),
        .expiresAt = 0,
        .viewsLeft = 1,
    } };
    defer if (spy.metadata_value) |*value| value.deinit(std.testing.allocator);
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expectError(error.RecipientMismatch, pullWithRemote(.{
        .drop = "0123456789abcdef0123456789abcdef",
    }, runtime, .{
        .context = &spy,
        .metadata = PullSpy.metadata,
        .open = PullSpy.open,
    }));
    try std.testing.expectEqual(@as(usize, 1), spy.metadata_calls);
    try std.testing.expectEqual(@as(usize, 0), spy.open_calls);
}

test "pull reference resolution uses the parsed drop ID and endpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    _ = try identity.create(std.testing.io, config_dir, "identity.json");
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const id = "0123456789abcdef0123456789abcdef";
    const references = [_]struct {
        input: []const u8,
        expected_endpoint: []const u8,
    }{
        .{
            .input = "https://web.example/s/0123456789abcdef0123456789abcdef",
            .expected_endpoint = "http://env.example",
        },
        .{
            .input = "ashdrop://drop/0123456789abcdef0123456789abcdef?api=http%3A%2F%2Furi.example%3A18080",
            .expected_endpoint = "http://uri.example:18080",
        },
    };

    for (references) |reference| {
        const args = [_][]const u8{ "pull", reference.input };
        var target = try resolvePull(std.testing.allocator, &args, "http://env.example");
        defer target.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(id, target.options.drop);
        try std.testing.expectEqualStrings(reference.expected_endpoint, target.endpoint);
        var spy = PullSpy{};
        try std.testing.expectError(error.DropUnavailable, pullWithRemote(target.options, runtime, .{
            .context = &spy,
            .metadata = PullSpy.metadata,
            .open = PullSpy.open,
        }));
        try std.testing.expectEqualStrings(id, spy.metadata_id.?);
        try std.testing.expectEqual(@as(usize, 0), spy.open_calls);
    }
}

test "invalid decrypted plaintext is never written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    const local_identity = try identity.create(std.testing.io, config_dir, "identity.json");
    const public = links.formatRawReceive(local_identity.publicSec1());
    var sealed = try crypto.sealForRecipient(std.testing.allocator, std.testing.io, &[_]u8{ 0xff, 0xfe }, &local_identity.publicSec1());

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var spy = PullSpy{
        .metadata_value = .{
            .recipientKeyed = true,
            .recipientPub = try std.testing.allocator.dupe(u8, &public),
            .expiresAt = 0,
            .viewsLeft = 1,
        },
        .open_value = .{
            .ciphertext = sealed.ciphertext,
            .iv = sealed.iv,
            .ephemeralPub = sealed.ephemeral_pub,
            .recipientKeyed = true,
        },
    };
    sealed = undefined;
    defer if (spy.metadata_value) |*value| value.deinit(std.testing.allocator);
    defer if (spy.open_value) |*value| value.deinit(std.testing.allocator);
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expectError(error.InvalidUtf8, pullWithRemote(.{
        .drop = "0123456789abcdef0123456789abcdef",
    }, runtime, .{
        .context = &spy,
        .metadata = PullSpy.metadata,
        .open = PullSpy.open,
    }));
    try std.testing.expectEqual(@as(usize, 1), spy.open_calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".env.ashdrop", .{}));
}

test "forced directory output fails before metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".env.ashdrop", @enumFromInt(0o700));
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    _ = try identity.create(std.testing.io, config_dir, "identity.json");

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var spy = PullSpy{};
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expectError(error.OutputIsDirectory, pullWithRemote(.{
        .drop = "0123456789abcdef0123456789abcdef",
        .force = true,
    }, runtime, .{
        .context = &spy,
        .metadata = PullSpy.metadata,
        .open = PullSpy.open,
    }));
    try std.testing.expectEqual(@as(usize, 0), spy.metadata_calls);
    try std.testing.expectEqual(@as(usize, 0), spy.open_calls);
}

test "intermediate output symlink fails before metadata and leaves target unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "safe", @enumFromInt(0o700));
    try tmp.dir.createDir(std.testing.io, "target", @enumFromInt(0o700));
    try tmp.dir.createDir(std.testing.io, "target/subdir", @enumFromInt(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target/subdir/.env.ashdrop", .data = "KEEP=yes\n" });
    try tmp.dir.symLink(std.testing.io, "../target", "safe/link", .{ .is_directory = true });
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    _ = try identity.create(std.testing.io, config_dir, "identity.json");

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var spy = PullSpy{};
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expectError(error.UnsafeOutputPath, pullWithRemote(.{
        .drop = "0123456789abcdef0123456789abcdef",
        .output = "safe/link/subdir/.env.ashdrop",
    }, runtime, .{
        .context = &spy,
        .metadata = PullSpy.metadata,
        .open = PullSpy.open,
    }));
    try std.testing.expectEqual(@as(usize, 0), spy.metadata_calls);
    try std.testing.expectEqual(@as(usize, 0), spy.open_calls);
    var content: [64]u8 = undefined;
    try std.testing.expectEqualStrings("KEEP=yes\n", try tmp.dir.readFile(std.testing.io, "target/subdir/.env.ashdrop", &content));
}

test "share and pull keep plaintext out of command streams" {
    const test_server = @import("test_server.zig");
    const source = "TOKEN=stream-secret\n";
    const id = "0123456789abcdef0123456789abcdef";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    const local_identity = try identity.create(std.testing.io, config_dir, "identity.json");
    const local_public = links.formatRawReceive(local_identity.publicSec1());
    var sealed = try crypto.sealForRecipient(std.testing.allocator, std.testing.io, source, &local_identity.publicSec1());
    defer sealed.deinit(std.testing.allocator);
    const metadata_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"recipientKeyed\":true,\"recipientPub\":\"{s}\",\"expiresAt\":1,\"viewsLeft\":1}}",
        .{&local_public},
    );
    defer std.testing.allocator.free(metadata_body);
    const opened_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"ciphertext\":\"{s}\",\"iv\":\"{s}\",\"ephemeralPub\":\"{s}\",\"recipientKeyed\":true}}",
        .{ sealed.ciphertext, sealed.iv, sealed.ephemeral_pub },
    );
    defer std.testing.allocator.free(opened_body);
    const expected = [_]test_server.ExpectedRequest{
        .{ .method = .POST, .target = "/api/secrets", .json_body = true, .response_status = @enumFromInt(201), .response_body = "{\"id\":\"0123456789abcdef0123456789abcdef\",\"notifyToken\":\"notify\",\"expiresAt\":1}" },
        .{ .method = .GET, .target = "/api/secrets/0123456789abcdef0123456789abcdef/metadata", .response_status = .ok, .response_body = metadata_body },
        .{ .method = .POST, .target = "/api/secrets/0123456789abcdef0123456789abcdef/open", .response_status = .ok, .response_body = opened_body },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const api_env = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(api_env);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.env", .data = source });
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = Runtime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = tmp.dir,
        .home_base = tmp.dir,
        .home = "home",
        .api_env = api_env,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const share_args = [_][]const u8{ "share", "--to", &local_public, "--file", "source.env" };
    try share(&share_args, runtime);
    const drop = std.mem.trimEnd(u8, stdout.written(), "\n");
    var parsed_drop = try links.parseDrop(std.testing.allocator, drop);
    defer parsed_drop.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(id, parsed_drop.id);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), source) == null);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);

    const pull_args = [_][]const u8{ "pull", drop, "--output", "received.env" };
    try pull(&pull_args, runtime);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), source) == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), source) == null);
    try std.testing.expectEqualStrings("received.env\n", stderr.written());
    var received: [128]u8 = undefined;
    try std.testing.expectEqualStrings(source, try tmp.dir.readFile(std.testing.io, "received.env", &received));
    try server.deinit();
    server_live = false;
}
