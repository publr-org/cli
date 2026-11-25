//! `publr pull`: the site brought down again into the folder linked to it, only what changed:
//! the database when the site moved past what the folder took, and of the media only the
//! files the folder does not hold the same. It never touches the folder's own work: a folder
//! with changes not pushed, or pushed and still waiting for review, is left as it is.
//! `--check` only says where the folder is, as JSON, for Publr Desktop; it also moves the
//! folder's release pin when the site runs another release.

const std = @import("std");
const api = @import("publr_api");
const core = @import("../core.zig");

const Config = core.Config;
const archive = core.archive;
const credentials = core.credentials;
const links = core.links;
const site_data = core.site_data;
const transfer = core.transfer;
const versions = core.versions;

const download_name = ".publr/pull" ++ archive.extension;
const incoming_dir = ".publr/incoming";
const previous_dir = ".publr/previous";
const media_dir = "data/media";
const installed_dir = "data/plugins";
const list_path = "/api/environments.list";
const activity_path = "/api/activity.list";
const walk_entries_max: u32 = 1 << 24;

/// Exit codes Desktop tells apart: signed out of the site, work of the folder's own in the
/// way, a server running in the folder.
pub const signed_out: u8 = 3;
pub const own_work: u8 = 4;
pub const serving: u8 = 5;

/// Where the folder is, as `--check` says it.
pub const Where = struct {
    /// The folder holds work of its own.
    changes: bool,
    /// Some of it was not pushed.
    unsent: bool,
    /// It was all pushed, and its branch is still there for review.
    waiting: bool,
    /// The site has changed since the folder last came down.
    behind: bool,
    /// It was all pushed and its branch is gone unmerged: the review discarded it, so the
    /// folder comes down again as the site is (a pull wipes the work).
    discarded: bool = false,
    /// The folder holds the site's media files (false: they load from the site).
    media: bool = true,
    /// What the site's media files weigh, for `pull --media` to say first.
    media_bytes: u64 = 0,
    /// The branch it pushes to, and the site.
    branch: []const u8,
    site: []const u8,
    /// While waiting: the page where a person reviews and merges the branch.
    review: []const u8 = "",
};

/// A linked folder, its Publr and the site it is linked to.
pub const Linked = struct {
    folder: []const u8,
    publr: []const u8,
    link: links.Clone,
    site: credentials.Site,
    /// The same site where it is synced (`transfer.sync_of`): packs, pieces and pushes go
    /// there; every address shown to a person stays the site's own.
    sync: credentials.Site,
};

/// The site around this folder and what it is linked to; null, having said why (with the
/// exit code in `code`), when it is not linked or not signed in there.
pub fn linked_here(init: std.process.Init, config: *const Config, code: *u8) !?Linked {
    const here = try std.process.currentPathAlloc(config.io, config.arena);
    const folder = try core.sites.around(config.io, config.arena, here) orelse {
        std.debug.print("publr: this folder is not linked to a site; " ++
            "`publr clone <address>` makes one that is\n", .{});
        code.* = 1;
        return null;
    };
    const publr = try publr_of(init, config, folder);
    const link = try links.read_clone(config, folder, publr) orelse {
        std.debug.print("publr: this folder is not linked to a site; " ++
            "`publr clone <address>` makes one that is\n", .{});
        code.* = 1;
        return null;
    };
    const site = try credentials.find(init, link.site) orelse {
        std.debug.print("publr: not signed in to {s}; run \"publr login {s}\"\n", .{
            link.site,
            link.site,
        });
        code.* = signed_out;
        return null;
    };

    return .{
        .folder = folder,
        .publr = publr,
        .link = link,
        .site = site,
        .sync = transfer.sync_of(config.io, config.arena, site),
    };
}

