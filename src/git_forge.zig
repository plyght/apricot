const std = @import("std");
const carrier = @import("carrier.zig");
const carrier_store = @import("carrier_store.zig");
const git = @import("git_transport.zig");

const carrier_chunk_size: u32 = 4 * 1024 * 1024;

pub const ProjectionKind = enum {
    file,
    symlink,
};

pub const ProjectionEntry = struct {
    path: []const u8,
    kind: ProjectionKind,
    executable: bool = false,
    data: []const u8,
};

pub const Published = struct {
    commit: git.Oid,
    carrier_commit: git.Oid,
    carrier_root: carrier.ContentId,
};

pub const Fetched = struct {
    commit: git.Oid,
    carrier_root: carrier.ContentId,
    carrier_bytes: []u8,

    pub fn deinit(self: Fetched, allocator: std.mem.Allocator) void {
        allocator.free(self.carrier_bytes);
    }
};

const Graph = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(git.Object) = .empty,
    allocations: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Graph) void {
        for (self.allocations.items) |allocation| self.allocator.free(allocation);
        self.allocations.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    fn own(self: *Graph, bytes: []u8) ![]const u8 {
        try self.allocations.append(self.allocator, bytes);
        return bytes;
    }

    fn append(self: *Graph, object: git.Object) !git.Oid {
        const oid = object.oid();
        for (self.objects.items) |existing| if (git.Oid.eql(existing.oid(), oid)) return oid;
        try self.objects.append(self.allocator, object);
        return oid;
    }
};

pub fn publish(
    allocator: std.mem.Allocator,
    smart_http: git.SmartHttp,
    branch: []const u8,
    encoded_carrier: []const u8,
    carrier_root: carrier.ContentId,
    projection: []const ProjectionEntry,
    timestamp: i64,
) !Published {
    try carrier.verifyEncoded(carrier_root, encoded_carrier, .{});
    try validateBranch(branch);
    try validateProjection(projection);

    var graph = Graph{ .allocator = allocator };
    defer graph.deinit();
    const tree = try buildTree(&graph, "", projection, &.{});
    const carrier_tree = try buildCarrierTree(&graph, encoded_carrier, carrier_root, smart_http.limits);

    const advertisement = try smart_http.discover(.receive_pack);
    defer advertisement.deinit();
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(ref_name);
    const old = advertisement.findRef(ref_name) orelse git.Oid.zero;
    const native_ref = try branchCarrierRef(allocator, branch);
    defer allocator.free(native_ref);
    const scoped_carrier = advertisement.findRef(native_ref);
    const legacy_carrier = advertisement.findRef("refs/apricot/native");
    const old_carrier = scoped_carrier orelse legacy_carrier orelse git.Oid.zero;
    const commit_data = try commitPayload(allocator, tree, if (git.Oid.eql(old, git.Oid.zero)) null else old, carrier_root, timestamp, "Apricot projection");
    const owned_commit_data = try graph.own(commit_data);
    const commit = try graph.append(.{ .kind = .commit, .data = owned_commit_data });
    const carrier_commit_data = try commitPayload(allocator, carrier_tree, if (git.Oid.eql(old_carrier, git.Oid.zero)) null else old_carrier, carrier_root, timestamp, "Apricot native carrier");
    const owned_carrier_commit_data = try graph.own(carrier_commit_data);
    const carrier_commit = try graph.append(.{ .kind = .commit, .data = owned_carrier_commit_data });

    const request = try git.buildReceivePackRequest(
        allocator,
        advertisement,
        &.{
            .{ .old = old, .new = commit, .name = ref_name },
            .{ .old = scoped_carrier orelse git.Oid.zero, .new = carrier_commit, .name = native_ref },
        },
        graph.objects.items,
        advertisement.hasCapability("atomic"),
        smart_http.limits,
    );
    defer allocator.free(request);
    const response = try smart_http.rpc(.receive_pack, request);
    try git.validateReceivePackReport(allocator, response.body, smart_http.limits);
    return .{ .commit = commit, .carrier_commit = carrier_commit, .carrier_root = carrier_root };
}

