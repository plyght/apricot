const std = @import("std");

pub const magic = "APCTCAR\x00";
pub const current_version: u16 = 1;

pub const Limits = struct {
    max_manifest_bytes: usize = 256 * 1024 * 1024,
    max_objects: usize = 1_000_000,
    max_refs: usize = 100_000,
    max_projection_mappings: usize = 1_000_000,
    max_object_bytes: usize = 64 * 1024 * 1024,
    max_total_object_bytes: usize = 4 * 1024 * 1024 * 1024,
    max_identifier_bytes: usize = 4096,
    min_chunk_bytes: usize = 1024,
    max_chunk_bytes: usize = 16 * 1024 * 1024,
};

pub const ContentId = struct {
    bytes: [32]u8,

    pub fn of(domain: []const u8, payload: []const u8) ContentId {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("apricot\x00");
        hash.update(domain);
        hash.update("\x00");
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, payload.len, .big);
        hash.update(&length);
        hash.update(payload);
        var bytes: [32]u8 = undefined;
        hash.final(&bytes);
        return .{ .bytes = bytes };
    }

    pub fn eql(a: ContentId, b: ContentId) bool {
        return std.crypto.timing_safe.eql([32]u8, a.bytes, b.bytes);
    }
};

pub const Chunk = struct {
    offset: usize,
    bytes: []const u8,
    id: ContentId,
};

pub const ChunkIterator = struct {
    bytes: []const u8,
    chunk_size: usize,
    offset: usize = 0,

    pub fn next(self: *ChunkIterator) ?Chunk {
        if (self.offset == self.bytes.len) return null;
        const end = @min(self.bytes.len, self.offset + self.chunk_size);
        const offset = self.offset;
        const bytes = self.bytes[offset..end];
        self.offset = end;
        return .{ .offset = offset, .bytes = bytes, .id = ContentId.of("chunk-v1", bytes) };
    }
};

pub fn chunks(bytes: []const u8, chunk_size: usize, limits: Limits) !ChunkIterator {
    if (chunk_size < limits.min_chunk_bytes or chunk_size > limits.max_chunk_bytes) return error.InvalidChunkSize;
    return .{ .bytes = bytes, .chunk_size = chunk_size };
}

pub const NativeObject = struct {
    native_id: []const u8,
    object_type: []const u8,
    bytes: []const u8,
    content_id: ContentId,

    pub fn create(native_id: []const u8, object_type: []const u8, bytes: []const u8) NativeObject {
        return .{
            .native_id = native_id,
            .object_type = object_type,
            .bytes = bytes,
            .content_id = ContentId.of("native-object-v1", bytes),
        };
    }
};

pub const NativeRef = struct {
    name: []const u8,
    target_native_id: []const u8,
};

pub const ProjectionMapping = struct {
    native_id: []const u8,
    projected_id: []const u8,
};

pub const Manifest = struct {
    version: u16 = current_version,
    vcs: []const u8,
    repository_id: []const u8,
    chunk_size: u32,
    prior_root: ?ContentId = null,
    objects: []const NativeObject,
    refs: []const NativeRef,
    projection_mappings: []const ProjectionMapping,
};

pub const EncodedManifest = struct {
    root: ContentId,
    bytes: []u8,

    pub fn deinit(self: EncodedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const OwnedManifest = struct {
    manifest: Manifest,
    backing: []u8,
    objects: []NativeObject,
    refs: []NativeRef,
    projection_mappings: []ProjectionMapping,

    pub fn deinit(self: *OwnedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.projection_mappings);
        allocator.free(self.refs);
        allocator.free(self.objects);
        allocator.free(self.backing);
        self.* = undefined;
    }
};

const Encoder = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
    }

    fn raw(self: *Encoder, value: []const u8) !void {
        const new_length = std.math.add(usize, self.bytes.items.len, value.len) catch return error.ResourceLimitExceeded;
        if (new_length > self.max_bytes) return error.ResourceLimitExceeded;
        try self.bytes.appendSlice(self.allocator, value);
    }

    fn byte(self: *Encoder, value: u8) !void {
        try self.bytes.append(self.allocator, value);
    }

    fn int(self: *Encoder, comptime T: type, value: T) !void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .big);
        try self.raw(&encoded);
    }

    fn sized(self: *Encoder, value: []const u8) !void {
        const length = std.math.cast(u32, value.len) orelse return error.ResourceLimitExceeded;
        try self.int(u32, length);
        try self.raw(value);
    }
};

