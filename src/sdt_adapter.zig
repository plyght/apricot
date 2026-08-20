const std = @import("std");
const contract = @import("adapter.zig");

pub const EntryKind = enum(u8) {
    directory = 1,
    file = 2,
    symlink = 3,
};

pub const Entry = struct {
    kind: EntryKind,
    path: []u8,
    mode: u32,
    data: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.data);
    }
};

pub const Archive = struct {
    root_mode: u32,
    entries: []Entry,

    pub fn deinit(self: Archive, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const SuperdetermineAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    restore_path: []const u8,
    archive_bytes: ?[]u8 = null,
    digest: [32]u8 = undefined,
    root: [1]contract.NativeRoot = undefined,
    native_ref: [1]contract.NativeRef = undefined,

    const capabilities = [_]contract.Capability{
        .{ .name = "opaque-native-repository", .support = .required },
        .{ .name = "filesystem-executable-bit", .support = .required },
        .{ .name = "filesystem-symbolic-link", .support = .required },
        .{ .name = "foreign-operation-import", .support = .unsupported },
        .{ .name = "commit-dag", .support = .unsupported },
    };
    const authoritative_kinds = [_][]const u8{"superdetermine-repository-archive"};
    const exclusions = [_]contract.ClosureExclusion{
        .{ .namespace = "filesystem.timestamps", .reason = "not authoritative to Superdetermine repository semantics", .affects_semantics = false },
        .{ .namespace = "filesystem.ownership", .reason = "host-local identity metadata", .affects_semantics = false },
        .{ .namespace = "filesystem.extended-attributes", .reason = "not authoritative to Superdetermine repository semantics", .affects_semantics = false },
        .{ .namespace = "worktree.ignored", .reason = "ignored and unindexed worktree paths are non-authoritative", .affects_semantics = false },
        .{ .namespace = ".sdt.gitmirror", .reason = "legacy Git interoperability cache is non-authoritative", .affects_semantics = false },
        .{ .namespace = ".sdt.apricot-fetch", .reason = "transient Apricot fetch directories are non-authoritative", .affects_semantics = false },
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8) SuperdetermineAdapter {
        return .{
            .allocator = allocator,
            .io = io,
            .repository_path = repository_path,
            .restore_path = restore_path,
        };
    }

    pub fn deinit(self: *SuperdetermineAdapter) void {
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
    }

    pub fn adapter(self: *SuperdetermineAdapter) contract.Adapter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn cast(context: *anyopaque) *SuperdetermineAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn snapshot(context: *anyopaque) !contract.Snapshot {
        const self = cast(context);
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
        self.archive_bytes = try captureRepository(self.allocator, self.io, self.repository_path);
        std.crypto.hash.sha2.Sha256.hash(self.archive_bytes.?, &self.digest, .{});
        const id = contract.NativeId{ .scheme = "apricot-sdt-archive-sha256-v1", .bytes = &self.digest };
        self.root[0] = .{ .role = "repository", .id = id };
        self.native_ref[0] = .{ .namespace = "repository", .name = "exact", .target = id, .mutable = true };
        return .{
            .vcs = "superdetermine",
            .format_version = "filesystem-archive-v1",
            .roots = &self.root,
            .refs = &self.native_ref,
            .capabilities = &capabilities,
            .closure = .{
                .tier = .byte_lossless,
                .authoritative_kinds = &authoritative_kinds,
                .exclusions = &exclusions,
            },
        };
    }

    fn enumerate(context: *anyopaque, roots: []const contract.NativeRoot, sink: contract.ObjectSink) !void {
        const self = cast(context);
        const bytes = self.archive_bytes orelse return error.SnapshotRequired;
        if (roots.len != 1 or !roots[0].id.eql(self.root[0].id)) return error.UnknownRoot;
        try sink.emit(.{
            .id = self.root[0].id,
            .kind = "superdetermine-repository-archive",
            .bytes = bytes,
        });
    }

    fn restore(context: *anyopaque, snapshot_value: contract.Snapshot, source: contract.ObjectSource) !contract.RestoreReport {
        const self = cast(context);
        if (snapshot_value.roots.len != 1) return error.InvalidSnapshot;
        const object = try source.get(snapshot_value.roots[0].id) orelse return error.MissingObject;
        if (!std.mem.eql(u8, object.kind, "superdetermine-repository-archive")) return error.InvalidObjectKind;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object.bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, snapshot_value.roots[0].id.bytes)) return error.CorruptObject;
        try restoreRepository(self.allocator, self.io, self.restore_path, object.bytes);
        self.digest = actual;
        self.root[0] = .{ .role = "repository", .id = .{ .scheme = "apricot-sdt-archive-sha256-v1", .bytes = &self.digest } };
        return .{ .roots = &self.root, .verified_tier = .byte_lossless };
    }

    fn project(context: *anyopaque, snapshot_value: contract.Snapshot, sink: contract.ProjectionSink) !void {
        const self = cast(context);
        const bytes = self.archive_bytes orelse return error.SnapshotRequired;
        if (snapshot_value.roots.len != 1 or !snapshot_value.roots[0].id.eql(self.root[0].id)) return error.InvalidSnapshot;
        var archive = try decodeArchive(self.allocator, bytes);
        defer archive.deinit(self.allocator);
        try sink.emitResource(.{ .id = ".", .kind = "tree", .media_type = "application/vnd.apricot.tree", .payload = "" });
        for (archive.entries) |entry| switch (entry.kind) {
            .file => if (!isVcsMetadataPath(entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "file", .media_type = "application/octet-stream", .payload = entry.data, .executable = entry.mode & 0o111 != 0 });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .symlink => if (!isVcsMetadataPath(entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "symlink", .media_type = "application/vnd.apricot.symlink", .payload = entry.data });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .directory => {},
        };
        try sink.emitEntryPoint(.{ .namespace = "heads", .name = "main", .resource = "." });
    }

    fn inspectForeign(context: *anyopaque, operation: contract.ForeignOperation) !contract.ForeignInspection {
        _ = cast(context);
        _ = operation;
        return .{ .refused = .{ .reason = "foreign projection changes require an explicit Superdetermine import policy" } };
    }

    fn importForeign(context: *anyopaque, operation: contract.ForeignOperation, source: contract.ObjectSource) !contract.ForeignOutcome {
        _ = source;
        const result = try inspectForeign(context, operation);
        return .{ .refused = .{ .reason = result.refused.reason } };
    }

    const vtable = contract.Adapter.VTable{
        .snapshot = snapshot,
        .enumerate = enumerate,
        .restore = restore,
        .project = project,
        .inspectForeign = inspectForeign,
        .importForeign = importForeign,
    };
};

