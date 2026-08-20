const std = @import("std");
const adapter_contract = @import("adapter.zig");
const carrier = @import("carrier.zig");
const forge = @import("git_forge.zig");
const git = @import("git_transport.zig");
const host_contract = @import("host.zig");

pub const api_version: u32 = 1;

pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

pub const version = Version{ .major = 0, .minor = 1, .patch = 0 };

pub const AdapterRegistration = struct {
    name: []const u8,
    contract_version: u32 = 1,
    implementation: adapter_contract.Adapter,
};

const RegisteredAdapter = struct {
    name: []u8,
    contract_version: u32,
    implementation: adapter_contract.Adapter,
};

pub const DiscoverRequest = struct {
    remote: []const u8,
};

pub const Discovery = struct {
    can_fetch: bool,
    can_publish: bool,
    supports_atomic_publish: bool,
    projection_ref_count: usize,
    has_native_carrier: bool,
};

pub const PublishRequest = struct {
    adapter_name: []const u8,
    remote: []const u8,
    branch: []const u8 = "main",
    repository_id: []const u8,
    signature: forge.Signature,
    timestamp: i64,
    carrier_limits: carrier.Limits = .{},
    git_limits: git.Limits = .{},
};

pub const PublishResult = struct {
    projection_commit: git.Oid,
    carrier_commit: git.Oid,
    carrier_root: carrier.ContentId,
};

pub const FetchRequest = struct {
    remote: []const u8,
    branch: []const u8 = "main",
    git_limits: git.Limits = .{},
};

pub const FetchResult = struct {
    projection_commit: git.Oid,
    carrier_root: carrier.ContentId,
    carrier_bytes: []u8,

    pub fn deinit(self: FetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.carrier_bytes);
    }
};

pub const VerifyRequest = struct {
    expected_root: carrier.ContentId,
    carrier_bytes: []const u8,
    limits: carrier.Limits = .{},
};

pub const VerifyResult = struct {
    vcs: []u8,
    repository_id: []u8,
    object_count: usize,
    ref_count: usize,

    pub fn deinit(self: VerifyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.vcs);
        allocator.free(self.repository_id);
    }
};

pub const MaterializeRequest = struct {
    expected_root: carrier.ContentId,
    carrier_bytes: []const u8,
    adapter_name: ?[]const u8 = null,
    required_tier: adapter_contract.PreservationTier = .byte_lossless,
    limits: carrier.Limits = .{},
};

