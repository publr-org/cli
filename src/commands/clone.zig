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

pub const usage =
    \\usage: publr clone <address or project> [<folder>] [--media all|none] [--size]
    \\                   [--no-open] [--no-serve]
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

    if (asked.size_only) {
        const text = try transfer.size_text(config.io, config.arena, site) orelse return 1;

        try out.print("{s}\n", .{text});
        return 0;
    }

    const release = try transfer.release_of(config.io, config.arena, site) orelse return 1;
    const publr = try versions.kept(config, release);
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

    const media = if (asked.media_given) asked.media else try ask_media(init, config, site);

    try out.print("Bringing {s} (Publr {s}) into {s}\n", .{ site.address, release, folder });
    try out.flush();

    const latest = bring_down(config, out, site, publr, folder, media) catch |err| {
        std.debug.print("publr clone: {s}\n", .{stopped_because(err)});
        std.Io.Dir.cwd().deleteTree(config.io, folder) catch |removing| {
            std.log.warn("removing {s}: {t}", .{ folder, removing });
        };
        return 1;
    } orelse return 1;

    try site_data.pin(config, folder, release);
    try links.write_clone(config, folder, .{
        .site = site.address,
        .branch = try links.new_branch(config.io, config.arena),
        .pulled = latest,
    });

    if (!media) {
        const written = try site_data.write_placeholders(config, publr, folder);

        try out.print("Placeholders stand in for {d} media files; push never sends them.\n", .{written});
    }

    try out.print("Cloned {s} into {s}. Send it up as a branch: publr push\n", .{ site.address, folder });

    if (!asked.serve) {
        return 0;
    }

    return serve(init, config, out, folder, site.email, asked.open, self_path);
}

/// The clone as a site of this computer's: listed, signed in as the account that cloned it
/// (the only one it has, an administrator there), started, its admin opened.
fn serve(
    init: std.process.Init,
    config: *Config,
    out: *std.Io.Writer,
    folder: []const u8,
    email: []const u8,
    open: bool,
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
    site.local.created_ms = core.server.now_ms(config.io);
    try core.sites.save(config, site);
    try core.project.set_up(config, &site, try versions.binary_for(config, site), self_path);
    try out.print("  site   {s}\n  admin  {s}\n", .{
        try core.server.site_url(config.arena, site),
        try core.server.admin_url(config.arena, site),
    });

    if (open and init.environ_map.get("PUBLR_NO_BROWSER") == null) {
        try out.flush();
        core.login.open_browser(init, try core.sign_on.link(config, site, "/admin"));
    }

    return 0;
}

/// Whether to bring media files down: asked on the terminal, with what they weigh; all of
/// them when nobody is there to ask.
fn ask_media(init: std.process.Init, config: *const Config, site: credentials.Site) !bool {
    const size = try transfer.size_of(config.io, config.arena, site) orelse return true;

    const asking = std.Io.File.stdin().isTty(init.io) catch false;

    if (size.media_files == 0 or !asking) {
        return true;
    }

    std.debug.print("Bring the {d} media files down too ({d} MiB)? Without them, " ++
        "placeholders of the same size stand in. [Y/n] ", .{
        size.media_files,
        size.media_bytes >> 20,
    });

    var buffer: [64]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const line = stdin.interface.takeDelimiterExclusive('\n') catch return true;
    const answer = std.mem.trim(u8, line, " \r\t");

    return !(std.ascii.eqlIgnoreCase(answer, "n") or std.ascii.eqlIgnoreCase(answer, "no"));
}

/// The site packed for this clone, downloaded and taken in as the folder and its base; the
/// site's newest change it carries. Null, having said why, when the site did not pack.
fn bring_down(
    config: *const Config,
    out: *std.Io.Writer,
    site: credentials.Site,
    publr: []const u8,
    folder: []const u8,
    media: bool,
) !?i64 {
    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    const asked = if (media) "{}" else "{\"media\":\"none\"}";
    const made = try transfer.prepared(config.io, arena, site, asked, out) orelse return null;
    const download = try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, archive.extension });

    defer cwd.deleteFile(config.io, download) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download, err });
    };

    try transfer.fetch(config.io, site, made.bytes, download, out);

    const exported = try site_data.scratch_beside(config, folder, "clone");
    defer cwd.deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    const manifest = try archive.read(config.io, arena, download, exported);
    const base = try std.fs.path.join(arena, &.{ folder, site_data.base_dir });

    try out.print("Taking it in...\n", .{});
    try out.flush();
    try site_data.import_from(config, publr, folder, exported, .{});
    try site_data.import_from(config, publr, base, exported, .{
        .media = false,
    });
    try site_data.keep_only_database(config.io, arena, base);

    return manifest.latest_change;
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
