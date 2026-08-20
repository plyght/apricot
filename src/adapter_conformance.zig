const std = @import("std");
const contract = @import("adapter.zig");

pub const Status = enum {
    passed,
    failed,
    skipped,
};

pub const Check = struct {
    name: []const u8,
    status: Status,
    code: []const u8,
};

pub const Limits = struct {
    max_objects: usize = 100_000,
    max_object_bytes: usize = 64 * 1024 * 1024,
    max_total_object_bytes: usize = 1024 * 1024 * 1024,
    max_projection_records: usize = 1_000_000,
    max_projection_bytes: usize = 1024 * 1024 * 1024,

    pub fn validate(self: Limits) !void {
        if (self.max_objects == 0 or self.max_object_bytes == 0 or self.max_total_object_bytes == 0) return error.InvalidLimits;
        if (self.max_projection_records == 0 or self.max_projection_bytes == 0) return error.InvalidLimits;
        if (self.max_object_bytes > self.max_total_object_bytes) return error.InvalidLimits;
    }
};

pub const SemanticVerifier = struct {
    context: *anyopaque,
    verifyFn: *const fn (context: *anyopaque, original: contract.Snapshot, restored: contract.Snapshot) anyerror!void,

    pub fn verify(self: SemanticVerifier, original: contract.Snapshot, restored: contract.Snapshot) !void {
        return self.verifyFn(self.context, original, restored);
    }
};

pub const ObjectVerifier = struct {
    context: *anyopaque,
    verifyFn: *const fn (context: *anyopaque, object: contract.NativeObject) anyerror!void,

    pub fn verify(self: ObjectVerifier, object: contract.NativeObject) !void {
        return self.verifyFn(self.context, object);
    }
};

pub const Config = struct {
    adapter: contract.Adapter,
    restored_adapter: ?contract.Adapter = null,
    forbidden_payloads: []const []const u8 = &.{},
    foreign_operations: []const contract.ForeignOperation = &default_foreign_operations,
    semantic_verifier: ?SemanticVerifier = null,
    object_verifier: ?ObjectVerifier = null,
    limits: Limits = .{},
};

pub const Result = struct {
    schema: u16 = 1,
    checks: []Check,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.checks);
        self.* = undefined;
    }

    pub fn passed(self: Result) bool {
        for (self.checks) |check| if (check.status == .failed) return false;
        return true;
    }

    pub fn encodeJson(self: Result, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, "{\"schema\":1,\"passed\":");
        try output.appendSlice(allocator, if (self.passed()) "true" else "false");
        try output.appendSlice(allocator, ",\"checks\":[");
        for (self.checks, 0..) |check, index| {
            if (index != 0) try output.append(allocator, ',');
            try output.appendSlice(allocator, "{\"name\":");
            try appendJsonString(&output, allocator, check.name);
            try output.appendSlice(allocator, ",\"status\":\"");
            try output.appendSlice(allocator, @tagName(check.status));
            try output.appendSlice(allocator, "\",\"code\":");
            try appendJsonString(&output, allocator, check.code);
            try output.append(allocator, '}');
        }
        try output.appendSlice(allocator, "]}");
        return output.toOwnedSlice(allocator);
    }
};

const default_foreign_operations = [_]contract.ForeignOperation{
    .{ .kind = "fast-forward-tree", .base_projection = "base", .observed_projection = "next", .evidence_media_type = "application/vnd.apricot.fixture", .evidence = "importable" },
    .{ .kind = "conflicted-tree", .base_projection = "base", .observed_projection = "conflict", .evidence_media_type = "application/vnd.apricot.fixture", .evidence = "resolution" },
    .{ .kind = "unknown-operation", .base_projection = "base", .observed_projection = "unknown", .evidence_media_type = "application/vnd.apricot.fixture", .evidence = "refusal" },
};

const OwnedObject = struct {
    scheme: []u8,
    id_bytes: []u8,
    kind: []u8,
    bytes: []u8,
    dependency_schemes: [][]u8,
    dependency_bytes: [][]u8,
    dependencies: []contract.NativeId,

    fn deinit(self: OwnedObject, allocator: std.mem.Allocator) void {
        for (self.dependency_schemes) |value| allocator.free(value);
        for (self.dependency_bytes) |value| allocator.free(value);
        allocator.free(self.dependency_schemes);
        allocator.free(self.dependency_bytes);
        allocator.free(self.dependencies);
        allocator.free(self.scheme);
        allocator.free(self.id_bytes);
        allocator.free(self.kind);
        allocator.free(self.bytes);
    }

    fn view(self: OwnedObject) contract.NativeObject {
        return .{
            .id = .{ .scheme = self.scheme, .bytes = self.id_bytes },
            .kind = self.kind,
            .bytes = self.bytes,
            .dependencies = self.dependencies,
        };
    }
};

