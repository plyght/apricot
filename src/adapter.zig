const std = @import("std");

pub const PreservationTier = enum {
    byte_lossless,
    semantic_lossless,

    pub fn satisfies(actual: PreservationTier, required: PreservationTier) bool {
        return actual == .byte_lossless or actual == required;
    }
};

pub const Support = enum {
    required,
    optional,
    unsupported,
};

pub const NativeId = struct {
    scheme: []const u8,
    bytes: []const u8,

    pub fn eql(a: NativeId, b: NativeId) bool {
        return std.mem.eql(u8, a.scheme, b.scheme) and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub const NativeRoot = struct {
    role: []const u8,
    id: NativeId,
};

pub const NativeRef = struct {
    namespace: []const u8,
    name: []const u8,
    target: NativeId,
    mutable: bool,
};

pub const CapabilityParameter = struct {
    name: []const u8,
    value: []const u8,
};

pub const Capability = struct {
    name: []const u8,
    support: Support,
    parameters: []const CapabilityParameter = &.{},
};

pub const ClosureExclusion = struct {
    namespace: []const u8,
    reason: []const u8,
    affects_semantics: bool,
};

pub const ClosureDeclaration = struct {
    tier: PreservationTier,
    authoritative_kinds: []const []const u8,
    exclusions: []const ClosureExclusion,
};

pub const Snapshot = struct {
    vcs: []const u8,
    format_version: []const u8,
    roots: []const NativeRoot,
    refs: []const NativeRef,
    capabilities: []const Capability,
    closure: ClosureDeclaration,
};

pub const NativeObject = struct {
    id: NativeId,
    kind: []const u8,
    bytes: []const u8,
    dependencies: []const NativeId = &.{},
};

pub const ObjectSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, object: NativeObject) anyerror!void,

    pub fn emit(self: ObjectSink, object: NativeObject) !void {
        return self.emitFn(self.context, object);
    }
};

pub const ObjectSource = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, id: NativeId) anyerror!?NativeObject,

    pub fn get(self: ObjectSource, id: NativeId) !?NativeObject {
        return self.getFn(self.context, id);
    }
};

pub const ProjectionResource = struct {
    id: []const u8,
    kind: []const u8,
    media_type: []const u8,
    payload: []const u8,
};

pub const ProjectionRelation = struct {
    kind: []const u8,
    source: []const u8,
    target: []const u8,
    ordinal: ?u64 = null,
};

pub const ProjectionEntryPoint = struct {
    namespace: []const u8,
    name: []const u8,
    resource: []const u8,
};

pub const ProjectionSink = struct {
    context: *anyopaque,
    emitResourceFn: *const fn (context: *anyopaque, resource: ProjectionResource) anyerror!void,
    emitRelationFn: *const fn (context: *anyopaque, relation: ProjectionRelation) anyerror!void,
    emitEntryPointFn: *const fn (context: *anyopaque, entry: ProjectionEntryPoint) anyerror!void,

    pub fn emitResource(self: ProjectionSink, resource: ProjectionResource) !void {
        return self.emitResourceFn(self.context, resource);
    }

    pub fn emitRelation(self: ProjectionSink, relation: ProjectionRelation) !void {
        return self.emitRelationFn(self.context, relation);
    }

    pub fn emitEntryPoint(self: ProjectionSink, entry: ProjectionEntryPoint) !void {
        return self.emitEntryPointFn(self.context, entry);
    }
};

pub const ForeignOperation = struct {
    kind: []const u8,
    base_projection: []const u8,
    observed_projection: []const u8,
    evidence_media_type: []const u8,
    evidence: []const u8,
};

pub const ForeignInspection = union(enum) {
    importable: struct {
        strategy: []const u8,
        affected_refs: []const NativeRef,
    },
    requires_resolution: struct {
        reason: []const u8,
        affected_refs: []const NativeRef,
    },
    refused: struct {
        reason: []const u8,
    },
};

