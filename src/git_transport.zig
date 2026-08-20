const std = @import("std");

pub const Limits = struct {
    max_pkt_line: usize = 65520,
    max_advertisement: usize = 8 * 1024 * 1024,
    max_pack: usize = 512 * 1024 * 1024,
    max_objects: u32 = 1_000_000,
    max_object: usize = 256 * 1024 * 1024,
    max_refs: usize = 100_000,
};

pub const Error = error{
    BadChecksum,
    BadContentType,
    BadObject,
    BadObjectId,
    BadPack,
    BadPktLine,
    BadRef,
    AuthenticationRequired,
    CapabilityMissing,
    HttpFailure,
    InvalidArgument,
    LimitExceeded,
    PermissionDenied,
    ProtocolError,
    DeltaInvalid,
    UnresolvedDeltaBase,
    UnsupportedDelta,
    UnsupportedHash,
    UnsupportedProtocol,
};

pub const Oid = struct {
    bytes: [20]u8,

    pub fn fromHex(input: []const u8) Error!Oid {
        if (input.len != 40) return error.BadObjectId;
        var result: Oid = undefined;
        _ = std.fmt.hexToBytes(&result.bytes, input) catch return error.BadObjectId;
        return result;
    }

    pub fn format(self: Oid, output: *[40]u8) []const u8 {
        return std.fmt.bufPrint(output, "{x}", .{self.bytes}) catch unreachable;
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub const zero: Oid = .{ .bytes = @splat(0) };
};

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,

    pub fn name(self: ObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
    }
};

pub const Object = struct {
    kind: ObjectType,
    data: []const u8,

    pub fn oid(self: Object) Oid {
        var hash = std.crypto.hash.Sha1.init(.{});
        var size_buffer: [32]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buffer, "{d}", .{self.data.len}) catch unreachable;
        hash.update(self.kind.name());
        hash.update(" ");
        hash.update(size);
        hash.update(&.{0});
        hash.update(self.data);
        var result: Oid = undefined;
        hash.final(&result.bytes);
        return result;
    }
};

pub const OwnedObject = struct {
    kind: ObjectType,
    data: []u8,

    pub fn oid(self: OwnedObject) Oid {
        return (Object{ .kind = self.kind, .data = self.data }).oid();
    }

    pub fn deinit(self: OwnedObject, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub fn encodeLoose(allocator: std.mem.Allocator, object: Object, limit: usize) ![]u8 {
    if (object.data.len > limit) return error.LimitExceeded;
    var header: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&header, "{s} {d}\x00", .{ object.kind.name(), object.data.len }) catch return error.LimitExceeded;
    const result = try allocator.alloc(u8, prefix.len + object.data.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], object.data);
    return result;
}

pub const PktKind = enum { data, flush, delimiter, response_end };

pub const Pkt = struct {
    kind: PktKind,
    data: []const u8 = &.{},
};

pub fn appendPkt(output: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8, limits: Limits) !void {
    const total = data.len + 4;
    if (total > limits.max_pkt_line or total > 0xffff) return error.LimitExceeded;
    var header: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&header, "{x:0>4}", .{total}) catch unreachable;
    try output.appendSlice(allocator, &header);
    try output.appendSlice(allocator, data);
}

pub fn appendFlush(output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try output.appendSlice(allocator, "0000");
}

pub const PktIterator = struct {
    input: []const u8,
    offset: usize = 0,
    limits: Limits,

    pub fn next(self: *PktIterator) Error!?Pkt {
        if (self.offset == self.input.len) return null;
        if (self.input.len - self.offset < 4) return error.BadPktLine;
        const length = std.fmt.parseInt(u16, self.input[self.offset..][0..4], 16) catch return error.BadPktLine;
        self.offset += 4;
        if (length == 0) return .{ .kind = .flush };
        if (length == 1) return .{ .kind = .delimiter };
        if (length == 2) return .{ .kind = .response_end };
        if (length < 4 or length > self.limits.max_pkt_line) return error.BadPktLine;
        const payload_len: usize = length - 4;
        if (payload_len > self.input.len - self.offset) return error.BadPktLine;
        const payload = self.input[self.offset..][0..payload_len];
        self.offset += payload_len;
        return .{ .kind = .data, .data = payload };
    }
};

pub const Ref = struct {
    name: []const u8,
    oid: Oid,
};