pub fn fetch(
    allocator: std.mem.Allocator,
    smart_http: git.SmartHttp,
    branch: []const u8,
) !Fetched {
    try validateBranch(branch);
    const advertisement = try smart_http.discover(.upload_pack);
    defer advertisement.deinit();
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(ref_name);
    const commit = advertisement.findRef(ref_name) orelse return error.MissingBranch;
    const native_ref = try branchCarrierRef(allocator, branch);
    defer allocator.free(native_ref);
    const carrier_commit = advertisement.findRef(native_ref) orelse advertisement.findRef("refs/apricot/native") orelse return error.MissingCarrierRef;
    const request = try git.buildUploadPackRequest(allocator, advertisement, &.{ commit, carrier_commit }, &.{}, smart_http.limits);
    defer allocator.free(request);
    const response = try smart_http.rpc(.upload_pack, request);
    const side_band = advertisement.hasCapability("side-band-64k");
    const pack = try git.extractUploadPack(allocator, response.body, side_band, smart_http.limits);
    defer allocator.free(pack);
    const decoded = try git.decodePack(allocator, pack, smart_http.limits);
    defer decoded.deinit();

    const carrier_commit_object = findObject(decoded.objects, carrier_commit, .commit) orelse return error.MissingCommit;
    const carrier_tree = try commitTree(carrier_commit_object.data);
    const reconstructed = try reconstructCarrier(allocator, decoded.objects, carrier_tree, smart_http.limits);
    errdefer allocator.free(reconstructed.bytes);
    return .{
        .commit = commit,
        .carrier_root = reconstructed.root,
        .carrier_bytes = reconstructed.bytes,
    };
}

pub fn defaultBranch(allocator: std.mem.Allocator, smart_http: git.SmartHttp) ![]u8 {
    const advertisement = try smart_http.discover(.upload_pack);
    defer advertisement.deinit();
    const prefix = "symref=HEAD:refs/heads/";
    for (advertisement.capabilities) |capability| {
        if (std.mem.startsWith(u8, capability, prefix) and capability.len > prefix.len) {
            const branch = capability[prefix.len..];
            try validateBranch(branch);
            return allocator.dupe(u8, branch);
        }
    }
    if (advertisement.findRef("HEAD")) |head| {
        for (advertisement.refs) |ref| {
            const branch_prefix = "refs/heads/";
            if (std.mem.startsWith(u8, ref.name, branch_prefix) and git.Oid.eql(ref.oid, head)) {
                const branch = ref.name[branch_prefix.len..];
                try validateBranch(branch);
                return allocator.dupe(u8, branch);
            }
        }
    }
    if (advertisement.findRef("refs/heads/main") != null) return allocator.dupe(u8, "main");
    if (advertisement.findRef("refs/heads/master") != null) return allocator.dupe(u8, "master");
    var only: ?[]const u8 = null;
    for (advertisement.refs) |ref| {
        const branch_prefix = "refs/heads/";
        if (!std.mem.startsWith(u8, ref.name, branch_prefix)) continue;
        if (only != null) return error.AmbiguousDefaultBranch;
        only = ref.name[branch_prefix.len..];
    }
    return allocator.dupe(u8, only orelse return error.MissingBranch);
}

pub fn branchCarrierRef(allocator: std.mem.Allocator, branch: []const u8) ![]u8 {
    try validateBranch(branch);
    return std.fmt.allocPrint(allocator, "refs/apricot/carriers/{s}", .{branch});
}

