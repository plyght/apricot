const std = @import("std");
const carrier = @import("carrier.zig");
const collaboration = @import("collaboration.zig");

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 1;

pub const Status = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    incompatible_abi = 2,
    out_of_memory = 3,
    cancelled = 4,
    unsupported = 5,
    corrupt_data = 6,
    callback_failed = 7,
    invalid_state = 8,
    internal = 9,
};

pub const OperationKind = enum(u32) {
    publish = 1,
    fetch = 2,
    verify = 3,
    custom = 255,
    _,
};

pub const OperationState = enum(u32) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    cancelled = 4,
};

pub const Bytes = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    fn slice(self: Bytes) ?[]const u8 {
        if (self.len == 0) return &.{};
        const ptr = self.ptr orelse return null;
        return ptr[0..self.len];
    }
};

pub const ReleaseFn = *const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) void;

pub const OwnedBytes = extern struct {
    bytes: Bytes,
    release: ?ReleaseFn,
    user_data: ?*anyopaque,
};

pub const HttpRequest = extern struct {
    method: Bytes,
    url: Bytes,
    headers: Bytes,
    body: Bytes,
};

pub const HttpResponse = extern struct {
    status_code: u16,
    reserved: u16,
    headers: OwnedBytes,
    body: OwnedBytes,
};

pub const HttpFn = *const fn (?*anyopaque, *const HttpRequest, *HttpResponse) callconv(.c) u32;
pub const CredentialsFn = *const fn (?*anyopaque, Bytes, *OwnedBytes) callconv(.c) u32;
pub const ProgressFn = *const fn (?*anyopaque, u32, Bytes, u64, u64) callconv(.c) void;
pub const CancelFn = *const fn (?*anyopaque) callconv(.c) u8;
pub const LogFn = *const fn (?*anyopaque, u32, Bytes) callconv(.c) void;

pub const OpaqueId = extern struct {
    provider: Bytes,
    value: Bytes,
};

pub const OwnedOpaqueId = extern struct {
    provider: OwnedBytes,
    value: OwnedBytes,
};

pub const CollaborationOperations = extern struct {
    create: u8,
    get: u8,
    update: u8,
    delete_resource: u8,
    list: u8,
    reserved: [3]u8,
};

pub const CollaborationCapability = extern struct {
    resource_kind: u32,
    operations: CollaborationOperations,
};

pub const CapabilitiesReleaseFn = *const fn (?*anyopaque, ?[*]const CollaborationCapability, usize) callconv(.c) void;

pub const OwnedCapabilities = extern struct {
    ptr: ?[*]const CollaborationCapability,
    len: usize,
    release: ?CapabilitiesReleaseFn,
    user_data: ?*anyopaque,
};

pub const CollaborationRequest = extern struct {
    struct_size: u32,
    contract_version: u32,
    operation: u32,
    resource_kind: u32,
    repository_vcs: Bytes,
    repository: Bytes,
    id: OpaqueId,
    cursor: Bytes,
    limit: u32,
    flags: u32,
    content_type: Bytes,
    payload: Bytes,
    extensions: Bytes,
};

pub const CollaborationCallbackResponse = extern struct {
    struct_size: u32,
    response_kind: u32,
    resource_kind: u32,
    failure_code: u32,
    id: OwnedOpaqueId,
    version: OwnedBytes,
    content_type: OwnedBytes,
    payload: OwnedBytes,
    extensions: OwnedBytes,
    next_cursor: OwnedBytes,
    total: u64,
    retry_after_seconds: u64,
    has_total: u8,
    has_retry_after: u8,
    retryable: u8,
    pagination: u8,
    conditional_updates: u8,
    idempotent_creates: u8,
    federation: u8,
    reserved: u8,
    provider: OwnedBytes,
    protocol_family: OwnedBytes,
    capabilities: OwnedCapabilities,
    error_message: OwnedBytes,
    provider_code: OwnedBytes,
};

pub const CollaborationResponse = extern struct {
    response_kind: u32,
    resource_kind: u32,
    failure_code: u32,
    id: OpaqueId,
    version: Bytes,
    content_type: Bytes,
    payload: Bytes,
    extensions: Bytes,
    next_cursor: Bytes,
    total: u64,
    retry_after_seconds: u64,
    has_total: u8,
    has_retry_after: u8,
    retryable: u8,
    pagination: u8,
    conditional_updates: u8,
    idempotent_creates: u8,
    federation: u8,
    reserved: u8,
    provider: Bytes,
    protocol_family: Bytes,
    capabilities: ?[*]const CollaborationCapability,
    capabilities_len: usize,
    error_message: Bytes,
    provider_code: Bytes,
};