pub const ForeignOutcome = union(enum) {
    imported: struct {
        roots: []const NativeRoot,
        tier: PreservationTier,
    },
    requires_resolution: struct {
        reason: []const u8,
    },
    refused: struct {
        reason: []const u8,
    },
};

pub const RestoreReport = struct {
    roots: []const NativeRoot,
    verified_tier: PreservationTier,
};

pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (context: *anyopaque) anyerror!Snapshot,
        enumerate: *const fn (context: *anyopaque, roots: []const NativeRoot, sink: ObjectSink) anyerror!void,
        restore: *const fn (context: *anyopaque, snapshot_value: Snapshot, source: ObjectSource) anyerror!RestoreReport,
        project: *const fn (context: *anyopaque, snapshot_value: Snapshot, sink: ProjectionSink) anyerror!void,
        inspectForeign: *const fn (context: *anyopaque, operation: ForeignOperation) anyerror!ForeignInspection,
        importForeign: *const fn (context: *anyopaque, operation: ForeignOperation, source: ObjectSource) anyerror!ForeignOutcome,
    };

    pub fn snapshot(self: Adapter) !Snapshot {
        const value = try self.vtable.snapshot(self.context);
        try validateSnapshot(value);
        return value;
    }

    pub fn enumerate(self: Adapter, roots: []const NativeRoot, sink: ObjectSink) !void {
        return self.vtable.enumerate(self.context, roots, sink);
    }

    pub fn restore(self: Adapter, snapshot_value: Snapshot, source: ObjectSource) !RestoreReport {
        try validateSnapshot(snapshot_value);
        return self.vtable.restore(self.context, snapshot_value, source);
    }

    pub fn project(self: Adapter, snapshot_value: Snapshot, sink: ProjectionSink) !void {
        try validateSnapshot(snapshot_value);
        return self.vtable.project(self.context, snapshot_value, sink);
    }

    pub fn inspectForeign(self: Adapter, operation: ForeignOperation) !ForeignInspection {
        return self.vtable.inspectForeign(self.context, operation);
    }

    pub fn importForeign(self: Adapter, operation: ForeignOperation, source: ObjectSource) !ForeignOutcome {
        return self.vtable.importForeign(self.context, operation, source);
    }
};

pub fn validateSnapshot(value: Snapshot) !void {
    if (value.vcs.len == 0 or value.format_version.len == 0) return error.InvalidIdentity;
    if (value.roots.len == 0) return error.MissingRoot;
    if (value.closure.authoritative_kinds.len == 0) return error.EmptyClosure;
    for (value.roots, 0..) |root, index| {
        try validateNativeId(root.id);
        if (root.role.len == 0) return error.InvalidRoot;
        for (value.roots[0..index]) |earlier| {
            if (std.mem.eql(u8, root.role, earlier.role)) return error.DuplicateRootRole;
        }
    }
    for (value.refs, 0..) |native_ref, index| {
        try validateNativeId(native_ref.target);
        if (native_ref.namespace.len == 0 or native_ref.name.len == 0) return error.InvalidRef;
        for (value.refs[0..index]) |earlier| {
            if (std.mem.eql(u8, native_ref.namespace, earlier.namespace) and
                std.mem.eql(u8, native_ref.name, earlier.name)) return error.DuplicateRef;
        }
    }
    for (value.capabilities, 0..) |capability, index| {
        if (capability.name.len == 0) return error.InvalidCapability;
        for (value.capabilities[0..index]) |earlier| {
            if (std.mem.eql(u8, capability.name, earlier.name)) return error.DuplicateCapability;
        }
        for (capability.parameters, 0..) |parameter, parameter_index| {
            if (parameter.name.len == 0) return error.InvalidCapabilityParameter;
            for (capability.parameters[0..parameter_index]) |earlier| {
                if (std.mem.eql(u8, parameter.name, earlier.name)) return error.DuplicateCapabilityParameter;
            }
        }
    }
    for (value.closure.authoritative_kinds, 0..) |kind, index| {
        if (kind.len == 0) return error.InvalidAuthoritativeKind;
        for (value.closure.authoritative_kinds[0..index]) |earlier| {
            if (std.mem.eql(u8, kind, earlier)) return error.DuplicateAuthoritativeKind;
        }
    }
    for (value.closure.exclusions, 0..) |exclusion, index| {
        if (exclusion.namespace.len == 0 or exclusion.reason.len == 0) return error.InvalidExclusion;
        if (exclusion.affects_semantics) return error.LosslessExclusionAffectsSemantics;
        for (value.closure.exclusions[0..index]) |earlier| {
            if (std.mem.eql(u8, exclusion.namespace, earlier.namespace)) return error.DuplicateExclusion;
        }
    }
}