fn buildCarrierTree(graph: *Graph, encoded_carrier: []const u8, carrier_root: carrier.ContentId, git_limits: git.Limits) !git.Oid {
    const limits = carrierStoreLimits(git_limits);
    var plan = try carrier_store.split(graph.allocator, encoded_carrier, carrier_chunk_size, limits);
    defer plan.deinit(graph.allocator);
    const descriptor = try plan.encodeDescriptor(graph.allocator, limits);
    const descriptor_bytes = try graph.own(descriptor.bytes);

    var chunks_payload: std.ArrayList(u8) = .empty;
    errdefer chunks_payload.deinit(graph.allocator);
    var iterator = plan.iterator();
    while (iterator.next()) |chunk| {
        const oid = try graph.append(.{ .kind = .blob, .data = chunk.bytes });
        var name_buffer: [8]u8 = undefined;
        const name = try chunkName(chunk.index, &name_buffer);
        try appendTreeEntry(graph.allocator, &chunks_payload, "100644", name, oid);
    }
    const chunks_tree = try graph.append(.{ .kind = .tree, .data = try graph.own(try chunks_payload.toOwnedSlice(graph.allocator)) });

    var root_text_buffer: [65]u8 = undefined;
    const root_text = try graph.own(try graph.allocator.dupe(u8, try carrierRootText(carrier_root, &root_text_buffer)));
    var descriptor_id_buffer: [65]u8 = undefined;
    const descriptor_id_text = try graph.own(try graph.allocator.dupe(u8, try storeRootText(descriptor.id, &descriptor_id_buffer)));
    const descriptor_oid = try graph.append(.{ .kind = .blob, .data = descriptor_bytes });
    const descriptor_id_oid = try graph.append(.{ .kind = .blob, .data = descriptor_id_text });
    const root_oid = try graph.append(.{ .kind = .blob, .data = root_text });
    var root_payload: std.ArrayList(u8) = .empty;
    errdefer root_payload.deinit(graph.allocator);
    try appendTreeEntry(graph.allocator, &root_payload, "40000", "chunks", chunks_tree);
    try appendTreeEntry(graph.allocator, &root_payload, "100644", "descriptor", descriptor_oid);
    try appendTreeEntry(graph.allocator, &root_payload, "100644", "descriptor-id", descriptor_id_oid);
    try appendTreeEntry(graph.allocator, &root_payload, "100644", "root", root_oid);
    return graph.append(.{ .kind = .tree, .data = try graph.own(try root_payload.toOwnedSlice(graph.allocator)) });
}

const Reconstructed = struct {
    root: carrier.ContentId,
    bytes: []u8,
};

fn reconstructCarrier(allocator: std.mem.Allocator, objects: []const git.OwnedObject, tree: git.Oid, git_limits: git.Limits) !Reconstructed {
    const limits = carrierStoreLimits(git_limits);
    const descriptor_blob = try treeChild(objects, tree, "descriptor", .blob);
    const descriptor_id_blob = try treeChild(objects, tree, "descriptor-id", .blob);
    const root_blob = try treeChild(objects, tree, "root", .blob);
    const chunks_tree = try treeChild(objects, tree, "chunks", .tree);
    const descriptor_object = findObject(objects, descriptor_blob, .blob) orelse return error.MissingCarrierDescriptor;
    const descriptor_id_object = findObject(objects, descriptor_id_blob, .blob) orelse return error.MissingCarrierDescriptorId;
    const root_object = findObject(objects, root_blob, .blob) orelse return error.MissingCarrierRoot;
    const descriptor_id = try parseStoreRoot(descriptor_id_object.data);
    try carrier_store.verifyDescriptor(descriptor_object.data, descriptor_id);
    var descriptor = try carrier_store.decode(allocator, descriptor_object.data, limits);
    defer descriptor.deinit(allocator);
    const expected_root = try parseCarrierRoot(root_object.data);

    var blobs = std.AutoHashMap([20]u8, []const u8).init(allocator);
    defer blobs.deinit();
    for (objects) |object| {
        if (object.kind != .blob) continue;
        const oid = (git.Object{ .kind = .blob, .data = object.data }).oid();
        try blobs.put(oid.bytes, object.data);
    }

    const chunks_object = findObject(objects, chunks_tree, .tree) orelse return error.MissingCarrierChunks;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, std.math.cast(usize, descriptor.descriptor.total_length) orelse return error.ResourceLimitExceeded);
    var sink = CarrierSink{ .allocator = allocator, .bytes = &output };
    var assembler = try carrier_store.Assembler.init(descriptor.descriptor, limits);
    var offset: usize = 0;
    for (descriptor.descriptor.chunks, 0..) |_, index| {
        const entry = try nextTreeEntry(chunks_object.data, &offset);
        var expected_name_buffer: [8]u8 = undefined;
        const expected_name = try chunkName(@intCast(index), &expected_name_buffer);
        if (!std.mem.eql(u8, entry.mode, "100644") or !std.mem.eql(u8, entry.name, expected_name)) return error.InvalidCarrierChunkTree;
        const bytes = blobs.get(entry.oid.bytes) orelse return error.MissingCarrierChunk;
        try assembler.push(@intCast(index), bytes, sink.sink());
    }
    if (offset != chunks_object.data.len) return error.InvalidCarrierChunkTree;
    _ = try assembler.finish();
    const result = try output.toOwnedSlice(allocator);
    try carrier.verifyEncoded(expected_root, result, .{});
    return .{ .root = expected_root, .bytes = result };
}

