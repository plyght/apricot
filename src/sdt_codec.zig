const std = @import("std");
const carrier = @import("carrier.zig");
const forge = @import("git_forge.zig");
const sdt = @import("sdt_adapter.zig");

pub const Captured = struct {
    archive_bytes: []u8,
    archive: sdt.Archive,
    encoded: carrier.EncodedManifest,
    projection: []forge.ProjectionEntry,

    pub fn deinit(self: *Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.projection);
        self.encoded.deinit(allocator);
        self.archive.deinit(allocator);
        allocator.free(self.archive_bytes);
        self.* = undefined;
    }
};

pub fn capture(allocator: std.mem.Allocator, io: std.Io, repository_path: []const u8, repository_id: []const u8) !Captured {
    const archive_bytes = try sdt.captureRepository(allocator, io, repository_path);
    errdefer allocator.free(archive_bytes);
    var archive = try sdt.decodeArchive(allocator, archive_bytes);
    errdefer archive.deinit(allocator);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &digest, .{});
    var native_id_buffer: [64]u8 = undefined;
    const native_id = std.fmt.bufPrint(&native_id_buffer, "{x}", .{digest}) catch unreachable;
    const objects = [_]carrier.NativeObject{
        carrier.NativeObject.create(native_id, "application/vnd.apricot.superdetermine-archive-v1", archive_bytes),
    };
    const refs = [_]carrier.NativeRef{
        .{ .name = "repository/exact", .target_native_id = native_id },
    };
    const manifest = carrier.Manifest{
        .vcs = "superdetermine",
        .repository_id = repository_id,
        .chunk_size = 4 * 1024 * 1024,
        .objects = &objects,
        .refs = &refs,
        .projection_mappings = &.{},
    };
    const encoded = try carrier.encode(allocator, manifest, .{});
    errdefer encoded.deinit(allocator);

    var projection: std.ArrayList(forge.ProjectionEntry) = .empty;
    errdefer projection.deinit(allocator);
    for (archive.entries) |entry| switch (entry.kind) {
        .directory => {},
        .file => {
            if (isNativeMetadata(entry.path)) continue;
            try projection.append(allocator, .{
                .path = entry.path,
                .kind = .file,
                .executable = entry.mode & 0o111 != 0,
                .data = entry.data,
            });
        },
        .symlink => {
            if (isNativeMetadata(entry.path)) continue;
            try projection.append(allocator, .{
                .path = entry.path,
                .kind = .symlink,
                .data = entry.data,
            });
        },
    };
    return .{
        .archive_bytes = archive_bytes,
        .archive = archive,
        .encoded = encoded,
        .projection = try projection.toOwnedSlice(allocator),
    };
}

pub fn restore(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, encoded: []const u8, expected_root: carrier.ContentId) !void {
    try carrier.verifyEncoded(expected_root, encoded, .{});
    var decoded = try carrier.decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);
    if (!std.mem.eql(u8, decoded.manifest.vcs, "superdetermine")) return error.WrongVcs;
    if (decoded.manifest.objects.len != 1) return error.InvalidSuperdetermineCarrier;
    const object = decoded.manifest.objects[0];
    if (!std.mem.eql(u8, object.object_type, "application/vnd.apricot.superdetermine-archive-v1")) return error.InvalidSuperdetermineCarrier;
    try sdt.restoreRepository(allocator, io, destination, object.bytes);
}

fn isNativeMetadata(path: []const u8) bool {
    return std.mem.eql(u8, path, ".sdt") or std.mem.startsWith(u8, path, ".sdt/") or
        std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/");
}

test "sdt codec keeps native metadata only in exact carrier" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.createDirPath(io, ".sdt/objects");
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/index", .data = "1 5 1 hash source\n" });
    try source.dir.writeFile(io, .{ .sub_path = ".sdt/HEAD", .data = "ref: refs/heads/main\n" });
    try source.dir.writeFile(io, .{ .sub_path = "source", .data = "hello" });
    const source_path = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    var captured = try capture(allocator, io, source_path, "fixture");
    defer captured.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), captured.projection.len);
    try std.testing.expectEqualStrings("source", captured.projection[0].path);
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const destination_path = try destination.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(destination_path);
    try restore(allocator, io, destination_path, captured.encoded.bytes, captured.encoded.root);
    const head = try destination.dir.readFileAlloc(io, ".sdt/HEAD", allocator, .unlimited);
    defer allocator.free(head);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head);
}