pub fn validateNativeId(id: NativeId) !void {
    if (id.scheme.len == 0 or id.bytes.len == 0) return error.InvalidNativeId;
}

pub fn validateNativeObject(object: NativeObject) !void {
    try validateNativeId(object.id);
    if (object.kind.len == 0) return error.InvalidObjectKind;
    for (object.dependencies) |dependency| try validateNativeId(dependency);
}

pub fn validateProjectionResource(resource: ProjectionResource) !void {
    if (resource.id.len == 0 or resource.kind.len == 0 or resource.media_type.len == 0) return error.InvalidProjectionResource;
}

pub fn validateProjectionRelation(relation: ProjectionRelation) !void {
    if (relation.kind.len == 0 or relation.source.len == 0 or relation.target.len == 0) return error.InvalidProjectionRelation;
}

pub const AdversarialAdapter = struct {
    restored: bool = false,

    const root_bytes = [_]u8{0xa1} ** 32;
    const patch_bytes = [_]u8{0xb2} ** 32;
    const conflict_bytes = [_]u8{0xc3} ** 32;
    const opaque_bytes = [_]u8{0xd4} ** 32;
    const root_id = NativeId{ .scheme = "fixture-v1", .bytes = &root_bytes };
    const patch_id = NativeId{ .scheme = "fixture-v1", .bytes = &patch_bytes };
    const conflict_id = NativeId{ .scheme = "fixture-v1", .bytes = &conflict_bytes };
    const opaque_id = NativeId{ .scheme = "fixture-v1", .bytes = &opaque_bytes };
    const root_dependencies = [_]NativeId{ patch_id, conflict_id, opaque_id };
    const patch_dependencies = [_]NativeId{conflict_id};
    const conflict_dependencies = [_]NativeId{patch_id};
    const objects = [_]NativeObject{
        .{ .id = root_id, .kind = "repository-state", .bytes = "root\x00state\xff", .dependencies = &root_dependencies },
        .{ .id = patch_id, .kind = "commuting-patch", .bytes = "patch:b->a"[0..], .dependencies = &patch_dependencies },
        .{ .id = conflict_id, .kind = "logical-conflict", .bytes = "unresolved\x00left\x00right", .dependencies = &conflict_dependencies },
        .{ .id = opaque_id, .kind = "vendor.example/unknown", .bytes = "\x00\xffopaque\x7f" },
    };
    const roots = [_]NativeRoot{
        .{ .role = "repository", .id = root_id },
        .{ .role = "operation-log", .id = patch_id },
    };
    const refs = [_]NativeRef{
        .{ .namespace = "heads", .name = "main/with space", .target = patch_id, .mutable = true },
        .{ .namespace = "conflicts", .name = "unresolved", .target = conflict_id, .mutable = false },
    };
    const capability_parameters = [_]CapabilityParameter{
        .{ .name = "identity", .value = "stable-native" },
    };
    const capabilities = [_]Capability{
        .{ .name = "cyclic-object-relations", .support = .required },
        .{ .name = "logical-conflicts", .support = .required },
        .{ .name = "foreign-operation-import", .support = .optional, .parameters = &capability_parameters },
        .{ .name = "commit-dag", .support = .unsupported },
    };
    const authoritative_kinds = [_][]const u8{
        "repository-state",
        "commuting-patch",
        "logical-conflict",
        "vendor.example/unknown",
    };
    const exclusions = [_]ClosureExclusion{
        .{ .namespace = "machine-cache", .reason = "reconstructible and non-authoritative", .affects_semantics = false },
        .{ .namespace = "credentials", .reason = "machine-local secret material", .affects_semantics = false },
    };
    const snapshot_value = Snapshot{
        .vcs = "adversarial-fixture",
        .format_version = "1",
        .roots = &roots,
        .refs = &refs,
        .capabilities = &capabilities,
        .closure = .{
            .tier = .byte_lossless,
            .authoritative_kinds = &authoritative_kinds,
            .exclusions = &exclusions,
        },
    };

    pub fn adapter(self: *AdversarialAdapter) Adapter {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn fixtureSnapshot() Snapshot {
        return snapshot_value;
    }

    pub fn fixtureObjects() []const NativeObject {
        return &objects;
    }

    fn cast(context: *anyopaque) *AdversarialAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn snapshot(context: *anyopaque) !Snapshot {
        _ = cast(context);
        return snapshot_value;
    }

    fn enumerate(context: *anyopaque, requested_roots: []const NativeRoot, sink: ObjectSink) !void {
        _ = cast(context);
        if (!rootsEqual(requested_roots, &roots)) return error.UnknownRoot;
        for (objects) |object| try sink.emit(object);
    }

    fn restore(context: *anyopaque, supplied_snapshot: Snapshot, source: ObjectSource) !RestoreReport {
        const self = cast(context);
        if (!snapshotEqual(supplied_snapshot, snapshot_value)) return error.SnapshotMismatch;
        for (objects) |expected| {
            const actual = try source.get(expected.id) orelse return error.MissingObject;
            if (!objectEqual(actual, expected)) return error.CorruptObject;
        }
        self.restored = true;
        return .{ .roots = &roots, .verified_tier = .byte_lossless };
    }

    fn project(context: *anyopaque, supplied_snapshot: Snapshot, sink: ProjectionSink) !void {
        _ = cast(context);
        if (!snapshotEqual(supplied_snapshot, snapshot_value)) return error.SnapshotMismatch;
        try sink.emitResource(.{ .id = "state", .kind = "state", .media_type = "application/vnd.apricot.fixture-state", .payload = "root" });
        try sink.emitResource(.{ .id = "change", .kind = "change", .media_type = "application/vnd.apricot.fixture-change", .payload = "commutes" });
        try sink.emitResource(.{ .id = "README", .kind = "file", .media_type = "text/plain", .payload = "adversarial fixture\n" });
        try sink.emitRelation(.{ .kind = "contains", .source = "state", .target = "README", .ordinal = 0 });
        try sink.emitRelation(.{ .kind = "observes", .source = "state", .target = "change" });
        try sink.emitRelation(.{ .kind = "rewrites", .source = "change", .target = "state" });
        try sink.emitEntryPoint(.{ .namespace = "heads", .name = "main/with space", .resource = "state" });
    }

    fn inspectForeign(context: *anyopaque, operation: ForeignOperation) !ForeignInspection {
        _ = cast(context);
        if (std.mem.eql(u8, operation.kind, "fast-forward-tree")) {
            return .{ .importable = .{ .strategy = "snapshot-import", .affected_refs = refs[0..1] } };
        }
        if (std.mem.eql(u8, operation.kind, "conflicted-tree")) {
            return .{ .requires_resolution = .{ .reason = "native conflict identity cannot be inferred", .affected_refs = refs[0..1] } };
        }
        return .{ .refused = .{ .reason = "foreign operation has no lossless native interpretation" } };
    }

    fn importForeign(context: *anyopaque, operation: ForeignOperation, source: ObjectSource) !ForeignOutcome {
        _ = cast(context);
        _ = source;
        const inspection = try inspectForeign(context, operation);
        return switch (inspection) {
            .importable => .{ .imported = .{ .roots = &roots, .tier = .semantic_lossless } },
            .requires_resolution => |resolution| .{ .requires_resolution = .{ .reason = resolution.reason } },
            .refused => |refusal| .{ .refused = .{ .reason = refusal.reason } },
        };
    }

    const vtable = Adapter.VTable{
        .snapshot = snapshot,
        .enumerate = enumerate,
        .restore = restore,
        .project = project,
        .inspectForeign = inspectForeign,
        .importForeign = importForeign,
    };
};

fn idsEqual(a: []const NativeId, b: []const NativeId) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!left.eql(right)) return false;
    return true;
}

