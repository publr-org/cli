//! The sites in every listed folder. A site is a folder with `publr.zon`; an entry of the
//! list is either a folder of sites (sites one level down) or a single site's own folder.
//! What the command knows of a site on this computer (its port, its server's process) lives
//! in the site's own folder, `.publr/local.json`, so a folder moved between entries keeps it.

const std = @import("std");
const config_module = @import("config.zig");

const Config = config_module.Config;

pub const project_file = "publr.zon";
pub const own_folder = ".publr";
pub const local_name = "local.json";
pub const name_len_max: u32 = 40;
pub const sites_max: u32 = 1024;
/// Clear of the dev server (8080, 8081), the smoke tests (8090, 8091) and review (8801+).
pub const first_port: u16 = 8100;
pub const last_port: u16 = 8799;
const local_bytes_max: u32 = 64 << 10;

/// What this computer keeps of a site.
pub const Local = struct {
    /// Its own port, never changed once given; 0 until it first starts.
    port: u16 = 0,
    /// The admin a signed link signs in as; asked of the site's Publr, empty until it has one.
    email: []const u8 = "",
    created_ms: i64 = 0,
    /// The server's process while the command started one; 0 when stopped.
    pid: i32 = 0,
    /// A Publr this site runs instead of its pinned release (one built from source, say);
    /// empty follows the config's choice, else the pin.
    publr: []const u8 = "",
};

pub const Site = struct {
    /// The folder's name.
    name: []const u8,
    /// The site's folder, absolute.
    folder: []const u8,
    /// The entry of the list it was found under.
    entry: []const u8,
    local: Local,
};

pub const Sites = struct {
    config: *const Config,
    all: []Site,

    /// Every site under every entry, by entry, then by name.
    pub fn find(config: *const Config) !Sites {
        const arena = config.arena;
        var found: std.ArrayList(Site) = .empty;

        for (try config.entries()) |entry| {
            if (is_site(config.io, arena, entry)) {
                try found.append(arena, try load(config, entry, entry));
                continue;
            }

            var dir = std.Io.Dir.cwd().openDir(config.io, entry, .{
                .iterate = true,
            }) catch continue;
            defer dir.close(config.io);

            var inside: std.ArrayList([]const u8) = .empty;
            var iterator = dir.iterate();

            while (try iterator.next(config.io)) |item| {
                if (item.kind != .directory and item.kind != .sym_link) {
                    continue;
                }

                if (item.name[0] == '.') {
                    continue;
                }

                const folder = try std.fs.path.join(arena, &.{ entry, item.name });

                if (is_site(config.io, arena, folder)) {
                    try inside.append(arena, folder);
                }
            }

            std.mem.sort([]const u8, inside.items, {}, less);

            for (inside.items) |folder| {
                if (found.items.len == sites_max) {
                    break;
                }

                try found.append(arena, try load(config, folder, entry));
            }
        }

        return .{
            .config = config,
            .all = found.items,
        };
    }

    /// The site named `name` (its folder's name), or the site a path names.
    pub fn named(sites: *const Sites, name: []const u8) !Site {
        std.debug.assert(name.len > 0);

        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".")) {
            const folder = try absolute(sites.config, name);

            for (sites.all) |site| {
                if (std.mem.eql(u8, site.folder, folder)) {
                    return site;
                }
            }

            return error.NoSuchSite;
        }

        var match: ?Site = null;

        for (sites.all) |site| {
            if (!std.mem.eql(u8, site.name, name)) {
                continue;
            }

            if (match) |first| {
                std.debug.print("publr: two sites are named {s}: {s} and {s}; give its path\n", .{
                    name,
                    first.folder,
                    site.folder,
                });
                return error.AmbiguousName;
            }

            match = site;
        }

        return match orelse error.NoSuchSite;
    }

    /// The first port no site holds and nothing answers on.
    pub fn free_port(sites: *const Sites, listening: *const fn (std.Io, u16) bool) !u16 {
        std.debug.assert(first_port < last_port);

        var port = first_port;

        while (port <= last_port) : (port += 1) {
            var taken = listening(sites.config.io, port);

            for (sites.all) |site| {
                taken = taken or site.local.port == port;
            }

            if (!taken) {
                return port;
            }
        }

        return error.NoFreePort;
    }
};

pub fn is_site(io: std.Io, arena: std.mem.Allocator, folder: []const u8) bool {
    const file = std.fs.path.join(arena, &.{ folder, project_file }) catch return false;

    std.Io.Dir.cwd().access(io, file, .{}) catch return false;

    return true;
}

/// The site `folder` holds, with what this computer keeps of it.
pub fn load(config: *const Config, folder: []const u8, entry: []const u8) !Site {
    std.debug.assert(std.fs.path.isAbsolute(folder));

    const local_path = try std.fs.path.join(config.arena, &.{ folder, own_folder, local_name });
    var local: Local = .{};

    if (std.Io.Dir.cwd().readFileAlloc(config.io, local_path, config.arena, .limited(local_bytes_max))) |text| {
        local = std.json.parseFromSliceLeaky(Local, config.arena, text, .{
            .ignore_unknown_fields = true,
        }) catch .{};
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return .{
        .name = std.fs.path.basename(folder),
        .folder = folder,
        .entry = entry,
        .local = local,
    };
}

pub fn save(config: *const Config, site: Site) !void {
    std.debug.assert(std.fs.path.isAbsolute(site.folder));

    const own = try std.fs.path.join(config.arena, &.{ site.folder, own_folder });
    const text = try std.json.Stringify.valueAlloc(config.arena, site.local, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().createDirPath(config.io, own);
    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ own, local_name }),
        .data = text,
    });
}

/// The site's folder `from` is in (it, or a folder above it), or null outside every site.
pub fn around(io: std.Io, arena: std.mem.Allocator, from: []const u8) !?[]const u8 {
    std.debug.assert(std.fs.path.isAbsolute(from));

    var folder: []const u8 = from;
    var hops: u32 = 0;

    while (hops < 64) : (hops += 1) {
        if (is_site(io, arena, folder)) {
            return folder;
        }

        folder = std.fs.path.dirname(folder) orelse return null;
    }

    return null;
}

pub fn absolute(config: *const Config, given: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(given)) {
        return std.mem.trimEnd(u8, given, "/");
    }

    const here = try std.process.currentPathAlloc(config.io, config.arena);
    const joined = try std.fs.path.resolve(config.arena, &.{ here, given });

    return joined;
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Lowercase letters, digits and single hyphens, starting with a letter: a folder name, and
/// later a hostname label.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max or !std.ascii.isLower(name[0])) {
        return false;
    }

    if (name[name.len - 1] == '-' or std.mem.indexOf(u8, name, "--") != null) {
        return false;
    }

    for (name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') {
            return false;
        }
    }

    return true;
}

test "site names: lowercase, digits, single hyphens, a letter first" {
    try std.testing.expect(valid_name("wagmatik"));
    try std.testing.expect(valid_name("shop-2"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name("2shop"));
    try std.testing.expect(!valid_name("Shop"));
    try std.testing.expect(!valid_name("my site"));
    try std.testing.expect(!valid_name("a--b"));
    try std.testing.expect(!valid_name("shop-"));
    try std.testing.expect(!valid_name(".bin"));
}
