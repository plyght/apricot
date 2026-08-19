const std = @import("std");

pub const HashAlgorithm = enum {
    blake3_256,
    sha2_256,
    sha2_512,
};

pub const ObjectId = struct {
    algorithm: HashAlgorithm,
    digest: [64]u8,
    digest_len: u8,

    pub fn isValid(self: ObjectId) bool {
        return switch (self.algorithm) {
            .blake3_256, .sha2_256 => self.digest_len == 32,
            .sha2_512 => self.digest_len == 64,
        };
    }

    pub fn eql(a: ObjectId, b: ObjectId) bool {
        return a.algorithm == b.algorithm and
            a.digest_len == b.digest_len and
            std.mem.eql(u8, a.digest[0..a.digest_len], b.digest[0..b.digest_len]);
    }
};

pub const Object = struct {
    id: ObjectId,
    bytes: []const u8,
};

pub const RefScope = enum {
    native,
    projection,
    transaction,
    metadata,
};

pub const RefId = struct {
    scope: RefScope,
    name: []const u8,

    pub fn isValid(self: RefId) bool {
        if (self.name.len == 0 or self.name.len > InMemoryForgeEdge.max_ref_name_bytes) return false;
        for (self.name) |byte| {
            if (byte == 0) return false;
        }
        return true;
    }

    pub fn eql(a: RefId, b: RefId) bool {
        return a.scope == b.scope and std.mem.eql(u8, a.name, b.name);
    }
};

pub const RefUpdate = struct {
    ref: RefId,
    expected: ?ObjectId,
    desired: ?ObjectId,
};

pub const UpdatePolicy = enum {
    require_atomic,
    prefer_atomic,
    allow_sequential,
};

pub const UpdateMode = enum {
    atomic,
    sequential,
};

pub const UpdateResult = struct {
    mode: UpdateMode,
    updated: usize,
};

pub const ProtocolCapabilities = struct {
    compare_and_swap_refs: bool,
    atomic_ref_updates: bool,
    ref_deletion: bool,
    max_object_bytes: ?u64,
    max_updates_per_transaction: ?u32,
    hash_algorithms: []const HashAlgorithm,

    pub fn supportsHash(self: ProtocolCapabilities, algorithm: HashAlgorithm) bool {
        for (self.hash_algorithms) |candidate| {
            if (candidate == algorithm) return true;
        }
        return false;
    }
};

pub const TransactionId = [16]u8;

pub const PublicationPhase = enum {
    prepare,
    project,
    commit,
    abort,
};

pub const PublicationPlan = struct {
    id: TransactionId,
    native_root: ObjectId,
    objects: []const Object,
    projection_updates: []const RefUpdate,
    commit_updates: []const RefUpdate,
};

pub const RevisionRelation = enum {
    equal,
    ahead,
    behind,
    diverged,
    missing,
};

pub const Divergence = enum {
    in_sync,
    projection_only,
    carrier_only,
    remote_advanced,
    remote_rewound,
    concurrent_change,
};

pub const DivergenceInput = struct {
    carrier: RevisionRelation,
    projection: RevisionRelation,
};

pub fn classifyDivergence(input: DivergenceInput) Divergence {
    if (input.carrier == .equal and input.projection == .equal) return .in_sync;
    if (input.carrier == .equal) return .projection_only;
    if (input.projection == .equal) return .carrier_only;
    if (input.carrier == .ahead and input.projection == .ahead) return .remote_advanced;
    if ((input.carrier == .behind or input.carrier == .missing) and
        (input.projection == .behind or input.projection == .missing)) return .remote_rewound;
    return .concurrent_change;
}

pub const RecoverySnapshot = struct {
    recorded_phase: ?PublicationPhase,
    projection: RevisionRelation,
    carrier: RevisionRelation,
    preconditions_hold: bool,
};

pub const RecoveryDecision = enum {
    restart_prepare,
    resume_project,
    resume_commit,
    resume_abort,
    complete,
    complete_aborted,
    manual_reconcile,
};

