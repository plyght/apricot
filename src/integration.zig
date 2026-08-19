const std = @import("std");
const carrier = @import("carrier.zig");
const edge = @import("edge.zig");

test "carrier survives provider-neutral edge round trip" {
    const allocator = std.testing.allocator;
    const limits = carrier.Limits{};
    const objects = [_]carrier.NativeObject{
        carrier.NativeObject.create("moment:root", "application/x-superdetermine-moment", "opaque native state\x00with exact bytes"),
    };
    const refs = [_]carrier.NativeRef{
        .{ .name = "refs/main", .target_native_id = "moment:root" },
    };
    const mappings = [_]carrier.ProjectionMapping{
        .{ .native_id = "moment:root", .projected_id = "sha256:forge-projection" },
    };
    const manifest = carrier.Manifest{
        .vcs = "superdetermine",
        .repository_id = "example/repository",
        .chunk_size = 1024,
        .objects = &objects,
        .refs = &refs,
        .projection_mappings = &mappings,
    };
    const encoded = try carrier.encode(allocator, manifest, limits);
    defer encoded.deinit(allocator);

    const supported_hashes = [_]edge.HashAlgorithm{.sha2_256};
    var forge = edge.InMemoryForgeEdge.init(allocator, .{
        .compare_and_swap_refs = true,
        .atomic_ref_updates = true,
        .ref_deletion = true,
        .max_object_bytes = null,
        .max_updates_per_transaction = null,
        .hash_algorithms = &supported_hashes,
    });
    defer forge.deinit();
    const provider_edge = forge.edge();

    var digest = [_]u8{0} ** 64;
    @memcpy(digest[0..32], &encoded.root.bytes);
    const object_id = edge.ObjectId{
        .algorithm = .sha2_256,
        .digest = digest,
        .digest_len = 32,
    };
    try provider_edge.putObject(.{ .id = object_id, .bytes = encoded.bytes });
    const updates = [_]edge.RefUpdate{
        .{
            .ref = .{ .scope = .native, .name = "apricot/native/root" },
            .expected = null,
            .desired = object_id,
        },
    };
    const result = try provider_edge.applyRefUpdates(&updates, .require_atomic);
    try std.testing.expectEqual(edge.UpdateMode.atomic, result.mode);

    const fetched = provider_edge.getObject(object_id) orelse return error.MissingObject;
    try carrier.verifyEncoded(encoded.root, fetched, limits);
    var decoded = try carrier.decode(allocator, fetched, limits);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("superdetermine", decoded.manifest.vcs);
    try std.testing.expectEqualStrings(objects[0].bytes, decoded.manifest.objects[0].bytes);
    try std.testing.expect(edge.ObjectId.eql(object_id, provider_edge.readRef(updates[0].ref).?));
}
