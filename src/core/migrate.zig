//! The first run on a computer that used `p`: `~/publr-sites` joins the list where it is,
//! each `site.json` becomes the site's `.publr/local.json` (its port kept), `p`'s sign-on
//! key becomes the command's (every one of those sites trusts it already), and a site with
//! no pin runs the workspace build, seeded from `p`'s own so nothing is built again.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const sign_on = @import("sign_on.zig");
const versions = @import("versions.zig");

const Config = config_module.Config;

pub const p_folder = "publr-sites";
const record_bytes_max: u32 = 64 << 10;

/// What `p` kept of a site, beside it.
const Record = struct {
    port: u16 = 0,
    email: []const u8 = sites_module.email,
    created_ms: i64 = 0,
    pid: i32 = 0,
    binary: []const u8 = "",
};

/// Done once, on the command's first run; quiet when there is no `~/publr-sites`.
pub fn from_p(config: *Config) !void {
    std.debug.assert(config.fresh);

    const home = config.environ.get("HOME") orelse return;
    const root = try std.fs.path.join(config.arena, &.{ home, p_folder });
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(config.io, root, .{
        .iterate = true,
    }) catch {
        try config.save();
        return;
    };
    defer dir.close(config.io);

    _ = try config.add(root);
    try config.save();
    try take_key(config, root);
    try take_build(config, root);

    var moved: u32 = 0;
    var iterator = dir.iterate();

    while (try iterator.next(config.io)) |item| {
        if (item.kind != .directory or item.name[0] == '.') {
            continue;
        }

        const folder = try std.fs.path.join(config.arena, &.{ root, item.name });

        if (try take_site(config, root, folder)) {
            moved += 1;
        }
    }

    std.debug.print("publr: took over {d} sites from {s} (left where they are)\n", .{ moved, root });
}

fn take_key(config: *const Config, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const mine = try config.path(&.{sign_on.key_name});

    cwd.access(config.io, mine, .{}) catch {
        const theirs = try std.fs.path.join(config.arena, &.{ root, ".sign-on.key" });
        const hex = cwd.readFileAlloc(config.io, theirs, config.arena, .limited(256)) catch return;

        try cwd.writeFile(config.io, .{
            .sub_path = mine,
            .data = hex,
            .flags = .{
                .permissions = .fromMode(0o600),
            },
        });
    };
}

/// `p`'s workspace build copied in as the command's, once.
fn take_build(config: *const Config, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const mine = try versions.workspace_binary(config);

    cwd.access(config.io, mine, .{}) catch {
        const theirs = try std.fs.path.join(config.arena, &.{ root, ".bin", "bin", "publr" });

        cwd.access(config.io, theirs, .{}) catch return;
        try cwd.createDirPath(config.io, std.fs.path.dirname(mine).?);
        try cwd.copyFile(theirs, cwd, mine, config.io, .{});
    };
}

fn take_site(config: *const Config, root: []const u8, folder: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const record_path = try std.fs.path.join(config.arena, &.{ folder, "site.json" });
    const text = cwd.readFileAlloc(config.io, record_path, config.arena, .limited(record_bytes_max)) catch return false;
    const record = std.json.parseFromSliceLeaky(Record, config.arena, text, .{
        .ignore_unknown_fields = true,
    }) catch return false;

    if (!sites_module.is_site(config.io, config.arena, folder)) {
        return false;
    }

    var site = try sites_module.load(config, folder, root);

    if (site.local.port == 0) {
        site.local = .{
            .port = record.port,
            .email = record.email,
            .created_ms = record.created_ms,
            .pid = record.pid,
        };
        try sites_module.save(config, site);
    }

    const pinned = (try versions.pin_of(config, folder)) != null;
    const own = (try versions.own_binary(config, folder)) != null;

    if (!pinned and !own) {
        const link = try std.fs.path.join(config.arena, &.{ folder, versions.binary_name });
        const target = if (record.binary.len > 0) record.binary else try versions.workspace_binary(config);

        try cwd.symLink(config.io, target, link, .{});
    }

    // `p`'s own copy of the first admin's account goes where the command keeps it.
    const account = try std.fs.path.join(config.arena, &.{ folder, "admin.json" });
    const kept = try std.fs.path.join(config.arena, &.{ folder, sites_module.own_folder, "admin.json" });

    cwd.rename(account, cwd, kept, config.io) catch {};

    return true;
}
