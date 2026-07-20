//! Defines the Ashdrop command-line entry point, dispatch, diagnostics, and address command.

const std = @import("std");
const config = @import("config.zig");
const commands = @import("commands.zig");
const crypto = @import("crypto.zig");
const identity = @import("identity.zig");
const links = @import("links.zig");

const AddressOptions = struct {
    create: bool = false,
    raw: bool = false,
    api: ?[]const u8 = null,
    web: ?[]const u8 = null,
};

const AddressRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home_base: std.Io.Dir,
    home: []const u8,
    api_env: ?[]const u8 = null,
    web_env: ?[]const u8 = null,
    inbox_now: ?i64 = null,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        const status = writeFailure(&stderr.interface, error.CommandFailed);
        return finishCommand(status, &stdout.interface, &stderr.interface);
    };
    const home = init.environ_map.get("HOME") orelse {
        const status = writeFailure(&stderr.interface, error.HomeMissing);
        return finishCommand(status, &stdout.interface, &stderr.interface);
    };
    const status = runCommand(args[1..], .{
        .allocator = init.gpa,
        .io = init.io,
        .home_base = std.Io.Dir.cwd(),
        .home = home,
        .api_env = init.environ_map.get("ASHDROP_API_URL"),
        .web_env = init.environ_map.get("ASHDROP_WEB_URL"),
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
    });
    return finishCommand(status, &stdout.interface, &stderr.interface);
}

fn runCommand(args: anytype, runtime: AddressRuntime) u8 {
    if (args.len == 0) return writeFailure(runtime.stderr, error.Usage);
    const command: []const u8 = args[0];
    if (std.mem.eql(u8, command, "address")) return runAddress(args, runtime);
    if (std.mem.eql(u8, command, "share")) return runShare(args, runtime);
    if (std.mem.eql(u8, command, "pull")) return runPull(args, runtime);
    if (std.mem.eql(u8, command, "inbox")) return runInbox(args, runtime);
    return writeFailure(runtime.stderr, error.Usage);
}

fn runShare(args: []const []const u8, runtime: AddressRuntime) u8 {
    commands.share(args, commandRuntime(runtime)) catch |err| return writeFailure(runtime.stderr, err);
    return 0;
}

fn runPull(args: []const []const u8, runtime: AddressRuntime) u8 {
    commands.pull(args, commandRuntime(runtime)) catch |err| return writeFailure(runtime.stderr, err);
    return 0;
}

fn runInbox(args: []const []const u8, runtime: AddressRuntime) u8 {
    commands.inbox(args, commandRuntime(runtime)) catch |err| return writeFailure(runtime.stderr, err);
    return 0;
}

fn commandRuntime(runtime: AddressRuntime) commands.Runtime {
    return .{
        .allocator = runtime.allocator,
        .io = runtime.io,
        .cwd = std.Io.Dir.cwd(),
        .home_base = runtime.home_base,
        .home = runtime.home,
        .api_env = runtime.api_env,
        .web_env = runtime.web_env,
        .inbox_now = runtime.inbox_now,
        .stdout = runtime.stdout,
        .stderr = runtime.stderr,
    };
}

fn runAddress(args: anytype, runtime: AddressRuntime) u8 {
    const options = parseAddressArgs(args) catch |err| return writeFailure(runtime.stderr, err);
    const api = config.resolveApi(options.api, runtime.api_env, null) catch |err| return writeFailure(runtime.stderr, err);
    _ = config.resolveWeb(options.web, runtime.web_env) catch |err| return writeFailure(runtime.stderr, err);
    const configured_web = config.configuredWeb(options.web, runtime.web_env);

    var config_dir = identity.openConfigDirAt(runtime.io, runtime.home_base, runtime.home) catch |err| return writeFailure(runtime.stderr, err);
    defer config_dir.close(runtime.io);
    const local_identity = if (options.create)
        identity.create(runtime.io, config_dir, "identity.json")
    else
        identity.load(runtime.allocator, runtime.io, config_dir, "identity.json");
    const loaded = local_identity catch |err| return writeFailure(runtime.stderr, err);
    const public = loaded.publicSec1();

    if (options.raw) {
        const raw = links.formatRawReceive(public);
        runtime.stdout.print("{s}\n", .{&raw}) catch |err| return writeFailure(runtime.stderr, err);
        return 0;
    }

    const receive_url = links.formatReceive(runtime.allocator, public, api, configured_web) catch |err| return writeFailure(runtime.stderr, err);
    defer runtime.allocator.free(receive_url);
    runtime.stdout.print("{s}\n", .{receive_url}) catch |err| return writeFailure(runtime.stderr, err);
    return 0;
}

