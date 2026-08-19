const std = @import("std");

pub const magic = "APCTSTR\x00";
pub const current_version: u16 = 1;

pub const Limits = struct {
    min_chunk_bytes: u32 = 64 * 1024,
    max_chunk_bytes: u32 = 16 * 1024 * 1024,
    max_chunks: u32 = 1_000_000,
    max_total_bytes: u64 = 1024 * 1024 * 1024 * 1024,
    max_descriptor_bytes: usize = 64 * 1024 * 1024,
};

pub const ContentId = struct {
    bytes: [32]u8,

    pub fn eql(a: ContentId, b: ContentId) bool {
        return std.crypto.timing_safe.eql([32]u8, a.bytes, b.bytes);
    }
};

pub const ChunkRecord = struct {
    offset: u64,
    length: u32,
    id: ContentId,
};

pub const Descriptor = struct {
    version: u16 = current_version,
    chunk_size: u32,
    total_length: u64,
    root: ContentId,
    chunks: []const ChunkRecord,
};

pub const EncodedDescriptor = struct {
    id: ContentId,
    bytes: []u8,

    pub fn deinit(self: EncodedDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const OwnedDescriptor = struct {
    descriptor: Descriptor,
    chunks: []ChunkRecord,

    pub fn deinit(self: *OwnedDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
        self.* = undefined;
    }
};

pub const Chunk = struct {
    index: u32,
    offset: u64,
    bytes: []const u8,
    id: ContentId,
};

pub const ChunkIterator = struct {
    carrier: []const u8,
    chunk_size: u32,
    index: u32 = 0,
    offset: usize = 0,

    pub fn next(self: *ChunkIterator) ?Chunk {
        if (self.offset == self.carrier.len) return null;
        const remaining = self.carrier.len - self.offset;
        const length = @min(remaining, self.chunk_size);
        const start = self.offset;
        const bytes = self.carrier[start .. start + length];
        defer {
            self.index += 1;
            self.offset += length;
        }
        return .{
            .index = self.index,
            .offset = start,
            .bytes = bytes,
            .id = contentId("carrier-store-chunk-v1", bytes),
        };
    }
};

pub const SplitPlan = struct {
    carrier: []const u8,
    descriptor: Descriptor,
    records: []ChunkRecord,

    pub fn deinit(self: *SplitPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        self.* = undefined;
    }

    pub fn iterator(self: SplitPlan) ChunkIterator {
        return .{ .carrier = self.carrier, .chunk_size = self.descriptor.chunk_size };
    }

    pub fn encodeDescriptor(self: SplitPlan, allocator: std.mem.Allocator, limits: Limits) !EncodedDescriptor {
        return encode(allocator, self.descriptor, limits);
    }
};

pub fn split(allocator: std.mem.Allocator, carrier: []const u8, chunk_size: u32, limits: Limits) !SplitPlan {
    try validateSize(chunk_size, carrier.len, limits);
    const count = chunkCount(carrier.len, chunk_size);
    if (count > limits.max_chunks) return error.ResourceLimitExceeded;
    const records = try allocator.alloc(ChunkRecord, count);
    errdefer allocator.free(records);
    var iterator = ChunkIterator{ .carrier = carrier, .chunk_size = chunk_size };
    var index: usize = 0;
    while (iterator.next()) |chunk| : (index += 1) {
        records[index] = .{ .offset = chunk.offset, .length = @intCast(chunk.bytes.len), .id = chunk.id };
    }
    return .{
        .carrier = carrier,
        .records = records,
        .descriptor = .{
            .chunk_size = chunk_size,
            .total_length = carrier.len,
            .root = rootId(carrier),
            .chunks = records,
        },
    };
}

pub fn encode(allocator: std.mem.Allocator, descriptor: Descriptor, limits: Limits) !EncodedDescriptor {
    try validate(descriptor, limits);
    const record_bytes = std.math.mul(usize, descriptor.chunks.len, 44) catch return error.ResourceLimitExceeded;
    const total = std.math.add(usize, 58, record_bytes) catch return error.ResourceLimitExceeded;
    if (total > limits.max_descriptor_bytes) return error.ResourceLimitExceeded;
    const bytes = try allocator.alloc(u8, total);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    writeRaw(bytes, &offset, magic);
    writeInt(u16, bytes, &offset, descriptor.version);
    writeInt(u32, bytes, &offset, descriptor.chunk_size);
    writeInt(u64, bytes, &offset, descriptor.total_length);
    writeRaw(bytes, &offset, &descriptor.root.bytes);
    writeInt(u32, bytes, &offset, @intCast(descriptor.chunks.len));
    for (descriptor.chunks) |chunk| {
        writeInt(u64, bytes, &offset, chunk.offset);
        writeInt(u32, bytes, &offset, chunk.length);
        writeRaw(bytes, &offset, &chunk.id.bytes);
    }
    return .{ .id = contentId("carrier-store-descriptor-v1", bytes), .bytes = bytes };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !OwnedDescriptor {
    if (bytes.len > limits.max_descriptor_bytes or bytes.len < 58) return error.MalformedDescriptor;
    var cursor: usize = 0;
    if (!std.mem.eql(u8, try readRaw(bytes, &cursor, magic.len), magic)) return error.InvalidMagic;
    const version = try readInt(u16, bytes, &cursor);
    if (version != current_version) return error.UnsupportedVersion;
    const chunk_size = try readInt(u32, bytes, &cursor);
    const total_length = try readInt(u64, bytes, &cursor);
    var root: ContentId = undefined;
    @memcpy(&root.bytes, try readRaw(bytes, &cursor, 32));
    const count = try readInt(u32, bytes, &cursor);
    if (count > limits.max_chunks) return error.ResourceLimitExceeded;
    const expected_records = std.math.mul(usize, count, 44) catch return error.ResourceLimitExceeded;
    const expected_length = std.math.add(usize, 58, expected_records) catch return error.ResourceLimitExceeded;
    if (bytes.len != expected_length) return error.MalformedDescriptor;
    const records = try allocator.alloc(ChunkRecord, count);
    errdefer allocator.free(records);
    for (records) |*record| {
        record.offset = try readInt(u64, bytes, &cursor);
        record.length = try readInt(u32, bytes, &cursor);
        @memcpy(&record.id.bytes, try readRaw(bytes, &cursor, 32));
    }
    const owned = OwnedDescriptor{
        .chunks = records,
        .descriptor = .{
            .version = version,
            .chunk_size = chunk_size,
            .total_length = total_length,
            .root = root,
            .chunks = records,
        },
    };
    try validate(owned.descriptor, limits);
    return owned;
}

pub fn validate(descriptor: Descriptor, limits: Limits) !void {
    if (descriptor.version != current_version) return error.UnsupportedVersion;
    if (descriptor.chunk_size < limits.min_chunk_bytes or descriptor.chunk_size > limits.max_chunk_bytes) return error.InvalidChunkSize;
    if (descriptor.total_length > limits.max_total_bytes or descriptor.chunks.len > limits.max_chunks) return error.ResourceLimitExceeded;
    const expected_count = chunkCountU64(descriptor.total_length, descriptor.chunk_size);
    if (descriptor.chunks.len != expected_count) return error.InvalidChunkLayout;
    var expected_offset: u64 = 0;
    for (descriptor.chunks, 0..) |chunk, index| {
        if (chunk.offset != expected_offset) return error.InvalidChunkLayout;
        const remaining = descriptor.total_length - expected_offset;
        const expected_length: u32 = @intCast(@min(remaining, descriptor.chunk_size));
        if (chunk.length != expected_length or chunk.length == 0) return error.InvalidChunkLayout;
        if (index + 1 < descriptor.chunks.len and chunk.length != descriptor.chunk_size) return error.InvalidChunkLayout;
        expected_offset = std.math.add(u64, expected_offset, chunk.length) catch return error.InvalidChunkLayout;
    }
    if (expected_offset != descriptor.total_length) return error.InvalidChunkLayout;
}

pub const Sink = struct {
    context: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn write(self: Sink, bytes: []const u8) !void {
        try self.writeFn(self.context, bytes);
    }
};

pub const Assembler = struct {
    descriptor: Descriptor,
    next_index: usize = 0,
    received: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256,

    pub fn init(descriptor: Descriptor, limits: Limits) !Assembler {
        try validate(descriptor, limits);
        return .{ .descriptor = descriptor, .hasher = rootHasher(descriptor.total_length) };
    }

    pub fn push(self: *Assembler, index: u32, bytes: []const u8, sink: Sink) !void {
        if (index != self.next_index) return error.UnexpectedChunk;
        if (self.next_index >= self.descriptor.chunks.len) return error.UnexpectedChunk;
        const expected = self.descriptor.chunks[self.next_index];
        if (bytes.len != expected.length) return error.InvalidChunkLength;
        if (!contentId("carrier-store-chunk-v1", bytes).eql(expected.id)) return error.ChunkIntegrityFailure;
        try sink.write(bytes);
        self.hasher.update(bytes);
        self.received = std.math.add(u64, self.received, bytes.len) catch return error.ResourceLimitExceeded;
        self.next_index += 1;
    }

    pub fn finish(self: *Assembler) !ContentId {
        if (self.next_index != self.descriptor.chunks.len or self.received != self.descriptor.total_length) return error.IncompleteCarrier;
        var bytes: [32]u8 = undefined;
        self.hasher.final(&bytes);
        const actual = ContentId{ .bytes = bytes };
        if (!actual.eql(self.descriptor.root)) return error.CarrierIntegrityFailure;
        return actual;
    }
};

pub fn verifyDescriptor(encoded: []const u8, expected: ContentId) !void {
    if (!contentId("carrier-store-descriptor-v1", encoded).eql(expected)) return error.DescriptorIntegrityFailure;
}

pub fn rootId(bytes: []const u8) ContentId {
    var hasher = rootHasher(bytes.len);
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .bytes = digest };
}

fn contentId(domain: []const u8, bytes: []const u8) ContentId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("apricot\x00");
    hasher.update(domain);
    hasher.update("\x00");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hasher.update(&length);
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .bytes = digest };
}

