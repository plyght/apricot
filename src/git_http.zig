const std = @import("std");
const transport = @import("git_transport.zig");
const native_http = @import("http_client.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: ?native_http.Credentials = null,
    last_response: ?native_http.Response = null,

    pub fn deinit(self: *Client) void {
        if (self.last_response) |response| response.deinit(self.allocator);
        self.last_response = null;
    }

    pub fn http(self: *Client) transport.Http {
        return .{ .context = self, .request_fn = request };
    }

    fn request(context: *anyopaque, value: transport.HttpRequest) !transport.HttpResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        if (self.last_response) |response| response.deinit(self.allocator);
        self.last_response = null;

        var content_type: ?[]const u8 = null;
        var accept: ?[]const u8 = null;
        for (value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) {
                content_type = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Accept")) {
                accept = header.value;
            } else {
                return error.UnsupportedHeader;
            }
        }
        const response = try native_http.execute(self.allocator, self.io, .{
            .method = switch (value.method) {
                .get => .GET,
                .post => .POST,
            },
            .url = value.url,
            .payload = if (value.method == .post) value.body else null,
            .content_type = content_type,
            .accept = accept,
            .credentials = self.credentials,
        });
        if (response.body.len > value.max_response_bytes) {
            response.deinit(self.allocator);
            return error.ResponseTooLarge;
        }
        self.last_response = response;
        return .{
            .status = @intFromEnum(response.status),
            .content_type = response.content_type,
            .body = response.body,
        };
    }
};

test "client exposes provider-neutral http interface" {
    var client = Client{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .credentials = .{ .username = "user", .password = "token" },
    };
    try std.testing.expect(@intFromPtr(client.http().context) == @intFromPtr(&client));
}
