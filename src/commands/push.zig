//! `publr push`: the clone in this folder and its base exported by its Publr, archived and
//! sent up; the plugin that keeps copies makes a branch of them, reviewed and merged there.
//! Nothing local writes to live.

const std = @import("std");
const core = @import("../core.zig");
const pulling = @import("pull.zig");

const Config = core.Config;
const archive = core.archive;
const links = core.links;
const site_data = core.site_data;
const transfer = core.transfer;

const push_route = "/api/environments/push";
const push_dir = ".publr/push";
const upload_piece_bytes: u32 = 256 << 10;

pub fn run(
    init: std.process.Init,
    config: *const Config,
    out: *std.Io.Writer,
    rest: []const []const u8,
) !u8 {
    if (rest.len > 0) {
        std.debug.print("usage: publr push\n", .{});
        return 2;
    }

    var code: u8 = 0;
    var linked = try pulling.linked_here(init, config, &code) orelse return code;

    try pulling.ensure_base(config, &linked);

    // What is sent, named before exporting: work made while it goes up is not in it.
    const sent = try core.changes.mark(config, linked.publr, linked.folder, linked.link.since);

    if (sent.len == 0) {
        try out.print("Nothing to push: this folder is as {s} is\n", .{linked.link.site});
        return 0;
    }

    const arena = config.arena;
    const cwd = std.Io.Dir.cwd();
    const dir = try std.fs.path.join(arena, &.{ linked.folder, push_dir });

    try cwd.deleteTree(config.io, dir);
    try cwd.createDirPath(config.io, dir);
    defer cwd.deleteTree(config.io, dir) catch |err| {
        std.log.debug("removing {s}: {t}", .{ dir, err });
    };

    const base = try std.fs.path.join(arena, &.{ linked.folder, site_data.base_dir });
    const packed_site = try pack_part(config, linked.publr, linked.folder, dir, "site", true);
    const packed_base = try pack_part(config, linked.publr, base, dir, "base", false);

    if (try send_part(config, out, linked, "base", packed_base) == null) {
        return 1;
    }

    const answer = try send_part(config, out, linked, "site", packed_site) orelse return 1;
    const Pushed = struct {
        name: []const u8,
        address: []const u8 = "",
        merge: []const u8 = "",
    };
    const pushed = try std.json.parseFromSliceLeaky(Pushed, arena, answer, .{
        .ignore_unknown_fields = true,
    });

    // A site that does not know its admin's address names only the path.
    const merge = if (std.mem.startsWith(u8, pushed.merge, "/"))
        try std.fmt.allocPrint(arena, "{s}{s}", .{ linked.site.address, pushed.merge })
    else
        pushed.merge;

    linked.link.branch = pushed.name;
    linked.link.pushed = sent;
    try links.write_clone(config, linked.folder, linked.link);
    try out.print("Pushed as the branch {s}\n  Preview  {s}\n" ++
        "  Merge    {s}  (a person reviews it)\n", .{
        pushed.name,
        pushed.address,
        merge,
    });

    return 0;
}

/// The site in `folder` exported as a clone and archived as `<dir>/<part>.site.tar.gz`. For
/// the folder itself, a placeholder still there goes up as it came down: left out, so the
/// branch keeps the live file.
fn pack_part(
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    dir: []const u8,
    part: []const u8,
    leave_placeholders: bool,
) ![]const u8 {
    const arena = config.arena;
    const exported = try std.fs.path.join(arena, &.{ dir, part });
    const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ exported, archive.extension });
    var options: site_data.ExportOptions = .{
        .clone = true,
    };

    if (leave_placeholders) {
        const kept = try site_data.placeholders_kept(config, folder);

        if (kept.len > 0) {
            const list = try std.fmt.allocPrint(arena, "{s}.placeholders", .{exported});
            var text: std.Io.Writer.Allocating = .init(arena);

            for (kept) |key| {
                try text.writer.print("{s}\n", .{key});
            }

            try std.Io.Dir.cwd().writeFile(config.io, .{
                .sub_path = list,
                .data = text.written(),
            });
            options.placeholders = list;
        }
    }

    try site_data.export_to(config, publr, folder, exported, options);
    _ = try archive.write(config.io, arena, exported, file, .{
        .fast = true,
    });

    return file;
}

/// One archive uploaded; its answer, or null having said why it was refused.
fn send_part(
    config: *const Config,
    out: *std.Io.Writer,
    linked: pulling.Linked,
    part: []const u8,
    path: []const u8,
) !?[]const u8 {
    const arena = config.arena;
    const reply = try transfer.send(config.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}?name={s}&part={s}", .{
            linked.sync.address,
            push_route,
            linked.link.branch,
            part,
        }),
        .token = linked.site.token,
        .path = path,
        .piece_bytes = upload_piece_bytes,
        .out = out,
    });

    if (reply.status != .ok and reply.status != .created) {
        std.debug.print("publr push: {s} answered {d}: {s}\n", .{
            linked.site.address,
            @intFromEnum(reply.status),
            reply.body,
        });
        return null;
    }

    return reply.body;
}
