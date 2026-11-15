//! A site's data on its way between this computer and a Publr elsewhere: what a clone would
//! bring down (`GET /api/sites/size`), the site packed for it (`POST /api/sites/pack`,
//! followed at `/api/sites/pack/progress`) and fetched in pieces, the release the site runs
//! (`GET /api/health`), and a file sent up in pieces with its length declared.

const std = @import("std");
const credentials = @import("credentials.zig");
const remote = @import("remote.zig");

pub const size_route = "/api/sites/size";
pub const pack_route = "/api/sites/pack";
pub const pack_progress_route = "/api/sites/pack/progress";
pub const health_route = "/api/health";
/// The most one piece of a pack holds, as the site sends them.
pub const piece_bytes_max: u32 = 1 << 20;
const pack_poll_ms: u32 = 300;
const answer_bytes_max: u32 = 64 << 10;

/// What a clone would bring down.
pub const Size = struct {
    database_bytes: u64 = 0,
    media_files: u64 = 0,
    media_bytes: u64 = 0,
    apps_bytes: u64 = 0,
    plugins_bytes: u64 = 0,
    /// The newest activity entry: a clone that took an older one is behind.
    latest_change: i64 = 0,
};

/// A media file a folder holds already, by its storage key and its hash.
pub const Held = struct {
    key: []const u8,
    hash: []const u8,
};

/// The pack, once made.
pub const Made = struct {
    bytes: u64,
    /// The Publr that made it.
    publr: []const u8,
    name: []const u8 = "",
};

const Packing = struct {
    state: []const u8,
    /// How far, in ten-thousandths.
    through: u32 = 0,
    made: ?Made = null,
    why: []const u8 = "",
};

const Answer = struct {
    status: std.http.Status,
    body: []const u8,
};

/// `GET <route>` on the site, as the device signed in there.
pub fn get(io: std.Io, arena: std.mem.Allocator, site: credentials.Site, route: []const u8) !Answer {
    std.debug.assert(site.token.len > 0);
    std.debug.assert(route.len > 0 and route[0] == '/');

    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, route });
    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = url,
        },
        .keep_alive = false,
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{site.token}),
        }},
        .response_writer = &body.writer,
    });

    return .{
        .status = result.status,
        .body = body.written(),
    };
}

