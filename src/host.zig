const std = @import("std");

pub const abi_version: u32 = 1;

pub const HttpMethod = enum(u8) {
    get,
    post,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: HttpMethod,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    max_response_bytes: usize,
};

pub const HttpResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

pub const Credential = struct {
    header_name: []const u8,
    header_value: []const u8,
};

pub const ProgressPhase = enum(u8) {
    discovering,
    capturing,
    projecting,
    publishing,
    fetching,
    verifying,
    restoring,
    complete,
};

pub const Progress = struct {
    phase: ProgressPhase,
    completed: u64 = 0,
    total: ?u64 = null,
    message: []const u8 = &.{},
};

pub const LogLevel = enum(u8) {
    debug,
    info,
    warning,
    err,
};

pub const Callbacks = struct {
    context: *anyopaque,
    http: *const fn (*anyopaque, HttpRequest) anyerror!HttpResponse,
    credential: ?*const fn (*anyopaque, []const u8) anyerror!?Credential = null,
    progress: ?*const fn (*anyopaque, Progress) void = null,
    cancelled: ?*const fn (*anyopaque) bool = null,
    log: ?*const fn (*anyopaque, LogLevel, []const u8) void = null,
};

pub const OwnedHttpResponse = struct {
    status: u16,
    content_type: []u8,
    body: []u8,

    pub fn deinit(self: OwnedHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

pub const OwnedCredential = struct {
    header_name: []u8,
    header_value: []u8,

    pub fn deinit(self: OwnedCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.header_name);
        allocator.free(self.header_value);
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    callbacks: Callbacks,

    pub fn request(self: Host, request_value: HttpRequest) !OwnedHttpResponse {
        try self.checkCancelled();
        const borrowed = try self.callbacks.http(self.callbacks.context, request_value);
        if (borrowed.body.len > request_value.max_response_bytes) return error.ResponseLimitExceeded;
        const content_type = try self.allocator.dupe(u8, borrowed.content_type);
        errdefer self.allocator.free(content_type);
        return .{
            .status = borrowed.status,
            .content_type = content_type,
            .body = try self.allocator.dupe(u8, borrowed.body),
        };
    }

    pub fn getCredential(self: Host, remote: []const u8) !?OwnedCredential {
        try self.checkCancelled();
        const callback = self.callbacks.credential orelse return null;
        const borrowed = try callback(self.callbacks.context, remote) orelse return null;
        if (borrowed.header_name.len == 0 or borrowed.header_value.len == 0) return error.InvalidCredential;
        const name = try self.allocator.dupe(u8, borrowed.header_name);
        errdefer self.allocator.free(name);
        return .{
            .header_name = name,
            .header_value = try self.allocator.dupe(u8, borrowed.header_value),
        };
    }

    pub fn report(self: Host, value: Progress) void {
        if (self.callbacks.progress) |callback| callback(self.callbacks.context, value);
    }

    pub fn writeLog(self: Host, level: LogLevel, message: []const u8) void {
        if (self.callbacks.log) |callback| callback(self.callbacks.context, level, message);
    }

    pub fn checkCancelled(self: Host) !void {
        if (self.callbacks.cancelled) |callback| {
            if (callback(self.callbacks.context)) return error.Cancelled;
        }
    }
};

test "host copies callback-owned response and credential data" {
    const Fixture = struct {
        response: [4]u8 = .{ 'd', 'a', 't', 'a' },
        requests: usize = 0,

        fn http(context: *anyopaque, request_value: HttpRequest) !HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests += 1;
            try std.testing.expectEqual(HttpMethod.get, request_value.method);
            return .{ .status = 200, .content_type = "text/plain", .body = &self.response };
        }

        fn credential(_: *anyopaque, _: []const u8) !?Credential {
            return .{ .header_name = "Authorization", .header_value = "Bearer secret" };
        }
    };
    var fixture = Fixture{};
    const contract = Host{
        .allocator = std.testing.allocator,
        .callbacks = .{ .context = &fixture, .http = Fixture.http, .credential = Fixture.credential },
    };
    const response = try contract.request(.{ .method = .get, .url = "https://example.invalid", .headers = &.{}, .body = &.{}, .max_response_bytes = 4 });
    defer response.deinit(std.testing.allocator);
    fixture.response[0] = 'x';
    try std.testing.expectEqualStrings("data", response.body);
    const credential_value = (try contract.getCredential("https://example.invalid")).?;
    defer credential_value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Authorization", credential_value.header_name);
    try std.testing.expectEqual(@as(usize, 1), fixture.requests);
}

test "host enforces response limits and cancellation" {
    const Fixture = struct {
        cancelled_value: bool = false,

        fn http(_: *anyopaque, _: HttpRequest) !HttpResponse {
            return .{ .status = 200, .content_type = "text/plain", .body = "too large" };
        }

        fn cancelled(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.cancelled_value;
        }
    };
    var fixture = Fixture{};
    const contract = Host{
        .allocator = std.testing.allocator,
        .callbacks = .{ .context = &fixture, .http = Fixture.http, .cancelled = Fixture.cancelled },
    };
    try std.testing.expectError(error.ResponseLimitExceeded, contract.request(.{ .method = .get, .url = "x", .headers = &.{}, .body = &.{}, .max_response_bytes = 2 }));
    fixture.cancelled_value = true;
    try std.testing.expectError(error.Cancelled, contract.checkCancelled());
}
