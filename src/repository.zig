const std = @import("std");
const adapter = @import("adapter.zig");
const carrier = @import("carrier.zig");
const edge = @import("edge.zig");

pub const native_root_ref = edge.RefId{ .scope = .native, .name = "apricot/root" };
pub const projection_root_ref = edge.RefId{ .scope = .projection, .name = "apricot/projection" };

pub const RepositoryError = error{
    AbortedTransaction,
    CarrierRootMismatch,
    CorruptCarrier,
    MissingCarrier,
    MissingCarrierRef,
    ProjectionChanged,
    RefusedForeignProjection,
    RequiresForeignResolution,
    UnsupportedHashAlgorithm,
};

pub const Revision = struct {
    carrier_object: edge.ObjectId,
    carrier_root: carrier.ContentId,
    projection_object: edge.ObjectId,
};

pub const Publication = struct {
    transaction: edge.TransactionId,
    carrier_bytes: []const u8,
    carrier_root: carrier.ContentId,
    projection_bytes: []const u8,
    expected_carrier: ?edge.ObjectId,
    expected_projection: ?edge.ObjectId,
};

pub const PublicationResult = struct {
    revision: Revision,
    projection_mode: edge.UpdateMode,
    commit_mode: edge.UpdateMode,
};

pub const FetchedCarrier = struct {
    object_id: edge.ObjectId,
    encoded: []const u8,
    root: carrier.ContentId,
};

pub const ProjectionState = union(enum) {
    clean,
    importable: struct { strategy: []const u8 },
    requires_resolution: struct { reason: []const u8 },
    refused: struct { reason: []const u8 },
};

pub const RecoveryResult = union(enum) {
    published: PublicationResult,
    already_complete: Revision,
};

pub const NativeObjectDecoder = struct {
    context: *anyopaque,
    decodeFn: *const fn (context: *anyopaque, object: carrier.NativeObject) anyerror!adapter.NativeObject,

    pub fn decode(self: NativeObjectDecoder, object: carrier.NativeObject) !adapter.NativeObject {
        return self.decodeFn(self.context, object);
    }
};

pub const RestoreResult = struct {
    carrier_root: carrier.ContentId,
    report: adapter.RestoreReport,
};

