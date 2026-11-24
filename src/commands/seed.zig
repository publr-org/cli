//! `publr --site <address> seed --type <type> --file <path> [--publish]`: a file on this
//! computer made into records on a Publr elsewhere, sent as `record create_many` calls of up
//! to 200 documents (fewer when they are large). The file is a JSON array of objects, or one
//! object a line. A site on this computer seeds itself: its own `publr seed` reads the file.

const std = @import("std");
const core = @import("../core.zig");

const file_bytes_max: u64 = 1 << 30;
/// A batch's documents together, kept well under what a request carries (1 MiB).
const batch_bytes_max: u32 = 512 << 10;
/// The most `record create_many` takes in one call.
const documents_max: u32 = 200;

const usage =
    \\usage: publr seed --type <type> --file <path> [--publish]
    \\
    \\Makes a record of the type from every document in the file: a JSON array of objects, or
    \\one object a line. Sent in batches of up to 200 (`record create_many`); each batch is all
    \\or nothing, and a refused one stops the seed, saying which document.
    \\
;

const Asked = struct {
    type: []const u8 = "",
    file: []const u8 = "",
    publish: bool = false,
};

/// Where `seed` is in the words: first, or after who runs it (`--as-admin`, `--as <who>`),
/// which every batch then carries. Null when the words are another command.
pub fn seed_at(words: []const []const u8) ?u32 {
    const at: u32 = if (words.len > 1 and std.mem.eql(u8, words[0], "--as-admin"))
        1
    else if (words.len > 2 and std.mem.eql(u8, words[0], "--as"))
        2
    else
        0;

    if (words.len > at and std.mem.eql(u8, words[at], "seed")) {
        return at;
    }

    return null;
}

/// The seed in `words` (`seed_at` found it) sent to `address` in batches.
pub fn run(
    init: std.process.Init,
    address: []const u8,
    env: ?[]const u8,
    words: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    const at = seed_at(words).?;
    const caller = words[0..at];
    const asked = parse(words[at + 1 ..]) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, asked.file, arena, limit) catch |err| {
        std.debug.print("publr seed: {s}: {t}\n", .{ asked.file, err });
        return 1;
    };
    const documents = try documents_of(arena, text) orelse {
        std.debug.print("publr seed: {s} is not a JSON array of objects, nor one object a line\n", .{
            asked.file,
        });
        return 1;
    };
    var start: u32 = 0;

    while (start < documents.len) {
        var state = std.heap.ArenaAllocator.init(init.gpa);
        defer state.deinit();

        const batch_arena = state.allocator();
        const end = batch_end(documents, start);
        var array: std.Io.Writer.Allocating = .init(batch_arena);

        try array.writer.writeByte('[');

        for (documents[start..end], 0..) |document, index| {
            if (index > 0) {
                try array.writer.writeByte(',');
            }

            try array.writer.writeAll(document);
        }

        try array.writer.writeByte(']');

        const command = [_][]const u8{
            "record",      "create_many",   "--type",    asked.type,
            "--documents", array.written(), "--publish", if (asked.publish) "true" else "false",
        };
        const batch = try std.mem.concat(batch_arena, []const u8, &.{ caller, &command });
        var answer: std.Io.Writer.Allocating = .init(batch_arena);
        const code = try core.remote.forward(init, address, batch, env, &answer.writer);

        if (code != 0) {
            std.debug.print("publr seed: the batch from document {d} was refused:\n{s}", .{
                start,
                answer.written(),
            });
            return code;
        }

        start = end;
        try out.print("Seeded {d} of {d}\n", .{ start, documents.len });
        try out.flush();
    }

    return 0;
}

fn parse(args: []const []const u8) ?Asked {
    var asked: Asked = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const valued = index + 1 < args.len;

        if (std.mem.eql(u8, arg, "--type") and valued) {
            index += 1;
            asked.type = args[index];
        } else if (std.mem.eql(u8, arg, "--file") and valued) {
            index += 1;
            asked.file = args[index];
        } else if (std.mem.eql(u8, arg, "--publish")) {
            asked.publish = true;
        } else {
            return null;
        }
    }

    return if (asked.type.len > 0 and asked.file.len > 0) asked else null;
}

/// Each document as its own JSON text; null when the text is neither shape.
fn documents_of(arena: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    if (trimmed.len == 0) {
        return null;
    }

    if (trimmed[0] == '[') {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch {
            return null;
        };

        if (parsed != .array) {
            return null;
        }

        const documents = try arena.alloc([]const u8, parsed.array.items.len);

        for (parsed.array.items, documents) |item, *document| {
            if (item != .object) {
                return null;
            }

            document.* = try std.json.Stringify.valueAlloc(arena, item, .{});
        }

        return documents;
    }

    var documents: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, trimmed, '\n');

    while (lines.next()) |line| {
        const document = std.mem.trim(u8, line, " \t\r");

        if (document.len == 0) {
            continue;
        }

        if (document[0] != '{') {
            return null;
        }

        try documents.append(arena, document);
    }

    return documents.items;
}

/// Where a batch from `start` ends: 200 documents, or fewer when they pass `batch_bytes_max`,
/// never none.
fn batch_end(documents: []const []const u8, start: u32) u32 {
    std.debug.assert(start < documents.len);

    var end = start;
    var bytes: u64 = 0;

    while (end < documents.len and end - start < documents_max) : (end += 1) {
        bytes += documents[end].len + 1;

        if (bytes > batch_bytes_max and end > start) {
            break;
        }
    }

    return end;
}

test "a seed file is an array, or one object a line, and goes in batches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(usize, 2), (try documents_of(arena, "[{\"a\":1},{\"a\":2}]")).?.len);
    try std.testing.expectEqual(@as(usize, 2), (try documents_of(arena, "{\"a\":1}\n\n{\"a\":2}\n")).?.len);
    try std.testing.expect(try documents_of(arena, "[1,2]") == null);

    const many = try arena.alloc([]const u8, 600);

    @memset(many, "{\"title\":\"x\"}");
    try std.testing.expectEqual(@as(u32, 200), batch_end(many, 0));
    try std.testing.expectEqual(@as(u32, 600), batch_end(many, 500));
    try std.testing.expectEqual(@as(?u32, 1), seed_at(&.{ "--as-admin", "seed", "--type", "post" }));
    try std.testing.expectEqual(@as(?u32, null), seed_at(&.{ "record", "list" }));
}
