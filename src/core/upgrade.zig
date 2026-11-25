//! `publr upgrade <site>`: a site on this computer moved to the release Cloud runs, however
//! far behind it is and whatever made it. Update, Update this copy and Make Cloud compatible
//! in Desktop are this one action (`.agents/specs/updates.md`, "Sites on a computer").
//!
//! First the plan, which changes nothing: Cloud's release asked whether it opens the
//! database as it is (`db check`); when it does not, what its repair (`db conform`) would do
//! and leave out. Then the update: the server stopped, the database kept aside, repaired
//! when it must be, the site pinned to the release and started, which migrates it (Publr backs
//! the whole site up first). Anything failing puts the database, the Publr it ran and its
//! server back as they were.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const versions = @import("versions.zig");
const server = @import("server.zig");
const compat = @import("compat.zig");
const site_data = @import("site_data.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

/// The database's files, kept aside while it is updated: the database and SQLite's journal.
const database_files = [_][]const u8{ "", "-wal", "-shm" };
const kept_folder = "before-update";

pub const Plan = struct {
    version: compat.Version,
    /// The release it moves to.
    to: []const u8,
    /// Cloud's release would not open the database as it is: `db conform` brings it back.
    repair: bool = false,
    /// What the repair leaves out, as `db conform` says it (`leave-out …`), one per line; kept
    /// aside in the backup it takes.
    left_out: []const []const u8 = &.{},
    /// What the repair changes, as `db conform` says it (`rebuild …`, `drop …`).
    changes: []const []const u8 = &.{},

    pub fn needed(found: Plan) bool {
        return found.version.state != .up_to_date or found.repair;
    }
};

pub const Options = struct {
    /// The person saw what the repair leaves out (`Plan.left_out`) and agreed.
    accept_left_out: bool = false,
};

pub const Error = error{
    /// Every site runs a Publr chosen with `publr config publr`: the update would not reach it.
    ChosenForAll,
    /// Cloud's release has no `db conform`; a release that has comes first.
    RepairUnavailable,
    /// `db conform` refused the database (a newer release made it, or it is damaged).
    RepairRefused,
    /// The repair leaves something out and the person has not agreed yet.
    NeedsConsent,
};

/// What updating `site` would do; changes nothing.
pub fn plan(config: *const Config, site: Site) !Plan {
    if (config.call_publr.len > 0 or config.publr.len > 0) {
        return Error.ChosenForAll;
    }

    const version = try compat.of(config, site, .{});
    const to = version.cloud;
    var found: Plan = .{
        .version = version,
        .to = to,
    };

    // A release's database reaches Cloud's by the migration chain, which the start runs (and a
    // refusal there puts everything back). Only a local only site needs the repair: Cloud's
    // Publr was asked already (`compat.of`) and would not open it.
    if (version.state != .local_only) {
        return found;
    }

    const said = try conform(config, site, to, true);

    found.repair = true;
    found.left_out = try lines_of(config.arena, said, "leave-out ");
    found.changes = try changes_of(config.arena, said);

    return found;
}

/// `site` moved to `chosen.to`; its server running afterwards if it ran before.
pub fn run(config: *const Config, site: *Site, chosen: Plan, options: Options) !void {
    std.debug.assert(chosen.to.len > 0);

    if (chosen.left_out.len > 0 and !options.accept_left_out) {
        return Error.NeedsConsent;
    }

    const release = try versions.kept(config, chosen.to);
    const was_running = server.running(config.io, site.*);
    const old_pin = try versions.pin_of(config, site.folder);
    const old_publr = site.local.publr;

    try server.stop(config, site);
    try keep_database(config, site.*);

    moved(config, site, chosen, release) catch |err| {
        std.debug.print("publr: updating {s} to Publr {s} failed ({t}); putting it back\n", .{
            site.name,
            chosen.to,
            err,
        });
        server.stop(config, site) catch {};
        restore_database(config, site.*) catch |restore_err| {
            std.debug.print("publr: {s}'s database could not be put back ({t}): it is in {s}\n", .{
                site.name,
                restore_err,
                try kept_path(config, site.*, ""),
            });
        };

        if (old_pin) |pin| versions.set_pin(config, site.folder, pin) catch {};

        site.local.publr = old_publr;
        sites_module.save(config, site.*) catch {};

        if (was_running) {
            const old = versions.binary_for(config, site.*) catch return err;

            server.start(config, site, old) catch {};
        }

        return err;
    };

    compat.forget(config, site.*);

    if (!was_running) {
        try server.stop(config, site);
    }
}

/// The steps that change the site; the caller puts it back when one fails.
fn moved(config: *const Config, site: *Site, chosen: Plan, release: []const u8) !void {
    if (chosen.repair) {
        _ = try conform(config, site.*, chosen.to, false);
    }

    try versions.set_pin(config, site.folder, chosen.to);
    site.local.publr = "";
    try sites_module.save(config, site.*);
    // Starting opens the database through Publr's gate: it backs the site up, migrates it
    // and refuses it when it cannot; answering means it took it.
    try server.start(config, site, release);
}

/// `db conform` of Cloud's release on the site's database: what it would do (`dry`), or
/// done. Its output, line by line.
fn conform(config: *const Config, site: Site, to: []const u8, dry: bool) ![]const u8 {
    const release = try versions.kept(config, to);
    const database = try std.fs.path.join(config.arena, &.{ site.folder, site_data.database });
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.appendSlice(config.arena, &.{ release, "--db", database, "db", "conform" });

    if (dry) {
        try argv.append(config.arena, "--dry-run");
    }

    const result = try std.process.run(config.arena, config.io, .{
        .argv = argv.items,
        .cwd = .{
            .path = site.folder,
        },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(4 << 20),
    });

    if (versions.succeeded(result.term)) {
        return result.stdout;
    }

    // A release before the repair existed answers with its usage, not a refusal.
    if (std.mem.indexOf(u8, result.stdout, "conform:") == null and
        std.mem.indexOf(u8, result.stderr, "conform") == null)
    {
        std.debug.print("publr: Publr {s} cannot repair {s}'s database; a later release can\n", .{
            to,
            site.name,
        });
        return Error.RepairUnavailable;
    }

    std.debug.print("publr: Publr {s} would not repair {s}'s database:\n{s}{s}\n", .{
        to,
        site.name,
        result.stdout,
        result.stderr,
    });
    return Error.RepairRefused;
}

fn lines_of(arena: std.mem.Allocator, said: []const u8, prefix: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, said, '\n');

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            try found.append(arena, line);
        }
    }

    return found.items;
}