pub const MaterializeResult = struct {
    vcs: []u8,
    verified_tier: adapter_contract.PreservationTier,
    restored_root_count: usize,
    restored_object_count: usize,

    pub fn deinit(self: MaterializeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.vcs);
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    host: host_contract.Host,
    adapters: std.ArrayList(RegisteredAdapter) = .empty,

    pub fn init(allocator: std.mem.Allocator, callbacks: host_contract.Callbacks) Engine {
        return .{
            .allocator = allocator,
            .host = .{ .allocator = allocator, .callbacks = callbacks },
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.adapters.items) |entry| self.allocator.free(entry.name);
        self.adapters.deinit(self.allocator);
    }

    pub fn registerAdapter(self: *Engine, registration: AdapterRegistration) !void {
        if (registration.name.len == 0 or registration.contract_version != 1) return error.UnsupportedAdapterContract;
        if (self.findAdapter(registration.name) != null) return error.AdapterAlreadyRegistered;
        const name = try self.allocator.dupe(u8, registration.name);
        errdefer self.allocator.free(name);
        try self.adapters.append(self.allocator, .{
            .name = name,
            .contract_version = registration.contract_version,
            .implementation = registration.implementation,
        });
    }

    pub fn discover(self: *Engine, request: DiscoverRequest) !Discovery {
        if (request.remote.len == 0) return error.InvalidRemote;
        self.host.report(.{ .phase = .discovering, .message = "Discovering forge capabilities" });
        var session = try HttpSession.init(self.allocator, self.host, request.remote, .{});
        defer session.deinit();
        const smart_http = session.smartHttp(request.remote);
        const upload = smart_http.discover(.upload_pack) catch |err| switch (err) {
            error.HttpFailure, error.BadContentType => null,
            else => return err,
        };
        defer if (upload) |value| value.deinit();
        const receive = smart_http.discover(.receive_pack) catch |err| switch (err) {
            error.HttpFailure, error.BadContentType => null,
            else => return err,
        };
        defer if (receive) |value| value.deinit();
        try self.host.checkCancelled();
        const result = Discovery{
            .can_fetch = upload != null,
            .can_publish = receive != null,
            .supports_atomic_publish = if (receive) |value| value.hasCapability("atomic") else false,
            .projection_ref_count = if (upload) |value| value.refs.len else 0,
            .has_native_carrier = if (upload) |value| value.findRef("refs/apricot/native") != null or value.hasRefPrefix("refs/apricot/carriers/") else false,
        };
        self.host.report(.{ .phase = .complete, .completed = 1, .total = 1, .message = "Discovery complete" });
        return result;
    }

    pub fn publish(self: *Engine, request: PublishRequest) !PublishResult {
        const registration = self.findAdapter(request.adapter_name) orelse return error.AdapterNotRegistered;
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .capturing, .message = "Capturing native repository" });
        const snapshot = try registration.implementation.snapshot();
        if (!std.mem.eql(u8, snapshot.vcs, request.adapter_name)) return error.AdapterIdentityMismatch;
        var capture = Capture.init(self.allocator);
        defer capture.deinit();
        try registration.implementation.enumerate(snapshot.roots, capture.objectSink());
        try capture.finish(snapshot, request.repository_id);
        const encoded = try carrier.encode(self.allocator, capture.manifest(snapshot, request.repository_id), request.carrier_limits);
        defer encoded.deinit(self.allocator);
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .projecting, .message = "Building forge projection" });
        var projection = Projection.init(self.allocator);
        defer projection.deinit();
        try registration.implementation.project(snapshot, projection.sink());
        try projection.finish();
        var session = try HttpSession.init(self.allocator, self.host, request.remote, request.git_limits);
        defer session.deinit();
        self.host.report(.{ .phase = .publishing, .message = "Publishing projection and native carrier" });
        const published = try forge.publish(self.allocator, session.smartHttp(request.remote), request.branch, encoded.bytes, encoded.root, projection.entries.items, request.signature, request.timestamp);
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .complete, .completed = 1, .total = 1, .message = "Publish complete" });
        return .{
            .projection_commit = published.commit,
            .carrier_commit = published.carrier_commit,
            .carrier_root = published.carrier_root,
        };
    }

    pub fn fetch(self: *Engine, request: FetchRequest) !FetchResult {
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .fetching, .message = "Fetching native carrier" });
        var session = try HttpSession.init(self.allocator, self.host, request.remote, request.git_limits);
        defer session.deinit();
        const fetched = try forge.fetch(self.allocator, session.smartHttp(request.remote), request.branch);
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .complete, .completed = 1, .total = 1, .message = "Fetch complete" });
        return .{
            .projection_commit = fetched.commit,
            .carrier_root = fetched.carrier_root,
            .carrier_bytes = fetched.carrier_bytes,
        };
    }

    pub fn verify(self: *Engine, request: VerifyRequest) !VerifyResult {
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .verifying, .message = "Verifying native carrier" });
        try carrier.verifyEncoded(request.expected_root, request.carrier_bytes, request.limits);
        var decoded = try carrier.decode(self.allocator, request.carrier_bytes, request.limits);
        defer decoded.deinit(self.allocator);
        const vcs = try self.allocator.dupe(u8, decoded.manifest.vcs);
        errdefer self.allocator.free(vcs);
        const result = VerifyResult{
            .vcs = vcs,
            .repository_id = try self.allocator.dupe(u8, decoded.manifest.repository_id),
            .object_count = decoded.manifest.objects.len,
            .ref_count = decoded.manifest.refs.len,
        };
        self.host.report(.{ .phase = .complete, .completed = 1, .total = 1, .message = "Verification complete" });
        return result;
    }

    pub fn materialize(self: *Engine, request: MaterializeRequest) !MaterializeResult {
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .verifying, .message = "Verifying native carrier" });
        try carrier.verifyEncoded(request.expected_root, request.carrier_bytes, request.limits);
        var decoded = try carrier.decode(self.allocator, request.carrier_bytes, request.limits);
        defer decoded.deinit(self.allocator);
        if (request.adapter_name) |name| {
            if (!std.mem.eql(u8, name, decoded.manifest.vcs)) return error.AdapterIdentityMismatch;
        }
        const registration = self.findAdapter(decoded.manifest.vcs) orelse return error.AdapterNotRegistered;
        const snapshot = try registration.implementation.snapshot();
        if (!std.mem.eql(u8, snapshot.vcs, decoded.manifest.vcs)) return error.AdapterIdentityMismatch;
        if (!snapshot.closure.tier.satisfies(request.required_tier)) return error.InsufficientPreservation;
        try verifySnapshotMetadata(self.allocator, decoded.manifest, snapshot);
        var source = try MaterializedSource.init(self.allocator, decoded.manifest.objects);
        defer source.deinit();
        try self.host.checkCancelled();
        self.host.report(.{ .phase = .restoring, .message = "Restoring native repository" });
        const report = try registration.implementation.restore(snapshot, source.source());
        if (!report.verified_tier.satisfies(request.required_tier)) return error.InsufficientPreservation;
        const vcs = try self.allocator.dupe(u8, decoded.manifest.vcs);
        self.host.report(.{ .phase = .complete, .completed = 1, .total = 1, .message = "Restore complete" });
        return .{
            .vcs = vcs,
            .verified_tier = report.verified_tier,
            .restored_root_count = report.roots.len,
            .restored_object_count = source.objects.items.len,
        };
    }

    fn findAdapter(self: *Engine, name: []const u8) ?RegisteredAdapter {
        for (self.adapters.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }
};