const CarrierSink = struct {
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),

    fn sink(self: *CarrierSink) carrier_store.Sink {
        return .{ .context = self, .writeFn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CarrierSink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};

const TreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: git.Oid,
};

fn nextTreeEntry(data: []const u8, offset: *usize) !TreeEntry {
    if (offset.* >= data.len) return error.InvalidCarrierChunkTree;
    const space = std.mem.indexOfScalarPos(u8, data, offset.*, ' ') orelse return error.InvalidTree;
    const nul = std.mem.indexOfScalarPos(u8, data, space + 1, 0) orelse return error.InvalidTree;
    if (data.len - nul - 1 < 20) return error.InvalidTree;
    defer offset.* = nul + 21;
    return .{
        .mode = data[offset.*..space],
        .name = data[space + 1 .. nul],
        .oid = .{ .bytes = data[nul + 1 ..][0..20].* },
    };
}

fn appendTreeEntry(allocator: std.mem.Allocator, payload: *std.ArrayList(u8), mode: []const u8, name: []const u8, oid: git.Oid) !void {
    try payload.appendSlice(allocator, mode);
    try payload.append(allocator, ' ');
    try payload.appendSlice(allocator, name);
    try payload.append(allocator, 0);
    try payload.appendSlice(allocator, &oid.bytes);
}

fn chunkName(index: u32, buffer: *[8]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>8}", .{index}) catch return error.ResourceLimitExceeded;
}

fn carrierStoreLimits(git_limits: git.Limits) carrier_store.Limits {
    return .{
        .max_chunks = git_limits.max_objects,
        .max_total_bytes = git_limits.max_pack,
        .max_descriptor_bytes = @min(64 * 1024 * 1024, git_limits.max_object),
    };
}