pub const Advertisement = struct {
    refs: []Ref,
    capabilities: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Advertisement) void {
        for (self.refs) |ref| self.allocator.free(ref.name);
        for (self.capabilities) |capability| self.allocator.free(capability);
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
    }

    pub fn hasCapability(self: Advertisement, name: []const u8) bool {
        for (self.capabilities) |capability| {
            if (std.mem.eql(u8, capability, name) or
                (std.mem.startsWith(u8, capability, name) and capability.len > name.len and capability[name.len] == '=')) return true;
        }
        return false;
    }

    pub fn findRef(self: Advertisement, name: []const u8) ?Oid {
        for (self.refs) |ref| if (std.mem.eql(u8, ref.name, name)) return ref.oid;
        return null;
    }

    pub fn hasRefPrefix(self: Advertisement, prefix: []const u8) bool {
        for (self.refs) |ref| if (std.mem.startsWith(u8, ref.name, prefix)) return true;
        return false;
    }
};

fn validRef(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "refs/") or name.len > 1024 or name[name.len - 1] == '/') return false;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "@{") != null or std.mem.indexOf(u8, name, "//") != null) return false;
    for (name) |byte| if (byte <= 0x20 or byte == 0x7f or std.mem.indexOfScalar(u8, "~^:?*[\\", byte) != null) return false;
    return true;
}

fn validAdvertisedRef(name: []const u8) bool {
    if (validRef(name)) return true;
    const suffix = "^{}";
    return std.mem.endsWith(u8, name, suffix) and validRef(name[0 .. name.len - suffix.len]);
}

pub fn parseAdvertisement(allocator: std.mem.Allocator, input: []const u8, limits: Limits) !Advertisement {
    if (input.len > limits.max_advertisement) return error.LimitExceeded;
    var refs: std.ArrayList(Ref) = .empty;
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit(allocator);
    }
    var capabilities: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (capabilities.items) |capability| allocator.free(capability);
        capabilities.deinit(allocator);
    }
    var iterator = PktIterator{ .input = input, .limits = limits };
    var first = true;
    while (try iterator.next()) |pkt| {
        if (pkt.kind == .flush) {
            if (refs.items.len == 0) continue;
            break;
        }
        if (pkt.kind != .data) return error.UnsupportedProtocol;
        var line = std.mem.trimEnd(u8, pkt.data, "\n");
        if (std.mem.startsWith(u8, line, "# service=")) continue;
        if (line.len == 0) continue;
        var caps: []const u8 = &.{};
        if (first) {
            if (std.mem.indexOfScalar(u8, line, 0)) |nul| {
                caps = line[nul + 1 ..];
                line = line[0..nul];
            }
        }
        if (line.len < 42 or line[40] != ' ') return error.ProtocolError;
        const oid = try Oid.fromHex(line[0..40]);
        const name = line[41..];
        if (!validAdvertisedRef(name) and !std.mem.eql(u8, name, "capabilities^{}") and !std.mem.eql(u8, name, "HEAD")) return error.BadRef;
        if (refs.items.len >= limits.max_refs) return error.LimitExceeded;
        try refs.append(allocator, .{ .name = try allocator.dupe(u8, name), .oid = oid });
        var cap_it = std.mem.tokenizeScalar(u8, caps, ' ');
        while (cap_it.next()) |capability| try capabilities.append(allocator, try allocator.dupe(u8, capability));
        first = false;
    }
    return .{ .refs = try refs.toOwnedSlice(allocator), .capabilities = try capabilities.toOwnedSlice(allocator), .allocator = allocator };
}

fn appendU32(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try output.appendSlice(allocator, &bytes);
}

fn appendStoredZlib(output: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try output.appendSlice(allocator, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < data.len or data.len == 0 and offset == 0) {
        const remaining = data.len - offset;
        const count: u16 = @intCast(@min(remaining, 65535));
        const final = offset + count == data.len;
        try output.append(allocator, if (final) 1 else 0);
        var len: [2]u8 = undefined;
        var nlen: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, count, .little);
        std.mem.writeInt(u16, &nlen, ~count, .little);
        try output.appendSlice(allocator, &len);
        try output.appendSlice(allocator, &nlen);
        try output.appendSlice(allocator, data[offset..][0..count]);
        offset += count;
        if (final) break;
    }
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, std.hash.Adler32.hash(data), .big);
    try output.appendSlice(allocator, &checksum);
}

fn appendPackEntryHeader(output: *std.ArrayList(u8), allocator: std.mem.Allocator, type_code: u3, data_size: usize) !void {
    var size = data_size;
    var first: u8 = @as(u8, type_code) << 4 | @as(u8, @truncate(size & 0x0f));
    size >>= 4;
    if (size != 0) first |= 0x80;
    try output.append(allocator, first);
    while (size != 0) {
        var byte: u8 = @truncate(size & 0x7f);
        size >>= 7;
        if (size != 0) byte |= 0x80;
        try output.append(allocator, byte);
    }
}

