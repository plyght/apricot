const std = @import("std");
const collaboration = @import("collaboration.zig");

pub const Family = enum {
    github,
    origin,
    gitlab,
    forgejo,
    tangled,
    git_wire,
};

pub const Method = enum {
    get,
    post,
    put,
    patch,
    delete,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    url: []u8,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.headers);
        allocator.free(self.body);
    }
};

pub const Response = struct {
    status: u16,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
};

pub const Transport = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, Method, []const u8, []const Header, []const u8) anyerror!Response,

    pub fn request(self: Transport, value: Request) !Response {
        return self.request_fn(self.context, value.method, value.url, value.headers, value.body);
    }
};

pub const Feature = enum(u8) {
    issues,
    issue_comments,
    pull_requests,
    pull_request_reviews,
    forks,
    releases,
    labels,
    milestones,
    assignees,
    merge,
    push_proposals,
};

pub const FeatureSet = std.EnumSet(Feature);

pub const Capabilities = struct {
    family: Family,
    features: FeatureSet,
    discovered_from: []u8,

    pub fn deinit(self: Capabilities, allocator: std.mem.Allocator) void {
        allocator.free(self.discovered_from);
    }

    pub fn supports(self: Capabilities, feature: Feature) bool {
        return self.features.contains(feature);
    }
};

pub const ErrorKind = enum {
    authentication,
    forbidden,
    missing,
    conflict,
    validation,
    rate_limited,
    unavailable,
    protocol,
};

pub const RemoteError = struct {
    kind: ErrorKind,
    status: u16,
    retry_after_seconds: ?u64,
    raw: []u8,

    pub fn deinit(self: RemoteError, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

pub const Page = struct {
    records: [][]u8,
    next: ?[]u8,
    raw: []u8,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        for (self.records) |record| allocator.free(record);
        allocator.free(self.records);
        if (self.next) |next| allocator.free(next);
        allocator.free(self.raw);
    }
};

pub const IssueInput = struct {
    title: []const u8,
    body: []const u8,
};

pub const ProposalInput = struct {
    title: []const u8,
    body: []const u8,
    head: []const u8,
    base: []const u8,
    draft: bool = false,
};

pub const EndpointDialect = struct {
    discovery: ?[]const u8 = null,
    create_issue: ?[]const u8 = null,
    create_proposal: ?[]const u8 = null,
    create_comment: ?[]const u8 = null,
    create_fork: ?[]const u8 = null,
};

pub const TangledDialect = struct {
    discovery_method: ?[]const u8 = null,
    issue_collection: ?[]const u8 = null,
    pull_collection: ?[]const u8 = null,
    comment_collection: ?[]const u8 = null,
    fork_collection: ?[]const u8 = null,
    list_issues_method: ?[]const u8 = "sh.tangled.repo.listIssues",
};

pub const CommentInput = struct {
    target: u64,
    body: []const u8,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    family: Family,
    base_url: []const u8,
    repository: []const u8,
    auth: ?Header = null,
    transport: ?Transport = null,
    endpoints: EndpointDialect = .{},
    tangled: TangledDialect = .{},

    pub fn collaborationDriver(self: *Driver) collaboration.Driver {
        return .{ .context = self, .vtable = &collaboration_vtable };
    }

    pub fn discoveryRequest(self: Driver) !Request {
        const path = switch (self.family) {
            .github => try std.fmt.allocPrint(self.allocator, "/repos/{s}", .{self.repository}),
            .origin => try self.configuredPath(self.endpoints.discovery),
            .gitlab => try self.gitlabProjectPath(),
            .forgejo => try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}", .{self.repository}),
            .tangled => try self.xrpcQueryPath(self.tangled.discovery_method),
            .git_wire => "/info/refs?service=git-upload-pack",
        };
        defer if (self.family != .git_wire) self.allocator.free(path);
        return self.make(.get, path, &.{});
    }

    pub fn discover(self: Driver, response: Response) !Capabilities {
        if (response.status < 200 or response.status >= 300) return error.RemoteFailure;
        var features = FeatureSet.initEmpty();
        switch (self.family) {
            .github, .gitlab, .forgejo => {
                try requireJsonObject(response.body);
                features.insert(.issues);
                features.insert(.issue_comments);
                features.insert(.pull_requests);
                features.insert(.pull_request_reviews);
                features.insert(.forks);
                features.insert(.releases);
                features.insert(.labels);
                features.insert(.milestones);
            },
            .origin => {
                try requireJsonObject(response.body);
                if (self.endpoints.create_issue != null) features.insert(.issues);
                if (self.endpoints.create_comment != null) features.insert(.issue_comments);
                if (self.endpoints.create_proposal != null) features.insert(.pull_requests);
                if (self.endpoints.create_fork != null) features.insert(.forks);
            },
            .tangled => {
                try requireJsonObject(response.body);
                if (self.tangled.issue_collection != null) features.insert(.issues);
                if (self.tangled.comment_collection != null) features.insert(.issue_comments);
                if (self.tangled.pull_collection != null) features.insert(.pull_requests);
                if (self.tangled.fork_collection != null) features.insert(.forks);
            },
            .git_wire => {
                if (std.mem.indexOf(u8, response.body, "git-upload-pack") == null and std.mem.indexOf(u8, response.body, "refs/") == null) return error.InvalidDiscoveryResponse;
            },
        }
        return .{
            .family = self.family,
            .features = features,
            .discovered_from = try self.allocator.dupe(u8, response.body),
        };
    }

    pub fn createIssueRequest(self: Driver, input: IssueInput) !Request {
        return switch (self.family) {
            .github => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/repos/{s}/issues", .{self.repository}), .{ .title = input.title, .body = input.body }),
            .origin => self.jsonRequest(.post, try self.configuredPath(self.endpoints.create_issue), .{ .title = input.title, .body = input.body }),
            .gitlab => self.jsonRequest(.post, try self.gitlabPath("issues"), .{ .title = input.title, .description = input.body }),
            .forgejo => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}/issues", .{self.repository}), .{ .title = input.title, .body = input.body }),
            .tangled => self.xrpcRecord(self.tangled.issue_collection orelse return error.UnsupportedFeature, .{ .title = input.title, .body = input.body, .repo = self.repository }),
            .git_wire => error.UnsupportedFeature,
        };
    }

    pub fn createProposalRequest(self: Driver, input: ProposalInput) !Request {
        return switch (self.family) {
            .github => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/repos/{s}/pulls", .{self.repository}), .{ .title = input.title, .body = input.body, .head = input.head, .base = input.base, .draft = input.draft }),
            .origin => self.jsonRequest(.post, try self.configuredPath(self.endpoints.create_proposal), .{ .title = input.title, .body = input.body, .head = input.head, .base = input.base, .draft = input.draft }),
            .gitlab => self.jsonRequest(.post, try self.gitlabPath("merge_requests"), .{ .title = input.title, .description = input.body, .source_branch = input.head, .target_branch = input.base }),
            .forgejo => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}/pulls", .{self.repository}), .{ .title = input.title, .body = input.body, .head = input.head, .base = input.base }),
            .tangled => self.xrpcRecord(self.tangled.pull_collection orelse return error.UnsupportedFeature, .{ .title = input.title, .body = input.body, .source = input.head, .target = input.base, .repo = self.repository }),
            .git_wire => error.UnsupportedFeature,
        };
    }

    pub fn createCommentRequest(self: Driver, input: CommentInput) !Request {
        return switch (self.family) {
            .github => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/repos/{s}/issues/{d}/comments", .{ self.repository, input.target }), .{ .body = input.body }),
            .origin => self.jsonRequest(.post, try self.configuredPath(self.endpoints.create_comment), .{ .target = input.target, .body = input.body }),
            .gitlab => blk: {
                const project = try self.gitlabProjectPath();
                defer self.allocator.free(project);
                break :blk self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "{s}/merge_requests/{d}/notes", .{ project, input.target }), .{ .body = input.body });
            },
            .forgejo => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}/issues/{d}/comments", .{ self.repository, input.target }), .{ .body = input.body }),
            .tangled => self.xrpcRecord(self.tangled.comment_collection orelse return error.UnsupportedFeature, .{ .subject = input.target, .body = input.body, .repo = self.repository }),
            .git_wire => error.UnsupportedFeature,
        };
    }

    pub fn forkRequest(self: Driver) !Request {
        return switch (self.family) {
            .github => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/repos/{s}/forks", .{self.repository}), @as(struct {}, .{})),
            .origin => self.jsonRequest(.post, try self.configuredPath(self.endpoints.create_fork), @as(struct {}, .{})),
            .gitlab => self.jsonRequest(.post, try self.gitlabPath("fork"), @as(struct {}, .{})),
            .forgejo => self.jsonRequest(.post, try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}/forks", .{self.repository}), @as(struct {}, .{})),
            .tangled => self.xrpcRecord(self.tangled.fork_collection orelse return error.UnsupportedFeature, .{ .source = self.repository }),
            .git_wire => error.UnsupportedFeature,
        };
    }

    pub fn listIssuesRequest(self: Driver, page: ?[]const u8) !Request {
        if (page) |next| {
            if (!sameOrigin(self.base_url, next)) return error.UntrustedPaginationUrl;
            return self.makeAbsolute(.get, next, &.{});
        }
        return switch (self.family) {
            .github => self.makeOwned(.get, try std.fmt.allocPrint(self.allocator, "/repos/{s}/issues?per_page=100", .{self.repository}), &.{}),
            .origin => self.makeOwned(.get, try self.configuredPath(self.endpoints.create_issue), &.{}),
            .gitlab => blk: {
                const project = try self.gitlabProjectPath();
                defer self.allocator.free(project);
                break :blk self.makeOwned(.get, try std.fmt.allocPrint(self.allocator, "{s}/issues?per_page=100", .{project}), &.{});
            },
            .forgejo => self.makeOwned(.get, try std.fmt.allocPrint(self.allocator, "/api/v1/repos/{s}/issues?limit=50", .{self.repository}), &.{}),
            .tangled => self.makeOwned(.get, try self.xrpcSubjectPath(self.tangled.list_issues_method), &.{}),
            .git_wire => error.UnsupportedFeature,
        };
    }

    pub fn parsePage(self: Driver, response: Response) !Page {
        if (response.status < 200 or response.status >= 300) return error.RemoteFailure;
        const raw = try self.allocator.dupe(u8, response.body);
        errdefer self.allocator.free(raw);
        const records = try splitRecords(self.allocator, response.body);
        errdefer {
            for (records) |record| self.allocator.free(record);
            self.allocator.free(records);
        }
        return .{
            .records = records,
            .next = try nextPage(self.allocator, self.family, response.headers, response.body),
            .raw = raw,
        };
    }

    pub fn mapError(self: Driver, response: Response) !RemoteError {
        const kind: ErrorKind = switch (response.status) {
            401 => .authentication,
            403 => if (header(response.headers, "x-ratelimit-remaining")) |remaining| if (std.mem.eql(u8, remaining, "0")) .rate_limited else .forbidden else .forbidden,
            404 => .missing,
            409, 412, 422 => if (response.status == 422) .validation else .conflict,
            429 => .rate_limited,
            500...599 => .unavailable,
            else => .protocol,
        };
        const retry = if (header(response.headers, "retry-after")) |value| std.fmt.parseInt(u64, value, 10) catch null else null;
        return .{ .kind = kind, .status = response.status, .retry_after_seconds = retry, .raw = try self.allocator.dupe(u8, response.body) };
    }

    pub fn gitLabMergePushOptions(_: Driver, input: ProposalInput, allocator: std.mem.Allocator) ![][]u8 {
        const options = try allocator.alloc([]u8, 4);
        errdefer allocator.free(options);
        var initialized: usize = 0;
        errdefer for (options[0..initialized]) |option| allocator.free(option);
        options[0] = try allocator.dupe(u8, "merge_request.create");
        initialized += 1;
        options[1] = try std.fmt.allocPrint(allocator, "merge_request.target={s}", .{input.base});
        initialized += 1;
        options[2] = try std.fmt.allocPrint(allocator, "merge_request.title={s}", .{input.title});
        initialized += 1;
        options[3] = try std.fmt.allocPrint(allocator, "merge_request.description={s}", .{input.body});
        return options;
    }

    pub fn agitReference(_: Driver, input: ProposalInput, allocator: std.mem.Allocator) ![]u8 {
        if (!validRefPart(input.base) or !validRefPart(input.head)) return error.InvalidReference;
        return std.fmt.allocPrint(allocator, "refs/for/{s}/{s}", .{ input.base, input.head });
    }

    pub fn xrpcCreateRecordRequest(self: Driver, collection: []const u8, record_json: []const u8) !Request {
        if (self.family != .tangled) return error.UnsupportedFeature;
        try requireJsonObject(record_json);
        const repo_json = try std.json.Stringify.valueAlloc(self.allocator, self.repository, .{});
        defer self.allocator.free(repo_json);
        const collection_json = try std.json.Stringify.valueAlloc(self.allocator, collection, .{});
        defer self.allocator.free(collection_json);
        const body = try std.fmt.allocPrint(self.allocator, "{{\"repo\":{s},\"collection\":{s},\"record\":{s}}}", .{ repo_json, collection_json, record_json });
        errdefer self.allocator.free(body);
        const request = try self.make(.post, "/xrpc/com.atproto.repo.createRecord", body);
        self.allocator.free(request.body);
        var result = request;
        result.body = body;
        return result;
    }

    fn gitlabProjectPath(self: Driver) ![]u8 {
        const encoded = try percentEncode(self.allocator, self.repository);
        defer self.allocator.free(encoded);
        return std.fmt.allocPrint(self.allocator, "/api/v4/projects/{s}", .{encoded});
    }

    fn gitlabPath(self: Driver, suffix: []const u8) ![]u8 {
        const project = try self.gitlabProjectPath();
        defer self.allocator.free(project);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ project, suffix });
    }

    fn xrpcRecord(self: Driver, collection: []const u8, record: anytype) !Request {
        return self.jsonRequest(.post, try self.allocator.dupe(u8, "/xrpc/com.atproto.repo.createRecord"), .{ .repo = self.repository, .collection = collection, .record = record });
    }

    fn xrpcQueryPath(self: Driver, method: ?[]const u8) ![]u8 {
        const value = method orelse return error.UnsupportedFeature;
        const encoded = try percentEncode(self.allocator, self.repository);
        defer self.allocator.free(encoded);
        return std.fmt.allocPrint(self.allocator, "/xrpc/{s}?repo={s}", .{ value, encoded });
    }

    fn xrpcSubjectPath(self: Driver, method: ?[]const u8) ![]u8 {
        const value = method orelse return error.UnsupportedFeature;
        const encoded = try percentEncode(self.allocator, self.repository);
        defer self.allocator.free(encoded);
        return std.fmt.allocPrint(self.allocator, "/xrpc/{s}?subject={s}&limit=50", .{ value, encoded });
    }

    fn configuredPath(self: Driver, value: ?[]const u8) ![]u8 {
        return self.allocator.dupe(u8, value orelse return error.UnsupportedFeature);
    }

    fn jsonRequest(self: Driver, method: Method, path: []u8, value: anytype) !Request {
        defer self.allocator.free(path);
        const body = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        errdefer self.allocator.free(body);
        const request = try self.make(method, path, body);
        self.allocator.free(request.body);
        var result = request;
        result.body = body;
        return result;
    }

    fn make(self: Driver, method: Method, path: []const u8, body: []const u8) !Request {
        const url = try joinUrl(self.allocator, self.base_url, path);
        errdefer self.allocator.free(url);
        const count: usize = if (self.auth == null) 2 else 3;
        const headers = try self.allocator.alloc(Header, count);
        errdefer self.allocator.free(headers);
        headers[0] = .{ .name = "Accept", .value = acceptFor(self.family) };
        headers[1] = .{ .name = "Content-Type", .value = "application/json" };
        if (self.auth) |auth_value| headers[2] = auth_value;
        return .{ .method = method, .url = url, .headers = headers, .body = try self.allocator.dupe(u8, body) };
    }

    fn makeOwned(self: Driver, method: Method, path: []u8, body: []const u8) !Request {
        defer self.allocator.free(path);
        return self.make(method, path, body);
    }

    fn makeAbsolute(self: Driver, method: Method, url_value: []const u8, body: []const u8) !Request {
        const path = if (std.mem.startsWith(u8, url_value, self.base_url)) url_value[self.base_url.len..] else return error.UntrustedPaginationUrl;
        return self.make(method, path, body);
    }
};

const CollaborationResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
};

const collaboration_vtable = collaboration.VTable{
    .discover = collaborationDiscover,
    .create = collaborationCreate,
    .get = collaborationGet,
    .update = collaborationUpdate,
    .delete = collaborationDelete,
    .list = collaborationList,
};

const crud = collaboration.Operations{ .create = .native, .get = .native, .update = .native, .delete = .native, .list = .native };
const no_delete = collaboration.Operations{ .create = .native, .get = .native, .update = .native, .list = .native };
const github_capabilities = [_]collaboration.ResourceCapability{
    .{ .kind = .issue, .operations = no_delete },
    .{ .kind = .change_request, .operations = no_delete },
    .{ .kind = .review, .operations = .{ .create = .native } },
    .{ .kind = .comment, .operations = crud },
    .{ .kind = .fork, .operations = .{ .create = .native, .list = .native } },
    .{ .kind = .check, .operations = no_delete },
    .{ .kind = .release, .operations = crud },
    .{ .kind = .label, .operations = crud },
    .{ .kind = .milestone, .operations = crud },
};
const gitlab_capabilities = [_]collaboration.ResourceCapability{
    .{ .kind = .issue, .operations = no_delete },
    .{ .kind = .change_request, .operations = no_delete },
    .{ .kind = .review, .operations = .{ .create = .native } },
    .{ .kind = .comment, .operations = .{ .create = .native } },
    .{ .kind = .fork, .operations = .{ .create = .native, .list = .native } },
    .{ .kind = .check, .operations = .{ .get = .native, .list = .native } },
    .{ .kind = .release, .operations = crud },
    .{ .kind = .label, .operations = crud },
    .{ .kind = .milestone, .operations = crud },
};
const forgejo_capabilities = [_]collaboration.ResourceCapability{
    .{ .kind = .issue, .operations = no_delete },
    .{ .kind = .change_request, .operations = no_delete },
    .{ .kind = .review, .operations = .{ .create = .native } },
    .{ .kind = .comment, .operations = crud },
    .{ .kind = .fork, .operations = .{ .create = .native, .list = .native } },
    .{ .kind = .release, .operations = crud },
    .{ .kind = .label, .operations = crud },
    .{ .kind = .milestone, .operations = crud },
};