fn buildTree(graph: *Graph, prefix: []const u8, projection: []const ProjectionEntry, metadata: []const ProjectionEntry) !git.Oid {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(graph.allocator);
    try collectChildNames(graph.allocator, &names, prefix, projection);
    try collectChildNames(graph.allocator, &names, prefix, metadata);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(graph.allocator);
    for (names.items) |name| {
        const full_path = if (prefix.len == 0)
            try graph.allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(graph.allocator, "{s}/{s}", .{ prefix, name });
        defer graph.allocator.free(full_path);
        const leaf = findEntry(full_path, projection) orelse findEntry(full_path, metadata);
        const child_oid = if (leaf) |entry|
            try graph.append(.{ .kind = .blob, .data = entry.data })
        else
            try buildTree(graph, full_path, projection, metadata);
        const mode = if (leaf) |entry| switch (entry.kind) {
            .symlink => "120000",
            .file => if (entry.executable) "100755" else "100644",
        } else "40000";
        try payload.appendSlice(graph.allocator, mode);
        try payload.append(graph.allocator, ' ');
        try payload.appendSlice(graph.allocator, name);
        try payload.append(graph.allocator, 0);
        try payload.appendSlice(graph.allocator, &child_oid.bytes);
    }
    const owned = try graph.own(try payload.toOwnedSlice(graph.allocator));
    return graph.append(.{ .kind = .tree, .data = owned });
}

fn collectChildNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), prefix: []const u8, entries: []const ProjectionEntry) !void {
    for (entries) |entry| {
        const remainder = if (prefix.len == 0) entry.path else blk: {
            if (!std.mem.startsWith(u8, entry.path, prefix) or entry.path.len <= prefix.len or entry.path[prefix.len] != '/') continue;
            break :blk entry.path[prefix.len + 1 ..];
        };
        const name = if (std.mem.indexOfScalar(u8, remainder, '/')) |slash| remainder[0..slash] else remainder;
        var present = false;
        for (names.items) |existing| if (std.mem.eql(u8, existing, name)) {
            present = true;
            break;
        };
        if (!present) try names.append(allocator, name);
    }
}

fn findEntry(path: []const u8, entries: []const ProjectionEntry) ?ProjectionEntry {
    for (entries) |entry| if (std.mem.eql(u8, path, entry.path)) return entry;
    return null;
}

