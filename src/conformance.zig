const std = @import("std");
const git = @import("git_transport.zig");

pub const Mode = enum { public_read_only, configured_writable };

pub const Availability = enum {
    available,
    authentication_required,
    forbidden,
    missing,
    unavailable,
    malformed,
    limit_exceeded,
    not_probed,
};

pub const Protocol = enum { v0, v1, v2, unknown };
pub const ObjectFormat = enum { sha1, sha256, unknown };
pub const Presence = enum { visible, absent, unknown };
pub const Collaboration = enum {
    available,
    authentication_required,
    forbidden,
    missing,
    refused,
    unavailable,
    malformed,
    limit_exceeded,
    not_configured,
};

pub const Limits = struct {
    max_response_bytes: usize = 8 * 1024 * 1024,
    max_requests: u8 = 3,
    request_timeout_ms: u32 = 10_000,
    max_refs: usize = 100_000,

    pub fn validate(self: Limits) !void {
        if (self.max_response_bytes == 0 or self.max_response_bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        if (self.max_requests == 0 or self.max_requests > 16) return error.InvalidLimits;
        if (self.request_timeout_ms == 0 or self.request_timeout_ms > 120_000) return error.InvalidLimits;
        if (self.max_refs == 0 or self.max_refs > 1_000_000) return error.InvalidLimits;
    }
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    url: []const u8,
    headers: []const Header,
    max_response_bytes: usize,
    timeout_ms: u32,
};

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

pub const Requester = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, Request) anyerror!Response,

    pub fn request(self: Requester, value: Request) !Response {
        return self.request_fn(self.context, value);
    }
};

pub const Config = struct {
    repository_url: []const u8,
    mode: Mode = .public_read_only,
    headers: []const Header = &.{},
    collaboration_discovery_url: ?[]const u8 = null,
    limits: Limits = .{},
};

pub const ServiceResult = struct {
    availability: Availability = .not_probed,
    protocol: Protocol = .unknown,
    object_format: ObjectFormat = .unknown,
    capability_count: usize = 0,
};

pub const Result = struct {
    schema: u16 = 1,
    mode: Mode,
    upload_pack: ServiceResult,
    receive_pack: ServiceResult,
    native_carrier: Presence,
    default_branch: ?[]u8,
    collaboration: Collaboration,
    requests: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        if (self.default_branch) |branch| self.allocator.free(branch);
        self.* = undefined;
    }

    pub fn encodeJson(self: Result, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, "{\"schema\":1,\"mode\":\"");
        try output.appendSlice(allocator, @tagName(self.mode));
        try output.appendSlice(allocator, "\",\"upload_pack\":");
        try appendServiceJson(&output, allocator, self.upload_pack);
        try output.appendSlice(allocator, ",\"receive_pack\":");
        try appendServiceJson(&output, allocator, self.receive_pack);
        try output.appendSlice(allocator, ",\"native_carrier\":\"");
        try output.appendSlice(allocator, @tagName(self.native_carrier));
        try output.appendSlice(allocator, "\",\"default_branch\":");
        if (self.default_branch) |branch| try appendJsonString(&output, allocator, branch) else try output.appendSlice(allocator, "null");
        try output.appendSlice(allocator, ",\"collaboration\":\"");
        try output.appendSlice(allocator, @tagName(self.collaboration));
        try output.appendSlice(allocator, "\",\"requests\":");
        const request_count = try std.fmt.allocPrint(allocator, "{d}", .{self.requests});
        defer allocator.free(request_count);
        try output.appendSlice(allocator, request_count);
        try output.append(allocator, '}');
        return output.toOwnedSlice(allocator);
    }
};

const Parsed = struct {
    protocol: Protocol,
    object_format: ObjectFormat,
    capability_count: usize,
    native_carrier: Presence,
    default_branch: ?[]u8,
};

const Run = struct {
    allocator: std.mem.Allocator,
    requester: Requester,
    config: Config,
    requests: u8 = 0,

    fn get(self: *Run, url: []const u8, headers: []const Header) !Response {
        if (self.requests >= self.config.limits.max_requests) return error.RequestLimitExceeded;
        self.requests += 1;
        const response = try self.requester.request(.{
            .url = url,
            .headers = headers,
            .max_response_bytes = self.config.limits.max_response_bytes,
            .timeout_ms = self.config.limits.request_timeout_ms,
        });
        if (response.body.len > self.config.limits.max_response_bytes) return error.ResponseTooLarge;
        return response;
    }
};