const Decoder = struct {
    bytes: []u8,
    offset: usize = 0,

    fn raw(self: *Decoder, length: usize) ![]u8 {
        const end = std.math.add(usize, self.offset, length) catch return error.MalformedManifest;
        if (end > self.bytes.len) return error.MalformedManifest;
        defer self.offset = end;
        return self.bytes[self.offset..end];
    }

    fn byte(self: *Decoder) !u8 {
        return (try self.raw(1))[0];
    }

    fn int(self: *Decoder, comptime T: type) !T {
        const encoded = try self.raw(@sizeOf(T));
        return std.mem.readInt(T, encoded[0..@sizeOf(T)], .big);
    }

    fn sized(self: *Decoder, maximum: usize) ![]u8 {
        const length = try self.int(u32);
        if (length > maximum) return error.ResourceLimitExceeded;
        return self.raw(length);
    }
};

pub fn encode(allocator: std.mem.Allocator, manifest: Manifest, limits: Limits) !EncodedManifest {
    try validate(manifest, limits);
    var encoder = Encoder{ .allocator = allocator, .max_bytes = limits.max_manifest_bytes };
    errdefer encoder.deinit();
    try encoder.raw(magic);
    try encoder.int(u16, manifest.version);
    try encoder.int(u32, manifest.chunk_size);
    try encoder.sized(manifest.vcs);
    try encoder.sized(manifest.repository_id);
    if (manifest.prior_root) |root| {
        try encoder.byte(1);
        try encoder.raw(&root.bytes);
    } else {
        try encoder.byte(0);
    }
    try encoder.int(u32, @intCast(manifest.objects.len));
    for (manifest.objects) |object| {
        try encoder.sized(object.native_id);
        try encoder.sized(object.object_type);
        try encoder.raw(&object.content_id.bytes);
        try encoder.int(u64, @intCast(object.bytes.len));
        const chunk_count = if (object.bytes.len == 0) 0 else (object.bytes.len - 1) / manifest.chunk_size + 1;
        try encoder.int(u32, @intCast(chunk_count));
        var iterator = try chunks(object.bytes, manifest.chunk_size, limits);
        while (iterator.next()) |chunk| {
            try encoder.int(u32, @intCast(chunk.bytes.len));
            try encoder.raw(&chunk.id.bytes);
        }
        try encoder.raw(object.bytes);
    }
    try encoder.int(u32, @intCast(manifest.refs.len));
    for (manifest.refs) |ref| {
        try encoder.sized(ref.name);
        try encoder.sized(ref.target_native_id);
    }
    try encoder.int(u32, @intCast(manifest.projection_mappings.len));
    for (manifest.projection_mappings) |mapping| {
        try encoder.sized(mapping.native_id);
        try encoder.sized(mapping.projected_id);
    }
    if (encoder.bytes.items.len > limits.max_manifest_bytes) return error.ResourceLimitExceeded;
    const owned = try encoder.bytes.toOwnedSlice(allocator);
    return .{ .root = ContentId.of("manifest-v1", owned), .bytes = owned };
}

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8, limits: Limits) !OwnedManifest {
    if (encoded.len > limits.max_manifest_bytes) return error.ResourceLimitExceeded;
    var backing = try allocator.dupe(u8, encoded);
    errdefer allocator.free(backing);
    var decoder = Decoder{ .bytes = backing };
    if (!std.mem.eql(u8, try decoder.raw(magic.len), magic)) return error.InvalidMagic;
    const version = try decoder.int(u16);
    if (version != current_version) return error.UnsupportedVersion;
    const chunk_size = try decoder.int(u32);
    if (chunk_size < limits.min_chunk_bytes or chunk_size > limits.max_chunk_bytes) return error.InvalidChunkSize;
    const vcs = try decoder.sized(limits.max_identifier_bytes);
    const repository_id = try decoder.sized(limits.max_identifier_bytes);
    const prior_root = switch (try decoder.byte()) {
        0 => null,
        1 => ContentId{ .bytes = (try decoder.raw(32))[0..32].* },
        else => return error.MalformedManifest,
    };
    const object_count = try decoder.int(u32);
    if (object_count > limits.max_objects) return error.ResourceLimitExceeded;
    const objects = try allocator.alloc(NativeObject, object_count);
    errdefer allocator.free(objects);
    var object_index: usize = 0;
    var total_object_bytes: usize = 0;
    while (object_index < object_count) : (object_index += 1) {
        const native_id = try decoder.sized(limits.max_identifier_bytes);
        const object_type = try decoder.sized(limits.max_identifier_bytes);
        const content_id = ContentId{ .bytes = (try decoder.raw(32))[0..32].* };
        const object_length = try decoder.int(u64);
        if (object_length > limits.max_object_bytes) return error.ResourceLimitExceeded;
        const object_len: usize = @intCast(object_length);
        total_object_bytes = std.math.add(usize, total_object_bytes, object_len) catch return error.ResourceLimitExceeded;
        if (total_object_bytes > limits.max_total_object_bytes) return error.ResourceLimitExceeded;
        const expected_chunks = if (object_len == 0) 0 else (object_len - 1) / chunk_size + 1;
        const chunk_count = try decoder.int(u32);
        if (chunk_count != expected_chunks) return error.MalformedManifest;
        const descriptors_offset = decoder.offset;
        const descriptor_bytes = std.math.mul(usize, chunk_count, 36) catch return error.ResourceLimitExceeded;
        _ = try decoder.raw(descriptor_bytes);
        const object_bytes = try decoder.raw(object_len);
        var descriptor_decoder = Decoder{ .bytes = backing[descriptors_offset .. descriptors_offset + descriptor_bytes] };
        var iterator = try chunks(object_bytes, chunk_size, limits);
        while (iterator.next()) |chunk| {
            const declared_length = try descriptor_decoder.int(u32);
            const declared_id = ContentId{ .bytes = (try descriptor_decoder.raw(32))[0..32].* };
            if (declared_length != chunk.bytes.len or !declared_id.eql(chunk.id)) return error.IntegrityFailure;
        }
        if (!content_id.eql(ContentId.of("native-object-v1", object_bytes))) return error.IntegrityFailure;
        objects[object_index] = .{
            .native_id = native_id,
            .object_type = object_type,
            .bytes = object_bytes,
            .content_id = content_id,
        };
    }
    const ref_count = try decoder.int(u32);
    if (ref_count > limits.max_refs) return error.ResourceLimitExceeded;
    const refs = try allocator.alloc(NativeRef, ref_count);
    errdefer allocator.free(refs);
    for (refs) |*ref| {
        ref.* = .{
            .name = try decoder.sized(limits.max_identifier_bytes),
            .target_native_id = try decoder.sized(limits.max_identifier_bytes),
        };
    }
    const mapping_count = try decoder.int(u32);
    if (mapping_count > limits.max_projection_mappings) return error.ResourceLimitExceeded;
    const projection_mappings = try allocator.alloc(ProjectionMapping, mapping_count);
    errdefer allocator.free(projection_mappings);
    for (projection_mappings) |*mapping| {
        mapping.* = .{
            .native_id = try decoder.sized(limits.max_identifier_bytes),
            .projected_id = try decoder.sized(limits.max_identifier_bytes),
        };
    }
    if (decoder.offset != backing.len) return error.TrailingData;
    const manifest = Manifest{
        .version = version,
        .vcs = vcs,
        .repository_id = repository_id,
        .chunk_size = chunk_size,
        .prior_root = prior_root,
        .objects = objects,
        .refs = refs,
        .projection_mappings = projection_mappings,
    };
    try validate(manifest, limits);
    return .{
        .manifest = manifest,
        .backing = backing,
        .objects = objects,
        .refs = refs,
        .projection_mappings = projection_mappings,
    };
}

