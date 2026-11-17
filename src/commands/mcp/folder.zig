//! The site a folder works on, for `publr mcp`: the one its `.publr/site` names; for a copy
//! of a Cloud project brought down to this computer, that project; else the site it is
//! (`data/publr.db`) through the server running it. Looked for in the folder and the folders
//! above it, as an agent may start in a subfolder of its project.
const std = @import("std");
const core = @import("../../core.zig");

const credentials = core.credentials;
const links = core.links;

pub const database_path = "data/publr.db";
const depth_max: u32 = 32;
const site_bytes_max: u32 = 512;

pub const Target = union(enum) {
    /// A site elsewhere, named by `.publr/site` in `folder`.
    linked: Found,
    /// A copy of the Cloud project at `address`: work goes to the project, never the copy,
    /// whose changes no one sees until they are sent up.
    copy: Found,
    /// This folder is a site and its server runs: the admin's origin.
    serving: Found,
    /// This folder is a site and nothing serves it, or a server too old to say its admin.
    stopped: Found,
    /// Neither, up to the root.
    none,
};

pub const Found = struct {
    folder: []const u8,
    address: []const u8 = "",
};

/// The folder an agent's tool started this in: `given` unless the tool left its variable
/// unexpanded (Cursor with no folder open), else the current one.
pub fn start_folder(io: std.Io, arena: std.mem.Allocator, given: ?[]const u8) ![]const u8 {
    std.debug.assert(depth_max > 0);

    if (given) |folder| {
        const unexpanded = std.mem.indexOf(u8, folder, "${") != null;

        if (folder.len > 0 and !unexpanded) {
            return folder;
        }
    }

    const current = try std.process.currentPathAlloc(io, arena);

    std.debug.assert(current.len > 0);

    return current;
}

pub fn find(io: std.Io, arena: std.mem.Allocator, start: []const u8) !Target {
    std.debug.assert(start.len > 0);

    var folder: []const u8 = start;
    var depth: u32 = 0;

    while (depth < depth_max) : (depth += 1) {
        if (try site_named(io, arena, folder)) |address| {
            return .{
                .linked = .{
                    .folder = folder,
                    .address = address,
                },
            };
        }

        if (try copy_of(io, arena, folder)) |address| {
            return .{
                .copy = .{
                    .folder = folder,
                    .address = address,
                },
            };
        }

        const database = try std.fs.path.join(arena, &.{ folder, database_path });

        if (exists(io, database)) {
            const admin = try serving_admin(io, arena, database);
            const found: Found = .{
                .folder = folder,
                .address = admin,
            };

            return if (admin.len > 0) .{
                .serving = found,
            } else .{
                .stopped = found,
            };
        }

        folder = std.fs.path.dirname(folder) orelse return .none;
    }

    return .none;
}

/// Names `address` as the site `folder` works on. A folder that is a site keeps itself.
pub fn link(io: std.Io, arena: std.mem.Allocator, folder: []const u8, address: []const u8) !void {
    std.debug.assert(folder.len > 0);
    std.debug.assert(address.len > 0 and address.len <= site_bytes_max);

    if (try is_site(io, arena, folder)) {
        return error.FolderIsASite;
    }

    const path = try std.fs.path.join(arena, &.{ folder, credentials.site_path });
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = try std.fmt.allocPrint(arena, "{s}\n", .{address}),
    });
}