pub const CollaborationFn = *const fn (?*anyopaque, *const CollaborationRequest, *CollaborationCallbackResponse) callconv(.c) u32;

pub const ContextOptions = extern struct {
    struct_size: u32,
    abi_major: u32,
    abi_minor: u32,
    flags: u32,
    user_data: ?*anyopaque,
    http: ?HttpFn,
    credentials: ?CredentialsFn,
    progress: ?ProgressFn,
    cancel: ?CancelFn,
    log: ?LogFn,
    collaboration: ?CollaborationFn,
};

const Callbacks = struct {
    user_data: ?*anyopaque,
    http: ?HttpFn,
    credentials: ?CredentialsFn,
    progress: ?ProgressFn,
    cancel: ?CancelFn,
    log: ?LogFn,
    collaboration: ?CollaborationFn,
};

const ContextImpl = struct {
    callbacks: Callbacks,
};

const OperationImpl = struct {
    callbacks: Callbacks,
    kind: u32,
    state: OperationState,
    status: Status,
    request: []u8,
    result: []u8,
    message: []u8,
};

pub const Context = opaque {};
pub const Operation = opaque {};
pub const Collaboration = opaque {};

const CollaborationImpl = struct {
    arena: std.heap.ArenaAllocator,
    callbacks: Callbacks,
    request: CollaborationRequest,
    state: OperationState,
    status: Status,
    callback_response: CollaborationCallbackResponse,
    response: CollaborationResponse,
    has_response: bool,
};

const allocator = std.heap.page_allocator;

fn statusCode(status: Status) u32 {
    return @intFromEnum(status);
}

fn statusFromCode(status: u32) Status {
    return switch (status) {
        0 => .ok,
        1 => .invalid_argument,
        2 => .incompatible_abi,
        3 => .out_of_memory,
        4 => .cancelled,
        5 => .unsupported,
        6 => .corrupt_data,
        7 => .callback_failed,
        8 => .invalid_state,
        else => .internal,
    };
}

fn contextImpl(context: *Context) *ContextImpl {
    return @ptrCast(@alignCast(context));
}

fn operationImpl(operation: *Operation) *OperationImpl {
    return @ptrCast(@alignCast(operation));
}

fn constOperationImpl(operation: *const Operation) *const OperationImpl {
    return @ptrCast(@alignCast(operation));
}

fn collaborationImpl(handle: *Collaboration) *CollaborationImpl {
    return @ptrCast(@alignCast(handle));
}

fn constCollaborationImpl(handle: *const Collaboration) *const CollaborationImpl {
    return @ptrCast(@alignCast(handle));
}

fn emptyBytes() Bytes {
    return .{ .ptr = null, .len = 0 };
}