pub fn probe(allocator: std.mem.Allocator, requester: Requester, config: Config) !Result {
    try config.limits.validate();
    if (!validUrl(config.repository_url)) return error.InvalidUrl;
    if (config.collaboration_discovery_url) |url| if (!validUrl(url)) return error.InvalidUrl;
    var run = Run{ .allocator = allocator, .requester = requester, .config = config };
    var result = Result{
        .mode = config.mode,
        .upload_pack = .{},
        .receive_pack = .{},
        .native_carrier = .unknown,
        .default_branch = null,
        .collaboration = if (config.collaboration_discovery_url == null) .not_configured else .unavailable,
        .requests = 0,
        .allocator = allocator,
    };
    errdefer result.deinit();
    const upload = try probeService(&run, "git-upload-pack");
    result.upload_pack = upload.service;
    result.native_carrier = upload.native_carrier;
    result.default_branch = upload.default_branch;
    const receive = try probeService(&run, "git-receive-pack");
    if (receive.default_branch) |branch| allocator.free(branch);
    result.receive_pack = receive.service;
    if (config.collaboration_discovery_url) |url| result.collaboration = try probeCollaboration(&run, url);
    result.requests = run.requests;
    return result;
}

const ServiceProbe = struct {
    service: ServiceResult,
    native_carrier: Presence = .unknown,
    default_branch: ?[]u8 = null,
};

fn probeService(run: *Run, service: []const u8) !ServiceProbe {
    const url = try std.fmt.allocPrint(run.allocator, "{s}/info/refs?service={s}", .{ std.mem.trimEnd(u8, run.config.repository_url, "/"), service });
    defer run.allocator.free(url);
    var protocol_headers: std.ArrayList(Header) = .empty;
    defer protocol_headers.deinit(run.allocator);
    try protocol_headers.appendSlice(run.allocator, run.config.headers);
    try protocol_headers.append(run.allocator, .{ .name = "Git-Protocol", .value = "version=2" });
    const response = run.get(url, protocol_headers.items) catch |err| return .{ .service = .{ .availability = classifyRequestError(err) } };
    const availability = classifyStatus(response.status);
    if (availability != .available) return .{ .service = .{ .availability = availability } };
    var expected: [80]u8 = undefined;
    const expected_type = std.fmt.bufPrint(&expected, "application/x-{s}-advertisement", .{service}) catch unreachable;
    if (!contentTypeMatches(response.content_type, expected_type)) return .{ .service = .{ .availability = .malformed } };
    const parsed = parseAdvertisement(run.allocator, response.body, run.config.limits) catch |err| return .{ .service = .{ .availability = classifyParseError(err) } };
    return .{
        .service = .{
            .availability = .available,
            .protocol = parsed.protocol,
            .object_format = parsed.object_format,
            .capability_count = parsed.capability_count,
        },
        .native_carrier = if (std.mem.eql(u8, service, "git-upload-pack")) parsed.native_carrier else .unknown,
        .default_branch = parsed.default_branch,
    };
}

fn probeCollaboration(run: *Run, url: []const u8) !Collaboration {
    const response = run.get(url, run.config.headers) catch |err| return switch (classifyRequestError(err)) {
        .limit_exceeded => .limit_exceeded,
        else => .unavailable,
    };
    return switch (classifyStatus(response.status)) {
        .available => if (isStructuredDiscovery(response.content_type, response.body)) .available else .refused,
        .authentication_required => .authentication_required,
        .forbidden => .forbidden,
        .missing => .missing,
        .limit_exceeded => .limit_exceeded,
        .malformed => .malformed,
        else => .unavailable,
    };
}