pub fn decideRecovery(snapshot: RecoverySnapshot) RecoveryDecision {
    const phase = snapshot.recorded_phase orelse {
        if (snapshot.projection == .equal and snapshot.carrier == .equal) return .complete;
        return .restart_prepare;
    };

    return switch (phase) {
        .prepare => if (!snapshot.preconditions_hold)
            .resume_abort
        else if (snapshot.projection == .equal)
            .resume_commit
        else
            .resume_project,
        .project => if (snapshot.carrier == .equal)
            .complete
        else if (snapshot.preconditions_hold)
            .resume_commit
        else
            .manual_reconcile,
        .commit => if (snapshot.carrier == .equal and snapshot.projection == .equal)
            .complete
        else
            .manual_reconcile,
        .abort => .complete_aborted,
    };
}

pub const EdgeError = error{
    AtomicUpdatesUnsupported,
    CapacityExceeded,
    CompareAndSwapUnsupported,
    InvalidObjectId,
    InvalidRef,
    MissingObject,
    ObjectIdCollision,
    RefConflict,
    RefDeletionUnsupported,
    TransactionAlreadyCommitted,
    TransactionIdCollision,
    TransactionNotFound,
    TransactionPhaseMismatch,
    TooManyUpdates,
};

pub const Edge = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        discover_capabilities: *const fn (context: *anyopaque) ProtocolCapabilities,
        put_object: *const fn (context: *anyopaque, object: Object) anyerror!void,
        get_object: *const fn (context: *anyopaque, id: ObjectId) ?[]const u8,
        read_ref: *const fn (context: *anyopaque, id: RefId) ?ObjectId,
        apply_ref_updates: *const fn (context: *anyopaque, updates: []const RefUpdate, policy: UpdatePolicy) anyerror!UpdateResult,
        prepare: *const fn (context: *anyopaque, plan: PublicationPlan) anyerror!void,
        project: *const fn (context: *anyopaque, plan: PublicationPlan, policy: UpdatePolicy) anyerror!UpdateResult,
        commit: *const fn (context: *anyopaque, plan: PublicationPlan, policy: UpdatePolicy) anyerror!UpdateResult,
        abort: *const fn (context: *anyopaque, id: TransactionId) anyerror!void,
        transaction_phase: *const fn (context: *anyopaque, id: TransactionId) ?PublicationPhase,
    };

    pub fn discoverCapabilities(self: Edge) ProtocolCapabilities {
        return self.vtable.discover_capabilities(self.context);
    }

    pub fn putObject(self: Edge, object: Object) !void {
        return self.vtable.put_object(self.context, object);
    }

    pub fn getObject(self: Edge, id: ObjectId) ?[]const u8 {
        return self.vtable.get_object(self.context, id);
    }

    pub fn readRef(self: Edge, id: RefId) ?ObjectId {
        return self.vtable.read_ref(self.context, id);
    }

    pub fn applyRefUpdates(self: Edge, updates: []const RefUpdate, policy: UpdatePolicy) !UpdateResult {
        return self.vtable.apply_ref_updates(self.context, updates, policy);
    }

    pub fn prepare(self: Edge, plan: PublicationPlan) !void {
        return self.vtable.prepare(self.context, plan);
    }

    pub fn project(self: Edge, plan: PublicationPlan, policy: UpdatePolicy) !UpdateResult {
        return self.vtable.project(self.context, plan, policy);
    }

    pub fn commit(self: Edge, plan: PublicationPlan, policy: UpdatePolicy) !UpdateResult {
        return self.vtable.commit(self.context, plan, policy);
    }

    pub fn abort(self: Edge, id: TransactionId) !void {
        return self.vtable.abort(self.context, id);
    }

    pub fn transactionPhase(self: Edge, id: TransactionId) ?PublicationPhase {
        return self.vtable.transaction_phase(self.context, id);
    }
};