pub fn verifyEncoded(expected_root: ContentId, encoded: []const u8, limits: Limits) !void {
    if (!expected_root.eql(computeRoot(encoded))) return error.RootMismatch;
    var decoded = try decode(std.heap.page_allocator, encoded, limits);
    decoded.deinit(std.heap.page_allocator);
}

pub fn computeRoot(encoded: []const u8) ContentId {
    return ContentId.of("manifest-v1", encoded);
}

pub fn validate(manifest: Manifest, limits: Limits) !void {
    if (manifest.version != current_version) return error.UnsupportedVersion;
    if (manifest.vcs.len == 0 or manifest.vcs.len > limits.max_identifier_bytes) return error.InvalidIdentifier;
    if (manifest.repository_id.len == 0 or manifest.repository_id.len > limits.max_identifier_bytes) return error.InvalidIdentifier;
    if (manifest.chunk_size < limits.min_chunk_bytes or manifest.chunk_size > limits.max_chunk_bytes) return error.InvalidChunkSize;
    if (manifest.objects.len > limits.max_objects or manifest.refs.len > limits.max_refs or manifest.projection_mappings.len > limits.max_projection_mappings) return error.ResourceLimitExceeded;
    var total_object_bytes: usize = 0;
    var prior_object_id: ?[]const u8 = null;
    for (manifest.objects) |object| {
        try validField(object.native_id, limits);
        try validField(object.object_type, limits);
        if (prior_object_id) |prior| if (std.mem.order(u8, prior, object.native_id) != .lt) return error.NonCanonicalOrder;
        prior_object_id = object.native_id;
        if (object.bytes.len > limits.max_object_bytes) return error.ResourceLimitExceeded;
        total_object_bytes = std.math.add(usize, total_object_bytes, object.bytes.len) catch return error.ResourceLimitExceeded;
        if (total_object_bytes > limits.max_total_object_bytes) return error.ResourceLimitExceeded;
        if (!object.content_id.eql(ContentId.of("native-object-v1", object.bytes))) return error.IntegrityFailure;
    }
    var prior_ref_name: ?[]const u8 = null;
    for (manifest.refs) |ref| {
        try validField(ref.name, limits);
        try validField(ref.target_native_id, limits);
        if (prior_ref_name) |prior| if (std.mem.order(u8, prior, ref.name) != .lt) return error.NonCanonicalOrder;
        prior_ref_name = ref.name;
        if (!hasObject(manifest.objects, ref.target_native_id)) return error.DanglingNativeId;
    }
    var prior_mapping_id: ?[]const u8 = null;
    for (manifest.projection_mappings) |mapping| {
        try validField(mapping.native_id, limits);
        try validField(mapping.projected_id, limits);
        if (prior_mapping_id) |prior| if (std.mem.order(u8, prior, mapping.native_id) != .lt) return error.NonCanonicalOrder;
        prior_mapping_id = mapping.native_id;
        if (!hasObject(manifest.objects, mapping.native_id)) return error.DanglingNativeId;
    }
}

