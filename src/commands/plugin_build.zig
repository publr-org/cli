//! `publr plugin build --name <n> [--dir <folder>] [--with <x.wasm>]... [--out <file>]`: a
//! sandboxed plugin's source built by the compiler the command carries, against the SDK and
//! recipe of the Publr it goes to, then checked and installed by that Publr. The steps:
//! Publr's `plugin prepare` (the SDK, docs, views, published interfaces, the compiler's
//! arguments), the compiler, Publr's `plugin check --file` (the manifest written in, the
//! examples run), then `plugin add` and `plugin enable` for a new plugin or `plugin update`
//! for its next version. For a local site that Publr is the site's own; for a site elsewhere
//! (`--site`, `PUBLR_SITE`, `.publr/site`) it is a copy of the release that site runs, and
//! the module goes up in pieces. Every other `plugin` command is Publr's, handed on.

const std = @import("std");
const core = @import("../core.zig");
const toolchain = @import("toolchain.zig");

const Config = core.Config;
const versions = core.versions;

/// Raw bytes per piece: base64 of it stays well under `/api/cli`'s 1 MiB body.
const piece_bytes_max: u32 = 384 << 10;
const module_bytes_max: u32 = 16 << 20;
const answer_bytes_max: u32 = 16 << 20;
const interfaces_page: u32 = 200;
const interfaces_pages_max: u32 = 3;

pub const Request = struct {
    name: []const u8,
    /// The plugin's folder, as given (`plugins/<name>` by default).
    dir: ?[]const u8 = null,
    /// Only build, into this file: nothing is installed.
    out: ?[]const u8 = null,
    with: []const []const u8 = &.{},
};

/// `plugin build` without `--files` (the operation that takes the sources in the command,
/// Publr's) and `--help`.
pub fn handles(words: []const []const u8) bool {
    if (words.len < 2 or !std.mem.eql(u8, words[0], "plugin") or !std.mem.eql(u8, words[1], "build")) {
        return false;
    }

    for (words[2..]) |word| {
        if (std.mem.eql(u8, word, "--files") or std.mem.eql(u8, word, "--help")) {
            return false;
        }
    }

    return true;
}

pub fn parse(arena: std.mem.Allocator, args: []const []const u8) ?Request {
    var request: Request = .{
        .name = "",
    };
    var with: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;

    while (index + 1 < args.len) : (index += 2) {
        const flag = args[index];
        const value = args[index + 1];

        if (std.mem.eql(u8, flag, "--name")) {
            request.name = value;
        } else if (std.mem.eql(u8, flag, "--dir")) {
            request.dir = value;
        } else if (std.mem.eql(u8, flag, "--out")) {
            request.out = value;
        } else if (std.mem.eql(u8, flag, "--with")) {
            with.append(arena, value) catch return null;
        } else {
            return null;
        }
    }

    if (index != args.len or request.name.len == 0) {
        return null;
    }

    request.with = with.items;

    return request;
}

const usage = "usage: publr plugin build --name <name> [--dir <folder>] [--with <x.wasm>]... " ++
    "[--out <file>]\n";