fn writeFailure(stderr: *std.Io.Writer, err: anyerror) u8 {
    const status: u8 = switch (err) {
        error.Usage,
        error.InvalidEndpoint,
        error.InsecureInboxEndpoint,
        error.HomeMissing,
        error.InvalidHomePath,
        error.IdentityAlreadyExists,
        error.FileNotFound,
        error.InvalidIdentity,
        error.IdentityMissing,
        error.InvalidReceiveReference,
        error.InvalidDropReference,
        error.InvalidOutputPath,
        => 2,
        else => 1,
    };
    const message = switch (err) {
        error.Usage => "usage: ashdrop <address|share|pull|inbox> [options]\n",
        error.InvalidEndpoint, error.InsecureInboxEndpoint => "ashdrop: invalid API or web endpoint\n",
        error.HomeMissing => "ashdrop: HOME is not set\n",
        error.InvalidHomePath => "ashdrop: HOME is invalid\n",
        error.IdentityAlreadyExists => "ashdrop: receive identity already exists\n",
        error.FileNotFound, error.IdentityMissing => "ashdrop: receive identity does not exist; run `ashdrop address create`\n",
        error.InvalidIdentity => "ashdrop: stored receive identity is invalid\n",
        error.InvalidReceiveReference => "ashdrop: invalid receive address\n",
        error.InvalidDropReference => "ashdrop: invalid drop reference\n",
        error.InvalidOutputPath => "ashdrop: invalid output path\n",
        error.OutputIsDirectory => "ashdrop: output path is a directory\n",
        error.OutputExists => "ashdrop: output file already exists; use --force to replace it\n",
        error.UnsafeOutputPath => "ashdrop: output path must not be a symlink\n",
        error.OutputPreparationFailed => "ashdrop: could not prepare output path\n",
        error.OutputWriteFailed => "ashdrop: could not write output file\n",
        error.FileTooLarge => "ashdrop: input file is too large\n",
        error.InputFileMissing => "ashdrop: input file does not exist\n",
        error.InvalidUtf8 => "ashdrop: input file is not valid UTF-8\n",
        error.RequestTooLarge => "ashdrop: encrypted request is too large\n",
        error.RateLimited => "ashdrop: request was rate limited\n",
        error.DropUnavailable => "ashdrop: drop no longer exists\n",
        error.RecipientMismatch => "ashdrop: drop is for a different receive identity\n",
        error.InboxUnauthorized,
        error.InboxRateLimited,
        error.RemoteFailure,
        error.ResponseTooLarge,
        error.InvalidResponse,
        => "ashdrop: API request failed\n",
        else => "ashdrop: command failed\n",
    };
    stderr.writeAll(message) catch {};
    return status;
}

fn finishCommand(status: u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    const stdout_failed = blk: {
        stdout.flush() catch break :blk true;
        break :blk false;
    };
    const stderr_failed = blk: {
        stderr.flush() catch break :blk true;
        break :blk false;
    };
    if (status == 0 and (stdout_failed or stderr_failed)) return 1;
    return status;
}

