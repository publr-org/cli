//! A site's server: `publr serve` in its folder, on its port, in a process group of its own so
//! it outlives the command and the terminal. Whether a site runs is whether its port answers;
//! the recorded pid is only how it is stopped.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

pub const log_name = "serve.log";
const start_wait_ms: u32 = 30_000;
const stop_wait_ms: u32 = 5_000;
const poll_ms: u32 = 100;

pub fn listening(io: std.Io, port: u16) bool {
    std.debug.assert(port > 0);

    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = address.connect(io, .{
        .mode = .stream,
    }) catch return false;

    stream.close(io);

    return true;
}

pub fn running(io: std.Io, site: Site) bool {
    return site.local.port > 0 and listening(io, site.local.port);
}

pub fn site_url(arena: std.mem.Allocator, site: Site) ![]const u8 {
    std.debug.assert(site.local.port > 0);

    return std.fmt.allocPrint(arena, "http://localhost:{d}", .{site.local.port});
}

/// The admin's own origin: another host than the site's, so the site's scripts never run
/// beside the admin's session. `*.localhost` needs no setup on any system.
pub fn admin_origin(arena: std.mem.Allocator, site: Site) ![]const u8 {
    std.debug.assert(site.local.port > 0);

    return std.fmt.allocPrint(arena, "http://admin.localhost:{d}", .{site.local.port});
}

pub fn admin_url(arena: std.mem.Allocator, site: Site) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/admin", .{try admin_origin(arena, site)});
}

pub fn log_path(arena: std.mem.Allocator, site: Site) ![]const u8 {
    return std.fs.path.join(arena, &.{ site.folder, sites_module.own_folder, log_name });
}

/// The site given a port of its own, once.
pub fn ensure_port(config: *const Config, site: *Site) !void {
    if (site.local.port > 0) {
        return;
    }

    const all = try sites_module.Sites.find(config);

    site.local.port = try all.free_port(&listening);

    if (site.local.created_ms == 0) {
        site.local.created_ms = now_ms(config.io);
    }

    try sites_module.save(config, site.*);
}

/// Started with `publr` and answering, or an error naming the log to read.
pub fn start(config: *const Config, site: *Site, publr: []const u8) !void {
    return start_with(config, site, publr, &.{});
}

/// Started with `publr` and `more` after `serve`'s own words (`--plugin <file>`).
pub fn start_with(config: *const Config, site: *Site, publr: []const u8, more: []const []const u8) !void {
    std.debug.assert(publr.len > 0);
    std.debug.assert(more.len <= 16);

    try ensure_port(config, site);

    if (listening(config.io, site.local.port)) {
        return;
    }

    const arena = config.arena;
    const own = try std.fs.path.join(arena, &.{ site.folder, sites_module.own_folder });

    try std.Io.Dir.cwd().createDirPath(config.io, own);

    const log = try log_path(arena, site.*);
    const file = try std.Io.Dir.cwd().createFile(config.io, log, .{});
    defer file.close(config.io);

    const port = try std.fmt.allocPrint(arena, "{d}", .{site.local.port});
    const url = try site_url(arena, site.*);
    const admin = try admin_origin(arena, site.*);
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.appendSlice(arena, &.{ publr, "serve", "--port", port, "--url", url, "--admin-url", admin });
    try argv.appendSlice(arena, more);

    const child = try std.process.spawn(config.io, .{
        .argv = argv.items,
        .cwd = .{
            .path = site.folder,
        },
        .stdin = .ignore,
        .stdout = .{
            .file = file,
        },
        .stderr = .{
            .file = file,
        },
        .pgid = 0,
    });

    site.local.pid = child.id orelse 0;
    try sites_module.save(config, site.*);

    if (!try wait(config.io, site.local.port, true, start_wait_ms)) {
        std.debug.print("publr: {s} did not start; see {s}\n", .{ site.name, log });
        return error.NotStarted;
    }

    // Publr's own commands find the running server by this file; until it is there, a
    // command beside it would open the database itself.
    const marker = try std.fs.path.join(arena, &.{ site.folder, "data", "publr.db.serve" });
    var waited: u32 = 0;

    while (waited < start_wait_ms) : (waited += poll_ms) {
        std.Io.Dir.cwd().access(config.io, marker, .{}) catch {
            try std.Io.sleep(config.io, .fromMilliseconds(poll_ms), .awake);
            continue;
        };

        return;
    }
}

pub fn stop(config: *const Config, site: *Site) !void {
    std.debug.assert(site.name.len > 0);

    if (site.local.port == 0) {
        return;
    }

    if (site.local.pid > 0) {
        signal(site.local.pid, std.posix.SIG.TERM);

        if (!try wait(config.io, site.local.port, false, stop_wait_ms)) {
            signal(site.local.pid, std.posix.SIG.KILL);
            _ = try wait(config.io, site.local.port, false, stop_wait_ms);
        }
    }

    site.local.pid = 0;
    try sites_module.save(config, site.*);

    if (listening(config.io, site.local.port)) {
        std.debug.print("publr: port {d} still answers: something else, not {s}, holds it\n", .{
            site.local.port,
            site.name,
        });
        return error.PortHeld;
    }
}

fn signal(pid: i32, sig: std.posix.SIG) void {
    std.debug.assert(pid > 0);

    std.posix.kill(pid, sig) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => std.debug.print("publr: could not signal {d}: {t}\n", .{ pid, err }),
    };
}

/// Until the port answers (`up`) or stops answering; false when the time ran out.
fn wait(io: std.Io, port: u16, up: bool, limit_ms: u32) !bool {
    std.debug.assert(port > 0);
    std.debug.assert(limit_ms >= poll_ms);

    var waited: u32 = 0;

    while (waited < limit_ms) : (waited += poll_ms) {
        if (listening(io, port) == up) {
            return true;
        }

        try std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
    }

    return listening(io, port) == up;
}

pub fn now_ms(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);

    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}