pub fn captureRepository(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    for (0..8) |_| {
        const first = try captureRepositoryOnce(allocator, io, absolute_path);
        const second = try captureRepositoryOnce(allocator, io, absolute_path);
        if (std.mem.eql(u8, first, second)) {
            allocator.free(second);
            return first;
        }
        allocator.free(second);
        allocator.free(first);
    }
    return error.RepositoryMutatedDuringCapture;
}

fn captureRepositoryOnce(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);
    const root_stat = try directory.statFile(io, ".", .{});
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    try appendPath(allocator, io, directory, ".sdt", &entries);
    var metadata = try directory.openDir(io, ".sdt", .{ .iterate = true });
    defer metadata.close(io);
    var walker = try metadata.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (walked.kind == .directory) {
            if (isExcludedMetadataTree(walked.path)) continue;
            try walker.enter(io, walked);
        }
        const path = try std.fmt.allocPrint(allocator, ".sdt/{s}", .{walked.path});
        defer allocator.free(path);
        try appendPath(allocator, io, directory, path, &entries);
    }
    const index_bytes = blk: {
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, ".sdt/index") and entry.kind == .file) break :blk entry.data;
        }
        return error.MissingSuperdetermineIndex;
    };
    var lines = std.mem.splitScalar(u8, index_bytes, '\n');
    while (lines.next()) |line| {
        const path = parseIndexPath(line) orelse continue;
        if (!validRelativePath(path) or isVcsMetadataPath(path)) return error.InvalidIndexPath;
        appendIndexedPath(allocator, io, directory, path, &entries) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "APCTSDT1");
    try appendInt(&output, allocator, u32, @intCast(root_stat.permissions.toMode() & 0o7777));
    try appendInt(&output, allocator, u64, entries.items.len);
    for (entries.items) |entry| {
        try output.append(allocator, @intFromEnum(entry.kind));
        try appendInt(&output, allocator, u32, @intCast(entry.path.len));
        try appendInt(&output, allocator, u32, entry.mode);
        try appendInt(&output, allocator, u64, entry.data.len);
        try output.appendSlice(allocator, entry.path);
        try output.appendSlice(allocator, entry.data);
    }
    return output.toOwnedSlice(allocator);
}