pub fn encodePack(allocator: std.mem.Allocator, objects: []const Object, limits: Limits) ![]u8 {
    if (objects.len > limits.max_objects) return error.LimitExceeded;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "PACK");
    try appendU32(&output, allocator, 2);
    try appendU32(&output, allocator, @intCast(objects.len));
    for (objects) |object| {
        if (object.data.len > limits.max_object) return error.LimitExceeded;
        try appendPackEntryHeader(&output, allocator, @intFromEnum(object.kind), object.data.len);
        try appendStoredZlib(&output, allocator, object.data);
        if (output.items.len > limits.max_pack - 20) return error.LimitExceeded;
    }
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(output.items, &digest, .{});
    try output.appendSlice(allocator, &digest);
    return output.toOwnedSlice(allocator);
}

pub const DecodedPack = struct {
    objects: []OwnedObject,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DecodedPack) void {
        for (self.objects) |object| object.deinit(self.allocator);
        self.allocator.free(self.objects);
    }
};

const PackedKind = union(enum) {
    object: ObjectType,
    ofs_delta: usize,
    ref_delta: Oid,
};

const PackedEntry = struct {
    offset: usize,
    kind: PackedKind,
    representation: []u8,
    resolved: ?OwnedObject = null,
};

fn readDeltaSize(input: []const u8, offset: *usize, limit: usize) !usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (offset.* >= input.len or shift >= @bitSizeOf(usize)) return error.DeltaInvalid;
        const byte = input[offset.*];
        offset.* += 1;
        const part = @as(usize, byte & 0x7f) << shift;
        result = std.math.add(usize, result, part) catch return error.DeltaInvalid;
        if (result > limit) return error.LimitExceeded;
        if (byte & 0x80 == 0) return result;
        shift += 7;
    }
}

fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8, limits: Limits) ![]u8 {
    var offset: usize = 0;
    const declared_base = try readDeltaSize(delta, &offset, limits.max_object);
    if (declared_base != base.len) return error.DeltaInvalid;
    const result_size = try readDeltaSize(delta, &offset, limits.max_object);
    const result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);
    var written: usize = 0;
    while (offset < delta.len) {
        const opcode = delta[offset];
        offset += 1;
        if (opcode == 0) return error.DeltaInvalid;
        if (opcode & 0x80 == 0) {
            const count: usize = opcode;
            if (count > delta.len - offset or count > result.len - written) return error.DeltaInvalid;
            @memcpy(result[written..][0..count], delta[offset..][0..count]);
            offset += count;
            written += count;
            continue;
        }
        var copy_offset: usize = 0;
        var copy_size: usize = 0;
        const offset_bits = [_]u8{ 0x01, 0x02, 0x04, 0x08 };
        for (offset_bits, 0..) |bit, index| {
            if (opcode & bit != 0) {
                if (offset >= delta.len) return error.DeltaInvalid;
                copy_offset |= @as(usize, delta[offset]) << @intCast(index * 8);
                offset += 1;
            }
        }
        const size_bits = [_]u8{ 0x10, 0x20, 0x40 };
        for (size_bits, 0..) |bit, index| {
            if (opcode & bit != 0) {
                if (offset >= delta.len) return error.DeltaInvalid;
                copy_size |= @as(usize, delta[offset]) << @intCast(index * 8);
                offset += 1;
            }
        }
        if (copy_size == 0) copy_size = 0x10000;
        if (copy_offset > base.len or copy_size > base.len - copy_offset or copy_size > result.len - written) return error.DeltaInvalid;
        @memcpy(result[written..][0..copy_size], base[copy_offset..][0..copy_size]);
        written += copy_size;
    }
    if (written != result.len) return error.DeltaInvalid;
    return result;
}

fn findByOffset(entries: []PackedEntry, offset: usize) ?*PackedEntry {
    for (entries) |*entry| if (entry.offset == offset) return entry;
    return null;
}

fn findByOid(entries: []PackedEntry, oid: Oid) ?*PackedEntry {
    for (entries) |*entry| {
        if (entry.resolved) |object| if (object.oid().eql(oid)) return entry;
    }
    return null;
}

