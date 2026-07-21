//! Builds the standalone Ashdrop CLI executable and its unit-test runner.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const package_version = "0.1.0";
    const development_version = package_version ++ "-dev";
    const version = b.option([]const u8, "version", "Ashdrop version") orelse development_version;
    _ = std.SemanticVersion.parse(version) catch @panic("-Dversion must be a semantic version");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "ashdrop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Keep argument forwarding compatible with stable 0.16 and newer build APIs.
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run_cmd.addPassthruArgs();
    } else if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Ashdrop CLI");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", build_options);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_tests.step);
}