fn changes_of(arena: std.mem.Allocator, said: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, said, '\n');

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "rebuild ") or std.mem.startsWith(u8, line, "drop ") or
            std.mem.startsWith(u8, line, "create ") or std.mem.startsWith(u8, line, "null ") or
            std.mem.startsWith(u8, line, "forget "))
        {
            try found.append(arena, line);
        }
    }

    return found.items;
}

fn kept_path(config: *const Config, site: Site, suffix: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(config.arena, "publr.db{s}", .{suffix});

    return std.fs.path.join(config.arena, &.{ site.folder, sites_module.own_folder, kept_folder, name });
}

/// The stopped site's database files copied to `.publr/before-update/`, replacing an earlier
/// copy.
fn keep_database(config: *const Config, site: Site) !void {
    const cwd = std.Io.Dir.cwd();
    const into = try std.fs.path.join(config.arena, &.{ site.folder, sites_module.own_folder, kept_folder });

    try cwd.deleteTree(config.io, into);
    try cwd.createDirPath(config.io, into);

    for (database_files) |suffix| {
        const from = try std.fmt.allocPrint(config.arena, "{s}/{s}{s}", .{ site.folder, site_data.database, suffix });

        cwd.copyFile(from, cwd, try kept_path(config, site, suffix), config.io, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
}

/// The database put back as `keep_database` copied it.
fn restore_database(config: *const Config, site: Site) !void {
    const cwd = std.Io.Dir.cwd();

    for (database_files) |suffix| {
        const to = try std.fmt.allocPrint(config.arena, "{s}/{s}{s}", .{ site.folder, site_data.database, suffix });

        cwd.deleteFile(config.io, to) catch {};
        cwd.copyFile(try kept_path(config, site, suffix), cwd, to, config.io, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
}

test "what a repair would leave out is read from its lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const said =
        \\rebuild ledger_transfers
        \\drop index ledger_transfers_hold
        \\leave-out ledger_transfers 3 rows
        \\conform: 2 change(s), 3 left out
    ;

    try std.testing.expectEqual(1, (try lines_of(arena, said, "leave-out ")).len);
    try std.testing.expectEqual(2, (try changes_of(arena, said)).len);
    try std.testing.expectEqual(0, (try lines_of(arena, "conform: nothing to do", "leave-out ")).len);
}
