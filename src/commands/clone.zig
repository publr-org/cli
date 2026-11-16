//! `publr clone <address or project> [<folder>]`: a site brought down to work on, on the
//! release it runs. Signed in as a device, the site packs itself for a clone; the pieces come
//! down, the release's Publr takes them in as the folder and, without media, as the merge base
//! `.publr/base/`; `.publr/clone.json` links the folder back. The folder is then a site of
//! this computer's: started, signed in as the account that cloned it, opened. `publr push`
//! sends the work up as a branch.

const std = @import("std");
const core = @import("../core.zig");

const Config = core.Config;
const archive = core.archive;
const credentials = core.credentials;
const links = core.links;
const site_data = core.site_data;
const transfer = core.transfer;
const versions = core.versions;
const Arriving = @import("clone/arriving.zig").Arriving;

pub const usage =
    \\usage: publr clone <address or project> [<folder>] [--media all|none] [--size]
    \\                   [--port <n>] [--no-open] [--no-serve]
    \\
;

/// What was asked: `--media none` brings no media files down (placeholders stand in);
/// `--size` only says what a clone would bring down.
const Asked = struct {
    given: []const u8 = "",
    folder: ?[]const u8 = null,
    media: bool = true,
    /// `--media` was given: nothing to ask.
    media_given: bool = false,
    size_only: bool = false,
    /// The port its page, then the site, answers on; a free one when null.
    port: ?u16 = null,
    open: bool = true,
    serve: bool = true,
};

fn parse(args: []const []const u8) ?Asked {
    var asked: Asked = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--media") and index + 1 < args.len) {
            index += 1;

            const all = std.mem.eql(u8, args[index], "all");

            if (!all and !std.mem.eql(u8, args[index], "none")) {
                return null;
            }

            asked.media = all;
            asked.media_given = true;
        } else if (std.mem.eql(u8, arg, "--port") and index + 1 < args.len) {
            index += 1;
            asked.port = std.fmt.parseInt(u16, args[index], 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--size")) {
            asked.size_only = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            asked.open = false;
        } else if (std.mem.eql(u8, arg, "--no-serve")) {
            asked.serve = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return null;
        } else if (asked.given.len == 0) {
            asked.given = arg;
        } else if (asked.folder == null) {
            asked.folder = arg;
        } else {
            return null;
        }
    }

    return if (asked.given.len > 0) asked else null;
}

pub fn run(
    init: std.process.Init,
    config: *Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
    self_path: []const u8,
) !u8 {
    const asked = parse(rest) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const site = try signed_in(init, config, out, asked.given) orelse return 1;
    // Packs and pieces come from where the site is synced, past any CDN in front of it.
    const syncing = transfer.sync_of(config.io, config.arena, site);

    if (asked.size_only) {
        const text = try transfer.size_text(config.io, config.arena, syncing) orelse return 1;

        try out.print("{s}\n", .{text});
        return 0;
    }

    const release = try transfer.release_of(config.io, config.arena, site) orelse return 1;
    const publr = versions.chosen_for_all(config) orelse try versions.kept(config, release);
    const by_slug = std.mem.indexOfAny(u8, asked.given, ".:/") == null;
    const name = if (by_slug) asked.given else name_of(site.address);
    const folder = if (asked.folder) |given|
        try core.sites.absolute(config, given)
    else
        try std.fs.path.join(config.arena, &.{ config.folder, name });

    if (std.Io.Dir.cwd().access(config.io, folder, .{})) |_| {
        std.debug.print("publr clone: {s} is there already\n", .{folder});
        return 1;
    } else |_| {}

    // The folder it goes in, made on a computer with no projects yet.
    if (std.fs.path.dirname(folder)) |parent| try std.Io.Dir.cwd().createDirPath(config.io, parent);

    // Weighed before the page is drawn: its choice and its bar's parts come from this.
    const size = try transfer.size_of(config.io, config.arena, syncing) orelse transfer.Size{};
    const port = asked.port orelse try (try core.Sites.find(config)).free_port(&core.server.listening);
    // Asked on the page what comes down, unless the command said (`--media`) or the site has
    // no media files, when everything is all there is.
    const asking = !asked.media_given and size.media_files > 0;
    var arriving: Arriving = undefined;

    try arriving.open(config, publr, release, site.email, port, "cloning", .{
        .name = name,
        .folder = shown_folder(folder),
        .phase = if (asking) "choosing" else "packing",
        .media = asked.media,
        .database_bytes = size.database_bytes,
        .media_files = size.media_files,
        .media_bytes = size.media_bytes,
        .apps_bytes = size.apps_bytes,
        .plugins_bytes = size.plugins_bytes,
    });

    const page = try arriving.link();

    try out.print("Bringing {s} into {s}. Follow it at {s}\n", .{ site.address, folder, page });
    try out.flush();

    if (asked.open and init.environ_map.get("PUBLR_NO_BROWSER") == null) {
        core.login.open_browser(init, page);
    }

    var media = asked.media;

    if (asking) {
        try out.writeAll("Choose on that page what comes down (or run again with --media all|none).\n");
        try out.flush();
        media = arriving.wait_for_choice() catch |err| {
            arriving.close();
            std.debug.print("publr clone: {s}\n", .{stopped_because(err)});
            return 1;
        };
    }

    const latest = bring_down(config, out, syncing, publr, folder, media, &arriving) catch |err| {
        const why = stopped_because(err);

        std.debug.print("publr clone: {s}\n", .{why});
        failed(&arriving, why);
        std.Io.Dir.cwd().deleteTree(config.io, folder) catch |removing| {
            std.log.warn("removing {s}: {t}", .{ folder, removing });
        };
        return 1;
    } orelse {
        failed(&arriving, "the site could not be packed; the command said why");
        std.Io.Dir.cwd().deleteTree(config.io, folder) catch |removing| {
            std.log.warn("removing {s}: {t}", .{ folder, removing });
        };
        return 1;
    };

    try site_data.pin(config, folder, release);
    try links.write_clone(config, folder, .{
        .site = site.address,
        .branch = try links.new_branch(config.io, config.arena),
        .pulled = latest,
    });

    if (!media) {
        arriving.progress.phase = "placeholders";
        _ = try arriving.feed(true);

        const written = try site_data.write_placeholders(config, publr, folder);

        arriving.progress.placeholders = written;
        try out.print("Placeholders stand in for {d} media files; push never sends them.\n", .{written});
    }

    // The page hears the site is coming before this server stops answering, then waits for
    // the site's own server on the same address.
    arriving.progress.phase = "starting";
    _ = try arriving.feed(true);
    try std.Io.sleep(config.io, .fromMilliseconds(1200), .awake);
    arriving.close();

    try out.print("Cloned {s} into {s}. Send it up as a branch: publr push\n", .{ site.address, folder });

    if (!asked.serve) {
        return 0;
    }

    return serve(config, out, folder, site.email, port, self_path);
}