const HttpSession = struct {
    allocator: std.mem.Allocator,
    host: host_contract.Host,
    credential: ?host_contract.OwnedCredential = null,
    last_response: ?host_contract.OwnedHttpResponse = null,
    auth_header: [1]git.Header = undefined,
    limits: git.Limits,

    fn init(allocator: std.mem.Allocator, host: host_contract.Host, remote: []const u8, limits: git.Limits) !HttpSession {
        return .{ .allocator = allocator, .host = host, .credential = try host.getCredential(remote), .limits = limits };
    }

    fn deinit(self: *HttpSession) void {
        if (self.last_response) |value| value.deinit(self.allocator);
        if (self.credential) |value| value.deinit(self.allocator);
    }

    fn smartHttp(self: *HttpSession, remote: []const u8) git.SmartHttp {
        const headers: []const git.Header = if (self.credential) |value| blk: {
            self.auth_header[0] = .{ .name = value.header_name, .value = value.header_value };
            break :blk &self.auth_header;
        } else &.{};
        return .{
            .allocator = self.allocator,
            .http = .{ .context = self, .request_fn = request },
            .base_url = remote,
            .auth_headers = headers,
            .limits = self.limits,
        };
    }

    fn request(context: *anyopaque, request_value: git.HttpRequest) !git.HttpResponse {
        const self: *HttpSession = @ptrCast(@alignCast(context));
        if (self.last_response) |value| value.deinit(self.allocator);
        self.last_response = null;
        const headers = try self.allocator.alloc(host_contract.Header, request_value.headers.len);
        defer self.allocator.free(headers);
        for (request_value.headers, 0..) |header, index| headers[index] = .{ .name = header.name, .value = header.value };
        const response = try self.host.request(.{
            .method = switch (request_value.method) {
                .get => .get,
                .post => .post,
            },
            .url = request_value.url,
            .headers = headers,
            .body = request_value.body,
            .max_response_bytes = request_value.max_response_bytes,
        });
        self.last_response = response;
        return .{ .status = response.status, .content_type = response.content_type, .body = response.body };
    }
};

