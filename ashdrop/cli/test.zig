//! Imports the CLI modules that expose inline unit tests to Zig's test runner.

test {
    _ = @import("src/main.zig");
    _ = @import("src/api.zig");
    _ = @import("src/files.zig");
    _ = @import("src/commands.zig");
}