fn validateProjection(entries: []const ProjectionEntry) !void {
    for (entries, 0..) |entry, index| {
        if (!validPath(entry.path)) return error.InvalidProjectionPath;
        for (entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, entry.path)) return error.DuplicateProjectionPath;
            if (isParent(earlier.path, entry.path) or isParent(entry.path, earlier.path)) return error.ProjectionPathConflict;
        }
    }
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn isParent(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn validateBranch(branch: []const u8) !void {
    if (branch.len == 0 or branch.len > 255 or std.mem.indexOfAny(u8, branch, "\x00\r\n ~^:?*[\\") != null or std.mem.indexOf(u8, branch, "..") != null) return error.InvalidBranch;
}

fn commitPayload(allocator: std.mem.Allocator, tree: git.Oid, parent: ?git.Oid, root: carrier.ContentId, timestamp: i64, subject: []const u8) ![]u8 {
    var tree_hex: [40]u8 = undefined;
    var parent_hex: [40]u8 = undefined;
    var root_hex: [64]u8 = undefined;
    const root_text = std.fmt.bufPrint(&root_hex, "{x}", .{root.bytes}) catch unreachable;
    if (parent) |parent_oid| {
        return std.fmt.allocPrint(
            allocator,
            "tree {s}\nparent {s}\nauthor Apricot <apricot@localhost> {d} +0000\ncommitter Apricot <apricot@localhost> {d} +0000\n\n{s}\n\nCarrier-Root: {s}\n",
            .{ tree.format(&tree_hex), parent_oid.format(&parent_hex), timestamp, timestamp, subject, root_text },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "tree {s}\nauthor Apricot <apricot@localhost> {d} +0000\ncommitter Apricot <apricot@localhost> {d} +0000\n\n{s}\n\nCarrier-Root: {s}\n",
        .{ tree.format(&tree_hex), timestamp, timestamp, subject, root_text },
    );
}

fn carrierRootText(root: carrier.ContentId, buffer: *[65]u8) ![]const u8 {
    const text = std.fmt.bufPrint(buffer[0..64], "{x}", .{root.bytes}) catch return error.InvalidCarrierRoot;
    buffer[64] = '\n';
    return buffer[0 .. text.len + 1];
}

fn storeRootText(root: carrier_store.ContentId, buffer: *[65]u8) ![]const u8 {
    const text = std.fmt.bufPrint(buffer[0..64], "{x}", .{root.bytes}) catch return error.InvalidCarrierStoreRoot;
    buffer[64] = '\n';
    return buffer[0 .. text.len + 1];
}

fn parseCarrierRoot(data: []const u8) !carrier.ContentId {
    const text = std.mem.trim(u8, data, " \t\r\n");
    if (text.len != 64) return error.InvalidCarrierRoot;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidCarrierRoot;
    return .{ .bytes = bytes };
}

fn parseStoreRoot(data: []const u8) !carrier_store.ContentId {
    const text = std.mem.trim(u8, data, " \t\r\n");
    if (text.len != 64) return error.InvalidCarrierStoreRoot;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidCarrierStoreRoot;
    return .{ .bytes = bytes };
}

fn findObject(objects: []const git.OwnedObject, oid: git.Oid, kind: git.ObjectType) ?git.OwnedObject {
    for (objects) |object| {
        if (object.kind == kind and git.Oid.eql((git.Object{ .kind = object.kind, .data = object.data }).oid(), oid)) return object;
    }
    return null;
}

fn commitTree(data: []const u8) !git.Oid {
    if (!std.mem.startsWith(u8, data, "tree ") or data.len < 45 or data[45] != '\n') return error.InvalidCommit;
    return git.Oid.fromHex(data[5..45]);
}

fn treeChild(objects: []const git.OwnedObject, tree_oid: git.Oid, name: []const u8, kind: git.ObjectType) !git.Oid {
    const tree = findObject(objects, tree_oid, .tree) orelse return error.MissingTree;
    var offset: usize = 0;
    while (offset < tree.data.len) {
        const space = std.mem.indexOfScalarPos(u8, tree.data, offset, ' ') orelse return error.InvalidTree;
        const nul = std.mem.indexOfScalarPos(u8, tree.data, space + 1, 0) orelse return error.InvalidTree;
        if (tree.data.len - nul - 1 < 20) return error.InvalidTree;
        const mode = tree.data[offset..space];
        const child_name = tree.data[space + 1 .. nul];
        const oid = git.Oid{ .bytes = tree.data[nul + 1 ..][0..20].* };
        if (std.mem.eql(u8, child_name, name)) {
            const actual_kind: git.ObjectType = if (std.mem.eql(u8, mode, "40000")) .tree else .blob;
            if (actual_kind != kind) return error.InvalidTree;
            return oid;
        }
        offset = nul + 21;
    }
    return error.MissingTreeEntry;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

test "native carrier references are branch scoped" {
    const main_ref = try branchCarrierRef(std.testing.allocator, "main");
    defer std.testing.allocator.free(main_ref);
    const topic_ref = try branchCarrierRef(std.testing.allocator, "topic/native");
    defer std.testing.allocator.free(topic_ref);
    try std.testing.expectEqualStrings("refs/apricot/carriers/main", main_ref);
    try std.testing.expectEqualStrings("refs/apricot/carriers/topic/native", topic_ref);
    try std.testing.expectError(error.InvalidBranch, branchCarrierRef(std.testing.allocator, "bad..branch"));
}

test "exact multichunk carrier stays outside the projection tree and reconstructs" {
    const allocator = std.testing.allocator;
    const native = try allocator.alloc(u8, carrier_chunk_size * 2 + 137);
    defer allocator.free(native);
    for (native, 0..) |*byte, index| byte.* = @truncate(index *% 193 +% 29);
    const objects = [_]carrier.NativeObject{carrier.NativeObject.create("root", "opaque", native)};
    const refs = [_]carrier.NativeRef{.{ .name = "main", .target_native_id = "root" }};
    const manifest = carrier.Manifest{
        .vcs = "fixture",
        .repository_id = "repo",
        .chunk_size = 1024,
        .objects = &objects,
        .refs = &refs,
        .projection_mappings = &.{},
    };
    const encoded = try carrier.encode(allocator, manifest, .{});
    defer encoded.deinit(allocator);
    var graph = Graph{ .allocator = allocator };
    defer graph.deinit();
    const projection = [_]ProjectionEntry{
        .{ .path = "src/main.zig", .kind = .file, .executable = false, .data = "pub fn main() void {}" },
        .{ .path = "run", .kind = .file, .executable = true, .data = "#!/bin/sh\n" },
    };
    const tree = try buildTree(&graph, "", &projection, &.{});
    const carrier_tree = try buildCarrierTree(&graph, encoded.bytes, encoded.root, .{});
    var owned: std.ArrayList(git.OwnedObject) = .empty;
    defer {
        for (owned.items) |object| object.deinit(allocator);
        owned.deinit(allocator);
    }
    for (graph.objects.items) |object| try owned.append(allocator, .{ .kind = object.kind, .data = try allocator.dupe(u8, object.data) });
    try std.testing.expectError(error.MissingTreeEntry, treeChild(owned.items, tree, ".apricot", .tree));
    try std.testing.expectError(error.MissingTreeEntry, treeChild(owned.items, carrier_tree, "carrier", .blob));
    const chunks_tree = try treeChild(owned.items, carrier_tree, "chunks", .tree);
    const chunks_object = findObject(owned.items, chunks_tree, .tree).?;
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < chunks_object.data.len) : (count += 1) _ = try nextTreeEntry(chunks_object.data, &offset);
    try std.testing.expect(count >= 3);
    const fetched = try reconstructCarrier(allocator, owned.items, carrier_tree, .{});
    defer allocator.free(fetched.bytes);
    try std.testing.expect(fetched.root.eql(encoded.root));
    try std.testing.expectEqualSlices(u8, encoded.bytes, fetched.bytes);
}

test "missing carrier chunk is rejected" {
    const allocator = std.testing.allocator;
    const native = try allocator.alloc(u8, carrier_chunk_size + 1);
    defer allocator.free(native);
    @memset(native, 0xa5);
    const objects = [_]carrier.NativeObject{carrier.NativeObject.create("root", "opaque", native)};
    const refs = [_]carrier.NativeRef{.{ .name = "main", .target_native_id = "root" }};
    const manifest = carrier.Manifest{
        .vcs = "fixture",
        .repository_id = "repo",
        .chunk_size = 1024,
        .objects = &objects,
        .refs = &refs,
        .projection_mappings = &.{},
    };
    const encoded = try carrier.encode(allocator, manifest, .{});
    defer encoded.deinit(allocator);
    var graph = Graph{ .allocator = allocator };
    defer graph.deinit();
    const carrier_tree = try buildCarrierTree(&graph, encoded.bytes, encoded.root, .{});
    var owned: std.ArrayList(git.OwnedObject) = .empty;
    defer {
        for (owned.items) |object| object.deinit(allocator);
        owned.deinit(allocator);
    }
    for (graph.objects.items) |object| try owned.append(allocator, .{ .kind = object.kind, .data = try allocator.dupe(u8, object.data) });
    const chunks_tree = try treeChild(owned.items, carrier_tree, "chunks", .tree);
    const chunks_object = findObject(owned.items, chunks_tree, .tree).?;
    var offset: usize = 0;
    const first = try nextTreeEntry(chunks_object.data, &offset);
    for (owned.items, 0..) |object, index| {
        if (object.kind == .blob and git.Oid.eql((git.Object{ .kind = .blob, .data = object.data }).oid(), first.oid)) {
            var removed = owned.orderedRemove(index);
            removed.deinit(allocator);
            break;
        }
    }
    try std.testing.expectError(error.MissingCarrierChunk, reconstructCarrier(allocator, owned.items, carrier_tree, .{}));
}
