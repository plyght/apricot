const std = @import("std");
const git_http = @import("git_http.zig");
const git_transport = @import("git_transport.zig");
const host = @import("host.zig");
const http_client = @import("http_client.zig");
const workflow = @import("pijul_workflow.zig");

pub fn main(init: std.process.Init) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    var iterator = init.minimal.args.iterate();
    defer iterator.deinit();
    while (iterator.next()) |argument| try args.append(init.gpa, argument);
    if (args.items.len != 4) return error.InvalidArguments;
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const output = &output_writer.interface;
    defer output.flush() catch {};
    if (std.mem.eql(u8, args.items[1], "publish")) {
        const name = init.environ_map.get("APRICOT_AUTHOR_NAME") orelse return error.MissingAuthorIdentity;
        const email = init.environ_map.get("APRICOT_AUTHOR_EMAIL") orelse return error.MissingAuthorIdentity;
        try publish(init, output, args.items[2], args.items[3], .{ .name = name, .email = email });
    } else if (std.mem.eql(u8, args.items[1], "fetch")) {
        try fetch(init, output, args.items[2], args.items[3]);
    } else {
        return error.InvalidArguments;
    }
}

pub fn publish(init: std.process.Init, writer: *std.Io.Writer, remote: []const u8, path: []const u8, signature: @import("git_forge.zig").Signature) !void {
    const absolute_path = try absolutePath(init, path);
    defer init.gpa.free(absolute_path);
    var runtime = Runtime.init(init);
    defer runtime.deinit();
    const timestamp: i64 = @intCast(std.Io.Clock.real.now(init.io).toSeconds());
    const result = try workflow.publish(init.gpa, init.io, runtime.callbacks(), .{
        .remote = remote,
        .repository_path = absolute_path,
        .repository_id = remote,
        .signature = signature,
        .timestamp = timestamp,
    });
    var commit_hex: [40]u8 = undefined;
    try writer.print("published Pijul repository {s} carrier {x}\n", .{ result.projection_commit.format(&commit_hex), result.carrier_root.bytes });
}

pub fn fetch(init: std.process.Init, writer: *std.Io.Writer, remote: []const u8, destination: []const u8) !void {
    const absolute_destination = try absolutePath(init, destination);
    defer init.gpa.free(absolute_destination);
    var runtime = Runtime.init(init);
    defer runtime.deinit();
    const result = try workflow.fetchAndRestore(init.gpa, init.io, runtime.callbacks(), .{
        .remote = remote,
        .destination_path = absolute_destination,
    });
    var commit_hex: [40]u8 = undefined;
    try writer.print("restored Pijul repository {s} with byte-lossless carrier {x}\n", .{ result.projection_commit.format(&commit_hex), result.carrier_root.bytes });
}

const Runtime = struct {
    client: git_http.Client,

    fn init(process_init: std.process.Init) Runtime {
        const token = process_init.environ_map.get("APRICOT_TOKEN") orelse process_init.environ_map.get("GIT_TOKEN") orelse process_init.environ_map.get("GITHUB_TOKEN");
        const credentials: ?http_client.Credentials = if (token) |password| .{
            .username = process_init.environ_map.get("APRICOT_USERNAME") orelse "apricot",
            .password = password,
        } else null;
        return .{ .client = .{ .allocator = process_init.gpa, .io = process_init.io, .credentials = credentials } };
    }

    fn deinit(self: *Runtime) void {
        self.client.deinit();
    }

    fn callbacks(self: *Runtime) host.Callbacks {
        return .{ .context = self, .http = request };
    }

    fn request(context: *anyopaque, request_value: host.HttpRequest) !host.HttpResponse {
        const self: *Runtime = @ptrCast(@alignCast(context));
        const headers = try self.client.allocator.alloc(git_transport.Header, request_value.headers.len);
        defer self.client.allocator.free(headers);
        for (request_value.headers, 0..) |header, index| headers[index] = .{ .name = header.name, .value = header.value };
        const response = try self.client.http().request(.{
            .method = switch (request_value.method) {
                .get => .get,
                .post => .post,
            },
            .url = request_value.url,
            .headers = headers,
            .body = request_value.body,
            .max_response_bytes = request_value.max_response_bytes,
        });
        return .{
            .status = response.status,
            .content_type = response.content_type,
            .body = response.body,
        };
    }
};

fn absolutePath(init: std.process.Init, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return init.gpa.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    return std.fs.path.resolve(init.gpa, &.{ cwd, path });
}