fn configuredResources(allocator: std.mem.Allocator, driver: Driver) ![]const collaboration.ResourceCapability {
    var count: usize = 0;
    if (if (driver.family == .origin) driver.endpoints.create_issue != null else driver.tangled.issue_collection != null) count += 1;
    if (if (driver.family == .origin) driver.endpoints.create_proposal != null else driver.tangled.pull_collection != null) count += 1;
    if (if (driver.family == .origin) driver.endpoints.create_comment != null else driver.tangled.comment_collection != null) count += 1;
    if (if (driver.family == .origin) driver.endpoints.create_fork != null else driver.tangled.fork_collection != null) count += 1;
    const values = try allocator.alloc(collaboration.ResourceCapability, count);
    var index: usize = 0;
    if (if (driver.family == .origin) driver.endpoints.create_issue != null else driver.tangled.issue_collection != null) {
        values[index] = .{ .kind = .issue, .operations = .{ .create = .native } };
        index += 1;
    }
    if (if (driver.family == .origin) driver.endpoints.create_proposal != null else driver.tangled.pull_collection != null) {
        values[index] = .{ .kind = .change_request, .operations = .{ .create = .native } };
        index += 1;
    }
    if (if (driver.family == .origin) driver.endpoints.create_comment != null else driver.tangled.comment_collection != null) {
        values[index] = .{ .kind = .comment, .operations = .{ .create = .native } };
        index += 1;
    }
    if (if (driver.family == .origin) driver.endpoints.create_fork != null else driver.tangled.fork_collection != null) {
        values[index] = .{ .kind = .fork, .operations = .{ .create = .native } };
    }
    return values;
}

fn collaborationDiscover(context: *anyopaque, allocator: std.mem.Allocator, repository: collaboration.RepositoryIdentity) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, repository.repository, self.repository)) return collaborationFailure(allocator, .validation, "repository identity does not match driver", false, null, null);
    const request = self.discoveryRequest() catch |err| switch (err) {
        error.UnsupportedFeature => return collaborationFailure(allocator, .unsupported, "provider discovery endpoint is not configured", false, null, null),
        else => return err,
    };
    defer request.deinit(self.allocator);
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    const found = self.discover(response) catch return collaborationFailure(allocator, .provider_failure, "invalid provider discovery response", false, null, response.body);
    defer found.deinit(self.allocator);
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const arena = result.arena.allocator();
    const extension = try arena.alloc(collaboration.Extension, 1);
    extension[0] = .{ .namespace = "apricot.dev", .name = "discovery", .format = .bytes, .value = try arena.dupe(u8, found.discovered_from) };
    const resources: []const collaboration.ResourceCapability = switch (self.family) {
        .github => &github_capabilities,
        .gitlab => &gitlab_capabilities,
        .forgejo => &forgejo_capabilities,
        .origin, .tangled => try configuredResources(arena, self.*),
        .git_wire => &.{},
    };
    return finishCollaborationResult(result, .{ .discovery = .{
        .contract = collaboration.contract_version,
        .provider = familyName(self.family),
        .protocol_family = protocolFamily(self.family),
        .capabilities = .{ .resources = resources, .pagination = if (resources.len == 0) .unsupported else .native, .conditional_updates = if (self.family == .github or self.family == .forgejo) .native else .unsupported },
        .extensions = extension,
    } });
}

fn collaborationCreate(context: *anyopaque, allocator: std.mem.Allocator, request_value: collaboration.CreateRequest) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, request_value.repository.repository, self.repository)) return collaborationFailure(allocator, .validation, "repository identity does not match driver", false, null, null);
    if (unsupportedDraftField(request_value.draft)) |field| return collaborationFailure(allocator, .unsupported, field, false, null, null);
    const request = switch (request_value.draft.value) {
        .issue => |value| self.createIssueRequest(.{ .title = value.title, .body = value.body }),
        .change_request => |value| self.createProposalRequest(.{
            .title = value.title,
            .body = value.body,
            .head = value.source.revision,
            .base = value.target.revision,
            .draft = value.state == .draft,
        }),
        .comment => |value| blk: {
            const target = std.fmt.parseInt(u64, value.parent.value, 10) catch return collaborationFailure(allocator, .validation, "comment parent id must be numeric for this protocol family", false, null, null);
            if (self.family == .gitlab) {
                const project = try self.gitlabProjectPath();
                defer self.allocator.free(project);
                const segment = if (value.parent_kind == .issue) "issues" else if (value.parent_kind == .change_request) "merge_requests" else return collaborationFailure(allocator, .unsupported, "GitLab notes require an issue or change request parent", false, null, null);
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{d}/notes", .{ project, segment, target });
                const body = try collaborationDraftJsonFor(self.*, request_value.draft);
                defer self.allocator.free(body);
                break :blk self.makeOwned(.post, path, body);
            }
            break :blk self.createCommentRequest(.{ .target = target, .body = value.body });
        },
        .fork => self.forkRequest(),
        .review => |value| blk: {
            const path = reviewCreatePath(self.*, value.change_request.value) catch |err| return pathFailure(allocator, err);
            const body = try reviewDraftJson(self.*, value);
            defer self.allocator.free(body);
            break :blk self.makeOwned(.post, path, body);
        },
        .check, .release, .label, .milestone => blk: {
            if (request_value.draft.kind() == .check and self.family != .github) return collaborationFailure(allocator, .unsupported, "check creation is not supported by this provider protocol", false, null, null);
            const path = restCreatePath(self.*, request_value.draft.kind()) catch |err| return pathFailure(allocator, err);
            const body = try collaborationDraftJsonFor(self.*, request_value.draft);
            defer self.allocator.free(body);
            break :blk self.makeOwned(.post, path, body);
        },
    } catch |err| switch (err) {
        error.UnsupportedFeature => return collaborationFailure(allocator, .unsupported, "provider endpoint or record collection is not configured", false, null, null),
        else => return err,
    };
    defer request.deinit(self.allocator);
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    return collaborationCreatedItem(allocator, self.*, "", request_value.draft, response);
}

fn collaborationGet(context: *anyopaque, allocator: std.mem.Allocator, request_value: collaboration.GetRequest) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    const path = restResourcePath(self.*, request_value.kind, .get, request_value.id.value, null, null) catch |err| return pathFailure(allocator, err);
    const request = try self.makeOwned(.get, path, &.{});
    defer request.deinit(self.allocator);
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    return collaborationItemFromJson(allocator, self.*, request_value.repository, request_value.kind, response);
}

fn collaborationUpdate(context: *anyopaque, allocator: std.mem.Allocator, request_value: collaboration.UpdateRequest) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    if (unsupportedDraftField(request_value.replacement)) |field| return collaborationFailure(allocator, .unsupported, field, false, null, null);
    const kind = request_value.replacement.kind();
    const path = restResourcePath(self.*, kind, .update, request_value.id.value, null, null) catch |err| return pathFailure(allocator, err);
    const body = try collaborationDraftJsonFor(self.*, request_value.replacement);
    defer self.allocator.free(body);
    var request = try self.makeOwned(if (self.family == .gitlab) .put else .patch, path, body);
    defer request.deinit(self.allocator);
    if (request_value.expected_version) |version| {
        const next = try self.allocator.alloc(Header, request.headers.len + 1);
        @memcpy(next[0..request.headers.len], request.headers);
        next[request.headers.len] = .{ .name = "If-Match", .value = version };
        self.allocator.free(request.headers);
        request.headers = next;
    }
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    return collaborationCreatedItem(allocator, self.*, request_value.id.value, request_value.replacement, response);
}

fn collaborationDelete(context: *anyopaque, allocator: std.mem.Allocator, request_value: collaboration.DeleteRequest) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    const path = restResourcePath(self.*, request_value.kind, .delete, request_value.id.value, null, null) catch |err| return pathFailure(allocator, err);
    var request = try self.makeOwned(.delete, path, &.{});
    defer request.deinit(self.allocator);
    if (request_value.expected_version) |version| {
        const next = try self.allocator.alloc(Header, request.headers.len + 1);
        @memcpy(next[0..request.headers.len], request.headers);
        next[request.headers.len] = .{ .name = "If-Match", .value = version };
        self.allocator.free(request.headers);
        request.headers = next;
    }
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const arena = result.arena.allocator();
    return finishCollaborationResult(result, .{ .deleted = .{ .provider = familyName(self.family), .value = try arena.dupe(u8, request_value.id.value) } });
}

