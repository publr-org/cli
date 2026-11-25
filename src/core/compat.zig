//! A site on this computer measured against the Publr Cloud runs: up to date, an update out,
//! its Cloud project ahead of it, or local only (Cloud's Publr cannot open its database, as
//! when a development build of Publr made it). The command, `publr ls` and Desktop show the
//! same state; `publr upgrade <site>` (`update.zig`) is the one action that fixes each.
//! `.agents/specs/updates.md`, "Sites on a computer".

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const versions = @import("versions.zig");
const links = @import("links.zig");
const site_data = @import("site_data.zig");
const cloud_login = @import("cloud_login.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

pub const State = enum {
    /// It runs the release Cloud runs.
    up_to_date,
    /// An older release, or a development build whose database Cloud's Publr opens.
    update_available,
    /// Cloud's Publr cannot open its database, or it runs a release newer than Cloud's.
    local_only,
};

pub const Version = struct {
    state: State,
    /// What it runs: a release (`0.7.5`) or `development build`.
    runs: []const u8,
    /// The release Cloud runs, which `publr upgrade` moves it to.
    cloud: []const u8,
    /// Why it is local only, in words; empty otherwise.
    reason: []const u8 = "",
};

pub const development = "development build";
/// How long Cloud's release, once asked, is taken as known.
const cloud_release_keep_ms: i64 = 60 * 60 * 1000;
const cache_name = "cloud-release";
const check_name = "compat.json";
const check_bytes_max: u32 = 64 * 1024;

pub const Options = struct {
    /// Wait: ask Cloud for its release when the one kept is old, and run Cloud's Publr on the
    /// database when no answer is kept for it. False answers from what is kept alone, of any
    /// age (`error.NotKnown` before Cloud was ever asked; a development build never checked
    /// counts as compatible until it is): for a caller that must not wait, as Desktop's main
    /// thread, which asks the rest on another.
    wait: bool = true,
};

/// Where `site` stands against Cloud's release.
pub fn of(config: *const Config, site: Site, options: Options) !Version {
    const cloud = if (options.wait) try cloud_release(config) else try kept_release(config);
    const linked = linked_to_cloud(config, site.folder);

    if (versions.chosen_binary(config, site)) |binary| {
        const compatible = try opens(config, site, binary, cloud, options);

        return if (compatible) .{
            .state = .update_available,
            .runs = development,
            .cloud = cloud,
        } else .{
            .state = .local_only,
            .runs = development,
            .cloud = cloud,
            .reason = "Made with a development build of Publr, so it cannot go to Cloud yet",
        };
    }

    const pin = (try versions.pin_of(config, site.folder)) orelse return .{
        .state = .up_to_date,
        .runs = cloud,
        .cloud = cloud,
    };

    return of_release(config.arena, pin, cloud, linked);
}

/// Whether the folder is a copy of a site on Cloud: one deployed from it (`cloud.json`) or one
/// cloned from Cloud (`.publr/clone.json`). Either follows its site by itself.
fn linked_to_cloud(config: *const Config, folder: []const u8) bool {
    for ([_][]const u8{ links.cloud_name, links.clone_path }) |name| {
        const path = std.fs.path.join(config.arena, &.{ folder, name }) catch continue;

        if (std.Io.Dir.cwd().access(config.io, path, .{})) |_| {
            return true;
        } else |_| {}
    }

    return false;
}

/// A site that runs release `pin`, against Cloud's `cloud`.
pub fn of_release(arena: std.mem.Allocator, pin: []const u8, cloud: []const u8, linked: bool) !Version {
    const order = order_of(pin, cloud);

    return switch (order) {
        .eq => .{
            .state = .up_to_date,
            .runs = pin,
            .cloud = cloud,
        },
        .lt => .{
            // A copy linked to a Cloud project follows it by itself (`publr pull --check`, which
            // Desktop's sync runs, pins the project's release): never an update to ask for.
            .state = if (linked) .up_to_date else .update_available,
            .runs = pin,
            .cloud = cloud,
        },
        .gt => .{
            .state = .local_only,
            .runs = pin,
            .cloud = cloud,
            .reason = try std.fmt.allocPrint(arena, "Runs Publr {s}, newer than the {s} Cloud runs", .{
                pin,
                cloud,
            }),
        },
    };
}

fn order_of(left: []const u8, right: []const u8) std.math.Order {
    const a = std.SemanticVersion.parse(left) catch return .eq;
    const b = std.SemanticVersion.parse(right) catch return .eq;

    return a.order(b);
}

/// The release Cloud runs as last asked, of any age, without asking.
pub fn kept_release(config: *const Config) ![]const u8 {
    const found = read_kept(config, try config.path(&.{cache_name})) orelse return error.NotKnown;

    return found.version;
}

/// The release Cloud runs, as its health check says (no sign-in needed), kept for an hour;
/// the last one asked when Cloud cannot be reached; the newest release when never asked.
pub fn cloud_release(config: *const Config) ![]const u8 {
    const path = try config.path(&.{cache_name});
    const now = std.Io.Timestamp.now(config.io, .real).toMilliseconds();
    const kept = read_kept(config, path);

    if (kept) |found| {
        if (now - found.asked_ms < cloud_release_keep_ms) {
            return found.version;
        }
    }

    const asked = ask_cloud(config) catch |err| {
        if (kept) |found| {
            return found.version;
        }

        std.debug.print("publr: Cloud's release could not be asked for ({t})\n", .{err});
        return versions.newest(config);
    };

    write_kept(config, path, asked, now) catch {};

    return asked;
}

const Kept = struct {
    version: []const u8,
    asked_ms: i64,
};

fn read_kept(config: *const Config, path: []const u8) ?Kept {
    const text = std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, .limited(256)) catch return null;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    const version = words.next() orelse return null;
    const asked = std.fmt.parseInt(i64, words.next() orelse return null, 10) catch return null;

    _ = std.SemanticVersion.parse(version) catch return null;

    return .{
        .version = version,
        .asked_ms = asked,
    };
}

