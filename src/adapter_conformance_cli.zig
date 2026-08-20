const std = @import("std");
const conformance = @import("adapter_conformance.zig");
const pijul = @import("pijul_adapter.zig");

const usage =
    \\Usage: apricot-adapter-conformance --vcs pijul REPOSITORY EMPTY_RESTORE_PATH [--forbid PAYLOAD]...
    \\
    \\Runs the real Pijul adapter conformance suite and writes deterministic JSON.
    \\Use --forbid more than once to assert that ignored or untracked secrets are excluded.
    \\
;

const RunOptions = struct {
    repository_path: []const u8,
    restore_path: []const u8,
    forbidden_payloads: []const []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: RunOptions) void {
        self.allocator.free(self.forbidden_payloads);
    }
};

const Command = union(enum) {
    help,
    run: RunOptions,

    fn deinit(self: Command) void {
        switch (self) {
            .help => {},
            .run => |options| options.deinit(),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(init.gpa);
    var iterator = init.minimal.args.iterate();
    defer iterator.deinit();
    while (iterator.next()) |argument| try arguments.append(init.gpa, argument);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var command = try parse(init.gpa, if (arguments.items.len == 0) &.{} else arguments.items[1..]);
    defer command.deinit();
    switch (command) {
        .help => try stdout.writeAll(usage),
        .run => |options| if (!try execute(init.gpa, init.io, stdout, options)) return error.ConformanceFailed,
    }
}

fn parse(allocator: std.mem.Allocator, arguments: []const []const u8) !Command {
    if (arguments.len == 1 and (std.mem.eql(u8, arguments[0], "--help") or std.mem.eql(u8, arguments[0], "help"))) return .help;
    if (arguments.len < 4 or !std.mem.eql(u8, arguments[0], "--vcs") or !std.mem.eql(u8, arguments[1], "pijul")) return error.InvalidArguments;
    if (arguments[2].len == 0 or arguments[3].len == 0) return error.InvalidArguments;
    var forbidden: std.ArrayList([]const u8) = .empty;
    errdefer forbidden.deinit(allocator);
    var index: usize = 4;
    while (index < arguments.len) {
        if (!std.mem.eql(u8, arguments[index], "--forbid") or index + 1 >= arguments.len or arguments[index + 1].len == 0) return error.InvalidArguments;
        try forbidden.append(allocator, arguments[index + 1]);
        index += 2;
    }
    return .{ .run = .{
        .repository_path = arguments[2],
        .restore_path = arguments[3],
        .forbidden_payloads = try forbidden.toOwnedSlice(allocator),
        .allocator = allocator,
    } };
}

fn execute(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, options: RunOptions) !bool {
    const repository_path = try absolutePath(allocator, io, options.repository_path);
    defer allocator.free(repository_path);
    const restore_path = try absolutePath(allocator, io, options.restore_path);
    defer allocator.free(restore_path);
    if (std.mem.eql(u8, repository_path, restore_path)) return error.RestorePathMatchesRepository;
    try ensureEmptyRestorePath(io, restore_path);

    var source = pijul.PijulAdapter.init(allocator, io, repository_path, restore_path);
    defer source.deinit();
    var restored = pijul.PijulAdapter.init(allocator, io, restore_path, restore_path);
    defer restored.deinit();
    var result = try conformance.run(allocator, .{
        .adapter = source.adapter(),
        .restored_adapter = restored.adapter(),
        .forbidden_payloads = options.forbidden_payloads,
    });
    defer result.deinit();
    const json = try result.encodeJson(allocator);
    defer allocator.free(json);
    try writer.writeAll(json);
    try writer.writeByte('\n');
    return result.passed();
}

fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn ensureEmptyRestorePath(io: std.Io, path: []const u8) !void {
    var directory = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    if (try iterator.next(io) != null) return error.RestorePathNotEmpty;
}

test "parser accepts repeated forbidden payloads" {
    var command = try parse(std.testing.allocator, &.{ "--vcs", "pijul", "repo", "restore", "--forbid", "secret-one", "--forbid", "secret-two" });
    defer command.deinit();
    const options = command.run;
    try std.testing.expectEqualStrings("repo", options.repository_path);
    try std.testing.expectEqualStrings("restore", options.restore_path);
    try std.testing.expectEqual(@as(usize, 2), options.forbidden_payloads.len);
    try std.testing.expectEqualStrings("secret-one", options.forbidden_payloads[0]);
    try std.testing.expectEqualStrings("secret-two", options.forbidden_payloads[1]);
}

test "parser rejects incomplete and empty forbidden payloads" {
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "--vcs", "pijul", "repo", "restore", "--forbid" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "--vcs", "pijul", "repo", "restore", "--forbid", "" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "--vcs", "pijul", "repo", "restore", "unknown", "value" }));
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "--vcs", "unknown", "repo", "restore" }));
}

test "parser exposes help without allocating run options" {
    var command = try parse(std.testing.allocator, &.{"--help"});
    defer command.deinit();
    try std.testing.expect(command == .help);
}

test "restore path must be empty or absent" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try ensureEmptyRestorePath(io, path);
    try temporary.dir.writeFile(io, .{ .sub_path = "occupied", .data = "x" });
    try std.testing.expectError(error.RestorePathNotEmpty, ensureEmptyRestorePath(io, path));
    const absent = try std.fs.path.resolve(std.testing.allocator, &.{ path, "absent" });
    defer std.testing.allocator.free(absent);
    try ensureEmptyRestorePath(io, absent);
}