fn collaborationList(context: *anyopaque, allocator: std.mem.Allocator, request_value: collaboration.ListRequest) !collaboration.Handle {
    const self: *Driver = @ptrCast(@alignCast(context));
    if (request_value.cursor) |cursor| {
        if ((std.mem.startsWith(u8, cursor, "https://") or std.mem.startsWith(u8, cursor, "http://")) and !sameOrigin(self.base_url, cursor)) return collaborationFailure(allocator, .validation, "pagination cursor has a different origin", false, null, null);
    }
    var path = restResourcePath(self.*, request_value.kind, .list, null, request_value.cursor, request_value.limit) catch |err| return pathFailure(allocator, err);
    if (request_value.cursor) |cursor| {
        if (!std.mem.startsWith(u8, cursor, "https://") and !std.mem.startsWith(u8, cursor, "http://")) {
            for (cursor) |byte| if (!std.ascii.isDigit(byte)) return collaborationFailure(allocator, .validation, "pagination cursor is malformed", false, null, null);
            const paged = try std.fmt.allocPrint(self.allocator, "{s}&page={s}", .{ path, cursor });
            self.allocator.free(path);
            path = paged;
        }
    }
    const absolute_cursor = if (request_value.cursor) |cursor| std.mem.startsWith(u8, cursor, "https://") or std.mem.startsWith(u8, cursor, "http://") else false;
    const request = if (absolute_cursor) try self.makeAbsolute(.get, request_value.cursor.?, &.{}) else try self.makeOwned(.get, path, &.{});
    if (absolute_cursor) self.allocator.free(path);
    defer request.deinit(self.allocator);
    const response = try transportRequest(self.*, request);
    if (response.status < 200 or response.status >= 300) return collaborationRemoteFailure(self.*, allocator, response);
    return collaborationPageFromJson(allocator, self.*, request_value.repository, request_value.kind, response);
}

fn transportRequest(self: Driver, request: Request) !Response {
    const transport = self.transport orelse return error.TransportNotConfigured;
    return transport.request(request);
}

fn newCollaborationResult(allocator: std.mem.Allocator) !*CollaborationResult {
    const result = try allocator.create(CollaborationResult);
    result.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    return result;
}

fn finishCollaborationResult(result: *CollaborationResult, response: collaboration.Response) collaboration.Handle {
    return .{ .context = result, .response = response, .release_fn = releaseCollaborationResult };
}

fn releaseCollaborationResult(context: *anyopaque) void {
    const result: *CollaborationResult = @ptrCast(@alignCast(context));
    const allocator = result.allocator;
    result.arena.deinit();
    allocator.destroy(result);
}

fn collaborationFailure(allocator: std.mem.Allocator, code: collaboration.FailureCode, message: []const u8, retryable: bool, retry_after: ?u64, raw: ?[]const u8) !collaboration.Handle {
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const arena = result.arena.allocator();
    const extensions: []const collaboration.Extension = if (raw) |value| blk: {
        const items = try arena.alloc(collaboration.Extension, 1);
        items[0] = .{ .namespace = "apricot.dev", .name = "provider-error", .format = .bytes, .value = try arena.dupe(u8, value) };
        break :blk items;
    } else &.{};
    return finishCollaborationResult(result, .{ .failure = .{
        .code = code,
        .message = try arena.dupe(u8, message),
        .retryable = retryable,
        .retry_after_seconds = retry_after,
        .extensions = extensions,
    } });
}

fn collaborationRemoteFailure(self: Driver, allocator: std.mem.Allocator, response: Response) !collaboration.Handle {
    const mapped = try self.mapError(response);
    defer mapped.deinit(self.allocator);
    const code: collaboration.FailureCode = switch (mapped.kind) {
        .authentication => .unauthenticated,
        .forbidden => .forbidden,
        .missing => .not_found,
        .conflict => .conflict,
        .validation => .validation,
        .rate_limited => .rate_limited,
        .unavailable => .unavailable,
        .protocol => .provider_failure,
    };
    return collaborationFailure(allocator, code, "provider request failed", code == .rate_limited or code == .unavailable, mapped.retry_after_seconds, mapped.raw);
}

fn familyName(family: Family) []const u8 {
    return switch (family) {
        .github => "github-rest",
        .origin => "origin-rest",
        .gitlab => "gitlab-rest",
        .forgejo => "forgejo-rest",
        .tangled => "tangled-atproto",
        .git_wire => "git-wire",
    };
}

fn protocolFamily(family: Family) collaboration.ProtocolFamily {
    return switch (family) {
        .github, .origin, .gitlab, .forgejo => .rest,
        .tangled => .custom,
        .git_wire => .command,
    };
}

fn responseId(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    inline for (.{ "id", "iid", "uri", "rkey" }) |name| {
        if (try jsonStringField(allocator, body, name)) |value| return value;
        if (try jsonIntegerField(allocator, body, name)) |value| return value;
    }
    return error.MissingProviderIdentity;
}

fn responseResourceId(allocator: std.mem.Allocator, driver: Driver, kind: collaboration.ResourceKind, body: []const u8) ![]const u8 {
    const field: ?[]const u8 = switch (driver.family) {
        .github, .forgejo => if (kind == .issue or kind == .change_request) "number" else null,
        .gitlab => if (kind == .issue or kind == .change_request) "iid" else null,
        else => null,
    };
    if (field) |name| if (try jsonIntegerField(allocator, body, name)) |value| return value;
    return responseId(allocator, body);
}

fn jsonIntegerField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !?[]u8 {
    const key = try std.fmt.allocPrint(allocator, "\"{s}\"", .{field});
    defer allocator.free(key);
    const marker = std.mem.indexOf(u8, body, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, body, marker + key.len, ':') orelse return error.InvalidJson;
    var start = colon + 1;
    while (start < body.len and std.ascii.isWhitespace(body[start])) start += 1;
    var end = start;
    while (end < body.len and std.ascii.isDigit(body[end])) end += 1;
    if (end == start) return null;
    return try allocator.dupe(u8, body[start..end]);
}

fn cloneCollaborationExtensions(allocator: std.mem.Allocator, source: []const collaboration.Extension, raw: []const u8) ![]const collaboration.Extension {
    const values = try allocator.alloc(collaboration.Extension, source.len + 1);
    for (source, 0..) |item, index| values[index] = .{
        .namespace = try allocator.dupe(u8, item.namespace),
        .name = try allocator.dupe(u8, item.name),
        .format = item.format,
        .value = try allocator.dupe(u8, item.value),
    };
    values[source.len] = .{ .namespace = "apricot.dev", .name = "provider-response", .format = .bytes, .value = try allocator.dupe(u8, raw) };
    return values;
}

fn cloneCollaborationId(allocator: std.mem.Allocator, value: collaboration.OpaqueId) !collaboration.OpaqueId {
    return .{ .provider = try allocator.dupe(u8, value.provider), .value = try allocator.dupe(u8, value.value) };
}

fn cloneCollaborationRepository(allocator: std.mem.Allocator, value: collaboration.RepositoryIdentity) !collaboration.RepositoryIdentity {
    return .{
        .vcs = try allocator.dupe(u8, value.vcs),
        .repository = try allocator.dupe(u8, value.repository),
        .extensions = try cloneBaseExtensions(allocator, value.extensions),
    };
}

fn cloneCollaborationRevision(allocator: std.mem.Allocator, value: collaboration.RevisionIdentity) !collaboration.RevisionIdentity {
    return .{
        .vcs = try allocator.dupe(u8, value.vcs),
        .repository = try allocator.dupe(u8, value.repository),
        .revision = try allocator.dupe(u8, value.revision),
        .extensions = try cloneBaseExtensions(allocator, value.extensions),
    };
}

fn cloneCollaborationActor(allocator: std.mem.Allocator, value: collaboration.Actor) !collaboration.Actor {
    return .{
        .id = try cloneCollaborationId(allocator, value.id),
        .login = try allocator.dupe(u8, value.login),
        .display_name = try allocator.dupe(u8, value.display_name),
        .extensions = try cloneBaseExtensions(allocator, value.extensions),
    };
}

fn cloneBaseExtensions(allocator: std.mem.Allocator, source: []const collaboration.Extension) ![]const collaboration.Extension {
    const values = try allocator.alloc(collaboration.Extension, source.len);
    for (source, 0..) |item, index| values[index] = .{
        .namespace = try allocator.dupe(u8, item.namespace),
        .name = try allocator.dupe(u8, item.name),
        .format = item.format,
        .value = try allocator.dupe(u8, item.value),
    };
    return values;
}

fn cloneCollaborationIds(allocator: std.mem.Allocator, source: []const collaboration.OpaqueId) ![]const collaboration.OpaqueId {
    const values = try allocator.alloc(collaboration.OpaqueId, source.len);
    for (source, 0..) |item, index| values[index] = try cloneCollaborationId(allocator, item);
    return values;
}

fn cloneReleaseAssets(allocator: std.mem.Allocator, source: []const collaboration.ReleaseAsset) ![]const collaboration.ReleaseAsset {
    const values = try allocator.alloc(collaboration.ReleaseAsset, source.len);
    for (source, 0..) |item, index| values[index] = .{
        .name = try allocator.dupe(u8, item.name),
        .media_type = try allocator.dupe(u8, item.media_type),
        .size = item.size,
        .digest = try allocator.dupe(u8, item.digest),
        .download_url = if (item.download_url) |url| try allocator.dupe(u8, url) else null,
        .extensions = try cloneBaseExtensions(allocator, item.extensions),
    };
    return values;
}

