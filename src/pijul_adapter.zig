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

pub const PijulAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    restore_path: []const u8,
    tracked_paths: ?[]const []const u8 = null,
    archive_bytes: ?[]u8 = null,
    digest: [32]u8 = undefined,
    root: [1]contract.NativeRoot = undefined,
    native_ref: [1]contract.NativeRef = undefined,

    const capabilities = [_]contract.Capability{
        .{ .name = "opaque-native-repository", .support = .required },
        .{ .name = "change-graph", .support = .required },
        .{ .name = "channels", .support = .required },
        .{ .name = "filesystem-executable-bit", .support = .required },
        .{ .name = "filesystem-symbolic-link", .support = .required },
        .{ .name = "foreign-operation-import", .support = .unsupported },
        .{ .name = "commit-dag", .support = .unsupported },
    };
    const authoritative_kinds = [_][]const u8{"pijul-repository-archive"};
    const exclusions = [_]contract.ClosureExclusion{
        .{ .namespace = "filesystem.timestamps", .reason = "not authoritative to Pijul repository semantics", .affects_semantics = false },
        .{ .namespace = "filesystem.ownership", .reason = "host-local identity metadata", .affects_semantics = false },
        .{ .namespace = "filesystem.extended-attributes", .reason = "not authoritative to Pijul repository semantics", .affects_semantics = false },
        .{ .namespace = "pijul.user-credentials", .reason = "user identities and private keys are external credentials", .affects_semantics = false },
        .{ .namespace = "worktree.untracked", .reason = "untracked and ignored worktree paths are non-authoritative and may contain credentials", .affects_semantics = false },
        .{ .namespace = "other-vcs.metadata", .reason = "co-located metadata owned by another version control system", .affects_semantics = false },
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8) PijulAdapter {
        return .{
            .allocator = allocator,
            .io = io,
            .repository_path = repository_path,
            .restore_path = restore_path,
        };
    }

    pub fn initWithTrackedPaths(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8, tracked_paths: []const []const u8) PijulAdapter {
        var result = init(allocator, io, repository_path, restore_path);
        result.tracked_paths = tracked_paths;
        return result;
    }

    pub fn deinit(self: *PijulAdapter) void {
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
    }

    pub fn adapter(self: *PijulAdapter) contract.Adapter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn cast(context: *anyopaque) *PijulAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn snapshot(context: *anyopaque) !contract.Snapshot {
        const self = cast(context);
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
        self.archive_bytes = if (self.tracked_paths) |paths|
            try captureRepositoryFromPaths(self.allocator, self.io, self.repository_path, paths)
        else
            try captureRepository(self.allocator, self.io, self.repository_path);
        std.crypto.hash.sha2.Sha256.hash(self.archive_bytes.?, &self.digest, .{});
        const id = contract.NativeId{ .scheme = "apricot-pijul-archive-sha256-v1", .bytes = &self.digest };
        self.root[0] = .{ .role = "repository", .id = id };
        self.native_ref[0] = .{ .namespace = "repository", .name = "exact", .target = id, .mutable = true };
        return .{
            .vcs = "pijul",
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
            .kind = "pijul-repository-archive",
            .bytes = bytes,
        });
    }

    fn restore(context: *anyopaque, snapshot_value: contract.Snapshot, source: contract.ObjectSource) !contract.RestoreReport {
        const self = cast(context);
        if (snapshot_value.roots.len != 1) return error.InvalidSnapshot;
        const root_id = snapshot_value.roots[0].id;
        if (!std.mem.eql(u8, root_id.scheme, "apricot-pijul-archive-sha256-v1") or root_id.bytes.len != 32) return error.InvalidSnapshot;
        const object = try source.get(root_id) orelse return error.MissingObject;
        if (!std.mem.eql(u8, object.kind, "pijul-repository-archive")) return error.InvalidObjectKind;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object.bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, root_id.bytes)) return error.CorruptObject;
        try restoreRepository(self.allocator, self.io, self.restore_path, object.bytes);
        self.digest = actual;
        self.root[0] = .{ .role = "repository", .id = .{ .scheme = "apricot-pijul-archive-sha256-v1", .bytes = &self.digest } };
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
            .file => if (!isMetadataPath(entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "file", .media_type = "application/octet-stream", .payload = entry.data });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .symlink => if (!isMetadataPath(entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "symlink", .media_type = "application/vnd.apricot.symlink", .payload = entry.data });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .directory => {},
        };
        try sink.emitEntryPoint(.{ .namespace = "channels", .name = "current", .resource = "." });
    }

    fn inspectForeign(context: *anyopaque, operation: contract.ForeignOperation) !contract.ForeignInspection {
        _ = cast(context);
        _ = operation;
        return .{ .refused = .{ .reason = "foreign projection changes require an explicit Pijul import policy" } };
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
    for (0..8) |_| {
        const first = try captureRepositoryOnceUsingPijul(allocator, io, absolute_path);
        const second = try captureRepositoryOnceUsingPijul(allocator, io, absolute_path);
        if (std.mem.eql(u8, first, second)) {
            allocator.free(second);
            return first;
        }
        allocator.free(second);
        allocator.free(first);
    }
    return error.RepositoryMutatedDuringCapture;
}

