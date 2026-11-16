//! `publr`: one command for Publr sites on this computer and on Cloud. It answers its own
//! commands anywhere; inside a site's folder every other command goes to the Publr that site
//! runs, with the words unchanged.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");

const login_module = core.login;
const mcp_command = @import("commands/mcp.zig");
const setup_command = @import("commands/setup.zig");
const skill_command = @import("commands/skill.zig");
const plugin_build_command = @import("commands/plugin_build.zig");
const pack_command = @import("commands/pack.zig");
const clone_command = @import("commands/clone.zig");
const pull_command = @import("commands/pull.zig");
const push_command = @import("commands/push.zig");
const deploy_command = @import("commands/deploy.zig");
const seed_command = @import("commands/seed.zig");
const toolchain = @import("commands/toolchain.zig");
const clash = @import("clash.zig");

const Config = core.Config;
const Site = core.Site;
const Sites = core.Sites;
const server = core.server;
const versions = core.versions;

pub const version = "0.1.1";

const usage =
    \\publr: Publr sites on this computer and on Cloud
    \\
    \\  publr new <name>           a new site in the default folder, started, opened
    \\                             --admin-only: no front end, / opens the admin
    \\                             --publr <version>: that release, not the newest
    \\                             --admin <email> [--admin-name <name>]: its first admin
    \\  publr init [<path>]        that folder made a site, or set up and listed (.: here)
    \\  publr ls [--json]          every site in every listed folder
    \\  publr start <name>...      start sites in the background
    \\  publr stop <name>...       stop sites (--all: every one)
    \\  publr restart <name>...    stop, then start
    \\  publr open [<name>] [path] the admin in your browser, signed in (or any page: / )
    \\                             --print: the signed-in link instead (good for a minute, once)
    \\  publr logs [<name>]        the end of the site's server log
    \\  publr rm <name> [--yes]    stop it and move it to its folder's .trash
    \\  publr studio [<name>]      Studio opened
    \\  publr config               where sites go and which folders hold them
    \\    config folder <path>       the default folder
    \\    config folders add|remove <path>
    \\    config publr <path>|<release> [<name>...]
    \\                               a Publr those sites (or every site) run instead of
    \\                               their pinned releases (one built from source, say)
    \\    config publr --unset [<name>...]
    \\                               back to their pinned releases
    \\    config admin <email> [--name <name>]
    \\                               the default account email: every new site's first admin
    \\                               (not set: the Cloud account, else the setup page); --unset
    \\  publr versions             the Publr releases kept, and which site runs which
    \\    versions use <version> <name>...|--all
    \\
    \\  publr login <address>      this computer signed in to a Publr site, approved there
    \\                             --name, --scope read|write|production|publish,
    \\                             --no-browser, --claim <code>, --sign-on <token>
    \\  publr logout [<address>]   signed out there, and forgotten here
    \\  publr whoami [<address>]   who this computer is there, and what it may do
    \\  publr cloud login          this computer signed in to Publr Cloud (--cloud <dashboard>)
    \\  publr deploy               this site made a Publr Cloud project (also `cloud deploy`)
    \\                             --space, --slug <address>, --name, --cloud <dashboard>
    \\  publr clone <address>      a site brought down into the default folder, on its release,
    \\                             started and opened ([<folder>], --media all|none, --size,
    \\                             --no-open, --no-serve)
    \\  publr push                 this clone's work sent up as a branch for review
    \\  publr pull [--check]       the site brought down again (--check: where it is, as JSON)
    \\  publr pack [<file>]        the site here as one file; `publr unpack <file>` back
    \\  publr mcp [--folder <path>]  Publr for an agent's tool: the site its folder works on
    \\  publr setup cursor|claude|codex  Publr added to that tool, for every project
    \\  publr skill [install]      the build-on-publr skill, printed or written for agents
    \\                             --agent claude|codex|cursor|pi, --dir <path>
    \\  publr plugin build --name <n>  a sandboxed plugin built, checked and installed in the
    \\                             site here or at --site (--dir, --with <x.wasm>, --out <file>)
    \\  publr zig <args>           the compiler it carries (wasm32 only)
    \\
    \\Inside a site's folder every other command goes to the Publr it runs:
    \\`publr content list`, `publr serve`, `publr agents`.
    \\To a site elsewhere: `publr --site <address> [--env <copy>] <command>`, or PUBLR_SITE,
    \\or from a folder whose .publr/site names it.
    \\`publr --publr <path>|<release> <command>`: every site runs that Publr for this call.
    \\