pub const InMemoryForgeEdge = struct {
    pub const max_objects = 256;
    pub const max_refs = 128;
    pub const max_transactions = 64;
    pub const max_ref_name_bytes = 255;

    const ObjectSlot = struct {
        id: ObjectId,
        bytes: []u8,
    };

    const RefSlot = struct {
        scope: RefScope,
        name: [max_ref_name_bytes]u8,
        name_len: u8,
        value: ObjectId,

        fn id(self: *const RefSlot) RefId {
            return .{ .scope = self.scope, .name = self.name[0..self.name_len] };
        }
    };

    const TransactionSlot = struct {
        id: TransactionId,
        native_root: ObjectId,
        phase: PublicationPhase,
    };

    allocator: std.mem.Allocator,
    capabilities: ProtocolCapabilities,
    object_slots: [max_objects]ObjectSlot = undefined,
    object_count: usize = 0,
    ref_slots: [max_refs]RefSlot = undefined,
    ref_count: usize = 0,
    transaction_slots: [max_transactions]TransactionSlot = undefined,
    transaction_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capabilities: ProtocolCapabilities) InMemoryForgeEdge {
        return .{ .allocator = allocator, .capabilities = capabilities };
    }

    pub fn edge(self: *InMemoryForgeEdge) Edge {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn deinit(self: *InMemoryForgeEdge) void {
        for (self.object_slots[0..self.object_count]) |slot| self.allocator.free(slot.bytes);
        self.* = undefined;
    }

    pub fn discoverCapabilities(self: *const InMemoryForgeEdge) ProtocolCapabilities {
        return self.capabilities;
    }

    pub fn putObject(self: *InMemoryForgeEdge, object: Object) (EdgeError || std.mem.Allocator.Error)!void {
        if (!object.id.isValid()) return error.InvalidObjectId;
        if (!self.capabilities.supportsHash(object.id.algorithm)) return error.InvalidObjectId;
        if (self.capabilities.max_object_bytes) |maximum| {
            if (object.bytes.len > maximum) return error.CapacityExceeded;
        }
        if (self.findObject(object.id)) |index| {
            if (!std.mem.eql(u8, self.object_slots[index].bytes, object.bytes)) return error.ObjectIdCollision;
            return;
        }
        if (self.object_count == max_objects) return error.CapacityExceeded;
        const bytes = try self.allocator.dupe(u8, object.bytes);
        self.object_slots[self.object_count] = .{ .id = object.id, .bytes = bytes };
        self.object_count += 1;
    }

    pub fn getObject(self: *const InMemoryForgeEdge, id: ObjectId) ?[]const u8 {
        const index = self.findObject(id) orelse return null;
        return self.object_slots[index].bytes;
    }

    pub fn readRef(self: *const InMemoryForgeEdge, id: RefId) ?ObjectId {
        const index = self.findRef(id) orelse return null;
        return self.ref_slots[index].value;
    }

    pub fn applyRefUpdates(self: *InMemoryForgeEdge, updates: []const RefUpdate, policy: UpdatePolicy) EdgeError!UpdateResult {
        if (!self.capabilities.compare_and_swap_refs) return error.CompareAndSwapUnsupported;
        if (self.capabilities.max_updates_per_transaction) |maximum| {
            if (updates.len > maximum) return error.TooManyUpdates;
        }
        const mode: UpdateMode = switch (policy) {
            .require_atomic => if (self.capabilities.atomic_ref_updates) .atomic else return error.AtomicUpdatesUnsupported,
            .prefer_atomic => if (self.capabilities.atomic_ref_updates) .atomic else .sequential,
            .allow_sequential => .sequential,
        };
        try self.validateUpdates(updates);
        if (mode == .atomic) {
            try self.preflightAtomic(updates);
            for (updates) |update| {
                if (update.desired == null) self.applyOne(update);
            }
            for (updates) |update| {
                if (update.desired != null and self.findRef(update.ref) != null) self.applyOne(update);
            }
            for (updates) |update| {
                if (update.desired != null and self.findRef(update.ref) == null) self.applyOne(update);
            }
        } else {
            for (updates) |update| {
                try self.checkExpected(update);
                if (update.desired != null and self.findRef(update.ref) == null and self.ref_count == max_refs) {
                    return error.CapacityExceeded;
                }
                self.applyOne(update);
            }
        }
        return .{ .mode = mode, .updated = updates.len };
    }

    pub fn prepare(self: *InMemoryForgeEdge, plan: PublicationPlan) (EdgeError || std.mem.Allocator.Error)!void {
        if (self.findTransaction(plan.id)) |index| {
            const existing = self.transaction_slots[index];
            if (!ObjectId.eql(existing.native_root, plan.native_root)) return error.TransactionIdCollision;
            return;
        }
        if (self.transaction_count == max_transactions) return error.CapacityExceeded;
        for (plan.objects) |object| try self.putObject(object);
        if (self.getObject(plan.native_root) == null) return error.MissingObject;
        self.transaction_slots[self.transaction_count] = .{
            .id = plan.id,
            .native_root = plan.native_root,
            .phase = .prepare,
        };
        self.transaction_count += 1;
    }

    pub fn project(self: *InMemoryForgeEdge, plan: PublicationPlan, policy: UpdatePolicy) EdgeError!UpdateResult {
        const index = self.findTransaction(plan.id) orelse return error.TransactionNotFound;
        const record = &self.transaction_slots[index];
        if (!ObjectId.eql(record.native_root, plan.native_root)) return error.TransactionIdCollision;
        if (record.phase == .project) return .{ .mode = self.selectedMode(policy) catch return error.AtomicUpdatesUnsupported, .updated = 0 };
        if (record.phase != .prepare) return error.TransactionPhaseMismatch;
        const result = try self.applyRefUpdates(plan.projection_updates, policy);
        record.phase = .project;
        return result;
    }

    pub fn commit(self: *InMemoryForgeEdge, plan: PublicationPlan, policy: UpdatePolicy) EdgeError!UpdateResult {
        const index = self.findTransaction(plan.id) orelse return error.TransactionNotFound;
        const record = &self.transaction_slots[index];
        if (!ObjectId.eql(record.native_root, plan.native_root)) return error.TransactionIdCollision;
        if (record.phase == .commit) return .{ .mode = self.selectedMode(policy) catch return error.AtomicUpdatesUnsupported, .updated = 0 };
        if (record.phase != .project) return error.TransactionPhaseMismatch;
        const result = try self.applyRefUpdates(plan.commit_updates, policy);
        record.phase = .commit;
        return result;
    }

    pub fn abort(self: *InMemoryForgeEdge, id: TransactionId) EdgeError!void {
        const index = self.findTransaction(id) orelse return error.TransactionNotFound;
        const record = &self.transaction_slots[index];
        if (record.phase == .commit) return error.TransactionAlreadyCommitted;
        record.phase = .abort;
    }

    pub fn transactionPhase(self: *const InMemoryForgeEdge, id: TransactionId) ?PublicationPhase {
        const index = self.findTransaction(id) orelse return null;
        return self.transaction_slots[index].phase;
    }

    fn selectedMode(self: *const InMemoryForgeEdge, policy: UpdatePolicy) EdgeError!UpdateMode {
        return switch (policy) {
            .require_atomic => if (self.capabilities.atomic_ref_updates) .atomic else error.AtomicUpdatesUnsupported,
            .prefer_atomic => if (self.capabilities.atomic_ref_updates) .atomic else .sequential,
            .allow_sequential => .sequential,
        };
    }

    fn validateUpdates(self: *const InMemoryForgeEdge, updates: []const RefUpdate) EdgeError!void {
        var final_ref_count = self.ref_count;
        for (updates, 0..) |update, index| {
            if (!update.ref.isValid()) return error.InvalidRef;
            if (update.desired == null and !self.capabilities.ref_deletion) return error.RefDeletionUnsupported;
            if (update.desired) |desired| {
                if (self.findObject(desired) == null) return error.MissingObject;
            }
            for (updates[0..index]) |previous| {
                if (RefId.eql(previous.ref, update.ref)) return error.RefConflict;
            }
            const exists = self.findRef(update.ref) != null;
            if (!exists and update.desired != null) final_ref_count += 1;
            if (exists and update.desired == null) final_ref_count -= 1;
        }
        if (final_ref_count > max_refs) return error.CapacityExceeded;
    }

    fn preflightAtomic(self: *const InMemoryForgeEdge, updates: []const RefUpdate) EdgeError!void {
        for (updates) |update| try self.checkExpected(update);
    }

    fn checkExpected(self: *const InMemoryForgeEdge, update: RefUpdate) EdgeError!void {
        const actual = self.readRef(update.ref);
        if (actual == null and update.expected == null) return;
        if (actual == null or update.expected == null) return error.RefConflict;
        if (!ObjectId.eql(actual.?, update.expected.?)) return error.RefConflict;
    }

    fn applyOne(self: *InMemoryForgeEdge, update: RefUpdate) void {
        if (self.findRef(update.ref)) |index| {
            if (update.desired) |desired| {
                self.ref_slots[index].value = desired;
            } else {
                self.ref_count -= 1;
                self.ref_slots[index] = self.ref_slots[self.ref_count];
            }
            return;
        }
        const desired = update.desired orelse return;
        var slot: RefSlot = undefined;
        slot.scope = update.ref.scope;
        @memcpy(slot.name[0..update.ref.name.len], update.ref.name);
        slot.name_len = @intCast(update.ref.name.len);
        slot.value = desired;
        self.ref_slots[self.ref_count] = slot;
        self.ref_count += 1;
    }

    fn findObject(self: *const InMemoryForgeEdge, id: ObjectId) ?usize {
        for (self.object_slots[0..self.object_count], 0..) |slot, index| {
            if (ObjectId.eql(slot.id, id)) return index;
        }
        return null;
    }

    fn findRef(self: *const InMemoryForgeEdge, id: RefId) ?usize {
        for (self.ref_slots[0..self.ref_count], 0..) |*slot, index| {
            if (RefId.eql(slot.id(), id)) return index;
        }
        return null;
    }

    fn findTransaction(self: *const InMemoryForgeEdge, id: TransactionId) ?usize {
        for (self.transaction_slots[0..self.transaction_count], 0..) |slot, index| {
            if (std.mem.eql(u8, &slot.id, &id)) return index;
        }
        return null;
    }

    fn cast(context: *anyopaque) *InMemoryForgeEdge {
        return @ptrCast(@alignCast(context));
    }

    fn vDiscoverCapabilities(context: *anyopaque) ProtocolCapabilities {
        return cast(context).discoverCapabilities();
    }

    fn vPutObject(context: *anyopaque, object: Object) !void {
        return cast(context).putObject(object);
    }

    fn vGetObject(context: *anyopaque, id: ObjectId) ?[]const u8 {
        return cast(context).getObject(id);
    }

    fn vReadRef(context: *anyopaque, id: RefId) ?ObjectId {
        return cast(context).readRef(id);
    }

    fn vApplyRefUpdates(context: *anyopaque, updates: []const RefUpdate, policy: UpdatePolicy) !UpdateResult {
        return cast(context).applyRefUpdates(updates, policy);
    }

    fn vPrepare(context: *anyopaque, plan: PublicationPlan) !void {
        return cast(context).prepare(plan);
    }

    fn vProject(context: *anyopaque, plan: PublicationPlan, policy: UpdatePolicy) !UpdateResult {
        return cast(context).project(plan, policy);
    }

    fn vCommit(context: *anyopaque, plan: PublicationPlan, policy: UpdatePolicy) !UpdateResult {
        return cast(context).commit(plan, policy);
    }

    fn vAbort(context: *anyopaque, id: TransactionId) !void {
        return cast(context).abort(id);
    }

    fn vTransactionPhase(context: *anyopaque, id: TransactionId) ?PublicationPhase {
        return cast(context).transactionPhase(id);
    }

    const vtable = Edge.VTable{
        .discover_capabilities = vDiscoverCapabilities,
        .put_object = vPutObject,
        .get_object = vGetObject,
        .read_ref = vReadRef,
        .apply_ref_updates = vApplyRefUpdates,
        .prepare = vPrepare,
        .project = vProject,
        .commit = vCommit,
        .abort = vAbort,
        .transaction_phase = vTransactionPhase,
    };
};