const ObjectCapture = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    objects: std.ArrayList(OwnedObject) = .empty,
    total_bytes: usize = 0,

    fn deinit(self: *ObjectCapture) void {
        for (self.objects.items) |object| object.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    fn sink(self: *ObjectCapture) contract.ObjectSink {
        return .{ .context = self, .emitFn = emit };
    }

    fn emit(context: *anyopaque, object: contract.NativeObject) !void {
        const self: *ObjectCapture = @ptrCast(@alignCast(context));
        try contract.validateNativeObject(object);
        if (self.objects.items.len >= self.limits.max_objects) return error.ObjectLimitExceeded;
        if (object.bytes.len > self.limits.max_object_bytes) return error.ObjectSizeLimitExceeded;
        self.total_bytes = std.math.add(usize, self.total_bytes, object.bytes.len) catch return error.TotalObjectBytesLimitExceeded;
        if (self.total_bytes > self.limits.max_total_object_bytes) return error.TotalObjectBytesLimitExceeded;
        for (self.objects.items) |existing| if (existing.view().id.eql(object.id)) return error.DuplicateObject;
        const owned = try cloneObject(self.allocator, object);
        errdefer owned.deinit(self.allocator);
        try self.objects.append(self.allocator, owned);
    }

    fn find(self: *ObjectCapture, id: contract.NativeId) ?OwnedObject {
        for (self.objects.items) |object| if (object.view().id.eql(id)) return object;
        return null;
    }
};

fn cloneObject(allocator: std.mem.Allocator, object: contract.NativeObject) !OwnedObject {
    const scheme = try allocator.dupe(u8, object.id.scheme);
    errdefer allocator.free(scheme);
    const id_bytes = try allocator.dupe(u8, object.id.bytes);
    errdefer allocator.free(id_bytes);
    const kind = try allocator.dupe(u8, object.kind);
    errdefer allocator.free(kind);
    const bytes = try allocator.dupe(u8, object.bytes);
    errdefer allocator.free(bytes);
    const dependency_schemes = try allocator.alloc([]u8, object.dependencies.len);
    errdefer allocator.free(dependency_schemes);
    const dependency_bytes = try allocator.alloc([]u8, object.dependencies.len);
    errdefer allocator.free(dependency_bytes);
    const dependencies = try allocator.alloc(contract.NativeId, object.dependencies.len);
    errdefer allocator.free(dependencies);
    var initialized: usize = 0;
    errdefer {
        for (dependency_schemes[0..initialized]) |value| allocator.free(value);
        for (dependency_bytes[0..initialized]) |value| allocator.free(value);
    }
    for (object.dependencies, 0..) |dependency, index| {
        const owned_dependency = try cloneDependency(allocator, dependency);
        dependency_schemes[index] = owned_dependency.scheme;
        dependency_bytes[index] = owned_dependency.bytes;
        dependencies[index] = .{ .scheme = dependency_schemes[index], .bytes = dependency_bytes[index] };
        initialized += 1;
    }
    return .{
        .scheme = scheme,
        .id_bytes = id_bytes,
        .kind = kind,
        .bytes = bytes,
        .dependency_schemes = dependency_schemes,
        .dependency_bytes = dependency_bytes,
        .dependencies = dependencies,
    };
}

const OwnedDependency = struct {
    scheme: []u8,
    bytes: []u8,
};

fn cloneDependency(allocator: std.mem.Allocator, dependency: contract.NativeId) !OwnedDependency {
    const scheme = try allocator.dupe(u8, dependency.scheme);
    errdefer allocator.free(scheme);
    return .{ .scheme = scheme, .bytes = try allocator.dupe(u8, dependency.bytes) };
}

const SourceMode = enum { exact, missing_first, tampered_first };
const SourceState = struct {
    capture: *ObjectCapture,
    mode: SourceMode,

    fn source(self: *SourceState) contract.ObjectSource {
        return .{ .context = self, .getFn = get };
    }
};

