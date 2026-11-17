//! The build-on-publr skill this command carries (`skills/build-on-publr/`), written into a
//! folder where agents that load skills find it. Every site's folder gets it when the site
//! starts, so an agent opened there has it, kept up to date with this command.
const std = @import("std");

pub const name = "build-on-publr";

/// The shared Agent Skills folder (Codex, Cursor, Pi and others read it) and Claude Code's,
/// which reads only its own.
pub const dirs_default = [_][]const u8{
    ".agents/skills/" ++ name,
    ".claude/skills/" ++ name,
};

pub const files = [_]struct {
    path: []const u8,
    text: []const u8,
}{
    .{
        .path = "SKILL.md",
        .text = @embedFile("skill"),
    },
    .{
        .path = "references/core-changes.md",
        .text = @embedFile("skill_core_changes"),
    },
};

/// The skill's files in `dir`, a path from the working folder or absolute.
pub fn write(io: std.Io, dir: []const u8) !void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(files.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, dir);

    var root = try cwd.openDir(io, dir, .{});
    defer root.close(io);

    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |sub| {
            try root.createDirPath(io, sub);
        }

        try root.writeFile(io, .{
            .sub_path = file.path,
            .data = file.text,
        });
    }
}

/// The skill in each of `folder`'s default places.
pub fn write_into(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !void {
    std.debug.assert(folder.len > 0);

    for (dirs_default) |dir| {
        try write(io, try std.fs.path.join(arena, &.{ folder, dir }));
    }
}

test "a folder gets the skill where Claude Code and the other agents read it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);

    try write_into(io, arena, root);
    try write_into(io, arena, root);

    for (dirs_default) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, "SKILL.md" });
        const text = try scratch.dir.readFileAlloc(io, path, arena, .limited(1 << 20));

        try std.testing.expectEqualStrings(files[0].text, text);
    }
}
