const std = @import("std");

pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    credentials: ?Credentials = null,
};

pub const Response = struct {
    status: std.http.Status,
    content_type: []u8,
    body: []u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, request: Request) !Response {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var authorization_buffer: [4096]u8 = undefined;
    const authorization = if (request.credentials) |credentials|
        try basicAuthorization(credentials, &authorization_buffer)
    else
        null;

    const accept_headers: []const std.http.Header = if (request.accept) |accept|
        &.{.{ .name = "Accept", .value = accept }}
    else
        &.{};

    const uri = try std.Uri.parse(request.url);
    var http_request = try client.request(request.method, uri, .{
        .redirect_behavior = .init(5),
        .headers = .{
            .authorization = if (authorization) |value| .{ .override = value } else .default,
            .content_type = if (request.content_type) |value| .{ .override = value } else .default,
        },
        .extra_headers = accept_headers,
    });
    defer http_request.deinit();
    if (request.payload) |payload| {
        http_request.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try http_request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try http_request.connection.?.flush();
    } else {
        try http_request.sendBodiless();
    }
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try http_request.receiveHead(&redirect_buffer);
    const content_type = try allocator.dupe(u8, response.head.content_type orelse "");
    errdefer allocator.free(content_type);
    const status = response.head.status;
    if (request.method == .HEAD or status.class() == .informational or status == .no_content or status == .not_modified) {
        http_request.reader.state = .ready;
        return .{ .status = status, .content_type = content_type, .body = try allocator.alloc(u8, 0) };
    }
    var transfer_buffer: [64]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    const body = try reader.allocRemaining(allocator, .limited(512 * 1024 * 1024));
    return .{ .status = status, .content_type = content_type, .body = body };
}

pub fn basicAuthorization(credentials: Credentials, buffer: []u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, credentials.username, "\r\n:") != null) return error.InvalidCredentials;
    if (std.mem.indexOfAny(u8, credentials.password, "\r\n") != null) return error.InvalidCredentials;
    const plain_length = std.math.add(usize, credentials.username.len, credentials.password.len + 1) catch return error.CredentialsTooLong;
    if (plain_length > 2048) return error.CredentialsTooLong;
    var plain: [2048]u8 = undefined;
    @memcpy(plain[0..credentials.username.len], credentials.username);
    plain[credentials.username.len] = ':';
    @memcpy(plain[credentials.username.len + 1 .. plain_length], credentials.password);
    const encoded_length = std.base64.standard.Encoder.calcSize(plain_length);
    const total_length = std.math.add(usize, "Basic ".len, encoded_length) catch return error.CredentialsTooLong;
    if (total_length > buffer.len) return error.CredentialsTooLong;
    @memcpy(buffer[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(buffer["Basic ".len..total_length], plain[0..plain_length]);
    return buffer[0..total_length];
}

test "basic authorization is encoded without retaining plaintext" {
    var buffer: [128]u8 = undefined;
    const value = try basicAuthorization(.{ .username = "apricot", .password = "native" }, &buffer);
    try std.testing.expectEqualStrings("Basic YXByaWNvdDpuYXRpdmU=", value);
}

test "basic authorization rejects header injection" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidCredentials, basicAuthorization(.{ .username = "bad\r\nheader", .password = "value" }, &buffer));
    try std.testing.expectError(error.InvalidCredentials, basicAuthorization(.{ .username = "bad:name", .password = "value" }, &buffer));
}