fn get(context: *anyopaque, id: contract.NativeId) !?contract.NativeObject {
    const state: *SourceState = @ptrCast(@alignCast(context));
    const object = state.capture.find(id) orelse return null;
    if (state.capture.objects.items.len != 0 and object.view().id.eql(state.capture.objects.items[0].view().id)) {
        if (state.mode == .missing_first) return null;
        if (state.mode == .tampered_first) {
            var result = object.view();
            result.bytes = "tampered";
            return result;
        }
    }
    return object.view();
}

const ProjectionCapture = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    records: std.ArrayList([]u8) = .empty,
    total_bytes: usize = 0,

    fn deinit(self: *ProjectionCapture) void {
        for (self.records.items) |record| self.allocator.free(record);
        self.records.deinit(self.allocator);
    }

    fn sink(self: *ProjectionCapture) contract.ProjectionSink {
        return .{ .context = self, .emitResourceFn = resource, .emitRelationFn = relation, .emitEntryPointFn = entry };
    }

    fn add(self: *ProjectionCapture, fields: []const []const u8) !void {
        if (self.records.items.len >= self.limits.max_projection_records) return error.ProjectionRecordLimitExceeded;
        var size: usize = 1;
        for (fields) |field| size = std.math.add(usize, size, 8 + field.len) catch return error.ProjectionBytesLimitExceeded;
        self.total_bytes = std.math.add(usize, self.total_bytes, size) catch return error.ProjectionBytesLimitExceeded;
        if (self.total_bytes > self.limits.max_projection_bytes) return error.ProjectionBytesLimitExceeded;
        var record = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(record);
        record[0] = @intCast(fields.len);
        var offset: usize = 1;
        for (fields) |field| {
            std.mem.writeInt(u64, record[offset..][0..8], field.len, .big);
            offset += 8;
            @memcpy(record[offset..][0..field.len], field);
            offset += field.len;
        }
        try self.records.append(self.allocator, record);
    }

    fn resource(context: *anyopaque, value: contract.ProjectionResource) !void {
        const self: *ProjectionCapture = @ptrCast(@alignCast(context));
        try contract.validateProjectionResource(value);
        const executable = [_]u8{@intFromBool(value.executable)};
        try self.add(&.{ "resource", value.id, value.kind, value.media_type, value.payload, &executable });
    }

    fn relation(context: *anyopaque, value: contract.ProjectionRelation) !void {
        const self: *ProjectionCapture = @ptrCast(@alignCast(context));
        try contract.validateProjectionRelation(value);
        var ordinal: [8]u8 = undefined;
        std.mem.writeInt(u64, &ordinal, value.ordinal orelse std.math.maxInt(u64), .big);
        try self.add(&.{ "relation", value.kind, value.source, value.target, &ordinal });
    }

    fn entry(context: *anyopaque, value: contract.ProjectionEntryPoint) !void {
        const self: *ProjectionCapture = @ptrCast(@alignCast(context));
        if (value.namespace.len == 0 or value.name.len == 0 or value.resource.len == 0) return error.InvalidProjectionEntryPoint;
        try self.add(&.{ "entry", value.namespace, value.name, value.resource });
    }
};