pub fn decodePack(allocator: std.mem.Allocator, input: []const u8, limits: Limits) !DecodedPack {
    if (input.len > limits.max_pack) return error.LimitExceeded;
    if (input.len < 32 or !std.mem.eql(u8, input[0..4], "PACK")) return error.BadPack;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input[0 .. input.len - 20], &digest, .{});
    if (!std.mem.eql(u8, &digest, input[input.len - 20 ..])) return error.BadChecksum;
    const version = std.mem.readInt(u32, input[4..8], .big);
    if (version != 2 and version != 3) return error.UnsupportedProtocol;
    const count = std.mem.readInt(u32, input[8..12], .big);
    if (count > limits.max_objects) return error.LimitExceeded;
    const entries = try allocator.alloc(PackedEntry, count);
    defer allocator.free(entries);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| {
            allocator.free(entry.representation);
            if (entry.resolved) |object| if (object.data.ptr != entry.representation.ptr) object.deinit(allocator);
        }
    }
    var offset: usize = 12;
    for (0..count) |entry_index| {
        if (offset >= input.len - 20) return error.BadPack;
        const entry_offset = offset;
        var byte = input[offset];
        offset += 1;
        const type_code: u3 = @truncate((byte >> 4) & 7);
        var kind: PackedKind = switch (type_code) {
            1 => .{ .object = .commit },
            2 => .{ .object = .tree },
            3 => .{ .object = .blob },
            4 => .{ .object = .tag },
            6 => .{ .ofs_delta = 0 },
            7 => .{ .ref_delta = undefined },
            else => return error.BadObject,
        };
        var size: usize = byte & 0x0f;
        var shift: u6 = 4;
        while (byte & 0x80 != 0) {
            if (offset >= input.len - 20 or shift >= @bitSizeOf(usize)) return error.BadPack;
            byte = input[offset];
            offset += 1;
            size |= @as(usize, byte & 0x7f) << shift;
            shift += 7;
        }
        if (size > limits.max_object) return error.LimitExceeded;
        if (type_code == 6) {
            if (offset >= input.len - 20) return error.BadPack;
            var distance: usize = input[offset] & 0x7f;
            var distance_byte = input[offset];
            offset += 1;
            while (distance_byte & 0x80 != 0) {
                if (offset >= input.len - 20) return error.BadPack;
                distance = std.math.add(usize, distance, 1) catch return error.BadPack;
                distance = std.math.mul(usize, distance, 128) catch return error.BadPack;
                distance_byte = input[offset];
                offset += 1;
                distance = std.math.add(usize, distance, distance_byte & 0x7f) catch return error.BadPack;
            }
            if (distance == 0 or distance > entry_offset) return error.BadPack;
            kind = .{ .ofs_delta = entry_offset - distance };
        } else if (type_code == 7) {
            if (input.len - 20 - offset < 20) return error.BadPack;
            var base_oid: Oid = undefined;
            @memcpy(&base_oid.bytes, input[offset..][0..20]);
            offset += 20;
            kind = .{ .ref_delta = base_oid };
        }
        var source = std.Io.Reader.fixed(input[offset .. input.len - 20]);
        var history: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&source, .zlib, &history);
        const data = decompressor.reader.readAlloc(allocator, size) catch return error.BadPack;
        errdefer allocator.free(data);
        var probe: [1]u8 = undefined;
        const extra = decompressor.reader.readSliceShort(&probe) catch return error.BadPack;
        if (extra != 0) return error.BadObject;
        offset += source.seek;
        if (offset > input.len - 20) return error.BadPack;
        entries[entry_index] = .{ .offset = entry_offset, .kind = kind, .representation = data };
        initialized += 1;
    }
    if (offset != input.len - 20) return error.BadPack;
    var resolved_count: usize = 0;
    for (entries) |*entry| switch (entry.kind) {
        .object => |kind| {
            entry.resolved = .{ .kind = kind, .data = entry.representation };
            resolved_count += 1;
        },
        else => {},
    };
    while (resolved_count < entries.len) {
        var progress = false;
        for (entries) |*entry| {
            if (entry.resolved != null) continue;
            const base_entry = switch (entry.kind) {
                .ofs_delta => |base_offset| findByOffset(entries, base_offset),
                .ref_delta => |base_oid| findByOid(entries, base_oid),
                .object => unreachable,
            } orelse continue;
            const base = base_entry.resolved orelse continue;
            const data = try applyDelta(allocator, base.data, entry.representation, limits);
            entry.resolved = .{ .kind = base.kind, .data = data };
            resolved_count += 1;
            progress = true;
        }
        if (!progress) return error.UnresolvedDeltaBase;
    }
    const objects = try allocator.alloc(OwnedObject, entries.len);
    errdefer allocator.free(objects);
    for (entries, 0..) |*entry, index| {
        objects[index] = entry.resolved.?;
        if (objects[index].data.ptr != entry.representation.ptr) allocator.free(entry.representation);
        entry.representation = &.{};
        entry.resolved = null;
    }
    return .{ .objects = objects, .allocator = allocator };
}

