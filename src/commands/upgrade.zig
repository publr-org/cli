//! `publr upgrade <name>...`: each site moved to the release Publr Cloud runs (`core/update.zig`).
//! `--check` says what it would do and changes nothing; `--yes` agrees to what a repair keeps
//! aside, which is otherwise asked (or, without a terminal to ask on, refused).

const std = @import("std");
const core = @import("../core.zig");

const Config = core.Config;
const Site = core.Site;
const upgrade = core.upgrade;
const compat = core.compat;

pub const Flags = struct {
    check: bool = false,
    yes: bool = false,
};

pub fn run(config: *const Config, out: *std.Io.Writer, sites: []Site, flags: Flags) !u8 {
    var failed: u8 = 0;

    for (sites) |*site| {
        one(config, out, site, flags) catch |err| {
            try out.print("{s}: not updated ({s})\n", .{ site.name, reason_of(err) });
            failed = 1;
        };
        try out.flush();
    }

    return failed;
}

fn one(config: *const Config, out: *std.Io.Writer, site: *Site, flags: Flags) !void {
    const chosen = try upgrade.plan(config, site.*);
    const from = chosen.version.runs;

    if (!chosen.needed()) {
        try out.print("{s}: up to date (Publr {s})\n", .{ site.name, chosen.to });
        return;
    }

    try out.print("{s}: {s}{s} to Publr {s}\n", .{
        site.name,
        if (std.mem.eql(u8, from, compat.development)) "" else "Publr ",
        from,
        chosen.to,
    });

    if (chosen.repair) {
        try out.print("  Cloud's Publr cannot open its database as it is; it is repaired:\n", .{});

        for (chosen.changes) |line| try out.print("    {s}\n", .{line});
    }

    for (chosen.left_out) |line| try out.print("  kept aside, in the backup: {s}\n", .{line});

    if (flags.check) {
        return;
    }

    const agreed = flags.yes or chosen.left_out.len == 0 or try ask(config, out);

    try upgrade.run(config, site, chosen, .{
        .accept_left_out = agreed,
    });
    try out.print("{s}: now runs Publr {s}\n", .{ site.name, chosen.to });
}

/// Whether the person agrees, asked on the terminal; no terminal is no.
fn ask(config: *const Config, out: *std.Io.Writer) !bool {
    const stdin = std.Io.File.stdin();

    if (!(stdin.isTty(config.io) catch false)) {
        return false;
    }

    try out.print("Keep those aside and update? [y/N] ", .{});
    try out.flush();

    var buffer: [16]u8 = undefined;
    var reader = stdin.reader(config.io, &buffer);
    const answer = reader.interface.takeDelimiterExclusive('\n') catch return false;

    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

fn reason_of(err: anyerror) []const u8 {
    return switch (err) {
        error.ChosenForAll => "every site runs the Publr chosen with `publr config publr`; " ++
            "`publr config publr --unset` first",
        error.RepairUnavailable => "Cloud's Publr cannot repair it yet; a later release can",
        error.RepairRefused => "its database cannot be repaired, see above",
        error.NeedsConsent => "something would be kept aside: run it again with --yes to agree",
        else => @errorName(err),
    };
}