fn rootsEqual(a: []const NativeRoot, b: []const NativeRoot) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.role, right.role) or !left.id.eql(right.id)) return false;
    }
    return true;
}

fn refsEqual(a: []const NativeRef, b: []const NativeRef) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.namespace, right.namespace) or
            !std.mem.eql(u8, left.name, right.name) or
            !left.target.eql(right.target) or
            left.mutable != right.mutable) return false;
    }
    return true;
}

fn stringSlicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn capabilityParametersEqual(a: []const CapabilityParameter, b: []const CapabilityParameter) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, left.value, right.value)) return false;
    }
    return true;
}

fn capabilitiesEqual(a: []const Capability, b: []const Capability) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or
            left.support != right.support or
            !capabilityParametersEqual(left.parameters, right.parameters)) return false;
    }
    return true;
}

fn exclusionsEqual(a: []const ClosureExclusion, b: []const ClosureExclusion) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.namespace, right.namespace) or
            !std.mem.eql(u8, left.reason, right.reason) or
            left.affects_semantics != right.affects_semantics) return false;
    }
    return true;
}

fn snapshotEqual(a: Snapshot, b: Snapshot) bool {
    return std.mem.eql(u8, a.vcs, b.vcs) and
        std.mem.eql(u8, a.format_version, b.format_version) and
        rootsEqual(a.roots, b.roots) and
        refsEqual(a.refs, b.refs) and
        capabilitiesEqual(a.capabilities, b.capabilities) and
        a.closure.tier == b.closure.tier and
        stringSlicesEqual(a.closure.authoritative_kinds, b.closure.authoritative_kinds) and
        exclusionsEqual(a.closure.exclusions, b.closure.exclusions);
}

