//! `publr deploy` (also `publr cloud deploy`): the site in this folder made a Publr Cloud
//! project. Its Publr exports it, the command archives it and sends it to the account's
//! dashboard, which makes it a project at the address asked for (or one made from the
//! folder's name); then the folder carries the link to it (`cloud.json`) and this computer is
//! signed in there, so it pulls and pushes. A linked folder is refused: its changes go up as
//! a branch, never over the live site. While it goes, the clone's progress page shows it, on
//! a server of its own beside the site's (`clone/arriving.zig`).

const std = @import("std");
const core = @import("../core.zig");
const Arriving = @import("clone/arriving.zig").Arriving;

const Config = core.Config;
const archive = core.archive;
const cloud_login = core.cloud_login;
const links = core.links;
const site_data = core.site_data;
const transfer = core.transfer;
const versions = core.versions;

/// Where the dashboard takes a packed site.
const upload_path = "/api/cloud/bundles";
const upload_piece_bytes: u32 = 256 << 10;
const ending_len: u32 = 6;
const slug_len_max: u32 = 63;
const spaces_max: u32 = 64;
/// The scratch site's own administrator, who watches the page; nobody signs in as it
/// elsewhere.
const page_email = "deploy@publr.localhost";
/// How long the page's server stays after the end while a page is shown, for it to show
/// the end (it asks every few hundred milliseconds).
const shown_linger_ms: u32 = 15_000;
/// How long Cloud may take to answer at the new address.
const live_wait_ms: u32 = 90_000;

pub const usage =
    \\usage: publr deploy [--space <space>] [--slug <address>] [--name <name>] [--cloud <dashboard>]
    \\                    [--progress json] [--no-open]
    \\
;

/// What Cloud said when it refused, for the page.
var refused_because: []const u8 = "";
/// How long the page's server stays after the end: only while a page is shown, opened in
/// the browser or by the program driving the command (`--progress json`).
var linger_ms: u32 = 0;

const Options = struct {
    space: []const u8 = "",
    slug: []const u8 = "",
    name: []const u8 = "",
    dashboard: []const u8 = "",
    /// One JSON line per step on stdout instead of the words, for a program driving it
    /// (Publr Studio): `{"stage":"packing"}`, `{"stage":"uploading","done":…,"total":…}`,
    /// `{"stage":"starting"}`, `{"stage":"done","address":…,"admin":…,…}`, or
    /// `{"stage":"failed","error":…,"message":…}`. `{"stage":"page","url":…}` names the
    /// progress page as soon as it is up.
    json: bool = false,
    /// The progress page opened in the browser (not with `--no-open`).
    open: bool = true,
};

const Deployed = struct {
    id: []const u8,
    slug: []const u8,
    project_id: []const u8,
    address: []const u8,
    admin: []const u8,
    state: []const u8 = "",
};

fn parse(args: []const []const u8) ?Options {
    var options: Options = .{};
    var index: u32 = 0;

    while (index < args.len) {
        const flag = args[index];

        if (std.mem.eql(u8, flag, "--no-open")) {
            options.open = false;
            index += 1;
            continue;
        }

        if (index + 1 == args.len) {
            return null;
        }

        const value = args[index + 1];

        index += 2;

        if (std.mem.eql(u8, flag, "--space")) {
            options.space = value;
        } else if (std.mem.eql(u8, flag, "--slug")) {
            options.slug = value;
        } else if (std.mem.eql(u8, flag, "--name")) {
            options.name = value;
        } else if (std.mem.eql(u8, flag, "--cloud")) {
            options.dashboard = std.mem.trimEnd(u8, value, "/");
        } else if (std.mem.eql(u8, flag, "--progress") and std.mem.eql(u8, value, "json")) {
            options.json = true;
        } else {
            return null;
        }
    }

    return if (index == args.len) options else null;
}

