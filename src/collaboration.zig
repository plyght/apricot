const std = @import("std");

pub const contract_version: u32 = 1;

pub const ProtocolFamily = enum {
    rest,
    graphql,
    forgefed,
    command,
    custom,
};

pub const Support = enum {
    unsupported,
    native,
    emulated,
};

pub const ResourceKind = enum(u8) {
    issue,
    change_request,
    review,
    comment,
    fork,
    check,
    release,
    label,
    milestone,
};

pub const Operation = enum {
    create,
    get,
    update,
    delete,
    list,
};

pub const Operations = struct {
    create: Support = .unsupported,
    get: Support = .unsupported,
    update: Support = .unsupported,
    delete: Support = .unsupported,
    list: Support = .unsupported,

    pub fn support(self: Operations, operation: Operation) Support {
        return switch (operation) {
            .create => self.create,
            .get => self.get,
            .update => self.update,
            .delete => self.delete,
            .list => self.list,
        };
    }
};

pub const ResourceCapability = struct {
    kind: ResourceKind,
    operations: Operations,
};

pub const ExtensionFormat = enum {
    bytes,
    utf8,
    json,
};

pub const Extension = struct {
    namespace: []const u8,
    name: []const u8,
    format: ExtensionFormat,
    value: []const u8,
};

pub const OpaqueId = struct {
    provider: []const u8,
    value: []const u8,

    pub fn eql(a: OpaqueId, b: OpaqueId) bool {
        return std.mem.eql(u8, a.provider, b.provider) and std.mem.eql(u8, a.value, b.value);
    }
};

pub const RepositoryIdentity = struct {
    vcs: []const u8,
    repository: []const u8,
    extensions: []const Extension = &.{},
};

pub const RevisionIdentity = struct {
    vcs: []const u8,
    repository: []const u8,
    revision: []const u8,
    extensions: []const Extension = &.{},
};

pub const Actor = struct {
    id: OpaqueId,
    login: []const u8,
    display_name: []const u8,
    extensions: []const Extension = &.{},
};

pub const State = enum {
    open,
    closed,
    merged,
    draft,
    pending,
    running,
    passed,
    failed,
    cancelled,
    archived,
};

pub const Issue = struct {
    title: []const u8,
    body: []const u8,
    state: State,
    labels: []const OpaqueId = &.{},
    milestone: ?OpaqueId = null,
    assignees: []const OpaqueId = &.{},
};

pub const ChangeRequest = struct {
    title: []const u8,
    body: []const u8,
    state: State,
    source_repository: RepositoryIdentity,
    source: RevisionIdentity,
    target: RevisionIdentity,
    labels: []const OpaqueId = &.{},
    milestone: ?OpaqueId = null,
};

pub const ReviewVerdict = enum {
    pending,
    approved,
    changes_requested,
    dismissed,
    commented,
};

pub const Review = struct {
    change_request: OpaqueId,
    body: []const u8,
    verdict: ReviewVerdict,
    revision: ?RevisionIdentity = null,
};

pub const Comment = struct {
    parent_kind: ResourceKind,
    parent: OpaqueId,
    body: []const u8,
    revision: ?RevisionIdentity = null,
    path: ?[]const u8 = null,
    line: ?u64 = null,
};

pub const Fork = struct {
    source: RepositoryIdentity,
    destination: RepositoryIdentity,
    state: State,
};

pub const Check = struct {
    name: []const u8,
    revision: RevisionIdentity,
    state: State,
    summary: []const u8,
    details_url: ?[]const u8 = null,
};

pub const ReleaseAsset = struct {
    name: []const u8,
    media_type: []const u8,
    size: u64,
    digest: []const u8,
    download_url: ?[]const u8 = null,
    extensions: []const Extension = &.{},
};

pub const Release = struct {
    name: []const u8,
    body: []const u8,
    revision: RevisionIdentity,
    state: State,
    assets: []const ReleaseAsset = &.{},
};

