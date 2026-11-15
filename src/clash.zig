//! The clash check (`.agents/specs/publr-cli.md`): the command's own names are a short fixed
//! list Publr never uses. Run before every release as part of `zig build test`.

const std = @import("std");
const main = @import("main.zig");

/// Publr's top-level words, kept by hand from `publr/src/main.zig` (`tool()` and the
/// `handles()` it calls), the SDK namespaces in `publr/src/server/registry.zig`
/// (`core_namespaces`) and the compiled-in plugins in `publr/publr.zon`. A new word there
/// goes here.
pub const publr_words = [_][]const u8{
    // Machine commands.
    "serve",          "build",        "agents",       "agent",         "seed",
    "clone-pack-run", "queue-run",    "update-run",   "site",          "db",
    "backups",        "restore",      "check-apps",   "check-plugins",
    // SDK namespaces.
    "activity",
    "ai",             "apps",         "content_type", "custom_fields", "design",
    "device",         "errors",       "flow",         "health",        "heartbeat",
    "http",           "identity",     "internal",     "job",           "media",
    "mod",            "operation",    "plugin",       "project",       "provider",
    "rail",           "record",       "removal",      "role",          "secret",
    "sign_on",        "snapshot",     "status",       "taxonomy",      "term",
    "trash",          "update",       "user",         "view",          "webhook",
    // Compiled-in plugins' namespaces.
    "hello",          "environments", "deployments",  "merge",         "ai_usage",
    "languages",      "currencies",   "language_pl",  "roles",
};

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |held| {
        if (std.mem.eql(u8, held, word)) {
            return true;
        }
    }

    return false;
}

/// The command's own words that Publr uses too.
pub fn clashes(buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;

    inline for (@typeInfo(main.Command).@"enum".field_names) |word| {
        const flag = word[0] == '-';

        if (!flag and contains(&publr_words, word)) {
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
        std.debug.print("clash: `{s}` is Publr's too\n", .{word});
    }

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "`plugin` stays Publr's: only `plugin build` is the command's, as two words" {
    try std.testing.expect(contains(&publr_words, "plugin"));
    try std.testing.expect(std.meta.stringToEnum(main.Command, "plugin") == null);
}
