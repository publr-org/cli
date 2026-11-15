//! The command's own place: `config.zon` in the system's folder for app settings, with the
//! Publr releases kept (`versions/`), the sign-on key and the helper's log beside it. It says
//! where new sites go (the default folder) and which other folders hold sites.

const std = @import("std");
const builtin = @import("builtin");

pub const file_name = "config.zon";
pub const folders_max: u32 = 64;
pub const path_len_max: u32 = 1024;
const file_bytes_max: u32 = 256 << 10;
const default_folder_name = "Publr";

pub const Config = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    /// The system's folder for this command's things, absolute.
    root: []const u8,
    /// Where `new` and `clone` put sites: `~/Publr` unless changed.
    folder: []const u8,
    /// The other entries: folders of sites, and single sites' own folders.
    folders: []const []const u8,
    /// The Publr workspace (the folder with `workspace.zon`), for `versions use workspace`.
    workspace: []const u8,
    /// No `config.zon` was there: the command's first run on this computer.
    fresh: bool = false,

    /// Read, or made with the defaults the first time. Everything it holds is in `arena`.
    pub fn load(
        io: std.Io,
        arena: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
    ) !Config {
        const root = try root_of(arena, environ);
        const home = environ.get("HOME") orelse return error.NoHome;
        var config: Config = .{
            .io = io,
            .arena = arena,
            .environ = environ,
            .root = root,
            .folder = try std.fs.path.join(arena, &.{ home, default_folder_name }),
            .folders = &.{},
            .workspace = "",
        };

        try std.Io.Dir.cwd().createDirPath(io, root);

        const file_path = try config.path(&.{file_name});
        const text = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            file_path,
            arena,
            .limited(file_bytes_max),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                config.fresh = true;
                return config;
            },
            else => return err,
        };
        const File = struct {
            folder: []const u8 = "",
            folders: []const []const u8 = &.{},
            workspace: []const u8 = "",
        };
        const file = std.zon.parse.fromSliceAlloc(File, arena, text, null, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.debug.print("publr: {s} is not readable; fix or remove it\n", .{file_path});
            return error.BadConfig;
        };

        if (file.folder.len > 0) {
            config.folder = file.folder;
        }

        config.folders = file.folders;
        config.workspace = file.workspace;

        return config;
    }

    pub fn save(config: *const Config) !void {
        std.debug.assert(config.folder.len > 0);
        std.debug.assert(config.folders.len <= folders_max);

        var out: std.Io.Writer.Allocating = .init(config.arena);
        const writer = &out.writer;

        try writer.writeAll(".{\n");
        try writer.print("    .folder = \"{f}\",\n", .{std.zig.fmtString(config.folder)});
        try writer.writeAll("    .folders = .{\n");

        for (config.folders) |folder| {
            try writer.print("        \"{f}\",\n", .{std.zig.fmtString(folder)});
        }

        try writer.writeAll("    },\n");
        try writer.print("    .workspace = \"{f}\",\n", .{std.zig.fmtString(config.workspace)});
        try writer.writeAll("}\n");

        try std.Io.Dir.cwd().writeFile(config.io, .{
            .sub_path = try config.path(&.{file_name}),
            .data = out.written(),
        });
    }

    /// A path inside the command's own folder.
    pub fn path(config: *const Config, parts: []const []const u8) ![]const u8 {
        std.debug.assert(parts.len > 0);
        std.debug.assert(config.root.len > 0);

        var all: std.ArrayList([]const u8) = .empty;

        try all.append(config.arena, config.root);
        try all.appendSlice(config.arena, parts);

        return std.fs.path.join(config.arena, all.items);
    }

    /// Every entry: the default folder first, then the others as listed.
    pub fn entries(config: *const Config) ![]const []const u8 {
        var all: std.ArrayList([]const u8) = .empty;

        try all.append(config.arena, config.folder);

        for (config.folders) |folder| {
            if (!std.mem.eql(u8, folder, config.folder)) {
                try all.append(config.arena, folder);
            }
        }

        return all.items;
    }

    /// `folder` added to the list, once; false when it was there already.
    pub fn add(config: *Config, folder: []const u8) !bool {
        std.debug.assert(std.fs.path.isAbsolute(folder));

        const clean = std.mem.trimEnd(u8, folder, "/");

        for (try config.entries()) |held| {
            if (std.mem.eql(u8, held, clean)) {
                return false;
            }
        }

        if (config.folders.len == folders_max) {
            return error.TooManyFolders;
        }

        var all: std.ArrayList([]const u8) = .empty;

        try all.appendSlice(config.arena, config.folders);
        try all.append(config.arena, try config.arena.dupe(u8, clean));
        config.folders = all.items;

        return true;
    }

    /// `folder` taken off the list; false when it was not on it.
    pub fn remove(config: *Config, folder: []const u8) !bool {
        const clean = std.mem.trimEnd(u8, folder, "/");
        var all: std.ArrayList([]const u8) = .empty;
        var found = false;

        for (config.folders) |held| {
            if (std.mem.eql(u8, held, clean)) {
                found = true;
            } else {
                try all.append(config.arena, held);
            }
        }

        config.folders = all.items;

        return found;
    }
};

/// `$PUBLR_CONFIG`, else the system's place: `~/Library/Application Support/Publr` (macOS),
/// `$XDG_CONFIG_HOME/publr` or `~/.config/publr` (Linux).
pub fn root_of(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("PUBLR_CONFIG")) |given| {
        if (given.len > 0) {
            return given;
        }
    }

    const home = environ.get("HOME") orelse return error.NoHome;

    std.debug.assert(home.len > 0);

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(arena, &.{ home, "Library", "Application Support", "Publr" }),
        else => if (environ.get("XDG_CONFIG_HOME")) |xdg|
            std.fs.path.join(arena, &.{ xdg, "publr" })
        else
            std.fs.path.join(arena, &.{ home, ".config", "publr" }),
    };
}
