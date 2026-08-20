const std = @import("std");
const builtin = @import("builtin");
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

pub const Limits = struct {
    stable_attempts: u8 = 8,
    max_entries: u64 = 1_000_000,
    max_path_bytes: u32 = std.fs.max_path_bytes,
    max_total_path_bytes: u64 = 1024 * 1024 * 1024,
    max_entry_bytes: u64 = 8 * 1024 * 1024 * 1024,
    max_total_bytes: u64 = 64 * 1024 * 1024 * 1024,
};

pub const PathPolicy = struct {
    allow_backslash: bool = false,
};

pub const PathExclusion = struct {
    path: []const u8,
    recursive: bool = true,
};

pub const PathFilter = struct {
    context: *anyopaque,
    excludeFn: *const fn (context: *anyopaque, path: []const u8) anyerror!bool,

    pub fn excludes(self: PathFilter, path: []const u8) !bool {
        return self.excludeFn(self.context, path);
    }
};

pub const TrackedPathSink = struct {
    context: *anyopaque,
    addFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,

    pub fn add(self: TrackedPathSink, path: []const u8) !void {
        return self.addFn(self.context, path);
    }
};

pub const TrackedPathProvider = struct {
    context: *anyopaque,
    listFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, sink: TrackedPathSink) anyerror!void,

    pub fn list(self: TrackedPathProvider, allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, sink: TrackedPathSink) !void {
        return self.listFn(self.context, allocator, io, repository_path, sink);
    }
};

pub const CaptureSession = struct {
    context: *anyopaque,
    addMetadataPathFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    addMetadataTreeFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    addTrackedPathFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,

    pub fn addMetadataPath(self: CaptureSession, path: []const u8) !void {
        return self.addMetadataPathFn(self.context, path);
    }

    pub fn addMetadataTree(self: CaptureSession, path: []const u8) !void {
        return self.addMetadataTreeFn(self.context, path);
    }

    pub fn addTrackedPath(self: CaptureSession, path: []const u8) !void {
        return self.addTrackedPathFn(self.context, path);
    }
};

pub const CaptureHook = struct {
    context: *anyopaque,
    captureFn: *const fn (context: *anyopaque, repository_path: []const u8, session: CaptureSession) anyerror!void,

    pub fn capture(self: CaptureHook, repository_path: []const u8, session: CaptureSession) !void {
        return self.captureFn(self.context, repository_path, session);
    }
};

pub const RestoreHook = struct {
    context: *anyopaque,
    restoredFn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,

    pub fn restored(self: RestoreHook, path: []const u8) !void {
        return self.restoredFn(self.context, path);
    }
};

pub const ProjectionHook = struct {
    context: *anyopaque,
    projectFn: *const fn (context: *anyopaque, archive: *const Archive, sink: contract.ProjectionSink) anyerror!void,

    pub fn project(self: ProjectionHook, archive: *const Archive, sink: contract.ProjectionSink) !void {
        return self.projectFn(self.context, archive, sink);
    }
};

pub const ForeignHooks = struct {
    context: *anyopaque,
    inspectFn: *const fn (context: *anyopaque, operation: contract.ForeignOperation) anyerror!contract.ForeignInspection,
    importFn: *const fn (context: *anyopaque, operation: contract.ForeignOperation, source: contract.ObjectSource) anyerror!contract.ForeignOutcome,
};

pub const Definition = struct {
    vcs: []const u8,
    format_version: []const u8,
    id_scheme: []const u8,
    object_kind: []const u8,
    archive_magic: []const u8 = "APCTFS01",
    metadata_roots: []const []const u8,
    tracked_paths: []const []const u8 = &.{},
    tracked_provider: ?TrackedPathProvider = null,
    capture_hook: ?CaptureHook = null,
    restore_hook: ?RestoreHook = null,
    projection_hook: ?ProjectionHook = null,
    foreign_hooks: ?ForeignHooks = null,
    path_exclusions: []const PathExclusion = &.{},
    path_filter: ?PathFilter = null,
    projection_exclusions: []const PathExclusion = &.{},
    capabilities: []const contract.Capability,
    closure_exclusions: []const contract.ClosureExclusion,
    preservation_tier: contract.PreservationTier = .byte_lossless,
    root_role: []const u8 = "repository",
    ref_namespace: []const u8 = "repository",
    ref_name: []const u8 = "exact",
    ref_mutable: bool = true,
    projection_namespace: []const u8 = "heads",
    projection_name: []const u8 = "main",
    foreign_refusal_reason: []const u8 = "foreign projection changes require an explicit native import policy",
    path_policy: PathPolicy = .{},
    limits: Limits = .{},
};