pub fn run(
    init: std.process.Init,
    config: *const Config,
    events: *std.Io.Writer,
    rest: []const []const u8,
) !u8 {
    var options = parse(rest) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // With `--progress json` the words go nowhere and the events to stdout.
    var quiet_buffer: [256]u8 = undefined;
    var quiet: std.Io.Writer.Discarding = .init(&quiet_buffer);
    const out = if (options.json) &quiet.writer else events;

    if (options.dashboard.len == 0) {
        const given = init.environ_map.get(cloud_login.dashboard_variable) orelse
            cloud_login.dashboard_default;

        options.dashboard = std.mem.trimEnd(u8, given, "/");
    }

    const token = try cloud_login.token_for(init, options.dashboard, cloud_login.token_variable) orelse {
        std.debug.print("publr deploy: not signed in to {s}; run `publr cloud login`\n", .{
            options.dashboard,
        });
        return 1;
    };
    const here = try std.process.currentPathAlloc(config.io, config.arena);
    const folder = try core.sites.around(config.io, config.arena, here) orelse {
        std.debug.print("publr deploy: no site here; run it in a site's folder\n", .{});
        return 1;
    };

    if (try links.read_cloud(config, folder)) |link| {
        std.debug.print("publr deploy: this folder is {s}'s; its changes go up as a branch " ++
            "(publr push), never over the live site\n", .{link.address});
        return 1;
    }

    const publr = try versions.binary_for(config, try core.sites.load(config, folder, folder));

    try open_once(config, publr, folder);

    if (options.name.len == 0) {
        options.name = std.fs.path.basename(folder);
    }

    const client: Client = .{
        .config = config,
        .dashboard = options.dashboard,
        .token = token,
        .events = if (options.json) events else null,
    };

    if (options.space.len == 0) {
        options.space = try default_space(client) orelse return 1;
    }

    if (options.slug.len == 0) {
        options.slug = try slug_with(config.arena, options.name, &random_ending(config.io));
    }

    return deploy(init, client, out, publr, folder, options);
}

/// A site made and never run has no database yet: its Publr makes it, as `serve` would, so
/// the site goes up like any other.
fn open_once(config: *const Config, publr: []const u8, folder: []const u8) !void {
    const database = try std.fs.path.join(config.arena, &.{ folder, site_data.database });

    if (std.Io.Dir.cwd().access(config.io, database, .{})) |_| {
        return;
    } else |_| {}

    _ = try core.project.run(config, publr, folder, &.{ "heartbeat", "check" });
}

fn deploy(
    init: std.process.Init,
    client: Client,
    out: *std.Io.Writer,
    publr: []const u8,
    folder: []const u8,
    options: Options,
) !u8 {
    if (!try address_free(client, out, options.slug)) {
        return 1;
    }

    var arriving: Arriving = undefined;
    const page = open_page(init, client, out, publr, &arriving, options);
    const code = go(init, client, out, publr, folder, page, options) catch |err| {
        stopped(page, @errorName(err));
        return err;
    };

    if (code != 0) {
        stopped(page, if (refused_because.len > 0) refused_because else "Publr Cloud did not make it.");
    }

    return code;
}

/// The progress page up beside the site, named and opened; null, having said why, when it
/// could not be (the deploy goes on without it).
fn open_page(
    init: std.process.Init,
    client: Client,
    out: *std.Io.Writer,
    publr: []const u8,
    arriving: *Arriving,
    options: Options,
) ?*Arriving {
    const config = client.config;
    const release = release_of(config, publr) catch |err| {
        std.log.warn("deploy progress: which Publr: {t}", .{err});
        return null;
    };
    const sites = core.Sites.find(config) catch |err| {
        std.log.warn("deploy progress: {t}", .{err});
        return null;
    };
    const port = sites.free_port(&core.server.listening) catch |err| {
        std.log.warn("deploy progress: {t}", .{err});
        return null;
    };
    const where = std.fmt.allocPrint(config.arena, "Publr Cloud · {s}", .{options.slug}) catch return null;

    arriving.open(config, publr, release, page_email, port, "deploying", .{
        .direction = "up",
        .name = options.name,
        .folder = where,
    }) catch |err| {
        std.log.warn("deploy progress: the page did not start: {t}", .{err});
        return null;
    };

    const link = arriving.link() catch return null;

    out.print("Deploying {s} to Cloud. Follow it at {s}\n", .{ options.name, link }) catch {};
    out.flush() catch {};
    client.event(.{
        .stage = "page",
        .url = link,
    }) catch {};

    if (options.open and !options.json and init.environ_map.get("PUBLR_NO_BROWSER") == null) {
        core.login.open_browser(init, link);
        linger_ms = shown_linger_ms;
    }

    if (options.json) {
        linger_ms = shown_linger_ms;
    }

    return arriving;
}

/// The release `publr` is (`publr --version`): where the page's plugin is kept built.
fn release_of(config: *const Config, publr: []const u8) ![]const u8 {
    const result = try std.process.run(config.arena, config.io, .{
        .argv = &.{ publr, "--version" },
    });
    const said = std.mem.trim(u8, result.stdout, " \r\n");
    const prefix = "publr ";

    if (!versions.succeeded(result.term) or !std.mem.startsWith(u8, said, prefix)) {
        return error.NoVersion;
    }

    return said[prefix.len..];
}