fn borrowed(bytes: []const u8) Bytes {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn replaceOwned(target: *[]u8, source: []const u8) Status {
    const replacement = allocator.dupe(u8, source) catch return .out_of_memory;
    allocator.free(target.*);
    target.* = replacement;
    return .ok;
}

fn ownedSlice(bytes: OwnedBytes) ?[]const u8 {
    return bytes.bytes.slice();
}

fn releaseOwned(bytes: *OwnedBytes) void {
    if (bytes.release) |release| release(bytes.user_data, bytes.bytes.ptr, bytes.bytes.len);
    bytes.* = std.mem.zeroes(OwnedBytes);
}

fn releaseCallbackResponse(response: *CollaborationCallbackResponse) void {
    releaseOwned(&response.id.provider);
    releaseOwned(&response.id.value);
    releaseOwned(&response.version);
    releaseOwned(&response.content_type);
    releaseOwned(&response.payload);
    releaseOwned(&response.extensions);
    releaseOwned(&response.next_cursor);
    releaseOwned(&response.provider);
    releaseOwned(&response.protocol_family);
    if (response.capabilities.release) |release| release(response.capabilities.user_data, response.capabilities.ptr, response.capabilities.len);
    response.capabilities = std.mem.zeroes(OwnedCapabilities);
    releaseOwned(&response.error_message);
    releaseOwned(&response.provider_code);
}

fn validSupport(value: u8) bool {
    return value <= 2;
}

fn validateCapabilities(value: OwnedCapabilities) bool {
    if (value.len != 0 and value.ptr == null) return false;
    const items = if (value.len == 0) &.{} else value.ptr.?[0..value.len];
    for (items) |item| {
        if (item.resource_kind < 1 or item.resource_kind > 9) return false;
        const operations = item.operations;
        if (!validSupport(operations.create) or !validSupport(operations.get) or !validSupport(operations.update) or !validSupport(operations.delete_resource) or !validSupport(operations.list)) return false;
    }
    return true;
}

fn validateCallbackResponse(value: CollaborationCallbackResponse) bool {
    if (value.struct_size < @sizeOf(CollaborationCallbackResponse)) return false;
    if (value.response_kind < 1 or value.response_kind > 5) return false;
    if (value.resource_kind > 9 or value.failure_code > 10) return false;
    if (value.has_total > 1 or value.has_retry_after > 1 or value.retryable > 1) return false;
    if (value.response_kind == 1 and value.resource_kind != 0) return false;
    if (value.response_kind >= 2 and value.response_kind <= 4 and (value.resource_kind < 1 or value.resource_kind > 9)) return false;
    if (value.response_kind == 5 and (value.failure_code < 1 or value.failure_code > 10)) return false;
    if (value.response_kind != 5 and value.failure_code != 0) return false;
    if (!validSupport(value.pagination) or !validSupport(value.conditional_updates) or !validSupport(value.idempotent_creates) or !validSupport(value.federation)) return false;
    const fields = [_]OwnedBytes{
        value.id.provider,
        value.id.value,
        value.version,
        value.content_type,
        value.payload,
        value.extensions,
        value.next_cursor,
        value.provider,
        value.protocol_family,
        value.error_message,
        value.provider_code,
    };
    for (fields) |field| if (ownedSlice(field) == null) return false;
    return validateCapabilities(value.capabilities);
}

fn copyCallbackResponse(a: std.mem.Allocator, value: CollaborationCallbackResponse) !CollaborationResponse {
    const capability_items = if (value.capabilities.len == 0) &.{} else value.capabilities.ptr.?[0..value.capabilities.len];
    const capabilities = try a.dupe(CollaborationCapability, capability_items);
    return .{
        .response_kind = value.response_kind,
        .resource_kind = value.resource_kind,
        .failure_code = value.failure_code,
        .id = .{ .provider = try copyBytes(a, value.id.provider.bytes), .value = try copyBytes(a, value.id.value.bytes) },
        .version = try copyBytes(a, value.version.bytes),
        .content_type = try copyBytes(a, value.content_type.bytes),
        .payload = try copyBytes(a, value.payload.bytes),
        .extensions = try copyBytes(a, value.extensions.bytes),
        .next_cursor = try copyBytes(a, value.next_cursor.bytes),
        .total = value.total,
        .retry_after_seconds = value.retry_after_seconds,
        .has_total = value.has_total,
        .has_retry_after = value.has_retry_after,
        .retryable = value.retryable,
        .pagination = value.pagination,
        .conditional_updates = value.conditional_updates,
        .idempotent_creates = value.idempotent_creates,
        .federation = value.federation,
        .reserved = 0,
        .provider = try copyBytes(a, value.provider.bytes),
        .protocol_family = try copyBytes(a, value.protocol_family.bytes),
        .capabilities = if (capabilities.len == 0) null else capabilities.ptr,
        .capabilities_len = capabilities.len,
        .error_message = try copyBytes(a, value.error_message.bytes),
        .provider_code = try copyBytes(a, value.provider_code.bytes),
    };
}

fn makeOperation(context: *Context, kind: u32, request: Bytes, output: *?*Operation) Status {
    output.* = null;
    const request_slice = request.slice() orelse return .invalid_argument;
    const owned_request = allocator.dupe(u8, request_slice) catch return .out_of_memory;
    errdefer allocator.free(owned_request);
    const operation = allocator.create(OperationImpl) catch return .out_of_memory;
    operation.* = .{
        .callbacks = contextImpl(context).callbacks,
        .kind = kind,
        .state = .pending,
        .status = .ok,
        .request = owned_request,
        .result = &.{},
        .message = &.{},
    };
    output.* = @ptrCast(operation);
    return .ok;
}

pub export fn apricot_abi_version() callconv(.c) u32 {
    return (abi_major << 16) | abi_minor;
}

pub export fn apricot_abi_negotiate(requested_major: u32, minimum_minor: u32, negotiated_minor: ?*u32) callconv(.c) u32 {
    const output = negotiated_minor orelse return statusCode(.invalid_argument);
    output.* = 0;
    if (requested_major != abi_major or minimum_minor > abi_minor) return statusCode(.incompatible_abi);
    output.* = abi_minor;
    return statusCode(.ok);
}

pub export fn apricot_context_create(options: ?*const ContextOptions, output: ?*?*Context) callconv(.c) u32 {
    const config = options orelse return statusCode(.invalid_argument);
    const result = output orelse return statusCode(.invalid_argument);
    result.* = null;
    if (config.struct_size < @offsetOf(ContextOptions, "collaboration")) return statusCode(.invalid_argument);
    if (config.abi_major != abi_major or config.abi_minor > abi_minor) return statusCode(.incompatible_abi);
    if (config.flags != 0) return statusCode(.unsupported);
    const context = allocator.create(ContextImpl) catch return statusCode(.out_of_memory);
    context.* = .{ .callbacks = .{
        .user_data = config.user_data,
        .http = config.http,
        .credentials = config.credentials,
        .progress = config.progress,
        .cancel = config.cancel,
        .log = config.log,
        .collaboration = if (config.struct_size >= @sizeOf(ContextOptions)) config.collaboration else null,
    } };
    result.* = @ptrCast(context);
    return statusCode(.ok);
}

pub export fn apricot_context_free(context: ?*Context) callconv(.c) void {
    if (context) |value| allocator.destroy(contextImpl(value));
}

pub export fn apricot_operation_create(context: ?*Context, kind: u32, request: Bytes, output: ?*?*Operation) callconv(.c) u32 {
    const owner = context orelse return statusCode(.invalid_argument);
    const result = output orelse return statusCode(.invalid_argument);
    return statusCode(makeOperation(owner, kind, request, result));
}

pub export fn apricot_operation_free(operation: ?*Operation) callconv(.c) void {
    const handle = operation orelse return;
    const value = operationImpl(handle);
    allocator.free(value.message);
    allocator.free(value.result);
    allocator.free(value.request);
    allocator.destroy(value);
}

pub export fn apricot_operation_start(operation: ?*Operation) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .pending) return statusCode(.invalid_state);
    if (value.callbacks.cancel) |cancel| {
        if (cancel(value.callbacks.user_data) != 0) {
            value.state = .cancelled;
            value.status = .cancelled;
            return statusCode(.cancelled);
        }
    }
    value.state = .running;
    if (value.callbacks.progress) |progress| progress(value.callbacks.user_data, value.kind, borrowed("start"), 0, 0);
    return statusCode(.ok);
}