pub const FilesystemAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    restore_path: []const u8,
    definition: Definition,
    archive_bytes: ?[]u8 = null,
    digest: [32]u8 = undefined,
    root: [1]contract.NativeRoot = undefined,
    native_ref: [1]contract.NativeRef = undefined,
    authoritative_kind: [1][]const u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, restore_path: []const u8, definition: Definition) !FilesystemAdapter {
        try validateDefinition(definition);
        return .{
            .allocator = allocator,
            .io = io,
            .repository_path = repository_path,
            .restore_path = restore_path,
            .definition = definition,
        };
    }

    pub fn deinit(self: *FilesystemAdapter) void {
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
    }

    pub fn adapter(self: *FilesystemAdapter) contract.Adapter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn cast(context: *anyopaque) *FilesystemAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn snapshot(context: *anyopaque) !contract.Snapshot {
        const self = cast(context);
        const next = try captureStable(self.allocator, self.io, self.repository_path, self.definition);
        if (self.archive_bytes) |bytes| self.allocator.free(bytes);
        self.archive_bytes = next;
        std.crypto.hash.sha2.Sha256.hash(next, &self.digest, .{});
        const id = contract.NativeId{ .scheme = self.definition.id_scheme, .bytes = &self.digest };
        self.root[0] = .{ .role = self.definition.root_role, .id = id };
        self.native_ref[0] = .{
            .namespace = self.definition.ref_namespace,
            .name = self.definition.ref_name,
            .target = id,
            .mutable = self.definition.ref_mutable,
        };
        self.authoritative_kind[0] = self.definition.object_kind;
        return .{
            .vcs = self.definition.vcs,
            .format_version = self.definition.format_version,
            .roots = &self.root,
            .refs = &self.native_ref,
            .capabilities = self.definition.capabilities,
            .closure = .{
                .tier = self.definition.preservation_tier,
                .authoritative_kinds = &self.authoritative_kind,
                .exclusions = self.definition.closure_exclusions,
            },
        };
    }

    fn enumerate(context: *anyopaque, roots: []const contract.NativeRoot, sink: contract.ObjectSink) !void {
        const self = cast(context);
        const bytes = self.archive_bytes orelse return error.SnapshotRequired;
        if (roots.len != 1 or !roots[0].id.eql(self.root[0].id)) return error.UnknownRoot;
        try sink.emit(.{ .id = self.root[0].id, .kind = self.definition.object_kind, .bytes = bytes });
    }

    fn restore(context: *anyopaque, snapshot_value: contract.Snapshot, source: contract.ObjectSource) !contract.RestoreReport {
        const self = cast(context);
        if (snapshot_value.roots.len != 1) return error.InvalidSnapshot;
        const root_id = snapshot_value.roots[0].id;
        if (!std.mem.eql(u8, root_id.scheme, self.definition.id_scheme) or root_id.bytes.len != 32) return error.InvalidSnapshot;
        const object = try source.get(root_id) orelse return error.MissingObject;
        if (!std.mem.eql(u8, object.kind, self.definition.object_kind)) return error.InvalidObjectKind;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object.bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, root_id.bytes)) return error.CorruptObject;
        try restoreArchive(self.allocator, self.io, self.restore_path, object.bytes, self.definition);
        if (self.definition.restore_hook) |hook| try hook.restored(self.restore_path);
        const verified = try captureStable(self.allocator, self.io, self.restore_path, self.definition);
        defer self.allocator.free(verified);
        if (!std.mem.eql(u8, verified, object.bytes)) return error.RestoreVerificationFailed;
        self.digest = actual;
        self.root[0] = .{ .role = self.definition.root_role, .id = .{ .scheme = self.definition.id_scheme, .bytes = &self.digest } };
        return .{ .roots = &self.root, .verified_tier = self.definition.preservation_tier };
    }

    fn project(context: *anyopaque, snapshot_value: contract.Snapshot, sink: contract.ProjectionSink) !void {
        const self = cast(context);
        const bytes = self.archive_bytes orelse return error.SnapshotRequired;
        if (snapshot_value.roots.len != 1 or !snapshot_value.roots[0].id.eql(self.root[0].id)) return error.InvalidSnapshot;
        var archive = try decodeArchive(self.allocator, bytes, self.definition);
        defer archive.deinit(self.allocator);
        if (self.definition.projection_hook) |hook| return hook.project(&archive, sink);
        try sink.emitResource(.{ .id = ".", .kind = "tree", .media_type = "application/vnd.apricot.tree", .payload = "" });
        for (archive.entries) |entry| switch (entry.kind) {
            .file => if (!isProjectionExcluded(self.definition, entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "file", .media_type = "application/octet-stream", .payload = entry.data, .executable = entry.mode & 0o111 != 0 });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .symlink => if (!isProjectionExcluded(self.definition, entry.path)) {
                try sink.emitResource(.{ .id = entry.path, .kind = "symlink", .media_type = "application/vnd.apricot.symlink", .payload = entry.data });
                try sink.emitRelation(.{ .kind = "contains", .source = ".", .target = entry.path });
            },
            .directory => {},
        };
        try sink.emitEntryPoint(.{ .namespace = self.definition.projection_namespace, .name = self.definition.projection_name, .resource = "." });
    }

    fn inspectForeign(context: *anyopaque, operation: contract.ForeignOperation) !contract.ForeignInspection {
        const self = cast(context);
        if (self.definition.foreign_hooks) |hooks| return hooks.inspectFn(hooks.context, operation);
        return .{ .refused = .{ .reason = self.definition.foreign_refusal_reason } };
    }

    fn importForeign(context: *anyopaque, operation: contract.ForeignOperation, source: contract.ObjectSource) !contract.ForeignOutcome {
        const self = cast(context);
        if (self.definition.foreign_hooks) |hooks| return hooks.importFn(hooks.context, operation, source);
        return .{ .refused = .{ .reason = self.definition.foreign_refusal_reason } };
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

pub fn validateDefinition(definition: Definition) !void {
    if (definition.vcs.len == 0 or definition.format_version.len == 0) return error.InvalidIdentity;
    if (definition.id_scheme.len == 0 or definition.object_kind.len == 0) return error.InvalidObjectIdentity;
    if (definition.archive_magic.len != 8) return error.InvalidArchiveMagic;
    if (definition.path_policy.allow_backslash and builtin.os.tag == .windows) return error.InvalidPathPolicy;
    if (definition.metadata_roots.len == 0) return error.MissingMetadataRoot;
    if (definition.capture_hook != null and (definition.tracked_paths.len != 0 or definition.tracked_provider != null)) return error.AmbiguousCaptureConfiguration;
    if (definition.tracked_paths.len != 0 and definition.tracked_provider != null) return error.AmbiguousTrackedPathProvider;
    if (definition.root_role.len == 0 or definition.ref_namespace.len == 0 or definition.ref_name.len == 0) return error.InvalidReferenceIdentity;
    if (definition.projection_namespace.len == 0 or definition.projection_name.len == 0) return error.InvalidProjectionIdentity;
    if (definition.foreign_refusal_reason.len == 0) return error.InvalidForeignRefusalReason;
    if (definition.limits.stable_attempts == 0 or definition.limits.max_entries == 0 or definition.limits.max_path_bytes == 0 or definition.limits.max_total_path_bytes == 0 or definition.limits.max_entry_bytes == 0 or definition.limits.max_total_bytes == 0) return error.InvalidLimits;
    for (definition.metadata_roots, 0..) |path, index| {
        if (!validRelativePath(path, definition.path_policy)) return error.InvalidMetadataRoot;
        for (definition.metadata_roots[0..index]) |earlier| if (pathMatches(.{ .path = earlier }, path) or pathMatches(.{ .path = path }, earlier)) return error.OverlappingMetadataRoots;
        if (try pathExcluded(definition, path)) return error.ExcludedMetadataRoot;
    }
    for (definition.tracked_paths, 0..) |path, index| {
        try validateTrackedPath(definition, path);
        for (definition.tracked_paths[0..index]) |earlier| if (std.mem.eql(u8, path, earlier)) return error.DuplicateTrackedPath;
    }
    for (definition.path_exclusions, 0..) |exclusion, index| {
        if (!validRelativePath(exclusion.path, definition.path_policy)) return error.InvalidExclusionPath;
        for (definition.path_exclusions[0..index]) |earlier| if (std.mem.eql(u8, earlier.path, exclusion.path)) return error.DuplicateExclusionPath;
    }
    for (definition.projection_exclusions, 0..) |exclusion, index| {
        if (!validRelativePath(exclusion.path, definition.path_policy)) return error.InvalidProjectionExclusion;
        for (definition.projection_exclusions[0..index]) |earlier| if (std.mem.eql(u8, earlier.path, exclusion.path)) return error.DuplicateProjectionExclusion;
    }
    for (definition.closure_exclusions) |exclusion| if (exclusion.affects_semantics) return error.LosslessExclusionAffectsSemantics;
}

pub fn captureStable(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, definition: Definition) ![]u8 {
    try validateDefinition(definition);
    for (0..definition.limits.stable_attempts) |_| {
        const first = try captureOnce(allocator, io, absolute_path, definition);
        const second = captureOnce(allocator, io, absolute_path, definition) catch |err| {
            allocator.free(first);
            return err;
        };
        if (std.mem.eql(u8, first, second)) {
            allocator.free(second);
            return first;
        }
        allocator.free(first);
        allocator.free(second);
    }
    return error.RepositoryMutatedDuringCapture;
}

pub fn captureOnce(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, definition: Definition) ![]u8 {
    try validateDefinition(definition);
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);
    const root_stat = try directory.statFile(io, ".", .{});
    var state = CaptureState{
        .allocator = allocator,
        .io = io,
        .directory = directory,
        .definition = definition,
    };
    defer state.deinit();
    if (definition.capture_hook) |hook| {
        try hook.capture(absolute_path, state.session());
    } else {
        for (definition.metadata_roots) |path| try state.addMetadata(path);
        if (definition.tracked_provider) |provider| {
            try provider.list(allocator, io, absolute_path, .{ .context = &state, .addFn = CaptureState.addTrackedOpaque });
        } else {
            for (definition.tracked_paths) |path| try state.addTracked(path);
        }
    }
    try state.validateClosure();
    std.mem.sort(Entry, state.entries.items, {}, lessThanEntry);
    return encodeArchive(allocator, @intCast(root_stat.permissions.toMode() & 0o7777), state.entries.items, definition.archive_magic, definition.path_policy, definition.limits);
}