pub const RefUpdate = struct {
    old: Oid,
    new: Oid,
    name: []const u8,
};

pub fn buildReceivePackRequest(allocator: std.mem.Allocator, advertisement: Advertisement, updates: []const RefUpdate, objects: []const Object, atomic: bool, limits: Limits) ![]u8 {
    if (updates.len == 0) return error.InvalidArgument;
    if (!advertisement.hasCapability("report-status")) return error.CapabilityMissing;
    if (atomic and !advertisement.hasCapability("atomic")) return error.CapabilityMissing;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (updates, 0..) |update, index| {
        if (!validRef(update.name)) return error.BadRef;
        var old_hex: [40]u8 = undefined;
        var new_hex: [40]u8 = undefined;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, update.old.format(&old_hex));
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, update.new.format(&new_hex));
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, update.name);
        if (index == 0) {
            try line.append(allocator, 0);
            try line.appendSlice(allocator, "report-status side-band-64k");
            if (atomic) try line.appendSlice(allocator, " atomic");
        }
        try line.append(allocator, '\n');
        try appendPkt(&output, allocator, line.items, limits);
    }
    try appendFlush(&output, allocator);
    const pack = try encodePack(allocator, objects, limits);
    defer allocator.free(pack);
    try output.appendSlice(allocator, pack);
    if (output.items.len > limits.max_pack + limits.max_advertisement) return error.LimitExceeded;
    return output.toOwnedSlice(allocator);
}

pub fn buildUploadPackRequest(allocator: std.mem.Allocator, advertisement: Advertisement, wants: []const Oid, haves: []const Oid, limits: Limits) ![]u8 {
    if (wants.len == 0) return error.InvalidArgument;
    if (advertisement.hasCapability("object-format=sha256")) return error.UnsupportedHash;
    const side_band = advertisement.hasCapability("side-band-64k");
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (wants, 0..) |want, index| {
        var hex: [40]u8 = undefined;
        var line: [128]u8 = undefined;
        const payload = if (index == 0 and side_band)
            std.fmt.bufPrint(&line, "want {s} side-band-64k\n", .{want.format(&hex)}) catch unreachable
        else
            std.fmt.bufPrint(&line, "want {s}\n", .{want.format(&hex)}) catch unreachable;
        try appendPkt(&output, allocator, payload, limits);
    }
    try appendFlush(&output, allocator);
    for (haves) |have| {
        var hex: [40]u8 = undefined;
        var line: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&line, "have {s}\n", .{have.format(&hex)}) catch unreachable;
        try appendPkt(&output, allocator, payload, limits);
    }
    try appendPkt(&output, allocator, "done\n", limits);
    return output.toOwnedSlice(allocator);
}

pub fn extractUploadPack(allocator: std.mem.Allocator, input: []const u8, side_band: bool, limits: Limits) ![]u8 {
    if (input.len > limits.max_pack + limits.max_advertisement) return error.LimitExceeded;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var iterator = PktIterator{ .input = input, .limits = limits };
    var negotiation_done = false;
    while (iterator.offset < input.len) {
        if (std.mem.startsWith(u8, input[iterator.offset..], "PACK")) {
            try output.appendSlice(allocator, input[iterator.offset..]);
            break;
        }
        const pkt = (try iterator.next()) orelse break;
        switch (pkt.kind) {
            .flush, .delimiter, .response_end => continue,
            .data => {
                if (!negotiation_done and (std.mem.startsWith(u8, pkt.data, "NAK") or std.mem.startsWith(u8, pkt.data, "ACK"))) {
                    negotiation_done = true;
                    continue;
                }
                if (!side_band) return error.ProtocolError;
                if (pkt.data.len == 0) return error.ProtocolError;
                switch (pkt.data[0]) {
                    1 => try output.appendSlice(allocator, pkt.data[1..]),
                    2 => {},
                    3 => return error.ProtocolError,
                    else => return error.ProtocolError,
                }
            },
        }
        if (output.items.len > limits.max_pack) return error.LimitExceeded;
    }
    if (!std.mem.startsWith(u8, output.items, "PACK")) return error.BadPack;
    return output.toOwnedSlice(allocator);
}