fn rootHasher(total_length: u64) std.crypto.hash.sha2.Sha256 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("apricot\x00carrier-store-root-v1\x00");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, total_length, .big);
    hasher.update(&length);
    return hasher;
}

fn validateSize(chunk_size: u32, total_length: usize, limits: Limits) !void {
    if (chunk_size < limits.min_chunk_bytes or chunk_size > limits.max_chunk_bytes) return error.InvalidChunkSize;
    if (total_length > limits.max_total_bytes) return error.ResourceLimitExceeded;
}

fn chunkCount(total_length: usize, chunk_size: u32) usize {
    if (total_length == 0) return 0;
    return (total_length - 1) / chunk_size + 1;
}

fn chunkCountU64(total_length: u64, chunk_size: u32) u64 {
    if (total_length == 0) return 0;
    return (total_length - 1) / chunk_size + 1;
}

fn writeRaw(destination: []u8, offset: *usize, bytes: []const u8) void {
    @memcpy(destination[offset.* .. offset.* + bytes.len], bytes);
    offset.* += bytes.len;
}

fn writeInt(comptime T: type, destination: []u8, offset: *usize, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    writeRaw(destination, offset, &bytes);
}

fn readRaw(source: []const u8, offset: *usize, length: usize) ![]const u8 {
    const end = std.math.add(usize, offset.*, length) catch return error.MalformedDescriptor;
    if (end > source.len) return error.MalformedDescriptor;
    defer offset.* = end;
    return source[offset.*..end];
}