pub export fn apricot_operation_complete(operation: ?*Operation, result: Bytes) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    const source = result.slice() orelse return statusCode(.invalid_argument);
    const status = replaceOwned(&value.result, source);
    if (status != .ok) return statusCode(status);
    value.state = .completed;
    value.status = .ok;
    if (value.callbacks.progress) |progress| progress(value.callbacks.user_data, value.kind, borrowed("complete"), 1, 1);
    return statusCode(.ok);
}

pub export fn apricot_operation_fail(operation: ?*Operation, status: u32, message: Bytes) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    const source = message.slice() orelse return statusCode(.invalid_argument);
    const known = statusFromCode(status);
    if (known == .ok) return statusCode(.invalid_argument);
    const copied = replaceOwned(&value.message, source);
    if (copied != .ok) return statusCode(copied);
    value.status = known;
    value.state = if (known == .cancelled) .cancelled else .failed;
    return statusCode(.ok);
}

pub export fn apricot_operation_state(operation: ?*const Operation) callconv(.c) u32 {
    const value = operation orelse return @intFromEnum(OperationState.failed);
    return @intFromEnum(constOperationImpl(value).state);
}

pub export fn apricot_operation_status(operation: ?*const Operation) callconv(.c) u32 {
    const value = operation orelse return statusCode(.invalid_argument);
    return statusCode(constOperationImpl(value).status);
}

pub export fn apricot_operation_request(operation: ?*const Operation) callconv(.c) Bytes {
    const value = operation orelse return emptyBytes();
    return borrowed(constOperationImpl(value).request);
}

pub export fn apricot_operation_result(operation: ?*const Operation) callconv(.c) Bytes {
    const value = operation orelse return emptyBytes();
    return borrowed(constOperationImpl(value).result);
}

pub export fn apricot_operation_error(operation: ?*const Operation) callconv(.c) Bytes {
    const value = operation orelse return emptyBytes();
    return borrowed(constOperationImpl(value).message);
}

pub export fn apricot_operation_is_cancelled(operation: ?*Operation) callconv(.c) u8 {
    const value = operationImpl(operation orelse return 1);
    if (value.state == .cancelled) return 1;
    if (value.callbacks.cancel) |cancel| {
        if (cancel(value.callbacks.user_data) != 0) {
            value.state = .cancelled;
            value.status = .cancelled;
            return 1;
        }
    }
    return 0;
}

pub export fn apricot_operation_http(operation: ?*Operation, request: ?*const HttpRequest, response: ?*HttpResponse) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    const input = request orelse return statusCode(.invalid_argument);
    const output = response orelse return statusCode(.invalid_argument);
    output.* = std.mem.zeroes(HttpResponse);
    const callback = value.callbacks.http orelse return statusCode(.unsupported);
    return callback(value.callbacks.user_data, input, output);
}

