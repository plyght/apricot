const std = @import("std");
const apricot = @import("apricot");

pub fn main(init: std.process.Init) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    var iterator = init.minimal.args.iterate();
    defer iterator.deinit();
    while (iterator.next()) |argument| try args.append(init.gpa, argument);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.items.len <= 1 or std.mem.eql(u8, args.items[1], "help") or std.mem.eql(u8, args.items[1], "--help")) {
        try printHelp(stdout);
    } else if (std.mem.eql(u8, args.items[1], "version") or std.mem.eql(u8, args.items[1], "--version")) {
        try stdout.print("apct {s}\n", .{apricot.version});
    } else if (std.mem.eql(u8, args.items[1], "features")) {
        try stdout.writeAll("carrier-v1\ncarrier-store-v1\nadapter-v1\nembedded-api-v1\ncollaboration-api-v1\nedge-transactions-v1\ngit-smart-http-v0\nsuperdetermine-filesystem-archive-v1\npijul-filesystem-archive-v1\n");
    } else if (std.mem.eql(u8, args.items[1], "probe")) {
        if (args.items.len != 3) return error.InvalidArguments;
        try probe(init, stdout, args.items[2]);
    } else if (std.mem.eql(u8, args.items[1], "publish")) {
        if (args.items.len >= 5 and std.mem.eql(u8, args.items[2], "--vcs")) {
            if (args.items.len > 6 or !std.mem.eql(u8, args.items[3], "pijul")) return error.InvalidArguments;
            try apricot.pijul_cli.publish(init, stdout, args.items[4], if (args.items.len == 6) args.items[5] else ".", configuredSignature(init));
        } else {
            if (args.items.len < 3 or args.items.len > 4) return error.InvalidArguments;
            try publish(init, stdout, args.items[2], if (args.items.len == 4) args.items[3] else ".");
        }
    } else if (std.mem.eql(u8, args.items[1], "fetch")) {
        if (args.items.len == 6 and std.mem.eql(u8, args.items[2], "--vcs") and std.mem.eql(u8, args.items[3], "pijul")) {
            try apricot.pijul_cli.fetch(init, stdout, args.items[4], args.items[5]);
        } else {
            if (args.items.len != 4) return error.InvalidArguments;
            try fetch(init, stdout, args.items[2], args.items[3]);
        }
    } else if (std.mem.eql(u8, args.items[1], "verify")) {
        if (args.items.len != 3) return error.InvalidArguments;
        try verify(init, stdout, args.items[2]);
    } else {
        try stdout.print("unknown command: {s}\n\n", .{args.items[1]});
        try printHelp(stdout);
    }
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Apricot carries native VCS repositories through standard code forges.
        \\
        \\Usage: apct <command>
        \\
        \\Commands:
        \\  help       Show this help
        \\  version    Show the Apricot version
        \\  features   List implemented protocol surfaces
        \\  probe URL  Discover Git smart-HTTP capabilities
        \\  publish URL [PATH]
        \\              Publish an exact sdt carrier and browsable projection
        \\  publish --vcs pijul URL [PATH]
        \\              Publish an exact Pijul carrier and browsable projection
        \\  fetch URL PATH
        \\              Restore the exact sdt repository into an empty path
        \\  fetch --vcs pijul URL PATH
        \\              Restore the exact Pijul repository into an empty path
        \\  verify URL  Fetch and verify the exact carrier without restoring
        \\
        \\Authentication uses APRICOT_USERNAME and APRICOT_TOKEN.
        \\Projection identity uses APRICOT_AUTHOR_NAME and APRICOT_AUTHOR_EMAIL.
        \\
    );
}

fn configuredSignature(init: std.process.Init) apricot.git_forge.Signature {
    return .{
        .name = init.environ_map.get("APRICOT_AUTHOR_NAME") orelse init.environ_map.get("USER") orelse "Apricot",
        .email = init.environ_map.get("APRICOT_AUTHOR_EMAIL") orelse "apricot@localhost",
    };
}

fn client(init: std.process.Init) apricot.git_http.Client {
    const token = init.environ_map.get("APRICOT_TOKEN");
    const credentials: ?apricot.http_client.Credentials = if (token) |password| .{
        .username = init.environ_map.get("APRICOT_USERNAME") orelse "apricot",
        .password = password,
    } else null;
    return .{ .allocator = init.gpa, .io = init.io, .credentials = credentials };
}

fn smart(init: std.process.Init, native_client: *apricot.git_http.Client, url: []const u8) apricot.git_transport.SmartHttp {
    return .{
        .allocator = init.gpa,
        .http = native_client.http(),
        .base_url = url,
    };
}

