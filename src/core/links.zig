//! A folder's links to the site it works on. `cloud.json`: what a deploy left, the Cloud
//! project the folder became. `.publr/clone.json`: where the folder came from, the branch it
//! pushes to, how far it has pulled and what it last pushed; written by `clone`, or made the
//! first time from `cloud.json`, since a deployed folder is a clone of its project too.

const std = @import("std");
const config_module = @import("config.zig");
const site_data = @import("site_data.zig");

const Config = config_module.Config;

pub const cloud_name = "cloud.json";
pub const clone_path = ".publr/clone.json";
const link_bytes_max: u32 = 64 << 10;
const branch_suffix_len: u32 = 6;

/// What the folder keeps about the project it was deployed as.
pub const Cloud = struct {
    dashboard: []const u8,
    space: []const u8,
    /// The project's record on the dashboard, and the id the host knows it by.
    project: []const u8,
    project_id: []const u8,
    slug: []const u8,
    address: []const u8,
    admin: []const u8,
    deployed_at_ms: i64,
};

pub const Clone = struct {
    site: []const u8,
    branch: []const u8,
    /// The site's newest activity entry when the folder last came down: the site is ahead
    /// when its own is newer.
    pulled: i64 = 0,
    /// The folder's own work as it was pushed (`changes.zig`'s mark), empty when nothing was.
    pushed: []const u8 = "",
    /// The folder's newest write to the site when it last matched it: 0 for a folder that
    /// came down (its log came empty), a deployed folder's newest by the time it went up.
    since: i64 = 0,
};

pub fn read_cloud(config: *const Config, folder: []const u8) !?Cloud {
    const path = try std.fs.path.join(config.arena, &.{ folder, cloud_name });
    const limit: std.Io.Limit = .limited(link_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return try std.json.parseFromSliceLeaky(Cloud, config.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn write_cloud(config: *const Config, folder: []const u8, link: Cloud) !void {
    std.debug.assert(link.address.len > 0);

    const text = try std.json.Stringify.valueAlloc(config.arena, link, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ folder, cloud_name }),
        .data = text,
    });
}

/// The folder's clone link; made from its `cloud.json` when it has only that (`publr`, the
/// folder's Publr, says how far its writes went by the deploy); null for neither.
pub fn read_clone(config: *const Config, folder: []const u8, publr: []const u8) !?Clone {
    const path = try std.fs.path.join(config.arena, &.{ folder, clone_path });
    const limit: std.Io.Limit = .limited(link_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, limit) catch |err| switch (err) {
        error.FileNotFound => return from_deploy(config, folder, publr),
        else => return err,
    };

    return try std.json.parseFromSliceLeaky(Clone, config.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn write_clone(config: *const Config, folder: []const u8, link: Clone) !void {
    std.debug.assert(link.site.len > 0);
    std.debug.assert(link.branch.len > 0);

    const path = try std.fs.path.join(config.arena, &.{ folder, clone_path });
    const text = try std.json.Stringify.valueAlloc(config.arena, link, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().createDirPath(config.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = path,
        .data = text,
    });
}

/// Whether `folder` is linked to a site elsewhere: a clone or a deployed folder.
pub fn linked(config: *const Config, folder: []const u8) bool {
    for ([_][]const u8{ clone_path, cloud_name }) |name| {
        const path = std.fs.path.join(config.arena, &.{ folder, name }) catch return false;

        if (std.Io.Dir.cwd().access(config.io, path, .{})) |_| {
            return true;
        } else |_| {}
    }

    return false;
}

/// A branch name of this folder's own: `work-` and six letters.
pub fn new_branch(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(branch_suffix_len > 0);

    var random: [branch_suffix_len]u8 = undefined;

    io.random(&random);

    for (&random) |*byte| {
        byte.* = "abcdefghijkmnpqrstuvwxyz23456789"[byte.* & 31];
    }

    return std.fmt.allocPrint(arena, "work-{s}", .{&random});
}

/// A deployed folder's link: its project's address, a branch of its own, nothing pulled yet.
fn from_deploy(config: *const Config, folder: []const u8, publr: []const u8) !?Clone {
    const deployed = try read_cloud(config, folder) orelse return null;
    const database = try std.fs.path.join(config.arena, &.{ folder, site_data.database });
    const has_database = blk: {
        std.Io.Dir.cwd().access(config.io, database, .{}) catch break :blk false;
        break :blk true;
    };
    const since = if (has_database)
        (try site_data.state(config, publr, folder, deployed.deployed_at_ms)).latest_write
    else
        0;
    const link: Clone = .{
        .site = std.mem.trimEnd(u8, deployed.address, "/"),
        .branch = try new_branch(config.io, config.arena),
        .since = since,
    };

    try write_clone(config, folder, link);

    return link;
}

test "a branch of the folder's own" {
    const made = try new_branch(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(made);

    try std.testing.expect(std.mem.startsWith(u8, made, "work-"));
    try std.testing.expectEqual(@as(usize, 11), made.len);
}