pub export fn apricot_operation_credentials(operation: ?*Operation, scope: Bytes, credentials: ?*OwnedBytes) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    if (scope.slice() == null) return statusCode(.invalid_argument);
    const output = credentials orelse return statusCode(.invalid_argument);
    output.* = std.mem.zeroes(OwnedBytes);
    const callback = value.callbacks.credentials orelse return statusCode(.unsupported);
    return callback(value.callbacks.user_data, scope, output);
}

pub export fn apricot_operation_progress(operation: ?*Operation, phase: Bytes, completed: u64, total: u64) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    if (phase.slice() == null or (total != 0 and completed > total)) return statusCode(.invalid_argument);
    if (value.callbacks.progress) |progress| progress(value.callbacks.user_data, value.kind, phase, completed, total);
    return statusCode(.ok);
}

pub export fn apricot_operation_log(operation: ?*Operation, level: u32, message: Bytes) callconv(.c) u32 {
    const value = operationImpl(operation orelse return statusCode(.invalid_argument));
    if (value.state != .running) return statusCode(.invalid_state);
    if (message.slice() == null or level < 1 or level > 4) return statusCode(.invalid_argument);
    if (value.callbacks.log) |log| log(value.callbacks.user_data, level, message);
    return statusCode(.ok);
}

pub export fn apricot_verify_carrier(context: ?*Context, expected_root: Bytes, encoded: Bytes, output: ?*?*Operation) callconv(.c) u32 {
    const owner = context orelse return statusCode(.invalid_argument);
    const result = output orelse return statusCode(.invalid_argument);
    const root_bytes = expected_root.slice() orelse return statusCode(.invalid_argument);
    const carrier_bytes = encoded.slice() orelse return statusCode(.invalid_argument);
    if (root_bytes.len != 32) return statusCode(.invalid_argument);
    var handle: ?*Operation = null;
    const created = makeOperation(owner, @intFromEnum(OperationKind.verify), encoded, &handle);
    if (created != .ok) return statusCode(created);
    result.* = handle;
    const operation = handle.?;
    const started = apricot_operation_start(operation);
    if (started != statusCode(.ok)) return started;
    var expected: carrier.ContentId = undefined;
    @memcpy(&expected.bytes, root_bytes);
    carrier.verifyEncoded(expected, carrier_bytes, .{}) catch {
        _ = apricot_operation_fail(operation, statusCode(.corrupt_data), borrowed("carrier verification failed"));
        return statusCode(.corrupt_data);
    };
    return apricot_operation_complete(operation, expected_root);
}

pub export fn apricot_owned_bytes_release(bytes: ?*OwnedBytes) callconv(.c) void {
    const value = bytes orelse return;
    releaseOwned(value);
}

fn copyBytes(a: std.mem.Allocator, value: Bytes) !Bytes {
    const source = value.slice() orelse return error.InvalidArgument;
    return borrowed(try a.dupe(u8, source));
}

fn copyOpaqueId(a: std.mem.Allocator, value: OpaqueId) !OpaqueId {
    return .{ .provider = try copyBytes(a, value.provider), .value = try copyBytes(a, value.value) };
}

fn copyCollaborationRequest(a: std.mem.Allocator, input: CollaborationRequest) !CollaborationRequest {
    return .{
        .struct_size = @sizeOf(CollaborationRequest),
        .contract_version = input.contract_version,
        .operation = input.operation,
        .resource_kind = input.resource_kind,
        .repository_vcs = try copyBytes(a, input.repository_vcs),
        .repository = try copyBytes(a, input.repository),
        .id = try copyOpaqueId(a, input.id),
        .cursor = try copyBytes(a, input.cursor),
        .limit = input.limit,
        .flags = 0,
        .content_type = try copyBytes(a, input.content_type),
        .payload = try copyBytes(a, input.payload),
        .extensions = try copyBytes(a, input.extensions),
    };
}

pub export fn apricot_collaboration_create(context: ?*Context, request: ?*const CollaborationRequest, output: ?*?*Collaboration) callconv(.c) u32 {
    const owner = context orelse return statusCode(.invalid_argument);
    const input = request orelse return statusCode(.invalid_argument);
    const result = output orelse return statusCode(.invalid_argument);
    result.* = null;
    if (input.struct_size < @sizeOf(CollaborationRequest)) return statusCode(.invalid_argument);
    if (input.contract_version != collaboration.contract_version or input.flags != 0) return statusCode(.unsupported);
    if (input.operation > 5) return statusCode(.invalid_argument);
    if ((input.operation == 0 and input.resource_kind != 0) or (input.operation != 0 and (input.resource_kind < 1 or input.resource_kind > 9))) return statusCode(.invalid_argument);
    if (input.operation == 5 and (input.limit == 0 or input.limit > 1000)) return statusCode(.invalid_argument);
    const value = allocator.create(CollaborationImpl) catch return statusCode(.out_of_memory);
    value.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .callbacks = contextImpl(owner).callbacks,
        .request = undefined,
        .state = .pending,
        .status = .ok,
        .callback_response = std.mem.zeroes(CollaborationCallbackResponse),
        .response = std.mem.zeroes(CollaborationResponse),
        .has_response = false,
    };
    errdefer {
        value.arena.deinit();
        allocator.destroy(value);
    }
    const a = value.arena.allocator();
    value.request = copyCollaborationRequest(a, input.*) catch |err| return statusCode(if (err == error.OutOfMemory) .out_of_memory else .invalid_argument);
    result.* = @ptrCast(value);
    return statusCode(.ok);
}

