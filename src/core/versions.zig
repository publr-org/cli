//! Which Publr a site runs. A site pins a release in its `publr.zon` (`.publr = "0.6.4"`);
//! the command keeps each release it needs in `versions/<v>/publr`, fetched from where Publr
//! publishes them and checked against the signature Publr's own updates trust. A Publr
//! chosen with `--publr`, for the site, or for every site (one built from source, say) runs
//! instead of the pin.

const std = @import("std");
const builtin = @import("builtin");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");

const Config = config_module.Config;
const Site = sites_module.Site;

pub const folder_name = "versions";
pub const binary_name = "publr";
/// The public half of the key Publr's Release workflow signs `SHA256SUMS` with; the same one
/// Publr's updates check (`publr/src/model/release.zig`).
pub const signing_key_hex = "72928f861218c31c9358d8be4d51294e4fe923a2970d784740f436e28a7567e8";
pub const repository = "publr-org/publr";
pub const kept_max: u32 = 256;
const downloads_default = "https://github.com/" ++ repository ++ "/releases/download";
const latest_default = "https://api.github.com/repos/" ++ repository ++ "/releases/latest";
const sums_name = "SHA256SUMS";
const signature_name = "SHA256SUMS.sig";
const project_bytes_max: u32 = 1 << 20;
const binary_bytes_max: u32 = 512 << 20;

/// This machine's file in a release: `publr-macos-aarch64`, `publr-linux-x86_64`.
pub fn asset_name() []const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unsupported",
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unsupported",
    };

    return "publr-" ++ os ++ "-" ++ arch;
}