pub fn captureRepositoryFromPaths(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, tracked_paths: []const []const u8) ![]u8 {
    for (0..8) |_| {
        const first = try captureRepositoryOnce(allocator, io, absolute_path, tracked_paths);
        const second = try captureRepositoryOnce(allocator, io, absolute_path, tracked_paths);
        if (std.mem.eql(u8, first, second)) {
            allocator.free(second);
            return first;
        }
        allocator.free(second);
        allocator.free(first);
    }
    return error.RepositoryMutatedDuringCapture;
}

const TrackedPaths = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    paths: [][]const u8,

    fn deinit(self: TrackedPaths) void {
        self.allocator.free(self.paths);
        self.allocator.free(self.stdout);
    }
};

fn listTrackedPaths(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !TrackedPaths {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pijul", "list", "--repository", absolute_path },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.PijulExecutableNotFound,
        error.StreamTooLong => error.PijulOutputLimitExceeded,
        else => err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |status| if (status != 0) return error.PijulListFailed,
        else => return error.PijulListFailed,
    }
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const path = std.mem.trimEnd(u8, raw_line, "\r");
        if (path.len == 0) continue;
        if (!validRelativePath(path) or isMetadataPath(path) or isExcludedTree(path)) return error.InvalidTrackedPath;
        for (paths.items) |earlier| if (std.mem.eql(u8, earlier, path)) return error.DuplicateTrackedPath;
        try paths.append(allocator, path);
    }
    return .{ .allocator = allocator, .stdout = result.stdout, .paths = try paths.toOwnedSlice(allocator) };
}

fn captureRepositoryOnceUsingPijul(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    try rejectAmbiguousRepositoryPaths(allocator, io, absolute_path);
    const tracked = try listTrackedPaths(allocator, io, absolute_path);
    defer tracked.deinit();
    return captureRepositoryOnce(allocator, io, absolute_path, tracked.paths);
}

fn captureRepositoryOnce(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, tracked_paths: []const []const u8) ![]u8 {
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);
    const metadata_stat = directory.statFile(io, ".pijul", .{ .follow_symlinks = false }) catch return error.NotPijulRepository;
    if (metadata_stat.kind != .directory) return error.NotPijulRepository;
    const root_stat = try directory.statFile(io, ".", .{});
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    try appendPath(allocator, io, directory, ".pijul", &entries);
    var metadata = try directory.openDir(io, ".pijul", .{ .iterate = true });
    defer metadata.close(io);
    var walker = try metadata.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (walked.kind == .directory) {
            try walker.enter(io, walked);
        }
        const path = try std.fmt.allocPrint(allocator, ".pijul/{s}", .{walked.path});
        defer allocator.free(path);
        try appendPath(allocator, io, directory, path, &entries);
    }
    for (tracked_paths) |path| {
        if (!validRelativePath(path) or isMetadataPath(path) or isExcludedTree(path)) return error.InvalidTrackedPath;
        appendTrackedPath(allocator, io, directory, path, &entries) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    const metadata_entry = findEntry(entries.items, ".pijul") orelse return error.NotPijulRepository;
    if (metadata_entry.kind != .directory) return error.NotPijulRepository;
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "APCTPIJ1");
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

