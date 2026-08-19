const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("apricot", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "apricot", .module = lib_mod }},
    });

    const exe = b.addExecutable(.{ .name = "apct", .root_module = exe_mod });
    b.installArtifact(exe);

    const static_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const static_lib = b.addLibrary(.{
        .name = "apricot",
        .root_module = static_abi_mod,
        .linkage = .static,
    });
    static_lib.installHeader(b.path("include/apricot.h"), "apricot.h");
    b.installArtifact(static_lib);

    const shared_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    const shared_lib = b.addLibrary(.{
        .name = "apricot",
        .root_module = shared_abi_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    shared_lib.installHeader(b.path("include/apricot.h"), "apricot.h");
    b.installArtifact(shared_lib);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Apricot");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = lib_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const fmt_paths = &[_][]const u8{ "build.zig", "src" };
    const fmt = b.addFmt(.{ .paths = fmt_paths });
    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    const fmt_check_step = b.step("fmt-check", "Check source formatting");
    fmt_check_step.dependOn(&fmt_check.step);

    const typecheck_step = b.step("typecheck", "Type-check Apricot");
    typecheck_step.dependOn(&exe.step);
    typecheck_step.dependOn(&static_lib.step);
    typecheck_step.dependOn(&shared_lib.step);

    const lint_step = b.step("lint", "Run static checks");
    lint_step.dependOn(&fmt_check.step);
    lint_step.dependOn(&exe.step);
    lint_step.dependOn(&static_lib.step);
    lint_step.dependOn(&shared_lib.step);

    const check_step = b.step("check", "Run all quality gates");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&exe.step);
    check_step.dependOn(&static_lib.step);
    check_step.dependOn(&shared_lib.step);
    check_step.dependOn(&run_tests.step);
}