const test_hashes = [_]HashAlgorithm{.blake3_256};

fn testCapabilities(atomic: bool) ProtocolCapabilities {
    return .{
        .compare_and_swap_refs = true,
        .atomic_ref_updates = atomic,
        .ref_deletion = true,
        .max_object_bytes = null,
        .max_updates_per_transaction = null,
        .hash_algorithms = &test_hashes,
    };
}

fn testId(byte: u8) ObjectId {
    return .{
        .algorithm = .blake3_256,
        .digest = [_]u8{byte} ** 64,
        .digest_len = 32,
    };
}

fn testTransaction(byte: u8) TransactionId {
    return [_]u8{byte} ** 16;
}

test "capability discovery is provider neutral" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer edge.deinit();
    const capabilities = edge.discoverCapabilities();
    try std.testing.expect(capabilities.compare_and_swap_refs);
    try std.testing.expect(capabilities.atomic_ref_updates);
    try std.testing.expect(capabilities.supportsHash(.blake3_256));
    try std.testing.expect(!capabilities.supportsHash(.sha2_512));
}

test "edge abstraction dispatches without transport or provider knowledge" {
    var memory = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer memory.deinit();
    const edge = memory.edge();
    const id = testId(1);
    try edge.putObject(.{ .id = id, .bytes = "native" });
    try std.testing.expectEqualStrings("native", edge.getObject(id).?);
    try std.testing.expect(edge.discoverCapabilities().compare_and_swap_refs);
}

