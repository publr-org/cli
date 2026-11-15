//! A site in one file, `<name>.site.tar.gz`: a gzipped POSIX tar of what Publr's
//! `site export` writes into a folder (the manifest `publr-site.json` first, `data/`, `site/`).
//! The archive is the command's; what goes in it and what comes out of it is Publr's
//! (`site export`, `site import`), run by the site's own release.

const std = @import("std");

pub const extension = ".site.tar.gz";
pub const manifest_name = "publr-site.json";
/// The most a site may hold once unpacked; a larger archive is refused.
pub const bytes_max: u64 = 64 << 30;
const manifest_bytes_max: u32 = 64 << 10;
const copy_buffer_bytes: u32 = 64 << 10;
const entries_max: u32 = 1 << 24;

/// What the command reads of a manifest; Publr's own fields are left as they are.
pub const Manifest = struct {
    format: []const u8 = "",
    /// The Publr that made it.
    publr: []const u8 = "",
    name: []const u8 = "",
    /// The site's newest activity entry when it was made: a clone asks later whether the
    /// site moved past it.
    latest_change: i64 = 0,
    placeholders: []const []const u8 = &.{},
};

const Compressor = struct {
    window: [std.compress.flate.max_window_len]u8,
    compress: std.compress.flate.Compress,
};

pub const Written = struct {
    files: u32,
    /// Bytes before compression.
    bytes: u64,
};

pub const WriteOptions = struct {
    /// Faster and larger: for a clone or a push, mostly media compressed already.
    fast: bool = false,
};

/// The exported site in `folder` written to `out_path` as one archive, its manifest first.
pub fn write(
    io: std.Io,
    arena: std.mem.Allocator,
    folder: []const u8,
    out_path: []const u8,
    options: WriteOptions,
) !Written {
    std.debug.assert(folder.len > 0);
    std.debug.assert(out_path.len > 0);

    const cwd = std.Io.Dir.cwd();
    var root = try cwd.openDir(io, folder, .{
        .iterate = true,
    });
    defer root.close(io);

    const about = try root.readFileAlloc(io, manifest_name, arena, .limited(manifest_bytes_max));
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    errdefer cwd.deleteFile(io, out_path) catch |err| {
        std.log.warn("removing the unfinished {s}: {t}", .{ out_path, err });
    };

    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const compressor = try std.heap.page_allocator.create(Compressor);
    defer std.heap.page_allocator.destroy(compressor);

    const level: std.compress.flate.Compress.Options = if (options.fast) .fastest else .default;

    compressor.compress = try .init(&file_writer.interface, &compressor.window, .gzip, level);

    var tar: std.tar.Writer = .{
        .underlying_writer = &compressor.compress.writer,
    };
    var written: Written = .{
        .files = 1,
        .bytes = about.len,
    };

    try tar.writeFileBytes(manifest_name, about, .{});
    try add_tree(io, arena, root, &tar, &written);
    try tar.finishPedantically();
    try compressor.compress.finish();
    try file_writer.interface.flush();

    return written;
}

fn add_tree(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    tar: *std.tar.Writer,
    written: *Written,
) !void {
    var walker = try root.walk(arena);
    defer walker.deinit();

    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == entries_max) {
            return error.TooManyFiles;
        }

        if (entry.kind != .file) {
            continue;
        }

        const name = try arena.dupe(u8, entry.path);

        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');

        if (std.mem.eql(u8, name, manifest_name)) {
            continue;
        }

        var source = try root.openFile(io, entry.path, .{});
        defer source.close(io);
        var buffer: [copy_buffer_bytes]u8 = undefined;
        var reader = source.reader(io, &buffer);
        const size = try reader.getSize();

        try tar.writeFileStream(name, size, &reader.interface, .{});
        written.files += 1;
        written.bytes += size;
    }
}