;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        switch (err) {
            error.Usage => std.debug.print("{s}", .{usage}),
            error.NoSuchSite => std.debug.print("publr: no such site; `publr ls` lists them\n", .{}),
            error.NotASite => {},
            else => std.debug.print("publr: {t}\n", .{err}),
        }

        return 1;
    };
}

pub const Command = enum {
    new,
    init,
    ls,
    start,
    stop,
    restart,
    open,
    logs,
    rm,
    studio,
    config,
    versions,
    helper,
    login,
    logout,
    whoami,
    cloud,
    mcp,
    setup,
    skill,
    zig,
    pack,
    unpack,
    clone,
    pull,
    push,
    deploy,
    help,
    @"--help",
    @"-h",
    @"--version",
};

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var config = try Config.load(init.io, arena, init.environ_map);

    var words: []const []const u8 = args[1..];
    const globals = try take_globals(&words);

    if (words.len == 0) {
        return error.Usage;
    }

    if (globals.publr) |given| {
        if (given.len == 0) {
            return error.Usage;
        }

        config.call_publr = try versions.resolve(&config, given);
    }

    // `plugin build` is the command's; `plugin` itself, and every other word of it, Publr's.
    if (plugin_build_command.handles(words)) {
        const address = try elsewhere(init, &config, globals);

        return plugin_build_command.run(init, &config, address, globals.env, words[2..]);
    }

    const chosen = own(words) orelse {
        if (try elsewhere(init, &config, globals)) |address| {
            // A seed's file is on this computer: read here, sent in batches.
            if (seed_command.seed_at(words) != null) {
                return seed_with_output(init, address, globals.env, words);
            }

            return forward(init, address, globals.env, words);
        }

        return hand_on(init, &config, globals.env, words);
    };
    const rest: []const []const u8 = words[1..];
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const self_path = try std.process.executablePathAlloc(init.io, arena);

    switch (chosen) {
        .new => try new(init, &config, out, rest, self_path),
        .init => try init_folder(&config, out, rest, self_path),
        .ls => try list(&config, out, rest),
        .start => for (try many(&config, rest)) |site| try start(&config, out, site, self_path),
        .stop => for (try many(&config, rest)) |site| try stop(&config, out, site),
        .restart => for (try many(&config, rest)) |site| {
            try stop(&config, out, site);
            try start(&config, out, site, self_path);
        },
        .open => try open(init, &config, out, rest, self_path),
        .logs => try logs(&config, out, rest),
        .rm => try remove(init, &config, out, rest),
        .studio => try studio(init, &config, rest),
        .config => try configure(&config, out, rest),
        .versions => try versions_command(&config, out, rest),
        .helper => try core.helper.serve(init),
        .login, .logout, .whoami => {
            // `--site` names the address when the words do not.
            const account = if (globals.site != null and rest.len == 0)
                &[_][]const u8{ words[0], globals.site.? }
            else
                words;

            return login_module.run(init, out, account);
        },
        .cloud => {
            if (std.mem.eql(u8, rest[0], "deploy")) {
                return deploy_command.run(init, &config, out, rest[1..]);
            }

            return cloud(init, out, rest);
        },
        .mcp => return mcp_command.run(init, rest),
        .setup => return setup_command.run(init, out, rest),
        .skill => return skill_command.run(init, out, rest),
        .pack => return pack_command.pack(&config, out, rest),
        .unpack => return pack_command.unpack(&config, out, rest),
        .clone => return clone_command.run(init, &config, out, rest, self_path),
        .pull => return pull_command.run(init, &config, out, rest),
        .push => return push_command.run(init, &config, out, rest),
        .deploy => return deploy_command.run(init, &config, out, rest),
        .zig => return toolchain.run(init, rest),
        .help, .@"--help", .@"-h" => try out.writeAll(usage),
        .@"--version" => try out.print("publr {s}\n", .{version}),
    }

    return 0;
}