/// The Publr a linked folder runs: the one chosen or its pin, else (a folder cloned before
/// pins) the release its site runs, pinned now.
fn publr_of(init: std.process.Init, config: *const Config, folder: []const u8) ![]const u8 {
    const site = try core.sites.load(config, folder, folder);

    if (try versions.pin_of(config, folder) != null) {
        return versions.binary_for(config, site);
    }

    const address = blk: {
        const path = try std.fs.path.join(config.arena, &.{ folder, links.clone_path });

        if (std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, .limited(64 << 10))) |text| {
            const Named = struct {
                site: []const u8,
            };
            const named = try std.json.parseFromSliceLeaky(Named, config.arena, text, .{
                .ignore_unknown_fields = true,
            });

            break :blk named.site;
        } else |_| {}

        const deployed = try links.read_cloud(config, folder) orelse return versions.binary_for(config, site);

        break :blk deployed.address;
    };
    const signed = try credentials.find(init, address) orelse return versions.binary_for(config, site);
    const release = try transfer.release_of(config.io, config.arena, signed) orelse return error.NoRelease;

    try site_data.pin(config, folder, release);

    return versions.binary_for(config, site);
}

pub fn run(
    init: std.process.Init,
    config: *const Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
) !u8 {
    const checking = rest.len == 1 and std.mem.eql(u8, rest[0], "--check");
    // `--media`: a copy that loads its media from the site brings every file down, keeps them
    // from then on, and serves them itself.
    const all_media = rest.len == 1 and std.mem.eql(u8, rest[0], "--media");

    if (rest.len > 0 and !checking and !all_media) {
        std.debug.print("usage: publr pull [--check | --media]\n", .{});
        return 2;
    }

    var code: u8 = 0;
    var linked = try linked_here(init, config, &code) orelse return code;

    if (all_media and !linked.link.media) {
        return media_down(config, &linked, out);
    }

    try ensure_base(config, &linked);
    try follow_release(config, &linked);

    const where = try where_of(config, linked) orelse return 1;

    if (checking) {
        try out.print("{f}\n", .{std.json.fmt(where, .{})});
        return 0;
    }

    if (where.unsent) {
        std.debug.print("publr pull: this folder has changes not on the site yet; push them first\n", .{});
        return own_work;
    }

    if (where.waiting) {
        std.debug.print("publr pull: this folder's changes wait for review as {s}\n", .{linked.link.branch});
        return own_work;
    }

    if (!where.behind and !where.changes) {
        try out.print("Up to date with {s}\n", .{linked.link.site});
        return 0;
    }

    if (serving_here(config, linked.folder)) {
        return serving;
    }

    const brought = try bring_down(config, linked, out) orelse return 1;

    linked.link.pulled = brought.latest_change;
    linked.link.pushed = "";
    linked.link.since = 0;
    try links.write_clone(config, linked.folder, linked.link);
    try out.print("Pulled {s}: {d} KiB came down\n", .{ linked.link.site, brought.bytes / 1024 });

    return 0;
}

/// A deployed folder has no base until it first pulls or pushes: the folder as it is now
/// is one, the state it last matched the site in. Never the site's own state: what the site
/// has and the folder never had (Cloud's own types, plugins added there) would read as the
/// folder's removals, and a merge would remove them from the site. With nothing pulled yet,
/// the site's state comes down next, as any pull: the folder holds nothing of its own.
pub fn ensure_base(config: *const Config, linked: *Linked) !void {
    const base = try std.fs.path.join(config.arena, &.{ linked.folder, site_data.base_dir });
    const base_database = try std.fs.path.join(config.arena, &.{ base, site_data.database });

    if (std.Io.Dir.cwd().access(config.io, base_database, .{})) |_| {
        return;
    } else |_| {}

    const exported = try site_data.scratch_beside(config, linked.folder, "base");
    defer std.Io.Dir.cwd().deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    try site_data.export_to(config, linked.publr, linked.folder, exported, .{
        .clone = true,
        .media = false,
    });
    try std.Io.Dir.cwd().deleteTree(config.io, base);
    try site_data.import_from(config, linked.publr, base, exported, .{
        .media = false,
    });
    try site_data.keep_only_database(config.io, config.arena, base);

    linked.link.since = (try site_data.state(config, linked.publr, linked.folder, null)).latest_write;
    linked.link.pulled = 0;
    linked.link.pushed = "";
    try links.write_clone(config, linked.folder, linked.link);
}