pub export fn apricot_collaboration_execute(handle: ?*Collaboration) callconv(.c) u32 {
    const value = collaborationImpl(handle orelse return statusCode(.invalid_argument));
    if (value.state != .pending) return statusCode(.invalid_state);
    if (value.callbacks.cancel) |cancel| {
        if (cancel(value.callbacks.user_data) != 0) {
            value.state = .cancelled;
            value.status = .cancelled;
            return statusCode(.cancelled);
        }
    }
    const callback = value.callbacks.collaboration orelse {
        value.state = .failed;
        value.status = .unsupported;
        return statusCode(.unsupported);
    };
    value.state = .running;
    value.callback_response = std.mem.zeroes(CollaborationCallbackResponse);
    value.callback_response.struct_size = @sizeOf(CollaborationCallbackResponse);
    const callback_status = callback(value.callbacks.user_data, &value.request, &value.callback_response);
    if (callback_status != statusCode(.ok)) {
        releaseCallbackResponse(&value.callback_response);
        value.status = statusFromCode(callback_status);
        if (value.status == .ok) value.status = .callback_failed;
        value.state = if (value.status == .cancelled) .cancelled else .failed;
        return statusCode(value.status);
    }
    if (!validateCallbackResponse(value.callback_response)) {
        releaseCallbackResponse(&value.callback_response);
        value.status = .callback_failed;
        value.state = .failed;
        return statusCode(.callback_failed);
    }
    value.response = copyCallbackResponse(value.arena.allocator(), value.callback_response) catch {
        releaseCallbackResponse(&value.callback_response);
        value.status = .out_of_memory;
        value.state = .failed;
        return statusCode(.out_of_memory);
    };
    releaseCallbackResponse(&value.callback_response);
    value.has_response = true;
    value.status = .ok;
    value.state = .completed;
    return statusCode(.ok);
}

pub export fn apricot_collaboration_state(handle: ?*const Collaboration) callconv(.c) u32 {
    const value = handle orelse return @intFromEnum(OperationState.failed);
    return @intFromEnum(constCollaborationImpl(value).state);
}

pub export fn apricot_collaboration_status(handle: ?*const Collaboration) callconv(.c) u32 {
    const value = handle orelse return statusCode(.invalid_argument);
    return statusCode(constCollaborationImpl(value).status);
}

pub export fn apricot_collaboration_response_get(handle: ?*const Collaboration) callconv(.c) ?*const CollaborationResponse {
    const value = constCollaborationImpl(handle orelse return null);
    if (!value.has_response or value.state != .completed) return null;
    return &value.response;
}

pub export fn apricot_collaboration_free(handle: ?*Collaboration) callconv(.c) void {
    const value = collaborationImpl(handle orelse return);
    value.arena.deinit();
    allocator.destroy(value);
}

test "C ABI layouts are stable" {
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(Bytes));
    try std.testing.expect(@offsetOf(ContextOptions, "user_data") >= 16);
    try std.testing.expectEqual(@sizeOf(?*anyopaque), @sizeOf(?*Context));
    try std.testing.expectEqual(@sizeOf(?*anyopaque), @sizeOf(?*Operation));
    try std.testing.expectEqual(@as(u32, 0x0001_0001), apricot_abi_version());
}

test "operation lifecycle owns request and result" {
    var options = std.mem.zeroes(ContextOptions);
    options.struct_size = @sizeOf(ContextOptions);
    options.abi_major = abi_major;
    options.abi_minor = abi_minor;
    var context: ?*Context = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_context_create(&options, &context));
    defer apricot_context_free(context);
    var request = [_]u8{ 1, 2, 3 };
    var operation: ?*Operation = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_create(context, @intFromEnum(OperationKind.publish), borrowed(&request), &operation));
    defer apricot_operation_free(operation);
    request[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, apricot_operation_request(operation).slice().?);
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_start(operation));
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_complete(operation, borrowed("done")));
    try std.testing.expectEqual(@intFromEnum(OperationState.completed), apricot_operation_state(operation));
    try std.testing.expectEqualSlices(u8, "done", apricot_operation_result(operation).slice().?);
}