/// The command's own, from the first words; null for every other command, which goes to a
/// site's Publr. Of `cloud`, `cloud login` and `cloud deploy` are the command's.
pub fn own(words: []const []const u8) ?Command {
    std.debug.assert(words.len > 0);

    const chosen = std.meta.stringToEnum(Command, words[0]) orelse return null;

    const cloud_own = words.len >= 2 and
        (std.mem.eql(u8, words[1], "login") or std.mem.eql(u8, words[1], "deploy"));

    if (chosen == .cloud and !cloud_own) {
        return null;
    }

    return chosen;
}

const Globals = struct {
    /// `--site <address>`: the Publr elsewhere a command goes to.
    site: ?[]const u8 = null,
    /// `--env <name>`: one of that site's copies, or of the site here.
    env: ?[]const u8 = null,
    /// `--publr <release|path>`: the Publr every site runs for this call.
    publr: ?[]const u8 = null,
};

/// The leading `--site <address>`, `--env <name>` and `--publr <release|path>`, in any order,
/// taken off the words.
fn take_globals(words: *[]const []const u8) !Globals {
    var globals: Globals = .{};

    while (words.len >= 2) {
        const flag = words.*[0];

        if (std.mem.eql(u8, flag, "--site") and globals.site == null) {
            globals.site = words.*[1];
        } else if (std.mem.eql(u8, flag, "--env") and globals.env == null) {
            globals.env = words.*[1];
        } else if (std.mem.eql(u8, flag, "--publr") and globals.publr == null) {
            globals.publr = words.*[1];
        } else {
            break;
        }

        words.* = words.*[2..];
    }

    if (globals.site) |site| {
        if (site.len == 0) {
            return error.Usage;
        }
    }

    return globals;
}

/// The Publr elsewhere a command goes to: `--site`, else `PUBLR_SITE`, else the one this
/// folder's `.publr/site` names, unless this folder is a site of its own. Null to run it here.
fn elsewhere(init: std.process.Init, config: *const Config, globals: Globals) !?[]const u8 {
    if (globals.site) |site| {
        return site;
    }

    if (init.environ_map.get("PUBLR_SITE")) |variable| {
        if (variable.len > 0) {
            return variable;
        }
    }

    const here = try std.process.currentPathAlloc(init.io, config.arena);

    if (try core.sites.around(init.io, config.arena, here) != null) {
        return null;
    }

    return core.credentials.folder_site(init);
}

fn seed_with_output(
    init: std.process.Init,
    address: []const u8,
    env: ?[]const u8,
    words: []const []const u8,
) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    return seed_command.run(init, address, env, words, out);
}

fn forward(
    init: std.process.Init,
    address: []const u8,
    env: ?[]const u8,
    words: []const []const u8,
) !u8 {
    std.debug.assert(words.len > 0);

    var out_buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    return core.remote.forward(init, address, words, env, out);
}

/// `cloud login [--cloud <dashboard>]`.
fn cloud(init: std.process.Init, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    std.debug.assert(rest.len > 0);

    const words = rest[1..];
    var dashboard = init.environ_map.get(core.cloud_login.dashboard_variable) orelse
        core.cloud_login.dashboard_default;

    if (words.len == 2 and std.mem.eql(u8, words[0], "--cloud")) {
        dashboard = words[1];
    } else if (words.len != 0) {
        return error.Usage;
    }

    return core.cloud_login.run(init, out, std.mem.trimEnd(u8, dashboard, "/"));
}

