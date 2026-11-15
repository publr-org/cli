//! Making a project: its folder and `publr.zon` (pinned to a release), then the site's own
//! Publr run to set it up: its first admin, the command trusted as its sign-on issuer, its
//! server started. Publr gives a project with no `apps` folder its starter app; an
//! admin-only project gets an empty one.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const server = @import("server.zig");
const sign_on = @import("sign_on.zig");
const helper = @import("helper.zig");
const versions = @import("versions.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

pub const Options = struct {
    /// No front end: an empty `apps` folder, so Publr adds no starter app.
    admin_only: bool = false,
    /// The release to pin; the newest when empty.
    publr: []const u8 = "",
};

/// A new project named `name` in the default folder: made, set up, started.
/// `self_path` is the command itself, to start the helper with.
pub fn new(config: *Config, name: []const u8, self_path: []const u8, options: Options) !Site {
    std.debug.assert(sites_module.valid_name(name));

    const folder = try std.fs.path.join(config.arena, &.{ config.folder, name });

    std.Io.Dir.cwd().access(config.io, folder, .{}) catch |err| switch (err) {
        error.FileNotFound => return make(config, folder, config.folder, self_path, options),
        else => return err,
    };

    std.debug.print("publr: {s} exists: `publr open {s}`, or `publr rm {s}` first\n", .{
        folder,
        name,
        name,
    });
    return error.Exists;
}

/// `folder` made a project, or an existing one set up and listed.
pub fn init(config: *Config, folder: []const u8, self_path: []const u8, options: Options) !Site {
    std.debug.assert(std.fs.path.isAbsolute(folder));

    const name = std.fs.path.basename(folder);
    const entry = try entry_of(config, folder);

    if (sites_module.is_site(config.io, config.arena, folder)) {
        var site = try sites_module.load(config, folder, entry);

        try list_folder(config, folder);

        if ((try versions.pin_of(config, folder)) == null) {
            try versions.set_pin(config, folder, try pick(config, options.publr));
        }

        try set_up(config, &site, try versions.binary_for(config, site), self_path);

        return site;
    }

    if (!sites_module.valid_name(name)) {
        std.debug.print("publr: a site's folder name is lowercase letters, digits and single " ++
            "hyphens, starting with a letter (up to {d}): {s}\n", .{ sites_module.name_len_max, name });
        return error.BadName;
    }

    try list_folder(config, folder);

    return make(config, folder, entry, self_path, options);
}

fn make(
    config: *Config,
    folder: []const u8,
    entry: []const u8,
    self_path: []const u8,
    options: Options,
) !Site {
    const name = std.fs.path.basename(folder);
    const version = try pick(config, options.publr);
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(config.io, folder);
    try cwd.writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ folder, sites_module.project_file }),
        .data = try std.fmt.allocPrint(config.arena, ".{{\n    .name = \"{s}\",\n    .publr = \"{s}\",\n}}\n", .{
            name,
            version,
        }),
    });

    if (options.admin_only) {
        try cwd.createDirPath(config.io, try std.fs.path.join(config.arena, &.{ folder, "apps" }));
    }

    var site = try sites_module.load(config, folder, entry);

    site.local.created_ms = server.now_ms(config.io);
    try set_up(config, &site, try versions.binary_for(config, site), self_path);

    return site;
}

fn pick(config: *const Config, given: []const u8) ![]const u8 {
    if (given.len > 0) {
        return given;
    }

    return versions.newest(config);
}

/// The site's first admin made (once), its server started, the command trusted as its
/// sign-on issuer, the helper running.
pub fn set_up(config: *const Config, site: *Site, publr: []const u8, self_path: []const u8) !void {
    std.debug.assert(publr.len > 0);

    const own = try std.fs.path.join(config.arena, &.{ site.folder, sites_module.own_folder });
    const account_path = try std.fs.path.join(config.arena, &.{ own, "admin.json" });
    const cwd = std.Io.Dir.cwd();

    try server.ensure_port(config, site);
    try cwd.createDirPath(config.io, own);

    // A site with a database already has its people: one made elsewhere, cloned, or set up
    // before.
    const database = try std.fs.path.join(config.arena, &.{ site.folder, "data", "publr.db" });
    const made = exists(config.io, account_path) or exists(config.io, database);

    if (!made) {
        const account = try run(config, publr, site.folder, &.{
            "project",
            "init",
            "--email",
            site.local.email,
            "--display_name",
            "Admin",
        });

        try cwd.writeFile(config.io, .{
            .sub_path = account_path,
            .data = account,
        });
    }

    try server.start(config, site, publr);

    const key = try sign_on.public_key_hex(config);

    _ = try run(config, publr, site.folder, &.{
        "--as-admin",
        "sign_on",
        "configure",
        "--issuer",
        sign_on.issuer,
        "--public_key",
        &key,
        "--audience",
        site.name,
    });
    try helper.ensure(config, self_path);
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

/// The entry of the list `folder` belongs under: a listed folder of sites around it, or the
/// folder itself.
fn entry_of(config: *const Config, folder: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(folder) orelse return folder;

    for (try config.entries()) |entry| {
        if (std.mem.eql(u8, entry, parent) or std.mem.eql(u8, entry, folder)) {
            return entry;
        }
    }

    return folder;
}

/// `folder` listed, unless it is a site in a listed folder of sites already.
fn list_folder(config: *Config, folder: []const u8) !void {
    const entry = try entry_of(config, folder);

    if (!std.mem.eql(u8, entry, folder)) {
        return;
    }

    if (try config.add(folder)) {
        try config.save();
    }
}

/// A Publr command in `folder`; its output, or an error with it printed.
pub fn run(
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    args: []const []const u8,
) ![]const u8 {
    std.debug.assert(args.len > 0);

    var argv: std.ArrayList([]const u8) = .empty;

    try argv.append(config.arena, publr);
    try argv.appendSlice(config.arena, args);

    const result = try std.process.run(config.arena, config.io, .{
        .argv = argv.items,
        .cwd = .{
            .path = folder,
        },
    });

    if (!versions.succeeded(result.term)) {
        std.debug.print("publr: `publr {s}` failed in {s}:\n{s}{s}\n", .{
            args[0],
            folder,
            result.stdout,
            result.stderr,
        });
        return error.PublrFailed;
    }

    return result.stdout;
}
