//! Creates, validates, and securely persists the local P-256 receive identity.

const std = @import("std");

pub const Identity = struct {
    d: [32]u8,
    x: [32]u8,
    y: [32]u8,

    pub fn publicSec1(self: Identity) [65]u8 {
        var out: [65]u8 = undefined;
        out[0] = 0x04;
        @memcpy(out[1..33], &self.x);
        @memcpy(out[33..65], &self.y);
        return out;
    }
};

const StoredIdentity = struct {
    version: u8,
    kty: []const u8,
    crv: []const u8,
    x: []const u8,
    y: []const u8,
    d: []const u8,
};

pub fn generate(io: std.Io) Identity {
    const d = std.crypto.ecc.P256.scalar.random(io, .big);
    return derive(d) catch unreachable;
}

pub fn create(io: std.Io, dir: std.Io.Dir, filename: []const u8) !Identity {
    const identity = generate(io);
    try save(io, dir, filename, identity);
    return identity;
}

pub fn save(io: std.Io, dir: std.Io.Dir, filename: []const u8, identity: Identity) !void {
    try validate(identity);

    const d = encodeCoordinate(identity.d);
    const x = encodeCoordinate(identity.x);
    const y = encodeCoordinate(identity.y);
    var json_buffer: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buffer,
        "{{\"version\":1,\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"{s}\",\"y\":\"{s}\",\"d\":\"{s}\"}}\n",
        .{ &x, &y, &d },
    );

    var file = dir.createFile(io, filename, .{
        .exclusive = true,
        .permissions = filePermissions(),
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.IdentityAlreadyExists,
        else => |cause| return cause,
    };
    errdefer {
        file.close(io);
        dir.deleteFile(io, filename) catch {};
    }
    try file.setPermissions(io, filePermissions());
    try file.writeStreamingAll(io, json);
    try file.sync(io);
    file.close(io);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) !Identity {
    var file = try dir.openFile(io, filename, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    try file.setPermissions(io, filePermissions());
    var buffer: [512]u8 = undefined;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    const json = buffer[0..n];
    if (json.len == buffer.len) return error.InvalidIdentity;

    var parsed = std.json.parseFromSlice(StoredIdentity, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidIdentity,
    };
    defer parsed.deinit();
    const stored = parsed.value;
    if (stored.version != 1 or !std.mem.eql(u8, stored.kty, "EC") or !std.mem.eql(u8, stored.crv, "P-256")) {
        return error.InvalidIdentity;
    }

    const identity = Identity{
        .d = decodeCoordinate(stored.d) catch return error.InvalidIdentity,
        .x = decodeCoordinate(stored.x) catch return error.InvalidIdentity,
        .y = decodeCoordinate(stored.y) catch return error.InvalidIdentity,
    };
    try validate(identity);
    return identity;
}

pub fn openConfigDir(io: std.Io, home: []const u8) !std.Io.Dir {
    return openConfigDirAt(io, std.Io.Dir.cwd(), home);
}

pub fn openConfigDirAt(io: std.Io, home_base: std.Io.Dir, home_path: []const u8) !std.Io.Dir {
    var home_dir = try openSecurePath(io, home_base, home_path, false);
    defer home_dir.close(io);
    var config_dir = try openSecurePath(io, home_dir, ".config", false);
    defer config_dir.close(io);
    return openSecurePath(io, config_dir, "ashdrop", true);
}

fn openSecurePath(io: std.Io, base: std.Io.Dir, path: []const u8, enforce_final_mode: bool) !std.Io.Dir {
    if (path.len == 0) return error.InvalidHomePath;

    // Identity storage is a security boundary: traversal and symlinked components are never followed.
    var current = base;
    var owns_current = false;
    var start: usize = 0;
    if (std.Io.Dir.path.isAbsolute(path)) {
        current = try std.Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true });
        owns_current = true;
        while (start < path.len and path[start] == '/') : (start += 1) {}
    }
    errdefer if (owns_current) current.close(io);

    var saw_component = false;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const component = path[start..end];
        start = end + @intFromBool(end < path.len);
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidHomePath;
        saw_component = true;

        var next_start = start;
        while (next_start < path.len and path[next_start] == '/') : (next_start += 1) {}
        const is_final = next_start == path.len;
        const created = blk: {
            current.createDir(io, component, directoryPermissions()) catch |err| switch (err) {
                error.PathAlreadyExists => break :blk false,
                else => |cause| return cause,
            };
            break :blk true;
        };
        if (created) {
            // `mkdir` honors umask, so restore private permissions before this directory can hold keys.
            try current.setFilePermissions(io, component, directoryPermissions(), .{ .follow_symlinks = false });
        }

        var next = try current.openDir(io, component, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer next.close(io);
        if (created or (enforce_final_mode and is_final)) {
            try next.setPermissions(io, directoryPermissions());
        }
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }

    if (!saw_component) return error.InvalidHomePath;
    return current;
}

fn directoryPermissions() std.Io.Dir.Permissions {
    return @enumFromInt(0o700);
}

fn filePermissions() std.Io.File.Permissions {
    return @enumFromInt(0o600);
}

fn derive(d: [32]u8) error{InvalidIdentity}!Identity {
    const scalar = std.crypto.ecc.P256.scalar.Scalar.fromBytes(d, .big) catch return error.InvalidIdentity;
    if (scalar.isZero()) return error.InvalidIdentity;
    const point = std.crypto.ecc.P256.basePoint.mul(d, .big) catch return error.InvalidIdentity;
    const public = point.toUncompressedSec1();
    return .{
        .d = d,
        .x = public[1..33].*,
        .y = public[33..65].*,
    };
}