fn appendIndexedPath(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8, entries: *std.ArrayList(Entry)) !void {
    var parent = std.fs.path.dirname(path) orelse "";
    var parents: std.ArrayList([]const u8) = .empty;
    defer parents.deinit(allocator);
    while (parent.len > 0) {
        try parents.append(allocator, parent);
        parent = std.fs.path.dirname(parent) orelse break;
    }
    var index = parents.items.len;
    while (index > 0) {
        index -= 1;
        if (!containsEntry(entries.items, parents.items[index])) try appendPath(allocator, io, directory, parents.items[index], entries);
    }
    try appendPath(allocator, io, directory, path, entries);
}

fn appendPath(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path_value: []const u8, entries: *std.ArrayList(Entry)) !void {
    const stat = try directory.statFile(io, path_value, .{ .follow_symlinks = false });
    const kind: EntryKind = switch (stat.kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => return error.UnsupportedFilesystemEntry,
    };
    const path = try allocator.dupe(u8, path_value);
    errdefer allocator.free(path);
    const data = switch (kind) {
        .directory => try allocator.alloc(u8, 0),
        .file => try directory.readFileAlloc(io, path_value, allocator, .unlimited),
        .symlink => blk: {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const len = try directory.readLink(io, path_value, &buffer);
            break :blk try allocator.dupe(u8, buffer[0..len]);
        },
    };
    errdefer allocator.free(data);
    try entries.append(allocator, .{
        .kind = kind,
        .path = path,
        .mode = @intCast(stat.permissions.toMode() & 0o7777),
        .data = data,
    });
}

fn parseIndexPath(line: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    for (0..4) |_| {
        const separator = std.mem.indexOfScalarPos(u8, line, cursor, ' ') orelse return null;
        if (separator == cursor) return null;
        cursor = separator + 1;
    }
    if (cursor >= line.len) return null;
    return line[cursor..];
}

fn containsEntry(entries: []const Entry, path: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return true;
    return false;
}

pub fn decodeArchive(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
    var cursor: usize = 0;
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], "APCTSDT1")) return error.InvalidArchive;
    cursor = 8;
    const root_mode = try readInt(bytes, &cursor, u32);
    const count = try readInt(bytes, &cursor, u64);
    if (count > 1_000_000) return error.ArchiveLimitExceeded;
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    for (0..@intCast(count)) |_| {
        if (cursor >= bytes.len) return error.InvalidArchive;
        const kind: EntryKind = switch (bytes[cursor]) {
            1 => .directory,
            2 => .file,
            3 => .symlink,
            else => return error.InvalidArchive,
        };
        cursor += 1;
        const path_len = try readInt(bytes, &cursor, u32);
        const mode = try readInt(bytes, &cursor, u32);
        const data_len = try readInt(bytes, &cursor, u64);
        const path = try takeDupe(allocator, bytes, &cursor, path_len);
        errdefer allocator.free(path);
        const data = try takeDupe(allocator, bytes, &cursor, data_len);
        errdefer allocator.free(data);
        if (!validRelativePath(path)) return error.InvalidArchivePath;
        if (entries.items.len > 0 and std.mem.order(u8, entries.items[entries.items.len - 1].path, path) != .lt) return error.NonCanonicalArchive;
        try entries.append(allocator, .{ .kind = kind, .path = path, .mode = mode, .data = data });
    }
    if (cursor != bytes.len) return error.TrailingArchiveData;
    for (entries.items) |entry| {
        if (entry.kind != .symlink) continue;
        for (entries.items) |other| {
            if (other.path.len > entry.path.len and std.mem.startsWith(u8, other.path, entry.path) and other.path[entry.path.len] == std.fs.path.sep) return error.ArchivePathTraversesSymlink;
        }
    }
    return .{ .root_mode = root_mode, .entries = try entries.toOwnedSlice(allocator) };
}

