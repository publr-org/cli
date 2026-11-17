//! `publr skill`: the build-on-publr skill this command carries (`skills/build-on-publr/`).
//! What differs between Publr releases is in the guide each release carries (`publr agents`,
//! handed on to the site's Publr); the skill only says how to find and drive it. `publr skill install` writes it into
//! the folder, where agents that load skills find it: the Agent Skills folder most read
//! (`.agents/skills`) and Claude Code's, or the one agent named.
const std = @import("std");
const skill = @import("../core.zig").skill;

const skill_name = skill.name;

/// Where each agent reads a folder's skills from.
const agents = [_]struct {
    name: []const u8,
    dir: []const u8,
}{
    .{
        .name = "claude",
        .dir = ".claude/skills/" ++ skill_name,
    },
    .{
        .name = "codex",
        .dir = ".agents/skills/" ++ skill_name,
    },
    .{
        .name = "cursor",
        .dir = ".cursor/skills/" ++ skill_name,
    },
    .{
        .name = "pi",
        .dir = ".pi/skills/" ++ skill_name,
    },
};

const usage =
    \\usage: publr skill
    \\       publr skill install [--agent claude|codex|cursor|pi | --dir <path>]
    \\
;

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(skill.files.len > 0);

    if (args.len == 0) {
        try out.writeAll(skill.files[0].text);
        return 0;
    }

    if (!std.mem.eql(u8, args[0], "install") or (args.len != 1 and args.len != 3)) {
        std.debug.print(usage, .{});
        return 2;
    }

    const named = if (args.len == 3) dirs_of(args[1..]) else &skill.dirs_default;
    const dirs = named orelse {
        std.debug.print(usage, .{});
        return 2;
    };

    for (dirs) |dir| {
        try skill.write(init.io, dir);
        try out.print("{s} written to {s}/\n", .{ skill_name, dir });
    }

    return 0;
}

/// The one folder `--agent <name>` or `--dir <path>` names; null for anything else.
fn dirs_of(flag: []const []const u8) ?[]const []const u8 {
    std.debug.assert(flag.len == 2);
    std.debug.assert(agents.len > 0);

    if (flag[1].len == 0) {
        return null;
    }

    if (std.mem.eql(u8, flag[0], "--dir")) {
        return flag[1..2];
    }

    if (!std.mem.eql(u8, flag[0], "--agent")) {
        return null;
    }

    inline for (agents) |agent| {
        if (std.mem.eql(u8, flag[1], agent.name)) {
            return &.{agent.dir};
        }
    }

    return null;
}

test "an agent named gets its own folder, and nothing else is taken" {
    const claude = dirs_of(&.{ "--agent", "claude" }).?;
    const cursor = dirs_of(&.{ "--agent", "cursor" }).?;

    try std.testing.expectEqualStrings(".claude/skills/build-on-publr", claude[0]);
    try std.testing.expectEqualStrings(".cursor/skills/build-on-publr", cursor[0]);
    try std.testing.expectEqualStrings("here", dirs_of(&.{ "--dir", "here" }).?[0]);
    try std.testing.expect(dirs_of(&.{ "--agent", "copilot" }) == null);
    try std.testing.expect(dirs_of(&.{ "--dir", "" }) == null);
    try std.testing.expect(dirs_of(&.{ "--force", "x" }) == null);
}