fn objectEqual(a: NativeObject, b: NativeObject) bool {
    return a.id.eql(b.id) and
        std.mem.eql(u8, a.kind, b.kind) and
        std.mem.eql(u8, a.bytes, b.bytes) and
        idsEqual(a.dependencies, b.dependencies);
}

test "adversarial adapter snapshots enumerates and restores byte-losslessly" {
    const Collector = struct {
        items: [8]NativeObject = undefined,
        len: usize = 0,

        fn emit(context: *anyopaque, object: NativeObject) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.items[self.len] = object;
            self.len += 1;
        }

        fn get(context: *anyopaque, id: NativeId) !?NativeObject {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (self.items[0..self.len]) |object| if (object.id.eql(id)) return object;
            return null;
        }
    };

    var implementation = AdversarialAdapter{};
    const contract = implementation.adapter();
    const captured = try contract.snapshot();
    try std.testing.expectEqual(PreservationTier.byte_lossless, captured.closure.tier);
    try std.testing.expectEqual(@as(usize, 2), captured.roots.len);
    try std.testing.expectEqual(@as(usize, 4), captured.capabilities.len);

    var collector = Collector{};
    try contract.enumerate(captured.roots, .{ .context = &collector, .emitFn = Collector.emit });
    try std.testing.expectEqual(@as(usize, 4), collector.len);
    try std.testing.expect(idsEqual(collector.items[1].dependencies, &.{AdversarialAdapter.conflict_id}));

    const report = try contract.restore(captured, .{ .context = &collector, .getFn = Collector.get });
    try std.testing.expect(implementation.restored);
    try std.testing.expectEqual(PreservationTier.byte_lossless, report.verified_tier);
    try std.testing.expect(rootsEqual(captured.roots, report.roots));
}

