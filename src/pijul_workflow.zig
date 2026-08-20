const std = @import("std");
const api = @import("api.zig");
const carrier = @import("carrier.zig");
const forge = @import("git_forge.zig");
const git = @import("git_transport.zig");
const host = @import("host.zig");
const pijul = @import("pijul_adapter.zig");

pub const adapter_name = "pijul";
pub const archive_kind = "pijul-repository-archive";

pub const PublishOptions = struct {
    remote: []const u8,
    repository_path: []const u8,
    repository_id: []const u8,
    branch: []const u8 = "main",
    signature: forge.Signature,
    timestamp: i64,
    carrier_limits: carrier.Limits = .{},
    git_limits: git.Limits = .{},
};

pub const RestoreOptions = struct {
    remote: []const u8,
    destination_path: []const u8,
    branch: []const u8 = "main",
    carrier_limits: carrier.Limits = .{},
    git_limits: git.Limits = .{},
};

pub const Restored = struct {
    projection_commit: git.Oid,
    carrier_root: carrier.ContentId,
};

pub fn publish(allocator: std.mem.Allocator, io: std.Io, callbacks: host.Callbacks, options: PublishOptions) !api.PublishResult {
    if (options.repository_path.len == 0) return error.InvalidRepositoryPath;
    if (options.repository_id.len == 0) return error.InvalidRepositoryIdentity;
    var implementation = pijul.PijulAdapter.init(allocator, io, options.repository_path, options.repository_path);
    defer implementation.deinit();
    var engine = api.Engine.init(allocator, callbacks);
    defer engine.deinit();
    try engine.registerAdapter(.{ .name = adapter_name, .implementation = implementation.adapter() });
    return engine.publish(.{
        .adapter_name = adapter_name,
        .remote = options.remote,
        .branch = options.branch,
        .repository_id = options.repository_id,
        .signature = options.signature,
        .timestamp = options.timestamp,
        .carrier_limits = options.carrier_limits,
        .git_limits = options.git_limits,
    });
}

pub fn fetchAndRestore(allocator: std.mem.Allocator, io: std.Io, callbacks: host.Callbacks, options: RestoreOptions) !Restored {
    if (options.destination_path.len == 0) return error.InvalidRepositoryPath;
    var engine = api.Engine.init(allocator, callbacks);
    defer engine.deinit();
    const fetched = try engine.fetch(.{
        .remote = options.remote,
        .branch = options.branch,
        .git_limits = options.git_limits,
    });
    defer fetched.deinit(allocator);
    try restoreCarrier(allocator, io, options.destination_path, fetched.carrier_root, fetched.carrier_bytes, options.carrier_limits);
    return .{
        .projection_commit = fetched.projection_commit,
        .carrier_root = fetched.carrier_root,
    };
}

pub fn restoreCarrier(allocator: std.mem.Allocator, io: std.Io, destination_path: []const u8, expected_root: carrier.ContentId, encoded: []const u8, limits: carrier.Limits) !void {
    if (destination_path.len == 0) return error.InvalidRepositoryPath;
    try carrier.verifyEncoded(expected_root, encoded, limits);
    var decoded = try carrier.decode(allocator, encoded, limits);
    defer decoded.deinit(allocator);
    if (!std.mem.eql(u8, decoded.manifest.vcs, adapter_name)) return error.AdapterIdentityMismatch;
    if (decoded.manifest.objects.len != 1) return error.InvalidPijulCarrier;
    const object = decoded.manifest.objects[0];
    if (!std.mem.eql(u8, try decodedObjectKind(object.object_type), archive_kind)) return error.InvalidPijulCarrier;
    var referenced = false;
    for (decoded.manifest.refs) |native_ref| {
        if (std.mem.eql(u8, native_ref.target_native_id, object.native_id)) referenced = true;
    }
    if (!referenced) return error.InvalidPijulCarrier;
    try pijul.restoreRepository(allocator, io, destination_path, object.bytes);
}

fn decodedObjectKind(encoded: []const u8) ![]const u8 {
    if (encoded.len < 8) return error.MalformedAdapterMetadata;
    const kind_length: usize = std.mem.readInt(u32, encoded[0..4], .big);
    const kind_end = std.math.add(usize, 4, kind_length) catch return error.MalformedAdapterMetadata;
    const count_end = std.math.add(usize, kind_end, 4) catch return error.MalformedAdapterMetadata;
    if (kind_length == 0 or count_end > encoded.len) return error.MalformedAdapterMetadata;
    if (std.mem.readInt(u32, encoded[kind_end..][0..4], .big) != 0 or count_end != encoded.len) return error.InvalidPijulCarrier;
    return encoded[4..kind_end];
}

test "Pijul workflow decodes opaque archive object metadata" {
    var encoded: [4 + archive_kind.len + 4]u8 = undefined;
    std.mem.writeInt(u32, encoded[0..4], archive_kind.len, .big);
    @memcpy(encoded[4 .. 4 + archive_kind.len], archive_kind);
    std.mem.writeInt(u32, encoded[4 + archive_kind.len ..][0..4], 0, .big);
    try std.testing.expectEqualStrings(archive_kind, try decodedObjectKind(&encoded));
}

test "Pijul workflow rejects dependent and malformed archive objects" {
    var dependent: [4 + archive_kind.len + 4]u8 = undefined;
    std.mem.writeInt(u32, dependent[0..4], archive_kind.len, .big);
    @memcpy(dependent[4 .. 4 + archive_kind.len], archive_kind);
    std.mem.writeInt(u32, dependent[4 + archive_kind.len ..][0..4], 1, .big);
    try std.testing.expectError(error.InvalidPijulCarrier, decodedObjectKind(&dependent));
    try std.testing.expectError(error.MalformedAdapterMetadata, decodedObjectKind("short"));
}