pub fn run(allocator: std.mem.Allocator, config: Config) !Result {
    try config.limits.validate();
    var checks: std.ArrayList(Check) = .empty;
    errdefer checks.deinit(allocator);

    const first_snapshot = config.adapter.snapshot() catch |err| {
        try add(&checks, allocator, "snapshot_determinism", .failed, @errorName(err));
        try addRemainingSkipped(&checks, allocator, "snapshot unavailable");
        return .{ .checks = try checks.toOwnedSlice(allocator), .allocator = allocator };
    };
    const first_digest = digestSnapshot(first_snapshot);
    var first_objects = ObjectCapture{ .allocator = allocator, .limits = config.limits };
    defer first_objects.deinit();
    const first_enumerated = if (config.adapter.enumerate(first_snapshot.roots, first_objects.sink())) |_| true else |_| false;
    const second_snapshot = config.adapter.snapshot() catch |err| {
        try add(&checks, allocator, "snapshot_determinism", .failed, @errorName(err));
        try addRemainingSkipped(&checks, allocator, "snapshot unavailable");
        return .{ .checks = try checks.toOwnedSlice(allocator), .allocator = allocator };
    };
    const second_digest = digestSnapshot(second_snapshot);

    var objects = ObjectCapture{ .allocator = allocator, .limits = config.limits };
    defer objects.deinit();
    var enumeration_error: ?anyerror = null;
    config.adapter.enumerate(second_snapshot.roots, objects.sink()) catch |err| {
        enumeration_error = err;
    };
    const second_enumerated = enumeration_error == null;
    const deterministic = first_enumerated and second_enumerated and std.mem.eql(u8, &first_digest, &second_digest) and capturesEqual(&first_objects, &objects);
    try add(&checks, allocator, "snapshot_determinism", if (deterministic) .passed else .failed, if (deterministic) "ok" else "snapshot_or_objects_changed");

    if (second_enumerated) {
        var closure_error: ?anyerror = null;
        validateClosure(second_snapshot, &objects, config.object_verifier) catch |err| {
            closure_error = err;
        };
        if (closure_error) |err| {
            try add(&checks, allocator, "declared_closure", .failed, @errorName(err));
            try add(&checks, allocator, "object_completeness_integrity", .failed, @errorName(err));
        } else {
            try add(&checks, allocator, "declared_closure", .passed, "ok");
            try add(&checks, allocator, "object_completeness_integrity", .passed, "ok");
        }
    } else {
        try add(&checks, allocator, "declared_closure", .failed, @errorName(enumeration_error.?));
        try add(&checks, allocator, "object_completeness_integrity", .failed, @errorName(enumeration_error.?));
    }

    try secretCheck(&checks, allocator, &objects, null, config.forbidden_payloads, "ignored_untracked_secret_exclusion");

    const malformed_refused = restoreRefused(config.adapter, second_snapshot, &objects, .missing_first);
    const tampered_refused = restoreRefused(config.adapter, second_snapshot, &objects, .tampered_first);
    try add(&checks, allocator, "malformed_tampered_carrier_refusal", if (malformed_refused and tampered_refused) .passed else .failed, if (malformed_refused and tampered_refused) "ok" else "restore_accepted_invalid_source");

    var exact_state = SourceState{ .capture = &objects, .mode = .exact };
    const restored_report = config.adapter.restore(second_snapshot, exact_state.source()) catch |err| {
        try add(&checks, allocator, "exact_restore_recapture", .failed, @errorName(err));
        try add(&checks, allocator, "semantic_verification", .skipped, "restore_failed");
        try projectionChecks(&checks, allocator, config, second_snapshot, &objects);
        try foreignCheck(&checks, allocator, config, &objects);
        try addBoundedResources(&checks, allocator);
        return .{ .checks = try checks.toOwnedSlice(allocator), .allocator = allocator };
    };
    if (!restored_report.verified_tier.satisfies(second_snapshot.closure.tier)) {
        try add(&checks, allocator, "exact_restore_recapture", .failed, "preservation_tier_weakened");
    } else if (config.restored_adapter) |restored_adapter| {
        const restored_snapshot = restored_adapter.snapshot() catch |err| {
            try add(&checks, allocator, "exact_restore_recapture", .failed, @errorName(err));
            try add(&checks, allocator, "semantic_verification", .skipped, "recapture_failed");
            try projectionChecks(&checks, allocator, config, second_snapshot, &objects);
            try foreignCheck(&checks, allocator, config, &objects);
            try addBoundedResources(&checks, allocator);
            return .{ .checks = try checks.toOwnedSlice(allocator), .allocator = allocator };
        };
        var restored_objects = ObjectCapture{ .allocator = allocator, .limits = config.limits };
        defer restored_objects.deinit();
        var recapture_error: ?anyerror = null;
        restored_adapter.enumerate(restored_snapshot.roots, restored_objects.sink()) catch |err| {
            recapture_error = err;
        };
        if (recapture_error) |err| {
            try add(&checks, allocator, "exact_restore_recapture", .failed, @errorName(err));
        } else {
            const original_digest = digestSnapshot(second_snapshot);
            const restored_digest = digestSnapshot(restored_snapshot);
            const exact = std.mem.eql(u8, &original_digest, &restored_digest) and capturesEqual(&objects, &restored_objects);
            try add(&checks, allocator, "exact_restore_recapture", if (exact) .passed else .failed, if (exact) "ok" else "recapture_mismatch");
        }
        if (config.semantic_verifier) |verifier| {
            if (verifier.verify(second_snapshot, restored_snapshot)) |_| try add(&checks, allocator, "semantic_verification", .passed, "ok") else |err| try add(&checks, allocator, "semantic_verification", .failed, @errorName(err));
        } else try add(&checks, allocator, "semantic_verification", .skipped, "not_configured");
    } else {
        try add(&checks, allocator, "exact_restore_recapture", .skipped, "restored_adapter_not_configured");
        try add(&checks, allocator, "semantic_verification", .skipped, "not_configured");
    }

    try projectionChecks(&checks, allocator, config, second_snapshot, &objects);
    try foreignCheck(&checks, allocator, config, &objects);
    try addBoundedResources(&checks, allocator);
    return .{ .checks = try checks.toOwnedSlice(allocator), .allocator = allocator };
}

