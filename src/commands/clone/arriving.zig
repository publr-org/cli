//! A site moving, seen in the browser: a scratch site of the site's release, in the
//! command's `clones/<name>-<doing>`, served with the progress plugin given to that server
//! alone (`serve --plugin`). A clone serves it on the clone's own port and, once the site is
//! in its folder, the scratch server goes and the site takes the port; a deploy serves it on
//! a free port beside the site's own server. The command tells the plugin where the move is
//! and reads what the person chose on its page and what the page last showed.

const std = @import("std");
const core = @import("../../core.zig");

const Config = core.Config;
const Site = core.Site;
const versions = core.versions;

pub const plugin_name = "clone_progress";
pub const page_path = "/admin/plugin/clone_progress/progress";
const plugin_main = @embedFile("clone_progress_main");
const plugin_view = @embedFile("clone_progress_view");
const plugin_steps = @embedFile("clone_progress_steps");
/// Each feed is a Publr process talking to the page's server; more often than this, they
/// queue ahead of the page's own reads. The page's clock ticks between them.
const feed_every_ms: i64 = 250;
const choice_poll_ms: u32 = 300;

/// What the page shows: the plugin's record, field for field.
pub const Progress = struct {
    /// `down` (a clone) or `up` (a deploy).
    direction: []const u8 = "down",
    name: []const u8 = "",
    folder: []const u8 = "",
    phase: []const u8 = "packing",
    packed_through: u32 = 0,
    done_bytes: u64 = 0,
    total_bytes: u64 = 0,
    placeholders: u32 = 0,
    unpacked_bytes: u64 = 0,
    media: bool = true,
    database_bytes: u64 = 0,
    media_files: u64 = 0,
    media_bytes: u64 = 0,
    apps_bytes: u64 = 0,
    plugins_bytes: u64 = 0,
    problem: []const u8 = "",
    elapsed_ms: u64 = 0,
    /// Up, once done: where it is live, and its admin signed in once.
    address: []const u8 = "",
    admin: []const u8 = "",
};

pub const Arriving = struct {
    config: *const Config,
    /// The Publr the scratch site runs: the site's release, or the one chosen.
    publr: []const u8,
    site: Site,
    progress: Progress,
    began_ms: i64,
    fed_ms: i64 = 0,

    /// The scratch site made and served on `port`, its admin `email` (the account that
    /// clones); `doing` names its folder (`cloning`, `deploying`).
    pub fn open(
        arriving: *Arriving,
        config: *const Config,
        publr: []const u8,
        release: []const u8,
        email: []const u8,
        port: u16,
        doing: []const u8,
        progress: Progress,
    ) !void {
        std.debug.assert(port > 0);
        std.debug.assert(email.len > 0);

        const name = try std.fmt.allocPrint(config.arena, "{s}-{s}", .{ progress.name, doing });
        const folder = try config.path(&.{ core.sites.clones_folder, name });
        const cwd = std.Io.Dir.cwd();

        try cwd.deleteTree(config.io, folder);
        try cwd.createDirPath(config.io, try std.fs.path.join(config.arena, &.{ folder, "apps" }));
        errdefer cwd.deleteTree(config.io, folder) catch |err| {
            std.log.warn("clone progress: removing {s}: {t}", .{ folder, err });
        };
        try cwd.writeFile(config.io, .{
            .sub_path = try std.fs.path.join(config.arena, &.{ folder, core.sites.project_file }),
            .data = try std.fmt.allocPrint(config.arena, ".{{\n    .name = \"{s}\",\n    .publr = \"{s}\",\n}}\n", .{
                name,
                release,
            }),
        });

        arriving.* = .{
            .config = config,
            .publr = publr,
            .site = try core.sites.load(config, folder, folder),
            .progress = progress,
            .began_ms = core.server.now_ms(config.io),
        };
        arriving.site.local.port = port;
        arriving.site.local.email = email;
        try core.sites.save(config, arriving.site);

        _ = try core.project.run(config, publr, folder, &.{
            "project", "init", "--email", email, "--display_name", "Admin",
        });

        const plugin = try module_of(config, publr, release, folder);

        try core.server.start_with(config, &arriving.site, publr, &.{ "--plugin", plugin });

        const key = try core.sign_on.public_key_hex(config);

        _ = try core.project.run(config, publr, folder, &.{
            "--as-admin", "sign_on",   "configure",       "--issuer", core.sign_on.issuer,
            "--public_key", &key, "--audience", name,
        });
        _ = try arriving.feed(true);
    }

    /// The page, at the clone's own address; opened again, the helper signs in again.
    pub fn link(arriving: *const Arriving) ![]const u8 {
        const origin = try core.server.admin_origin(arriving.config.arena, arriving.site);

        return std.fmt.allocPrint(arriving.config.arena, "{s}{s}", .{ origin, page_path });
    }

    /// The page told where the clone is, at most every `feed_every_ms` unless `now`; what the
    /// person chose so far (`all`, `none` or empty).
    pub fn feed(arriving: *Arriving, now: bool) ![]const u8 {
        const config = arriving.config;
        const at = core.server.now_ms(config.io);

        if (!now and at - arriving.fed_ms < feed_every_ms) {
            return "";
        }

        arriving.fed_ms = at;

        const progress = &arriving.progress;

        if (!std.mem.eql(u8, progress.phase, "choosing")) {
            progress.elapsed_ms = @intCast(@max(0, at - arriving.began_ms));
        }

        const arena = config.arena;
        const number = struct {
            fn of(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
                return std.fmt.allocPrint(allocator, "{d}", .{value});
            }
        }.of;
        const answer = core.project.run(config, arriving.publr, arriving.site.folder, &.{
            "--as-admin",                 "clone_progress.update",
            "--direction",                progress.direction,
            "--address",                  progress.address,
            "--admin",                    progress.admin,
            "--name",                     progress.name,
            "--folder",                   progress.folder,
            "--phase",                    progress.phase,
            "--packed_through",           try number(arena, progress.packed_through),
            "--done_bytes",               try number(arena, progress.done_bytes),
            "--total_bytes",              try number(arena, progress.total_bytes),
            "--placeholders",             try number(arena, progress.placeholders),
            "--unpacked_bytes",           try number(arena, progress.unpacked_bytes),
            "--media",                    if (progress.media) "true" else "false",
            "--database_bytes",           try number(arena, progress.database_bytes),
            "--media_files",              try number(arena, progress.media_files),
            "--media_bytes",              try number(arena, progress.media_bytes),
            "--apps_bytes",               try number(arena, progress.apps_bytes),
            "--plugins_bytes",            try number(arena, progress.plugins_bytes),
            "--problem",                  progress.problem,
            "--elapsed_ms",               try number(arena, progress.elapsed_ms),
        }) catch |err| {
            std.log.warn("clone progress: {t}", .{err});
            return "";
        };
        const Answer = struct {
            chosen: []const u8 = "",
        };
        const parsed = std.json.parseFromSliceLeaky(Answer, arena, answer, .{
            .ignore_unknown_fields = true,
        }) catch return "";

        return parsed.chosen;
    }

    /// The page told where the move ended, then `linger_ms` for an open page to show it
    /// (it asks every few hundred milliseconds) before the server goes.
    pub fn finish(arriving: *Arriving, linger_ms: u32) void {
        _ = arriving.feed(true) catch "";

        if (linger_ms > 0) {
            std.Io.sleep(arriving.config.io, .fromMilliseconds(linger_ms), .awake) catch {
                std.log.debug("progress: the page was not given its moment", .{});
            };
        }

        arriving.close();
    }

    /// What the person chose on the page: true for everything, false for no media files.
    pub fn wait_for_choice(arriving: *Arriving) !bool {
        arriving.progress.phase = "choosing";

        while (true) {
            const chosen = try arriving.feed(true);

            if (chosen.len > 0) {
                arriving.progress.media = std.mem.eql(u8, chosen, "all");
                arriving.progress.phase = "packing";
                arriving.began_ms = core.server.now_ms(arriving.config.io);
                _ = try arriving.feed(true);

                return arriving.progress.media;
            }

            try std.Io.sleep(arriving.config.io, .fromMilliseconds(choice_poll_ms), .awake);
        }
    }

    /// The scratch server stopped and its folder gone: the site takes the port next.
    pub fn close(arriving: *Arriving) void {
        core.server.stop(arriving.config, &arriving.site) catch |err| {
            std.log.warn("clone progress: stopping: {t}", .{err});
        };
        std.Io.Dir.cwd().deleteTree(arriving.config.io, arriving.site.folder) catch |err| {
            std.log.warn("clone progress: removing {s}: {t}", .{ arriving.site.folder, err });
        };
    }
};