pub const Repository = struct {
    forge: edge.Edge,
    limits: carrier.Limits = .{},
    policy: edge.UpdatePolicy = .prefer_atomic,

    pub fn publish(self: Repository, publication: Publication) !PublicationResult {
        const plan_data = try self.makePlan(publication);
        const plan = plan_data.publicationPlan(publication.transaction);
        try self.forge.prepare(plan);
        const projected = self.forge.project(plan, self.policy) catch |err| {
            self.forge.abort(publication.transaction) catch {};
            return err;
        };
        const committed = self.forge.commit(plan, self.policy) catch |err| return err;
        return .{
            .revision = plan_data.revision,
            .projection_mode = projected.mode,
            .commit_mode = committed.mode,
        };
    }

    pub fn recover(self: Repository, publication: Publication) !RecoveryResult {
        const plan_data = try self.makePlan(publication);
        const plan = plan_data.publicationPlan(publication.transaction);
        const phase = self.forge.transactionPhase(publication.transaction) orelse {
            return .{ .published = try self.publish(publication) };
        };
        return switch (phase) {
            .prepare => blk: {
                const projected = try self.forge.project(plan, self.policy);
                const committed = try self.forge.commit(plan, self.policy);
                break :blk .{ .published = .{
                    .revision = plan_data.revision,
                    .projection_mode = projected.mode,
                    .commit_mode = committed.mode,
                } };
            },
            .project => blk: {
                const committed = try self.forge.commit(plan, self.policy);
                break :blk .{ .published = .{
                    .revision = plan_data.revision,
                    .projection_mode = committed.mode,
                    .commit_mode = committed.mode,
                } };
            },
            .commit => .{ .already_complete = plan_data.revision },
            .abort => error.AbortedTransaction,
        };
    }

    pub fn fetch(self: Repository) !FetchedCarrier {
        const object_id = self.forge.readRef(native_root_ref) orelse return error.MissingCarrierRef;
        const encoded = self.forge.getObject(object_id) orelse return error.MissingCarrier;
        const root = carrier.computeRoot(encoded);
        carrier.verifyEncoded(root, encoded, self.limits) catch return error.CorruptCarrier;
        return .{ .object_id = object_id, .encoded = encoded, .root = root };
    }

    pub fn fetchExact(self: Repository, expected: carrier.ContentId) !FetchedCarrier {
        const fetched = try self.fetch();
        if (!fetched.root.eql(expected)) return error.CarrierRootMismatch;
        return fetched;
    }

    pub fn decodeFetched(self: Repository, allocator: std.mem.Allocator, fetched: FetchedCarrier) !carrier.OwnedManifest {
        carrier.verifyEncoded(fetched.root, fetched.encoded, self.limits) catch return error.CorruptCarrier;
        return carrier.decode(allocator, fetched.encoded, self.limits) catch return error.CorruptCarrier;
    }

    pub fn restore(
        self: Repository,
        allocator: std.mem.Allocator,
        vcs_adapter: adapter.Adapter,
        snapshot: adapter.Snapshot,
        expected: carrier.ContentId,
        decoder: NativeObjectDecoder,
    ) !RestoreResult {
        const fetched = try self.fetchExact(expected);
        var decoded = try self.decodeFetched(allocator, fetched);
        defer decoded.deinit(allocator);
        var source_context = RestoreSource{
            .objects = decoded.manifest.objects,
            .decoder = decoder,
        };
        const report = try vcs_adapter.restore(snapshot, .{
            .context = &source_context,
            .getFn = RestoreSource.get,
        });
        if (!report.verified_tier.satisfies(snapshot.closure.tier)) return error.CorruptCarrier;
        return .{ .carrier_root = fetched.root, .report = report };
    }

    pub fn inspectProjection(
        self: Repository,
        vcs_adapter: adapter.Adapter,
        expected: edge.ObjectId,
        kind: []const u8,
        evidence_media_type: []const u8,
        evidence: []const u8,
    ) !ProjectionState {
        const observed = self.forge.readRef(projection_root_ref);
        if (observed != null and edge.ObjectId.eql(observed.?, expected)) return .clean;
        const expected_bytes = self.forge.getObject(expected) orelse return error.MissingCarrier;
        const observed_id = observed orelse return error.ProjectionChanged;
        const observed_bytes = self.forge.getObject(observed_id) orelse return error.ProjectionChanged;
        const inspection = try vcs_adapter.inspectForeign(.{
            .kind = kind,
            .base_projection = expected_bytes,
            .observed_projection = observed_bytes,
            .evidence_media_type = evidence_media_type,
            .evidence = evidence,
        });
        return switch (inspection) {
            .importable => |value| .{ .importable = .{ .strategy = value.strategy } },
            .requires_resolution => |value| .{ .requires_resolution = .{ .reason = value.reason } },
            .refused => |value| .{ .refused = .{ .reason = value.reason } },
        };
    }

    pub fn requireCleanProjection(
        self: Repository,
        vcs_adapter: adapter.Adapter,
        expected: edge.ObjectId,
        kind: []const u8,
        evidence_media_type: []const u8,
        evidence: []const u8,
    ) !void {
        const state = try self.inspectProjection(vcs_adapter, expected, kind, evidence_media_type, evidence);
        return switch (state) {
            .clean => {},
            .importable => error.ProjectionChanged,
            .requires_resolution => error.RequiresForeignResolution,
            .refused => error.RefusedForeignProjection,
        };
    }

    const PlanData = struct {
        revision: Revision,
        objects: [2]edge.Object,
        projection_updates: [1]edge.RefUpdate,
        commit_updates: [1]edge.RefUpdate,

        fn publicationPlan(self: *const PlanData, transaction: edge.TransactionId) edge.PublicationPlan {
            return .{
                .id = transaction,
                .native_root = self.revision.carrier_object,
                .objects = &self.objects,
                .projection_updates = &self.projection_updates,
                .commit_updates = &self.commit_updates,
            };
        }
    };

    fn makePlan(self: Repository, publication: Publication) !PlanData {
        carrier.verifyEncoded(publication.carrier_root, publication.carrier_bytes, self.limits) catch |err| switch (err) {
            error.RootMismatch => return error.CarrierRootMismatch,
            else => return error.CorruptCarrier,
        };
        const capabilities = self.forge.discoverCapabilities();
        const algorithm = selectHash(capabilities) orelse return error.UnsupportedHashAlgorithm;
        const carrier_id = objectId(algorithm, publication.carrier_bytes);
        const projection_id = objectId(algorithm, publication.projection_bytes);
        return PlanData{
            .revision = .{
                .carrier_object = carrier_id,
                .carrier_root = publication.carrier_root,
                .projection_object = projection_id,
            },
            .objects = .{
                .{ .id = carrier_id, .bytes = publication.carrier_bytes },
                .{ .id = projection_id, .bytes = publication.projection_bytes },
            },
            .projection_updates = .{.{
                .ref = projection_root_ref,
                .expected = publication.expected_projection,
                .desired = projection_id,
            }},
            .commit_updates = .{.{
                .ref = native_root_ref,
                .expected = publication.expected_carrier,
                .desired = carrier_id,
            }},
        };
    }
};