pub fn validateReceivePackReport(allocator: std.mem.Allocator, input: []const u8, limits: Limits) !void {
    if (input.len > limits.max_advertisement) return error.LimitExceeded;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(allocator);
    var outer = PktIterator{ .input = input, .limits = limits };
    while (try outer.next()) |pkt| {
        if (pkt.kind != .data) continue;
        if (pkt.data.len == 0) return error.ProtocolError;
        switch (pkt.data[0]) {
            1 => try report.appendSlice(allocator, pkt.data[1..]),
            2 => {},
            3 => return error.ProtocolError,
            else => try report.appendSlice(allocator, pkt.data),
        }
    }
    var inner = PktIterator{ .input = report.items, .limits = limits };
    var unpack_ok = false;
    var refs_ok: usize = 0;
    while (try inner.next()) |pkt| {
        if (pkt.kind != .data) continue;
        const line = std.mem.trimEnd(u8, pkt.data, "\n");
        if (std.mem.eql(u8, line, "unpack ok")) {
            unpack_ok = true;
        } else if (std.mem.startsWith(u8, line, "ok refs/")) {
            refs_ok += 1;
        } else if (std.mem.startsWith(u8, line, "ng ") or std.mem.startsWith(u8, line, "unpack ")) {
            return error.ProtocolError;
        }
    }
    if (!unpack_ok or refs_ok == 0) return error.ProtocolError;
}

pub const Method = enum { get, post };

pub const Header = struct { name: []const u8, value: []const u8 };

pub const HttpRequest = struct {
    method: Method,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    max_response_bytes: usize,
};

pub const HttpResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

pub const Http = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, HttpRequest) anyerror!HttpResponse,

    pub fn request(self: Http, request_value: HttpRequest) !HttpResponse {
        return self.request_fn(self.context, request_value);
    }
};

pub const Service = enum { upload_pack, receive_pack };

fn serviceName(service: Service) []const u8 {
    return switch (service) {
        .upload_pack => "git-upload-pack",
        .receive_pack => "git-receive-pack",
    };
}

pub const SmartHttp = struct {
    allocator: std.mem.Allocator,
    http: Http,
    base_url: []const u8,
    auth_headers: []const Header = &.{},
    limits: Limits = .{},

    pub fn discover(self: SmartHttp, service: Service) !Advertisement {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service={s}", .{ std.mem.trimEnd(u8, self.base_url, "/"), serviceName(service) });
        defer self.allocator.free(url);
        const response = try self.http.request(.{ .method = .get, .url = url, .headers = self.auth_headers, .body = &.{}, .max_response_bytes = self.limits.max_advertisement });
        try requireSuccess(response.status);
        var expected: [64]u8 = undefined;
        const content_type = std.fmt.bufPrint(&expected, "application/x-{s}-advertisement", .{serviceName(service)}) catch unreachable;
        if (!std.mem.eql(u8, response.content_type, content_type)) return error.BadContentType;
        return parseAdvertisement(self.allocator, response.body, self.limits);
    }

    pub fn rpc(self: SmartHttp, service: Service, body: []const u8) !HttpResponse {
        if (body.len > self.limits.max_pack + self.limits.max_advertisement) return error.LimitExceeded;
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, self.base_url, "/"), serviceName(service) });
        defer self.allocator.free(url);
        var content_type: [64]u8 = undefined;
        const value = std.fmt.bufPrint(&content_type, "application/x-{s}-request", .{serviceName(service)}) catch unreachable;
        const headers = try self.allocator.alloc(Header, self.auth_headers.len + 1);
        defer self.allocator.free(headers);
        @memcpy(headers[0..self.auth_headers.len], self.auth_headers);
        headers[self.auth_headers.len] = .{ .name = "Content-Type", .value = value };
        const response = try self.http.request(.{ .method = .post, .url = url, .headers = headers, .body = body, .max_response_bytes = self.limits.max_pack + self.limits.max_advertisement });
        try requireSuccess(response.status);
        var expected: [64]u8 = undefined;
        const response_type = std.fmt.bufPrint(&expected, "application/x-{s}-result", .{serviceName(service)}) catch unreachable;
        if (!std.mem.eql(u8, response.content_type, response_type)) return error.BadContentType;
        return response;
    }
};

fn requireSuccess(status: u16) !void {
    if (status == 401) return error.AuthenticationRequired;
    if (status == 403) return error.PermissionDenied;
    if (status != 200) return error.HttpFailure;
}

test "object ids match canonical git sha1" {
    const object = Object{ .kind = .blob, .data = "hello\n" };
    var hex: [40]u8 = undefined;
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", object.oid().format(&hex));
}