/// The plugin's source the command carries, as one number.
fn source_hash() u64 {
    var hasher = std.hash.Wyhash.init(0);

    hasher.update(plugin_main);
    hasher.update(plugin_view);
    hasher.update(plugin_steps);

    return hasher.final();
}

/// The plugin built for `publr`'s release from the source the command carries, kept beside
/// that release (`versions/<v>/clone_progress.wasm`); built for every clone when a Publr of
/// one's own runs instead.
fn module_of(config: *const Config, publr: []const u8, release: []const u8, site: []const u8) ![]const u8 {
    const own = versions.chosen_for_all(config) != null;
    // Named after its source, so a command carrying a changed plugin builds it again.
    const built_name = try std.fmt.allocPrint(config.arena, "{s}-{x}.wasm", .{ plugin_name, source_hash() });
    const kept = if (own)
        try config.path(&.{ core.sites.clones_folder, built_name })
    else
        try config.path(&.{ versions.folder_name, release, built_name });
    const cwd = std.Io.Dir.cwd();

    if (!own) {
        if (cwd.access(config.io, kept, .{})) |_| {
            return kept;
        } else |_| {}
    }

    const source = try config.path(&.{ core.sites.clones_folder, "source", plugin_name });

    try cwd.deleteTree(config.io, source);
    try cwd.createDirPath(config.io, try std.fs.path.join(config.arena, &.{ source, "ui" }));
    try cwd.writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ source, "main.zig" }),
        .data = plugin_main,
    });
    try cwd.writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ source, "ui", "CloneProgress.ptsx" }),
        .data = plugin_view,
    });
    try cwd.writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ source, "ui", "CloneSteps.ptsx" }),
        .data = plugin_steps,
    });

    const self_path = try std.process.executablePathAlloc(config.io, config.arena);
    const result = try std.process.run(config.arena, config.io, .{
        .argv = &.{ self_path, "--publr", publr, "plugin", "build", "--name", plugin_name, "--dir", source, "--out", kept },
        .cwd = .{
            .path = site,
        },
    });

    if (!versions.succeeded(result.term)) {
        std.debug.print("publr clone: the progress page did not build:\n{s}{s}\n", .{ result.stdout, result.stderr });
        return error.PluginNotBuilt;
    }

    return kept;
}