/// The folder pinned to the release the site runs now, when Cloud moved it: an exact match
/// is what a clone needs, so the folder follows its site.
pub fn follow_release(config: *const Config, linked: *Linked) !void {
    const release = try transfer.release_of(config.io, config.arena, linked.site) orelse return;
    const pinned = try versions.pin_of(config, linked.folder);
    if (pinned != null and std.mem.eql(u8, pinned.?, release)) {
        return;
    }

    try site_data.pin(config, linked.folder, release);
    linked.publr = try versions.binary_for(config, try core.sites.load(config, linked.folder, linked.folder));
}

fn serving_here(config: *const Config, folder: []const u8) bool {
    const site = core.sites.load(config, folder, folder) catch return false;

    if (core.server.running(config.io, site)) {
        std.debug.print("publr pull: {s} is running on port {d}; `publr stop` it first\n", .{
            site.name,
            site.local.port,
        });
        return true;
    }

    return false;
}

/// Where the folder is against the site; null, having said why, when the site cannot say.
fn where_of(config: *const Config, linked: Linked) !?Where {
    const size = try transfer.size_of(config.io, config.arena, linked.sync) orelse return null;
    const own = try core.changes.mark(config, linked.publr, linked.folder, linked.link.since);
    const unsent = own.len > 0 and !std.mem.eql(u8, own, linked.link.pushed);
    const pushed = own.len > 0 and !unsent;
    const review = if (pushed) try review_of(config, linked.site, linked.link.branch) else null;
    const waiting = review != null and !try merged(config, linked.site, linked.link.branch, linked.link.pulled);

    return .{
        .changes = own.len > 0,
        .unsent = unsent,
        .waiting = waiting,
        .behind = size.latest_change != linked.link.pulled,
        .discarded = pushed and review == null,
        .media = linked.link.media,
        .media_bytes = size.media_bytes,
        .branch = linked.link.branch,
        .site = linked.link.site,
        .review = if (waiting) review.? else "",
    };
}

/// Where the site's branch is reviewed, when the site has it (empty when it names no page);
/// null once deleted, or on a site that keeps no copies.
fn review_of(config: *const Config, site: credentials.Site, branch: []const u8) !?[]const u8 {
    const arena = config.arena;
    const reply = try core.remote.post(config.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, list_path }),
        .payload = "{}",
        .token = site.token,
    });

    if (reply.status == .not_found) {
        return null;
    }

    if (reply.status != .ok) {
        return error.ListRefused;
    }

    const Entry = struct {
        name: []const u8,
        merge: []const u8 = "",
    };
    const Listed = struct {
        environments: []const Entry,
    };
    const listed = try api.result(Listed, arena, reply.body);

    for (listed.environments) |entry| {
        if (std.mem.eql(u8, entry.name, branch)) {
            return entry.merge;
        }
    }

    return null;
}

/// Whether the site merged `branch` since its change `after`: its activity log says so
/// (`merge.accept`), as a merged branch is kept for its history.
fn merged(config: *const Config, site: credentials.Site, branch: []const u8, after: i64) !bool {
    const arena = config.arena;
    const reply = try core.remote.post(config.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, activity_path }),
        .payload = "{\"operation\":\"merge.accept\",\"limit\":50}",
        .token = site.token,
    });

    if (reply.status != .ok) {
        return error.ActivityRefused;
    }

    const Accepted = struct {
        branch: []const u8 = "",
    };
    const Entry = struct {
        id: i64,
        input: ?Accepted = null,
    };
    const Listed = struct {
        entries: []const Entry,
    };
    const listed = try api.result(Listed, arena, reply.body);

    for (listed.entries) |entry| {
        if (entry.id <= after) {
            continue;
        }

        const accepted = entry.input orelse continue;

        if (std.mem.eql(u8, accepted.branch, branch)) {
            return true;
        }
    }

    return false;
}