/// The page says why the clone stopped, a moment before its server goes.
fn failed(arriving: *Arriving, why: []const u8) void {
    arriving.progress.phase = "failed";
    arriving.progress.problem = why;
    _ = arriving.feed(true) catch "";
    std.Io.sleep(arriving.config.io, .fromSeconds(3), .awake) catch {
        std.log.debug("clone: the page was not given its moment", .{});
    };
    arriving.close();
}

/// The folder as the page names it: its last two names (`Publr/shop`), enough to know it.
fn shown_folder(folder: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, folder, "/");
    const last = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    const before = std.mem.lastIndexOfScalar(u8, trimmed[0..last], '/') orelse return trimmed;

    return trimmed[before + 1 ..];
}

/// The clone as a site of this computer's: listed, signed in as the account that cloned it
/// (the only one it has, an administrator there), started, its admin opened.
fn serve(
    config: *Config,
    out: *std.Io.Writer,
    folder: []const u8,
    email: []const u8,
    port: u16,
    self_path: []const u8,
) !u8 {
    const parent = std.fs.path.dirname(folder) orelse folder;
    var listed = false;

    for (try config.entries()) |entry| {
        listed = listed or std.mem.eql(u8, entry, parent) or std.mem.eql(u8, entry, folder);
    }

    if (!listed and try config.add(folder)) {
        try config.save();
    }

    var site = try core.sites.load(config, folder, if (listed) parent else folder);

    site.local.email = email;
    site.local.port = port;
    site.local.created_ms = core.server.now_ms(config.io);
    try core.sites.save(config, site);
    try core.project.set_up(config, &site, try versions.binary_for(config, site), self_path);
    try out.print("  site   {s}\n  admin  {s}\n", .{
        try core.server.site_url(config.arena, site),
        try core.server.admin_url(config.arena, site),
    });

    return 0;
}

/// The site packed for this clone, downloaded and taken in as the folder and its base, the
/// page told how far at each step; the site's newest change it carries. Null, having said
/// why, when the site did not pack.
fn bring_down(
    config: *const Config,
    out: *std.Io.Writer,
    site: credentials.Site,
    publr: []const u8,
    folder: []const u8,
    media: bool,
    arriving: *Arriving,
) !?i64 {
    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    const asked = if (media) "{}" else "{\"media\":\"none\"}";
    const watch: transfer.Watch = .{
        .context = arriving,
        .packing = packing,
        .downloading = downloading,
    };
    const made = try transfer.prepared(config.io, arena, site, asked, out, watch) orelse return null;
    const download = try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, archive.extension });

    defer cwd.deleteFile(config.io, download) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download, err });
    };

    arriving.progress.phase = "downloading";
    arriving.progress.total_bytes = made.bytes;
    _ = try arriving.feed(true);
    try transfer.fetch(config.io, site, made.bytes, download, out, watch);

    const exported = try site_data.scratch_beside(config, folder, "clone");
    defer cwd.deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    arriving.progress.phase = "unpacking";
    _ = try arriving.feed(true);

    const manifest = try archive.read(config.io, arena, download, exported);
    const base = try std.fs.path.join(arena, &.{ folder, site_data.base_dir });

    try out.print("Taking it in...\n", .{});
    try out.flush();
    try import_watched(config, publr, folder, exported, arriving);
    try site_data.import_from(config, publr, base, exported, .{
        .media = false,
    });
    try site_data.keep_only_database(config.io, arena, base);

    return manifest.latest_change;
}