fn projectionChecks(checks: *std.ArrayList(Check), allocator: std.mem.Allocator, config: Config, snapshot: contract.Snapshot, objects: *ObjectCapture) !void {
    var first = ProjectionCapture{ .allocator = allocator, .limits = config.limits };
    defer first.deinit();
    var second = ProjectionCapture{ .allocator = allocator, .limits = config.limits };
    defer second.deinit();
    config.adapter.project(snapshot, first.sink()) catch |err| {
        try add(checks, allocator, "projection_determinism_separation", .failed, @errorName(err));
        return;
    };
    config.adapter.project(snapshot, second.sink()) catch |err| {
        try add(checks, allocator, "projection_determinism_separation", .failed, @errorName(err));
        return;
    };
    const first_digest = projectionDigest(&first);
    const second_digest = projectionDigest(&second);
    const native_digest = objectDigest(objects);
    const deterministic = std.mem.eql(u8, &first_digest, &second_digest);
    const separate = !std.mem.eql(u8, &native_digest, &first_digest);
    try add(checks, allocator, "projection_determinism_separation", if (deterministic and separate) .passed else .failed, if (!deterministic) "projection_changed" else if (!separate) "projection_equals_native_capture" else "ok");
    try secretCheck(checks, allocator, objects, &first, config.forbidden_payloads, "projection_secret_exclusion");
}

fn foreignCheck(checks: *std.ArrayList(Check), allocator: std.mem.Allocator, config: Config, objects: *ObjectCapture) !void {
    for (config.foreign_operations) |operation| {
        const inspection = config.adapter.inspectForeign(operation) catch |err| {
            try add(checks, allocator, "foreign_operation_honesty", .failed, @errorName(err));
            return;
        };
        var source_state = SourceState{ .capture = objects, .mode = .exact };
        const outcome = config.adapter.importForeign(operation, source_state.source()) catch |err| {
            try add(checks, allocator, "foreign_operation_honesty", .failed, @errorName(err));
            return;
        };
        const honest = switch (inspection) {
            .importable => |value| value.strategy.len != 0 and switch (outcome) {
                .imported => true,
                else => false,
            },
            .requires_resolution => |value| value.reason.len != 0 and switch (outcome) {
                .requires_resolution => |result| result.reason.len != 0,
                else => false,
            },
            .refused => |value| value.reason.len != 0 and switch (outcome) {
                .refused => |result| result.reason.len != 0,
                else => false,
            },
        };
        if (!honest) {
            try add(checks, allocator, "foreign_operation_honesty", .failed, "inspection_outcome_mismatch");
            return;
        }
    }
    try add(checks, allocator, "foreign_operation_honesty", .passed, "ok");
}

fn validateClosure(snapshot: contract.Snapshot, objects: *ObjectCapture, verifier: ?ObjectVerifier) !void {
    if (objects.objects.items.len == 0) return error.EmptyObjectClosure;
    for (objects.objects.items) |object| {
        var declared = false;
        for (snapshot.closure.authoritative_kinds) |kind| if (std.mem.eql(u8, kind, object.kind)) {
            declared = true;
            break;
        };
        if (!declared) return error.UndeclaredObjectKind;
        if (verifier) |value| try value.verify(object.view());
        for (object.dependency_schemes, object.dependency_bytes) |scheme, bytes| if (objects.find(.{ .scheme = scheme, .bytes = bytes }) == null) return error.MissingDependency;
    }
    for (snapshot.roots) |root| if (objects.find(root.id) == null) return error.MissingRootObject;
    for (snapshot.refs) |native_ref| if (objects.find(native_ref.target) == null) return error.MissingRefObject;
}