fn validField(identifier: []const u8, limits: Limits) !void {
    if (identifier.len == 0 or identifier.len > limits.max_identifier_bytes) return error.InvalidIdentifier;
}

fn hasObject(objects: []const NativeObject, native_id: []const u8) bool {
    var low: usize = 0;
    var high = objects.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, objects[middle].native_id, native_id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn fixture() Manifest {
    const objects = &[_]NativeObject{
        NativeObject.create("native-1", "moment", "first object bytes"),
        NativeObject.create("native-2", "verdict", "second object bytes"),
    };
    const refs = &[_]NativeRef{
        .{ .name = "refs/heads/main", .target_native_id = "native-2" },
    };
    const mappings = &[_]ProjectionMapping{
        .{ .native_id = "native-1", .projected_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .native_id = "native-2", .projected_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    };
    return .{
        .vcs = "superdetermine",
        .repository_id = "repo-7a5c",
        .chunk_size = 1024,
        .objects = objects,
        .refs = refs,
        .projection_mappings = mappings,
    };
}

test "manifest round trips canonically and verifies root" {
    const allocator = std.testing.allocator;
    const first = try encode(allocator, fixture(), .{});
    defer first.deinit(allocator);
    try verifyEncoded(first.root, first.bytes, .{});
    var decoded = try decode(allocator, first.bytes, .{});
    defer decoded.deinit(allocator);
    const second = try encode(allocator, decoded.manifest, .{});
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expect(first.root.eql(second.root));
    try std.testing.expectEqualStrings("second object bytes", decoded.manifest.objects[1].bytes);
}

test "chunk iterator is bounded and content addressed" {
    var data: [2500]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index / 7 + index / 1024);
    var iterator = try chunks(&data, 1024, .{});
    const one = iterator.next().?;
    const two = iterator.next().?;
    const three = iterator.next().?;
    try std.testing.expectEqual(@as(usize, 1024), one.bytes.len);
    try std.testing.expectEqual(@as(usize, 1024), two.bytes.len);
    try std.testing.expectEqual(@as(usize, 452), three.bytes.len);
    try std.testing.expect(!one.id.eql(two.id));
    try std.testing.expect(iterator.next() == null);
}

test "tampering is rejected by root and chunk verification" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, fixture(), .{});
    defer encoded.deinit(allocator);
    var tampered = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(tampered);
    const object_offset = std.mem.indexOf(u8, tampered, "second object bytes").?;
    tampered[object_offset] ^= 1;
    try std.testing.expectError(error.RootMismatch, verifyEncoded(encoded.root, tampered, .{}));
    try std.testing.expectError(error.IntegrityFailure, decode(allocator, tampered, .{}));
}