fn probe(init: std.process.Init, writer: *std.Io.Writer, url: []const u8) !void {
    var native_client = client(init);
    defer native_client.deinit();
    const remote = smart(init, &native_client, url);
    const upload = remote.discover(.upload_pack) catch |err| {
        if (native_client.last_response) |response| try writer.print("upload-pack HTTP {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
        return err;
    };
    defer upload.deinit();
    const receive = remote.discover(.receive_pack) catch |err| {
        if (native_client.last_response) |response| switch (response.status) {
            .unauthorized, .proxy_auth_required => {
                try writer.print("smart-http-v0 sha1 upload-refs={d} receive=authentication-required carrier={s}\n", .{
                    upload.refs.len,
                    if (upload.findRef("refs/apricot/native") == null and !upload.hasRefPrefix("refs/apricot/carriers/")) "absent" else "visible",
                });
                return;
            },
            .forbidden => {
                try writer.print("smart-http-v0 sha1 upload-refs={d} receive=forbidden carrier={s}\n", .{
                    upload.refs.len,
                    if (upload.findRef("refs/apricot/native") == null and !upload.hasRefPrefix("refs/apricot/carriers/")) "absent" else "visible",
                });
                return;
            },
            else => try writer.print("receive-pack HTTP {d}: {s}\n", .{ @intFromEnum(response.status), response.body }),
        };
        return err;
    };
    defer receive.deinit();
    try writer.print("smart-http-v0 sha1 receive-refs={d} upload-refs={d} atomic={s} carrier={s}\n", .{
        receive.refs.len,
        upload.refs.len,
        if (receive.hasCapability("atomic")) "yes" else "no",
        if (upload.findRef("refs/apricot/native") == null and !upload.hasRefPrefix("refs/apricot/carriers/")) "absent" else "visible",
    });
}

fn publish(init: std.process.Init, writer: *std.Io.Writer, url: []const u8, path: []const u8) !void {
    const absolute_path = try absolutePath(init, path);
    defer init.gpa.free(absolute_path);
    var captured = try apricot.sdt_codec.capture(init.gpa, init.io, absolute_path, url);
    defer captured.deinit(init.gpa);
    var native_client = client(init);
    defer native_client.deinit();
    const remote = smart(init, &native_client, url);
    const timestamp: i64 = @intCast(std.Io.Clock.real.now(init.io).toSeconds());
    const result = try apricot.git_forge.publish(
        init.gpa,
        remote,
        "main",
        captured.encoded.bytes,
        captured.encoded.root,
        captured.projection,
        .{ .name = "Apricot", .email = "apricot@localhost" },
        timestamp,
    );
    var commit_hex: [40]u8 = undefined;
    try writer.print("published {s} carrier {x}\n", .{ result.commit.format(&commit_hex), result.carrier_root.bytes });
}

fn fetch(init: std.process.Init, writer: *std.Io.Writer, url: []const u8, destination: []const u8) !void {
    const absolute_destination = try absolutePath(init, destination);
    defer init.gpa.free(absolute_destination);
    var native_client = client(init);
    defer native_client.deinit();
    const remote = smart(init, &native_client, url);
    const branch = try apricot.git_forge.defaultBranch(init.gpa, remote);
    defer init.gpa.free(branch);
    const fetched = try apricot.git_forge.fetch(init.gpa, remote, branch);
    defer fetched.deinit(init.gpa);
    try apricot.sdt_codec.restore(init.gpa, init.io, absolute_destination, fetched.carrier_bytes, fetched.carrier_root);
    var commit_hex: [40]u8 = undefined;
    try writer.print("restored {s} with byte-lossless carrier {x}\n", .{ fetched.commit.format(&commit_hex), fetched.carrier_root.bytes });
}

fn verify(init: std.process.Init, writer: *std.Io.Writer, url: []const u8) !void {
    var native_client = client(init);
    defer native_client.deinit();
    const remote = smart(init, &native_client, url);
    const branch = try apricot.git_forge.defaultBranch(init.gpa, remote);
    defer init.gpa.free(branch);
    const fetched = try apricot.git_forge.fetch(init.gpa, remote, branch);
    defer fetched.deinit(init.gpa);
    var commit_hex: [40]u8 = undefined;
    try writer.print("verified {s} carrier {x}\n", .{ fetched.commit.format(&commit_hex), fetched.carrier_root.bytes });
}

fn absolutePath(init: std.process.Init, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return init.gpa.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    return std.fs.path.resolve(init.gpa, &.{ cwd, path });
}