/// Every other command: run by the Publr of the site around this folder, in its folder,
/// with the words unchanged (`--env` given back to it, for the copies it keeps). The process
/// becomes that Publr, so its input, output, signals and exit code are the person's.
/// Outside every site only `agents` is handed on, to the newest release kept: its guide.
fn hand_on(
    init: std.process.Init,
    config: *const Config,
    env: ?[]const u8,
    words: []const []const u8,
) !u8 {
    std.debug.assert(words.len > 0);

    const here = try std.process.currentPathAlloc(init.io, config.arena);
    const around = try core.sites.around(init.io, config.arena, here);
    var argv: std.ArrayList([]const u8) = .empty;

    const publr = if (around) |folder| blk: {
        const site = try core.sites.load(config, folder, folder);

        break :blk try versions.binary_for(config, site);
    } else if (std.mem.eql(u8, words[0], "agents")) blk: {
        const kept = try versions.list(config);
        const chosen = if (kept.len > 0) kept[kept.len - 1] else try versions.newest(config);

        break :blk try versions.kept(config, chosen);
    } else {
        std.debug.print("publr: `{s}` is a site's command: run it in a site's folder " ++
            "(`publr ls` lists them), or see `publr help`\n", .{words[0]});
        return error.NotASite;
    };

    try argv.append(config.arena, publr);

    if (env) |name| {
        try argv.appendSlice(config.arena, &.{ "--env", name });
    }

    try argv.appendSlice(config.arena, words);

    // Publr reads its project from the folder it runs in.
    if (around) |folder| {
        if (!std.mem.eql(u8, here, folder)) {
            var dir = try std.Io.Dir.cwd().openDir(init.io, folder, .{});
            defer dir.close(init.io);

            try std.process.setCurrentDir(init.io, dir);
        }
    }

    const err = std.process.replace(init.io, .{
        .argv = argv.items,
    });

    std.debug.print("publr: could not run {s}: {t}\n", .{ publr, err });
    return err;
}

/// The sites named, the site around this folder when none is, or every site for `--all`.
fn many(config: *const Config, rest: []const []const u8) ![]Site {
    const sites = try Sites.find(config);

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "--all")) {
        return sites.all;
    }

    var chosen: std.ArrayList(Site) = .empty;

    if (rest.len == 0) {
        try chosen.append(config.arena, try here_site(config, &sites));
        return chosen.items;
    }

    for (rest) |name| {
        try chosen.append(config.arena, try sites.named(name));
    }

    return chosen.items;
}

/// The site around this folder, as the list knows it.
fn here_site(config: *const Config, sites: *const Sites) !Site {
    const here = try std.process.currentPathAlloc(config.io, config.arena);
    const folder = (try core.sites.around(config.io, config.arena, here)) orelse return error.Usage;

    for (sites.all) |site| {
        if (std.mem.eql(u8, site.folder, folder)) {
            return site;
        }
    }

    std.debug.print("publr: {s} is not in a listed folder: `publr init .` lists it\n", .{folder});
    return error.NoSuchSite;
}

fn one(config: *const Config, name: ?[]const u8) !Site {
    const sites = try Sites.find(config);

    if (name) |given| {
        return sites.named(given);
    }

    return here_site(config, &sites);
}