const CaptureState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    definition: Definition,
    entries: std.ArrayList(Entry) = .empty,
    requested_tracked: std.ArrayList([]u8) = .empty,
    total_path_bytes: u64 = 0,
    total_data_bytes: u64 = 0,

    fn deinit(self: *CaptureState) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.requested_tracked.items) |path| self.allocator.free(path);
        self.requested_tracked.deinit(self.allocator);
    }

    fn session(self: *CaptureState) CaptureSession {
        return .{
            .context = self,
            .addMetadataPathFn = addMetadataPathOpaque,
            .addMetadataTreeFn = addMetadataOpaque,
            .addTrackedPathFn = addTrackedOpaque,
        };
    }

    fn addMetadataOpaque(context: *anyopaque, path: []const u8) !void {
        const self: *CaptureState = @ptrCast(@alignCast(context));
        try self.addTree(path, true);
    }

    fn addMetadataPathOpaque(context: *anyopaque, path: []const u8) !void {
        const self: *CaptureState = @ptrCast(@alignCast(context));
        try self.addMetadata(path);
    }

    fn addTrackedOpaque(context: *anyopaque, path: []const u8) !void {
        const self: *CaptureState = @ptrCast(@alignCast(context));
        try self.addTracked(path);
    }

    fn addTracked(self: *CaptureState, path: []const u8) !void {
        try validateTrackedPath(self.definition, path);
        for (self.requested_tracked.items) |earlier| if (std.mem.eql(u8, earlier, path)) return error.DuplicateTrackedPath;
        const requested = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(requested);
        try self.requested_tracked.append(self.allocator, requested);
        var parent = std.fs.path.dirname(path) orelse "";
        var parents: std.ArrayList([]const u8) = .empty;
        defer parents.deinit(self.allocator);
        while (parent.len > 0) {
            if (try pathExcluded(self.definition, parent)) return error.ExcludedTrackedPath;
            try parents.append(self.allocator, parent);
            parent = std.fs.path.dirname(parent) orelse break;
        }
        var index = parents.items.len;
        while (index > 0) {
            index -= 1;
            if (!self.contains(parents.items[index])) try self.addOne(parents.items[index]);
            if (self.find(parents.items[index]).?.kind != .directory) return error.ArchivePathTraversesNonDirectory;
        }
        if (!self.contains(path)) self.addOne(path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    fn addTree(self: *CaptureState, path: []const u8, required: bool) !void {
        if (!validRelativePath(path, self.definition.path_policy)) return error.InvalidRepositoryPath;
        if (try pathExcluded(self.definition, path)) return error.ExcludedRepositoryPath;
        var parent = std.fs.path.dirname(path) orelse "";
        var parents: std.ArrayList([]const u8) = .empty;
        defer parents.deinit(self.allocator);
        while (parent.len > 0) {
            if (try pathExcluded(self.definition, parent)) return error.ExcludedRepositoryPath;
            try parents.append(self.allocator, parent);
            parent = std.fs.path.dirname(parent) orelse break;
        }
        var parent_index = parents.items.len;
        while (parent_index > 0) {
            parent_index -= 1;
            if (!self.contains(parents.items[parent_index])) try self.addOne(parents.items[parent_index]);
            if (self.find(parents.items[parent_index]).?.kind != .directory) return error.ArchivePathTraversesNonDirectory;
        }
        if (!self.contains(path)) self.addOne(path) catch |err| switch (err) {
            error.FileNotFound => if (required) return error.MissingMetadataRoot else return,
            else => return err,
        };
        const entry = self.find(path) orelse return error.MissingMetadataRoot;
        if (entry.kind != .directory) return error.MetadataRootNotDirectory;
        try self.walkTree(path);
    }

    fn walkTree(self: *CaptureState, path: []const u8) !void {
        var child = try self.directory.openDir(self.io, path, .{ .iterate = true });
        defer child.close(self.io);
        var walker = try child.walkSelectively(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |walked| {
            const nested = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, walked.path });
            defer self.allocator.free(nested);
            if (try pathExcluded(self.definition, nested)) continue;
            if (walked.kind == .directory) try walker.enter(self.io, walked);
            if (!self.contains(nested)) try self.addOne(nested);
        }
    }

    fn addMetadata(self: *CaptureState, path: []const u8) !void {
        if (!validRelativePath(path, self.definition.path_policy)) return error.InvalidRepositoryPath;
        if (try pathExcluded(self.definition, path)) return error.ExcludedRepositoryPath;
        var parent = std.fs.path.dirname(path) orelse "";
        var parents: std.ArrayList([]const u8) = .empty;
        defer parents.deinit(self.allocator);
        while (parent.len > 0) {
            if (try pathExcluded(self.definition, parent)) return error.ExcludedRepositoryPath;
            try parents.append(self.allocator, parent);
            parent = std.fs.path.dirname(parent) orelse break;
        }
        var index = parents.items.len;
        while (index > 0) {
            index -= 1;
            if (!self.contains(parents.items[index])) try self.addOne(parents.items[index]);
            if (self.find(parents.items[index]).?.kind != .directory) return error.ArchivePathTraversesNonDirectory;
        }
        if (!self.contains(path)) self.addOne(path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingMetadataRoot,
            else => return err,
        };
        const entry = self.find(path) orelse return error.MissingMetadataRoot;
        switch (entry.kind) {
            .directory => try self.walkTree(path),
            .file => {},
            .symlink => return error.MetadataRootUnsupportedKind,
        }
    }

    fn addOne(self: *CaptureState, path: []const u8) !void {
        if (!validRelativePath(path, self.definition.path_policy)) return error.InvalidRepositoryPath;
        if (try pathExcluded(self.definition, path)) return error.ExcludedRepositoryPath;
        if (self.entries.items.len >= self.definition.limits.max_entries) return error.ArchiveLimitExceeded;
        const next_path_total = std.math.add(u64, self.total_path_bytes, path.len) catch return error.ArchiveLimitExceeded;
        if (path.len > self.definition.limits.max_path_bytes or next_path_total > self.definition.limits.max_total_path_bytes) return error.ArchiveLimitExceeded;
        const stat = try self.directory.statFile(self.io, path, .{ .follow_symlinks = false });
        const kind: EntryKind = switch (stat.kind) {
            .directory => .directory,
            .file => .file,
            .sym_link => .symlink,
            else => return error.UnsupportedFilesystemEntry,
        };
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const data = switch (kind) {
            .directory => try self.allocator.alloc(u8, 0),
            .file => blk: {
                const remaining = self.definition.limits.max_total_bytes - self.total_data_bytes;
                break :blk try self.directory.readFileAlloc(self.io, path, self.allocator, .limited(@min(self.definition.limits.max_entry_bytes, remaining)));
            },
            .symlink => blk: {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = try self.directory.readLink(self.io, path, &buffer);
                break :blk try self.allocator.dupe(u8, buffer[0..len]);
            },
        };
        errdefer self.allocator.free(data);
        const next_data_total = std.math.add(u64, self.total_data_bytes, data.len) catch return error.ArchiveLimitExceeded;
        if (data.len > self.definition.limits.max_entry_bytes or next_data_total > self.definition.limits.max_total_bytes) return error.ArchiveLimitExceeded;
        try self.entries.append(self.allocator, .{
            .kind = kind,
            .path = owned_path,
            .mode = @intCast(stat.permissions.toMode() & 0o7777),
            .data = data,
        });
        self.total_path_bytes = next_path_total;
        self.total_data_bytes = next_data_total;
    }

    fn contains(self: CaptureState, path: []const u8) bool {
        return self.find(path) != null;
    }

    fn find(self: CaptureState, path: []const u8) ?Entry {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
        return null;
    }

    fn validateClosure(self: CaptureState) !void {
        if (self.entries.items.len == 0) return error.EmptyCapture;
        for (self.definition.metadata_roots) |metadata_root| {
            const metadata = self.find(metadata_root) orelse return error.MissingMetadataRoot;
            if (metadata.kind == .symlink) return error.MetadataRootUnsupportedKind;
        }
        for (self.entries.items) |entry| {
            var parent = std.fs.path.dirname(entry.path);
            while (parent) |path| {
                if (self.find(path)) |parent_entry| if (parent_entry.kind != .directory) return error.ArchivePathTraversesNonDirectory;
                parent = std.fs.path.dirname(path);
            }
        }
    }
};

