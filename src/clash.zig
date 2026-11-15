//! The clash check (`.agents/specs/publr-cli.md`): the command's own names are a short fixed
//! list Publr never uses for anything else, except the commands moving out of Publr, which
//! Publr keeps only as stubs. Run before every release as part of `zig build test`.

const std = @import("std");
const main = @import("main.zig");

/// Publr's top-level words, kept by hand from `publr/src/main.zig` (`tool()` and the
/// `handles()` it calls), `publr/src/adapters/cli.zig` (the `init` alias), the SDK
/// namespaces in `publr/src/server/registry.zig` (`core_namespaces`) and the compiled-in
/// plugins in `publr/publr.zon`. A new word there goes here.
pub const publr_words = [_][]const u8{
    // Machine and tool commands.
    "serve",          "build",         "zig",            "agents",    "agent",
    "login",          "logout",        "whoami",         "skill",     "seed",
    "mcp",            "setup",         "new",            "clone-pack-run",
    "queue-run",      "update-run",    "cloud",          "clone",     "push",
    "pull",           "pack",          "unpack",         "db",        "backups",
    "restore",        "check-apps",    "check-plugins",  "init",
    // SDK namespaces.
    "activity",       "ai",            "apps",           "content_type",
    "custom_fields",  "design",        "device",         "errors",    "flow",
    "health",         "heartbeat",     "http",           "identity",  "internal",
    "job",            "media",         "mod",            "operation", "plugin",
    "project",        "provider",      "rail",           "record",    "removal",
    "role",           "secret",        "sign_on",        "snapshot",  "status",
    "taxonomy",       "term",          "trash",          "update",    "user",
    "view",           "webhook",
    // Compiled-in plugins' namespaces.
    "hello",          "environments",  "deployments",    "merge",     "ai_usage",
    "languages",      "currencies",    "language_pl",    "roles",
};

/// Publr's words that move to the command (the spec's "Moving out of Publr"), Publr keeping
/// only a stub that points here. `init` is Publr's alias for `project init`: the alias goes,
/// `project init` stays.
pub const moving_out = [_][]const u8{
    "new",   "clone",  "pull",   "push",  "pack",  "unpack", "cloud", "login", "logout",
    "whoami", "skill", "zig",    "mcp",   "setup", "init",
};

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |held| {
        if (std.mem.eql(u8, held, word)) {
            return true;
        }
    }

    return false;
}

/// The command's own words that Publr uses for something that is not moving out.
pub fn clashes(buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;

    inline for (@typeInfo(main.Command).@"enum".fields) |field| {
        const word = field.name;
        const flag = word[0] == '-';

        if (!flag and contains(&publr_words, word) and !contains(&moving_out, word)) {
            buffer[count] = word;
            count += 1;
        }
    }

    return buffer[0..count];
}

test "the command's own words never clash with Publr's" {
    var buffer: [64][]const u8 = undefined;
    const found = clashes(&buffer);

    for (found) |word| {
        std.debug.print("clash: `{s}` is Publr's and not moving out\n", .{word});
    }

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "`plugin` stays Publr's: only `plugin build` moves, as two words" {
    try std.testing.expect(!contains(&moving_out, "plugin"));
    try std.testing.expect(std.meta.stringToEnum(main.Command, "plugin") == null);
}