/// The release the site runs; null, having said why, when it does not say.
pub fn release_of(io: std.Io, arena: std.mem.Allocator, site: credentials.Site) !?[]const u8 {
    const answer = try get(io, arena, site, health_route);

    if (answer.status != .ok) {
        std.debug.print("publr: {s} answered {d} when asked its release\n", .{
            site.address,
            @intFromEnum(answer.status),
        });
        return null;
    }

    const Health = struct {
        version: []const u8,
    };
    const health = std.json.parseFromSliceLeaky(Health, arena, answer.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    return health.version;
}

/// Where `site` is synced: the address its Publr names in `/api/health` (`sync`: a host that
/// keeps sync away from the CDN in front of its pages, as Publr Cloud does), with the same
/// sign-in; the site itself when it names none or cannot be asked.
pub fn sync_of(io: std.Io, arena: std.mem.Allocator, site: credentials.Site) credentials.Site {
    const answer = get(io, arena, site, health_route) catch return site;

    if (answer.status != .ok) {
        return site;
    }

    const Health = struct {
        sync: []const u8 = "",
    };
    const health = std.json.parseFromSliceLeaky(Health, arena, answer.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return site;

    if (health.sync.len == 0 or std.mem.indexOf(u8, health.sync, "://") == null) {
        return site;
    }

    var synced = site;

    synced.address = std.mem.trimEnd(u8, health.sync, "/");

    return synced;
}

/// What a clone of `site` would bring down, as the site says it (JSON); null, having said
/// why, when it does not.
pub fn size_text(io: std.Io, arena: std.mem.Allocator, site: credentials.Site) !?[]const u8 {
    const answer = try get(io, arena, site, size_route);

    if (answer.status != .ok) {
        std.debug.print("publr: {s} answered {d} when asked its size\n", .{
            site.address,
            @intFromEnum(answer.status),
        });
        return null;
    }

    return answer.body;
}

pub fn size_of(io: std.Io, arena: std.mem.Allocator, site: credentials.Site) !?Size {
    const text = try size_text(io, arena, site) orelse return null;

    return try std.json.parseFromSliceLeaky(Size, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

/// Who else hears how far a pack or a download is, beside the terminal: a clone's progress
/// page.
pub const Watch = struct {
    context: ?*anyopaque = null,
    /// How far the site is packing it, in ten-thousandths.
    packing: ?*const fn (context: *anyopaque, through: u32) void = null,
    downloading: ?*const fn (context: *anyopaque, done_bytes: u64, total_bytes: u64) void = null,
};

/// The site packed for a clone (`asked`: what `POST /api/sites/pack` takes), followed until
/// it is made, how far told on `out` and to `watch`; null, having said why, when it was not.
pub fn prepared(
    io: std.Io,
    arena: std.mem.Allocator,
    site: credentials.Site,
    asked: []const u8,
    out: *std.Io.Writer,
    watch: Watch,
) !?Made {
    std.debug.assert(asked.len > 0);

    const reply = try remote.post(io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, pack_route }),
        .payload = asked,
        .token = site.token,
    });

    if (reply.status != .accepted) {
        const refused = reply.status == .unauthorized or reply.status == .forbidden;

        if (refused) {
            std.debug.print("publr: only {s}'s administrators can bring it down; " ++
                "sign in as one: publr login {s}\n", .{ site.address, site.address });
        } else {
            std.debug.print("publr: {s} answered {d} when asked to pack itself\n", .{
                site.address,
                @intFromEnum(reply.status),
            });
        }

        return null;
    }

    while (true) {
        var state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer state.deinit();

        const answer = try get(io, state.allocator(), site, pack_progress_route);

        if (answer.status != .ok) {
            std.debug.print("publr: {s} stopped saying how far the packing is\n", .{site.address});
            return null;
        }

        const packing = try std.json.parseFromSliceLeaky(Packing, state.allocator(), answer.body, .{
            .ignore_unknown_fields = true,
        });

        try out.print("\rPacking on the site... {d}%", .{packing.through / 100});
        try out.flush();

        if (watch.packing) |told| {
            told(watch.context.?, packing.through);
        }

        if (packing.made) |made| {
            try out.print("\rPacking on the site... done\n", .{});

            return .{
                .bytes = made.bytes,
                .publr = try arena.dupe(u8, made.publr),
                .name = try arena.dupe(u8, made.name),
            };
        }

        if (!std.mem.eql(u8, packing.state, "packing")) {
            try out.print("\n", .{});
            std.debug.print("publr: {s} could not pack itself; its own log says why ({s})\n", .{
                site.address,
                packing.why,
            });
            return null;
        }

        try std.Io.sleep(io, .fromMilliseconds(pack_poll_ms), .awake);
    }
}

/// The pack's pieces, in order, into `path`, how far told on `out` and to `watch`.
pub fn fetch(
    io: std.Io,
    site: credentials.Site,
    bytes: u64,
    path: []const u8,
    out: *std.Io.Writer,
    watch: Watch,
) !void {
    std.debug.assert(path.len > 0);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [64 << 10]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var offset: u64 = 0;

    while (true) {
        var state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer state.deinit();

        const taken = try fetch_piece(io, state.allocator(), site, offset, &writer.interface);

        offset += taken;
        try out.print("\rDownloading... {d}% of {d} KiB", .{ offset * 100 / @max(bytes, 1), bytes / 1024 });
        try out.flush();

        if (watch.downloading) |told| {
            told(watch.context.?, offset, bytes);
        }

        if (taken < piece_bytes_max) {
            break;
        }
    }

    try writer.interface.flush();
    try out.print("\n", .{});

    if (offset != bytes) {
        return error.ShortDownload;
    }
}

fn fetch_piece(
    io: std.Io,
    arena: std.mem.Allocator,
    site: credentials.Site,
    offset: u64,
    into: *std.Io.Writer,
) !u64 {
    const route = try std.fmt.allocPrint(arena, "{s}?offset={d}", .{ pack_route, offset });
    const answer = try get(io, arena, site, route);

    if (answer.status != .ok) {
        return error.DownloadRefused;
    }

    try into.writeAll(answer.body);

    return answer.body.len;
}

pub const Upload = struct {
    url: []const u8,
    token: []const u8,
    path: []const u8,
    /// How much is read and sent between two progress reports.
    piece_bytes: u32,
    /// Where the progress goes: `Uploading... 40%`.
    out: *std.Io.Writer,
    /// One JSON line per report instead (`{"stage":"uploading","done":…,"total":…}`), for a
    /// program driving the command.
    json: bool = false,
};

/// An upload sent in parts of at most this, each its own request: the proxy in front of
/// Publr Cloud refuses a request over 100 MB.
pub const part_bytes_max: u64 = 32 << 20;
const part_attempts: u32 = 5;

/// The file at `path` sent to a dashboard's `/api/cloud/bundles` in parts: the first
/// begins the upload, each later one adds `?upload=<name>&offset=<bytes>`; a refused offset
/// (409) or a lost connection goes on from the bytes the dashboard has. The last answer,
/// `{ upload, bytes }`, or the first refusal.
pub fn send_in_parts(io: std.Io, arena: std.mem.Allocator, upload: Upload) !Reply {
    std.debug.assert(upload.url.len > 0);
    std.debug.assert(upload.piece_bytes > 0);

    var file = try std.Io.Dir.cwd().openFile(io, upload.path, .{});
    defer file.close(io);

    var file_buffer: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const size = try reader.getSize();
    var name: []const u8 = "";
    var offset: u64 = 0;
    var failures: u32 = 0;
    var last: Reply = .{
        .status = .bad_request,
        .body = "",
    };

    while (offset < size or name.len == 0) {
        const url = if (name.len == 0)
            upload.url
        else
            try std.fmt.allocPrint(arena, "{s}?upload={s}&offset={d}", .{ upload.url, name, offset });
        const length = @min(size - offset, part_bytes_max);

        try reader.seekTo(offset);

        const sent = post_part(io, arena, upload, url, &reader.interface, offset, length, size);
        const reply = sent catch |err| {
            failures += 1;

            if (failures == part_attempts or name.len == 0) {
                return err;
            }

            continue;
        };

        last = reply;

        const Part = struct {
            upload: []const u8 = "",
            bytes: u64 = 0,
        };
        const answer = std.json.parseFromSliceLeaky(Part, arena, reply.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch Part{};

        switch (reply.status) {
            .created, .ok => {
                if (answer.upload.len > 0) {
                    name = answer.upload;
                }

                // A part taken and nothing added: the dashboard is not following along.
                if (answer.bytes <= offset and offset < size) {
                    return reply;
                }

                offset = answer.bytes;
            },
            // What the dashboard has is where the next part starts.
            .conflict => {
                failures += 1;

                if (failures == part_attempts) {
                    return reply;
                }

                offset = answer.bytes;
            },
            else => return reply,
        }

        if (name.len == 0 or offset > size) {
            return reply;
        }
    }

    if (!upload.json) {
        try upload.out.print("\n", .{});
        try upload.out.flush();
    }

    return last;
}

/// One part: `length` bytes from `reader` posted to `url`, its progress reported as part of
/// the whole upload; the answer.
fn post_part(
    io: std.Io,
    arena: std.mem.Allocator,
    upload: Upload,
    url: []const u8,
    reader: *std.Io.Reader,
    offset: u64,
    length: u64,
    size: u64,
) !Reply {
    std.debug.assert(offset + length <= size);

    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{upload.token});
    var request = try client.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{
                .override = "application/gzip",
            },
        },
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = bearer,
        }},
    });
    defer request.deinit();

    request.transfer_encoding = .{
        .content_length = length,
    };

    var body_buffer: [64 << 10]u8 = undefined;
    var body = try request.sendBodyUnflushed(&body_buffer);
    var sent: u64 = 0;

    while (sent < length) {
        const piece = @min(length - sent, upload.piece_bytes);

        try reader.streamExact64(&body.writer, piece);
        sent += piece;
        try report(upload, offset + sent, size);
    }

    try body.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    const status = response.head.status;
    var transfer: [64]u8 = undefined;
    const response_reader = response.reader(&transfer);
    const remaining = response_reader.allocRemaining(arena, .limited(answer_bytes_max));
    const answer = remaining catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };

    return .{
        .status = status,
        .body = answer,
    };
}

