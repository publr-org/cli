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
    /// The site's first admin, ahead of the config's (`config admin`); empty leaves it to the
    /// config, else to the setup page.
    admin: []const u8 = "",
    /// That admin's name; empty names them by their email.
    admin_name: []const u8 = "",
    /// The site's language (`pl`), ahead of the config's (`config language`); empty leaves it
    /// to the config, else English.
    language: []const u8 = "",
};

/// A language's code as Publr's packs name it: two to three lowercase letters (`pl`), each
/// pack the plugin `language_<code>`.
pub fn valid_language(code: []const u8) bool {
    if (code.len < 2 or code.len > 3) {
        return false;
    }

    for (code) |letter| {
        if (letter < 'a' or letter > 'z') {
            return false;
        }
    }

    return true;
}

/// How long a language pack may take to come from the plugin server.
const pack_wait_s_max: u32 = 120;

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
    const publr = try versions.binary_for(config, site);

    site.local.created_ms = server.now_ms(config.io);
    const given = if (options.language.len > 0) options.language else config.language;
    // English is built in: nothing to install or choose.
    const language = if (std.mem.eql(u8, given, "en")) "" else given;

    if (language.len > 0) {
        try speak(config, &site, publr, language);
    }

    try make_admin(config, &site, publr, language, options);
    try set_up(config, &site, publr, self_path);

    return site;
}

/// The site's first admin, chosen for it or by the config, made before it first starts, with a
/// password of its own nobody types (the command signs them in); none leaves it to the setup page.
fn make_admin(
    config: *const Config,
    site: *Site,
    publr: []const u8,
    language: []const u8,
    options: Options,
) !void {
    std.debug.assert(publr.len > 0);
    std.debug.assert(site.folder.len > 0);

    const email = if (options.admin.len > 0) options.admin else config.admin;

    if (email.len == 0) {
        return;
    }

    const given_name = if (options.admin.len > 0) options.admin_name else config.admin_name;
    const name = if (given_name.len > 0) given_name else email[0 .. std.mem.indexOfScalar(u8, email, '@') orelse email.len];

    const init_args: []const []const u8 = &.{ "project", "init", "--email", email, "--display_name", name, "--language", language };

    _ = try run(config, publr, site.folder, if (language.len > 0) init_args else init_args[0..6]);
    site.local.email = email;
    try sites_module.save(config, site.*);
}

/// The site made to speak `language` before anyone sets it up: its pack installed from the
/// plugin server (the server started for that), then chosen as the site's language, so the
/// setup page, if there is one, asks for the first account in it.
fn speak(config: *const Config, site: *Site, publr: []const u8, language: []const u8) !void {
    std.debug.assert(valid_language(language));
    std.debug.assert(site.folder.len > 0);

    const pack = try std.fmt.allocPrint(config.arena, "language_{s}", .{language});

    try server.ensure_port(config, site);
    try server.start(config, site, publr);

    const asked_text = try run(config, publr, site.folder, &.{ "--as-admin", "plugin", "install", "--name", pack });
    const Asked = struct {
        asked: []const u8,
    };
    const asked = try std.json.parseFromSliceLeaky(Asked, config.arena, asked_text, .{
        .ignore_unknown_fields = true,
    });
    var waited: u32 = 0;

    while (waited < pack_wait_s_max) : (waited += 1) {
        const answer_text = try run(config, publr, site.folder, &.{ "--as-admin", "job", "answer", "--id", asked.asked });
        const Answer = struct {
            state: []const u8,
            problem: []const u8 = "",
        };
        const answer = try std.json.parseFromSliceLeaky(Answer, config.arena, answer_text, .{
            .ignore_unknown_fields = true,
        });

        if (std.mem.eql(u8, answer.state, "done")) {
            break;
        }

        if (std.mem.eql(u8, answer.state, "failed")) {
            std.debug.print("publr: the {s} language pack could not be installed: {s}\n", .{
                language,
                answer.problem,
            });
            return error.LanguageNotInstalled;
        }

        try std.Io.sleep(config.io, .fromSeconds(1), .awake);
    } else {
        std.debug.print("publr: the {s} language pack took too long to install\n", .{language});
        return error.LanguageNotInstalled;
    }

    _ = try run(config, publr, site.folder, &.{ "--as-admin", "project", "set_admin_language", "--language", language });
}

fn pick(config: *const Config, given: []const u8) ![]const u8 {
    if (given.len > 0) {
        return given;
    }

    // The release Cloud runs (the newest when Cloud cannot be asked): a new site never gets
    // ahead of Cloud, where it may go.
    return @import("compat.zig").cloud_release(config);
}

/// The site's server started, the command trusted as its sign-on issuer, the helper running.
pub fn set_up(config: *const Config, site: *Site, publr: []const u8, self_path: []const u8) !void {
    std.debug.assert(publr.len > 0);

    try server.ensure_port(config, site);
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
