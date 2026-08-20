const std = @import("std");
const contract = @import("adapter.zig");
const filesystem = @import("filesystem_adapter.zig");

pub const EntryKind = filesystem.EntryKind;
pub const Entry = filesystem.Entry;
pub const Archive = filesystem.Archive;

const capabilities = [_]contract.Capability{
    .{ .name = "opaque-native-repository", .support = .required },
    .{ .name = "change-graph", .support = .required },
    .{ .name = "channels", .support = .required },
    .{ .name = "filesystem-executable-bit", .support = .required },
    .{ .name = "filesystem-symbolic-link", .support = .required },
    .{ .name = "foreign-operation-import", .support = .unsupported },
    .{ .name = "commit-dag", .support = .unsupported },
};
const exclusions = [_]contract.ClosureExclusion{
    .{ .namespace = "filesystem.timestamps", .reason = "not authoritative to Pijul repository semantics", .affects_semantics = false },
    .{ .namespace = "filesystem.ownership", .reason = "host-local identity metadata", .affects_semantics = false },
    .{ .namespace = "filesystem.extended-attributes", .reason = "not authoritative to Pijul repository semantics", .affects_semantics = false },
    .{ .namespace = "pijul.user-credentials", .reason = "user identities and private keys are external credentials", .affects_semantics = false },
    .{ .namespace = "worktree.untracked", .reason = "untracked and ignored worktree paths are non-authoritative and may contain credentials", .affects_semantics = false },
    .{ .namespace = "other-vcs.metadata", .reason = "co-located metadata owned by another version control system", .affects_semantics = false },
};
const path_exclusions = [_]filesystem.PathExclusion{
    .{ .path = ".git" },
    .{ .path = ".sdt" },
    .{ .path = ".jj" },
};
var tracked_provider_context: u8 = 0;

pub const PijulAdapter = struct {
    core: filesystem.FilesystemAdapter,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8) PijulAdapter {
        return .{ .core = core(allocator, io, repository_path, restore_path, definition(null)) };
    }

    pub fn initWithTrackedPaths(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8, tracked_paths: []const []const u8) PijulAdapter {
        return .{ .core = core(allocator, io, repository_path, restore_path, definition(tracked_paths)) };
    }

    pub fn deinit(self: *PijulAdapter) void {
        self.core.deinit();
    }

    pub fn adapter(self: *PijulAdapter) contract.Adapter {
        return self.core.adapter();
    }
};

fn core(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8, value: filesystem.Definition) filesystem.FilesystemAdapter {
    return .{
        .allocator = allocator,
        .io = io,
        .repository_path = repository_path,
        .restore_path = restore_path,
        .definition = value,
    };
}

fn definition(tracked_paths: ?[]const []const u8) filesystem.Definition {
    return .{
        .vcs = "pijul",
        .format_version = "filesystem-archive-v1",
        .id_scheme = "apricot-pijul-archive-sha256-v1",
        .object_kind = "pijul-repository-archive",
        .archive_magic = "APCTPIJ1",
        .metadata_roots = &.{".pijul"},
        .tracked_paths = tracked_paths orelse &.{},
        .tracked_provider = if (tracked_paths == null) .{ .context = &tracked_provider_context, .listFn = listTrackedPaths } else null,
        .path_exclusions = &path_exclusions,
        .capabilities = &capabilities,
        .closure_exclusions = &exclusions,
        .projection_namespace = "channels",
        .projection_name = "current",
        .foreign_refusal_reason = "foreign projection changes require an explicit Pijul import policy",
        .limits = .{ .max_total_path_bytes = @as(u64, std.fs.max_path_bytes) * 1_000_000 },
    };
}

pub fn repositoryId(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    const bytes = try captureRepository(allocator, io, absolute_path);
    return repositoryIdFromArchive(allocator, bytes);
}

pub fn repositoryIdWithTrackedPaths(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, tracked_paths: []const []const u8) ![]u8 {
    const bytes = try captureRepositoryFromPaths(allocator, io, absolute_path, tracked_paths);
    return repositoryIdFromArchive(allocator, bytes);
}

fn repositoryIdFromArchive(allocator: std.mem.Allocator, bytes: []u8) ![]u8 {
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "pijul:{x}", .{digest});
}

pub fn captureRepository(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    return filesystem.captureStable(allocator, io, absolute_path, definition(null));
}

pub fn captureRepositoryFromPaths(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, tracked_paths: []const []const u8) ![]u8 {
    return filesystem.captureStable(allocator, io, absolute_path, definition(tracked_paths));
}

pub fn decodeArchive(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
    return filesystem.decodeArchive(allocator, bytes, definition(&.{}));
}

pub fn restoreRepository(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, bytes: []const u8) !void {
    return filesystem.restoreArchive(allocator, io, absolute_path, bytes, definition(&.{}));
}