pub fn restoreRepository(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, bytes: []const u8) !void {
    var archive = try decodeArchive(allocator, bytes);
    defer archive.deinit(allocator);
    std.Io.Dir.cwd().createDirPath(io, absolute_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);
    var existing = directory.iterate();
    if (try existing.next(io) != null) return error.RestoreTargetNotEmpty;
    for (archive.entries) |entry| if (entry.kind == .directory) try directory.createDirPath(io, entry.path);
    for (archive.entries) |entry| switch (entry.kind) {
        .directory => {},
        .file => {
            if (std.fs.path.dirname(entry.path)) |parent| try directory.createDirPath(io, parent);
            try directory.writeFile(io, .{ .sub_path = entry.path, .data = entry.data });
            var file = try directory.openFile(io, entry.path, .{ .mode = .read_write });
            defer file.close(io);
            try file.setPermissions(io, .fromMode(@intCast(entry.mode)));
        },
        .symlink => {
            if (std.fs.path.dirname(entry.path)) |parent| try directory.createDirPath(io, parent);
            try directory.symLink(io, entry.data, entry.path, .{});
        },
    };
    var index = archive.entries.len;
    while (index > 0) {
        index -= 1;
        const entry = archive.entries[index];
        if (entry.kind == .directory) {
            var child = try directory.openDir(io, entry.path, .{});
            defer child.close(io);
            try child.setPermissions(io, .fromMode(@intCast(entry.mode)));
        }
    }
    try directory.setPermissions(io, .fromMode(@intCast(archive.root_mode)));
}

fn lessThanEntry(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn appendInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn readInt(bytes: []const u8, cursor: *usize, comptime T: type) !T {
    if (cursor.* > bytes.len or bytes.len - cursor.* < @sizeOf(T)) return error.InvalidArchive;
    const result = std.mem.readInt(T, bytes[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* += @sizeOf(T);
    return result;
}

fn takeDupe(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, length: anytype) ![]u8 {
    const len = std.math.cast(usize, length) orelse return error.ArchiveLimitExceeded;
    if (cursor.* > bytes.len or bytes.len - cursor.* < len) return error.InvalidArchive;
    const result = try allocator.dupe(u8, bytes[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return result;
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isVcsMetadataPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".sdt") or
        std.mem.startsWith(u8, path, ".sdt/") or
        std.mem.eql(u8, path, ".git") or
        std.mem.startsWith(u8, path, ".git/");
}

fn isExcludedMetadataTree(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, std.fs.path.sep) != null) return false;
    return std.mem.eql(u8, path, "gitmirror") or std.mem.startsWith(u8, path, "apricot-fetch-");
}

test "Superdetermine repository archive preserves bytes modes directories and symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".sdt/objects/aa");
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/config", .data = "branch=main\n\x00native" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/objects/aa/id", .data = "\x00\xffobject" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/index", .data = "0 0 0 00 run\n0 0 0 00 current\n" });
    try source.dir.writeFile(io, .{ .sub_path = "run", .data = "#!/bin/sh\n" });
    var executable = try source.dir.openFile(io, "run", .{ .mode = .read_write });
    try executable.setPermissions(io, .fromMode(0o751));
    executable.close(io);
    try source.dir.symLink(io, "run", "current", .{});
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const archive = try captureRepository(allocator, io, source_path);
    defer allocator.free(archive);
    var decoded = try decodeArchive(allocator, archive);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), decoded.entries.len);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    try restoreRepository(allocator, io, destination_path, archive);
    const config = try destination.dir.readFileAlloc(io, ".sdt/config", allocator, .unlimited);
    defer allocator.free(config);
    try std.testing.expectEqualSlices(u8, "branch=main\n\x00native", config);
    const object = try destination.dir.readFileAlloc(io, ".sdt/objects/aa/id", allocator, .unlimited);
    defer allocator.free(object);
    try std.testing.expectEqualSlices(u8, "\x00\xffobject", object);
    const run_stat = try destination.dir.statFile(io, "run", .{});
    try std.testing.expectEqual(@as(u32, 0o751), @as(u32, @intCast(run_stat.permissions.toMode() & 0o777)));
    var target: [32]u8 = undefined;
    const target_len = try destination.dir.readLink(io, "current", &target);
    try std.testing.expectEqualSlices(u8, "run", target[0..target_len]);
}

