//! `publr deploy` (also `publr cloud deploy`): the site in this folder made a Publr Cloud
//! project. Its Publr exports it, the command archives it and sends it to the account's
//! dashboard, which makes it a project at the address asked for (or one made from the
//! folder's name); then the folder carries the link to it (`cloud.json`) and this computer is
//! signed in there, so it pulls and pushes. A linked folder is refused: its changes go up as
//! a branch, never over the live site.

const std = @import("std");
const core = @import("../core.zig");

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

pub const usage =
    \\usage: publr deploy [--space <space>] [--slug <address>] [--name <name>] [--cloud <dashboard>]
    \\                    [--progress json]
    \\
;

const Options = struct {
    space: []const u8 = "",
    slug: []const u8 = "",
    name: []const u8 = "",
    dashboard: []const u8 = "",
    /// One JSON line per step on stdout instead of the words, for a program driving it
    /// (Publr Studio): `{"stage":"packing"}`, `{"stage":"uploading","done":…,"total":…}`,
    /// `{"stage":"starting"}`, `{"stage":"done","address":…,"admin":…,…}`, or
    /// `{"stage":"failed","error":…,"message":…}`.
    json: bool = false,
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

    while (index + 1 < args.len) : (index += 2) {
        const flag = args[index];
        const value = args[index + 1];

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
    const config = client.config;
    const arena = config.arena;

    if (!try address_free(client, out, options.slug)) {
        return 1;
    }

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
    try progress(out, "Packing the site", .{});
    try site_data.export_to(config, publr, folder, exported, .{});

    const made = try archive.write(config.io, arena, exported, file, .{});

    try out.print("{d} files\n", .{made.files});

    const upload = try client.upload(out, file) orelse return 1;

    try client.event(.{
        .stage = "starting",
    });
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
    try sign_in_folder(init, client, out, deployed);

    return 0;
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

    if (try core.login.run(init, out, &words) != 0) {
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

    /// The archive sent to the dashboard as it is read; the upload's name there.
    fn upload(client: Client, out: *std.Io.Writer, path: []const u8) !?[]const u8 {
        const arena = client.config.arena;
        const reply = try transfer.send_in_parts(client.config.io, arena, .{
            .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ client.dashboard, upload_path }),
            .token = client.token,
            .path = path,
            .piece_bytes = upload_piece_bytes,
            .out = client.events orelse out,
            .json = client.events != null,
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