fn parseAdvertisement(allocator: std.mem.Allocator, body: []const u8, limits: Limits) !Parsed {
    if (body.len > limits.max_response_bytes) return error.ResponseTooLarge;
    var iterator = git.PktIterator{ .input = body, .limits = .{ .max_advertisement = limits.max_response_bytes, .max_refs = limits.max_refs } };
    var protocol: Protocol = .v0;
    var object_format: ObjectFormat = .sha1;
    var capability_count: usize = 0;
    var native_carrier: Presence = .absent;
    var default_branch: ?[]u8 = null;
    errdefer if (default_branch) |branch| allocator.free(branch);
    var refs: usize = 0;
    while (try iterator.next()) |pkt| {
        if (pkt.kind != .data) continue;
        const line = std.mem.trimEnd(u8, pkt.data, "\n");
        if (std.mem.eql(u8, line, "version 2")) {
            protocol = .v2;
            object_format = .unknown;
            continue;
        }
        if (std.mem.eql(u8, line, "version 1")) {
            protocol = .v1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "# service=")) continue;
        if (protocol == .v2) {
            capability_count += 1;
            if (std.mem.eql(u8, line, "object-format=sha1")) object_format = .sha1;
            if (std.mem.eql(u8, line, "object-format=sha256")) object_format = .sha256;
            continue;
        }
        if (line.len < 42 or line[40] != ' ') return error.MalformedAdvertisement;
        const oid_length: usize = if (line.len >= 66 and line[64] == ' ') 64 else 40;
        if (line.len <= oid_length or line[oid_length] != ' ') return error.MalformedAdvertisement;
        object_format = if (oid_length == 64) .sha256 else .sha1;
        refs += 1;
        if (refs > limits.max_refs) return error.RefLimitExceeded;
        const remainder = line[oid_length + 1 ..];
        const nul = std.mem.indexOfScalar(u8, remainder, 0);
        const ref_name = if (nul) |index| remainder[0..index] else remainder;
        if (std.mem.eql(u8, ref_name, "refs/apricot/native") or std.mem.startsWith(u8, ref_name, "refs/apricot/carriers/")) native_carrier = .visible;
        if (nul) |index| {
            var tokens = std.mem.tokenizeScalar(u8, remainder[index + 1 ..], ' ');
            while (tokens.next()) |capability| {
                capability_count += 1;
                if (std.mem.eql(u8, capability, "object-format=sha256")) object_format = .sha256;
                const prefix = "symref=HEAD:refs/heads/";
                if (default_branch == null and std.mem.startsWith(u8, capability, prefix) and capability.len > prefix.len) default_branch = try allocator.dupe(u8, capability[prefix.len..]);
            }
        }
    }
    return .{
        .protocol = protocol,
        .object_format = object_format,
        .capability_count = capability_count,
        .native_carrier = if (protocol == .v2) .unknown else native_carrier,
        .default_branch = default_branch,
    };
}

fn classifyStatus(status: u16) Availability {
    return switch (status) {
        200...299 => .available,
        401, 407 => .authentication_required,
        403 => .forbidden,
        404, 410 => .missing,
        429, 500...599 => .unavailable,
        else => .malformed,
    };
}

fn classifyRequestError(err: anyerror) Availability {
    return switch (err) {
        error.ResponseTooLarge, error.RequestLimitExceeded => .limit_exceeded,
        else => .unavailable,
    };
}

fn classifyParseError(err: anyerror) Availability {
    return switch (err) {
        error.ResponseTooLarge, error.RefLimitExceeded, error.LimitExceeded => .limit_exceeded,
        else => .malformed,
    };
}

fn validUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://localhost:");
}

fn contentTypeMatches(actual: []const u8, expected: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, actual, ';') orelse actual.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, actual[0..end], " \t"), expected);
}