fn restoreRefused(adapter: contract.Adapter, snapshot: contract.Snapshot, objects: *ObjectCapture, mode: SourceMode) bool {
    var source_state = SourceState{ .capture = objects, .mode = mode };
    _ = adapter.restore(snapshot, source_state.source()) catch return true;
    return false;
}

fn secretCheck(checks: *std.ArrayList(Check), allocator: std.mem.Allocator, objects: *ObjectCapture, projection: ?*ProjectionCapture, forbidden: []const []const u8, name: []const u8) !void {
    for (forbidden) |needle| {
        if (needle.len == 0) continue;
        for (objects.objects.items) |object| if (std.mem.indexOf(u8, object.bytes, needle) != null) {
            try add(checks, allocator, name, .failed, "forbidden_payload_in_native_capture");
            return;
        };
        if (projection) |value| for (value.records.items) |record| if (std.mem.indexOf(u8, record, needle) != null) {
            try add(checks, allocator, name, .failed, "forbidden_payload_in_projection");
            return;
        };
    }
    try add(checks, allocator, name, .passed, "ok");
}

fn digestSnapshot(snapshot: contract.Snapshot) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, snapshot.vcs);
    hashField(&hash, snapshot.format_version);
    hashField(&hash, @tagName(snapshot.closure.tier));
    for (snapshot.roots) |root| {
        hashField(&hash, root.role);
        hashId(&hash, root.id);
    }
    for (snapshot.refs) |native_ref| {
        hashField(&hash, native_ref.namespace);
        hashField(&hash, native_ref.name);
        hashId(&hash, native_ref.target);
        hash.update(&.{@intFromBool(native_ref.mutable)});
    }
    for (snapshot.capabilities) |capability| {
        hashField(&hash, capability.name);
        hashField(&hash, @tagName(capability.support));
        for (capability.parameters) |parameter| {
            hashField(&hash, parameter.name);
            hashField(&hash, parameter.value);
        }
    }
    for (snapshot.closure.authoritative_kinds) |kind| hashField(&hash, kind);
    for (snapshot.closure.exclusions) |exclusion| {
        hashField(&hash, exclusion.namespace);
        hashField(&hash, exclusion.reason);
        hash.update(&.{@intFromBool(exclusion.affects_semantics)});
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn objectDigest(capture: *ObjectCapture) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (capture.objects.items) |object| {
        hashId(&hash, object.view().id);
        hashField(&hash, object.kind);
        hashField(&hash, object.bytes);
        for (object.dependency_schemes, object.dependency_bytes) |scheme, bytes| hashId(&hash, .{ .scheme = scheme, .bytes = bytes });
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn projectionDigest(capture: *ProjectionCapture) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (capture.records.items) |record| hashField(&hash, record);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn capturesEqual(left: *ObjectCapture, right: *ObjectCapture) bool {
    const left_digest = objectDigest(left);
    const right_digest = objectDigest(right);
    return std.mem.eql(u8, &left_digest, &right_digest);
}

fn hashId(hash: *std.crypto.hash.sha2.Sha256, id: contract.NativeId) void {
    hashField(hash, id.scheme);
    hashField(hash, id.bytes);
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}

fn add(checks: *std.ArrayList(Check), allocator: std.mem.Allocator, name: []const u8, status: Status, code: []const u8) !void {
    try checks.append(allocator, .{ .name = name, .status = status, .code = code });
}

fn addBoundedResources(checks: *std.ArrayList(Check), allocator: std.mem.Allocator) !void {
    for (checks.items) |check| {
        if (std.mem.endsWith(u8, check.code, "LimitExceeded")) {
            try add(checks, allocator, "bounded_resources", .failed, check.code);
            return;
        }
    }
    try add(checks, allocator, "bounded_resources", .passed, "ok");
}

fn addRemainingSkipped(checks: *std.ArrayList(Check), allocator: std.mem.Allocator, code: []const u8) !void {
    const names = [_][]const u8{
        "declared_closure",
        "object_completeness_integrity",
        "ignored_untracked_secret_exclusion",
        "malformed_tampered_carrier_refusal",
        "exact_restore_recapture",
        "semantic_verification",
        "projection_determinism_separation",
        "projection_secret_exclusion",
        "foreign_operation_honesty",
        "bounded_resources",
    };
    for (names) |name| try add(checks, allocator, name, .skipped, code);
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        0...0x1f => {
            const escaped = try std.fmt.allocPrint(allocator, "\\u00{x:0>2}", .{byte});
            defer allocator.free(escaped);
            try output.appendSlice(allocator, escaped);
        },
        else => try output.append(allocator, byte),
    };
    try output.append(allocator, '"');
}

test "adversarial adapter passes deterministic conformance checks" {
    var fixture = contract.AdversarialAdapter{};
    var restored = contract.AdversarialAdapter{};
    var result = try run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .restored_adapter = restored.adapter(),
        .forbidden_payloads = &.{"private-key-material"},
    });
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expectEqual(@as(usize, 11), result.checks.len);
    const json = try result.encodeJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"schema\":1,\"passed\":true,\"checks\":[{\"name\":\"snapshot_determinism\",\"status\":\"passed\",\"code\":\"ok\"}"));
}