test "object identifiers validate algorithms and reject collisions" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer edge.deinit();
    const id = testId(1);
    try edge.putObject(.{ .id = id, .bytes = "native" });
    try edge.putObject(.{ .id = id, .bytes = "native" });
    try std.testing.expectError(error.ObjectIdCollision, edge.putObject(.{ .id = id, .bytes = "changed" }));
    var invalid = id;
    invalid.digest_len = 31;
    try std.testing.expectError(error.InvalidObjectId, edge.putObject(.{ .id = invalid, .bytes = "native" }));
}

test "atomic compare and swap rejects every update when one ref diverges" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer edge.deinit();
    const first = testId(1);
    const second = testId(2);
    const third = testId(3);
    try edge.putObject(.{ .id = first, .bytes = "one" });
    try edge.putObject(.{ .id = second, .bytes = "two" });
    try edge.putObject(.{ .id = third, .bytes = "three" });
    _ = try edge.applyRefUpdates(&.{
        .{ .ref = .{ .scope = .native, .name = "root" }, .expected = null, .desired = first },
        .{ .ref = .{ .scope = .projection, .name = "main" }, .expected = null, .desired = first },
    }, .require_atomic);
    try std.testing.expectError(error.RefConflict, edge.applyRefUpdates(&.{
        .{ .ref = .{ .scope = .native, .name = "root" }, .expected = first, .desired = second },
        .{ .ref = .{ .scope = .projection, .name = "main" }, .expected = third, .desired = second },
    }, .require_atomic));
    try std.testing.expect(ObjectId.eql(first, edge.readRef(.{ .scope = .native, .name = "root" }).?));
    try std.testing.expect(ObjectId.eql(first, edge.readRef(.{ .scope = .projection, .name = "main" }).?));
}