/// The release `folder`'s `publr.zon` pins, or null.
pub fn pin_of(config: *const Config, folder: []const u8) !?[]const u8 {
    const text = try read_project(config, folder);
    const Project = struct {
        publr: ?[]const u8 = null,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const project = std.zon.parse.fromSlice(Project, .{
        .gpa = config.arena,
        .arena = config.arena,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch return error.BadProjectFile;

    return project.publr;
}

/// `folder`'s `publr.zon` pinned to `version`, the rest of the file as it was.
pub fn set_pin(config: *const Config, folder: []const u8, version: []const u8) !void {
    std.debug.assert(version.len > 0);

    const text = try read_project(config, folder);
    const changed = try with_pin(config.arena, text, version);

    try std.Io.Dir.cwd().writeFile(config.io, .{
        .sub_path = try std.fs.path.join(config.arena, &.{ folder, sites_module.project_file }),
        .data = changed,
    });
}

/// `text` (a `publr.zon`) with `.publr` set to `version`: the value replaced, or the field
/// added first.
pub fn with_pin(arena: std.mem.Allocator, text: []const u8, version: []const u8) ![]const u8 {
    std.debug.assert(version.len > 0);

    const field = ".publr = \"";

    if (std.mem.indexOf(u8, text, field)) |at| {
        const value_at = at + field.len;
        const end = std.mem.indexOfScalarPos(u8, text, value_at, '"') orelse return error.BadProjectFile;

        return std.mem.concat(arena, u8, &.{ text[0..value_at], version, text[end..] });
    }

    const open = std.mem.indexOf(u8, text, ".{") orelse return error.BadProjectFile;
    const after = open + 2;

    return std.fmt.allocPrint(arena, "{s}\n    .publr = \"{s}\",{s}", .{
        text[0..after],
        version,
        text[after..],
    });
}

fn read_project(config: *const Config, folder: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(config.arena, &.{ folder, sites_module.project_file });

    return std.Io.Dir.cwd().readFileAllocOptions(
        config.io,
        path,
        config.arena,
        .limited(project_bytes_max),
        .of(u8),
        0,
    );
}

/// The Publr chosen to run `site` instead of its pin, or null: `--publr` for this call, else
/// the site's own choice, else the one chosen for every site.
pub fn chosen_binary(config: *const Config, site: Site) ?[]const u8 {
    for ([_][]const u8{ config.call_publr, site.local.publr, config.publr }) |chosen| {
        if (chosen.len > 0) {
            return chosen;
        }
    }

    return null;
}

/// The Publr chosen for this call or for every site, ahead of any release, or null: for a
/// folder that is no site yet (a clone, an archive).
pub fn chosen_for_all(config: *const Config) ?[]const u8 {
    for ([_][]const u8{ config.call_publr, config.publr }) |chosen| {
        if (chosen.len > 0) {
            return chosen;
        }
    }

    return null;
}

/// What `--publr` or `config publr` names, as a binary: a path as given (made absolute), or
/// a release, fetched when not kept.
pub fn resolve(config: *const Config, given: []const u8) ![]const u8 {
    std.debug.assert(given.len > 0);

    if (std.mem.indexOfScalar(u8, given, '/') == null) {
        return kept(config, given);
    }

    const path = try sites_module.absolute(config, given);

    std.Io.Dir.cwd().access(config.io, path, .{}) catch {
        std.debug.print("publr: no Publr at {s}\n", .{path});
        return error.NoSuchBinary;
    };

    return path;
}

/// What a site runs, said in words: `0.6.4`, `chosen` (a Publr chosen for every site), or
/// `none`.
pub fn running_label(config: *const Config, site: Site) ![]const u8 {
    if (chosen_binary(config, site) != null) {
        return "chosen";
    }

    return (try pin_of(config, site.folder)) orelse "none";
}

/// The Publr `site` runs: the one chosen for every site, else its pinned release (the newest,
/// pinned now, when it names none), fetched when missing.
pub fn binary_for(config: *const Config, site: Site) ![]const u8 {
    if (chosen_binary(config, site)) |path| {
        return path;
    }

    // A site that names no release takes the one Cloud runs, as a new one would, and keeps it:
    // a site on a computer never gets ahead of Cloud, where it may go.
    const pin = (try pin_of(config, site.folder)) orelse blk: {
        const newest_release = try @import("compat.zig").cloud_release(config);

        try set_pin(config, site.folder, newest_release);
        std.debug.print("publr: {s} now runs Publr {s}\n", .{ site.name, newest_release });

        break :blk newest_release;
    };

    return kept(config, pin);
}

/// `versions/<version>/publr`, fetched first when it is not kept yet.
pub fn kept(config: *const Config, version: []const u8) ![]const u8 {
    std.debug.assert(version.len > 0);

    const path = try config.path(&.{ folder_name, version, binary_name });

    std.Io.Dir.cwd().access(config.io, path, .{}) catch {
        try fetch(config, version);
    };

    return path;
}

/// Every release kept, by version.
pub fn list(config: *const Config) ![]const []const u8 {
    const root = try config.path(&.{folder_name});
    var dir = std.Io.Dir.cwd().openDir(config.io, root, .{
        .iterate = true,
    }) catch return &.{};
    defer dir.close(config.io);

    var found: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(config.io)) |item| {
        if (item.kind != .directory or item.name[0] == '.') {
            continue;
        }

        // Only a release is kept here; any other folder is not one.
        _ = std.SemanticVersion.parse(item.name) catch continue;

        if (found.items.len == kept_max) {
            break;
        }

        try found.append(config.arena, try config.arena.dupe(u8, item.name));
    }

    std.mem.sort([]const u8, found.items, {}, older);

    return found.items;
}

fn older(_: void, left: []const u8, right: []const u8) bool {
    const left_version = std.SemanticVersion.parse(left) catch unreachable;
    const right_version = std.SemanticVersion.parse(right) catch unreachable;

    return left_version.order(right_version) == .lt;
}

/// The newest release published, or the newest kept when the list cannot be reached.
pub fn newest(config: *const Config) ![]const u8 {
    const url = config.environ.get("PUBLR_RELEASES_LATEST") orelse latest_default;
    var body: std.Io.Writer.Allocating = .init(config.arena);

    if (get(config.io, url, &body.writer)) {
        const Latest = struct {
            tag_name: []const u8,
        };
        const latest = std.json.parseFromSliceLeaky(Latest, config.arena, body.written(), .{
            .ignore_unknown_fields = true,
        }) catch null;

        if (latest) |found| {
            const tag = found.tag_name;
            const version = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

            if (std.SemanticVersion.parse(version)) |_| {
                return version;
            } else |_| {}
        }
    } else |err| {
        std.debug.print("publr: the newest release could not be asked for ({t})\n", .{err});
    }

    const all = try list(config);

    if (all.len == 0) {
        return error.NoRelease;
    }

    return all[all.len - 1];
}

/// Release `version`'s binary for this machine into `versions/<version>/`, kept only when
/// its checksums carry Publr's signature and list the binary's SHA-256.
pub fn fetch(config: *const Config, version: []const u8) !void {
    std.debug.assert(version.len > 0);

    _ = std.SemanticVersion.parse(version) catch {
        std.debug.print("publr: {s} is not a release (0.6.4, say)\n", .{version});
        return error.NotARelease;
    };

    const arena = config.arena;
    const io = config.io;
    const base = config.environ.get("PUBLR_RELEASES_URL") orelse downloads_default;
    const cwd = std.Io.Dir.cwd();
    const partial = try config.path(&.{ folder_name, try std.fmt.allocPrint(arena, ".{s}.partial", .{version}) });

    std.debug.print("publr: fetching Publr {s}…\n", .{version});

    try cwd.deleteTree(io, partial);
    try cwd.createDirPath(io, partial);

    var files: [3][]const u8 = undefined;

    for ([_][]const u8{ asset_name(), sums_name, signature_name }, 0..) |name, index| {
        const url = try std.fmt.allocPrint(arena, "{s}/v{s}/{s}", .{ base, version, name });
        var body: std.Io.Writer.Allocating = .init(arena);

        get(io, url, &body.writer) catch |err| {
            std.debug.print("publr: couldn't download Publr {s}: {t} ({s})\n", .{ version, err, url });
            return error.FetchFailed;
        };

        files[index] = body.written();
    }

    if (verified(files[0], files[1], files[2])) |problem| {
        std.debug.print("publr: Publr {s} refused: {s}\n", .{ version, problem });
        return error.NotVerified;
    }

    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ partial, binary_name }),
        .data = files[0],
        .flags = .{
            .permissions = .executable_file,
        },
    });

    const final = try config.path(&.{ folder_name, version });

    try cwd.deleteTree(io, final);
    try cwd.rename(partial, cwd, final, io);
}