/// The archive at `path` written out into `folder` (new or empty), as `site export` would
/// have left it. Refused for a link, a name that would land outside the folder, or more than
/// `bytes_max`; the folder is removed again when it is.
pub fn read(io: std.Io, arena: std.mem.Allocator, path: []const u8, folder: []const u8) !Manifest {
    std.debug.assert(path.len > 0);
    std.debug.assert(folder.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, folder);
    errdefer cwd.deleteTree(io, folder) catch |err| {
        std.log.warn("removing the unfinished {s}: {t}", .{ folder, err });
    };

    var root = try cwd.openDir(io, folder, .{});
    defer root.close(io);
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const window = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.heap.page_allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, window);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var entries: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var total: u64 = 0;

    while (try entries.next()) |entry| {
        if (entry.kind == .sym_link or !safe_name(entry.name)) {
            return error.InvalidArchive;
        }

        if (entry.kind == .directory) {
            try root.createDirPath(io, entry.name);
            continue;
        }

        total += entry.size;

        if (total > bytes_max) {
            return error.TooLarge;
        }

        if (std.fs.path.dirname(entry.name)) |parent| {
            try root.createDirPath(io, parent);
        }

        var out = try root.createFile(io, entry.name, .{
            .exclusive = true,
            .permissions = if (private(entry.name)) .fromMode(0o600) else .default_file,
        });
        defer out.close(io);
        var buffer: [copy_buffer_bytes]u8 = undefined;
        var writer = out.writer(io, &buffer);

        try entries.streamRemaining(entry, &writer.interface);
        try writer.interface.flush();
    }

    return manifest_in(io, arena, folder);
}

/// The manifest an exported folder holds.
pub fn manifest_in(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !Manifest {
    std.debug.assert(folder.len > 0);

    var root = try std.Io.Dir.cwd().openDir(io, folder, .{});
    defer root.close(io);

    const about = root.readFileAlloc(io, manifest_name, arena, .limited(manifest_bytes_max)) catch
        return error.NotASite;

    return std.json.parseFromSliceLeaky(Manifest, arena, about, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.NotASite;
}

/// The secrets' key stays its owner's alone, as it was.
fn private(name: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(name), "secret.key");
}

/// A relative name under `data/` or `site/` (or the manifest) with no part leading out.
pub fn safe_name(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return false;
    }

    var parts = std.mem.splitScalar(u8, name, '/');

    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            return false;
        }
    }

    return std.mem.eql(u8, name, manifest_name) or std.mem.startsWith(u8, name, "data/") or
        std.mem.startsWith(u8, name, "site/") or std.mem.eql(u8, name, "data") or
        std.mem.eql(u8, name, "site");
}

test "an archive's names stay inside the site" {
    try std.testing.expect(safe_name("publr-site.json"));
    try std.testing.expect(safe_name("data/publr.db"));
    try std.testing.expect(safe_name("site/apps/www/app.zon"));
    try std.testing.expect(!safe_name("/etc/passwd"));
    try std.testing.expect(!safe_name("data/../../x"));
    try std.testing.expect(!safe_name("other/file"));
    try std.testing.expect(!safe_name(""));
}

test "a folder written as an archive comes back the same" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;

    try scratch.dir.createDirPath(io, "out/data/media");
    try scratch.dir.createDirPath(io, "out/site");
    try scratch.dir.writeFile(io, .{
        .sub_path = "out/publr-site.json",
        .data = "{\"format\":\"publr-site\",\"publr\":\"0.6.4\",\"name\":\"shop\",\"latest_change\":7}",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "out/data/publr.db",
        .data = "database",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "out/site/publr.zon",
        .data = ".{}",
    });

    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const folder = try std.fs.path.join(arena, &.{ root, "out" });
    const file = try std.fs.path.join(arena, &.{ root, "shop.site.tar.gz" });
    const back = try std.fs.path.join(arena, &.{ root, "back" });
    const made = try write(io, arena, folder, file, .{});

    try std.testing.expectEqual(@as(u32, 3), made.files);

    const manifest = try read(io, arena, file, back);

    try std.testing.expectEqualStrings("0.6.4", manifest.publr);
    try std.testing.expectEqual(@as(i64, 7), manifest.latest_change);

    const database = try scratch.dir.readFileAlloc(io, "back/data/publr.db", arena, .limited(64));

    try std.testing.expectEqualStrings("database", database);
}