const Brought = struct {
    latest_change: i64,
    bytes: u64,
};

/// Every media file of the site brought into a copy that loaded them from it: the folder holds
/// them from now on (pulls bring new ones) and its own Publr serves them (`media_origin` set
/// back to the site itself). Its own work stays: only media comes down.
fn media_down(config: *const Config, linked: *Linked, out: *std.Io.Writer) !u8 {
    linked.link.media = true;

    const brought = try bring_media(config, linked.*, out) orelse return 1;

    try links.write_clone(config, linked.folder, linked.link);
    _ = core.project.run(config, linked.publr, linked.folder, &.{ "--as-admin", site_data.media_origin, "set", "--origin", "" }) catch {};
    try out.print("Media of {s} came down: {d} KiB\n", .{ linked.link.site, brought / 1024 });

    return 0;
}

/// The site packed with its media and only the media files taken into the folder; the bytes
/// that came down. Null, having said why, when the site did not pack.
fn bring_media(config: *const Config, linked: Linked, out: *std.Io.Writer) !?u64 {
    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    const asked = try std.json.Stringify.valueAlloc(arena, .{
        .have = try held(config, linked),
    }, .{});
    const made = try transfer.prepared(config.io, arena, linked.sync, asked, out, .{}) orelse return null;
    const download = try std.fs.path.join(arena, &.{ linked.folder, download_name });

    defer cwd.deleteFile(config.io, download) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download, err });
    };

    try transfer.fetch(config.io, linked.sync, made.bytes, download, out, .{});

    const exported = try site_data.scratch_beside(config, linked.folder, "media");
    defer cwd.deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    _ = try archive.read(config.io, arena, download, exported);
    try add_media(config.io, arena, exported, linked.folder);

    return made.bytes;
}

/// The site packed without what the folder holds the same and put in place, in the folder
/// and as its base; null, having said why, when it was not.
fn bring_down(config: *const Config, linked: Linked, out: *std.Io.Writer) !?Brought {
    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    // A copy that loads its media from the site brings none.
    const asked = if (linked.link.media) try std.json.Stringify.valueAlloc(arena, .{
        .have = try held(config, linked),
    }, .{}) else "{\"media\":\"none\"}";
    const made = try transfer.prepared(config.io, arena, linked.sync, asked, out, .{}) orelse return null;
    const download = try std.fs.path.join(arena, &.{ linked.folder, download_name });

    defer cwd.deleteFile(config.io, download) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download, err });
    };

    try transfer.fetch(config.io, linked.sync, made.bytes, download, out, .{});

    const exported = try site_data.scratch_beside(config, linked.folder, "pulled");
    defer cwd.deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    const manifest = try archive.read(config.io, arena, download, exported);
    const publr = versions.chosen_for_all(config) orelse try versions.kept(config, made.publr);

    try apply(config, publr, linked.folder, exported);

    const base = try std.fs.path.join(arena, &.{ linked.folder, site_data.base_dir });

    try cwd.deleteTree(config.io, base);
    try site_data.import_from(config, publr, base, exported, .{
        .media = false,
    });
    try site_data.keep_only_database(config.io, arena, base);
    try site_data.pin(config, linked.folder, made.publr);

    return .{
        .latest_change = manifest.latest_change,
        .bytes = made.bytes,
    };
}

/// The media files the folder holds, by key and the hash its database gives them: a pull
/// leaves out those the site holds the same. A placeholder counts, so it stays one.
fn held(config: *const Config, linked: Linked) ![]const transfer.Held {
    const state = try site_data.state(config, linked.publr, linked.folder, null);
    var files: std.ArrayList(transfer.Held) = .empty;

    for (state.media) |media| {
        const path = try std.fs.path.join(config.arena, &.{ linked.folder, media_dir, media.key });

        if (std.Io.Dir.cwd().access(config.io, path, .{})) |_| {
            try files.append(config.arena, .{
                .key = media.key,
                .hash = media.hash,
            });
        } else |_| {}
    }

    return files.items;
}