const RestoreSource = struct {
    objects: []const carrier.NativeObject,
    decoder: NativeObjectDecoder,

    fn get(context: *anyopaque, id: adapter.NativeId) !?adapter.NativeObject {
        const self: *RestoreSource = @ptrCast(@alignCast(context));
        for (self.objects) |object| {
            const decoded = try self.decoder.decode(object);
            if (decoded.id.eql(id)) return decoded;
        }
        return null;
    }
};

fn selectHash(capabilities: edge.ProtocolCapabilities) ?edge.HashAlgorithm {
    if (capabilities.supportsHash(.sha2_256)) return .sha2_256;
    if (capabilities.supportsHash(.blake3_256)) return .blake3_256;
    if (capabilities.supportsHash(.sha2_512)) return .sha2_512;
    return null;
}

fn objectId(algorithm: edge.HashAlgorithm, bytes: []const u8) edge.ObjectId {
    var digest = [_]u8{0} ** 64;
    const digest_len: u8 = switch (algorithm) {
        .sha2_256 => blk: {
            std.crypto.hash.sha2.Sha256.hash(bytes, digest[0..32], .{});
            break :blk 32;
        },
        .blake3_256 => blk: {
            std.crypto.hash.Blake3.hash(bytes, digest[0..32], .{});
            break :blk 32;
        },
        .sha2_512 => blk: {
            std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
            break :blk 64;
        },
    };
    return .{ .algorithm = algorithm, .digest = digest, .digest_len = digest_len };
}

fn testCapabilities() edge.ProtocolCapabilities {
    return .{
        .compare_and_swap_refs = true,
        .atomic_ref_updates = true,
        .ref_deletion = true,
        .max_object_bytes = null,
        .max_updates_per_transaction = null,
        .hash_algorithms = &.{.sha2_256},
    };
}

fn testCarrier(allocator: std.mem.Allocator, prior: ?carrier.ContentId) !carrier.EncodedManifest {
    const objects = &[_]carrier.NativeObject{
        carrier.NativeObject.create("state", "application/vnd.example.state", "native\x00bytes\xff"),
    };
    return carrier.encode(allocator, .{
        .vcs = "example-vcs",
        .repository_id = "repository",
        .chunk_size = 1024,
        .prior_root = prior,
        .objects = objects,
        .refs = &.{.{ .name = "main", .target_native_id = "state" }},
        .projection_mappings = &.{.{ .native_id = "state", .projected_id = "tree" }},
    }, .{});
}

fn testPublication(encoded: carrier.EncodedManifest, projection: []const u8, byte: u8) Publication {
    return .{
        .transaction = [_]u8{byte} ** 16,
        .carrier_bytes = encoded.bytes,
        .carrier_root = encoded.root,
        .projection_bytes = projection,
        .expected_carrier = null,
        .expected_projection = null,
    };
}

test "publication commits exact carrier after disposable projection" {
    const allocator = std.testing.allocator;
    const encoded = try testCarrier(allocator, null);
    defer encoded.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    const result = try repository.publish(testPublication(encoded, "projected tree", 1));
    try std.testing.expectEqual(edge.PublicationPhase.commit, memory.transactionPhase([_]u8{1} ** 16).?);
    try std.testing.expect(edge.ObjectId.eql(result.revision.carrier_object, memory.readRef(native_root_ref).?));
    try std.testing.expect(edge.ObjectId.eql(result.revision.projection_object, memory.readRef(projection_root_ref).?));
    const fetched = try repository.fetchExact(encoded.root);
    try std.testing.expectEqualSlices(u8, encoded.bytes, fetched.encoded);
    var decoded = try repository.decodeFetched(allocator, fetched);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "native\x00bytes\xff", decoded.manifest.objects[0].bytes);
}

test "carrier verification refuses corruption and mismatched declared roots" {
    const allocator = std.testing.allocator;
    const encoded = try testCarrier(allocator, null);
    defer encoded.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    var wrong = encoded.root;
    wrong.bytes[0] ^= 1;
    var publication = testPublication(encoded, "projection", 2);
    publication.carrier_root = wrong;
    try std.testing.expectError(error.CarrierRootMismatch, repository.publish(publication));
    const corrupt = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(corrupt);
    corrupt[0] = 'X';
    publication.carrier_bytes = corrupt;
    publication.carrier_root = carrier.computeRoot(corrupt);
    try std.testing.expectError(error.CorruptCarrier, repository.publish(publication));
}