pub fn encodeArchive(allocator: std.mem.Allocator, root_mode: u32, entries: []const Entry, archive_magic: []const u8, path_policy: PathPolicy, limits: Limits) ![]u8 {
    if (root_mode > 0o7777 or entries.len == 0 or entries.len > limits.max_entries) return error.ArchiveLimitExceeded;
    if (archive_magic.len != 8) return error.InvalidArchiveMagic;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, archive_magic);
    try appendInt(&output, allocator, u32, root_mode);
    try appendInt(&output, allocator, u64, entries.len);
    var total_data: u64 = 0;
    var total_paths: u64 = 0;
    for (entries, 0..) |entry, index| {
        if (!validRelativePath(entry.path, path_policy) or entry.path.len > limits.max_path_bytes) return error.InvalidArchivePath;
        if (entry.mode > 0o7777 or entry.data.len > limits.max_entry_bytes) return error.ArchiveLimitExceeded;
        if (entry.kind == .directory and entry.data.len != 0) return error.InvalidArchive;
        if (entry.kind == .symlink and (entry.data.len == 0 or std.mem.indexOfScalar(u8, entry.data, 0) != null)) return error.InvalidSymlink;
        if (index > 0 and std.mem.order(u8, entries[index - 1].path, entry.path) != .lt) return error.NonCanonicalArchive;
        total_data = std.math.add(u64, total_data, entry.data.len) catch return error.ArchiveLimitExceeded;
        if (total_data > limits.max_total_bytes) return error.ArchiveLimitExceeded;
        total_paths = std.math.add(u64, total_paths, entry.path.len) catch return error.ArchiveLimitExceeded;
        if (total_paths > limits.max_total_path_bytes) return error.ArchiveLimitExceeded;
        try output.append(allocator, @intFromEnum(entry.kind));
        try appendInt(&output, allocator, u32, @intCast(entry.path.len));
        try appendInt(&output, allocator, u32, entry.mode);
        try appendInt(&output, allocator, u64, entry.data.len);
        try output.appendSlice(allocator, entry.path);
        try output.appendSlice(allocator, entry.data);
    }
    try validateEntryHierarchy(entries);
    return output.toOwnedSlice(allocator);
}