fn isStructuredDiscovery(content_type: []const u8, body: []const u8) bool {
    if (body.len == 0) return false;
    const json_type = contentTypeMatches(content_type, "application/json") or contentTypeMatches(content_type, "application/ld+json");
    if (!json_type) return false;
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return trimmed.len >= 2 and ((trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') or (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']'));
}

fn appendServiceJson(output: *std.ArrayList(u8), allocator: std.mem.Allocator, service: ServiceResult) !void {
    const encoded = try std.fmt.allocPrint(allocator, "{{\"availability\":\"{s}\",\"protocol\":\"{s}\",\"object_format\":\"{s}\",\"capability_count\":{d}}}", .{
        @tagName(service.availability), @tagName(service.protocol), @tagName(service.object_format), service.capability_count,
    });
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
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

const Fixture = struct {
    responses: []const Response,
    index: usize = 0,
    observed_timeout: u32 = 0,
    observed_limit: usize = 0,

    fn requester(self: *Fixture) Requester {
        return .{ .context = self, .request_fn = request };
    }

    fn request(context: *anyopaque, value: Request) !Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.observed_timeout = value.timeout_ms;
        self.observed_limit = value.max_response_bytes;
        if (self.index >= self.responses.len) return error.NoFixtureResponse;
        const response = self.responses[self.index];
        self.index += 1;
        return response;
    }
};

fn advertisement(allocator: std.mem.Allocator, service: []const u8, refs: []const []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const announcement = try std.fmt.allocPrint(allocator, "# service={s}\n", .{service});
    defer allocator.free(announcement);
    try git.appendPkt(&output, allocator, announcement, .{});
    try git.appendFlush(&output, allocator);
    for (refs, 0..) |ref, index| {
        const suffix = if (index == 0) "\x00symref=HEAD:refs/heads/main report-status side-band-64k\n" else "\n";
        const line = try std.fmt.allocPrint(allocator, "1111111111111111111111111111111111111111 {s}{s}", .{ ref, suffix });
        defer allocator.free(line);
        try git.appendPkt(&output, allocator, line, .{});
    }
    try git.appendFlush(&output, allocator);
    return output.toOwnedSlice(allocator);
}

test "public probe classifies transport carrier branch and collaboration" {
    const upload = try advertisement(std.testing.allocator, "git-upload-pack", &.{ "HEAD", "refs/heads/main", "refs/apricot/native" });
    defer std.testing.allocator.free(upload);
    const receive = try advertisement(std.testing.allocator, "git-receive-pack", &.{"refs/heads/main"});
    defer std.testing.allocator.free(receive);
    var fixture = Fixture{ .responses = &.{
        .{ .status = 200, .content_type = "application/x-git-upload-pack-advertisement", .body = upload },
        .{ .status = 200, .content_type = "application/x-git-receive-pack-advertisement", .body = receive },
        .{ .status = 200, .content_type = "application/json; charset=utf-8", .body = "{\"resources\":[]}" },
    } };
    var result = try probe(std.testing.allocator, fixture.requester(), .{
        .repository_url = "https://forge.invalid/owner/repo",
        .collaboration_discovery_url = "https://forge.invalid/api/repository",
        .limits = .{ .max_response_bytes = 4096, .request_timeout_ms = 37 },
    });
    defer result.deinit();
    try std.testing.expectEqual(Availability.available, result.upload_pack.availability);
    try std.testing.expectEqual(Availability.available, result.receive_pack.availability);
    try std.testing.expectEqual(Protocol.v0, result.upload_pack.protocol);
    try std.testing.expectEqual(ObjectFormat.sha1, result.upload_pack.object_format);
    try std.testing.expectEqual(Presence.visible, result.native_carrier);
    try std.testing.expectEqualStrings("main", result.default_branch.?);
    try std.testing.expectEqual(Collaboration.available, result.collaboration);
    try std.testing.expectEqual(@as(u8, 3), result.requests);
    try std.testing.expectEqual(@as(u32, 37), fixture.observed_timeout);
    try std.testing.expectEqual(@as(usize, 4096), fixture.observed_limit);
}

test "protocol v2 and authentication refusals remain explicit" {
    var v2: std.ArrayList(u8) = .empty;
    defer v2.deinit(std.testing.allocator);
    try git.appendPkt(&v2, std.testing.allocator, "version 2\n", .{});
    try git.appendPkt(&v2, std.testing.allocator, "agent=fixture\n", .{});
    try git.appendPkt(&v2, std.testing.allocator, "object-format=sha256\n", .{});
    try git.appendFlush(&v2, std.testing.allocator);
    var fixture = Fixture{ .responses = &.{
        .{ .status = 200, .content_type = "application/x-git-upload-pack-advertisement", .body = v2.items },
        .{ .status = 401, .content_type = "text/plain", .body = "authorization required" },
        .{ .status = 403, .content_type = "application/json", .body = "{}" },
    } };
    var result = try probe(std.testing.allocator, fixture.requester(), .{
        .repository_url = "https://forge.invalid/o/r",
        .mode = .configured_writable,
        .collaboration_discovery_url = "https://forge.invalid/capabilities",
    });
    defer result.deinit();
    try std.testing.expectEqual(Protocol.v2, result.upload_pack.protocol);
    try std.testing.expectEqual(ObjectFormat.sha256, result.upload_pack.object_format);
    try std.testing.expectEqual(Presence.unknown, result.native_carrier);
    try std.testing.expectEqual(Availability.authentication_required, result.receive_pack.availability);
    try std.testing.expectEqual(Collaboration.forbidden, result.collaboration);
}

test "machine output is stable and escapes branch values" {
    var result = Result{
        .mode = .public_read_only,
        .upload_pack = .{ .availability = .available, .protocol = .v0, .object_format = .sha1, .capability_count = 2 },
        .receive_pack = .{ .availability = .forbidden },
        .native_carrier = .absent,
        .default_branch = try std.testing.allocator.dupe(u8, "topic\"x"),
        .collaboration = .not_configured,
        .requests = 2,
        .allocator = std.testing.allocator,
    };
    defer result.deinit();
    const encoded = try result.encodeJson(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"schema\":1,\"mode\":\"public_read_only\",\"upload_pack\":{\"availability\":\"available\",\"protocol\":\"v0\",\"object_format\":\"sha1\",\"capability_count\":2},\"receive_pack\":{\"availability\":\"forbidden\",\"protocol\":\"unknown\",\"object_format\":\"unknown\",\"capability_count\":0},\"native_carrier\":\"absent\",\"default_branch\":\"topic\\\"x\",\"collaboration\":\"not_configured\",\"requests\":2}", encoded);
}

test "resource and malformed discovery outcomes are deterministic" {
    const oversized = "0123456789";
    var fixture = Fixture{ .responses = &.{
        .{ .status = 200, .content_type = "application/x-git-upload-pack-advertisement", .body = oversized },
        .{ .status = 404, .content_type = "text/plain", .body = "" },
        .{ .status = 200, .content_type = "text/html", .body = "{}" },
    } };
    var result = try probe(std.testing.allocator, fixture.requester(), .{
        .repository_url = "http://127.0.0.1:8080/r",
        .collaboration_discovery_url = "http://localhost:8080/api",
        .limits = .{ .max_response_bytes = 10 },
    });
    defer result.deinit();
    try std.testing.expectEqual(Availability.malformed, result.upload_pack.availability);
    try std.testing.expectEqual(Availability.missing, result.receive_pack.availability);
    try std.testing.expectEqual(Collaboration.refused, result.collaboration);
    try std.testing.expectError(error.InvalidLimits, probe(std.testing.allocator, fixture.requester(), .{ .repository_url = "https://x.invalid/r", .limits = .{ .request_timeout_ms = 0 } }));
    try std.testing.expectError(error.InvalidUrl, probe(std.testing.allocator, fixture.requester(), .{ .repository_url = "file:///tmp/r" }));
}

test "request and response limits fail closed" {
    const upload = try advertisement(std.testing.allocator, "git-upload-pack", &.{"refs/heads/main"});
    defer std.testing.allocator.free(upload);
    const receive = try advertisement(std.testing.allocator, "git-receive-pack", &.{"refs/heads/main"});
    defer std.testing.allocator.free(receive);
    var fixture = Fixture{ .responses = &.{
        .{ .status = 200, .content_type = "application/x-git-upload-pack-advertisement", .body = upload },
        .{ .status = 200, .content_type = "application/x-git-receive-pack-advertisement", .body = receive },
    } };
    var result = try probe(std.testing.allocator, fixture.requester(), .{
        .repository_url = "https://forge.invalid/o/r",
        .collaboration_discovery_url = "https://forge.invalid/capabilities",
        .limits = .{ .max_requests = 2 },
    });
    defer result.deinit();
    try std.testing.expectEqual(Presence.absent, result.native_carrier);
    try std.testing.expectEqual(Collaboration.limit_exceeded, result.collaboration);
    try std.testing.expectEqual(@as(u8, 2), result.requests);

    var large_fixture = Fixture{ .responses = &.{
        .{ .status = 200, .content_type = "application/x-git-upload-pack-advertisement", .body = "12345" },
        .{ .status = 503, .content_type = "text/plain", .body = "" },
    } };
    var large_result = try probe(std.testing.allocator, large_fixture.requester(), .{
        .repository_url = "https://forge.invalid/o/r",
        .limits = .{ .max_response_bytes = 4 },
    });
    defer large_result.deinit();
    try std.testing.expectEqual(Availability.limit_exceeded, large_result.upload_pack.availability);
    try std.testing.expectEqual(Availability.unavailable, large_result.receive_pack.availability);
}