test "smart HTTP status errors preserve authentication and permission failures" {
    try std.testing.expectError(error.AuthenticationRequired, requireSuccess(401));
    try std.testing.expectError(error.PermissionDenied, requireSuccess(403));
    try std.testing.expectError(error.HttpFailure, requireSuccess(404));
    try requireSuccess(200);
}

test "pkt lines round trip and reject truncation" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendPkt(&output, std.testing.allocator, "hello\n", .{});
    try appendFlush(&output, std.testing.allocator);
    var iterator = PktIterator{ .input = output.items, .limits = .{} };
    const data = (try iterator.next()).?;
    try std.testing.expectEqual(PktKind.data, data.kind);
    try std.testing.expectEqualStrings("hello\n", data.data);
    try std.testing.expectEqual(PktKind.flush, (try iterator.next()).?.kind);
    try std.testing.expect((try iterator.next()) == null);
    var bad = PktIterator{ .input = "0008abc", .limits = .{} };
    try std.testing.expectError(error.BadPktLine, bad.next());
}

test "advertisement parses refs and capabilities" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPkt(&data, std.testing.allocator, "# service=git-receive-pack\n", .{});
    try appendFlush(&data, std.testing.allocator);
    try appendPkt(&data, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main\x00report-status side-band-64k atomic\n", .{});
    try appendPkt(&data, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a HEAD\n", .{});
    try appendPkt(&data, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a refs/tags/v1.0^{}\n", .{});
    try appendFlush(&data, std.testing.allocator);
    const advertisement = try parseAdvertisement(std.testing.allocator, data.items, .{});
    defer advertisement.deinit();
    try std.testing.expect(advertisement.hasCapability("report-status"));
    try std.testing.expect(advertisement.hasCapability("atomic"));
    try std.testing.expect(advertisement.findRef("refs/heads/main") != null);
    try std.testing.expect(advertisement.findRef("HEAD") != null);
    try std.testing.expect(advertisement.findRef("refs/tags/v1.0^{}") != null);
    try std.testing.expect(advertisement.hasRefPrefix("refs/heads/"));
    try std.testing.expect(!advertisement.hasRefPrefix("refs/apricot/native"));
}

test "pack round trips undeltified objects" {
    const expected = [_]Object{
        .{ .kind = .blob, .data = "carrier bytes\x00\xff" },
        .{ .kind = .blob, .data = "" },
        .{ .kind = .commit, .data = "tree 0000000000000000000000000000000000000000\n\nprojection\n" },
    };
    const encoded = try encodePack(std.testing.allocator, &expected, .{});
    defer std.testing.allocator.free(encoded);
    const decoded = try decodePack(std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(expected.len, decoded.objects.len);
    for (expected, decoded.objects) |a, b| {
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqualSlices(u8, a.data, b.data);
    }
}

fn finishTestPack(allocator: std.mem.Allocator, pack: *std.ArrayList(u8)) !void {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(pack.items, &digest, .{});
    try pack.appendSlice(allocator, &digest);
}

test "pack resolves ofs delta" {
    const base = "hello world\n";
    const delta = [_]u8{ 12, 10, 0x90, 6, 4, 'z', 'i', 'g', '\n' };
    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(std.testing.allocator);
    try pack.appendSlice(std.testing.allocator, "PACK");
    try appendU32(&pack, std.testing.allocator, 2);
    try appendU32(&pack, std.testing.allocator, 2);
    const base_offset = pack.items.len;
    try appendPackEntryHeader(&pack, std.testing.allocator, 3, base.len);
    try appendStoredZlib(&pack, std.testing.allocator, base);
    const delta_offset = pack.items.len;
    try appendPackEntryHeader(&pack, std.testing.allocator, 6, delta.len);
    const distance = delta_offset - base_offset;
    try std.testing.expect(distance < 128);
    try pack.append(std.testing.allocator, @intCast(distance));
    try appendStoredZlib(&pack, std.testing.allocator, &delta);
    try finishTestPack(std.testing.allocator, &pack);
    const decoded = try decodePack(std.testing.allocator, pack.items, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(ObjectType.blob, decoded.objects[1].kind);
    try std.testing.expectEqualStrings("hello zig\n", decoded.objects[1].data);
}

test "pack resolves forward ref delta" {
    const base = Object{ .kind = .blob, .data = "hello world\n" };
    const delta = [_]u8{ 12, 10, 0x90, 6, 4, 'z', 'i', 'g', '\n' };
    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(std.testing.allocator);
    try pack.appendSlice(std.testing.allocator, "PACK");
    try appendU32(&pack, std.testing.allocator, 2);
    try appendU32(&pack, std.testing.allocator, 2);
    try appendPackEntryHeader(&pack, std.testing.allocator, 7, delta.len);
    try pack.appendSlice(std.testing.allocator, &base.oid().bytes);
    try appendStoredZlib(&pack, std.testing.allocator, &delta);
    try appendPackEntryHeader(&pack, std.testing.allocator, 3, base.data.len);
    try appendStoredZlib(&pack, std.testing.allocator, base.data);
    try finishTestPack(std.testing.allocator, &pack);
    const decoded = try decodePack(std.testing.allocator, pack.items, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(ObjectType.blob, decoded.objects[0].kind);
    try std.testing.expectEqualStrings("hello zig\n", decoded.objects[0].data);
}

test "pack rejects unresolved external delta base" {
    const delta = [_]u8{ 12, 10, 0x90, 6, 4, 'z', 'i', 'g', '\n' };
    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(std.testing.allocator);
    try pack.appendSlice(std.testing.allocator, "PACK");
    try appendU32(&pack, std.testing.allocator, 2);
    try appendU32(&pack, std.testing.allocator, 1);
    try appendPackEntryHeader(&pack, std.testing.allocator, 7, delta.len);
    try pack.appendNTimes(std.testing.allocator, 0xab, 20);
    try appendStoredZlib(&pack, std.testing.allocator, &delta);
    try finishTestPack(std.testing.allocator, &pack);
    try std.testing.expectError(error.UnresolvedDeltaBase, decodePack(std.testing.allocator, pack.items, .{}));
}

test "receive request carries commands and a valid pack" {
    var advertisement_bytes: std.ArrayList(u8) = .empty;
    defer advertisement_bytes.deinit(std.testing.allocator);
    try appendPkt(&advertisement_bytes, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main\x00report-status side-band-64k atomic\n", .{});
    try appendFlush(&advertisement_bytes, std.testing.allocator);
    const advertisement = try parseAdvertisement(std.testing.allocator, advertisement_bytes.items, .{});
    defer advertisement.deinit();
    const old = try Oid.fromHex("ce013625030ba8dba906f756967f9e9ca394464a");
    const object = Object{ .kind = .blob, .data = "new carrier" };
    const request = try buildReceivePackRequest(std.testing.allocator, advertisement, &.{.{ .old = old, .new = object.oid(), .name = "refs/heads/main" }}, &.{object}, true, .{});
    defer std.testing.allocator.free(request);
    var iterator = PktIterator{ .input = request, .limits = .{} };
    _ = (try iterator.next()).?;
    try std.testing.expectEqual(PktKind.flush, (try iterator.next()).?.kind);
    const decoded = try decodePack(std.testing.allocator, request[iterator.offset..], .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("new carrier", decoded.objects[0].data);
}

test "upload side band extracts a valid pack" {
    const object = Object{ .kind = .blob, .data = "carrier" };
    const pack = try encodePack(std.testing.allocator, &.{object}, .{});
    defer std.testing.allocator.free(pack);
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(std.testing.allocator);
    try appendPkt(&response, std.testing.allocator, "NAK\n", .{});
    var offset: usize = 0;
    while (offset < pack.len) {
        const count = @min(pack.len - offset, 16);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(std.testing.allocator);
        try payload.append(std.testing.allocator, 1);
        try payload.appendSlice(std.testing.allocator, pack[offset..][0..count]);
        try appendPkt(&response, std.testing.allocator, payload.items, .{});
        offset += count;
    }
    try appendFlush(&response, std.testing.allocator);
    const extracted = try extractUploadPack(std.testing.allocator, response.items, true, .{});
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, pack, extracted);
}

test "receive report validates side band status" {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(std.testing.allocator);
    try appendPkt(&inner, std.testing.allocator, "unpack ok\n", .{});
    try appendPkt(&inner, std.testing.allocator, "ok refs/apricot/carrier\n", .{});
    try appendFlush(&inner, std.testing.allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try payload.append(std.testing.allocator, 1);
    try payload.appendSlice(std.testing.allocator, inner.items);
    var outer: std.ArrayList(u8) = .empty;
    defer outer.deinit(std.testing.allocator);
    try appendPkt(&outer, std.testing.allocator, payload.items, .{});
    try appendFlush(&outer, std.testing.allocator);
    try validateReceivePackReport(std.testing.allocator, outer.items, .{});
}