fn parseAddressArgs(args: anytype) error{Usage}!AddressOptions {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "address")) return error.Usage;

    var options = AddressOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "create")) {
            if (options.create) return error.Usage;
            options.create = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            if (options.raw) return error.Usage;
            options.raw = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--api") or std.mem.eql(u8, arg, "--web")) {
            index += 1;
            if (index == args.len) return error.Usage;
            const value: []const u8 = args[index];
            if (std.mem.eql(u8, arg, "--api")) {
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

    if (options.create and options.raw) return error.Usage;
    return options;
}

test {
    _ = @import("config.zig");
    _ = @import("crypto_test.zig");
    _ = @import("links.zig");
    _ = @import("identity.zig");
}

test "address parser accepts create with endpoint overrides" {
    const args = [_][]const u8{
        "address",
        "create",
        "--api",
        "https://api.example",
        "--web",
        "https://web.example",
    };
    const options = try parseAddressArgs(&args);
    try std.testing.expect(options.create);
    try std.testing.expectEqualStrings("https://api.example", options.api.?);
    try std.testing.expectEqualStrings("https://web.example", options.web.?);
}

test "address parser accepts raw output only for an existing address" {
    const args = [_][]const u8{ "address", "--raw" };
    const options = try parseAddressArgs(&args);
    try std.testing.expect(options.raw);
    try std.testing.expect(!options.create);
}

test "address parser rejects unsupported commands and conflicting modes" {
    const unsupported = [_][]const u8{"share"};
    const conflicting = [_][]const u8{ "address", "create", "--raw" };
    try std.testing.expectError(error.Usage, parseAddressArgs(&unsupported));
    try std.testing.expectError(error.Usage, parseAddressArgs(&conflicting));
}

test "address commands keep output streams separate and repair modes under umask" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const previous_umask = std.c.umask(0o777);
    defer _ = std.c.umask(previous_umask);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    const create = [_][]const u8{ "address", "create" };
    try std.testing.expectEqual(@as(u8, 0), runAddress(&create, runtime));
    try std.testing.expect(std.mem.startsWith(u8, stdout.written(), config.managed_web ++ "/drop-for/"));
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);

    const created = try std.testing.allocator.dupe(u8, stdout.written());
    defer std.testing.allocator.free(created);
    stdout.clearRetainingCapacity();
    var config_dir = try tmp.dir.openDir(std.testing.io, "home/.config/ashdrop", .{ .iterate = true });
    try config_dir.setPermissions(std.testing.io, @enumFromInt(0o755));
    try config_dir.setFilePermissions(std.testing.io, "identity.json", @enumFromInt(0o644), .{});
    config_dir.close(std.testing.io);
    const show = [_][]const u8{"address"};
    try std.testing.expectEqual(@as(u8, 0), runAddress(&show, runtime));
    try std.testing.expectEqualSlices(u8, created, stdout.written());
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);

    stdout.clearRetainingCapacity();
    const raw = [_][]const u8{ "address", "--raw" };
    try std.testing.expectEqual(@as(u8, 0), runAddress(&raw, runtime));
    try std.testing.expectEqual(@as(usize, 88), stdout.written().len);
    try std.testing.expectEqual(@as(u8, '\n'), stdout.written()[87]);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
    const before_duplicate = try std.testing.allocator.dupe(u8, stdout.written());
    defer std.testing.allocator.free(before_duplicate);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), runAddress(&create, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "already exists") != null);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), runAddress(&raw, runtime));
    try std.testing.expectEqualSlices(u8, before_duplicate, stdout.written());
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);

    config_dir = try tmp.dir.openDir(std.testing.io, "home/.config/ashdrop", .{ .iterate = true });
    defer config_dir.close(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try config_dir.stat(std.testing.io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try config_dir.statFile(std.testing.io, "identity.json", .{})).permissions.toMode() & 0o777);
}