fn cloneCollaborationValue(allocator: std.mem.Allocator, value: collaboration.ResourceValue) !collaboration.ResourceValue {
    return switch (value) {
        .issue => |item| .{ .issue = .{
            .title = try allocator.dupe(u8, item.title),
            .body = try allocator.dupe(u8, item.body),
            .state = item.state,
            .labels = try cloneCollaborationIds(allocator, item.labels),
            .milestone = if (item.milestone) |milestone| try cloneCollaborationId(allocator, milestone) else null,
            .assignees = try cloneCollaborationIds(allocator, item.assignees),
        } },
        .change_request => |item| .{ .change_request = .{
            .title = try allocator.dupe(u8, item.title),
            .body = try allocator.dupe(u8, item.body),
            .state = item.state,
            .source_repository = try cloneCollaborationRepository(allocator, item.source_repository),
            .source = try cloneCollaborationRevision(allocator, item.source),
            .target = try cloneCollaborationRevision(allocator, item.target),
            .labels = try cloneCollaborationIds(allocator, item.labels),
            .milestone = if (item.milestone) |milestone| try cloneCollaborationId(allocator, milestone) else null,
        } },
        .comment => |item| .{ .comment = .{
            .parent_kind = item.parent_kind,
            .parent = try cloneCollaborationId(allocator, item.parent),
            .body = try allocator.dupe(u8, item.body),
            .revision = if (item.revision) |revision| try cloneCollaborationRevision(allocator, revision) else null,
            .path = if (item.path) |path| try allocator.dupe(u8, path) else null,
            .line = item.line,
        } },
        .fork => |item| .{ .fork = .{
            .source = try cloneCollaborationRepository(allocator, item.source),
            .destination = try cloneCollaborationRepository(allocator, item.destination),
            .state = item.state,
        } },
        .review => |item| .{ .review = .{
            .change_request = try cloneCollaborationId(allocator, item.change_request),
            .body = try allocator.dupe(u8, item.body),
            .verdict = item.verdict,
            .revision = if (item.revision) |revision| try cloneCollaborationRevision(allocator, revision) else null,
        } },
        .check => |item| .{ .check = .{
            .name = try allocator.dupe(u8, item.name),
            .revision = try cloneCollaborationRevision(allocator, item.revision),
            .state = item.state,
            .summary = try allocator.dupe(u8, item.summary),
            .details_url = if (item.details_url) |url| try allocator.dupe(u8, url) else null,
        } },
        .release => |item| .{ .release = .{
            .name = try allocator.dupe(u8, item.name),
            .body = try allocator.dupe(u8, item.body),
            .revision = try cloneCollaborationRevision(allocator, item.revision),
            .state = item.state,
            .assets = try cloneReleaseAssets(allocator, item.assets),
        } },
        .label => |item| .{ .label = .{
            .name = try allocator.dupe(u8, item.name),
            .color = try allocator.dupe(u8, item.color),
            .description = try allocator.dupe(u8, item.description),
        } },
        .milestone => |item| .{ .milestone = .{
            .title = try allocator.dupe(u8, item.title),
            .description = try allocator.dupe(u8, item.description),
            .state = item.state,
            .due_at = item.due_at,
        } },
    };
}

const RestOperation = enum { get, update, delete, list };

fn restCreatePath(driver: Driver, kind: collaboration.ResourceKind) ![]u8 {
    const list = try restResourcePath(driver, kind, .list, null, null, 50);
    const query = std.mem.indexOfScalar(u8, list, '?') orelse return list;
    const result = try driver.allocator.dupe(u8, list[0..query]);
    driver.allocator.free(list);
    return result;
}

fn reviewCreatePath(driver: Driver, parent: []const u8) ![]u8 {
    if (driver.family == .origin or driver.family == .tangled or driver.family == .git_wire) return error.UnsupportedFeature;
    const encoded = try percentEncode(driver.allocator, parent);
    defer driver.allocator.free(encoded);
    return switch (driver.family) {
        .github => std.fmt.allocPrint(driver.allocator, "/repos/{s}/pulls/{s}/reviews", .{ driver.repository, encoded }),
        .forgejo => std.fmt.allocPrint(driver.allocator, "/api/v1/repos/{s}/pulls/{s}/reviews", .{ driver.repository, encoded }),
        .gitlab => blk: {
            const project = try driver.gitlabProjectPath();
            defer driver.allocator.free(project);
            break :blk std.fmt.allocPrint(driver.allocator, "{s}/merge_requests/{s}/approve", .{ project, encoded });
        },
        else => unreachable,
    };
}

fn restResourcePath(driver: Driver, kind: collaboration.ResourceKind, operation: RestOperation, id: ?[]const u8, cursor: ?[]const u8, limit: ?u32) ![]u8 {
    _ = cursor;
    if (driver.family == .origin or driver.family == .tangled or driver.family == .git_wire) return error.UnsupportedFeature;
    if ((kind == .issue or kind == .change_request) and operation == .delete) return error.UnsupportedFeature;
    if ((kind == .review or kind == .fork) and (operation == .update or operation == .delete)) return error.UnsupportedFeature;
    const collection = switch (driver.family) {
        .github, .forgejo => switch (kind) {
            .issue => "issues",
            .change_request => "pulls",
            .comment => "issues/comments",
            .fork => "forks",
            .check => "check-runs",
            .release => "releases",
            .label => "labels",
            .milestone => "milestones",
            .review => return error.RequiresParentIdentity,
        },
        .gitlab => switch (kind) {
            .issue => "issues",
            .change_request => "merge_requests",
            .comment => return error.RequiresParentIdentity,
            .fork => "forks",
            .check => "pipelines",
            .release => "releases",
            .label => "labels",
            .milestone => "milestones",
            .review => return error.RequiresParentIdentity,
        },
        else => unreachable,
    };
    const root = switch (driver.family) {
        .github => try std.fmt.allocPrint(driver.allocator, "/repos/{s}/{s}", .{ driver.repository, collection }),
        .forgejo => try std.fmt.allocPrint(driver.allocator, "/api/v1/repos/{s}/{s}", .{ driver.repository, collection }),
        .gitlab => blk: {
            const project = try driver.gitlabProjectPath();
            defer driver.allocator.free(project);
            break :blk try std.fmt.allocPrint(driver.allocator, "{s}/{s}", .{ project, collection });
        },
        else => unreachable,
    };
    if (operation == .list) {
        const result = try std.fmt.allocPrint(driver.allocator, "{s}?per_page={d}", .{ root, limit orelse 50 });
        driver.allocator.free(root);
        return result;
    }
    const identity = id orelse {
        driver.allocator.free(root);
        return error.MissingProviderIdentity;
    };
    const encoded = try percentEncode(driver.allocator, identity);
    defer driver.allocator.free(encoded);
    const result = try std.fmt.allocPrint(driver.allocator, "{s}/{s}", .{ root, encoded });
    driver.allocator.free(root);
    return result;
}

fn pathFailure(allocator: std.mem.Allocator, err: anyerror) !collaboration.Handle {
    return switch (err) {
        error.RequiresParentIdentity => collaborationFailure(allocator, .validation, "resource id requires its parent provider identity", false, null, null),
        error.UnsupportedFeature => collaborationFailure(allocator, .unsupported, "operation is not supported by this provider protocol", false, null, null),
        else => err,
    };
}

fn collaborationDraftJsonFor(driver: Driver, draft: collaboration.ResourceDraft) ![]u8 {
    const allocator = driver.allocator;
    return switch (draft.value) {
        .issue => |value| if (driver.family == .gitlab)
            std.json.Stringify.valueAlloc(allocator, .{ .title = value.title, .description = value.body, .state_event = if (value.state == .closed) "close" else "reopen" }, .{})
        else
            std.json.Stringify.valueAlloc(allocator, .{ .title = value.title, .body = value.body, .state = @tagName(value.state) }, .{}),
        .change_request => |value| if (driver.family == .gitlab)
            std.json.Stringify.valueAlloc(allocator, .{ .title = value.title, .description = value.body, .source_branch = value.source.revision, .target_branch = value.target.revision, .state_event = if (value.state == .closed) "close" else "reopen" }, .{})
        else
            std.json.Stringify.valueAlloc(allocator, .{ .title = value.title, .body = value.body, .head = value.source.revision, .base = value.target.revision, .state = @tagName(value.state) }, .{}),
        .review => |value| reviewDraftJson(driver, value),
        .comment => |value| std.json.Stringify.valueAlloc(allocator, .{ .body = value.body }, .{}),
        .fork => std.json.Stringify.valueAlloc(allocator, @as(struct {}, .{}), .{}),
        .check => |value| std.json.Stringify.valueAlloc(allocator, .{ .name = value.name, .head_sha = value.revision.revision, .status = @tagName(value.state), .output = .{ .title = value.name, .summary = value.summary } }, .{}),
        .release => |value| std.json.Stringify.valueAlloc(allocator, .{ .name = value.name, .description = value.body, .body = value.body, .tag_name = value.revision.revision }, .{}),
        .label => |value| std.json.Stringify.valueAlloc(allocator, .{ .name = value.name, .color = value.color, .description = value.description }, .{}),
        .milestone => |value| std.json.Stringify.valueAlloc(allocator, .{ .title = value.title, .description = value.description, .state = @tagName(value.state), .due_on = value.due_at }, .{}),
    };
}