pub const Label = struct {
    name: []const u8,
    color: []const u8,
    description: []const u8,
};

pub const Milestone = struct {
    title: []const u8,
    description: []const u8,
    state: State,
    due_at: ?i64 = null,
};

pub const ResourceValue = union(ResourceKind) {
    issue: Issue,
    change_request: ChangeRequest,
    review: Review,
    comment: Comment,
    fork: Fork,
    check: Check,
    release: Release,
    label: Label,
    milestone: Milestone,
};

pub const Resource = struct {
    id: OpaqueId,
    version: []const u8,
    created_at: i64,
    updated_at: i64,
    author: ?Actor,
    extensions: []const Extension = &.{},
    value: ResourceValue,

    pub fn kind(self: Resource) ResourceKind {
        return std.meta.activeTag(self.value);
    }
};

pub const ResourceDraft = struct {
    author: ?Actor = null,
    extensions: []const Extension = &.{},
    value: ResourceValue,

    pub fn kind(self: ResourceDraft) ResourceKind {
        return std.meta.activeTag(self.value);
    }
};

pub const Capabilities = struct {
    resources: []const ResourceCapability,
    pagination: Support = .unsupported,
    conditional_updates: Support = .unsupported,
    idempotent_creates: Support = .unsupported,
    federation: Support = .unsupported,

    pub fn operations(self: Capabilities, kind: ResourceKind) Operations {
        for (self.resources) |resource| if (resource.kind == kind) return resource.operations;
        return .{};
    }

    pub fn supports(self: Capabilities, kind: ResourceKind, operation: Operation) Support {
        return self.operations(kind).support(operation);
    }
};

pub const Discovery = struct {
    contract: u32,
    provider: []const u8,
    protocol_family: ProtocolFamily,
    capabilities: Capabilities,
    extensions: []const Extension = &.{},
};

pub const FailureCode = enum {
    unauthenticated,
    forbidden,
    not_found,
    conflict,
    validation,
    rate_limited,
    unsupported,
    unavailable,
    cancelled,
    provider_failure,
};

pub const Failure = struct {
    code: FailureCode,
    message: []const u8,
    retryable: bool = false,
    retry_after_seconds: ?u64 = null,
    provider_code: ?[]const u8 = null,
    extensions: []const Extension = &.{},
};

pub const Page = struct {
    items: []const Resource,
    next_cursor: ?[]const u8 = null,
    total: ?u64 = null,
    extensions: []const Extension = &.{},
};

pub const CreateRequest = struct {
    repository: RepositoryIdentity,
    draft: ResourceDraft,
    idempotency_key: ?[]const u8 = null,
};

pub const GetRequest = struct {
    repository: RepositoryIdentity,
    kind: ResourceKind,
    id: OpaqueId,
};

pub const UpdateRequest = struct {
    repository: RepositoryIdentity,
    id: OpaqueId,
    expected_version: ?[]const u8 = null,
    replacement: ResourceDraft,
};

pub const DeleteRequest = struct {
    repository: RepositoryIdentity,
    kind: ResourceKind,
    id: OpaqueId,
    expected_version: ?[]const u8 = null,
};

pub const ListRequest = struct {
    repository: RepositoryIdentity,
    kind: ResourceKind,
    cursor: ?[]const u8 = null,
    limit: u32 = 50,
    state: ?State = null,
    parent: ?OpaqueId = null,
    extensions: []const Extension = &.{},
};

pub const Response = union(enum) {
    discovery: Discovery,
    item: Resource,
    page: Page,
    deleted: OpaqueId,
    failure: Failure,
};

pub const Handle = struct {
    context: *anyopaque,
    response: Response,
    release_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: *Handle) void {
        self.release_fn(self.context);
        self.* = undefined;
    }
};

