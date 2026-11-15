//! The helper: the issuer every local site trusts, at `http://127.0.0.1:8789`. A site whose
//! admin session ran out sends the browser to `/sign-on?project=<name>&return=<path>`; the
//! helper starts the site if it is stopped and sends the browser back with a fresh signed
//! link. It runs in the background, started by any command that needs it, and answers only
//! this computer. `GET /about` tells it apart from anything else holding the port.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const server = @import("server.zig");
const sign_on = @import("sign_on.zig");
const versions = @import("versions.zig");

const Config = config_module.Config;

pub const log_name = "helper.log";
pub const about = "publr-cli helper\n";
const request_bytes_max: u32 = 8192;

/// Running, or started now with `self_path helper`. Refused while another program holds the
/// port.
pub fn ensure(config: *const Config, self_path: []const u8) !void {
    std.debug.assert(self_path.len > 0);

    if (server.listening(config.io, sign_on.helper_port)) {
        if (ours(config)) {
            return;
        }

        std.debug.print("publr: another program holds 127.0.0.1:{d}; " ++
            "signed-in links need it free\n", .{sign_on.helper_port});
        return;
    }

    const log_path = try config.path(&.{log_name});
    const log = try std.Io.Dir.cwd().createFile(config.io, log_path, .{});
    defer log.close(config.io);

    _ = try std.process.spawn(config.io, .{
        .argv = &.{ self_path, "helper" },
        .stdin = .ignore,
        .stdout = .{
            .file = log,
        },
        .stderr = .{
            .file = log,
        },
        .pgid = 0,
    });

    var waited: u32 = 0;

    while (waited < 5000 and !server.listening(config.io, sign_on.helper_port)) : (waited += 100) {
        try std.Io.sleep(config.io, .fromMilliseconds(100), .awake);
    }
}

fn ours(config: *const Config) bool {
    var body: std.Io.Writer.Allocating = .init(config.arena);

    versions.get(config.io, sign_on.issuer ++ "/about", &body.writer) catch return false;

    return std.mem.eql(u8, body.written(), about);
}

/// In the foreground: `publr helper`.
pub fn serve(init: std.process.Init) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", sign_on.helper_port);
    var listener = try address.listen(init.io, .{
        .reuse_address = true,
    });
    defer listener.deinit(init.io);

    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.debug.print("publr helper: accept: {t}\n", .{err});
            continue;
        };
        defer stream.close(init.io);

        var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena_state.deinit();

        answer(init, arena_state.allocator(), stream) catch |err| switch (err) {
            // Asking whether the helper is up: a connection and nothing sent.
            error.EndOfStream => {},
            else => std.debug.print("publr helper: {t}\n", .{err}),
        };
    }
}

fn answer(init: std.process.Init, arena: std.mem.Allocator, stream: std.Io.net.Stream) !void {
    var in_buffer: [request_bytes_max]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;
    var reader = stream.reader(init.io, &in_buffer);
    var writer = stream.writer(init.io, &out_buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
    const method = parts.next() orelse "";
    const target = parts.next() orelse "/";
    const out = &writer.interface;
    const get = std.mem.eql(u8, method, "GET");

    std.debug.assert(target.len <= request_bytes_max);

    if (get and std.mem.eql(u8, target, "/about")) {
        try out.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ about.len, about });
        return out.flush();
    }

    const location = if (get) try where(init, arena, target) else null;

    if (location) |found| {
        try out.print("HTTP/1.1 303 See Other\r\nLocation: {s}\r\nCache-Control: no-store\r\n" ++
            "Content-Length: 0\r\nConnection: close\r\n\r\n", .{found});
    } else {
        const body = "Not a site here. Run `publr ls`.\n";

        try out.print("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    }

    try out.flush();
}

/// `/sign-on?project=<name>&return=<path>`: the site's signed link, the site started first.
fn where(init: std.process.Init, arena: std.mem.Allocator, target: []const u8) !?[]const u8 {
    std.debug.assert(target.len > 0);

    const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return null;

    if (!std.mem.eql(u8, target[0..query_at], "/sign-on")) {
        return null;
    }

    var name: []const u8 = "";
    var back: []const u8 = "/admin";
    var pairs = std.mem.tokenizeScalar(u8, target[query_at + 1 ..], '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const value = try decode(arena, pair[equals + 1 ..]);

        if (std.mem.eql(u8, pair[0..equals], "project")) {
            name = value;
        } else if (std.mem.eql(u8, pair[0..equals], "return") and value.len > 0 and
            value[0] == '/' and !std.mem.startsWith(u8, value, "//"))
        {
            back = value;
        }
    }

    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
        return null;
    }

    const config = try Config.load(init.io, arena, init.environ_map);
    const all = try sites_module.Sites.find(&config);
    var site = all.named(name) catch return null;

    const publr = try versions.binary_for(&config, site);

    if (!server.running(config.io, site)) {
        try server.start(&config, &site, publr);
    }

    return try sign_on.entry(&config, &site, publr, back);
}

fn decode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= request_bytes_max);

    const copy = try arena.dupe(u8, text);

    for (copy) |*char| {
        if (char.* == '+') {
            char.* = ' ';
        }
    }

    return std.Uri.percentDecodeInPlace(copy);
}