fn listTrackedPaths(_: *anyopaque, allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, sink: filesystem.TrackedPathSink) !void {
    try rejectAmbiguousRepositoryPaths(allocator, io, repository_path);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pijul", "list", "--repository", repository_path },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.PijulExecutableNotFound,
        error.StreamTooLong => error.PijulOutputLimitExceeded,
        else => err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |status| if (status != 0) return error.PijulListFailed,
        else => return error.PijulListFailed,
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const path = std.mem.trimEnd(u8, raw_line, "\r");
        if (path.len == 0) continue;
        if (!validRelativePath(path) or isMetadataPath(path) or isExcludedTree(path)) return error.InvalidTrackedPath;
        try sink.add(path);
    }
}

fn rejectAmbiguousRepositoryPaths(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (std.mem.indexOfAny(u8, walked.path, "\r\n") != null) return error.AmbiguousTrackedPathOutput;
        if (walked.kind == .directory) try walker.enter(io, walked);
    }
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isMetadataPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".pijul") or std.mem.startsWith(u8, path, ".pijul/");
}

fn isExcludedTree(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '/') != null) return false;
    return std.mem.eql(u8, path, ".git") or std.mem.eql(u8, path, ".sdt") or std.mem.eql(u8, path, ".jj");
}

fn containsEntry(entries: []const Entry, path: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return true;
    return false;
}

fn appendInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn appendGoldenEntry(list: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: EntryKind, path: []const u8, mode: u32, data: []const u8) !void {
    try list.append(allocator, @intFromEnum(kind));
    try appendInt(list, allocator, u32, @intCast(path.len));
    try appendInt(list, allocator, u32, mode);
    try appendInt(list, allocator, u64, data.len);
    try list.appendSlice(allocator, path);
    try list.appendSlice(allocator, data);
}

test "Pijul archive preserves metadata worktree bytes modes directories and symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul/pristine");
    try source.dir.createDirPath(io, ".pijul/changes/AA");
    try source.dir.createDirPath(io, "src");
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/pristine/db", .data = "\x00\xffpristine" });
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/changes/AA/change", .data = "\xff\x00change" });
    try source.dir.writeFile(io, .{ .sub_path = "src/main", .data = "#!/bin/sh\n" });
    try source.dir.writeFile(io, .{ .sub_path = ".ignore", .data = ".env\n" });
    try source.dir.writeFile(io, .{ .sub_path = ".env", .data = "PRIVATE_TOKEN=must-not-leak" });
    var executable = try source.dir.openFile(io, "src/main", .{ .mode = .read_write });
    try executable.setPermissions(io, .fromMode(0o751));
    executable.close(io);
    try source.dir.symLink(io, "src/main", "current", .{});
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const tracked_paths = [_][]const u8{ "src/main", "current" };
    const archive = try captureRepositoryFromPaths(allocator, io, source_path, &tracked_paths);
    defer allocator.free(archive);
    var decoded = try decodeArchive(allocator, archive);
    defer decoded.deinit(allocator);
    try std.testing.expect(!containsEntry(decoded.entries, ".env"));
    try std.testing.expect(!containsEntry(decoded.entries, ".ignore"));
    try std.testing.expect(std.mem.indexOf(u8, archive, "PRIVATE_TOKEN=must-not-leak") == null);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    try restoreRepository(allocator, io, destination_path, archive);
    const second = try captureRepositoryFromPaths(allocator, io, destination_path, &tracked_paths);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, archive, second);
    const pristine = try destination.dir.readFileAlloc(io, ".pijul/pristine/db", allocator, .unlimited);
    defer allocator.free(pristine);
    try std.testing.expectEqualSlices(u8, "\x00\xffpristine", pristine);
    const executable_stat = try destination.dir.statFile(io, "src/main", .{});
    try std.testing.expectEqual(@as(u32, 0o751), @as(u32, @intCast(executable_stat.permissions.toMode() & 0o777)));
    var target: [32]u8 = undefined;
    const target_len = try destination.dir.readLink(io, "current", &target);
    try std.testing.expectEqualSlices(u8, "src/main", target[0..target_len]);
}