test "ABI negotiation rejects incompatible versions" {
    var negotiated: u32 = 99;
    try std.testing.expectEqual(statusCode(.ok), apricot_abi_negotiate(abi_major, abi_minor, &negotiated));
    try std.testing.expectEqual(abi_minor, negotiated);
    try std.testing.expectEqual(statusCode(.incompatible_abi), apricot_abi_negotiate(abi_major + 1, 0, &negotiated));
}

test "carrier verification returns an owned operation" {
    const encoded = try carrier.encode(std.testing.allocator, .{
        .vcs = "test",
        .repository_id = "repository",
        .chunk_size = 1024,
        .objects = &.{},
        .refs = &.{},
        .projection_mappings = &.{},
    }, .{});
    defer encoded.deinit(std.testing.allocator);
    var options = std.mem.zeroes(ContextOptions);
    options.struct_size = @sizeOf(ContextOptions);
    options.abi_major = abi_major;
    options.abi_minor = abi_minor;
    var context: ?*Context = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_context_create(&options, &context));
    defer apricot_context_free(context);
    var operation: ?*Operation = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_verify_carrier(context, borrowed(&encoded.root.bytes), borrowed(encoded.bytes), &operation));
    defer apricot_operation_free(operation);
    try std.testing.expectEqual(@intFromEnum(OperationState.completed), apricot_operation_state(operation));
    try std.testing.expectEqualSlices(u8, &encoded.root.bytes, apricot_operation_result(operation).slice().?);
}

test "callbacks and owned bytes cross the ABI boundary" {
    const State = struct {
        progress_calls: usize = 0,
        releases: usize = 0,

        fn progress(user_data: ?*anyopaque, kind: u32, phase: Bytes, completed: u64, total: u64) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(user_data.?));
            state.progress_calls += 1;
            std.debug.assert(kind == @intFromEnum(OperationKind.fetch));
            std.debug.assert(phase.slice() != null);
            std.debug.assert(total == 0 or completed <= total);
        }

        fn credentials(user_data: ?*anyopaque, scope: Bytes, output: *OwnedBytes) callconv(.c) u32 {
            std.debug.assert(std.mem.eql(u8, scope.slice().?, "forge"));
            output.* = .{
                .bytes = borrowed("token"),
                .release = release,
                .user_data = user_data,
            };
            return statusCode(.ok);
        }

        fn release(user_data: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(user_data.?));
            state.releases += 1;
        }
    };
    var state = State{};
    var options = std.mem.zeroes(ContextOptions);
    options.struct_size = @sizeOf(ContextOptions);
    options.abi_major = abi_major;
    options.abi_minor = abi_minor;
    options.user_data = &state;
    options.progress = State.progress;
    options.credentials = State.credentials;
    var context: ?*Context = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_context_create(&options, &context));
    defer apricot_context_free(context);
    var operation: ?*Operation = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_create(context, @intFromEnum(OperationKind.fetch), emptyBytes(), &operation));
    defer apricot_operation_free(operation);
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_start(operation));
    var credentials = std.mem.zeroes(OwnedBytes);
    const scope = borrowed("forge");
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_credentials(operation, scope, &credentials));
    apricot_owned_bytes_release(&credentials);
    try std.testing.expectEqual(@as(usize, 1), state.releases);
    try std.testing.expectEqual(statusCode(.ok), apricot_operation_complete(operation, emptyBytes()));
    try std.testing.expectEqual(@as(usize, 2), state.progress_calls);
}