fn unsupportedDraftField(draft: collaboration.ResourceDraft) ?[]const u8 {
    return switch (draft.value) {
        .issue => |value| if (value.labels.len != 0 or value.assignees.len != 0 or value.milestone != null) "issue associations are not supported by this provider protocol driver" else null,
        .change_request => |value| if (value.labels.len != 0 or value.milestone != null) "change request associations are not supported by this provider protocol driver" else null,
        .release => |value| if (value.assets.len != 0) "release asset transfer requires a dedicated provider asset operation" else null,
        else => null,
    };
}

fn reviewDraftJson(driver: Driver, value: collaboration.Review) ![]u8 {
    if (driver.family == .gitlab) return std.json.Stringify.valueAlloc(driver.allocator, .{}, .{});
    const event = switch (value.verdict) {
        .approved => "APPROVE",
        .changes_requested => "REQUEST_CHANGES",
        .commented, .pending => "COMMENT",
        .dismissed => return error.UnsupportedFeature,
    };
    return std.json.Stringify.valueAlloc(driver.allocator, .{ .body = value.body, .event = event }, .{});
}

fn collaborationCreatedItem(allocator: std.mem.Allocator, driver: Driver, fallback_id: []const u8, draft: collaboration.ResourceDraft, response: Response) !collaboration.Handle {
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const arena = result.arena.allocator();
    const id = responseResourceId(arena, driver, draft.kind(), response.body) catch try arena.dupe(u8, fallback_id);
    return finishCollaborationResult(result, .{ .item = .{
        .id = .{ .provider = familyName(driver.family), .value = id },
        .version = if (header(response.headers, "etag")) |etag| try arena.dupe(u8, etag) else id,
        .created_at = 0,
        .updated_at = 0,
        .author = if (draft.author) |author| try cloneCollaborationActor(arena, author) else null,
        .extensions = try cloneCollaborationExtensions(arena, draft.extensions, response.body),
        .value = try cloneCollaborationValue(arena, draft.value),
    } });
}

fn collaborationItemFromJson(allocator: std.mem.Allocator, driver: Driver, repository: collaboration.RepositoryIdentity, kind: collaboration.ResourceKind, response: Response) !collaboration.Handle {
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const resource = try parseCollaborationResource(result.arena.allocator(), driver, repository, kind, response.body, response.headers);
    return finishCollaborationResult(result, .{ .item = resource });
}

fn collaborationPageFromJson(allocator: std.mem.Allocator, driver: Driver, repository: collaboration.RepositoryIdentity, kind: collaboration.ResourceKind, response: Response) !collaboration.Handle {
    const result = try newCollaborationResult(allocator);
    errdefer releaseCollaborationResult(result);
    const arena = result.arena.allocator();
    const records = try splitRecords(arena, response.body);
    const items = try arena.alloc(collaboration.Resource, records.len);
    for (records, 0..) |record, index| items[index] = try parseCollaborationResource(arena, driver, repository, kind, record, &.{});
    const next = try nextPage(arena, driver.family, response.headers, response.body);
    const extensions = try arena.alloc(collaboration.Extension, 1);
    extensions[0] = .{ .namespace = "apricot.dev", .name = "provider-page", .format = .bytes, .value = try arena.dupe(u8, response.body) };
    return finishCollaborationResult(result, .{ .page = .{ .items = items, .next_cursor = next, .extensions = extensions } });
}

fn parseCollaborationResource(allocator: std.mem.Allocator, driver: Driver, repository: collaboration.RepositoryIdentity, kind: collaboration.ResourceKind, body: []const u8, headers: []const Header) !collaboration.Resource {
    const id = try responseResourceId(allocator, driver, kind, body);
    const title = try jsonStringAny(allocator, body, &.{ "title", "name" }, "");
    const description = try jsonStringAny(allocator, body, &.{ "body", "description", "summary" }, "");
    const state_text = try jsonStringAny(allocator, body, &.{ "state", "status", "conclusion" }, "open");
    const state = parseCollaborationState(state_text);
    const source_revision = try jsonStringAny(allocator, body, &.{ "source_branch", "head", "head_sha", "sha" }, "");
    const target_revision = try jsonStringAny(allocator, body, &.{ "target_branch", "base", "tag_name" }, "");
    const repo = try cloneCollaborationRepository(allocator, repository);
    const value: collaboration.ResourceValue = switch (kind) {
        .issue => .{ .issue = .{ .title = title, .body = description, .state = state } },
        .change_request => .{ .change_request = .{
            .title = title,
            .body = description,
            .state = state,
            .source_repository = repo,
            .source = .{ .vcs = repo.vcs, .repository = repo.repository, .revision = source_revision },
            .target = .{ .vcs = repo.vcs, .repository = repo.repository, .revision = target_revision },
        } },
        .review => .{ .review = .{ .change_request = .{ .provider = familyName(driver.family), .value = "" }, .body = description, .verdict = parseReviewVerdict(state_text) } },
        .comment => .{ .comment = .{ .parent_kind = .issue, .parent = .{ .provider = familyName(driver.family), .value = "" }, .body = description } },
        .fork => .{ .fork = .{ .source = repo, .destination = repo, .state = state } },
        .check => .{ .check = .{ .name = title, .revision = .{ .vcs = repo.vcs, .repository = repo.repository, .revision = source_revision }, .state = state, .summary = description } },
        .release => .{ .release = .{ .name = title, .body = description, .revision = .{ .vcs = repo.vcs, .repository = repo.repository, .revision = target_revision }, .state = state } },
        .label => .{ .label = .{ .name = title, .color = try jsonStringAny(allocator, body, &.{"color"}, ""), .description = description } },
        .milestone => .{ .milestone = .{ .title = title, .description = description, .state = state } },
    };
    const extensions = try allocator.alloc(collaboration.Extension, 1);
    extensions[0] = .{ .namespace = "apricot.dev", .name = "provider-response", .format = .bytes, .value = try allocator.dupe(u8, body) };
    return .{
        .id = .{ .provider = familyName(driver.family), .value = id },
        .version = if (header(headers, "etag")) |etag| try allocator.dupe(u8, etag) else id,
        .created_at = 0,
        .updated_at = 0,
        .author = null,
        .extensions = extensions,
        .value = value,
    };
}

fn jsonStringAny(allocator: std.mem.Allocator, body: []const u8, fields: []const []const u8, fallback: []const u8) ![]const u8 {
    for (fields) |field| if (try jsonStringField(allocator, body, field)) |value| return value;
    return allocator.dupe(u8, fallback);
}

fn parseCollaborationState(value: []const u8) collaboration.State {
    if (std.ascii.eqlIgnoreCase(value, "closed")) return .closed;
    if (std.ascii.eqlIgnoreCase(value, "merged")) return .merged;
    if (std.ascii.eqlIgnoreCase(value, "draft")) return .draft;
    if (std.ascii.eqlIgnoreCase(value, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(value, "running") or std.ascii.eqlIgnoreCase(value, "in_progress")) return .running;
    if (std.ascii.eqlIgnoreCase(value, "success") or std.ascii.eqlIgnoreCase(value, "passed")) return .passed;
    if (std.ascii.eqlIgnoreCase(value, "failure") or std.ascii.eqlIgnoreCase(value, "failed")) return .failed;
    if (std.ascii.eqlIgnoreCase(value, "cancelled")) return .cancelled;
    if (std.ascii.eqlIgnoreCase(value, "archived")) return .archived;
    return .open;
}

fn parseReviewVerdict(value: []const u8) collaboration.ReviewVerdict {
    if (std.ascii.eqlIgnoreCase(value, "approved") or std.ascii.eqlIgnoreCase(value, "approve")) return .approved;
    if (std.ascii.eqlIgnoreCase(value, "changes_requested") or std.ascii.eqlIgnoreCase(value, "request_changes")) return .changes_requested;
    if (std.ascii.eqlIgnoreCase(value, "dismissed")) return .dismissed;
    if (std.ascii.eqlIgnoreCase(value, "commented") or std.ascii.eqlIgnoreCase(value, "comment")) return .commented;
    return .pending;
}

pub fn freeOptions(allocator: std.mem.Allocator, options: [][]u8) void {
    for (options) |option| allocator.free(option);
    allocator.free(options);
}

fn acceptFor(family: Family) []const u8 {
    return switch (family) {
        .github => "application/vnd.github+json",
        .origin => "application/json",
        .gitlab, .forgejo => "application/json",
        .tangled => "application/json",
        .git_wire => "application/x-git-upload-pack-advertisement",
    };
}

fn joinUrl(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (base.len == 0 or path.len == 0) return error.InvalidUrl;
    const slash = std.mem.endsWith(u8, base, "/") and std.mem.startsWith(u8, path, "/");
    const missing = !std.mem.endsWith(u8, base, "/") and !std.mem.startsWith(u8, path, "/");
    return if (slash)
        std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path[1..] })
    else if (missing)
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path })
    else
        std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
}