fn packing(context: *anyopaque, through: u32) void {
    const arriving: *Arriving = @ptrCast(@alignCast(context));

    arriving.progress.packed_through = through;
    _ = arriving.feed(false) catch "";
}

fn downloading(context: *anyopaque, done_bytes: u64, total_bytes: u64) void {
    const arriving: *Arriving = @ptrCast(@alignCast(context));

    arriving.progress.phase = "downloading";
    arriving.progress.done_bytes = done_bytes;
    arriving.progress.total_bytes = total_bytes;
    _ = arriving.feed(false) catch "";
}

/// The import run beside, the page told how much of the site the folder holds as it grows.
fn import_watched(
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    exported: []const u8,
    arriving: *Arriving,
) !void {
    const Import = struct {
        config: Config,
        publr: []const u8,
        folder: []const u8,
        exported: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(import: *@This()) void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();

            var own = import.config;

            own.arena = arena_state.allocator();
            site_data.import_from(&own, import.publr, import.folder, import.exported, .{}) catch |err| {
                import.failure = err;
            };
            import.done.store(true, .release);
        }
    };
    var import: Import = .{
        .config = config.*,
        .publr = publr,
        .folder = folder,
        .exported = exported,
    };
    const thread = try std.Thread.spawn(.{}, Import.run, .{&import});

    while (!import.done.load(.acquire)) {
        arriving.progress.unpacked_bytes = bytes_in(config, folder);
        _ = arriving.feed(false) catch "";
        try std.Io.sleep(config.io, .fromMilliseconds(200), .awake);
    }

    thread.join();
    arriving.progress.unpacked_bytes = bytes_in(config, folder);

    if (import.failure) |err| {
        return err;
    }
}

/// What the files under `folder` weigh, as far as a walk of it gets.
fn bytes_in(config: *const Config, folder: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(config.io, folder, .{
        .iterate = true,
    }) catch return 0;
    defer dir.close(config.io);

    var walker = dir.walk(config.arena) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    var seen: u32 = 0;

    while (seen < 100_000) : (seen += 1) {
        const entry = (walker.next(config.io) catch return total) orelse return total;

        if (entry.kind != .file) {
            continue;
        }

        const stat = entry.dir.statFile(config.io, entry.basename, .{}) catch continue;

        total += stat.size;
    }

    return total;
}

/// This computer's device for the site `given` names, signing in first when it has none.
fn signed_in(
    init: std.process.Init,
    config: *const Config,
    out: *std.Io.Writer,
    given: []const u8,
) !?credentials.Site {
    const typed = if (std.mem.indexOfAny(u8, given, ".:/") == null)
        try std.fmt.allocPrint(config.arena, "https://{s}.publr.app", .{given})
    else
        given;
    const address = try credentials.normalize(config.arena, typed) orelse {
        std.debug.print("publr clone: {s} is not an address\n", .{given});
        return null;
    };

    if (try credentials.find(init, address) == null) {
        const words = [_][]const u8{ "login", address };

        if (try core.login.run(init, out, &words) != 0) {
            return null;
        }
    }

    return credentials.find(init, address);
}

/// Why a clone stopped, for people.
fn stopped_because(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "the site did not answer. Is it running?",
        error.ShortDownload, error.DownloadRefused => "the download broke off. Try again.",
        error.PublrFailed => "Publr could not take the site in; it said why above.",
        error.PageClosed => "the page closed before anything was chosen.",
        else => @errorName(err),
    };
}

/// A folder's name for a site given by its address: its first name, without the admin's
/// part (`test-m964yr--admin.publr.app` is `test-m964yr`, `admin.example.com` `example`).
fn name_of(address: []const u8) []const u8 {
    std.debug.assert(address.len > 0);

    const scheme_end = if (std.mem.indexOf(u8, address, "://")) |at| at + 3 else 0;
    const after_scheme = address[scheme_end..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    const bare = if (std.mem.startsWith(u8, host, "admin.")) host["admin.".len..] else host;
    const first = bare[0 .. std.mem.indexOfScalar(u8, bare, '.') orelse bare.len];
    const cut = std.mem.indexOf(u8, first, "--") orelse first.len;

    return if (cut > 0) first[0..cut] else "site";
}

test "a folder is named after the site's first name" {
    try std.testing.expectEqualStrings("test-m964yr", name_of("https://test-m964yr--admin.publr.app"));
    try std.testing.expectEqualStrings("example", name_of("https://admin.example.com"));
    try std.testing.expectEqualStrings("shop", name_of("http://shop.localhost:8080/"));
}

test "clone's words" {
    try std.testing.expect(parse(&.{}) == null);
    try std.testing.expect(!parse(&.{ "shop", "--media", "none" }).?.media);
    try std.testing.expect(parse(&.{ "shop", "--media", "some" }) == null);
    try std.testing.expectEqualStrings("here", parse(&.{ "shop", "here" }).?.folder.?);
}