test "malformed and unsupported manifests are rejected" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, fixture(), .{});
    defer encoded.deinit(allocator);
    try std.testing.expectError(error.MalformedManifest, decode(allocator, encoded.bytes[0 .. encoded.bytes.len - 1], .{}));
    var wrong_magic = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(wrong_magic);
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(allocator, wrong_magic, .{}));
    var wrong_version = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(wrong_version);
    wrong_version[magic.len + 1] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decode(allocator, wrong_version, .{}));
}

test "resource limits and noncanonical order are rejected" {
    const allocator = std.testing.allocator;
    var too_small = Limits{};
    too_small.max_objects = 1;
    try std.testing.expectError(error.ResourceLimitExceeded, encode(allocator, fixture(), too_small));
    var byte_limited = Limits{};
    byte_limited.max_manifest_bytes = 64;
    try std.testing.expectError(error.ResourceLimitExceeded, encode(allocator, fixture(), byte_limited));
    const reverse_objects = &[_]NativeObject{
        NativeObject.create("z", "object", "z"),
        NativeObject.create("a", "object", "a"),
    };
    var noncanonical = fixture();
    noncanonical.objects = reverse_objects;
    try std.testing.expectError(error.NonCanonicalOrder, encode(allocator, noncanonical, .{}));
}

test "prior root is preserved" {
    const allocator = std.testing.allocator;
    const parent = ContentId.of("manifest-v1", "parent");
    var manifest = fixture();
    manifest.prior_root = parent;
    const encoded = try encode(allocator, manifest, .{});
    defer encoded.deinit(allocator);
    var decoded = try decode(allocator, encoded.bytes, .{});
    defer decoded.deinit(allocator);
    try std.testing.expect(decoded.manifest.prior_root.?.eql(parent));
}

test "native identifiers preserve opaque bytes and references are checked" {
    const allocator = std.testing.allocator;
    const opaque_objects = &[_]NativeObject{
        NativeObject.create("\xff\x00native", "opaque", "bytes"),
    };
    const opaque_refs = &[_]NativeRef{
        .{ .name = "\xfe\x00ref", .target_native_id = "\xff\x00native" },
    };
    var manifest = fixture();
    manifest.objects = opaque_objects;
    manifest.refs = opaque_refs;
    manifest.projection_mappings = &.{};
    const encoded = try encode(allocator, manifest, .{});
    defer encoded.deinit(allocator);
    var decoded = try decode(allocator, encoded.bytes, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "\xff\x00native", decoded.manifest.objects[0].native_id);
    var dangling = manifest;
    dangling.refs = &.{.{ .name = "main", .target_native_id = "missing" }};
    try std.testing.expectError(error.DanglingNativeId, encode(allocator, dangling, .{}));
}