pub const VTable = struct {
    discover: *const fn (*anyopaque, std.mem.Allocator, RepositoryIdentity) anyerror!Handle,
    create: *const fn (*anyopaque, std.mem.Allocator, CreateRequest) anyerror!Handle,
    get: *const fn (*anyopaque, std.mem.Allocator, GetRequest) anyerror!Handle,
    update: *const fn (*anyopaque, std.mem.Allocator, UpdateRequest) anyerror!Handle,
    delete: *const fn (*anyopaque, std.mem.Allocator, DeleteRequest) anyerror!Handle,
    list: *const fn (*anyopaque, std.mem.Allocator, ListRequest) anyerror!Handle,
};

pub const Driver = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn discover(self: Driver, allocator: std.mem.Allocator, repository: RepositoryIdentity) !Handle {
        return self.vtable.discover(self.context, allocator, repository);
    }

    pub fn create(self: Driver, allocator: std.mem.Allocator, request: CreateRequest) !Handle {
        return self.vtable.create(self.context, allocator, request);
    }

    pub fn get(self: Driver, allocator: std.mem.Allocator, request: GetRequest) !Handle {
        return self.vtable.get(self.context, allocator, request);
    }

    pub fn update(self: Driver, allocator: std.mem.Allocator, request: UpdateRequest) !Handle {
        return self.vtable.update(self.context, allocator, request);
    }

    pub fn delete(self: Driver, allocator: std.mem.Allocator, request: DeleteRequest) !Handle {
        return self.vtable.delete(self.context, allocator, request);
    }

    pub fn list(self: Driver, allocator: std.mem.Allocator, request: ListRequest) !Handle {
        return self.vtable.list(self.context, allocator, request);
    }
};

const native_operations = Operations{
    .create = .native,
    .get = .native,
    .update = .native,
    .delete = .native,
    .list = .native,
};

const all_capabilities = [_]ResourceCapability{
    .{ .kind = .issue, .operations = native_operations },
    .{ .kind = .change_request, .operations = native_operations },
    .{ .kind = .review, .operations = native_operations },
    .{ .kind = .comment, .operations = native_operations },
    .{ .kind = .fork, .operations = native_operations },
    .{ .kind = .check, .operations = native_operations },
    .{ .kind = .release, .operations = native_operations },
    .{ .kind = .label, .operations = native_operations },
    .{ .kind = .milestone, .operations = native_operations },
};

pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    protocol_family: ProtocolFamily,
    records: std.ArrayList(Stored) = .empty,
    next_id: u64 = 1,
    clock: i64 = 1,

    const Stored = struct {
        arena: *std.heap.ArenaAllocator,
        repository: RepositoryIdentity,
        resource: Resource,
    };

    const ResultState = struct {
        arena: std.heap.ArenaAllocator,
    };

    pub fn init(allocator: std.mem.Allocator, provider: []const u8, protocol_family: ProtocolFamily) MemoryDriver {
        return .{ .allocator = allocator, .provider = provider, .protocol_family = protocol_family };
    }

    pub fn deinit(self: *MemoryDriver) void {
        for (self.records.items) |stored| {
            stored.arena.deinit();
            self.allocator.destroy(stored.arena);
        }
        self.records.deinit(self.allocator);
    }

    pub fn driver(self: *MemoryDriver) Driver {
        return .{ .context = self, .vtable = &memory_vtable };
    }

    fn makeResult(self: *MemoryDriver) !struct { state: *ResultState, allocator: std.mem.Allocator } {
        const state = try self.allocator.create(ResultState);
        state.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        return .{ .state = state, .allocator = state.arena.allocator() };
    }

    fn finishResult(result: anytype, response: Response) Handle {
        return .{ .context = result.state, .response = response, .release_fn = releaseResult };
    }

    fn releaseResult(context: *anyopaque) void {
        const state: *ResultState = @ptrCast(@alignCast(context));
        const allocator = state.arena.child_allocator;
        state.arena.deinit();
        allocator.destroy(state);
    }

    fn failure(self: *MemoryDriver, code: FailureCode, message: []const u8) !Handle {
        const result = try self.makeResult();
        return finishResult(result, .{ .failure = .{ .code = code, .message = try result.allocator.dupe(u8, message) } });
    }

    fn discoverFn(context: *anyopaque, allocator: std.mem.Allocator, repository: RepositoryIdentity) !Handle {
        _ = allocator;
        _ = repository;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        const result = try self.makeResult();
        return finishResult(result, .{ .discovery = .{
            .contract = contract_version,
            .provider = try result.allocator.dupe(u8, self.provider),
            .protocol_family = self.protocol_family,
            .capabilities = .{
                .resources = &all_capabilities,
                .pagination = .native,
                .conditional_updates = .native,
                .idempotent_creates = .native,
                .federation = .unsupported,
            },
        } });
    }

    fn createFn(context: *anyopaque, allocator: std.mem.Allocator, request: CreateRequest) !Handle {
        _ = allocator;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        if (request.idempotency_key) |key| {
            for (self.records.items) |stored| {
                for (stored.resource.extensions) |extension| {
                    if (std.mem.eql(u8, extension.namespace, "apricot") and std.mem.eql(u8, extension.name, "idempotency-key") and std.mem.eql(u8, extension.value, key)) {
                        const result = try self.makeResult();
                        return finishResult(result, .{ .item = try cloneResource(result.allocator, stored.resource) });
                    }
                }
            }
        }
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var extensions = std.ArrayList(Extension).empty;
        defer extensions.deinit(a);
        for (request.draft.extensions) |extension| try extensions.append(a, try cloneExtension(a, extension));
        if (request.idempotency_key) |key| try extensions.append(a, .{
            .namespace = try a.dupe(u8, "apricot"),
            .name = try a.dupe(u8, "idempotency-key"),
            .format = .utf8,
            .value = try a.dupe(u8, key),
        });
        const id_value = try std.fmt.allocPrint(a, "{d}", .{self.next_id});
        const version = try std.fmt.allocPrint(a, "{d}", .{1});
        const resource = Resource{
            .id = .{ .provider = try a.dupe(u8, self.provider), .value = id_value },
            .version = version,
            .created_at = self.clock,
            .updated_at = self.clock,
            .author = if (request.draft.author) |actor| try cloneActor(a, actor) else null,
            .extensions = try extensions.toOwnedSlice(a),
            .value = try cloneValue(a, request.draft.value),
        };
        const repository = try cloneRepository(a, request.repository);
        try self.records.append(self.allocator, .{ .arena = arena, .repository = repository, .resource = resource });
        self.next_id += 1;
        self.clock += 1;
        const result = try self.makeResult();
        return finishResult(result, .{ .item = try cloneResource(result.allocator, resource) });
    }

    fn getFn(context: *anyopaque, allocator: std.mem.Allocator, request: GetRequest) !Handle {
        _ = allocator;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        for (self.records.items) |stored| {
            if (repositoryEql(stored.repository, request.repository) and stored.resource.kind() == request.kind and stored.resource.id.eql(request.id)) {
                const result = try self.makeResult();
                return finishResult(result, .{ .item = try cloneResource(result.allocator, stored.resource) });
            }
        }
        return self.failure(.not_found, "resource not found");
    }

    fn updateFn(context: *anyopaque, allocator: std.mem.Allocator, request: UpdateRequest) !Handle {
        _ = allocator;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        for (self.records.items, 0..) |stored, index| {
            if (!repositoryEql(stored.repository, request.repository) or !stored.resource.id.eql(request.id)) continue;
            if (stored.resource.kind() != request.replacement.kind()) return self.failure(.validation, "resource kind cannot change");
            if (request.expected_version) |version| if (!std.mem.eql(u8, version, stored.resource.version)) return self.failure(.conflict, "resource version changed");
            const arena = try self.allocator.create(std.heap.ArenaAllocator);
            errdefer self.allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const next_version = try std.fmt.parseInt(u64, stored.resource.version, 10) + 1;
            const resource = Resource{
                .id = try cloneId(a, stored.resource.id),
                .version = try std.fmt.allocPrint(a, "{d}", .{next_version}),
                .created_at = stored.resource.created_at,
                .updated_at = self.clock,
                .author = if (request.replacement.author) |actor| try cloneActor(a, actor) else null,
                .extensions = try cloneExtensions(a, request.replacement.extensions),
                .value = try cloneValue(a, request.replacement.value),
            };
            const repository = try cloneRepository(a, request.repository);
            stored.arena.deinit();
            self.allocator.destroy(stored.arena);
            self.records.items[index] = .{ .arena = arena, .repository = repository, .resource = resource };
            self.clock += 1;
            const result = try self.makeResult();
            return finishResult(result, .{ .item = try cloneResource(result.allocator, resource) });
        }
        return self.failure(.not_found, "resource not found");
    }

    fn deleteFn(context: *anyopaque, allocator: std.mem.Allocator, request: DeleteRequest) !Handle {
        _ = allocator;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        for (self.records.items, 0..) |stored, index| {
            if (!repositoryEql(stored.repository, request.repository) or stored.resource.kind() != request.kind or !stored.resource.id.eql(request.id)) continue;
            if (request.expected_version) |version| if (!std.mem.eql(u8, version, stored.resource.version)) return self.failure(.conflict, "resource version changed");
            const result = try self.makeResult();
            const deleted = try cloneId(result.allocator, stored.resource.id);
            const removed = self.records.swapRemove(index);
            removed.arena.deinit();
            self.allocator.destroy(removed.arena);
            return finishResult(result, .{ .deleted = deleted });
        }
        return self.failure(.not_found, "resource not found");
    }

    fn listFn(context: *anyopaque, allocator: std.mem.Allocator, request: ListRequest) !Handle {
        _ = allocator;
        const self: *MemoryDriver = @ptrCast(@alignCast(context));
        if (request.limit == 0 or request.limit > 1000) return self.failure(.validation, "limit must be between 1 and 1000");
        const offset = if (request.cursor) |cursor| std.fmt.parseInt(usize, cursor, 10) catch return self.failure(.validation, "invalid cursor") else 0;
        const result = try self.makeResult();
        var matches = std.ArrayList(Resource).empty;
        var seen: usize = 0;
        var total: usize = 0;
        for (self.records.items) |stored| {
            if (!repositoryEql(stored.repository, request.repository) or stored.resource.kind() != request.kind or !matchesFilter(stored.resource, request)) continue;
            if (seen >= offset and matches.items.len < request.limit) try matches.append(result.allocator, try cloneResource(result.allocator, stored.resource));
            seen += 1;
            total += 1;
        }
        const next_cursor = if (offset + matches.items.len < total) try std.fmt.allocPrint(result.allocator, "{d}", .{offset + matches.items.len}) else null;
        return finishResult(result, .{ .page = .{
            .items = try matches.toOwnedSlice(result.allocator),
            .next_cursor = next_cursor,
            .total = total,
        } });
    }
};