test "Superdetermine adapter enumerates and restores one authoritative native object" {
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
    try source.dir.createDirPath(io, ".sdt/objects");
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/oplog", .data = "native-oplog" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/index", .data = "0 0 0 00 working\n" });
    try source.dir.writeFile(io, .{ .sub_path = "working", .data = "unsaved-is-still-native" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    var implementation = SuperdetermineAdapter.init(allocator, io, source_path, destination_path);
    defer implementation.deinit();
    const adapter = implementation.adapter();
    const snapshot_value = try adapter.snapshot();
    try std.testing.expectEqual(contract.PreservationTier.byte_lossless, snapshot_value.closure.tier);
    var collector = Collector{};
    try adapter.enumerate(snapshot_value.roots, .{ .context = &collector, .emitFn = Collector.emit });
    const report = try adapter.restore(snapshot_value, .{ .context = &collector, .getFn = Collector.get });
    try std.testing.expectEqual(contract.PreservationTier.byte_lossless, report.verified_tier);
    const working = try destination.dir.readFileAlloc(io, "working", allocator, .unlimited);
    defer allocator.free(working);
    try std.testing.expectEqualSlices(u8, "unsaved-is-still-native", working);
    const oplog = try destination.dir.readFileAlloc(io, ".sdt/oplog", allocator, .unlimited);
    defer allocator.free(oplog);
    try std.testing.expectEqualSlices(u8, "native-oplog", oplog);
}

test "archive decoder rejects traversal and trailing data" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "APCTSDT1");
    try appendInt(&bytes, allocator, u32, 0o755);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.append(allocator, @intFromEnum(EntryKind.file));
    try appendInt(&bytes, allocator, u32, 3);
    try appendInt(&bytes, allocator, u32, 0o644);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.appendSlice(allocator, "../x");
    try std.testing.expectError(error.InvalidArchivePath, decodeArchive(allocator, bytes.items));
}