/// Null when `binary` is what Publr published: `sums` signed with its key and listing the
/// binary's SHA-256. Else why not.
pub fn verified(binary: []const u8, sums: []const u8, signature: []const u8) ?[]const u8 {
    return verified_file(binary, asset_name(), sums, signature);
}

/// Null when `file`, published as `name`, is what Publr published: `sums` signed with its key
/// and listing `name`'s SHA-256. Else why not. Desktop's updates are checked the same way.
pub fn verified_file(file: []const u8, name: []const u8, sums: []const u8, signature: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(signing_key_hex.len == 64);

    const Ed25519 = std.crypto.sign.Ed25519;

    if (signature.len != Ed25519.Signature.encoded_length) {
        return "no signature";
    }

    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, signing_key_hex) catch unreachable;
    const key = Ed25519.PublicKey.fromBytes(key_bytes) catch unreachable;
    const parsed = Ed25519.Signature.fromBytes(signature[0..64].*);

    parsed.verify(sums, key) catch return "the checksums' signature is not Publr's";

    const expected = sum_of(sums, name) orelse return "the checksums do not list it";
    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(file, &digest, .{});

    const actual = std.fmt.bytesToHex(digest, .lower);

    if (!std.mem.eql(u8, &actual, expected)) {
        return "it is not the one the checksums list";
    }

    return null;
}