fn percentEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn requireJsonObject(body: []const u8) !void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidDiscoveryResponse;
}

fn header(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
    return null;
}

fn nextPage(allocator: std.mem.Allocator, family: Family, headers: []const Header, body: []const u8) !?[]u8 {
    if (family == .gitlab) {
        if (header(headers, "x-next-page")) |page| {
            if (page.len == 0) return null;
            return try allocator.dupe(u8, page);
        }
    }
    if (header(headers, "link")) |link| {
        var parts = std.mem.splitScalar(u8, link, ',');
        while (parts.next()) |part| {
            if (std.mem.indexOf(u8, part, "rel=\"next\"") == null) continue;
            const start = std.mem.indexOfScalar(u8, part, '<') orelse return error.InvalidPagination;
            const end = std.mem.indexOfScalarPos(u8, part, start + 1, '>') orelse return error.InvalidPagination;
            return try allocator.dupe(u8, part[start + 1 .. end]);
        }
    }
    if (family == .tangled) {
        if (try jsonStringField(allocator, body, "cursor")) |cursor| return cursor;
    }
    return null;
}

fn splitRecords(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc([]u8, 0);
    const array = if (trimmed[0] == '[') trimmed else blk: {
        const marker = std.mem.indexOf(u8, trimmed, "\"records\"") orelse std.mem.indexOf(u8, trimmed, "\"items\"") orelse return error.InvalidPage;
        const start = std.mem.indexOfScalarPos(u8, trimmed, marker, '[') orelse return error.InvalidPage;
        break :blk trimmed[start..];
    };
    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    var index: usize = 1;
    while (index < array.len) {
        while (index < array.len and (std.ascii.isWhitespace(array[index]) or array[index] == ',')) index += 1;
        if (index >= array.len or array[index] == ']') break;
        const start = index;
        const end = try jsonValueEnd(array, index);
        try values.append(allocator, try allocator.dupe(u8, array[start..end]));
        index = end;
    }
    return values.toOwnedSlice(allocator);
}

fn jsonValueEnd(input: []const u8, start: usize) !usize {
    if (start >= input.len) return error.InvalidJson;
    if (input[start] == '"') {
        var escaped = false;
        var string_index = start + 1;
        while (string_index < input.len) : (string_index += 1) {
            const byte = input[string_index];
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                return string_index + 1;
            }
        }
        return error.InvalidJson;
    }
    if (input[start] != '{' and input[start] != '[' and input[start] != '"') {
        var end = start;
        while (end < input.len and input[end] != ',' and input[end] != ']') end += 1;
        return end;
    }
    var depth: usize = 0;
    var string = false;
    var escaped = false;
    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') string = false;
            continue;
        }
        if (byte == '"') {
            string = true;
        } else if (byte == '{' or byte == '[') {
            depth += 1;
        } else if (byte == '}' or byte == ']') {
            if (depth == 0) return error.InvalidJson;
            depth -= 1;
            if (depth == 0) return index + 1;
        }
    }
    return error.InvalidJson;
}

fn jsonStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !?[]u8 {
    const key = try std.fmt.allocPrint(allocator, "\"{s}\"", .{field});
    defer allocator.free(key);
    const marker = std.mem.indexOf(u8, body, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, body, marker + key.len, ':') orelse return error.InvalidJson;
    var start = colon + 1;
    while (start < body.len and std.ascii.isWhitespace(body[start])) start += 1;
    if (start >= body.len or body[start] != '"') return null;
    const end = try jsonValueEnd(body, start);
    if (end < start + 2) return error.InvalidJson;
    return try allocator.dupe(u8, body[start + 1 .. end - 1]);
}

fn sameOrigin(base: []const u8, next: []const u8) bool {
    if (!std.mem.startsWith(u8, next, base)) return false;
    return next.len == base.len or next[base.len] == '/' or next[base.len] == '?';
}

fn validRefPart(value: []const u8) bool {
    if (value.len == 0 or value[0] == '/' or value[value.len - 1] == '/') return false;
    if (std.mem.indexOfAny(u8, value, " ~^:?*[\\\r\n") != null) return false;
    if (std.mem.indexOf(u8, value, "..") != null or std.mem.indexOf(u8, value, "@{") != null) return false;
    return true;
}

test "protocol families build native collaboration requests" {
    const allocator = std.testing.allocator;
    const proposal = ProposalInput{ .title = "Native change", .body = "Exact state", .head = "feature", .base = "main" };
    const fixtures = [_]struct { family: Family, base: []const u8, repository: []const u8, path: []const u8 }{
        .{ .family = .github, .base = "https://api.github.com", .repository = "acme/code", .path = "/repos/acme/code/pulls" },
        .{ .family = .gitlab, .base = "https://gitlab.example", .repository = "acme/code", .path = "/api/v4/projects/acme%2Fcode/merge_requests" },
        .{ .family = .forgejo, .base = "https://codeberg.example", .repository = "acme/code", .path = "/api/v1/repos/acme/code/pulls" },
        .{ .family = .tangled, .base = "https://tangled.example", .repository = "did:plc:abc", .path = "/xrpc/com.atproto.repo.createRecord" },
    };
    for (fixtures) |fixture| {
        const driver = Driver{
            .allocator = allocator,
            .family = fixture.family,
            .base_url = fixture.base,
            .repository = fixture.repository,
            .tangled = if (fixture.family == .tangled) .{ .pull_collection = "sh.tangled.repo.pull" } else .{},
        };
        const request = try driver.createProposalRequest(proposal);
        defer request.deinit(allocator);
        try std.testing.expectEqual(Method.post, request.method);
        try std.testing.expect(std.mem.endsWith(u8, request.url, fixture.path));
        try std.testing.expect(std.mem.indexOf(u8, request.body, "Native change") != null);
    }
}

test "discovery exposes family capabilities from fixture responses" {
    const allocator = std.testing.allocator;
    const families = [_]Family{ .github, .gitlab, .forgejo, .tangled };
    for (families) |family| {
        const driver = Driver{
            .allocator = allocator,
            .family = family,
            .base_url = "https://forge.example",
            .repository = "acme/code",
            .tangled = if (family == .tangled) .{ .issue_collection = "sh.tangled.repo.issue", .pull_collection = "sh.tangled.repo.pull" } else .{},
        };
        const capabilities = try driver.discover(.{ .status = 200, .body = "{\"unknown\":{\"exact\":true}}" });
        defer capabilities.deinit(allocator);
        try std.testing.expect(capabilities.supports(.issues));
        try std.testing.expect(capabilities.supports(.pull_requests));
        try std.testing.expectEqualStrings("{\"unknown\":{\"exact\":true}}", capabilities.discovered_from);
    }
}

test "pages preserve unknown records byte exactly and follow pagination" {
    const allocator = std.testing.allocator;
    const driver = Driver{ .allocator = allocator, .family = .github, .base_url = "https://api.example", .repository = "acme/code" };
    const body = "[ {\"id\":1, \"future\": [3,2,1]}, {\"id\":2,\"opaque\":\"x\\\"y\"} ]";
    const headers = [_]Header{.{ .name = "Link", .value = "<https://api.example/repos/acme/code/issues?page=2>; rel=\"next\", <https://api.example/repos/acme/code/issues?page=4>; rel=\"last\"" }};
    const page = try driver.parsePage(.{ .status = 200, .headers = &headers, .body = body });
    defer page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), page.records.len);
    try std.testing.expectEqualStrings("{\"id\":1, \"future\": [3,2,1]}", page.records[0]);
    try std.testing.expectEqualStrings("{\"id\":2,\"opaque\":\"x\\\"y\"}", page.records[1]);
    try std.testing.expectEqualStrings("https://api.example/repos/acme/code/issues?page=2", page.next.?);
    try std.testing.expectEqualStrings(body, page.raw);
}

test "push proposal dialects and error mapping are deterministic" {
    const allocator = std.testing.allocator;
    const input = ProposalInput{ .title = "A title", .body = "A body", .head = "topic", .base = "main" };
    const driver = Driver{ .allocator = allocator, .family = .gitlab, .base_url = "https://forge.example", .repository = "acme/code" };
    const options = try driver.gitLabMergePushOptions(input, allocator);
    defer freeOptions(allocator, options);
    try std.testing.expectEqualStrings("merge_request.create", options[0]);
    try std.testing.expectEqualStrings("merge_request.target=main", options[1]);
    const agit = try driver.agitReference(input, allocator);
    defer allocator.free(agit);
    try std.testing.expectEqualStrings("refs/for/main/topic", agit);
    const headers = [_]Header{
        .{ .name = "Retry-After", .value = "17" },
        .{ .name = "X-RateLimit-Remaining", .value = "0" },
    };
    const mapped = try driver.mapError(.{ .status = 403, .headers = &headers, .body = "{\"message\":\"slow\",\"future\":42}" });
    defer mapped.deinit(allocator);
    try std.testing.expectEqual(ErrorKind.rate_limited, mapped.kind);
    try std.testing.expectEqual(@as(?u64, 17), mapped.retry_after_seconds);
    try std.testing.expectEqualStrings("{\"message\":\"slow\",\"future\":42}", mapped.raw);
}