test "share and pull malformed commands report standard usage on stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    const share = [_][]const u8{"share"};
    try std.testing.expectEqual(@as(u8, 2), runCommand(&share, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("usage: ashdrop <address|share|pull|inbox> [options]\n", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    const pull = [_][]const u8{"pull"};
    try std.testing.expectEqual(@as(u8, 2), runCommand(&pull, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("usage: ashdrop <address|share|pull|inbox> [options]\n", stderr.written());
}

test "inbox command prints only item metadata" {
    const test_server = @import("test_server.zig");
    const at = 1_700_000_000;
    const plaintext = "TOKEN=never-print-this\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    const local_identity = try identity.create(std.testing.io, config_dir, "identity.json");
    const recipient = links.formatRawReceive(local_identity.publicSec1());
    const server_public = std.crypto.ecc.P256.basePoint.toUncompressedSec1();
    const server_key = links.formatRawReceive(server_public);
    const proof = try crypto.inboxProof(std.testing.allocator, &local_identity.d, &server_public, 2, at);
    defer {
        std.crypto.secureZero(u8, proof);
        std.testing.allocator.free(proof);
    }
    const key_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"publicKey\":\"{s}\"}}", .{&server_key});
    defer std.testing.allocator.free(key_body);
    const inbox_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/api/addresses/{s}/inbox?limit=2&at={d}",
        .{ &recipient, at },
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
    const api_env = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(api_env);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .api_env = api_env,
        .inbox_now = at,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const args = [_][]const u8{ "inbox", "--limit", "2" };

    try std.testing.expectEqual(@as(u8, 0), runCommand(&args, runtime));
    try std.testing.expectEqualStrings("ID\texpiresAt\tviewsLeft\n0123456789abcdef0123456789abcdef\t1700003600\t1\n", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), plaintext) == null);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
    try server.deinit();
    server_live = false;
}

test "inbox missing identity reports status 2 on stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const args = [_][]const u8{"inbox"};

    try std.testing.expectEqual(@as(u8, 2), runCommand(&args, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: receive identity does not exist; run `ashdrop address create`\n", stderr.written());
}

test "inbox unauthorized responses are generic operational failures" {
    const test_server = @import("test_server.zig");
    const at = 1_700_000_000;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    const local_identity = try identity.create(std.testing.io, config_dir, "identity.json");
    const recipient = links.formatRawReceive(local_identity.publicSec1());
    const server_public = std.crypto.ecc.P256.basePoint.toUncompressedSec1();
    const server_key = links.formatRawReceive(server_public);
    const proof = try crypto.inboxProof(std.testing.allocator, &local_identity.d, &server_public, 20, at);
    defer {
        std.crypto.secureZero(u8, proof);
        std.testing.allocator.free(proof);
    }
    const key_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"publicKey\":\"{s}\"}}", .{&server_key});
    defer std.testing.allocator.free(key_body);
    const inbox_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/api/addresses/{s}/inbox?limit=20&at={d}",
        .{ &recipient, at },
    );
    defer std.testing.allocator.free(inbox_target);
    const inbox_headers = [_]std.http.Header{.{ .name = "x-ashdrop-inbox-proof", .value = proof }};
    const expected = [_]test_server.ExpectedRequest{
        .{ .method = .GET, .target = "/api/inbox-key", .response_status = .ok, .response_body = key_body },
        .{
            .method = .GET,
            .target = inbox_target,
            .required_headers = &inbox_headers,
            .response_status = .unauthorized,
            .response_body = "{\"error\":\"inbox is not available\"}",
        },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const api_env = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(api_env);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .api_env = api_env,
        .inbox_now = at,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const args = [_][]const u8{"inbox"};

    try std.testing.expectEqual(@as(u8, 1), runCommand(&args, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: API request failed\n", stderr.written());
    try server.deinit();
    server_live = false;
}

test "address missing identity reports status 2 on stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    const address = [_][]const u8{"address"};
    try std.testing.expectEqual(@as(u8, 2), runCommand(&address, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: receive identity does not exist; run `ashdrop address create`\n", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    const raw = [_][]const u8{ "address", "--raw" };
    try std.testing.expectEqual(@as(u8, 2), runCommand(&raw, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: receive identity does not exist; run `ashdrop address create`\n", stderr.written());
}

test "share source-file failures are operational errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const raw = links.formatRawReceive(std.crypto.ecc.P256.basePoint.toUncompressedSec1());
    const share = [_][]const u8{ "share", "--to", &raw, "--file", "missing.env" };

    try std.testing.expectEqual(@as(u8, 1), runCommand(&share, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: input file does not exist\n", stderr.written());
}

test "invalid create response ID is an operational API failure" {
    const test_server = @import("test_server.zig");
    const expected = [_]test_server.ExpectedRequest{
        .{
            .method = .POST,
            .target = "/api/secrets",
            .json_body = true,
            .response_status = @enumFromInt(201),
            .response_body = "{\"id\":\"INVALID\",\"notifyToken\":\"notify\",\"expiresAt\":1}",
        },
    };
    var server: test_server.Server = undefined;
    try server.init(std.testing.io, &expected);
    var server_live = true;
    defer if (server_live) server.deinit() catch {};
    const api_env = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{server.port()});
    defer std.testing.allocator.free(api_env);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.env", .data = "TOKEN=never-print\n" });
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var source_path_buffer: [4096]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buffer, "{s}/source.env", .{path_buffer[0..path_len]});
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .api_env = api_env,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const recipient = links.formatRawReceive(std.crypto.ecc.P256.basePoint.toUncompressedSec1());
    const args = [_][]const u8{ "share", "--to", &recipient, "--file", source_path };

    try std.testing.expectEqual(@as(u8, 1), runCommand(&args, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: API request failed\n", stderr.written());
    try server.deinit();
    server_live = false;
}

test "directory output failures are operational errors" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 1), writeFailure(&stderr.writer, error.OutputIsDirectory));
    try std.testing.expectEqualStrings("ashdrop: output path is a directory\n", stderr.written());
}

test "output preparation and write failures use output diagnostics" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 1), writeFailure(&stderr.writer, error.OutputPreparationFailed));
    try std.testing.expectEqualStrings("ashdrop: could not prepare output path\n", stderr.written());
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), writeFailure(&stderr.writer, error.OutputWriteFailed));
    try std.testing.expectEqualStrings("ashdrop: could not write output file\n", stderr.written());
}