const Capture = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(carrier.NativeObject) = .empty,
    refs: std.ArrayList(carrier.NativeRef) = .empty,
    allocations: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Capture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Capture) void {
        for (self.allocations.items) |allocation| self.allocator.free(allocation);
        self.allocations.deinit(self.allocator);
        self.refs.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    fn objectSink(self: *Capture) adapter_contract.ObjectSink {
        return .{ .context = self, .emitFn = emitObject };
    }

    fn emitObject(context: *anyopaque, object: adapter_contract.NativeObject) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try adapter_contract.validateNativeObject(object);
        const id = try self.encodeId(object.id);
        const kind = try self.encodeObjectType(object);
        const bytes = try self.own(object.bytes);
        try self.objects.append(self.allocator, carrier.NativeObject.create(id, kind, bytes));
    }

    fn finish(self: *Capture, snapshot: adapter_contract.Snapshot, repository_id: []const u8) !void {
        if (repository_id.len == 0) return error.InvalidRepositoryIdentity;
        for (snapshot.roots) |root| {
            const target = try self.encodeId(root.id);
            const name = try std.fmt.allocPrint(self.allocator, "@apricot/root/{x}", .{root.role});
            self.allocations.append(self.allocator, name) catch |err| {
                self.allocator.free(name);
                return err;
            };
            try self.refs.append(self.allocator, .{ .name = name, .target_native_id = target });
        }
        for (snapshot.refs) |native_ref| {
            const target = try self.encodeId(native_ref.target);
            const name = try std.fmt.allocPrint(self.allocator, "@apricot/ref/{x}/{x}/{d}", .{ native_ref.namespace, native_ref.name, @intFromBool(native_ref.mutable) });
            self.allocations.append(self.allocator, name) catch |err| {
                self.allocator.free(name);
                return err;
            };
            try self.refs.append(self.allocator, .{ .name = name, .target_native_id = target });
        }
        std.mem.sort(carrier.NativeObject, self.objects.items, {}, lessObject);
        std.mem.sort(carrier.NativeRef, self.refs.items, {}, lessRef);
    }

    fn manifest(self: *Capture, snapshot: adapter_contract.Snapshot, repository_id: []const u8) carrier.Manifest {
        return .{
            .vcs = snapshot.vcs,
            .repository_id = repository_id,
            .chunk_size = 64 * 1024,
            .objects = self.objects.items,
            .refs = self.refs.items,
            .projection_mappings = &.{},
        };
    }

    fn encodeId(self: *Capture, id: adapter_contract.NativeId) ![]const u8 {
        const length = std.math.cast(u32, id.scheme.len) orelse return error.AdapterMetadataTooLarge;
        const value = try self.allocator.alloc(u8, 4 + id.scheme.len + id.bytes.len);
        errdefer self.allocator.free(value);
        std.mem.writeInt(u32, value[0..4], length, .big);
        @memcpy(value[4 .. 4 + id.scheme.len], id.scheme);
        @memcpy(value[4 + id.scheme.len ..], id.bytes);
        try self.allocations.append(self.allocator, value);
        return value;
    }

    fn encodeObjectType(self: *Capture, object: adapter_contract.NativeObject) ![]const u8 {
        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(self.allocator);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, std.math.cast(u32, object.kind.len) orelse return error.AdapterMetadataTooLarge, .big);
        try value.appendSlice(self.allocator, &length);
        try value.appendSlice(self.allocator, object.kind);
        std.mem.writeInt(u32, &length, std.math.cast(u32, object.dependencies.len) orelse return error.AdapterMetadataTooLarge, .big);
        try value.appendSlice(self.allocator, &length);
        for (object.dependencies) |dependency| {
            const encoded = try self.encodeId(dependency);
            std.mem.writeInt(u32, &length, std.math.cast(u32, encoded.len) orelse return error.AdapterMetadataTooLarge, .big);
            try value.appendSlice(self.allocator, &length);
            try value.appendSlice(self.allocator, encoded);
        }
        const owned = try value.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        try self.allocations.append(self.allocator, owned);
        return owned;
    }

    fn own(self: *Capture, value: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.allocations.append(self.allocator, copy);
        return copy;
    }

    fn lessObject(_: void, left: carrier.NativeObject, right: carrier.NativeObject) bool {
        return std.mem.lessThan(u8, left.native_id, right.native_id);
    }

    fn lessRef(_: void, left: carrier.NativeRef, right: carrier.NativeRef) bool {
        return std.mem.lessThan(u8, left.name, right.name);
    }
};