fn appendTrackedPath(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8, entries: *std.ArrayList(Entry)) !void {
    var parent = std.fs.path.dirname(path) orelse "";
    var parents: std.ArrayList([]const u8) = .empty;
    defer parents.deinit(allocator);
    while (parent.len > 0) {
        if (isMetadataPath(parent) or isExcludedTree(parent)) return error.InvalidTrackedPath;
        try parents.append(allocator, parent);
        parent = std.fs.path.dirname(parent) orelse break;
    }
    var index = parents.items.len;
    while (index > 0) {
        index -= 1;
        if (!containsEntry(entries.items, parents.items[index])) try appendPath(allocator, io, directory, parents.items[index], entries);
    }
    if (!containsEntry(entries.items, path)) try appendPath(allocator, io, directory, path, entries);
}

fn appendPath(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path_value: []const u8, entries: *std.ArrayList(Entry)) !void {
    if (!validRelativePath(path_value)) return error.InvalidRepositoryPath;
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

pub fn decodeArchive(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
    var cursor: usize = 0;
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], "APCTPIJ1")) return error.InvalidArchive;
    cursor = 8;
    const root_mode = try readInt(bytes, &cursor, u32);
    if (root_mode > 0o7777) return error.InvalidMode;
    const count = try readInt(bytes, &cursor, u64);
    if (count == 0 or count > 1_000_000) return error.ArchiveLimitExceeded;
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var total_data: u64 = 0;
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
        if (mode > 0o7777 or path_len == 0 or path_len > std.fs.max_path_bytes or data_len > 8 * 1024 * 1024 * 1024) return error.ArchiveLimitExceeded;
        total_data = std.math.add(u64, total_data, data_len) catch return error.ArchiveLimitExceeded;
        if (total_data > 64 * 1024 * 1024 * 1024) return error.ArchiveLimitExceeded;
        const path = try takeDupe(allocator, bytes, &cursor, path_len);
        errdefer allocator.free(path);
        const data = try takeDupe(allocator, bytes, &cursor, data_len);
        errdefer allocator.free(data);
        if (!validRelativePath(path)) return error.InvalidArchivePath;
        if (kind == .directory and data.len != 0) return error.InvalidArchive;
        if (entries.items.len > 0 and std.mem.order(u8, entries.items[entries.items.len - 1].path, path) != .lt) return error.NonCanonicalArchive;
        try entries.append(allocator, .{ .kind = kind, .path = path, .mode = mode, .data = data });
    }
    if (cursor != bytes.len) return error.TrailingArchiveData;
    const metadata = findEntry(entries.items, ".pijul") orelse return error.NotPijulRepository;
    if (metadata.kind != .directory) return error.NotPijulRepository;
    for (entries.items, 0..) |entry, index| {
        var parent = std.fs.path.dirname(entry.path);
        while (parent) |path| {
            if (findEntry(entries.items, path)) |parent_entry| if (parent_entry.kind != .directory) return error.ArchivePathTraversesNonDirectory;
            parent = std.fs.path.dirname(path);
        }
        if (entry.kind == .symlink) {
            if (entry.data.len == 0 or std.mem.indexOfScalar(u8, entry.data, 0) != null) return error.InvalidSymlink;
            for (entries.items[index + 1 ..]) |other| {
                if (other.path.len > entry.path.len and std.mem.startsWith(u8, other.path, entry.path) and other.path[entry.path.len] == std.fs.path.sep) return error.ArchivePathTraversesSymlink;
            }
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
    if (std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn containsEntry(entries: []const Entry, path: []const u8) bool {
    return findEntry(entries, path) != null;
}

fn findEntry(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

fn isMetadataPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".pijul") or std.mem.startsWith(u8, path, ".pijul/");
}

fn isExcludedTree(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '/') != null) return false;
    return std.mem.eql(u8, path, ".git") or std.mem.eql(u8, path, ".sdt") or std.mem.eql(u8, path, ".jj");
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

test "Pijul archive rejects traversal duplicate paths trailing data and symlink descendants" {
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
}