fn validate(identity: Identity) error{InvalidIdentity}!void {
    const expected = try derive(identity.d);
    if (!std.mem.eql(u8, &expected.x, &identity.x) or !std.mem.eql(u8, &expected.y, &identity.y)) {
        return error.InvalidIdentity;
    }
}

fn encodeCoordinate(value: [32]u8) [43]u8 {
    var encoded: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &value);
    return encoded;
}

fn decodeCoordinate(encoded: []const u8) error{InvalidIdentity}![32]u8 {
    if (encoded.len != 43) return error.InvalidIdentity;
    var value: [32]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&value, encoded) catch return error.InvalidIdentity;
    const canonical = encodeCoordinate(value);
    if (!std.mem.eql(u8, encoded, &canonical)) return error.InvalidIdentity;
    return value;
}

fn writeTestJwk(io: std.Io, dir: std.Io.Dir, d: []const u8, x: []const u8, y: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buffer,
        "{{\"version\":1,\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"{s}\",\"y\":\"{s}\",\"d\":\"{s}\"}}\n",
        .{ x, y, d },
    );
    try dir.writeFile(io, .{ .sub_path = "identity.json", .data = json });
}

test "identity save and load preserve the SEC1 public key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = generate(std.testing.io);
    try save(std.testing.io, tmp.dir, "identity.json", original);
    const loaded = try load(std.testing.allocator, std.testing.io, tmp.dir, "identity.json");
    const original_public = original.publicSec1();
    const loaded_public = loaded.publicSec1();
    try std.testing.expectEqualSlices(u8, &original_public, &loaded_public);
}

test "identity save never overwrites an existing identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try save(std.testing.io, tmp.dir, "identity.json", generate(std.testing.io));
    try std.testing.expectError(
        error.IdentityAlreadyExists,
        save(std.testing.io, tmp.dir, "identity.json", generate(std.testing.io)),
    );
}

test "identity load rejects invalid and noncanonical JWK coordinates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = generate(std.testing.io);
    const d = encodeCoordinate(original.d);
    const x = encodeCoordinate(original.x);
    const y = encodeCoordinate(original.y);
    try writeTestJwk(std.testing.io, tmp.dir, &d, "A", &y);
    try std.testing.expectError(
        error.InvalidIdentity,
        load(std.testing.allocator, std.testing.io, tmp.dir, "identity.json"),
    );

    var invalid_x = x;
    invalid_x[0] = '+';
    try writeTestJwk(std.testing.io, tmp.dir, &d, &invalid_x, &y);
    try std.testing.expectError(
        error.InvalidIdentity,
        load(std.testing.allocator, std.testing.io, tmp.dir, "identity.json"),
    );

    var noncanonical_x = x;
    const alphabet = std.base64.url_safe_alphabet_chars;
    const index = std.mem.indexOfScalar(u8, &alphabet, noncanonical_x[noncanonical_x.len - 1]).?;
    noncanonical_x[noncanonical_x.len - 1] = alphabet[index | 1];
    try writeTestJwk(std.testing.io, tmp.dir, &d, &noncanonical_x, &y);
    try std.testing.expectError(
        error.InvalidIdentity,
        load(std.testing.allocator, std.testing.io, tmp.dir, "identity.json"),
    );
}

test "identity load rejects coordinates that do not match the private scalar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = generate(std.testing.io);
    const second = generate(std.testing.io);
    const d = encodeCoordinate(second.d);
    const x = encodeCoordinate(first.x);
    const y = encodeCoordinate(first.y);
    try writeTestJwk(std.testing.io, tmp.dir, &d, &x, &y);
    try std.testing.expectError(
        error.InvalidIdentity,
        load(std.testing.allocator, std.testing.io, tmp.dir, "identity.json"),
    );
}

test "identity load preserves allocator failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try save(std.testing.io, tmp.dir, "identity.json", generate(std.testing.io));
    try std.testing.expectError(
        error.OutOfMemory,
        load(std.testing.failing_allocator, std.testing.io, tmp.dir, "identity.json"),
    );
}

test "identity config directory rejects symlinks without changing the target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var target = try tmp.dir.createDirPathOpen(std.testing.io, "target", .{ .open_options = .{ .iterate = true } });
    defer target.close(std.testing.io);
    try target.setPermissions(std.testing.io, @enumFromInt(0o755));
    var parent = try tmp.dir.createDirPathOpen(std.testing.io, "home/.config", .{});
    defer parent.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "../../target", "home/.config/ashdrop", .{ .is_directory = true });

    if (openConfigDirAt(std.testing.io, tmp.dir, "home")) |dir| {
        dir.close(std.testing.io);
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), (try target.stat(std.testing.io)).permissions.toMode() & 0o777);
}

test "identity load rejects symlinked files without changing the target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config_dir = try openConfigDirAt(std.testing.io, tmp.dir, "home");
    defer config_dir.close(std.testing.io);
    var parent = try tmp.dir.openDir(std.testing.io, "home/.config", .{ .iterate = true });
    defer parent.close(std.testing.io);
    try parent.writeFile(std.testing.io, .{ .sub_path = "target.json", .data = "TARGET\n" });
    try parent.setFilePermissions(std.testing.io, "target.json", @enumFromInt(0o644), .{});
    try config_dir.symLink(std.testing.io, "../target.json", "identity.json", .{});

    if (load(std.testing.allocator, std.testing.io, config_dir, "identity.json")) |_| {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), (try parent.statFile(std.testing.io, "target.json", .{})).permissions.toMode() & 0o777);
    var content: [16]u8 = undefined;
    try std.testing.expectEqualStrings("TARGET\n", try parent.readFile(std.testing.io, "target.json", &content));
}