pub fn decodeArchive(allocator: std.mem.Allocator, bytes: []const u8, definition: Definition) !Archive {
    try validateDefinition(definition);
    var cursor: usize = 0;
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], definition.archive_magic)) return error.InvalidArchive;
    cursor = 8;
    const root_mode = try readInt(bytes, &cursor, u32);
    if (root_mode > 0o7777) return error.InvalidMode;
    const count = try readInt(bytes, &cursor, u64);
    if (count == 0 or count > definition.limits.max_entries) return error.ArchiveLimitExceeded;
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var total_data: u64 = 0;
    var total_paths: u64 = 0;
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
        if (path_len == 0 or path_len > definition.limits.max_path_bytes or mode > 0o7777 or data_len > definition.limits.max_entry_bytes) return error.ArchiveLimitExceeded;
        total_data = std.math.add(u64, total_data, data_len) catch return error.ArchiveLimitExceeded;
        if (total_data > definition.limits.max_total_bytes) return error.ArchiveLimitExceeded;
        total_paths = std.math.add(u64, total_paths, path_len) catch return error.ArchiveLimitExceeded;
        if (total_paths > definition.limits.max_total_path_bytes) return error.ArchiveLimitExceeded;
        const path = try takeDupe(allocator, bytes, &cursor, path_len);
        errdefer allocator.free(path);
        const data = try takeDupe(allocator, bytes, &cursor, data_len);
        errdefer allocator.free(data);
        if (!validRelativePath(path, definition.path_policy)) return error.InvalidArchivePath;
        if (try pathExcluded(definition, path)) return error.ExcludedArchivePath;
        if (kind == .directory and data.len != 0) return error.InvalidArchive;
        if (kind == .symlink and (data.len == 0 or std.mem.indexOfScalar(u8, data, 0) != null)) return error.InvalidSymlink;
        if (entries.items.len > 0 and std.mem.order(u8, entries.items[entries.items.len - 1].path, path) != .lt) return error.NonCanonicalArchive;
        try entries.append(allocator, .{ .kind = kind, .path = path, .mode = mode, .data = data });
    }
    if (cursor != bytes.len) return error.TrailingArchiveData;
    for (definition.metadata_roots) |metadata_root| {
        const metadata = findEntry(entries.items, metadata_root) orelse return error.MissingMetadataRoot;
        if (metadata.kind == .symlink) return error.MetadataRootUnsupportedKind;
    }
    try validateEntryHierarchy(entries.items);
    return .{ .root_mode = root_mode, .entries = try entries.toOwnedSlice(allocator) };
}

