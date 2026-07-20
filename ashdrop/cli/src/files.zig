//! Validates shared environment files and writes received plaintext through safe atomic outputs.

const std = @import("std");

pub const max_file_size = 64 * 1024;
pub const max_api_body_size = 96 * 1024;

pub const PreparedOutput = struct {
    dir: std.Io.Dir,
    basename: []u8,
    owns_dir: bool,
    atomic_file: std.Io.File.Atomic,
    force: bool,

    pub fn deinit(self: *PreparedOutput, allocator: std.mem.Allocator, io: std.Io) void {
        self.atomic_file.deinit(io);
        if (self.owns_dir) self.dir.close(io);
        allocator.free(self.basename);
        self.* = undefined;
    }
};

pub fn readEnv(allocator: std.mem.Allocator, io: std.Io, base_dir: std.Io.Dir, path: []const u8) ![]u8 {
    const content = base_dir.readFileAlloc(io, path, allocator, .limited(max_file_size + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => return err,
    };
    errdefer allocator.free(content);
    if (content.len > max_file_size) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    return content;
}

pub fn requireApiBodySize(body: []const u8) error{RequestTooLarge}!void {
    if (body.len >= max_api_body_size) return error.RequestTooLarge;
}

const OutputParent = struct {
    dir: std.Io.Dir,
    owns_dir: bool,
};

fn openOutputParent(io: std.Io, base_dir: std.Io.Dir, path: []const u8) !OutputParent {
    const parent = std.Io.Dir.path.dirname(path) orelse "";
    var current = base_dir;
    var owns_current = false;
    var start: usize = 0;
    if (std.Io.Dir.path.isAbsolute(parent)) {
        current = try std.Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true });
        owns_current = true;
        while (start < parent.len and parent[start] == '/') : (start += 1) {}
    }
    errdefer if (owns_current) current.close(io);

    // Resolve each component without links so an intermediate symlink cannot redirect decrypted output.
    while (start < parent.len) {
        const end = std.mem.indexOfScalarPos(u8, parent, start, '/') orelse parent.len;
        const component = parent[start..end];
        start = end + @intFromBool(end < parent.len);
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;

        const stat = try current.statFile(io, component, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.UnsafeOutputPath;
        if (stat.kind != .directory) return error.NotDir;
        const next = try current.openDir(io, component, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
    return .{ .dir = current, .owns_dir = owns_current };
}

pub fn prepareOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    path: []const u8,
    force: bool,
) !PreparedOutput {
    const basename = std.Io.Dir.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidOutputPath;

    const output_parent = try openOutputParent(io, base_dir, path);
    const output_dir = output_parent.dir;
    const owns_dir = output_parent.owns_dir;
    errdefer if (owns_dir) output_dir.close(io);

    // Apply the same no-symlink rule to the final filename before reserving a temporary file.
    const existing = output_dir.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |cause| return cause,
    };
    if (existing) |stat| {
        if (stat.kind == .sym_link) return error.UnsafeOutputPath;
        if (stat.kind == .directory) return error.OutputIsDirectory;
        if (!force) return error.OutputExists;
    }

    const owned_basename = try allocator.dupe(u8, basename);
    errdefer allocator.free(owned_basename);
    var atomic_file = try output_dir.createFileAtomic(io, owned_basename, .{
        .permissions = @enumFromInt(0o600),
        .replace = force,
    });
    errdefer atomic_file.deinit(io);
    try atomic_file.file.setPermissions(io, @enumFromInt(0o600));
    return .{
        .dir = output_dir,
        .basename = owned_basename,
        .owns_dir = owns_dir,
        .atomic_file = atomic_file,
        .force = force,
    };
}

pub fn writeAtomically(io: std.Io, output: *PreparedOutput, content: []const u8) !void {
    try output.atomic_file.file.writeStreamingAll(io, content);
    try output.atomic_file.file.sync(io);
    // Normal delivery links only if the destination stayed absent; replacement requires explicit force.
    if (output.force) {
        try output.atomic_file.replace(io);
    } else {
        output.atomic_file.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => return error.OutputExists,
            else => return err,
        };
    }
}

test "readEnv rejects files larger than 64 KiB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = try std.testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer std.testing.allocator.free(content);
    @memset(content, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large.env", .data = content });

    try std.testing.expectError(
        error.FileTooLarge,
        readEnv(std.testing.allocator, std.testing.io, tmp.dir, "large.env"),
    );
}

test "readEnv rejects non-UTF-8 content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.env", .data = "KEY=\xff\n" });

    try std.testing.expectError(
        error.InvalidUtf8,
        readEnv(std.testing.allocator, std.testing.io, tmp.dir, "invalid.env"),
    );
}

test "create request bodies must remain below the API cap" {
    const body = try std.testing.allocator.alloc(u8, 96 * 1024);
    defer std.testing.allocator.free(body);
    try std.testing.expectError(error.RequestTooLarge, requireApiBodySize(body));
}

test "safe output preparation rejects an existing destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.ashdrop", .data = "EXISTING=yes\n" });

    try std.testing.expectError(
        error.OutputExists,
        prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", false),
    );
}

test "safe output preparation rejects a directory even when forced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".env.ashdrop", @enumFromInt(0o700));

    try std.testing.expectError(
        error.OutputIsDirectory,
        prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", true),
    );
}

test "output preparation reserves a secure atomic file before content is available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var output = try prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", false);
    defer output.deinit(std.testing.allocator, std.testing.io);

    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        (try output.atomic_file.file.stat(std.testing.io)).permissions.toMode() & 0o777,
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".env.ashdrop", .{}));
}

test "late destination creation is not replaced by atomic write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", false);
    defer output.deinit(std.testing.allocator, std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.ashdrop", .data = "LATE=yes\n" });

    try std.testing.expectError(error.OutputExists, writeAtomically(std.testing.io, &output, "TOKEN=secret\n"));
    var content: [64]u8 = undefined;
    try std.testing.expectEqualStrings("LATE=yes\n", try tmp.dir.readFile(std.testing.io, ".env.ashdrop", &content));
}

test "atomic writes set mode and replace only when forced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var output = try prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", false);
    try writeAtomically(std.testing.io, &output, "TOKEN=first\n");
    output.deinit(std.testing.allocator, std.testing.io);

    var content: [64]u8 = undefined;
    try std.testing.expectEqualStrings("TOKEN=first\n", try tmp.dir.readFile(std.testing.io, ".env.ashdrop", &content));
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try tmp.dir.statFile(std.testing.io, ".env.ashdrop", .{})).permissions.toMode() & 0o777);

    try std.testing.expectError(
        error.OutputExists,
        prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", false),
    );
    var forced = try prepareOutput(std.testing.allocator, std.testing.io, tmp.dir, ".env.ashdrop", true);
    defer forced.deinit(std.testing.allocator, std.testing.io);
    try writeAtomically(std.testing.io, &forced, "TOKEN=second\n");
    try std.testing.expectEqualStrings("TOKEN=second\n", try tmp.dir.readFile(std.testing.io, ".env.ashdrop", &content));
}