fn new(
    init: std.process.Init,
    config: *Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
    self_path: []const u8,
) !void {
    var name: ?[]const u8 = null;
    var options: core.project.Options = .{};
    var index: usize = 0;

    while (index < rest.len) : (index += 1) {
        const word = rest[index];

        if (std.mem.eql(u8, word, "--admin-only")) {
            options.admin_only = true;
        } else if (std.mem.eql(u8, word, "--publr") and index + 1 < rest.len) {
            index += 1;
            options.publr = rest[index];
        } else if (std.mem.eql(u8, word, "--admin") and index + 1 < rest.len) {
            index += 1;
            options.admin = rest[index];
        } else if (std.mem.eql(u8, word, "--admin-name") and index + 1 < rest.len) {
            index += 1;
            options.admin_name = rest[index];
        } else if (name == null and word.len > 0 and word[0] != '-') {
            name = word;
        } else {
            return error.Usage;
        }
    }

    const chosen = name orelse return error.Usage;

    if (!core.sites.valid_name(chosen)) {
        std.debug.print("publr: a name is lowercase letters, digits and single hyphens, " ++
            "starting with a letter (up to {d})\n", .{core.sites.name_len_max});
        return error.BadName;
    }

    // No default account email set: the Cloud account this computer signed in as.
    if (options.admin.len == 0 and config.admin.len == 0) {
        if (try core.credentials.find(init, core.cloud_login.dashboard_default)) |account| {
            options.admin = account.email;
        }
    }

    var site = try core.project.new(config, chosen, self_path, options);

    try out.print("created {s} in {s}\n", .{ site.name, site.folder });
    try print_links(config, out, site);
    try out.flush();
    try browse(init, try core.sign_on.entry(config, &site, try versions.binary_for(config, site), "/admin"));
}

fn init_folder(
    config: *Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
    self_path: []const u8,
) !void {
    var given: []const u8 = ".";
    var options: core.project.Options = .{};
    var index: usize = 0;

    while (index < rest.len) : (index += 1) {
        const word = rest[index];

        if (std.mem.eql(u8, word, "--admin-only")) {
            options.admin_only = true;
        } else if (std.mem.eql(u8, word, "--publr") and index + 1 < rest.len) {
            index += 1;
            options.publr = rest[index];
        } else if (std.mem.eql(u8, word, "--admin") and index + 1 < rest.len) {
            index += 1;
            options.admin = rest[index];
        } else if (std.mem.eql(u8, word, "--admin-name") and index + 1 < rest.len) {
            index += 1;
            options.admin_name = rest[index];
        } else if (word.len > 0 and word[0] != '-') {
            given = word;
        } else {
            return error.Usage;
        }
    }

    const folder = try core.sites.absolute(config, given);
    const site = try core.project.init(config, folder, self_path, options);

    try out.print("{s} is a site, listed: {s}\n", .{ site.name, site.folder });
    try print_links(config, out, site);
    try out.print("  publr open {s}   opens the admin, signed in\n", .{site.name});
}

fn list(config: *const Config, out: *std.Io.Writer, rest: []const []const u8) !void {
    const json = rest.len == 1 and std.mem.eql(u8, rest[0], "--json");

    if (rest.len > 0 and !json) {
        return error.Usage;
    }

    const sites = try Sites.find(config);

    if (json) {
        return list_json(config, out, sites);
    }

    if (sites.all.len == 0) {
        try out.print("no sites yet: publr new <name>\n", .{});
        return;
    }

    var entry: []const u8 = "";

    for (sites.all) |site| {
        if (!std.mem.eql(u8, entry, site.entry)) {
            entry = site.entry;
            try out.print("\n{s}\n", .{entry});
            try out.print("  {s:<24} {s:<8} {s:<10} {s:<24} {s}\n", .{ "NAME", "STATE", "PUBLR", "SITE", "ADMIN" });
        }

        const state = if (server.running(config.io, site)) "running" else "stopped";
        const publr = versions.running_label(config, site) catch "unreadable";

        if (site.local.port == 0) {
            try out.print("  {s:<24} {s:<8} {s:<10} {s:<24} {s}\n", .{ site.name, state, publr, "-", "-" });
            continue;
        }

        try out.print("  {s:<24} {s:<8} {s:<10} {s:<24} {s}\n", .{
            site.name,
            state,
            publr,
            try server.site_url(config.arena, site),
            try server.admin_url(config.arena, site),
        });
    }
}