test "pagination refuses cross-origin continuations" {
    const allocator = std.testing.allocator;
    const driver = Driver{ .allocator = allocator, .family = .github, .base_url = "https://api.example", .repository = "acme/code" };
    try std.testing.expectError(error.UntrustedPaginationUrl, driver.listIssuesRequest("https://evil.example/token"));
}

test "forge resource identities use public numbers and forks send objects" {
    const allocator = std.testing.allocator;
    const forgejo = Driver{ .allocator = allocator, .family = .forgejo, .base_url = "https://forge.example", .repository = "acme/code" };
    const issue_id = try responseResourceId(allocator, forgejo, .issue, "{\"id\":42,\"number\":7}");
    defer allocator.free(issue_id);
    try std.testing.expectEqualStrings("7", issue_id);
    const fork = try forgejo.forkRequest();
    defer fork.deinit(allocator);
    try std.testing.expectEqualStrings("{}", fork.body);
    const gitlab = Driver{ .allocator = allocator, .family = .gitlab, .base_url = "https://gitlab.example", .repository = "acme/code" };
    const change_id = try responseResourceId(allocator, gitlab, .change_request, "{\"id\":99,\"iid\":3}");
    defer allocator.free(change_id);
    try std.testing.expectEqualStrings("3", change_id);
    const repository = collaboration.RepositoryIdentity{ .vcs = "sdt", .repository = "acme/code" };
    const release = collaboration.ResourceDraft{ .value = .{ .release = .{
        .name = "v1",
        .body = "release",
        .revision = .{ .vcs = "sdt", .repository = repository.repository, .revision = "native-1" },
        .state = .open,
        .assets = &.{.{ .name = "artifact", .media_type = "application/octet-stream", .size = 1, .digest = "sha256:x" }},
    } } };
    try std.testing.expect(unsupportedDraftField(release) != null);
}

test "unverified dialects require runtime endpoint configuration" {
    const allocator = std.testing.allocator;
    const origin = Driver{ .allocator = allocator, .family = .origin, .base_url = "https://api.origin.example", .repository = "repo" };
    try std.testing.expectError(error.UnsupportedFeature, origin.createProposalRequest(.{ .title = "x", .body = "y", .head = "topic", .base = "main" }));
    const configured = Driver{
        .allocator = allocator,
        .family = .origin,
        .base_url = "https://api.origin.example",
        .repository = "repo",
        .endpoints = .{ .create_proposal = "/v1/repositories/repo/pull-requests" },
    };
    const request = try configured.createProposalRequest(.{ .title = "x", .body = "y", .head = "topic", .base = "main" });
    defer request.deinit(allocator);
    try std.testing.expectEqualStrings("https://api.origin.example/v1/repositories/repo/pull-requests", request.url);
    const tangled = Driver{ .allocator = allocator, .family = .tangled, .base_url = "https://tangled.example", .repository = "did:plc:abc" };
    try std.testing.expectError(error.UnsupportedFeature, tangled.createIssueRequest(.{ .title = "x", .body = "y" }));
    try std.testing.expectError(error.UnsupportedFeature, tangled.createProposalRequest(.{ .title = "x", .body = "y", .head = "topic", .base = "main" }));
    const pull = try tangled.xrpcCreateRecordRequest("sh.tangled.repo.pull", "{\"target\":{\"branch\":\"main\"},\"patchBlob\":{\"ref\":\"bafk\"}}");
    defer pull.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, pull.body, "sh.tangled.repo.pull") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull.body, "patchBlob") != null);
    const issues = try tangled.listIssuesRequest(null);
    defer issues.deinit(allocator);
    try std.testing.expectEqualStrings("https://tangled.example/xrpc/sh.tangled.repo.listIssues?subject=did%3Aplc%3Aabc&limit=50", issues.url);
}

test "collaboration contract executes through host supplied transport" {
    const Fixture = struct {
        calls: usize = 0,

        fn request(context: *anyopaque, method: Method, url: []const u8, _: []const Header, body: []const u8) !Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (method == .get) {
                try std.testing.expectEqualStrings("https://api.example/repos/acme/code", url);
                return .{ .status = 200, .body = "{\"id\":7,\"future\":true}" };
            }
            try std.testing.expectEqual(Method.post, method);
            try std.testing.expect(std.mem.endsWith(u8, url, "/repos/acme/code/issues"));
            try std.testing.expect(std.mem.indexOf(u8, body, "Native issue") != null);
            return .{ .status = 201, .headers = &.{.{ .name = "ETag", .value = "v7" }}, .body = "{\"id\":7,\"future\":{\"opaque\":true}}" };
        }
    };
    var fixture = Fixture{};
    var driver = Driver{
        .allocator = std.testing.allocator,
        .family = .github,
        .base_url = "https://api.example",
        .repository = "acme/code",
        .transport = .{ .context = &fixture, .request_fn = Fixture.request },
    };
    const contract = driver.collaborationDriver();
    const repository = collaboration.RepositoryIdentity{ .vcs = "sdt", .repository = "acme/code" };
    var discovery = try contract.discover(std.testing.allocator, repository);
    defer discovery.deinit();
    try std.testing.expectEqual(collaboration.ProtocolFamily.rest, discovery.response.discovery.protocol_family);
    try std.testing.expectEqual(collaboration.Support.native, discovery.response.discovery.capabilities.supports(.issue, .create));
    var created = try contract.create(std.testing.allocator, .{
        .repository = repository,
        .draft = .{ .value = .{ .issue = .{ .title = "Native issue", .body = "Exact", .state = .open } } },
    });
    defer created.deinit();
    try std.testing.expectEqualStrings("7", created.response.item.id.value);
    try std.testing.expectEqualStrings("v7", created.response.item.version);
    try std.testing.expectEqualStrings("{\"id\":7,\"future\":{\"opaque\":true}}", created.response.item.extensions[0].value);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "collaboration rest driver executes get list update and delete" {
    const Fixture = struct {
        fn request(_: *anyopaque, method: Method, url: []const u8, _: []const Header, _: []const u8) !Response {
            if (method == .delete) return .{ .status = 204 };
            if (std.mem.indexOfScalar(u8, url, '?') != null) return .{
                .status = 200,
                .headers = &.{.{ .name = "Link", .value = "<https://api.example/repos/acme/code/labels?per_page=50&page=2>; rel=\"next\"" }},
                .body = "[{\"id\":7,\"name\":\"bug\",\"color\":\"ff0000\",\"future\":9}]",
            };
            return .{ .status = 200, .headers = &.{.{ .name = "ETag", .value = "label-v2" }}, .body = "{\"id\":7,\"name\":\"bug\",\"color\":\"ff0000\",\"future\":9}" };
        }
    };
    var fixture = Fixture{};
    var driver = Driver{ .allocator = std.testing.allocator, .family = .github, .base_url = "https://api.example", .repository = "acme/code", .transport = .{ .context = &fixture, .request_fn = Fixture.request } };
    const contract = driver.collaborationDriver();
    const repository = collaboration.RepositoryIdentity{ .vcs = "sdt", .repository = "acme/code" };
    const id = collaboration.OpaqueId{ .provider = "github-rest", .value = "7" };
    var fetched = try contract.get(std.testing.allocator, .{ .repository = repository, .kind = .label, .id = id });
    defer fetched.deinit();
    try std.testing.expectEqualStrings("bug", fetched.response.item.value.label.name);
    try std.testing.expectEqualStrings("label-v2", fetched.response.item.version);
    var listed = try contract.list(std.testing.allocator, .{ .repository = repository, .kind = .label });
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.response.page.items.len);
    try std.testing.expect(listed.response.page.next_cursor != null);
    var updated = try contract.update(std.testing.allocator, .{
        .repository = repository,
        .id = id,
        .expected_version = "label-v1",
        .replacement = .{ .value = .{ .label = .{ .name = "bug", .color = "ff0000", .description = "Defect" } } },
    });
    defer updated.deinit();
    try std.testing.expectEqualStrings("Defect", updated.response.item.value.label.description);
    var deleted = try contract.delete(std.testing.allocator, .{ .repository = repository, .kind = .label, .id = id, .expected_version = "label-v2" });
    defer deleted.deinit();
    try std.testing.expect(deleted.response.deleted.eql(id));
}

test "rest endpoint matrix covers declared resource operations" {
    const allocator = std.testing.allocator;
    const families = [_]Family{ .github, .gitlab, .forgejo };
    const kinds = [_]collaboration.ResourceKind{ .issue, .change_request, .comment, .fork, .check, .release, .label, .milestone };
    for (families) |family| {
        const driver = Driver{ .allocator = allocator, .family = family, .base_url = "https://forge.example", .repository = "acme/code" };
        for (kinds) |kind| {
            const list = restResourcePath(driver, kind, .list, null, null, 25) catch |err| switch (err) {
                error.RequiresParentIdentity => continue,
                else => return err,
            };
            defer allocator.free(list);
            try std.testing.expect(std.mem.indexOf(u8, list, "25") != null);
            const get = restResourcePath(driver, kind, .get, "7", null, null) catch |err| switch (err) {
                error.RequiresParentIdentity => continue,
                else => return err,
            };
            defer allocator.free(get);
            try std.testing.expect(std.mem.endsWith(u8, get, "/7"));
        }
    }
}