/// `address` names a site elsewhere; null builds for the site around this folder.
pub fn run(
    init: std.process.Init,
    config: *const Config,
    address: ?[]const u8,
    env: ?[]const u8,
    args: []const []const u8,
) !u8 {
    const arena = config.arena;
    const request = parse(arena, args) orelse {
        std.debug.print(usage, .{});
        return 2;
    };

    if (address != null and request.out != null) {
        std.debug.print("publr plugin build: --out builds here; leave out --site\n", .{});
        return 2;
    }

    const here = try std.process.currentPathAlloc(init.io, arena);
    const around = try core.sites.around(init.io, arena, here);

    if (address == null and around == null and request.out == null) {
        std.debug.print("publr plugin build: run it in a site's folder, name a site elsewhere " ++
            "with --site, or build to a file with --out\n", .{});
        return 2;
    }

    // Where Publr runs: the site's folder, or for a site elsewhere and a build to a file
    // outside every site, a folder emptied for each build, so no database there poses as a
    // site of its own.
    const base = around orelse here;
    const dir = try core.sites.absolute(config, request.dir orelse
        try std.fs.path.join(arena, &.{ base, "plugins", request.name }));
    const work = if (around) |folder|
        try std.fs.path.join(arena, &.{ folder, "data", "builds", request.name })
    else
        try std.fs.path.join(arena, &.{ here, ".publr", "builds", request.name });
    const publr = if (address) |site|
        try release_of(init, config, site, env)
    else if (around) |folder|
        try versions.binary_for(config, try core.sites.load(config, folder, folder))
    else
        versions.chosen_for_all(config) orelse try versions.kept(config, try newest_kept(config));
    const runs_in = if (address == null and around != null)
        around.?
    else
        try std.fmt.allocPrint(arena, "{s}.run", .{work});
    const cwd = std.Io.Dir.cwd();

    try cwd.deleteTree(init.io, work);

    if (!std.mem.eql(u8, runs_in, base)) {
        try cwd.deleteTree(init.io, runs_in);
    }

    try cwd.createDirPath(init.io, runs_in);

    var prepare: std.ArrayList([]const u8) = .empty;

    try prepare.appendSlice(arena, &.{ "plugin", "prepare", "--name", request.name, "--dir", dir, "--out", work });

    for (request.with) |file| {
        try prepare.appendSlice(arena, &.{ "--with", try core.sites.absolute(config, file) });
    }

    if (address) |site| {
        const listing = try std.fs.path.join(arena, &.{ runs_in, "interfaces.json" });

        if (!try interfaces_of(init, site, env, listing)) {
            return 1;
        }

        try prepare.appendSlice(arena, &.{ "--interfaces", listing });
    }

    const prepared = try publr_output(init, config, publr, runs_in, prepare.items) orelse return 1;
    const Plan = struct {
        args: []const []const u8,
        module: []const u8,
        views: ?[]const u8 = null,
        dir: []const u8,
    };
    const plan = std.json.parseFromSliceLeaky(Plan, arena, prepared, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("publr plugin build: `plugin prepare` answered what this command " ++
            "does not read; is the site's Publr older than `plugin prepare`?\n", .{});
        return 1;
    };
    const tools = toolchain.unpack(init) catch |err| {
        std.debug.print("publr plugin build: the compiler could not be written out ({t}); " ++
            "set PUBLR_CACHE_DIR to a writable folder\n", .{err});
        return 1;
    };

    if (try toolchain.compile(init, tools, plan.args) != 0) {
        return 1;
    }

    var check: std.ArrayList([]const u8) = .empty;

    try check.appendSlice(arena, &.{ "plugin", "check", "--file", plan.module, "--dir", plan.dir });

    if (plan.views) |views| {
        try check.appendSlice(arena, &.{ "--views", views });
    }

    for (request.with) |file| {
        try check.appendSlice(arena, &.{ "--with", try core.sites.absolute(config, file) });
    }

    if (request.out == null) {
        try check.append(arena, "--types");
    }

    if (try publr_run(init, publr, runs_in, check.items, null) != 0) {
        return 1;
    }

    if (request.out) |file| {
        const target = try core.sites.absolute(config, file);

        try cwd.createDirPath(init.io, std.fs.path.dirname(target) orelse ".");
        try cwd.copyFile(plan.module, cwd, target, init.io, .{});
        std.debug.print("built {s}\n", .{target});
        return 0;
    }

    if (address) |site| {
        return install_there(init, site, env, request.name, plan.module);
    }

    return install_here(init, config, publr, runs_in, request.name, plan.module);
}

fn newest_kept(config: *const Config) ![]const u8 {
    const kept = try versions.list(config);

    return if (kept.len > 0) kept[kept.len - 1] else versions.newest(config);
}

