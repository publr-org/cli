//! A site on this computer renamed: its folder moved to the new name beside where it is, its
//! own entry on the list following it. A running server is stopped first and started again
//! after, so the site is not left stopped. Its own data (`.publr/local.json`: its port, its
//! admin) is in the folder and moves with it. A site linked to Cloud is named on Cloud, not
//! here: its folder keeps its name.
const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const server = @import("server.zig");
const versions = @import("versions.zig");
const links = @import("links.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

pub const Error = error{
    /// Not a site's name: lowercase letters, digits and single hyphens, a letter first.
    InvalidName,
    /// A site of that name is listed already, or the folder is there.
    NameTaken,
    /// Linked to a site elsewhere (Cloud, or a clone's source): named there, not here.
    Linked,
};

/// `site` renamed `new_name`, as it is now. Its name unchanged is no work.
pub fn rename(config: *Config, site: Site, new_name: []const u8) !Site {
    std.debug.assert(site.name.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(site.folder));

    if (!sites_module.valid_name(new_name)) {
        return Error.InvalidName;
    }

    if (std.mem.eql(u8, new_name, site.name)) {
        return site;
    }

    if (links.linked(config, site.folder)) {
        return Error.Linked;
    }

    const listed = try sites_module.Sites.find(config);

    for (listed.all) |other| {
        if (std.mem.eql(u8, other.name, new_name)) {
            return Error.NameTaken;
        }
    }

    const parent = std.fs.path.dirname(site.folder) orelse return Error.InvalidName;
    const folder = try std.fs.path.join(config.arena, &.{ parent, new_name });
    const cwd = std.Io.Dir.cwd();

    if (cwd.access(config.io, folder, .{})) |_| {
        return Error.NameTaken;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var moving = site;
    const was_running = server.running(config.io, moving);

    if (was_running) {
        try server.stop(config, &moving);
    }

    try cwd.rename(site.folder, cwd, folder, config.io);

    // A single site's own entry names its folder: it follows the folder.
    const own_entry = std.mem.eql(u8, site.entry, site.folder);

    if (own_entry) {
        _ = try config.remove(site.folder);
        _ = try config.add(folder);
        try config.save();
    }

    var renamed = try sites_module.load(config, folder, if (own_entry) folder else site.entry);

    if (was_running) {
        try server.start(config, &renamed, try versions.binary_for(config, renamed));
    }

    std.debug.assert(std.mem.eql(u8, renamed.name, new_name));

    return renamed;
}

test "a stopped site's folder takes the new name; a bad or taken name changes nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const folder = try std.fs.path.join(arena, &.{ root, "sites" });
    var environ: std.process.Environ.Map = .init(arena);

    try environ.put("PUBLR_CONFIG", try std.fs.path.join(arena, &.{ root, "config" }));
    try environ.put("HOME", root);

    var config: Config = .{
        .io = io,
        .arena = arena,
        .environ = &environ,
        .root = try std.fs.path.join(arena, &.{ root, "config" }),
        .folder = folder,
        .folders = &.{},
    };

    try scratch.dir.createDirPath(io, "config");

    for ([_][]const u8{ "sites/shop", "sites/blog" }) |path| {
        try scratch.dir.createDirPath(io, path);
        try scratch.dir.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(arena, "{s}/publr.zon", .{path}),
            .data = ".{}\n",
        });
    }

    const listed = try sites_module.Sites.find(&config);
    const shop = try listed.named("shop");

    try std.testing.expectError(Error.InvalidName, rename(&config, shop, "New Shop"));
    try std.testing.expectError(Error.NameTaken, rename(&config, shop, "blog"));

    try scratch.dir.writeFile(io, .{
        .sub_path = "sites/blog/cloud.json",
        .data = "{}",
    });

    const blog = try listed.named("blog");

    try std.testing.expectError(Error.Linked, rename(&config, blog, "journal"));

    const renamed = try rename(&config, shop, "store");

    try std.testing.expectEqualStrings("store", renamed.name);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ folder, "store" }), renamed.folder);
    try scratch.dir.access(io, "sites/store/publr.zon", .{});
    try std.testing.expectError(error.FileNotFound, scratch.dir.access(io, "sites/shop", .{}));
}