/// The pulled site in `exported` put in place in `folder`: the database, apps, plugins and
/// `publr.zon` replaced by the site's (this computer's rows carried over by Publr), the new
/// and changed media files added and the ones the site no longer has removed. What was
/// replaced is kept once in `.publr/previous/`.
fn apply(config: *const Config, publr: []const u8, folder: []const u8, exported: []const u8) !void {
    const io = config.io;
    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    const incoming = try std.fs.path.join(arena, &.{ folder, incoming_dir });
    const previous = try std.fs.path.join(arena, &.{ folder, previous_dir });
    const own_database = try std.fs.path.join(arena, &.{ folder, site_data.database });

    try cwd.deleteTree(io, incoming);
    defer cwd.deleteTree(io, incoming) catch |err| {
        std.log.warn("removing {s}: {t}", .{ incoming, err });
    };

    try site_data.import_from(config, publr, incoming, exported, .{
        .keep_local = own_database,
    });
    try cwd.deleteTree(io, previous);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ previous, "data" }));

    const database = site_data.database;
    const replaced = [_][]const u8{
        database,
        database ++ "-wal",
        database ++ "-shm",
        installed_dir,
        "publr.zon",
        "apps",
        "plugins",
    };

    for (replaced) |item| {
        try move(io, arena, folder, item, previous, item);
        try move(io, arena, incoming, item, folder, item);
    }

    try add_media(io, arena, incoming, folder);
    try remove_gone_media(config, publr, folder);
}

/// `from/<name>` moved to `to/<as>` when it is there.
fn move(
    io: std.Io,
    arena: std.mem.Allocator,
    from: []const u8,
    name: []const u8,
    to: []const u8,
    as: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const source = try std.fs.path.join(arena, &.{ from, name });
    const target = try std.fs.path.join(arena, &.{ to, as });

    cwd.access(io, source, .{}) catch return;
    try cwd.createDirPath(io, std.fs.path.dirname(target).?);
    try cwd.rename(source, cwd, target, io);
}

/// Every media file the pull brought, moved into the folder's media.
fn add_media(io: std.Io, arena: std.mem.Allocator, incoming: []const u8, folder: []const u8) !void {
    const root = try std.fs.path.join(arena, &.{ incoming, media_dir });
    var dir = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.kind == .file) {
            try files.append(arena, try arena.dupe(u8, entry.path));
        }
    }

    const media = try std.fs.path.join(arena, &.{ folder, media_dir });

    for (files.items) |path| {
        try move(io, arena, root, path, media, path);
    }
}

/// The folder's media files whose key the pulled database no longer has, removed; the
/// resized copies (dot folders) are left to the server, which makes them again.
fn remove_gone_media(config: *const Config, publr: []const u8, folder: []const u8) !void {
    const io = config.io;
    const arena = config.arena;
    const state = try site_data.state(config, publr, folder, null);
    var keys: std.StringHashMapUnmanaged(void) = .empty;

    for (state.media) |media| {
        try keys.put(arena, media.key, {});
    }

    const root = try std.fs.path.join(arena, &.{ folder, media_dir });
    var dir = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var gone: std.ArrayList([]const u8) = .empty;
    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.basename[0] == '.') {
            if (entry.kind == .directory) {
                walker.leave(io);
            }

            continue;
        }

        const key = try arena.dupe(u8, entry.path);

        std.mem.replaceScalar(u8, key, std.fs.path.sep, '/');

        if (entry.kind == .file and !keys.contains(key)) {
            try gone.append(arena, key);
        }
    }

    for (gone.items) |key| {
        try dir.deleteFile(io, key);
    }
}

test "where a folder is reads as Desktop reads it" {
    const where: Where = .{
        .changes = true,
        .unsent = false,
        .waiting = true,
        .behind = false,
        .branch = "work-abc234",
        .site = "https://shop.publr.app",
    };
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, where, .{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"waiting\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unsent\":false") != null);
}
