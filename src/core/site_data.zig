//! A site's data, asked of the site's own Publr in its folder: exported to a folder, taken in
//! from one, its state (release, newest change and write, media records), placeholders for
//! media it came without. The command never reads a site's database itself.

const std = @import("std");
const config_module = @import("config.zig");
const project = @import("project.zig");
const versions = @import("versions.zig");
const sites = @import("sites.zig");

const Config = config_module.Config;

pub const database = "data/publr.db";
pub const base_dir = ".publr/base";
pub const placeholders_list = ".publr/placeholders";
const state_bytes_max: u32 = 256 << 20;
const list_bytes_max: u32 = 64 << 20;

pub const ExportOptions = struct {
    /// Without what a clone leaves: logs, secrets, internal records.
    clone: bool = false,
    media: bool = true,
    /// A file of media storage keys, one a line, whose files stay behind.
    placeholders: []const u8 = "",
};

/// The site in `folder` exported into `to` (missing or empty) by `publr`.
pub fn export_to(
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    to: []const u8,
    options: ExportOptions,
) !void {
    std.debug.assert(to.len > 0);

    var words: std.ArrayList([]const u8) = .empty;

    try words.appendSlice(config.arena, &.{ "site", "export", "--to", to });

    if (options.clone) {
        try words.append(config.arena, "--clone");
    }

    if (!options.media) {
        try words.append(config.arena, "--no-media");
    }

    if (options.placeholders.len > 0) {
        try words.appendSlice(config.arena, &.{ "--placeholders", options.placeholders });
    }

    _ = try project.run(config, publr, folder, words.items);
}

pub const ImportOptions = struct {
    media: bool = true,
    /// A database whose rows of this computer's (sign-on, sessions, devices) carry over.
    keep_local: []const u8 = "",
};

/// The exported site in `from` taken into `folder` (made when missing) by `publr`.
pub fn import_from(
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    from: []const u8,
    options: ImportOptions,
) !void {
    std.debug.assert(from.len > 0);

    var words: std.ArrayList([]const u8) = .empty;

    try std.Io.Dir.cwd().createDirPath(config.io, folder);
    try words.appendSlice(config.arena, &.{ "site", "import", "--from", from });

    if (!options.media) {
        try words.append(config.arena, "--no-media");
    }

    if (options.keep_local.len > 0) {
        try words.appendSlice(config.arena, &.{ "--keep-local", options.keep_local });
    }

    _ = try project.run(config, publr, folder, words.items);
}

pub const Media = struct {
    key: []const u8,
    hash: []const u8,
};

pub const State = struct {
    release: []const u8 = "",
    latest_change: i64 = 0,
    latest_write: i64 = 0,
    media: []const Media = &.{},
};