test "recovery resumes prepared and projected transactions idempotently" {
    const allocator = std.testing.allocator;
    const encoded = try testCarrier(allocator, null);
    defer encoded.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    const publication = testPublication(encoded, "projection", 3);
    const prepared = try repository.makePlan(publication);
    try repository.forge.prepare(prepared.publicationPlan(publication.transaction));
    const resumed = try repository.recover(publication);
    try std.testing.expect(resumed == .published);
    const completed = try repository.recover(publication);
    try std.testing.expect(completed == .already_complete);
    try std.testing.expectEqual(edge.PublicationPhase.commit, repository.forge.transactionPhase(publication.transaction).?);
}

test "foreign projection changes are classified and refused explicitly" {
    const allocator = std.testing.allocator;
    const encoded = try testCarrier(allocator, null);
    defer encoded.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    const published = try repository.publish(testPublication(encoded, "base projection", 4));
    const changed_id = objectId(.sha2_256, "foreign projection");
    try repository.forge.putObject(.{ .id = changed_id, .bytes = "foreign projection" });
    _ = try repository.forge.applyRefUpdates(&.{.{
        .ref = projection_root_ref,
        .expected = published.revision.projection_object,
        .desired = changed_id,
    }}, .require_atomic);
    var implementation = adapter.AdversarialAdapter{};
    const vcs_adapter = implementation.adapter();
    const importable = try repository.inspectProjection(vcs_adapter, published.revision.projection_object, "fast-forward-tree", "application/octet-stream", "evidence");
    try std.testing.expect(importable == .importable);
    try std.testing.expectError(error.ProjectionChanged, repository.requireCleanProjection(vcs_adapter, published.revision.projection_object, "fast-forward-tree", "application/octet-stream", "evidence"));
    try std.testing.expectError(error.RequiresForeignResolution, repository.requireCleanProjection(vcs_adapter, published.revision.projection_object, "conflicted-tree", "application/octet-stream", "evidence"));
    try std.testing.expectError(error.RefusedForeignProjection, repository.requireCleanProjection(vcs_adapter, published.revision.projection_object, "identity-rewrite", "application/octet-stream", "evidence"));
}

test "compare and swap refuses concurrent carrier publication" {
    const allocator = std.testing.allocator;
    const first = try testCarrier(allocator, null);
    defer first.deinit(allocator);
    const second = try testCarrier(allocator, first.root);
    defer second.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    _ = try repository.publish(testPublication(first, "first", 5));
    try std.testing.expectError(error.RefConflict, repository.publish(testPublication(second, "second", 6)));
    const fetched = try repository.fetchExact(first.root);
    try std.testing.expectEqualSlices(u8, first.bytes, fetched.encoded);
}

test "restore delegates opaque carrier objects to the vcs codec and adapter" {
    const allocator = std.testing.allocator;
    const fixture_objects = adapter.AdversarialAdapter.fixtureObjects();
    var native_objects: [4]carrier.NativeObject = undefined;
    for (fixture_objects, 0..) |object, index| {
        native_objects[index] = carrier.NativeObject.create(object.id.bytes, object.kind, object.bytes);
    }
    const encoded = try carrier.encode(allocator, .{
        .vcs = "adversarial-fixture",
        .repository_id = "restore",
        .chunk_size = 1024,
        .objects = &native_objects,
        .refs = &.{.{ .name = "repository", .target_native_id = native_objects[0].native_id }},
        .projection_mappings = &.{},
    }, .{});
    defer encoded.deinit(allocator);
    var memory = edge.InMemoryForgeEdge.init(allocator, testCapabilities());
    defer memory.deinit();
    const repository = Repository{ .forge = memory.edge() };
    _ = try repository.publish(testPublication(encoded, "restore projection", 7));
    const Decoder = struct {
        fn decode(context: *anyopaque, object: carrier.NativeObject) !adapter.NativeObject {
            _ = context;
            for (adapter.AdversarialAdapter.fixtureObjects()) |fixture| {
                if (std.mem.eql(u8, fixture.id.bytes, object.native_id)) {
                    if (!std.mem.eql(u8, fixture.kind, object.object_type)) return error.CorruptObject;
                    return .{
                        .id = fixture.id,
                        .kind = object.object_type,
                        .bytes = object.bytes,
                        .dependencies = fixture.dependencies,
                    };
                }
            }
            return error.UnknownObject;
        }
    };
    var decoder_context: u8 = 0;
    var implementation = adapter.AdversarialAdapter{};
    const restored = try repository.restore(
        allocator,
        implementation.adapter(),
        adapter.AdversarialAdapter.fixtureSnapshot(),
        encoded.root,
        .{ .context = &decoder_context, .decodeFn = Decoder.decode },
    );
    try std.testing.expect(implementation.restored);
    try std.testing.expect(restored.carrier_root.eql(encoded.root));
    try std.testing.expectEqual(adapter.PreservationTier.byte_lossless, restored.report.verified_tier);
}