test "Pijul shared encoder preserves the pre-refactor APCTPIJ1 bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul");
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/state", .data = "native\x00state" });
    try source.dir.writeFile(io, .{ .sub_path = "work", .data = "working\n" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const actual = try captureRepositoryFromPaths(allocator, io, source_path, &.{"work"});
    defer allocator.free(actual);
    const root_stat = try source.dir.statFile(io, ".", .{});
    const metadata_stat = try source.dir.statFile(io, ".pijul", .{});
    const state_stat = try source.dir.statFile(io, ".pijul/state", .{});
    const work_stat = try source.dir.statFile(io, "work", .{});
    var golden: std.ArrayList(u8) = .empty;
    defer golden.deinit(allocator);
    try golden.appendSlice(allocator, "APCTPIJ1");
    try appendInt(&golden, allocator, u32, @intCast(root_stat.permissions.toMode() & 0o7777));
    try appendInt(&golden, allocator, u64, 3);
    try appendGoldenEntry(&golden, allocator, .directory, ".pijul", @intCast(metadata_stat.permissions.toMode() & 0o7777), "");
    try appendGoldenEntry(&golden, allocator, .file, ".pijul/state", @intCast(state_stat.permissions.toMode() & 0o7777), "native\x00state");
    try appendGoldenEntry(&golden, allocator, .file, "work", @intCast(work_stat.permissions.toMode() & 0o7777), "working\n");
    try std.testing.expectEqualSlices(u8, golden.items, actual);
}

test "Pijul adapter enumerates and restores one authoritative native object" {
    const Collector = struct {
        object: ?contract.NativeObject = null,

        fn emit(context: *anyopaque, object: contract.NativeObject) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.object = object;
        }

        fn get(context: *anyopaque, id: contract.NativeId) !?contract.NativeObject {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.object) |object| if (object.id.eql(id)) return object;
            return null;
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul/pristine");
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/pristine/db", .data = "native-pristine" });
    try source.dir.writeFile(io, .{ .sub_path = "dirty", .data = "unrecorded-worktree-state" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    const tracked_paths = [_][]const u8{"dirty"};
    var implementation = PijulAdapter.initWithTrackedPaths(allocator, io, source_path, destination_path, &tracked_paths);
    defer implementation.deinit();
    const adapter_value = implementation.adapter();
    const snapshot_value = try adapter_value.snapshot();
    try std.testing.expectEqualStrings("pijul", snapshot_value.vcs);
    try std.testing.expectEqual(contract.PreservationTier.byte_lossless, snapshot_value.closure.tier);
    var collector = Collector{};
    try adapter_value.enumerate(snapshot_value.roots, .{ .context = &collector, .emitFn = Collector.emit });
    const report = try adapter_value.restore(snapshot_value, .{ .context = &collector, .getFn = Collector.get });
    try std.testing.expectEqual(contract.PreservationTier.byte_lossless, report.verified_tier);
    const dirty = try destination.dir.readFileAlloc(io, "dirty", allocator, .unlimited);
    defer allocator.free(dirty);
    try std.testing.expectEqualSlices(u8, "unrecorded-worktree-state", dirty);
}

test "Pijul archive rejects traversal and symlink descendants" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "APCTPIJ1");
    try appendInt(&bytes, allocator, u32, 0o755);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.append(allocator, @intFromEnum(EntryKind.file));
    try appendInt(&bytes, allocator, u32, 4);
    try appendInt(&bytes, allocator, u32, 0o644);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.appendSlice(allocator, "../x");
    try bytes.append(allocator, 'x');
    try std.testing.expectError(error.InvalidArchivePath, decodeArchive(allocator, bytes.items));

    bytes.clearRetainingCapacity();
    try bytes.appendSlice(allocator, "APCTPIJ1");
    try appendInt(&bytes, allocator, u32, 0o755);
    try appendInt(&bytes, allocator, u64, 3);
    const fixture = [_]struct { EntryKind, []const u8, []const u8 }{
        .{ .directory, ".pijul", "" },
        .{ .symlink, "link", "target" },
        .{ .file, "link/child", "x" },
    };
    for (fixture) |value| {
        try bytes.append(allocator, @intFromEnum(value[0]));
        try appendInt(&bytes, allocator, u32, @intCast(value[1].len));
        try appendInt(&bytes, allocator, u32, 0o755);
        try appendInt(&bytes, allocator, u64, value[2].len);
        try bytes.appendSlice(allocator, value[1]);
        try bytes.appendSlice(allocator, value[2]);
    }
    try std.testing.expectError(error.ArchivePathTraversesSymlink, decodeArchive(allocator, bytes.items));
}

test "Pijul restore refuses nonempty targets without modifying them" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul");
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/config", .data = "channel = 'main'" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const archive = try captureRepositoryFromPaths(allocator, io, source_path, &.{});
    defer allocator.free(archive);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    try destination.dir.writeFile(io, .{ .sub_path = "existing", .data = "keep" });
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    try std.testing.expectError(error.RestoreTargetNotEmpty, restoreRepository(allocator, io, destination_path, archive));
    const existing = try destination.dir.readFileAlloc(io, "existing", allocator, .unlimited);
    defer allocator.free(existing);
    try std.testing.expectEqualSlices(u8, "keep", existing);
}

test "Pijul repository identity is deterministic and changes with native state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul");
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/config.toml", .data = "channel = 'main'" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const first = try repositoryIdWithTrackedPaths(allocator, io, source_path, &.{});
    defer allocator.free(first);
    const second = try repositoryIdWithTrackedPaths(allocator, io, source_path, &.{});
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, "pijul:"));
    try source.dir.writeFile(io, .{ .sub_path = ".pijul/config.toml", .data = "channel = 'feature'" });
    const changed = try repositoryIdWithTrackedPaths(allocator, io, source_path, &.{});
    defer allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
}

test "Pijul foreign projection mutation is refused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".pijul");
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var implementation = PijulAdapter.init(allocator, io, source_path, source_path);
    defer implementation.deinit();
    const result = try implementation.adapter().inspectForeign(.{
        .kind = "forge-push",
        .base_projection = "old",
        .observed_projection = "new",
        .evidence_media_type = "application/octet-stream",
        .evidence = "mutation",
    });
    try std.testing.expect(result == .refused);
    try std.testing.expectEqualStrings("foreign projection changes require an explicit Pijul import policy", result.refused.reason);
}