/// What `publr site state` says of the site in `folder`.
pub fn state(config: *const Config, publr: []const u8, folder: []const u8, until_ms: ?i64) !State {
    var words: std.ArrayList([]const u8) = .empty;

    try words.appendSlice(config.arena, &.{ "site", "state" });

    if (until_ms) |until| {
        try words.appendSlice(config.arena, &.{
            "--until",
            try std.fmt.allocPrint(config.arena, "{d}", .{until}),
        });
    }

    const text = try project.run(config, publr, folder, words.items);

    std.debug.assert(text.len < state_bytes_max);

    return std.json.parseFromSliceLeaky(State, config.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// The plugin that serves a site's media from another address (the plugins repo's
/// `media_origin`): a copy loads its media from the site it copies.
pub const media_origin = "media_origin";
/// How long the marketplace's install may take, in half seconds.
const install_waits_max: u32 = 240;

/// The copy in `folder` loads its media from `address`: `media_origin` installed from Publr's
/// marketplace and set to it. Its server must run (the install is its queued work). False,
/// having said why, when it cannot be (its Publr has no `media.base`, the marketplace is out of
/// reach): the caller writes placeholders instead.
pub fn media_from(config: *const Config, publr: []const u8, folder: []const u8, address: []const u8) bool {
    std.debug.assert(address.len > 0);

    const asked = project.run(config, publr, folder, &.{ "--as-admin", "plugin", "install", "--name", media_origin }) catch return false;
    const Asked = struct {
        asked: []const u8 = "",
    };
    const id = (std.json.parseFromSliceLeaky(Asked, config.arena, asked, .{
        .ignore_unknown_fields = true,
    }) catch return false).asked;

    if (id.len == 0) {
        return false;
    }

    var waits: u32 = 0;

    while (waits < install_waits_max) : (waits += 1) {
        const said = project.run(config, publr, folder, &.{ "--as-admin", "job", "answer", "--id", id }) catch return false;
        const Answer = struct {
            state: []const u8 = "",
            problem: []const u8 = "",
        };
        const answer = std.json.parseFromSliceLeaky(Answer, config.arena, said, .{
            .ignore_unknown_fields = true,
        }) catch return false;

        if (std.mem.eql(u8, answer.state, "done")) {
            break;
        }

        if (std.mem.eql(u8, answer.state, "failed")) {
            std.debug.print("publr: {s} could not be installed: {s}\n", .{ media_origin, answer.problem });
            return false;
        }

        std.Io.sleep(config.io, .fromMilliseconds(500), .awake) catch return false;
    } else return false;

    _ = project.run(config, publr, folder, &.{ "--as-admin", media_origin, "set", "--origin", address }) catch return false;

    return true;
}

/// Placeholders for the media `folder`'s site came without, written by its Publr, and their
/// list kept in `.publr/placeholders` so a push leaves them behind; how many.
pub fn write_placeholders(config: *const Config, publr: []const u8, folder: []const u8) !u32 {
    const list = try project.run(config, publr, folder, &.{ "site", "placeholders" });
    const path = try std.fs.path.join(config.arena, &.{ folder, placeholders_list });

    try std.Io.Dir.cwd().createDirPath(config.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = path,
        .data = list,
    });

    return @intCast(std.mem.count(u8, list, "\n"));
}

/// The storage keys under `folder` whose files are still the placeholders written for them:
/// one replaced since (a real file fetched, an image edited) is the folder's own again.
pub fn placeholders_kept(config: *const Config, folder: []const u8) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(config.arena, &.{ folder, placeholders_list });
    const text = cwd.readFileAlloc(config.io, path, config.arena, .limited(list_bytes_max)) catch |err| {
        return switch (err) {
            error.FileNotFound => &.{},
            else => err,
        };
    };
    var kept: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');

    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const key = line[0..tab];
        const bytes = std.fmt.parseInt(u64, line[tab + 1 ..], 10) catch continue;

        if (!safe_key(key)) {
            continue;
        }

        const file = try std.fs.path.join(config.arena, &.{ folder, "data", "media", key });
        const stat = cwd.statFile(config.io, file, .{}) catch continue;

        if (stat.size == bytes) {
            try kept.append(config.arena, key);
        }
    }

    return kept.items;
}

fn safe_key(key: []const u8) bool {
    return key.len > 0 and key[0] != '/' and std.mem.indexOf(u8, key, "..") == null;
}

/// Everything in a base's data folder but its database: media stays once, in the site.
pub fn keep_only_database(io: std.Io, arena: std.mem.Allocator, base: []const u8) !void {
    std.debug.assert(base.len > 0);

    const data = try std.fs.path.join(arena, &.{ base, "data" });
    var dir = try std.Io.Dir.cwd().openDir(io, data, .{
        .iterate = true,
    });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, std.fs.path.basename(database))) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        try dir.deleteTree(io, name);
    }
}

/// `folder` and its base pinned to `version`: the pin is this computer's, so both carry it
/// alike and it never reads as the folder's own work. A folder the site gave no `publr.zon`
/// gets one holding only the pin.
pub fn pin(config: *const Config, folder: []const u8, version: []const u8) !void {
    std.debug.assert(version.len > 0);

    const base = try std.fs.path.join(config.arena, &.{ folder, base_dir });

    for ([_][]const u8{ folder, base }) |each| {
        const exists = blk: {
            std.Io.Dir.cwd().access(config.io, each, .{}) catch break :blk false;
            break :blk true;
        };

        if (!exists) {
            continue;
        }

        if (!sites.is_site(config.io, config.arena, each)) {
            try std.Io.Dir.cwd().writeFile(config.io, .{
                .sub_path = try std.fs.path.join(config.arena, &.{ each, sites.project_file }),
                .data = try std.fmt.allocPrint(config.arena, ".{{\n    .publr = \"{s}\",\n}}\n", .{version}),
            });
            continue;
        }

        try versions.set_pin(config, each, version);
    }
}

/// A folder beside `folder`, named after it, for an export on its way in or out; removed
/// first when an earlier run left it.
pub fn scratch_beside(config: *const Config, folder: []const u8, label: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(folder) orelse ".";
    const name = std.fs.path.basename(folder);
    const path = try std.fs.path.join(config.arena, &.{
        parent,
        try std.fmt.allocPrint(config.arena, ".{s}.{s}", .{ name, label }),
    });

    try std.Io.Dir.cwd().deleteTree(config.io, path);

    return path;
}

test "a placeholder key never leads out of the media folder" {
    try std.testing.expect(safe_key("2026/11/cake.webp"));
    try std.testing.expect(!safe_key("../secret.key"));
    try std.testing.expect(!safe_key("/etc/passwd"));
    try std.testing.expect(!safe_key(""));
}