fn list_json(config: *const Config, out: *std.Io.Writer, sites: Sites) !void {
    const Row = struct {
        name: []const u8,
        folder: []const u8,
        entry: []const u8,
        running: bool,
        publr: []const u8,
        port: u16,
        site: []const u8,
        admin: []const u8,
    };
    var rows: std.ArrayList(Row) = .empty;

    for (sites.all) |site| {
        const port = site.local.port;

        try rows.append(config.arena, .{
            .name = site.name,
            .folder = site.folder,
            .entry = site.entry,
            .running = server.running(config.io, site),
            .publr = versions.running_label(config, site) catch "unreadable",
            .port = port,
            .site = if (port > 0) try server.site_url(config.arena, site) else "",
            .admin = if (port > 0) try server.admin_url(config.arena, site) else "",
        });
    }

    try std.json.Stringify.value(rows.items, .{
        .whitespace = .indent_2,
    }, out);
    try out.writeAll("\n");
}

fn start(config: *const Config, out: *std.Io.Writer, chosen: Site, self_path: []const u8) !void {
    var site = chosen;

    try server.start(config, &site, try versions.binary_for(config, site));
    try core.helper.ensure(config, self_path);
    try out.print("{s} running\n", .{site.name});
    try print_links(config, out, site);
}

fn stop(config: *const Config, out: *std.Io.Writer, chosen: Site) !void {
    var site = chosen;

    try server.stop(config, &site);
    try out.print("{s} stopped\n", .{site.name});
}

fn print_links(config: *const Config, out: *std.Io.Writer, site: Site) !void {
    try out.print("  site   {s}\n  admin  {s}\n", .{
        try server.site_url(config.arena, site),
        try server.admin_url(config.arena, site),
    });
}

/// `[<name>] [path] [--print]`: a word starting with `/` is the path.
fn open(
    init: std.process.Init,
    config: *const Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
    self_path: []const u8,
) !void {
    var name: ?[]const u8 = null;
    var back: []const u8 = "/admin";
    var printed = false;

    for (rest) |word| {
        if (std.mem.eql(u8, word, "--print")) {
            printed = true;
        } else if (word.len > 0 and word[0] == '/') {
            back = word;
        } else if (name == null) {
            name = word;
        } else {
            return error.Usage;
        }
    }

    var site = try one(config, name);

    const publr = try versions.binary_for(config, site);

    try server.start(config, &site, publr);
    try core.helper.ensure(config, self_path);

    const link = try core.sign_on.entry(config, &site, publr, back);

    if (printed) {
        return out.print("{s}\n", .{link});
    }

    try browse(init, link);

    const origin = if (std.mem.startsWith(u8, back, "/admin"))
        try server.admin_origin(config.arena, site)
    else
        try server.site_url(config.arena, site);

    try out.print("opened {s}{s}\n", .{ origin, back });
}

pub fn browse(init: std.process.Init, link: []const u8) !void {
    std.debug.assert(link.len > 0);

    if (init.environ_map.get("PUBLR_NO_BROWSER") != null) {
        return;
    }

    const opener = switch (builtin.os.tag) {
        .macos => "open",
        else => "xdg-open",
    };
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ opener, link },
        .stdout = .ignore,
        .stderr = .ignore,
    });

    _ = try child.wait(init.io);
}

fn logs(config: *const Config, out: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len > 1) {
        return error.Usage;
    }

    const site = try one(config, if (rest.len == 1) rest[0] else null);
    const path = try server.log_path(config.arena, site);
    const text = std.Io.Dir.cwd().readFileAlloc(config.io, path, config.arena, .limited(1 << 24)) catch |err| {
        if (err == error.FileNotFound) {
            return out.print("{s} has no log yet\n", .{site.name});
        }

        return err;
    };
    var start_at = text.len;
    var lines: u32 = 0;

    while (start_at > 0 and lines <= 40) : (start_at -= 1) {
        if (text[start_at - 1] == '\n') {
            lines += 1;
        }
    }

    try out.writeAll(text[start_at..]);
}