pub fn restoreArchive(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, bytes: []const u8, definition: Definition) !void {
    var archive = try decodeArchive(allocator, bytes, definition);
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

fn validateTrackedPath(definition: Definition, path: []const u8) !void {
    if (!validRelativePath(path, definition.path_policy)) return error.InvalidTrackedPath;
    if (try pathExcluded(definition, path)) return error.ExcludedTrackedPath;
    for (definition.metadata_roots) |root| if (pathMatches(.{ .path = root }, path)) return error.MetadataPathCannotBeTracked;
}

fn validRelativePath(path: []const u8, policy: PathPolicy) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null or (!policy.allow_backslash and std.mem.indexOfScalar(u8, path, '\\') != null)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn pathMatches(exclusion: PathExclusion, path: []const u8) bool {
    return std.mem.eql(u8, exclusion.path, path) or (exclusion.recursive and isChildPath(exclusion.path, path));
}

fn matchesAny(exclusions: []const PathExclusion, path: []const u8) bool {
    for (exclusions) |exclusion| if (pathMatches(exclusion, path)) return true;
    return false;
}

fn pathExcluded(definition: Definition, path: []const u8) !bool {
    if (matchesAny(definition.path_exclusions, path)) return true;
    if (definition.path_filter) |filter| return filter.excludes(path);
    return false;
}

fn isProjectionExcluded(definition: Definition, path: []const u8) bool {
    for (definition.metadata_roots) |root| if (pathMatches(.{ .path = root }, path)) return true;
    return matchesAny(definition.projection_exclusions, path);
}

fn isChildPath(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn findEntry(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

fn validateEntryHierarchy(entries: []const Entry) !void {
    for (entries, 0..) |entry, index| {
        var parent = std.fs.path.dirname(entry.path);
        while (parent) |path| {
            if (findEntry(entries, path)) |parent_entry| if (parent_entry.kind != .directory) return error.ArchivePathTraversesNonDirectory;
            parent = std.fs.path.dirname(path);
        }
        if (entry.kind == .symlink) {
            for (entries[index + 1 ..]) |other| if (isChildPath(entry.path, other.path)) return error.ArchivePathTraversesSymlink;
        }
    }
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

test "filesystem adapter captures restores projects and preserves exact bytes" {
    const Filter = struct {
        fn exclude(context: *anyopaque, path: []const u8) !bool {
            _ = context;
            return std.mem.startsWith(u8, path, ".toy/cache-");
        }
    };
    const Provider = struct {
        paths: []const []const u8,

        fn list(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, sink: TrackedPathSink) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = allocator;
            _ = io;
            if (repository_path.len == 0) return error.InvalidRepositoryPath;
            for (self.paths) |path| try sink.add(path);
        }
    };
    const Collector = struct {
        object: ?contract.NativeObject = null,
        resources: usize = 0,
        saw_source: bool = false,
        saw_executable: bool = false,
        leaked_metadata: bool = false,

        fn emit(context: *anyopaque, object: contract.NativeObject) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.object = object;
        }

        fn get(context: *anyopaque, id: contract.NativeId) !?contract.NativeObject {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.object) |object| if (object.id.eql(id)) return object;
            return null;
        }

        fn resource(context: *anyopaque, value: contract.ProjectionResource) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.resources += 1;
            if (std.mem.eql(u8, value.id, "src/run")) {
                self.saw_source = true;
                self.saw_executable = value.executable;
            }
            if (std.mem.startsWith(u8, value.id, ".toy")) self.leaked_metadata = true;
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
    try source.dir.createDirPath(io, ".toy/objects");
    try source.dir.createDirPath(io, ".toy/cache-123/nested");
    try source.dir.createDirPath(io, "src");
    try source.dir.writeFile(io, .{ .sub_path = ".toy/objects/state", .data = "\x00\xffnative" });
    try source.dir.writeFile(io, .{ .sub_path = ".toy/cache-123/nested/data", .data = "transient-must-not-leak" });
    try source.dir.writeFile(io, .{ .sub_path = "src/run", .data = "#!/bin/sh\n" });
    try source.dir.writeFile(io, .{ .sub_path = "secret", .data = "must-not-leak" });
    try source.dir.symLink(io, "src/run", "current", .{});
    var executable = try source.dir.openFile(io, "src/run", .{ .mode = .read_write });
    try executable.setPermissions(io, .fromMode(0o751));
    executable.close(io);
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    const capabilities = [_]contract.Capability{
        .{ .name = "opaque-native-repository", .support = .required },
        .{ .name = "foreign-operation-import", .support = .unsupported },
    };
    const exclusions = [_]contract.ClosureExclusion{
        .{ .namespace = "worktree.untracked", .reason = "outside the native closure", .affects_semantics = false },
    };
    var provider = Provider{ .paths = &.{ "src/run", "current" } };
    var filter_context: u8 = 0;
    const definition = Definition{
        .vcs = "toy",
        .format_version = "filesystem-archive-v1",
        .id_scheme = "apricot-toy-sha256-v1",
        .object_kind = "toy-repository-archive",
        .metadata_roots = &.{".toy"},
        .tracked_provider = .{ .context = &provider, .listFn = Provider.list },
        .path_filter = .{ .context = &filter_context, .excludeFn = Filter.exclude },
        .capabilities = &capabilities,
        .closure_exclusions = &exclusions,
    };
    var implementation = try FilesystemAdapter.init(allocator, io, source_path, destination_path, definition);
    defer implementation.deinit();
    const adapter_value = implementation.adapter();
    const snapshot_value = try adapter_value.snapshot();
    var collector = Collector{};
    try adapter_value.enumerate(snapshot_value.roots, .{ .context = &collector, .emitFn = Collector.emit });
    try std.testing.expect(std.mem.indexOf(u8, collector.object.?.bytes, "must-not-leak") == null);
    try std.testing.expect(std.mem.indexOf(u8, collector.object.?.bytes, "transient-must-not-leak") == null);
    try adapter_value.project(snapshot_value, .{
        .context = &collector,
        .emitResourceFn = Collector.resource,
        .emitRelationFn = Collector.relation,
        .emitEntryPointFn = Collector.entry,
    });
    try std.testing.expect(collector.saw_source);
    try std.testing.expect(collector.saw_executable);
    try std.testing.expect(!collector.leaked_metadata);
    const report = try adapter_value.restore(snapshot_value, .{ .context = &collector, .getFn = Collector.get });
    try std.testing.expectEqual(contract.PreservationTier.byte_lossless, report.verified_tier);
    const restored = try destination.dir.readFileAlloc(io, ".toy/objects/state", allocator, .unlimited);
    defer allocator.free(restored);
    try std.testing.expectEqualSlices(u8, "\x00\xffnative", restored);
    const recaptured = try captureStable(allocator, io, destination_path, definition);
    defer allocator.free(recaptured);
    try std.testing.expectEqualSlices(u8, collector.object.?.bytes, recaptured);
}

test "filesystem adapter providers hooks and foreign policy are injectable" {
    const Hooks = struct {
        restored: bool = false,
        inspected: bool = false,
        captures: usize = 0,

        fn capture(context: *anyopaque, repository_path: []const u8, session: CaptureSession) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (repository_path.len == 0) return error.InvalidRepositoryPath;
            self.captures += 1;
            try session.addMetadataTree(".native");
            try session.addTrackedPath("work");
        }

        fn afterRestore(context: *anyopaque, path: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (path.len == 0) return error.InvalidRestorePath;
            self.restored = true;
        }

        fn inspect(context: *anyopaque, operation: contract.ForeignOperation) !contract.ForeignInspection {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = operation;
            self.inspected = true;
            return .{ .importable = .{ .strategy = "native", .affected_refs = &.{} } };
        }

        fn import(context: *anyopaque, operation: contract.ForeignOperation, source: contract.ObjectSource) !contract.ForeignOutcome {
            _ = context;
            _ = operation;
            _ = source;
            return .{ .imported = .{ .roots = &.{}, .tier = .semantic_lossless } };
        }
    };
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
    try source.dir.createDirPath(io, ".native");
    try source.dir.writeFile(io, .{ .sub_path = ".native/state", .data = "state" });
    try source.dir.writeFile(io, .{ .sub_path = "work", .data = "work" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    var hooks = Hooks{};
    const definition = Definition{
        .vcs = "native",
        .format_version = "1",
        .id_scheme = "native-sha256-v1",
        .object_kind = "native-archive",
        .metadata_roots = &.{".native"},
        .capture_hook = .{ .context = &hooks, .captureFn = Hooks.capture },
        .restore_hook = .{ .context = &hooks, .restoredFn = Hooks.afterRestore },
        .foreign_hooks = .{ .context = &hooks, .inspectFn = Hooks.inspect, .importFn = Hooks.import },
        .capabilities = &.{.{ .name = "foreign-operation-import", .support = .required }},
        .closure_exclusions = &.{},
    };
    var implementation = try FilesystemAdapter.init(allocator, io, source_path, destination_path, definition);
    defer implementation.deinit();
    const adapter_value = implementation.adapter();
    const snapshot_value = try adapter_value.snapshot();
    try std.testing.expectEqual(@as(usize, 2), hooks.captures);
    var collector = Collector{};
    try adapter_value.enumerate(snapshot_value.roots, .{ .context = &collector, .emitFn = Collector.emit });
    _ = try adapter_value.restore(snapshot_value, .{ .context = &collector, .getFn = Collector.get });
    try std.testing.expect(hooks.restored);
    const inspection = try adapter_value.inspectForeign(.{
        .kind = "tree",
        .base_projection = "a",
        .observed_projection = "b",
        .evidence_media_type = "application/octet-stream",
        .evidence = "change",
    });
    try std.testing.expect(inspection == .importable);
    try std.testing.expect(hooks.inspected);
}

test "filesystem archive rejects traversal exclusions and symlink descendants" {
    const allocator = std.testing.allocator;
    const definition = Definition{
        .vcs = "toy",
        .format_version = "1",
        .id_scheme = "toy-sha256-v1",
        .object_kind = "toy-archive",
        .metadata_roots = &.{".toy"},
        .path_exclusions = &.{.{ .path = ".toy/secret" }},
        .capabilities = &.{.{ .name = "opaque-native-repository", .support = .required }},
        .closure_exclusions = &.{},
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "APCTFS01");
    try appendInt(&bytes, allocator, u32, 0o755);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.append(allocator, @intFromEnum(EntryKind.file));
    try appendInt(&bytes, allocator, u32, 4);
    try appendInt(&bytes, allocator, u32, 0o644);
    try appendInt(&bytes, allocator, u64, 1);
    try bytes.appendSlice(allocator, "../x");
    try bytes.append(allocator, 'x');
    try std.testing.expectError(error.InvalidArchivePath, decodeArchive(allocator, bytes.items, definition));

    const symlink_entries = [_]Entry{
        .{ .kind = .directory, .path = @constCast(".toy"), .mode = 0o755, .data = @constCast("") },
        .{ .kind = .symlink, .path = @constCast("link"), .mode = 0o777, .data = @constCast("target") },
        .{ .kind = .file, .path = @constCast("link/child"), .mode = 0o644, .data = @constCast("x") },
    };
    try std.testing.expectError(error.ArchivePathTraversesSymlink, encodeArchive(allocator, 0o755, &symlink_entries, "APCTFS01", .{}, .{}));
}

test "filesystem adapter supports single-file native metadata" {
    const Hooks = struct {
        fn capture(context: *anyopaque, repository_path: []const u8, session: CaptureSession) !void {
            _ = context;
            if (repository_path.len == 0) return error.InvalidRepositoryPath;
            try session.addMetadataPath("repository.fossil");
            try session.addTrackedPath("working.txt");
        }
    };
    const Collector = struct {
        object: ?contract.NativeObject = null,
        leaked_metadata: bool = false,
        saw_worktree: bool = false,

        fn emit(context: *anyopaque, object: contract.NativeObject) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.object = object;
        }

        fn get(context: *anyopaque, id: contract.NativeId) !?contract.NativeObject {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.object) |object| if (object.id.eql(id)) return object;
            return null;
        }

        fn resource(context: *anyopaque, value: contract.ProjectionResource) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, value.id, "repository.fossil")) self.leaked_metadata = true;
            if (std.mem.eql(u8, value.id, "working.txt")) self.saw_worktree = true;
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
    try source.dir.writeFile(io, .{ .sub_path = "repository.fossil", .data = "SQLite format 3\x00\xffnative" });
    try source.dir.writeFile(io, .{ .sub_path = "working.txt", .data = "uncommitted work" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    var hook_context: u8 = 0;
    const definition = Definition{
        .vcs = "fossil-fixture",
        .format_version = "1",
        .id_scheme = "fossil-fixture-sha256-v1",
        .object_kind = "fossil-fixture-archive",
        .metadata_roots = &.{"repository.fossil"},
        .capture_hook = .{ .context = &hook_context, .captureFn = Hooks.capture },
        .capabilities = &.{.{ .name = "opaque-native-repository", .support = .required }},
        .closure_exclusions = &.{},
    };
    var implementation = try FilesystemAdapter.init(allocator, io, source_path, destination_path, definition);
    defer implementation.deinit();
    const adapter_value = implementation.adapter();
    const snapshot_value = try adapter_value.snapshot();
    var collector = Collector{};
    try adapter_value.enumerate(snapshot_value.roots, .{ .context = &collector, .emitFn = Collector.emit });
    var archive = try decodeArchive(allocator, collector.object.?.bytes, definition);
    defer archive.deinit(allocator);
    const metadata = findEntry(archive.entries, "repository.fossil") orelse return error.MissingMetadataRoot;
    try std.testing.expectEqual(EntryKind.file, metadata.kind);
    try adapter_value.project(snapshot_value, .{
        .context = &collector,
        .emitResourceFn = Collector.resource,
        .emitRelationFn = Collector.relation,
        .emitEntryPointFn = Collector.entry,
    });
    try std.testing.expect(!collector.leaked_metadata);
    try std.testing.expect(collector.saw_worktree);
    _ = try adapter_value.restore(snapshot_value, .{ .context = &collector, .getFn = Collector.get });
    const restored_metadata = try destination.dir.readFileAlloc(io, "repository.fossil", allocator, .unlimited);
    defer allocator.free(restored_metadata);
    try std.testing.expectEqualSlices(u8, "SQLite format 3\x00\xffnative", restored_metadata);
    const recaptured = try captureStable(allocator, io, destination_path, definition);
    defer allocator.free(recaptured);
    try std.testing.expectEqualSlices(u8, collector.object.?.bytes, recaptured);
}

test "filesystem adapter validates configuration and closure declarations" {
    const base = Definition{
        .vcs = "toy",
        .format_version = "1",
        .id_scheme = "toy-sha256-v1",
        .object_kind = "toy-archive",
        .metadata_roots = &.{".toy"},
        .capabilities = &.{.{ .name = "opaque-native-repository", .support = .required }},
        .closure_exclusions = &.{},
    };
    try validateDefinition(base);
    var missing_root = base;
    missing_root.metadata_roots = &.{};
    try std.testing.expectError(error.MissingMetadataRoot, validateDefinition(missing_root));
    var invalid_magic = base;
    invalid_magic.archive_magic = "short";
    try std.testing.expectError(error.InvalidArchiveMagic, validateDefinition(invalid_magic));
    var overlapping = base;
    overlapping.metadata_roots = &.{ ".toy", ".toy/nested" };
    try std.testing.expectError(error.OverlappingMetadataRoots, validateDefinition(overlapping));
    var excluded = base;
    excluded.path_exclusions = &.{.{ .path = ".toy" }};
    try std.testing.expectError(error.ExcludedMetadataRoot, validateDefinition(excluded));
    var lossy = base;
    lossy.closure_exclusions = &.{.{ .namespace = "native", .reason = "lost", .affects_semantics = true }};
    try std.testing.expectError(error.LosslessExclusionAffectsSemantics, validateDefinition(lossy));
    var ambiguous = base;
    ambiguous.tracked_paths = &.{"work"};
    var provider_context: u8 = 0;
    const Provider = struct {
        fn list(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, sink: TrackedPathSink) !void {
            _ = context;
            _ = allocator;
            _ = io;
            _ = repository_path;
            _ = sink;
        }
    };
    ambiguous.tracked_provider = .{ .context = &provider_context, .listFn = Provider.list };
    try std.testing.expectError(error.AmbiguousTrackedPathProvider, validateDefinition(ambiguous));
}

test "filesystem restore refuses nonempty targets before writing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".toy");
    try source.dir.writeFile(io, .{ .sub_path = ".toy/state", .data = "native" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const definition = Definition{
        .vcs = "toy",
        .format_version = "1",
        .id_scheme = "toy-sha256-v1",
        .object_kind = "toy-archive",
        .metadata_roots = &.{".toy"},
        .capabilities = &.{.{ .name = "opaque-native-repository", .support = .required }},
        .closure_exclusions = &.{},
    };
    const bytes = try captureStable(allocator, io, source_path, definition);
    defer allocator.free(bytes);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    try destination.dir.writeFile(io, .{ .sub_path = "existing", .data = "keep" });
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    try std.testing.expectError(error.RestoreTargetNotEmpty, restoreArchive(allocator, io, destination_path, bytes, definition));
    const existing = try destination.dir.readFileAlloc(io, "existing", allocator, .unlimited);
    defer allocator.free(existing);
    try std.testing.expectEqualSlices(u8, "keep", existing);
    try std.testing.expectError(error.FileNotFound, destination.dir.statFile(io, ".toy", .{}));
}

test "filesystem capture omits missing tracked files and enforces bounds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".toy");
    try source.dir.writeFile(io, .{ .sub_path = ".toy/state", .data = "native" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const definition = Definition{
        .vcs = "toy",
        .format_version = "1",
        .id_scheme = "toy-sha256-v1",
        .object_kind = "toy-archive",
        .metadata_roots = &.{".toy"},
        .tracked_paths = &.{"deleted"},
        .capabilities = &.{.{ .name = "opaque-native-repository", .support = .required }},
        .closure_exclusions = &.{},
    };
    const bytes = try captureStable(allocator, io, source_path, definition);
    defer allocator.free(bytes);
    var archive = try decodeArchive(allocator, bytes, definition);
    defer archive.deinit(allocator);
    try std.testing.expect(findEntry(archive.entries, "deleted") == null);
    var bounded = definition;
    bounded.limits.max_entry_bytes = 3;
    try std.testing.expectError(error.StreamTooLong, captureOnce(allocator, io, source_path, bounded));
    var wrong_magic = definition;
    wrong_magic.archive_magic = "WRONG001";
    try std.testing.expectError(error.InvalidArchive, decodeArchive(allocator, bytes, wrong_magic));
}