/// The SHA-256 `sums` (a `SHA256SUMS` file) gives for `file`, as hex.
pub fn sum_of(sums: []const u8, file: []const u8) ?[]const u8 {
    std.debug.assert(file.len > 0);

    var lines = std.mem.tokenizeScalar(u8, sums, '\n');

    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " *");
        const digest = words.next() orelse continue;
        const name = words.next() orelse continue;

        if (std.mem.eql(u8, name, file) and digest.len == 64) {
            return digest;
        }
    }

    return null;
}

const request_head_bytes_max = 16 * 1024;
/// GitHub sends a release asset on to a signed address on another host.
const redirects_max: u32 = 4;

/// `url`'s body into `out`. Redirects are followed here, each as a request of its own: Zig's
/// client, following them itself, sends the next request damaged ("invalid header name" from
/// GitHub's asset host) and cuts long bodies short.
pub fn get(io: std.Io, url: []const u8, out: *std.Io.Writer) !void {
    std.debug.assert(url.len > 0);
    std.debug.assert(url.len < request_head_bytes_max);

    var location_buffer: [request_head_bytes_max]u8 = undefined;
    var next: []const u8 = url;
    var hops: u32 = 0;

    while (hops <= redirects_max) : (hops += 1) {
        const moved = try get_once(io, next, out, &location_buffer) orelse return;

        if (!std.mem.startsWith(u8, moved, "https://")) {
            return error.NotFound;
        }

        next = moved;
    }

    return error.NotFound;
}

/// One request: its body into `out` when it answers, or the address it moved to, copied into
/// `location_buffer`.
fn get_once(io: std.Io, url: []const u8, out: *std.Io.Writer, location_buffer: []u8) !?[]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(location_buffer.len >= request_head_bytes_max);

    // Its own memory: TLS loads the system's certificates, more than a request holds.
    var client_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer client_arena.deinit();
    var client: std.http.Client = .{
        .allocator = client_arena.allocator(),
        .io = io,
        // A whole request head in one buffer: a release asset's signed address is ~900 bytes.
        .write_buffer_size = request_head_bytes_max,
    };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{
                .override = "publr-cli",
            },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{
            .{
                .name = "Accept",
                .value = "application/vnd.github+json",
            },
        },
    });
    defer request.deinit();

    try request.sendBodiless();

    var response = try request.receiveHead(&.{});

    if (response.head.status.class() == .redirect) {
        const location = response.head.location orelse return error.NotFound;

        if (location.len > location_buffer.len) {
            return error.NotFound;
        }

        @memcpy(location_buffer[0..location.len], location);

        return location_buffer[0..location.len];
    }

    if (response.head.status != .ok) {
        return error.NotFound;
    }

    _ = response.reader(&.{}).streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |other| return other,
    };

    return null;
}

pub fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "a pin set in publr.zon, added or replaced" {
    const arena = std.testing.allocator;
    const added = try with_pin(arena, ".{\n    .name = \"shop\",\n}\n", "0.6.4");
    defer arena.free(added);

    try std.testing.expectEqualStrings(".{\n    .publr = \"0.6.4\",\n    .name = \"shop\",\n}\n", added);

    const replaced = try with_pin(arena, added, "0.7.0");
    defer arena.free(replaced);

    try std.testing.expectEqualStrings(".{\n    .publr = \"0.7.0\",\n    .name = \"shop\",\n}\n", replaced);
}

test "a release's checksum found by file name" {
    const sums = &@as([64]u8, @splat('a')) ++ "  publr-linux-x86_64\n" ++ &@as([64]u8, @splat('b')) ++ " *publr-macos-aarch64\n";

    try std.testing.expectEqualStrings(&@as([64]u8, @splat('b')), sum_of(sums, "publr-macos-aarch64").?);
    try std.testing.expect(sum_of(sums, "publr-linux-aarch64") == null);
}