fn remove(init: std.process.Init, config: *Config, out: *std.Io.Writer, rest: []const []const u8) !void {
    const sure = rest.len == 2 and std.mem.eql(u8, rest[1], "--yes");

    if (rest.len == 0 or (rest.len == 2 and !sure) or rest.len > 2) {
        return error.Usage;
    }

    const sites = try Sites.find(config);
    var site = try sites.named(rest[0]);
    const parent = std.fs.path.dirname(site.folder) orelse return error.Usage;
    const trash = try std.fs.path.join(config.arena, &.{ parent, ".trash" });

    if (!sure and !try confirmed(init, site.name, trash)) {
        try out.print("kept {s}\n", .{site.name});
        return;
    }

    try server.stop(config, &site);

    const kept = try std.fmt.allocPrint(config.arena, "{s}-{d}", .{ site.name, server.now_ms(config.io) });
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(config.io, trash);
    try cwd.rename(site.folder, cwd, try std.fs.path.join(config.arena, &.{ trash, kept }), config.io);

    // A single site's own entry goes off the list with it.
    if (std.mem.eql(u8, site.entry, site.folder) and try config.remove(site.folder)) {
        try config.save();
    }

    try out.print("removed {s}; it is in {s}/{s} until you delete it\n", .{ site.name, trash, kept });
}

fn confirmed(init: std.process.Init, name: []const u8, trash: []const u8) !bool {
    std.debug.print("remove {s}? its folder moves to {s} [y/N] ", .{ name, trash });

    var buffer: [64]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const line = stdin.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trim(u8, line, " \r\t");

    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

/// Studio opened, on a site when one is named.
fn studio(init: std.process.Init, config: *const Config, rest: []const []const u8) !void {
    if (rest.len > 1) {
        return error.Usage;
    }

    if (builtin.os.tag != .macos) {
        std.debug.print("publr: Studio is for macOS for now\n", .{});
        return error.NoStudio;
    }

    var argv: std.ArrayList([]const u8) = .empty;

    try argv.appendSlice(config.arena, &.{ "open", "-a", "Publr Studio" });

    if (rest.len == 1) {
        const site = try one(config, rest[0]);

        try argv.appendSlice(config.arena, &.{ "--args", "--open", site.folder });
    }

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
    });

    _ = try child.wait(init.io);
}