/// The release the site at `address` runs (its `heartbeat check`), kept here.
fn release_of(
    init: std.process.Init,
    config: *const Config,
    address: []const u8,
    env: ?[]const u8,
) ![]const u8 {
    var answer: std.Io.Writer.Allocating = .init(config.arena);

    if (try core.remote.forward(init, address, &.{ "heartbeat", "check" }, env, &answer.writer) != 0) {
        return error.SiteUnavailable;
    }

    const Heartbeat = struct {
        version: []const u8,
    };
    const heartbeat = std.json.parseFromSliceLeaky(Heartbeat, config.arena, answer.written(), .{
        .ignore_unknown_fields = true,
    }) catch return error.SiteUnavailable;

    return versions.kept(config, heartbeat.version);
}

/// Every plugin interface the site elsewhere answers (`plugin interfaces`, a page at a time)
/// written to `path` as one listing, for `plugin prepare --interfaces`. False, having said
/// why, when the site did not answer.
fn interfaces_of(
    init: std.process.Init,
    address: []const u8,
    env: ?[]const u8,
    path: []const u8,
) !bool {
    const arena = init.arena.allocator();
    var all: std.ArrayList(std.json.Value) = .empty;
    var page: u32 = 0;

    while (page < interfaces_pages_max) : (page += 1) {
        var answer: std.Io.Writer.Allocating = .init(arena);
        const offset = try std.fmt.allocPrint(arena, "{d}", .{page * interfaces_page});
        const limit = try std.fmt.allocPrint(arena, "{d}", .{interfaces_page});
        const words = [_][]const u8{ "plugin", "interfaces", "--limit", limit, "--offset", offset };

        if (try core.remote.forward(init, address, &words, env, &answer.writer) != 0) {
            std.debug.print("publr plugin build: the site did not list its plugins' interfaces\n", .{});
            return false;
        }

        const Page = struct {
            interfaces: []const std.json.Value = &.{},
            more: bool = false,
        };
        const parsed = std.json.parseFromSliceLeaky(Page, arena, answer.written(), .{
            .ignore_unknown_fields = true,
        }) catch {
            std.debug.print("publr plugin build: the site's interfaces could not be read\n", .{});
            return false;
        };

        try all.appendSlice(arena, parsed.interfaces);

        if (!parsed.more) {
            break;
        }
    }

    const listing = try std.json.Stringify.valueAlloc(arena, .{
        .interfaces = all.items,
    }, .{});

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(path) orelse ".");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = listing,
    });

    return true;
}

/// A Publr command in `folder`, its output; null, its errors printed, when it failed.
fn publr_output(
    init: std.process.Init,
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    args: []const []const u8,
) !?[]const u8 {
    var answer: std.Io.Writer.Allocating = .init(config.arena);

    if (try publr_run(init, publr, folder, args, &answer.writer) != 0) {
        return null;
    }

    return answer.written();
}

/// A Publr command in `folder`: its stderr passed through as it comes, its stdout into
/// `into` (or passed through when null); its exit code.
fn publr_run(
    init: std.process.Init,
    publr: []const u8,
    folder: []const u8,
    args: []const []const u8,
    into: ?*std.Io.Writer,
) !u8 {
    std.debug.assert(args.len > 0);

    const arena = init.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.append(arena, publr);
    try argv.appendSlice(arena, args);

    var child = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .cwd = .{
            .path = folder,
        },
        .stdin = .ignore,
        .stdout = if (into == null) .inherit else .pipe,
        .stderr = .inherit,
    });

    if (into) |writer| {
        var buffer: [16 << 10]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(init.io, &buffer);

        _ = try reader.interface.streamRemaining(writer);
    }

    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 1,
    };
}