fn write_kept(config: *const Config, path: []const u8, version: []const u8, now: i64) !void {
    const text = try std.fmt.allocPrint(config.arena, "{s} {d}\n", .{ version, now });

    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(config.io, dir);
    }

    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = path,
        .data = text,
    });
}

fn ask_cloud(config: *const Config) ![]const u8 {
    const dashboard = config.environ.get(cloud_login.dashboard_variable) orelse cloud_login.dashboard_default;
    const url = try std.fmt.allocPrint(config.arena, "{s}/api/health", .{dashboard});
    var body: std.Io.Writer.Allocating = .init(config.arena);

    try versions.get(config.io, url, &body.writer);

    const Health = struct {
        version: []const u8 = "",
    };
    const health = std.json.parseFromSliceLeaky(Health, config.arena, body.written(), .{
        .ignore_unknown_fields = true,
    }) catch return error.BadAnswer;

    _ = std.SemanticVersion.parse(health.version) catch return error.BadAnswer;

    return health.version;
}

/// What a check found, kept in the site's `.publr/compat.json`: asked again when the Publr
/// it runs or Cloud's release changes.
const Checked = struct {
    binary: []const u8,
    /// The binary's last change, so a rebuilt one is asked again.
    modified_ns: i96,
    cloud: []const u8,
    compatible: bool,
};

/// Whether Cloud's release opens the site's database as it is (`publr db check`, which
/// changes nothing): the answer kept for this binary and release, else asked now.
fn opens(config: *const Config, site: Site, binary: []const u8, cloud: []const u8, options: Options) !bool {
    const path = try std.fs.path.join(config.arena, &.{ site.folder, sites_module.own_folder, check_name });
    const modified = modified_of(config, binary);

    if (read_checked(config, path)) |found| {
        if (std.mem.eql(u8, found.binary, binary) and found.modified_ns == modified and
            std.mem.eql(u8, found.cloud, cloud))
        {
            return found.compatible;
        }
    }

    if (!options.wait) {
        return true;
    }

    const compatible = try check(config, site, cloud);
    const text = try std.json.Stringify.valueAlloc(config.arena, Checked{
        .binary = binary,
        .modified_ns = modified,
        .cloud = cloud,
        .compatible = compatible,
    }, .{});

    std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = path,
        .data = text,
    }) catch {};

    return compatible;
}

/// Cloud's release run on the site's database: `db check` exits 0 when it would open it.
pub fn check(config: *const Config, site: Site, cloud: []const u8) !bool {
    const release = try versions.kept(config, cloud);
    const database = try std.fs.path.join(config.arena, &.{ site.folder, site_data.database });

    std.Io.Dir.cwd().access(config.io, database, .{}) catch return true;

    const result = try std.process.run(config.arena, config.io, .{
        .argv = &.{ release, "--db", database, "db", "check" },
        .cwd = .{
            .path = site.folder,
        },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });

    return versions.succeeded(result.term);
}

/// Forget what a check found: after `publr upgrade` changed the site.
pub fn forget(config: *const Config, site: Site) void {
    const path = std.fs.path.join(config.arena, &.{ site.folder, sites_module.own_folder, check_name }) catch return;

    std.Io.Dir.cwd().deleteFile(config.io, path) catch {};
}

fn read_checked(config: *const Config, path: []const u8) ?Checked {
    const text = std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, .limited(check_bytes_max)) catch return null;

    return std.json.parseFromSliceLeaky(Checked, config.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

fn modified_of(config: *const Config, binary: []const u8) i96 {
    const stat = std.Io.Dir.cwd().statFile(config.io, binary, .{}) catch return 0;

    return stat.mtime.nanoseconds;
}

/// The state in a few words, for `publr ls`.
pub fn label(version: Version) []const u8 {
    return switch (version.state) {
        .up_to_date => "up to date",
        .update_available => "update out",
        .local_only => "local only",
    };
}

test "a release against Cloud's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(State.up_to_date, (try of_release(arena, "0.8.0", "0.8.0", false)).state);
    try std.testing.expectEqual(State.update_available, (try of_release(arena, "0.7.5", "0.8.0", false)).state);
    try std.testing.expectEqual(State.up_to_date, (try of_release(arena, "0.7.5", "0.8.0", true)).state);
    // Five releases behind is one update, as one behind is.
    try std.testing.expectEqual(State.update_available, (try of_release(arena, "0.3.0", "0.8.0", false)).state);

    const ahead = try of_release(arena, "0.9.0", "0.8.0", false);

    try std.testing.expectEqual(State.local_only, ahead.state);
    try std.testing.expectEqualStrings("Runs Publr 0.9.0, newer than the 0.8.0 Cloud runs", ahead.reason);
}