const memory_vtable = VTable{
    .discover = MemoryDriver.discoverFn,
    .create = MemoryDriver.createFn,
    .get = MemoryDriver.getFn,
    .update = MemoryDriver.updateFn,
    .delete = MemoryDriver.deleteFn,
    .list = MemoryDriver.listFn,
};

fn repositoryEql(a: RepositoryIdentity, b: RepositoryIdentity) bool {
    return std.mem.eql(u8, a.vcs, b.vcs) and std.mem.eql(u8, a.repository, b.repository);
}

fn matchesFilter(resource: Resource, request: ListRequest) bool {
    if (request.state) |wanted| {
        const actual: ?State = switch (resource.value) {
            .issue => |value| value.state,
            .change_request => |value| value.state,
            .fork => |value| value.state,
            .check => |value| value.state,
            .release => |value| value.state,
            .milestone => |value| value.state,
            else => null,
        };
        if (actual == null or actual.? != wanted) return false;
    }
    if (request.parent) |wanted| {
        const actual: ?OpaqueId = switch (resource.value) {
            .review => |value| value.change_request,
            .comment => |value| value.parent,
            else => null,
        };
        if (actual == null or !actual.?.eql(wanted)) return false;
    }
    return true;
}

fn cloneBytes(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn cloneExtension(allocator: std.mem.Allocator, value: Extension) !Extension {
    return .{
        .namespace = try allocator.dupe(u8, value.namespace),
        .name = try allocator.dupe(u8, value.name),
        .format = value.format,
        .value = try allocator.dupe(u8, value.value),
    };
}

fn cloneExtensions(allocator: std.mem.Allocator, values: []const Extension) ![]const Extension {
    const result = try allocator.alloc(Extension, values.len);
    for (values, 0..) |value, index| result[index] = try cloneExtension(allocator, value);
    return result;
}

fn cloneId(allocator: std.mem.Allocator, value: OpaqueId) !OpaqueId {
    return .{ .provider = try allocator.dupe(u8, value.provider), .value = try allocator.dupe(u8, value.value) };
}

fn cloneIds(allocator: std.mem.Allocator, values: []const OpaqueId) ![]const OpaqueId {
    const result = try allocator.alloc(OpaqueId, values.len);
    for (values, 0..) |value, index| result[index] = try cloneId(allocator, value);
    return result;
}

fn cloneActor(allocator: std.mem.Allocator, value: Actor) !Actor {
    return .{
        .id = try cloneId(allocator, value.id),
        .login = try allocator.dupe(u8, value.login),
        .display_name = try allocator.dupe(u8, value.display_name),
        .extensions = try cloneExtensions(allocator, value.extensions),
    };
}

fn cloneRepository(allocator: std.mem.Allocator, value: RepositoryIdentity) !RepositoryIdentity {
    return .{
        .vcs = try allocator.dupe(u8, value.vcs),
        .repository = try allocator.dupe(u8, value.repository),
        .extensions = try cloneExtensions(allocator, value.extensions),
    };
}

fn cloneRevision(allocator: std.mem.Allocator, value: RevisionIdentity) !RevisionIdentity {
    return .{
        .vcs = try allocator.dupe(u8, value.vcs),
        .repository = try allocator.dupe(u8, value.repository),
        .revision = try allocator.dupe(u8, value.revision),
        .extensions = try cloneExtensions(allocator, value.extensions),
    };
}

fn cloneValue(allocator: std.mem.Allocator, value: ResourceValue) !ResourceValue {
    return switch (value) {
        .issue => |v| .{ .issue = .{
            .title = try allocator.dupe(u8, v.title),
            .body = try allocator.dupe(u8, v.body),
            .state = v.state,
            .labels = try cloneIds(allocator, v.labels),
            .milestone = if (v.milestone) |id| try cloneId(allocator, id) else null,
            .assignees = try cloneIds(allocator, v.assignees),
        } },
        .change_request => |v| .{ .change_request = .{
            .title = try allocator.dupe(u8, v.title),
            .body = try allocator.dupe(u8, v.body),
            .state = v.state,
            .source_repository = try cloneRepository(allocator, v.source_repository),
            .source = try cloneRevision(allocator, v.source),
            .target = try cloneRevision(allocator, v.target),
            .labels = try cloneIds(allocator, v.labels),
            .milestone = if (v.milestone) |id| try cloneId(allocator, id) else null,
        } },
        .review => |v| .{ .review = .{
            .change_request = try cloneId(allocator, v.change_request),
            .body = try allocator.dupe(u8, v.body),
            .verdict = v.verdict,
            .revision = if (v.revision) |revision| try cloneRevision(allocator, revision) else null,
        } },
        .comment => |v| .{ .comment = .{
            .parent_kind = v.parent_kind,
            .parent = try cloneId(allocator, v.parent),
            .body = try allocator.dupe(u8, v.body),
            .revision = if (v.revision) |revision| try cloneRevision(allocator, revision) else null,
            .path = try cloneBytes(allocator, v.path),
            .line = v.line,
        } },
        .fork => |v| .{ .fork = .{
            .source = try cloneRepository(allocator, v.source),
            .destination = try cloneRepository(allocator, v.destination),
            .state = v.state,
        } },
        .check => |v| .{ .check = .{
            .name = try allocator.dupe(u8, v.name),
            .revision = try cloneRevision(allocator, v.revision),
            .state = v.state,
            .summary = try allocator.dupe(u8, v.summary),
            .details_url = try cloneBytes(allocator, v.details_url),
        } },
        .release => |v| blk: {
            const assets = try allocator.alloc(ReleaseAsset, v.assets.len);
            for (v.assets, 0..) |asset, index| assets[index] = .{
                .name = try allocator.dupe(u8, asset.name),
                .media_type = try allocator.dupe(u8, asset.media_type),
                .size = asset.size,
                .digest = try allocator.dupe(u8, asset.digest),
                .download_url = try cloneBytes(allocator, asset.download_url),
                .extensions = try cloneExtensions(allocator, asset.extensions),
            };
            break :blk .{ .release = .{
                .name = try allocator.dupe(u8, v.name),
                .body = try allocator.dupe(u8, v.body),
                .revision = try cloneRevision(allocator, v.revision),
                .state = v.state,
                .assets = assets,
            } };
        },
        .label => |v| .{ .label = .{
            .name = try allocator.dupe(u8, v.name),
            .color = try allocator.dupe(u8, v.color),
            .description = try allocator.dupe(u8, v.description),
        } },
        .milestone => |v| .{ .milestone = .{
            .title = try allocator.dupe(u8, v.title),
            .description = try allocator.dupe(u8, v.description),
            .state = v.state,
            .due_at = v.due_at,
        } },
    };
}

fn cloneResource(allocator: std.mem.Allocator, value: Resource) !Resource {
    return .{
        .id = try cloneId(allocator, value.id),
        .version = try allocator.dupe(u8, value.version),
        .created_at = value.created_at,
        .updated_at = value.updated_at,
        .author = if (value.author) |actor| try cloneActor(allocator, actor) else null,
        .extensions = try cloneExtensions(allocator, value.extensions),
        .value = try cloneValue(allocator, value.value),
    };
}

test "capability discovery explicitly reports every resource operation" {
    var memory = MemoryDriver.init(std.testing.allocator, "memory", .custom);
    defer memory.deinit();
    var handle = try memory.driver().discover(std.testing.allocator, .{ .vcs = "sdt", .repository = "r" });
    defer handle.deinit();
    const discovery = handle.response.discovery;
    try std.testing.expectEqual(contract_version, discovery.contract);
    inline for (std.meta.tags(ResourceKind)) |kind| {
        try std.testing.expectEqual(Support.native, discovery.capabilities.supports(kind, .create));
        try std.testing.expectEqual(Support.native, discovery.capabilities.supports(kind, .get));
        try std.testing.expectEqual(Support.native, discovery.capabilities.supports(kind, .update));
        try std.testing.expectEqual(Support.native, discovery.capabilities.supports(kind, .delete));
        try std.testing.expectEqual(Support.native, discovery.capabilities.supports(kind, .list));
    }
    try std.testing.expectEqual(Support.unsupported, discovery.capabilities.federation);
}

test "memory driver conforms to create get update list delete and preserves extensions" {
    var memory = MemoryDriver.init(std.testing.allocator, "forge", .rest);
    defer memory.deinit();
    const driver_value = memory.driver();
    const repository = RepositoryIdentity{ .vcs = "superdetermine", .repository = "native-repository-id" };
    const extension = Extension{ .namespace = "provider.example", .name = "opaque", .format = .bytes, .value = &.{ 0, 1, 255 } };
    var created = try driver_value.create(std.testing.allocator, .{
        .repository = repository,
        .idempotency_key = "create-1",
        .draft = .{
            .extensions = &.{extension},
            .value = .{ .issue = .{ .title = "First", .body = "Body", .state = .open } },
        },
    });
    defer created.deinit();
    const first = created.response.item;
    try std.testing.expectEqual(ResourceKind.issue, first.kind());
    try std.testing.expectEqualSlices(u8, extension.value, first.extensions[0].value);
    var duplicate = try driver_value.create(std.testing.allocator, .{
        .repository = repository,
        .idempotency_key = "create-1",
        .draft = .{ .value = .{ .issue = .{ .title = "Ignored", .body = "", .state = .open } } },
    });
    defer duplicate.deinit();
    try std.testing.expect(first.id.eql(duplicate.response.item.id));
    var fetched = try driver_value.get(std.testing.allocator, .{ .repository = repository, .kind = .issue, .id = first.id });
    defer fetched.deinit();
    try std.testing.expectEqualStrings("First", fetched.response.item.value.issue.title);
    var updated = try driver_value.update(std.testing.allocator, .{
        .repository = repository,
        .id = first.id,
        .expected_version = first.version,
        .replacement = .{ .extensions = &.{extension}, .value = .{ .issue = .{ .title = "Second", .body = "Body", .state = .closed } } },
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("2", updated.response.item.version);
    var page = try driver_value.list(std.testing.allocator, .{ .repository = repository, .kind = .issue, .state = .closed, .limit = 1 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.response.page.items.len);
    var deleted = try driver_value.delete(std.testing.allocator, .{ .repository = repository, .kind = .issue, .id = first.id, .expected_version = "2" });
    defer deleted.deinit();
    try std.testing.expect(deleted.response.deleted.eql(first.id));
    var missing = try driver_value.get(std.testing.allocator, .{ .repository = repository, .kind = .issue, .id = first.id });
    defer missing.deinit();
    try std.testing.expectEqual(FailureCode.not_found, missing.response.failure.code);
}

test "change requests retain native revisions without git identities" {
    var memory = MemoryDriver.init(std.testing.allocator, "forge", .graphql);
    defer memory.deinit();
    const repository = RepositoryIdentity{ .vcs = "sdt", .repository = "repo-quantum" };
    const source = RevisionIdentity{ .vcs = "sdt", .repository = "repo-quantum", .revision = "@green" };
    const target = RevisionIdentity{ .vcs = "sdt", .repository = "repo-quantum", .revision = "moment:9f01" };
    var result = try memory.driver().create(std.testing.allocator, .{
        .repository = repository,
        .draft = .{ .value = .{ .change_request = .{
            .title = "Native change",
            .body = "",
            .state = .open,
            .source_repository = repository,
            .source = source,
            .target = target,
        } } },
    });
    defer result.deinit();
    const change = result.response.item.value.change_request;
    try std.testing.expectEqualStrings("sdt", change.source.vcs);
    try std.testing.expectEqualStrings("@green", change.source.revision);
    try std.testing.expectEqualStrings("moment:9f01", change.target.revision);
}

test "pagination uses stable opaque cursor values" {
    var memory = MemoryDriver.init(std.testing.allocator, "forge", .rest);
    defer memory.deinit();
    const repository = RepositoryIdentity{ .vcs = "custom", .repository = "r" };
    for (0..3) |index| {
        var result = try memory.driver().create(std.testing.allocator, .{
            .repository = repository,
            .draft = .{ .value = .{ .label = .{
                .name = if (index == 0) "a" else if (index == 1) "b" else "c",
                .color = "ffffff",
                .description = "",
            } } },
        });
        result.deinit();
    }
    var first = try memory.driver().list(std.testing.allocator, .{ .repository = repository, .kind = .label, .limit = 2 });
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.response.page.items.len);
    try std.testing.expect(first.response.page.next_cursor != null);
    var second = try memory.driver().list(std.testing.allocator, .{ .repository = repository, .kind = .label, .limit = 2, .cursor = first.response.page.next_cursor });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.response.page.items.len);
    try std.testing.expect(second.response.page.next_cursor == null);
}