/// `plugin add` as the site's operator, then `plugin enable` for a new plugin or `plugin
/// update` for its next version; nothing when the installed one is this very module. In the
/// running server when one runs, so the new version is live when this returns.
fn install_here(
    init: std.process.Init,
    config: *const Config,
    publr: []const u8,
    folder: []const u8,
    name: []const u8,
    module: []const u8,
) !u8 {
    const arena = config.arena;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, module, arena, .limited(module_bytes_max));
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);
    const listed = try std.fmt.allocPrint(arena, "\"name\": \"{s}\"", .{name});
    const hashed = try std.fmt.allocPrint(arena, "\"hash\": \"{s}\"", .{&hex});
    const plugins = try publr_output(init, config, publr, folder, &.{ "--as-admin", "plugin", "list" }) orelse return 1;

    // Asked only once the plugin is there: `plugin get` reports a missing one as an error.
    if (std.mem.indexOf(u8, plugins, listed) != null) {
        const installed = try publr_output(init, config, publr, folder, &.{ "--as-admin", "plugin", "get", "--name", name });

        if (installed) |text| {
            if (std.mem.indexOf(u8, text, hashed) != null) {
                std.debug.print("{s} is up to date\n", .{name});
                return 0;
            }
        }
    }

    const added = try publr_output(init, config, publr, folder, &.{ "--as-admin", "plugin", "add", "--file", module }) orelse return 1;
    const update = std.mem.indexOf(u8, added, "\"update\": true") != null;
    const next: []const []const u8 = if (update)
        &.{ "--as-admin", "plugin", "update", "--name", name }
    else
        &.{ "--as-admin", "plugin", "enable", "--names", name };

    return publr_run(init, publr, folder, next, null);
}

/// The module sent to the site elsewhere as `plugin upload` pieces, then enabled when new or
/// applied when it was there.
fn install_there(
    init: std.process.Init,
    address: []const u8,
    env: ?[]const u8,
    name: []const u8,
    module: []const u8,
) !u8 {
    const arena = init.arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, module, arena, .limited(module_bytes_max));
    const encoder = std.base64.standard.Encoder;
    const file = try std.fmt.allocPrint(arena, "{s}.wasm", .{name});
    const encoded = try arena.alloc(u8, encoder.calcSize(piece_bytes_max));
    const whole: u32 = @intCast(bytes.len);
    const pieces: u32 = @max(1, (whole + piece_bytes_max - 1) / piece_bytes_max);
    var answer: std.Io.Writer.Allocating = .init(arena);

    std.debug.assert(pieces <= module_bytes_max / piece_bytes_max + 1);

    for (0..pieces) |index| {
        const offset: u32 = @as(u32, @intCast(index)) * piece_bytes_max;
        const end: u32 = @min(offset + piece_bytes_max, whole);
        const last = index + 1 == pieces;
        const at = try std.fmt.allocPrint(arena, "{d}", .{offset});
        const data = encoder.encode(encoded, bytes[offset..end]);
        const words = [_][]const u8{
            "plugin",   "upload",
            "--file",   file,
            "--offset", at,
            "--data",   data,
            "--last",   if (last) "true" else "false",
        };
        var discarded: std.Io.Writer.Discarding = .init(&.{});
        const into = if (last) &answer.writer else &discarded.writer;

        if (try core.remote.forward(init, address, &words, env, into) != 0) {
            return 1;
        }
    }

    const update = std.mem.indexOf(u8, answer.written(), "\"update\": true") != null;
    const next: []const []const u8 = if (update)
        &.{ "plugin", "update", "--name", name }
    else
        &.{ "plugin", "enable", "--names", name };
    var out_buffer: [16 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    defer stdout.interface.flush() catch {};

    return core.remote.forward(init, address, next, env, &stdout.interface);
}

test "plugin build is the command's; with --files it is Publr's operation" {
    try std.testing.expect(handles(&.{ "plugin", "build", "--name", "greeter" }));
    try std.testing.expect(!handles(&.{ "plugin", "build", "--name", "greeter", "--files", "[]" }));
    try std.testing.expect(!handles(&.{ "plugin", "list" }));
    try std.testing.expect(!handles(&.{"plugin"}));
}

test "plugin build's words" {
    const arena = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(arena);
    defer state.deinit();

    const request = parse(state.allocator(), &.{ "--name", "greeter", "--with", "a.wasm", "--with", "b.wasm" }).?;

    try std.testing.expectEqualStrings("greeter", request.name);
    try std.testing.expectEqual(@as(usize, 2), request.with.len);
    try std.testing.expect(parse(state.allocator(), &.{"--name"}) == null);
    try std.testing.expect(parse(state.allocator(), &.{ "--dir", "x" }) == null);
}