test "capture excludes unindexed worktree paths and retains indexed dirty state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".sdt/objects");
    try source.dir.createDirPath(io, "src");
    try source.dir.createDirPath(io, ".zig-cache/nested");
    try source.dir.createDirPath(io, "zig-out/bin");
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/index", .data = "0 1 1 aa src/dirty\n0 1 2 bb linked\n" });
    try source.dir.writeFile(io, .{ .sub_path = "src/dirty", .data = "current-unsaved-bytes" });
    try source.dir.symLink(io, "src/dirty", "linked", .{});
    try source.dir.writeFile(io, .{ .sub_path = ".zig-cache/nested/large", .data = "ignored-cache" });
    try source.dir.writeFile(io, .{ .sub_path = "zig-out/bin/apct", .data = "ignored-output" });
    try source.dir.writeFile(io, .{ .sub_path = "unindexed", .data = "ignored-worktree" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const bytes = try captureRepository(allocator, io, source_path);
    defer allocator.free(bytes);
    var archive = try decodeArchive(allocator, bytes);
    defer archive.deinit(allocator);
    try std.testing.expect(containsEntry(archive.entries, ".sdt/index"));
    try std.testing.expect(containsEntry(archive.entries, "src"));
    try std.testing.expect(containsEntry(archive.entries, "src/dirty"));
    try std.testing.expect(containsEntry(archive.entries, "linked"));
    try std.testing.expect(!containsEntry(archive.entries, ".zig-cache"));
    try std.testing.expect(!containsEntry(archive.entries, "zig-out"));
    try std.testing.expect(!containsEntry(archive.entries, "unindexed"));
    for (archive.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "src/dirty")) try std.testing.expectEqualSlices(u8, "current-unsaved-bytes", entry.data);
    }
}

test "native closure excludes Git caches and transient fetches without affecting roundtrip or projection" {
    const ProjectionCollector = struct {
        len: usize = 0,
        saw_root: bool = false,
        saw_source: bool = false,

        fn resource(context: *anyopaque, value: contract.ProjectionResource) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.len += 1;
            if (std.mem.eql(u8, value.id, ".")) self.saw_root = true;
            if (std.mem.eql(u8, value.id, "source.zig")) self.saw_source = true;
            if (isVcsMetadataPath(value.id)) return error.MetadataLeakedIntoProjection;
        }

        fn relation(context: *anyopaque, value: contract.ProjectionRelation) !void {
            _ = context;
            _ = value;
        }

        fn entry(context: *anyopaque, value: contract.ProjectionEntryPoint) !void {
            _ = context;
            _ = value;
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".sdt/objects/aa");
    try source.dir.createDirPath(io, ".sdt/gitmirror/.git/objects/pack");
    try source.dir.createDirPath(io, ".sdt/apricot-fetch-9381/nested");
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/index", .data = "0 1 1 aa source.zig\n" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/config", .data = "head=main\n" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/objects/aa/native", .data = "\x00\xffauthoritative" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/gitmirror/.git/objects/pack/data", .data = "\x00\xfflegacy-git\x00" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/apricot-fetch-9381/nested/data", .data = "\xfftransient\x00fetch" });
    try source.dir.writeFile(io, .{ .sub_path = "source.zig", .data = "pub fn value() u8 { return 7; }\n" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    const first = try captureRepository(allocator, io, source_path);
    defer allocator.free(first);
    var decoded = try decodeArchive(allocator, first);
    defer decoded.deinit(allocator);
    try std.testing.expect(containsEntry(decoded.entries, ".sdt/config"));
    try std.testing.expect(containsEntry(decoded.entries, ".sdt/objects/aa/native"));
    try std.testing.expect(containsEntry(decoded.entries, "source.zig"));
    for (decoded.entries) |entry_value| {
        try std.testing.expect(!std.mem.startsWith(u8, entry_value.path, ".sdt/gitmirror"));
        try std.testing.expect(!std.mem.startsWith(u8, entry_value.path, ".sdt/apricot-fetch-"));
    }
    try restoreRepository(allocator, io, destination_path, first);
    const second = try captureRepository(allocator, io, destination_path);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    var implementation = SuperdetermineAdapter.init(allocator, io, source_path, destination_path);
    defer implementation.deinit();
    const adapter = implementation.adapter();
    const snapshot_value = try adapter.snapshot();
    var projection = ProjectionCollector{};
    try adapter.project(snapshot_value, .{
        .context = &projection,
        .emitResourceFn = ProjectionCollector.resource,
        .emitRelationFn = ProjectionCollector.relation,
        .emitEntryPointFn = ProjectionCollector.entry,
    });
    try std.testing.expectEqual(@as(usize, 2), projection.len);
    try std.testing.expect(projection.saw_root);
    try std.testing.expect(projection.saw_source);
}