/// The page says why it stopped, keeps its server while the person reads it, then goes.
fn stopped(page: ?*Arriving, why: []const u8) void {
    const arriving = page orelse return;

    arriving.progress.phase = "failed";
    arriving.progress.problem = why;
    arriving.finish(linger_ms);
}

/// The page told the phase now.
fn phase(page: ?*Arriving, now: []const u8) void {
    const arriving = page orelse return;

    arriving.progress.phase = now;
    _ = arriving.feed(true) catch "";
}

/// The upload's bytes, told to the page as they go.
fn told_uploaded(context: *anyopaque, done: u64, size: u64) void {
    const arriving: *Arriving = @ptrCast(@alignCast(context));

    arriving.progress.phase = "uploading";
    arriving.progress.done_bytes = done;
    arriving.progress.total_bytes = size;
    _ = arriving.feed(done == size) catch "";
}

fn go(
    init: std.process.Init,
    client: Client,
    out: *std.Io.Writer,
    publr: []const u8,
    folder: []const u8,
    page: ?*Arriving,
    options: Options,
) !u8 {
    const config = client.config;
    const arena = config.arena;
    const exported = try site_data.scratch_beside(config, folder, "deploy");
    const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ exported, archive.extension });
    defer {
        std.Io.Dir.cwd().deleteTree(config.io, exported) catch |err| {
            std.log.warn("removing {s}: {t}", .{ exported, err });
        };
        std.Io.Dir.cwd().deleteFile(config.io, file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("removing {s}: {t}", .{ file, err }),
        };
    }

    try client.event(.{
        .stage = "packing",
    });
    phase(page, "packing");
    try progress(out, "Packing the site", .{});
    try site_data.export_to(config, publr, folder, exported, .{});

    const made = try archive.write(config.io, arena, exported, file, .{});

    try out.print("{d} files\n", .{made.files});
    phase(page, "uploading");

    const watch: transfer.Watch = if (page) |arriving| .{
        .context = arriving,
        .uploading = &told_uploaded,
    } else .{};
    const upload = try client.upload(out, file, watch) orelse return 1;

    try client.event(.{
        .stage = "starting",
    });
    phase(page, "going_live");
    try progress(out, "Starting it on Cloud", .{});

    const sent = try std.json.Stringify.valueAlloc(arena, .{
        .space = options.space,
        .name = options.name,
        .slug = options.slug,
        .upload = upload,
    }, .{});
    const answer = try client.call("cloud.deploy_site", sent);
    const deployed = try client.answered(Deployed, answer) orelse return 1;

    try links.write_cloud(config, folder, .{
        .dashboard = options.dashboard,
        .space = options.space,
        .project = deployed.id,
        .project_id = deployed.project_id,
        .slug = deployed.slug,
        .address = deployed.address,
        .admin = deployed.admin,
        .deployed_at_ms = core.server.now_ms(config.io),
    });
    try sign_in_folder(init, client, out, deployed);
    // Done once the project answers at its address, as the person will open it.
    answers_at(config, deployed.address);
    try client.event(.{
        .stage = "done",
        .address = deployed.address,
        .admin = deployed.admin,
        .project = deployed.id,
        .project_id = deployed.project_id,
        .slug = deployed.slug,
    });
    try out.print("done\n{s} is live at {s}\nAdmin: {s}\n" ++
        "This folder is linked to it ({s}).\n", .{
        options.name,
        deployed.address,
        deployed.admin,
        links.cloud_name,
    });

    if (page) |arriving| {
        arriving.progress.address = deployed.address;
        arriving.progress.admin = admin_link(client, deployed) catch deployed.admin;
        arriving.progress.phase = "done";
        arriving.finish(linger_ms);
    }

    return 0;
}

/// Until `address` answers its health check, at most `live_wait_ms`; Cloud starts a new
/// project's machine on its first request.
fn answers_at(config: *const Config, address: []const u8) void {
    const url = std.fmt.allocPrint(config.arena, "{s}/api/health", .{address}) catch return;
    var waited: u32 = 0;

    while (waited < live_wait_ms) : (waited += 1000) {
        var body: std.Io.Writer.Allocating = .init(config.arena);

        if (versions.get(config.io, url, &body.writer)) |_| {
            return;
        } else |_| {}

        std.Io.sleep(config.io, .fromSeconds(1), .awake) catch return;
    }
}

