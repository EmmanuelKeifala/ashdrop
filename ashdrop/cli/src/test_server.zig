//! Provides a scripted loopback HTTP server for CLI request and response tests.

const std = @import("std");

pub const ExpectedRequest = struct {
    method: std.http.Method,
    target: []const u8,
    json_body: bool = false,
    required_headers: []const std.http.Header = &.{},
    response_status: std.http.Status,
    response_body: []const u8,
    response_headers: []const std.http.Header = &.{},
};

pub const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server = undefined,
    thread: std.Thread = undefined,
    expected: []const ExpectedRequest,
    next: usize = 0,
    failure: ?anyerror = null,
    shutting_down: std.atomic.Value(bool) = .init(false),

    pub fn init(self: *Server, io: std.Io, expected: []const ExpectedRequest) !void {
        self.* = .{
            .io = io,
            .expected = expected,
            .shutting_down = .init(false),
        };
        const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        self.listener = try address.listen(io, .{});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn deinit(self: *Server) !void {
        self.shutting_down.store(true, .release);
        const address = self.listener.socket.address;
        if (std.Io.net.IpAddress.connect(&address, self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.thread.join();
        self.listener.socket.close(self.io);
        self.listener = undefined;
        if (self.failure) |err| return err;
        if (self.next != self.expected.len) return error.TestServerMissedRequest;
    }

    pub fn port(self: *const Server) u16 {
        return self.listener.socket.address.getPort();
    }

    fn serve(self: *Server) void {
        while (self.next < self.expected.len) {
            serveOne(self) catch |err| {
                if (self.shutting_down.load(.acquire)) return;
                self.failure = err;
                return;
            };
        }
    }

    fn serveOne(self: *Server) !void {
        var stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const expected = self.expected[self.next];
        if (request.head.method != expected.method or !std.mem.eql(u8, request.head.target, expected.target)) {
            return error.TestServerUnexpectedRequest;
        }
        if (expected.json_body and !std.mem.eql(u8, request.head.content_type orelse "", "application/json")) {
            return error.TestServerUnexpectedContentType;
        }
        for (expected.required_headers) |required| {
            var headers = request.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, required.name) and std.mem.eql(u8, header.value, required.value)) break;
            } else return error.TestServerMissingRequiredHeader;
        }

        var body_buffer: [8192]u8 = undefined;
        const body_reader = request.readerExpectNone(&.{});
        const body_len = body_reader.readSliceShort(&body_buffer) catch return error.TestServerReadFailed;
        const body = body_buffer[0..body_len];
        if (expected.json_body) {
            var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return error.TestServerInvalidJson;
            parsed.deinit();
        }
        try request.respond(expected.response_body, .{
            .status = expected.response_status,
            .extra_headers = expected.response_headers,
        });
        self.next += 1;
    }
};

test "server teardown before expected requests returns without waiting for a client" {
    const expected = [_]ExpectedRequest{
        .{ .method = .GET, .target = "/never", .response_status = .ok, .response_body = "{}" },
    };
    var server: Server = undefined;
    try server.init(std.testing.io, &expected);
    try std.testing.expectError(error.TestServerMissedRequest, server.deinit());
}