test "missing pull output parent is an output error, not an identity error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var dir_path: [4096]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_path);
    var output_path: [4096]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_path, "{s}/missing/.env.ashdrop", .{dir_path[0..dir_len]});
    const args = [_][]const u8{ "pull", "0123456789abcdef0123456789abcdef", "--output", output };

    try std.testing.expectEqual(@as(u8, 1), runCommand(&args, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: could not prepare output path\n", stderr.written());
}

test "address invalid identity and configuration report status 2 on stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    var config_dir = try identity.openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    try config_dir.writeFile(std.testing.io, .{ .sub_path = "identity.json", .data = "{}" });
    const address = [_][]const u8{"address"};
    try std.testing.expectEqual(@as(u8, 2), runCommand(&address, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: stored receive identity is invalid\n", stderr.written());

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    const invalid_api = [_][]const u8{ "address", "--api", "invalid" };
    try std.testing.expectEqual(@as(u8, 2), runCommand(&invalid_api, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: invalid API or web endpoint\n", stderr.written());
}

const FlushFailingWriter = struct {
    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        return error.WriteFailed;
    }

    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {
        return error.WriteFailed;
    }
};

test "invalid endpoint prevents address creation before identity persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    const create = [_][]const u8{ "address", "create", "--api", "https://:443" };
    try std.testing.expectEqual(@as(u8, 2), runCommand(&create, runtime));
    try std.testing.expectEqual(@as(usize, 0), stdout.written().len);
    try std.testing.expectEqualStrings("ashdrop: invalid API or web endpoint\n", stderr.written());
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "home/.config/ashdrop/identity.json", .{}),
    );
}

test "flush failure changes successful command status to 1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output_buffer: [256]u8 = undefined;
    var stdout = std.Io.Writer{ .vtable = &FlushFailingWriter.vtable, .buffer = &output_buffer };
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    const runtime = AddressRuntime{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home_base = tmp.dir,
        .home = "home",
        .stdout = &stdout,
        .stderr = &stderr.writer,
    };

    const create = [_][]const u8{ "address", "create" };
    try std.testing.expectEqual(@as(u8, 0), runCommand(&create, runtime));
    try std.testing.expectEqual(@as(u8, 1), finishCommand(0, &stdout, &stderr.writer));
    try std.testing.expectEqual(@as(u8, 2), finishCommand(2, &stdout, &stderr.writer));
}