/// Whether `folder` is a site: it works on itself. A folder inside one never reaches `link`,
/// as it already works on that site.
pub fn is_site(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !bool {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.join(arena, &.{ folder, database_path });

    return exists(io, database);
}

fn site_named(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !?[]const u8 {
    std.debug.assert(folder.len > 0);

    const path = try std.fs.path.join(arena, &.{ folder, credentials.site_path });
    const limit: std.Io.Limit = .limited(site_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => err,
        };
    };
    const site = std.mem.trim(u8, text, " \n\r\t");

    return if (site.len > 0) site else null;
}

/// The project a copy came from: `.publr/clone.json`'s site, or for a folder deployed and
/// not yet linked, `cloud.json`'s address. Null for a folder that is no copy.
fn copy_of(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !?[]const u8 {
    std.debug.assert(folder.len > 0);

    const Clone = struct {
        site: []const u8 = "",
    };
    const Deployed = struct {
        address: []const u8 = "",
    };

    if (try read_json(Clone, io, arena, folder, links.clone_path)) |clone| {
        if (clone.site.len > 0) {
            return std.mem.trimEnd(u8, clone.site, "/");
        }
    }

    const deployed = try read_json(Deployed, io, arena, folder, links.cloud_name) orelse {
        return null;
    };

    return if (deployed.address.len > 0) std.mem.trimEnd(u8, deployed.address, "/") else null;
}

fn read_json(
    comptime Shape: type,
    io: std.Io,
    arena: std.mem.Allocator,
    folder: []const u8,
    name: []const u8,
) !?Shape {
    std.debug.assert(folder.len > 0);
    std.debug.assert(name.len > 0);

    const path = try std.fs.path.join(arena, &.{ folder, name });
    const limit: std.Io.Limit = .limited(64 << 10);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => err,
        };
    };

    return std.json.parseFromSliceLeaky(Shape, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// The admin's origin a running server left beside its database (`publr.db.serve`:
/// `<port> <key> <build> <url> <admin>`), or "" when none answers.
pub fn serving_admin(io: std.Io, arena: std.mem.Allocator, database: []const u8) ![]const u8 {
    std.debug.assert(database.len > 0);

    const path = try std.fmt.allocPrint(arena, "{s}.serve", .{database});
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return "";
    var words = std.mem.tokenizeAny(u8, text, " \n");
    const port_text = words.next() orelse return "";
    const port = std.fmt.parseInt(u16, port_text, 10) catch return "";

    _ = words.next();
    _ = words.next();
    _ = words.next();

    const admin = words.next() orelse return "";

    if (port == 0 or !core.server.listening(io, port)) {
        return "";
    }

    return admin;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

test "a folder works on the site it names, from itself or a folder below it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const below = try std.fs.path.join(arena, &.{ root, "apps", "www" });

    try std.Io.Dir.cwd().createDirPath(io, below);
    // Folders above the scratch one may be a site (a checkout's own data/publr.db).
    try std.testing.expect(try find(io, arena, below) != .linked);

    try link(io, arena, root, "https://shop--admin.publr.app");

    const linked = try find(io, arena, below);

    try std.testing.expectEqualStrings("https://shop--admin.publr.app", linked.linked.address);
    try std.testing.expectEqualStrings(root, linked.linked.folder);
}

test "a folder that is a site is never linked elsewhere, and says when nothing serves it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);

    try scratch.dir.createDirPath(io, "data");
    try scratch.dir.writeFile(io, .{
        .sub_path = database_path,
        .data = "",
    });

    try std.testing.expectError(error.FolderIsASite, link(io, arena, root, "https://elsewhere"));
    try std.testing.expect(try find(io, arena, root) == .stopped);
    try std.testing.expectEqualStrings(
        "/somewhere",
        try start_folder(io, arena, "/somewhere"),
    );
    try std.testing.expect((try start_folder(io, arena, "${workspaceFolder}")).len > 0);
}

test "a copy of a Cloud project works on the project, not on itself" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);

    try scratch.dir.createDirPath(io, ".publr");
    try scratch.dir.createDirPath(io, "data");
    try scratch.dir.writeFile(io, .{
        .sub_path = database_path,
        .data = "",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = links.cloud_name,
        .data = "{\"address\":\"https://shop.publr.app/\"}",
    });
    const deployed = try find(io, arena, root);

    try std.testing.expectEqualStrings("https://shop.publr.app", deployed.copy.address);

    try scratch.dir.writeFile(io, .{
        .sub_path = links.clone_path,
        .data = "{\"site\":\"https://cafe.publr.app\",\"branch\":\"work-abcdef\"}",
    });

    const below = try std.fs.path.join(arena, &.{ root, "apps" });

    const cloned = try find(io, arena, below);

    try std.testing.expectEqualStrings("https://cafe.publr.app", cloned.copy.address);
}
