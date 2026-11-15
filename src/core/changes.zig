//! Whether a clone's folder holds work of its own: a write to the site made here since it
//! came down (its Publr says its newest, `site state`), or a file of its apps, plugins or
//! `publr.zon` that differs from `.publr/base/`'s. The mark names that work, so a push can say
//! what it sent and the folder can tell later whether anything was made since. The release
//! pin in `publr.zon` is this computer's, never work: it is left out of the digest.

const std = @import("std");
const config_module = @import("config.zig");
const site_data = @import("site_data.zig");

const Config = config_module.Config;

const project_items = [_][]const u8{ "publr.zon", "apps", "plugins" };
const walk_entries_max: u32 = 1 << 20;
const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// The folder's own work as a short mark, empty for none: its newest write to the site past
/// `since` and its files' digest. Two marks are the same work exactly when they are equal.
pub fn mark(config: *const Config, publr: []const u8, folder: []const u8, since: i64) ![]const u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(since >= 0);

    const base = try std.fs.path.join(config.arena, &.{ folder, site_data.base_dir });
    const written = (try site_data.state(config, publr, folder, null)).latest_write;
    const own = try digest_of(config.io, config.arena, folder);
    const came = try digest_of(config.io, config.arena, base);

    if (written <= since and std.mem.eql(u8, &own, &came)) {
        return "";
    }

    const hex = std.fmt.bytesToHex(own[0..8], .lower);

    return std.fmt.allocPrint(config.arena, "{d}-{s}", .{ written, &hex });
}

const Entry = struct {
    path: []const u8,
    hash: Digest,

    fn before(_: void, left: Entry, right: Entry) bool {
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

/// One digest of the folder's apps, plugin sources and `publr.zon`, by name and content, in
/// name order; dot files and build output are not the site's, as an export leaves them.
fn digest_of(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Digest {
    std.debug.assert(root.len > 0);

    var entries: std.ArrayList(Entry) = .empty;

    for (project_items) |item| {
        const path = try std.fs.path.join(arena, &.{ root, item });
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        if (stat.kind == .directory) {
            try add_tree(io, arena, path, item, &entries);
        } else {
            try entries.append(arena, .{
                .path = item,
                .hash = try hash_project_file(io, arena, path),
            });
        }
    }

    std.mem.sort(Entry, entries.items, {}, Entry.before);

    var whole: std.crypto.hash.sha2.Sha256 = .init(.{});

    for (entries.items) |entry| {
        whole.update(entry.path);
        whole.update(&.{0});
        whole.update(&entry.hash);
    }

    return whole.finalResult();
}

fn add_tree(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    prefix: []const u8,
    entries: *std.ArrayList(Entry),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.basename[0] == '.' or std.mem.eql(u8, entry.basename, "zig-out")) {
            if (entry.kind == .directory) {
                walker.leave(io);
            }

            continue;
        }

        if (entry.kind != .file) {
            continue;
        }

        const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.path });

        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
        try entries.append(arena, .{
            .path = name,
            .hash = try hash_file(io, try std.fs.path.join(arena, &.{ root, entry.path })),
        });
    }
}

/// `publr.zon` without the release pin, which is this computer's and never work.
fn hash_project_file(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Digest {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const parts = without_pin(text);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    hasher.update(parts.head);
    hasher.update(parts.tail);

    return hasher.finalResult();
}

pub const Pinless = struct {
    head: []const u8,
    tail: []const u8,
};

/// `text` around its `.publr = "..."` line; nothing at all when the pin was all it held.
pub fn without_pin(text: []const u8) Pinless {
    const field = ".publr = \"";
    const at = std.mem.indexOf(u8, text, field) orelse return .{
        .head = text,
        .tail = "",
    };
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n') orelse 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    const head = text[0..line_start];
    const tail = text[line_end..];
    const bare_head = std.mem.trim(u8, head, " \t\r\n.{");
    const bare_tail = std.mem.trim(u8, tail, " \t\r\n}");

    if (bare_head.len == 0 and bare_tail.len == 0) {
        return .{
            .head = "",
            .tail = "",
        };
    }

    return .{
        .head = head,
        .tail = tail,
    };
}

fn hash_file(io: std.Io, path: []const u8) !Digest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var through: [16 << 10]u8 = undefined;
    var chunk: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &through);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);

        if (count == 0) {
            break;
        }

        hasher.update(chunk[0..count]);
    }

    return hasher.finalResult();
}

test "a release pin is never work" {
    const alone = without_pin(".{\n    .publr = \"0.6.4\",\n}\n");

    try std.testing.expectEqualStrings("", alone.head);
    try std.testing.expectEqualStrings("", alone.tail);

    const one = without_pin(".{\n    .publr = \"0.6.4\",\n    .name = \"shop\",\n}\n");
    const other = without_pin(".{\n    .publr = \"0.7.0\",\n    .name = \"shop\",\n}\n");

    try std.testing.expectEqualStrings(one.head, other.head);
    try std.testing.expectEqualStrings(one.tail, other.tail);
}