/// The project's admin signed in once, through the dashboard's sign-on: good for a minute.
fn admin_link(client: Client, deployed: Deployed) ![]const u8 {
    const config = client.config;
    const sent = try std.json.Stringify.valueAlloc(config.arena, .{
        .project = deployed.slug,
    }, .{});
    const quiet: Client = .{
        .config = config,
        .dashboard = client.dashboard,
        .token = client.token,
    };
    const answer = try quiet.call("cloud.sign_on_token", sent);
    const Signed = struct {
        token: []const u8,
    };
    const signed = try quiet.answered(Signed, answer) orelse return error.NotSigned;
    const at = std.mem.indexOf(u8, deployed.admin, "/admin") orelse deployed.admin.len;

    return std.fmt.allocPrint(config.arena, "{s}/auth/sign-on?token={s}&return=%2Fadmin", .{
        deployed.admin[0..at],
        signed.token,
    });
}


/// This computer signed in to the project as the account that deployed it, through the
/// dashboard's sign-on, so the folder pulls and pushes with nothing to approve. A refusal
/// only means signing in later with `publr login`.
fn sign_in_folder(init: std.process.Init, client: Client, out: *std.Io.Writer, deployed: Deployed) !void {
    const sent = try std.json.Stringify.valueAlloc(client.config.arena, .{
        .project = deployed.slug,
    }, .{});
    const answer = try client.call("cloud.sign_on_token", sent);
    const Signed = struct {
        token: []const u8,
    };
    // The project is made either way: a refusal here is no failure of the deploy.
    const quiet: Client = .{
        .config = client.config,
        .dashboard = client.dashboard,
        .token = client.token,
    };
    const signed = try quiet.answered(Signed, answer) orelse return;
    const words = [_][]const u8{ "login", deployed.address, "--sign-on", signed.token };

    const signed_in = core.login.run(init, out, &words) catch 1;

    if (signed_in != 0) {
        std.debug.print("publr deploy: sign in later to pull and push: publr login {s}\n", .{
            deployed.address,
        });
    }
}

fn address_free(client: Client, out: *std.Io.Writer, slug: []const u8) !bool {
    const Checked = struct {
        available: bool,
        reason: ?[]const u8 = null,
    };
    const sent = try std.json.Stringify.valueAlloc(client.config.arena, .{
        .slug = slug,
    }, .{});

    try progress(out, "Checking the address {s}", .{slug});

    const answer = try client.call("cloud.check_address", sent);
    const checked = try client.answered(Checked, answer) orelse return false;

    try out.print("{s}\n", .{if (checked.available) "available" else checked.reason orelse "not available"});

    return checked.available;
}

/// The space to deploy into; null, having said why, when the account has none or several.
fn default_space(client: Client) !?[]const u8 {
    const answer = try client.call("cloud.spaces", "{}");

    if (answer.status == .unauthorized) {
        std.debug.print("publr deploy: {s} no longer takes this sign-in; run " ++
            "`publr cloud login` again\n", .{client.dashboard});
        return null;
    }

    const Listing = struct {
        spaces: []const struct {
            slug: []const u8,
            name: []const u8 = "",
        } = &.{},
    };
    const listing = try client.answered(Listing, answer) orelse return null;

    if (listing.spaces.len == 1) {
        return listing.spaces[0].slug;
    }

    if (listing.spaces.len == 0) {
        std.debug.print("publr deploy: your account has no space yet; make one at {s}\n", .{
            client.dashboard,
        });
        return null;
    }

    std.debug.print("publr deploy: your account has several spaces; say which with --space:\n", .{});

    for (listing.spaces[0..@min(listing.spaces.len, spaces_max)]) |found| {
        std.debug.print("  {s}  ({s})\n", .{ found.slug, found.name });
    }

    return null;
}

fn random_ending(io: std.Io) [ending_len]u8 {
    var bytes: [ending_len]u8 = undefined;

    io.random(&bytes);

    return bytes;
}

/// `<the folder's name>-<six random letters and digits>`, as Cloud makes a new project's:
/// the name lowercased, anything not a-z or 0-9 a single hyphen, cut to leave room for the
/// ending; `site` when nothing is left.
fn slug_with(arena: std.mem.Allocator, folder_name: []const u8, random: []const u8) ![]const u8 {
    std.debug.assert(random.len == ending_len);

    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    const room = slug_len_max - ending_len - 1;
    var made: std.ArrayList(u8) = .empty;

    for (folder_name) |char| {
        if (made.items.len == room) {
            break;
        }

        if (std.ascii.isAlphanumeric(char)) {
            try made.append(arena, std.ascii.toLower(char));
        } else if (made.items.len > 0 and made.items[made.items.len - 1] != '-') {
            try made.append(arena, '-');
        }
    }

    const base = std.mem.trimEnd(u8, made.items, "-");
    var ending: [ending_len]u8 = undefined;

    for (random, &ending) |byte, *char| {
        char.* = alphabet[byte % alphabet.len];
    }

    return std.fmt.allocPrint(arena, "{s}-{s}", .{ if (base.len > 0) base else "site", &ending });
}