const Projection = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(forge.ProjectionEntry) = .empty,
    allocations: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Projection {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Projection) void {
        for (self.allocations.items) |allocation| self.allocator.free(allocation);
        self.allocations.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    fn sink(self: *Projection) adapter_contract.ProjectionSink {
        return .{ .context = self, .emitResourceFn = emitResource, .emitRelationFn = emitRelation, .emitEntryPointFn = emitEntryPoint };
    }

    fn emitResource(context: *anyopaque, resource: adapter_contract.ProjectionResource) !void {
        const self: *Projection = @ptrCast(@alignCast(context));
        try adapter_contract.validateProjectionResource(resource);
        if (!std.mem.eql(u8, resource.kind, "file") and !std.mem.eql(u8, resource.kind, "symlink")) return;
        const path = try self.own(resource.id);
        const data = try self.own(resource.payload);
        try self.entries.append(self.allocator, .{
            .path = path,
            .kind = if (std.mem.eql(u8, resource.kind, "symlink")) .symlink else .file,
            .data = data,
        });
    }

    fn emitRelation(_: *anyopaque, relation: adapter_contract.ProjectionRelation) !void {
        try adapter_contract.validateProjectionRelation(relation);
    }

    fn emitEntryPoint(_: *anyopaque, entry: adapter_contract.ProjectionEntryPoint) !void {
        if (entry.namespace.len == 0 or entry.name.len == 0 or entry.resource.len == 0) return error.InvalidProjectionEntryPoint;
    }

    fn finish(self: *Projection) !void {
        if (self.entries.items.len == 0) return error.EmptyProjection;
        std.mem.sort(forge.ProjectionEntry, self.entries.items, {}, lessEntry);
    }

    fn own(self: *Projection, value: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.allocations.append(self.allocator, copy);
        return copy;
    }

    fn lessEntry(_: void, left: forge.ProjectionEntry, right: forge.ProjectionEntry) bool {
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

const MaterializedSource = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(adapter_contract.NativeObject) = .empty,
    dependencies: std.ArrayList([]adapter_contract.NativeId) = .empty,

    fn init(allocator: std.mem.Allocator, encoded_objects: []const carrier.NativeObject) !MaterializedSource {
        var self = MaterializedSource{ .allocator = allocator };
        errdefer self.deinit();
        for (encoded_objects) |encoded| {
            const id = try decodeId(encoded.native_id);
            const metadata = try decodeObjectType(allocator, encoded.object_type);
            errdefer allocator.free(metadata.dependencies);
            try self.objects.append(allocator, .{
                .id = id,
                .kind = metadata.kind,
                .bytes = encoded.bytes,
                .dependencies = metadata.dependencies,
            });
            try self.dependencies.append(allocator, metadata.dependencies);
        }
        return self;
    }

    fn deinit(self: *MaterializedSource) void {
        for (self.dependencies.items) |value| self.allocator.free(value);
        self.dependencies.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    fn source(self: *MaterializedSource) adapter_contract.ObjectSource {
        return .{ .context = self, .getFn = get };
    }

    fn get(context: *anyopaque, id: adapter_contract.NativeId) !?adapter_contract.NativeObject {
        const self: *MaterializedSource = @ptrCast(@alignCast(context));
        for (self.objects.items) |object| if (object.id.eql(id)) return object;
        return null;
    }
};

const DecodedObjectType = struct {
    kind: []const u8,
    dependencies: []adapter_contract.NativeId,
};

fn decodeId(encoded: []const u8) !adapter_contract.NativeId {
    if (encoded.len < 5) return error.MalformedAdapterMetadata;
    const scheme_length: usize = std.mem.readInt(u32, encoded[0..4], .big);
    const boundary = std.math.add(usize, 4, scheme_length) catch return error.MalformedAdapterMetadata;
    if (scheme_length == 0 or boundary >= encoded.len) return error.MalformedAdapterMetadata;
    return .{ .scheme = encoded[4..boundary], .bytes = encoded[boundary..] };
}

fn decodeObjectType(allocator: std.mem.Allocator, encoded: []const u8) !DecodedObjectType {
    if (encoded.len < 8) return error.MalformedAdapterMetadata;
    const kind_length: usize = std.mem.readInt(u32, encoded[0..4], .big);
    const kind_end = std.math.add(usize, 4, kind_length) catch return error.MalformedAdapterMetadata;
    const count_end = std.math.add(usize, kind_end, 4) catch return error.MalformedAdapterMetadata;
    if (kind_length == 0 or count_end > encoded.len) return error.MalformedAdapterMetadata;
    const dependency_count: usize = std.mem.readInt(u32, encoded[kind_end..][0..4], .big);
    const dependencies = try allocator.alloc(adapter_contract.NativeId, dependency_count);
    errdefer allocator.free(dependencies);
    var offset = count_end;
    for (dependencies) |*dependency| {
        const length_end = std.math.add(usize, offset, 4) catch return error.MalformedAdapterMetadata;
        if (length_end > encoded.len) return error.MalformedAdapterMetadata;
        const dependency_length: usize = std.mem.readInt(u32, encoded[offset..][0..4], .big);
        const dependency_end = std.math.add(usize, length_end, dependency_length) catch return error.MalformedAdapterMetadata;
        if (dependency_end > encoded.len) return error.MalformedAdapterMetadata;
        dependency.* = try decodeId(encoded[length_end..dependency_end]);
        offset = dependency_end;
    }
    if (offset != encoded.len) return error.MalformedAdapterMetadata;
    return .{ .kind = encoded[4..kind_end], .dependencies = dependencies };
}

fn verifySnapshotMetadata(allocator: std.mem.Allocator, manifest: carrier.Manifest, snapshot: adapter_contract.Snapshot) !void {
    if (manifest.refs.len != snapshot.roots.len + snapshot.refs.len) return error.SnapshotMetadataMismatch;
    for (snapshot.roots) |root| {
        const name = try std.fmt.allocPrint(allocator, "@apricot/root/{x}", .{root.role});
        defer allocator.free(name);
        const target = findCarrierRef(manifest.refs, name) orelse return error.SnapshotMetadataMismatch;
        const decoded = try decodeId(target);
        if (!decoded.eql(root.id)) return error.SnapshotMetadataMismatch;
    }
    for (snapshot.refs) |native_ref| {
        const name = try std.fmt.allocPrint(allocator, "@apricot/ref/{x}/{x}/{d}", .{ native_ref.namespace, native_ref.name, @intFromBool(native_ref.mutable) });
        defer allocator.free(name);
        const target = findCarrierRef(manifest.refs, name) orelse return error.SnapshotMetadataMismatch;
        const decoded = try decodeId(target);
        if (!decoded.eql(native_ref.target)) return error.SnapshotMetadataMismatch;
    }
}

fn findCarrierRef(refs: []const carrier.NativeRef, name: []const u8) ?[]const u8 {
    for (refs) |native_ref| if (std.mem.eql(u8, native_ref.name, name)) return native_ref.target_native_id;
    return null;
}

test "engine registration is versioned and duplicate-safe" {
    const Fixture = struct {
        fn http(_: *anyopaque, _: host_contract.HttpRequest) !host_contract.HttpResponse {
            return error.UnexpectedHttp;
        }
    };
    var context: u8 = 0;
    var implementation = adapter_contract.AdversarialAdapter{};
    var engine = Engine.init(std.testing.allocator, .{ .context = &context, .http = Fixture.http });
    defer engine.deinit();
    try engine.registerAdapter(.{ .name = "adversarial-fixture", .implementation = implementation.adapter() });
    try std.testing.expectError(error.AdapterAlreadyRegistered, engine.registerAdapter(.{ .name = "adversarial-fixture", .implementation = implementation.adapter() }));
    try std.testing.expectError(error.UnsupportedAdapterContract, engine.registerAdapter(.{ .name = "future", .contract_version = 2, .implementation = implementation.adapter() }));
}

test "verify returns owned carrier identity" {
    const Fixture = struct {
        fn http(_: *anyopaque, _: host_contract.HttpRequest) !host_contract.HttpResponse {
            return error.UnexpectedHttp;
        }
    };
    const native_objects = [_]carrier.NativeObject{carrier.NativeObject.create("id", "state", "exact bytes")};
    const manifest = carrier.Manifest{
        .vcs = "test-vcs",
        .repository_id = "repo-1",
        .chunk_size = 1024,
        .objects = &native_objects,
        .refs = &.{},
        .projection_mappings = &.{},
    };
    const encoded = try carrier.encode(std.testing.allocator, manifest, .{});
    defer encoded.deinit(std.testing.allocator);
    var context: u8 = 0;
    var engine = Engine.init(std.testing.allocator, .{ .context = &context, .http = Fixture.http });
    defer engine.deinit();
    const result = try engine.verify(.{ .expected_root = encoded.root, .carrier_bytes = encoded.bytes });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("test-vcs", result.vcs);
    try std.testing.expectEqualStrings("repo-1", result.repository_id);
    try std.testing.expectEqual(@as(usize, 1), result.object_count);
    try std.testing.expectError(error.RootMismatch, engine.verify(.{ .expected_root = carrier.ContentId.of("wrong", "root"), .carrier_bytes = encoded.bytes }));
}

test "discover uses host networking credentials and reports forge capabilities" {
    const Fixture = struct {
        advertisement: []const u8,
        calls: usize = 0,
        authenticated: bool = true,

        fn http(context: *anyopaque, request_value: host_contract.HttpRequest) !host_contract.HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var found = false;
            for (request_value.headers) |header| {
                if (std.mem.eql(u8, header.name, "Authorization") and std.mem.eql(u8, header.value, "Bearer fixture")) found = true;
            }
            self.authenticated = self.authenticated and found;
            const content_type = if (std.mem.indexOf(u8, request_value.url, "upload-pack") != null)
                "application/x-git-upload-pack-advertisement"
            else
                "application/x-git-receive-pack-advertisement";
            return .{ .status = 200, .content_type = content_type, .body = self.advertisement };
        }

        fn credential(_: *anyopaque, _: []const u8) !?host_contract.Credential {
            return .{ .header_name = "Authorization", .header_value = "Bearer fixture" };
        }
    };
    var advertisement: std.ArrayList(u8) = .empty;
    defer advertisement.deinit(std.testing.allocator);
    try git.appendPkt(&advertisement, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main\x00atomic report-status\n", .{});
    try git.appendPkt(&advertisement, std.testing.allocator, "ce013625030ba8dba906f756967f9e9ca394464a refs/apricot/native\n", .{});
    try git.appendFlush(&advertisement, std.testing.allocator);
    var fixture = Fixture{ .advertisement = advertisement.items };
    var engine = Engine.init(std.testing.allocator, .{ .context = &fixture, .http = Fixture.http, .credential = Fixture.credential });
    defer engine.deinit();
    const result = try engine.discover(.{ .remote = "https://example.invalid/repository" });
    try std.testing.expect(result.can_fetch);
    try std.testing.expect(result.can_publish);
    try std.testing.expect(result.supports_atomic_publish);
    try std.testing.expect(result.has_native_carrier);
    try std.testing.expect(fixture.authenticated);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "capture retains roots refs object kinds and dependency identities" {
    var implementation = adapter_contract.AdversarialAdapter{};
    const contract = implementation.adapter();
    const snapshot = try contract.snapshot();
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try contract.enumerate(snapshot.roots, capture.objectSink());
    try capture.finish(snapshot, "repo");
    const encoded = try carrier.encode(std.testing.allocator, capture.manifest(snapshot, "repo"), .{});
    defer encoded.deinit(std.testing.allocator);
    var decoded = try carrier.decode(std.testing.allocator, encoded.bytes, .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(snapshot.roots.len + snapshot.refs.len, decoded.manifest.refs.len);
    try std.testing.expectEqual(adapter_contract.AdversarialAdapter.fixtureObjects().len, decoded.manifest.objects.len);
    var found_dependencies = false;
    for (decoded.manifest.objects) |object| {
        const metadata = try decodeObjectType(std.testing.allocator, object.object_type);
        defer std.testing.allocator.free(metadata.dependencies);
        for (metadata.dependencies) |dependency| {
            if (std.mem.eql(u8, dependency.scheme, "fixture-v1")) found_dependencies = true;
        }
    }
    try std.testing.expect(found_dependencies);
}

test "materialize verifies selects and restores registered adapter byte-losslessly" {
    const Fixture = struct {
        fn http(_: *anyopaque, _: host_contract.HttpRequest) !host_contract.HttpResponse {
            return error.UnexpectedHttp;
        }
    };
    var implementation = adapter_contract.AdversarialAdapter{};
    const contract = implementation.adapter();
    const snapshot = try contract.snapshot();
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try contract.enumerate(snapshot.roots, capture.objectSink());
    try capture.finish(snapshot, "repo-materialize");
    const encoded = try carrier.encode(std.testing.allocator, capture.manifest(snapshot, "repo-materialize"), .{});
    defer encoded.deinit(std.testing.allocator);
    var context: u8 = 0;
    var engine = Engine.init(std.testing.allocator, .{ .context = &context, .http = Fixture.http });
    defer engine.deinit();
    try engine.registerAdapter(.{ .name = "adversarial-fixture", .implementation = contract });
    const result = try engine.materialize(.{ .expected_root = encoded.root, .carrier_bytes = encoded.bytes });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(implementation.restored);
    try std.testing.expectEqual(adapter_contract.PreservationTier.byte_lossless, result.verified_tier);
    try std.testing.expectEqual(snapshot.roots.len, result.restored_root_count);
    try std.testing.expectEqual(adapter_contract.AdversarialAdapter.fixtureObjects().len, result.restored_object_count);
    try std.testing.expectEqualStrings("adversarial-fixture", result.vcs);
    try std.testing.expectError(error.AdapterIdentityMismatch, engine.materialize(.{
        .expected_root = encoded.root,
        .carrier_bytes = encoded.bytes,
        .adapter_name = "wrong",
    }));
}

test "materialized metadata rejects malformed native identities" {
    try std.testing.expectError(error.MalformedAdapterMetadata, decodeId("short"));
    var invalid = [_]u8{ 0, 0, 0, 9, 'a' };
    try std.testing.expectError(error.MalformedAdapterMetadata, decodeId(&invalid));
    try std.testing.expectError(error.MalformedAdapterMetadata, decodeObjectType(std.testing.allocator, "invalid"));
}
