//! A command sent to a Publr elsewhere: `publr --site <address> <command>` posts its words
//! to the site's `/api/cli` with this computer's device token, and the site runs them as that
//! device. The words are read there, so a project's plugins answer with their own commands
//! whoever asks. `login.zig` gets the token.
const std = @import("std");
const credentials = @import("credentials.zig");

pub const route = "/api/cli";

pub const Envelope = struct {
    args: []const []const u8,
};
pub const Answer = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
    /// The name of the failure it ended with, empty for none.
    failure: []const u8 = "",
};

/// The command run by the Publr at `address` with the token this machine keeps for it, or by
/// its copy `env`: its exit code, its output written to `out` and its errors to stderr.
pub fn forward(
    init: std.process.Init,
    address: []const u8,
    args: []const []const u8,
    env: ?[]const u8,
    out: *std.Io.Writer,
) !u8 {
    std.debug.assert(address.len > 0);
    std.debug.assert(args.len > 0);

    const site = try credentials.find(init, address) orelse {
        std.debug.print("publr: not signed in to {s}; run \"publr login {s}\"\n", .{
            address,
            address,
        });
        return 1;
    };
    const target = if (env) |name|
        try copy_address(init, site, name) orelse return 1
    else
        site.address;
    const answer = try send(init, site, target, args) orelse return 1;

    try out.writeAll(answer.out);
    std.debug.print("{s}", .{answer.err});

    return answer.code;
}

/// One copy as `environments list` and `open` answer it: what `--env` needs.
pub const Copy = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    address: []const u8 = "",
    current: bool = false,
};
pub const Copies = struct {
    environments: []const Copy,
};

/// The copy called `name`, by its slug or an alias; null when none is.
pub fn copy_named(copies: []const Copy, name: []const u8) ?Copy {
    std.debug.assert(name.len > 0);

    for (copies) |copy| {
        if (std.mem.eql(u8, copy.name, name)) {
            return copy;
        }

        for (copy.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) {
                return copy;
            }
        }
    }

    return null;
}

/// Where `site`'s copy `name` answers, started if it was stopped; null, having said why, when
/// it cannot be reached.
fn copy_address(init: std.process.Init, site: credentials.Site, name: []const u8) !?[]const u8 {
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();
    const words = [_][]const u8{ "environments", "list" };
    const listed = try send(init, site, site.address, &words) orelse return null;
    const parse: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const parsed = std.json.parseFromSliceLeaky(Copies, arena, listed.out, parse) catch {
        std.debug.print("publr: {s} keeps no environments or branches here\n{s}", .{
            site.address,
            listed.err,
        });
        return null;
    };
    const copy = copy_named(parsed.environments, name) orelse {
        std.debug.print("publr --env: no environment, branch or alias {s}; " ++
            "`publr environments list` names them\n", .{name});
        return null;
    };

    if (copy.address.len > 0) {
        return copy.address;
    }

    const open = [_][]const u8{ "environments", "open", "--name", copy.name };
    const opened = try send(init, site, site.address, &open) orelse return null;
    const started = std.json.parseFromSliceLeaky(Copy, arena, opened.out, parse) catch null;

    if (started == null or started.?.address.len == 0) {
        std.debug.print("publr --env: {s} could not be started\n{s}", .{ name, opened.err });
        return null;
    }

    return started.?.address;
}

/// The command posted to `/api/cli` at `target` with `site`'s token; null, having said why,
/// when it was not run.
fn send(
    init: std.process.Init,
    site: credentials.Site,
    target: []const u8,
    args: []const []const u8,
) !?Answer {
    std.debug.assert(target.len > 0);
    std.debug.assert(args.len > 0);

    const arena = init.arena.allocator();
    const payload = try std.json.Stringify.valueAlloc(arena, Envelope{
        .args = args,
    }, .{});
    const reply = try post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ target, route }),
        .payload = payload,
        .token = site.token,
    });

    if (reply.status == .unauthorized) {
        std.debug.print("publr: {s} no longer accepts this device; run \"publr login {s}\"\n", .{
            target,
            site.address,
        });
        return null;
    }

    if (reply.status != .ok) {
        std.debug.print("publr: {s} answered {d}\n", .{ target, @backingInt(reply.status) });
        return null;
    }

    return try std.json.parseFromSliceLeaky(Answer, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });
}