test "sequential compare and swap exposes partial progress for recovery" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(false));
    defer edge.deinit();
    const first = testId(1);
    const second = testId(2);
    const third = testId(3);
    try edge.putObject(.{ .id = first, .bytes = "one" });
    try edge.putObject(.{ .id = second, .bytes = "two" });
    try edge.putObject(.{ .id = third, .bytes = "three" });
    _ = try edge.applyRefUpdates(&.{
        .{ .ref = .{ .scope = .native, .name = "root" }, .expected = null, .desired = first },
        .{ .ref = .{ .scope = .projection, .name = "main" }, .expected = null, .desired = first },
    }, .allow_sequential);
    try std.testing.expectError(error.RefConflict, edge.applyRefUpdates(&.{
        .{ .ref = .{ .scope = .native, .name = "root" }, .expected = first, .desired = second },
        .{ .ref = .{ .scope = .projection, .name = "main" }, .expected = third, .desired = second },
    }, .allow_sequential));
    try std.testing.expect(ObjectId.eql(second, edge.readRef(.{ .scope = .native, .name = "root" }).?));
    try std.testing.expect(ObjectId.eql(first, edge.readRef(.{ .scope = .projection, .name = "main" }).?));
    try std.testing.expectError(error.AtomicUpdatesUnsupported, edge.applyRefUpdates(&.{}, .require_atomic));
}

test "preferred atomic updates fall back without provider dispatch" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(false));
    defer edge.deinit();
    const first = testId(1);
    try edge.putObject(.{ .id = first, .bytes = "one" });
    const result = try edge.applyRefUpdates(&.{.{
        .ref = .{ .scope = .metadata, .name = "state" },
        .expected = null,
        .desired = first,
    }}, .prefer_atomic);
    try std.testing.expectEqual(UpdateMode.sequential, result.mode);
    try std.testing.expectEqual(@as(usize, 1), result.updated);
}

