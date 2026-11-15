//! `publr pack [<file>]` and `publr unpack <file>`: the site in this folder as one archive,
//! and back. The site's own Publr exports it and takes it in (`site export`, `site import`);
//! the archive around that is the command's.

const std = @import("std");
const core = @import("../core.zig");

const Config = core.Config;
const archive = core.archive;
const site_data = core.site_data;
const versions = core.versions;

pub const usage =
    \\usage: publr pack [<file>]     the site in this folder as one file
    \\       publr unpack <file>     a packed site written into this folder, which has none
    \\
;

/// `pack [<file>]`, run in a site's folder.
pub fn pack(config: *const Config, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len > 1) {
        std.debug.print("{s}", .{usage});
        return 2;
    }

    const folder = try here_site(config) orelse return 1;
    const site = try core.sites.load(config, folder, folder);
    const publr = try versions.binary_for(config, site);
    const file = if (rest.len == 1)
        try core.sites.absolute(config, rest[0])
    else
        try core.sites.absolute(config, try std.fmt.allocPrint(config.arena, "{s}{s}", .{
            std.fs.path.basename(folder),
            archive.extension,
        }));
    const exported = try site_data.scratch_beside(config, folder, "pack");
    defer std.Io.Dir.cwd().deleteTree(config.io, exported) catch |err| {
        std.log.warn("removing {s}: {t}", .{ exported, err });
    };

    try site_data.export_to(config, publr, folder, exported, .{});

    const made = try archive.write(config.io, config.arena, exported, file, .{});
    const stat = try std.Io.Dir.cwd().statFile(config.io, file, .{});

    try out.print("Packed {s}: {d} files, {d} KiB ({d} KiB unpacked)\n", .{
        file,
        made.files,
        stat.size / 1024,
        made.bytes / 1024,
    });

    return 0;
}

/// `unpack <file>`: into this folder, made a site pinned to the release that packed it,
/// unless it pins one already.
pub fn unpack(config: *const Config, out: *std.Io.Writer, rest: []const []const u8) !u8 {
    if (rest.len != 1) {
        std.debug.print("{s}", .{usage});
        return 2;
    }

    const file = try core.sites.absolute(config, rest[0]);
    const folder = try std.process.currentPathAlloc(config.io, config.arena);
    const unpacked = try site_data.scratch_beside(config, folder, "unpack");
    defer std.Io.Dir.cwd().deleteTree(config.io, unpacked) catch |err| {
        std.log.warn("removing {s}: {t}", .{ unpacked, err });
    };

    const manifest = archive.read(config.io, config.arena, file, unpacked) catch |err| {
        std.debug.print("publr unpack: {s}: {s}\n", .{ file, refusal(err) });
        return 1;
    };
    const publr = try binary_here(config, folder, manifest.publr);

    try site_data.import_from(config, publr, folder, unpacked, .{});

    if (try versions.pin_of(config, folder) == null and try versions.own_binary(config, folder) == null) {
        try versions.set_pin(config, folder, manifest.publr);
    }

    try out.print("Unpacked {s} (packed by Publr {s}) into {s}\n", .{
        manifest.name,
        manifest.publr,
        folder,
    });

    return 0;
}

/// The Publr to take a site in with: the folder's own when it is a site already, else the
/// release that packed it.
fn binary_here(config: *const Config, folder: []const u8, packed_by: []const u8) ![]const u8 {
    if (core.sites.is_site(config.io, config.arena, folder)) {
        const site = try core.sites.load(config, folder, folder);

        if (versions.binary_for(config, site)) |found| {
            return found;
        } else |_| {}
    }

    return versions.kept(config, packed_by);
}

fn refusal(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArchive => "it holds a link or a name outside the site",
        error.TooLarge => "it is larger than a site may be",
        error.NotASite => "it is not a packed site",
        else => @errorName(err),
    };
}

/// The site around this folder, or null having said so.
pub fn here_site(config: *const Config) !?[]const u8 {
    const here = try std.process.currentPathAlloc(config.io, config.arena);

    return try core.sites.around(config.io, config.arena, here) orelse {
        std.debug.print("publr: no site here; run it in a site's folder\n", .{});
        return null;
    };
}