test "projection IR preserves arbitrary cyclic relationships" {
    const Collector = struct {
        resources: usize = 0,
        relations: [8]ProjectionRelation = undefined,
        relations_len: usize = 0,
        entries: usize = 0,

        fn resource(context: *anyopaque, value: ProjectionResource) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = value;
            self.resources += 1;
        }

        fn relation(context: *anyopaque, value: ProjectionRelation) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.relations[self.relations_len] = value;
            self.relations_len += 1;
        }

        fn entry(context: *anyopaque, value: ProjectionEntryPoint) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = value;
            self.entries += 1;
        }
    };

    var implementation = AdversarialAdapter{};
    const contract = implementation.adapter();
    var collector = Collector{};
    try contract.project(try contract.snapshot(), .{
        .context = &collector,
        .emitResourceFn = Collector.resource,
        .emitRelationFn = Collector.relation,
        .emitEntryPointFn = Collector.entry,
    });
    try std.testing.expectEqual(@as(usize, 3), collector.resources);
    try std.testing.expectEqual(@as(usize, 3), collector.relations_len);
    try std.testing.expectEqual(@as(usize, 1), collector.entries);
    try std.testing.expect(std.mem.eql(u8, collector.relations[1].source, collector.relations[2].target));
    try std.testing.expect(std.mem.eql(u8, collector.relations[1].target, collector.relations[2].source));
}

test "foreign operations import resolve or refuse explicitly" {
    const EmptySource = struct {
        fn get(context: *anyopaque, id: NativeId) !?NativeObject {
            _ = context;
            _ = id;
            return null;
        }
    };

    var implementation = AdversarialAdapter{};
    const contract = implementation.adapter();
    var empty: u8 = 0;
    const source = ObjectSource{ .context = &empty, .getFn = EmptySource.get };
    const base = ForeignOperation{
        .kind = "fast-forward-tree",
        .base_projection = "projection-a",
        .observed_projection = "projection-b",
        .evidence_media_type = "application/octet-stream",
        .evidence = "evidence",
    };

    try std.testing.expect((try contract.inspectForeign(base)) == .importable);
    const imported = try contract.importForeign(base, source);
    try std.testing.expect(imported == .imported);
    try std.testing.expectEqual(PreservationTier.semantic_lossless, imported.imported.tier);

    var conflicted = base;
    conflicted.kind = "conflicted-tree";
    try std.testing.expect((try contract.inspectForeign(conflicted)) == .requires_resolution);
    try std.testing.expect((try contract.importForeign(conflicted, source)) == .requires_resolution);

    var unknown = base;
    unknown.kind = "native-identity-rewrite";
    try std.testing.expect((try contract.inspectForeign(unknown)) == .refused);
    try std.testing.expect((try contract.importForeign(unknown, source)) == .refused);
}

test "conformance validation rejects ambiguous or lossy declarations" {
    const valid = AdversarialAdapter.fixtureSnapshot();
    try validateSnapshot(valid);
    for (AdversarialAdapter.fixtureObjects()) |object| try validateNativeObject(object);
    try std.testing.expect(PreservationTier.byte_lossless.satisfies(.semantic_lossless));
    try std.testing.expect(!PreservationTier.semantic_lossless.satisfies(.byte_lossless));

    var no_roots = valid;
    no_roots.roots = &.{};
    try std.testing.expectError(error.MissingRoot, validateSnapshot(no_roots));

    const semantic_exclusion = [_]ClosureExclusion{
        .{ .namespace = "operation-log", .reason = "not exported", .affects_semantics = true },
    };
    var lossy = valid;
    lossy.closure.exclusions = &semantic_exclusion;
    try std.testing.expectError(error.LosslessExclusionAffectsSemantics, validateSnapshot(lossy));
}