fn progress(out: *std.Io.Writer, comptime step: []const u8, values: anytype) !void {
    try out.print(step ++ "... ", values);
    try out.flush();
}

/// The account's dashboard, called with its token.
const Client = struct {
    config: *const Config,
    dashboard: []const u8,
    token: []const u8,
    /// Where `--progress json` events go; null without it.
    events: ?*std.Io.Writer = null,

    /// One JSON event line, with `--progress json`.
    fn event(client: Client, value: anytype) !void {
        const writer = client.events orelse return;

        try std.json.Stringify.value(value, .{}, writer);
        try writer.writeAll("\n");
        try writer.flush();
    }

    /// `POST /api/<plugin>.<verb>` with a JSON body.
    fn call(client: Client, operation: []const u8, payload: []const u8) !transfer.Reply {
        const arena = client.config.arena;
        const reply = try core.remote.post(client.config.io, arena, .{
            .url = try std.fmt.allocPrint(arena, "{s}/api/{s}", .{ client.dashboard, operation }),
            .payload = payload,
            .token = client.token,
        });

        return .{
            .status = reply.status,
            .body = reply.body,
        };
    }

    /// The answer as `Answer`; null, having said why, for a refusal.
    fn answered(client: Client, comptime Answer: type, reply: transfer.Reply) !?Answer {
        const arena = client.config.arena;

        if (reply.status == .ok or reply.status == .created) {
            return try std.json.parseFromSliceLeaky(Answer, arena, reply.body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }

        const Refusal = struct {
            @"error": []const u8 = "",
            message: []const u8 = "",
        };
        const refusal = std.json.parseFromSliceLeaky(Refusal, arena, reply.body, .{
            .ignore_unknown_fields = true,
        }) catch Refusal{};
        const why = if (refusal.message.len > 0) refusal.message else refusal.@"error";

        refused_because = why;
        std.debug.print("\npublr deploy: {s} answered {d}: {s}\n", .{
            client.dashboard,
            @intFromEnum(reply.status),
            why,
        });
        try client.event(.{
            .stage = "failed",
            .@"error" = refusal.@"error",
            .message = why,
        });

        return null;
    }

    /// Where the dashboard takes uploads: its sync address (`cloud.sync`), straight to its
    /// server past the CDN in front of it; the dashboard itself when it names none.
    fn sync_address(client: Client) []const u8 {
        const reply = client.call("cloud.sync", "{}") catch return client.dashboard;

        if (reply.status != .ok) {
            return client.dashboard;
        }

        const Synced = struct {
            sync: []const u8 = "",
        };
        const synced = std.json.parseFromSliceLeaky(Synced, client.config.arena, reply.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return client.dashboard;

        if (synced.sync.len == 0 or std.mem.indexOf(u8, synced.sync, "://") == null) {
            return client.dashboard;
        }

        return std.mem.trimEnd(u8, synced.sync, "/");
    }

    /// The archive sent to the dashboard as it is read, to its sync address; the upload's
    /// name there.
    fn upload(client: Client, out: *std.Io.Writer, path: []const u8, watch: transfer.Watch) !?[]const u8 {
        const arena = client.config.arena;
        const reply = try transfer.send_in_parts(client.config.io, arena, .{
            .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ client.sync_address(), upload_path }),
            .token = client.token,
            .path = path,
            .piece_bytes = upload_piece_bytes,
            .out = client.events orelse out,
            .json = client.events != null,
            .watch = watch,
        });
        const Uploaded = struct {
            upload: []const u8,
            bytes: u64 = 0,
        };
        const uploaded = try client.answered(Uploaded, reply) orelse return null;

        return uploaded.upload;
    }
};

test "an address from the folder's name, never taken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const random = [_]u8{ 0, 1, 2, 26, 27, 35 };

    try std.testing.expectEqualStrings("my-shop-abc019", try slug_with(arena, "My Shop!", &random));
    try std.testing.expectEqualStrings("site-abc019", try slug_with(arena, "...", &random));
    try std.testing.expectEqual(@as(usize, 63), (try slug_with(arena, "x" ** 100, &random)).len);
}