test "publication advances through recoverable phases and is idempotent" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer edge.deinit();
    const native_root = testId(1);
    const projection_root = testId(2);
    const plan = PublicationPlan{
        .id = testTransaction(9),
        .native_root = native_root,
        .objects = &.{
            .{ .id = native_root, .bytes = "carrier" },
            .{ .id = projection_root, .bytes = "projection" },
        },
        .projection_updates = &.{.{
            .ref = .{ .scope = .projection, .name = "main" },
            .expected = null,
            .desired = projection_root,
        }},
        .commit_updates = &.{.{
            .ref = .{ .scope = .native, .name = "root" },
            .expected = null,
            .desired = native_root,
        }},
    };
    try edge.prepare(plan);
    try edge.prepare(plan);
    try std.testing.expectEqual(PublicationPhase.prepare, edge.transactionPhase(plan.id).?);
    const projected = try edge.project(plan, .require_atomic);
    try std.testing.expectEqual(@as(usize, 1), projected.updated);
    const projected_again = try edge.project(plan, .require_atomic);
    try std.testing.expectEqual(@as(usize, 0), projected_again.updated);
    try std.testing.expectEqual(PublicationPhase.project, edge.transactionPhase(plan.id).?);
    const committed = try edge.commit(plan, .require_atomic);
    try std.testing.expectEqual(@as(usize, 1), committed.updated);
    const committed_again = try edge.commit(plan, .require_atomic);
    try std.testing.expectEqual(@as(usize, 0), committed_again.updated);
    try std.testing.expectEqual(PublicationPhase.commit, edge.transactionPhase(plan.id).?);
    try std.testing.expectError(error.TransactionAlreadyCommitted, edge.abort(plan.id));
}

test "publication can abort before commit and refuses invalid transitions" {
    var edge = InMemoryForgeEdge.init(std.testing.allocator, testCapabilities(true));
    defer edge.deinit();
    const native_root = testId(1);
    const plan = PublicationPlan{
        .id = testTransaction(7),
        .native_root = native_root,
        .objects = &.{.{ .id = native_root, .bytes = "carrier" }},
        .projection_updates = &.{},
        .commit_updates = &.{},
    };
    try edge.prepare(plan);
    try std.testing.expectError(error.TransactionPhaseMismatch, edge.commit(plan, .require_atomic));
    try edge.abort(plan.id);
    try edge.abort(plan.id);
    try std.testing.expectEqual(PublicationPhase.abort, edge.transactionPhase(plan.id).?);
    try std.testing.expectError(error.TransactionPhaseMismatch, edge.project(plan, .require_atomic));
}

test "recovery decisions cover crashes at every publication boundary" {
    try std.testing.expectEqual(RecoveryDecision.restart_prepare, decideRecovery(.{
        .recorded_phase = null,
        .projection = .missing,
        .carrier = .missing,
        .preconditions_hold = true,
    }));
    try std.testing.expectEqual(RecoveryDecision.resume_project, decideRecovery(.{
        .recorded_phase = .prepare,
        .projection = .behind,
        .carrier = .behind,
        .preconditions_hold = true,
    }));
    try std.testing.expectEqual(RecoveryDecision.resume_commit, decideRecovery(.{
        .recorded_phase = .project,
        .projection = .equal,
        .carrier = .behind,
        .preconditions_hold = true,
    }));
    try std.testing.expectEqual(RecoveryDecision.resume_abort, decideRecovery(.{
        .recorded_phase = .prepare,
        .projection = .behind,
        .carrier = .behind,
        .preconditions_hold = false,
    }));
    try std.testing.expectEqual(RecoveryDecision.manual_reconcile, decideRecovery(.{
        .recorded_phase = .project,
        .projection = .diverged,
        .carrier = .diverged,
        .preconditions_hold = false,
    }));
    try std.testing.expectEqual(RecoveryDecision.complete, decideRecovery(.{
        .recorded_phase = .commit,
        .projection = .equal,
        .carrier = .equal,
        .preconditions_hold = false,
    }));
    try std.testing.expectEqual(RecoveryDecision.complete_aborted, decideRecovery(.{
        .recorded_phase = .abort,
        .projection = .diverged,
        .carrier = .missing,
        .preconditions_hold = false,
    }));
}

test "divergence classification distinguishes independent and concurrent movement" {
    try std.testing.expectEqual(Divergence.in_sync, classifyDivergence(.{ .carrier = .equal, .projection = .equal }));
    try std.testing.expectEqual(Divergence.projection_only, classifyDivergence(.{ .carrier = .equal, .projection = .ahead }));
    try std.testing.expectEqual(Divergence.carrier_only, classifyDivergence(.{ .carrier = .ahead, .projection = .equal }));
    try std.testing.expectEqual(Divergence.remote_advanced, classifyDivergence(.{ .carrier = .ahead, .projection = .ahead }));
    try std.testing.expectEqual(Divergence.remote_rewound, classifyDivergence(.{ .carrier = .behind, .projection = .missing }));
    try std.testing.expectEqual(Divergence.concurrent_change, classifyDivergence(.{ .carrier = .ahead, .projection = .behind }));
}