pub const Post = struct {
    url: []const u8,
    payload: []const u8,
    token: ?[]const u8 = null,
};
pub const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

/// A JSON body posted to `url`, with a device's token when there is one.
pub fn post(io: std.Io, arena: std.mem.Allocator, request: Post) !Reply {
    std.debug.assert(request.url.len > 0);
    std.debug.assert(request.payload.len > 0);

    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const bearer = if (request.token) |token|
        try std.fmt.allocPrint(arena, "Bearer {s}", .{token})
    else
        "";
    const authorization: []const std.http.Header = if (request.token != null)
        &.{.{
            .name = "Authorization",
            .value = bearer,
        }}
    else
        &.{};
    const result = try client.fetch(.{
        .location = .{
            .url = request.url,
        },
        .method = .POST,
        .payload = request.payload,
        .keep_alive = false,
        .headers = .{
            .content_type = .{
                .override = "application/json",
            },
        },
        .extra_headers = authorization,
        .response_writer = &body.writer,
    });

    return .{
        .status = result.status,
        .body = body.written(),
    };
}

/// The address to use for `address`. An `https://` one whose port answers plain HTTP (a
/// `publr serve`, which speaks no TLS) would leave the TLS handshake waiting forever: on
/// this machine its `http://` address is used, saying so; elsewhere it is refused with why.
pub fn settle(io: std.Io, arena: std.mem.Allocator, address: []const u8) ![]const u8 {
    std.debug.assert(address.len > 0);

    const prefix = "https://";

    if (!std.mem.startsWith(u8, address, prefix)) {
        return address;
    }

    const rest = address[prefix.len..];
    const authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |at| authority[0..at] else authority;
    const port = if (colon) |at| std.fmt.parseInt(u16, authority[at + 1 ..], 10) catch 443 else 443;

    if (!plain_http(io, host, port)) {
        return address;
    }

    const plain = try std.fmt.allocPrint(arena, "http://{s}", .{rest});

    if (!credentials.on_this_machine(host)) {
        std.debug.print("publr: {s} answers plain http, not https; use {s} if you mean it\n", .{
            address,
            plain,
        });
        return error.NotHttps;
    }

    std.debug.print("publr: {s} answers plain http (a `publr serve`): using {s}\n", .{
        address,
        plain,
    });

    return plain;
}

/// Whether `host:port` speaks plain HTTP and no TLS. Some TLS servers (Cloudflare, nginx)
/// answer plain HTTP on their TLS port with an HTTP 400, so an HTTP answer alone is not
/// enough: a server that also answers a TLS record with one speaks TLS. A TLS server
/// refuses plain bytes at once and a plain one answers the TLS probe with an HTTP error,
/// so no probe waits long.
fn plain_http(io: std.Io, host: []const u8, port: u16) bool {
    std.debug.assert(port > 0);

    const answer = probe(io, host, port, "HEAD / HTTP/1.0\r\n\r\n", 5) orelse return false;

    if (!std.mem.eql(u8, answer.slice(), "HTTP/")) {
        return false;
    }

    // A ClientHello record too short to be one: a TLS server answers with an alert (0x15).
    // The blank line after it ends the bytes as an HTTP request, so a plain server answers
    // instead of waiting for more.
    const hello = "\x16\x03\x01\x00\x04\x01\x00\x00\x00\r\n\r\n";
    const tls = probe(io, host, port, hello, 1) orelse return true;
    const record = tls.slice()[0];

    return record != 0x15 and record != 0x16;
}

const Head = struct {
    bytes: [8]u8,
    len: u32,

    fn slice(head: *const Head) []const u8 {
        return head.bytes[0..head.len];
    }
};

/// The first `len` bytes `host:port` answers to `request` on a fresh connection, or null
/// when it cannot be reached or closes first.
fn probe(io: std.Io, host: []const u8, port: u16, request: []const u8, len: u32) ?Head {
    std.debug.assert(len > 0);
    std.debug.assert(len <= 8);

    const name = std.Io.net.HostName.init(host) catch return null;
    const stream = name.connect(io, port, .{
        .mode = .stream,
    }) catch return null;
    defer stream.close(io);

    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    writer.interface.writeAll(request) catch return null;
    writer.interface.flush() catch return null;

    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const answer = reader.interface.peek(len) catch return null;

    var head: Head = .{
        .bytes = undefined,
        .len = len,
    };
    @memcpy(head.bytes[0..len], answer);

    return head;
}