fn report(upload: Upload, done: u64, size: u64) !void {
    std.debug.assert(done <= size);

    if (upload.json) {
        try upload.out.print("{{\"stage\":\"uploading\",\"done\":{d},\"total\":{d}}}\n", .{ done, size });
    } else {
        try upload.out.print("\rUploading... {d}%", .{done * 100 / @max(size, 1)});
    }

    try upload.out.flush();
}

pub const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

/// The file at `path` posted as the body, read and sent a piece at a time with its length
/// declared, so a site of any size never sits in memory; the answer.
pub fn send(io: std.Io, arena: std.mem.Allocator, upload: Upload) !Reply {
    std.debug.assert(upload.url.len > 0);
    std.debug.assert(upload.piece_bytes > 0);

    var file = try std.Io.Dir.cwd().openFile(io, upload.path, .{});
    defer file.close(io);

    var file_buffer: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const size = try reader.getSize();
    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{upload.token});
    var request = try client.request(.POST, try std.Uri.parse(upload.url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{
                .override = "application/gzip",
            },
        },
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = bearer,
        }},
    });
    defer request.deinit();

    request.transfer_encoding = .{
        .content_length = size,
    };

    var body_buffer: [64 << 10]u8 = undefined;
    var body = try request.sendBodyUnflushed(&body_buffer);
    var sent: u64 = 0;

    while (sent < size) {
        const piece = @min(size - sent, upload.piece_bytes);

        try reader.interface.streamExact64(&body.writer, piece);
        sent += piece;
        try upload.out.print("\rUploading... {d}%", .{sent * 100 / size});
        try upload.out.flush();
    }

    try upload.out.print("\n", .{});
    try body.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    const status = response.head.status;
    var transfer: [64]u8 = undefined;
    const response_reader = response.reader(&transfer);
    const remaining = response_reader.allocRemaining(arena, .limited(answer_bytes_max));
    const answer = remaining catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };

    return .{
        .status = status,
        .body = answer,
    };
}