test "secret needles fail closed" {
    var fixture = contract.AdversarialAdapter{};
    var result = try run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .forbidden_payloads = &.{"opaque"},
        .foreign_operations = &.{},
    });
    defer result.deinit();
    try std.testing.expect(!result.passed());
    try std.testing.expectEqualStrings("forbidden_payload_in_native_capture", result.checks[3].code);
}

test "invalid limits are rejected" {
    var fixture = contract.AdversarialAdapter{};
    try std.testing.expectError(error.InvalidLimits, run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .limits = .{ .max_objects = 0 },
    }));
}

test "resource bounds fail deterministically" {
    var fixture = contract.AdversarialAdapter{};
    var result = try run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .limits = .{ .max_objects = 1 },
        .foreign_operations = &.{},
    });
    defer result.deinit();
    try std.testing.expect(!result.passed());
    try std.testing.expectEqual(Status.failed, result.checks[result.checks.len - 1].status);
    try std.testing.expectEqualStrings("ObjectLimitExceeded", result.checks[result.checks.len - 1].code);
}

test "projection-only secret leakage is detected" {
    var fixture = contract.AdversarialAdapter{};
    var result = try run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .forbidden_payloads = &.{"adversarial fixture"},
        .foreign_operations = &.{},
    });
    defer result.deinit();
    try std.testing.expect(!result.passed());
    try std.testing.expectEqualStrings("projection_secret_exclusion", result.checks[8].name);
    try std.testing.expectEqualStrings("forbidden_payload_in_projection", result.checks[8].code);
}

const SemanticFixture = struct {
    called: bool = false,

    fn verifier(self: *SemanticFixture) SemanticVerifier {
        return .{ .context = self, .verifyFn = verify };
    }

    fn verify(context: *anyopaque, original: contract.Snapshot, restored: contract.Snapshot) !void {
        const self: *SemanticFixture = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, original.vcs, restored.vcs)) return error.SemanticMismatch;
        self.called = true;
    }
};

test "semantic verifier runs after exact recapture" {
    var fixture = contract.AdversarialAdapter{};
    var restored = contract.AdversarialAdapter{};
    var semantic = SemanticFixture{};
    var result = try run(std.testing.allocator, .{
        .adapter = fixture.adapter(),
        .restored_adapter = restored.adapter(),
        .semantic_verifier = semantic.verifier(),
    });
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expect(semantic.called);
    try std.testing.expectEqual(Status.passed, result.checks[6].status);
}

test "machine result encoding is deterministic" {
    var first_fixture = contract.AdversarialAdapter{};
    var first_result = try run(std.testing.allocator, .{ .adapter = first_fixture.adapter(), .foreign_operations = &.{} });
    defer first_result.deinit();
    const first_json = try first_result.encodeJson(std.testing.allocator);
    defer std.testing.allocator.free(first_json);
    var second_fixture = contract.AdversarialAdapter{};
    var second_result = try run(std.testing.allocator, .{ .adapter = second_fixture.adapter(), .foreign_operations = &.{} });
    defer second_result.deinit();
    const second_json = try second_result.encodeJson(std.testing.allocator);
    defer std.testing.allocator.free(second_json);
    try std.testing.expectEqualStrings(first_json, second_json);
}