test "collaboration ABI discovers capabilities and preserves pagination extensions" {
    const State = struct {
        releases: usize = 0,

        const capability_values = [_]CollaborationCapability{.{
            .resource_kind = 1,
            .operations = .{ .create = 1, .get = 1, .update = 2, .delete_resource = 0, .list = 1, .reserved = .{ 0, 0, 0 } },
        }};
        const extension_value = [_]u8{ 0, 4, 0, 255 };

        fn owned(user_data: ?*anyopaque, bytes: []const u8) OwnedBytes {
            return .{ .bytes = borrowed(bytes), .release = releaseBytes, .user_data = user_data };
        }

        fn releaseBytes(user_data: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(user_data.?));
            state.releases += 1;
        }

        fn releaseCapabilities(user_data: ?*anyopaque, _: ?[*]const CollaborationCapability, _: usize) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(user_data.?));
            state.releases += 1;
        }

        fn invoke(user_data: ?*anyopaque, request: *const CollaborationRequest, response: *CollaborationCallbackResponse) callconv(.c) u32 {
            std.debug.assert(request.contract_version == collaboration.contract_version);
            response.* = std.mem.zeroes(CollaborationCallbackResponse);
            response.struct_size = @sizeOf(CollaborationCallbackResponse);
            if (request.operation == 0) {
                response.response_kind = 1;
                response.provider = owned(user_data, "forge");
                response.protocol_family = owned(user_data, "rest");
                response.pagination = 1;
                response.conditional_updates = 1;
                response.idempotent_creates = 2;
                response.capabilities = .{
                    .ptr = &capability_values,
                    .len = capability_values.len,
                    .release = releaseCapabilities,
                    .user_data = user_data,
                };
            } else {
                std.debug.assert(request.operation == 5);
                std.debug.assert(request.resource_kind == 1);
                std.debug.assert(std.mem.eql(u8, request.repository.slice().?, "repo-copy"));
                response.response_kind = 3;
                response.resource_kind = 1;
                response.extensions = owned(user_data, &extension_value);
                response.next_cursor = owned(user_data, "opaque-next");
                response.total = 42;
                response.has_total = 1;
            }
            return statusCode(.ok);
        }
    };
    var state = State{};
    var options = std.mem.zeroes(ContextOptions);
    options.struct_size = @sizeOf(ContextOptions);
    options.abi_major = abi_major;
    options.abi_minor = abi_minor;
    options.user_data = &state;
    options.collaboration = State.invoke;
    var context: ?*Context = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_context_create(&options, &context));
    defer apricot_context_free(context);

    var discover = std.mem.zeroes(CollaborationRequest);
    discover.struct_size = @sizeOf(CollaborationRequest);
    discover.contract_version = collaboration.contract_version;
    discover.repository_vcs = borrowed("sdt");
    discover.repository = borrowed("repo");
    var discovery_handle: ?*Collaboration = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_collaboration_create(context, &discover, &discovery_handle));
    defer apricot_collaboration_free(discovery_handle);
    try std.testing.expectEqual(statusCode(.ok), apricot_collaboration_execute(discovery_handle));
    const discovery = apricot_collaboration_response_get(discovery_handle).?;
    try std.testing.expectEqual(@as(u32, 1), discovery.response_kind);
    try std.testing.expectEqual(@as(usize, 1), discovery.capabilities_len);
    try std.testing.expectEqual(@as(u8, 2), discovery.capabilities.?[0].operations.update);

    var repository = [_]u8{ 'r', 'e', 'p', 'o', '-', 'c', 'o', 'p', 'y' };
    var list = std.mem.zeroes(CollaborationRequest);
    list.struct_size = @sizeOf(CollaborationRequest);
    list.contract_version = collaboration.contract_version;
    list.operation = 5;
    list.resource_kind = 1;
    list.repository_vcs = borrowed("sdt");
    list.repository = borrowed(&repository);
    list.limit = 50;
    var list_handle: ?*Collaboration = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_collaboration_create(context, &list, &list_handle));
    defer apricot_collaboration_free(list_handle);
    repository[0] = 'X';
    try std.testing.expectEqual(statusCode(.ok), apricot_collaboration_execute(list_handle));
    const page = apricot_collaboration_response_get(list_handle).?;
    try std.testing.expectEqualSlices(u8, &State.extension_value, page.extensions.slice().?);
    try std.testing.expectEqualSlices(u8, "opaque-next", page.next_cursor.slice().?);
    try std.testing.expectEqual(@as(u64, 42), page.total);
    try std.testing.expectEqual(@as(usize, 5), state.releases);
}

test "older context option size remains compatible" {
    const Legacy = struct {
        fn unexpected(_: ?*anyopaque, _: *const CollaborationRequest, _: *CollaborationCallbackResponse) callconv(.c) u32 {
            @panic("new callback read from legacy options");
        }
    };
    var options = std.mem.zeroes(ContextOptions);
    options.struct_size = @offsetOf(ContextOptions, "collaboration");
    options.abi_major = abi_major;
    options.abi_minor = 0;
    options.collaboration = Legacy.unexpected;
    var context: ?*Context = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_context_create(&options, &context));
    defer apricot_context_free(context);
    var request = std.mem.zeroes(CollaborationRequest);
    request.struct_size = @sizeOf(CollaborationRequest);
    request.contract_version = collaboration.contract_version;
    var handle: ?*Collaboration = null;
    try std.testing.expectEqual(statusCode(.ok), apricot_collaboration_create(context, &request, &handle));
    defer apricot_collaboration_free(handle);
    try std.testing.expectEqual(statusCode(.unsupported), apricot_collaboration_execute(handle));
}