fn readInt(comptime T: type, source: []const u8, offset: *usize) !T {
    const bytes = try readRaw(source, offset, @sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

const ArraySink = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn sink(self: *ArraySink) Sink {
        return .{ .context = self, .writeFn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *ArraySink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};

test "arbitrary binary carrier round trips through descriptor and streaming assembly" {
    const allocator = std.testing.allocator;
    var carrier = try allocator.alloc(u8, 200_003);
    defer allocator.free(carrier);
    for (carrier, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);
    carrier[0] = 0;
    carrier[1] = 0xff;

    var plan = try split(allocator, carrier, 64 * 1024, .{});
    defer plan.deinit(allocator);
    var encoded = try plan.encodeDescriptor(allocator, .{});
    defer encoded.deinit(allocator);
    try verifyDescriptor(encoded.bytes, encoded.id);
    var decoded = try decode(allocator, encoded.bytes, .{});
    defer decoded.deinit(allocator);

    var output = ArraySink{ .allocator = allocator };
    defer output.bytes.deinit(allocator);
    var assembler = try Assembler.init(decoded.descriptor, .{});
    var iterator = plan.iterator();
    while (iterator.next()) |chunk| try assembler.push(chunk.index, chunk.bytes, output.sink());
    const recovered_root = try assembler.finish();
    try std.testing.expect(recovered_root.eql(plan.descriptor.root));
    try std.testing.expectEqualSlices(u8, carrier, output.bytes.items);
}

test "reorder omission and tampering are rejected" {
    const allocator = std.testing.allocator;
    const carrier = ([_]u8{0x41} ** (128 * 1024 + 7))[0..];
    var plan = try split(allocator, carrier, 64 * 1024, .{});
    defer plan.deinit(allocator);
    var output = ArraySink{ .allocator = allocator };
    defer output.bytes.deinit(allocator);

    var iterator = plan.iterator();
    const first = iterator.next().?;
    const second = iterator.next().?;
    var reordered = try Assembler.init(plan.descriptor, .{});
    try std.testing.expectError(error.UnexpectedChunk, reordered.push(second.index, second.bytes, output.sink()));

    var omitted = try Assembler.init(plan.descriptor, .{});
    try omitted.push(first.index, first.bytes, output.sink());
    try std.testing.expectError(error.IncompleteCarrier, omitted.finish());

    var corrupt = try allocator.dupe(u8, first.bytes);
    defer allocator.free(corrupt);
    corrupt[9] ^= 0x80;
    var tampered = try Assembler.init(plan.descriptor, .{});
    try std.testing.expectError(error.ChunkIntegrityFailure, tampered.push(first.index, corrupt, output.sink()));
}

test "descriptor tampering and abusive bounds are rejected" {
    const allocator = std.testing.allocator;
    const carrier = ([_]u8{0x5a} ** (64 * 1024))[0..];
    var plan = try split(allocator, carrier, 64 * 1024, .{});
    defer plan.deinit(allocator);
    var encoded = try plan.encodeDescriptor(allocator, .{});
    defer encoded.deinit(allocator);
    encoded.bytes[20] ^= 1;
    try std.testing.expectError(error.DescriptorIntegrityFailure, verifyDescriptor(encoded.bytes, encoded.id));
    try std.testing.expectError(error.ResourceLimitExceeded, decode(allocator, encoded.bytes, .{ .max_total_bytes = 1 }));

    var malformed = plan.descriptor;
    var records = try allocator.dupe(ChunkRecord, malformed.chunks);
    defer allocator.free(records);
    records[0].offset = 1;
    malformed.chunks = records;
    try std.testing.expectError(error.InvalidChunkLayout, validate(malformed, .{}));
}

test "logical carrier larger than sixty four mebibytes validates without large allocation" {
    const allocator = std.testing.allocator;
    const chunk_size: u32 = 1024 * 1024;
    const count: usize = 65;
    const total_length: u64 = count * chunk_size;
    const records = try allocator.alloc(ChunkRecord, count);
    defer allocator.free(records);
    var repeated = [_]u8{0x7c} ** 4096;
    const nominal_id = contentId("carrier-store-chunk-v1", &repeated);
    for (records, 0..) |*record, index| {
        record.* = .{ .offset = index * chunk_size, .length = chunk_size, .id = nominal_id };
    }
    const descriptor = Descriptor{
        .chunk_size = chunk_size,
        .total_length = total_length,
        .root = .{ .bytes = [_]u8{0} ** 32 },
        .chunks = records,
    };
    try validate(descriptor, .{});
    var encoded = try encode(allocator, descriptor, .{});
    defer encoded.deinit(allocator);
    var decoded = try decode(allocator, encoded.bytes, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(total_length, decoded.descriptor.total_length);
    try std.testing.expectEqual(count, decoded.descriptor.chunks.len);
}