fn configure(config: *Config, out: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len == 0) {
        try out.print("default folder  {s}\n", .{config.folder});

        for (config.folders) |folder| {
            try out.print("also            {s}\n", .{folder});
        }

        try out.print("publr           {s}\n", .{if (config.publr.len > 0) config.publr else "each site's pinned release"});
        try out.print("admin           {s}\n", .{if (config.admin.len > 0) config.admin else "not set: the Cloud account signed in, else the setup page"});
        try out.print("config          {s}\n", .{try config.path(&.{core.config.file_name})});
        return;
    }

    if (std.mem.eql(u8, rest[0], "folder") and rest.len == 2) {
        config.folder = try core.sites.absolute(config, rest[1]);
        try std.Io.Dir.cwd().createDirPath(config.io, config.folder);
    } else if (std.mem.eql(u8, rest[0], "publr") and rest.len >= 2) {
        const unset = std.mem.eql(u8, rest[1], "--unset");
        const chosen = if (unset) "" else try versions.resolve(config, rest[1]);

        if (rest.len == 2) {
            config.publr = chosen;
        } else {
            // Named sites only: the choice is theirs, kept on this computer.
            for (try many(config, rest[2..])) |chosen_site| {
                var site = chosen_site;

                const was_running = server.running(config.io, site);

                if (was_running) {
                    try server.stop(config, &site);
                }

                site.local.publr = chosen;
                try core.sites.save(config, site);

                if (was_running) {
                    try server.start(config, &site, try versions.binary_for(config, site));
                }

                try out.print("{s} runs {s}\n", .{ site.name, if (unset) "its pinned release" else chosen });
            }

            return;
        }
    } else if (std.mem.eql(u8, rest[0], "admin") and rest.len >= 2) {
        if (std.mem.eql(u8, rest[1], "--unset") and rest.len == 2) {
            config.admin = "";
            config.admin_name = "";
        } else if (rest.len == 2 or (rest.len == 4 and std.mem.eql(u8, rest[2], "--name"))) {
            if (std.mem.indexOfScalar(u8, rest[1], '@') == null) {
                return error.Usage;
            }

            config.admin = rest[1];
            config.admin_name = if (rest.len == 4) rest[3] else "";
        } else {
            return error.Usage;
        }
    } else if (std.mem.eql(u8, rest[0], "folders") and rest.len == 3) {
        const folder = try core.sites.absolute(config, rest[2]);

        if (std.mem.eql(u8, rest[1], "add")) {
            if (!try config.add(folder)) {
                return out.print("{s} is listed already\n", .{folder});
            }
        } else if (std.mem.eql(u8, rest[1], "remove")) {
            if (!try config.remove(folder)) {
                return out.print("{s} is not listed\n", .{folder});
            }
        } else {
            return error.Usage;
        }
    } else {
        return error.Usage;
    }

    try config.save();
    try configure(config, out, &.{});
}

fn versions_command(config: *const Config, out: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len == 0) {
        const kept = try versions.list(config);
        const sites = try Sites.find(config);

        try out.print("kept:", .{});

        for (kept) |held| {
            try out.print(" {s}", .{held});
        }

        try out.print("{s}\n", .{if (kept.len == 0) " none" else ""});

        for (sites.all) |site| {
            try out.print("  {s:<24} {s}\n", .{ site.name, versions.running_label(config, site) catch "unreadable" });
        }

        return;
    }

    if (!std.mem.eql(u8, rest[0], "use") or rest.len < 3) {
        return error.Usage;
    }

    const chosen = rest[1];
    const targets = try many(config, rest[2..]);

    _ = try versions.kept(config, chosen);

    for (targets) |site| {
        var running = site;
        const was_running = server.running(config.io, site);

        if (was_running) {
            try server.stop(config, &running);
        }

        try versions.set_pin(config, site.folder, chosen);

        if (was_running) {
            try server.start(config, &running, try versions.binary_for(config, site));
        }

        try out.print("{s} runs {s}\n", .{ site.name, chosen });
    }
}

test {
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(mcp_command);
    std.testing.refAllDecls(setup_command);
    std.testing.refAllDecls(skill_command);
    std.testing.refAllDecls(plugin_build_command);
    std.testing.refAllDecls(pack_command);
    std.testing.refAllDecls(clone_command);
    std.testing.refAllDecls(pull_command);
    std.testing.refAllDecls(push_command);
    std.testing.refAllDecls(deploy_command);
    std.testing.refAllDecls(seed_command);
    std.testing.refAllDecls(toolchain);
    std.testing.refAllDecls(clash);
}

test "of `cloud` only `cloud login` and `cloud deploy` are the command's own" {
    try std.testing.expectEqual(Command.cloud, own(&.{ "cloud", "login" }).?);
    try std.testing.expectEqual(Command.cloud, own(&.{ "cloud", "deploy" }).?);
    try std.testing.expect(own(&.{ "cloud", "spaces" }) == null);
    try std.testing.expect(own(&.{ "content", "list" }) == null);
    try std.testing.expectEqual(Command.ls, own(&.{"ls"}).?);
}
