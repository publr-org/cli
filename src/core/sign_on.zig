//! Signed-in links. Every local site trusts the command as its issuer (`sign_on configure`):
//! it holds an Ed25519 seed in its own folder (`sign-on.key`) and signs a token, good for a
//! minute and once, for the site's admin. The format is core's (`publr/src/model/sign_on_token.zig`):
//! `<payload>.<signature>`, base64url without padding, JSON claims, Ed25519 over the
//! payload's text.

const std = @import("std");
const config_module = @import("config.zig");
const sites_module = @import("sites.zig");
const server = @import("server.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.url_safe_no_pad;
const Config = config_module.Config;
const Site = sites_module.Site;

pub const key_name = "sign-on.key";
pub const helper_port: u16 = 8789;
pub const issuer = "http://127.0.0.1:8789";
const lifetime_ms: i64 = 60 * std.time.ms_per_s;

pub fn seed(config: *const Config) ![Ed25519.KeyPair.seed_length]u8 {
    std.debug.assert(config.root.len > 0);

    const key_path = try config.path(&.{key_name});
    var out: [Ed25519.KeyPair.seed_length]u8 = undefined;
    const cwd = std.Io.Dir.cwd();

    if (cwd.readFileAlloc(config.io, key_path, config.arena, .limited(256))) |hex| {
        if (hex.len == out.len * 2) {
            _ = try std.fmt.hexToBytes(&out, hex);
            return out;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    config.io.random(&out);

    const hex = std.fmt.bytesToHex(out, .lower);

    try cwd.writeFile(config.io, .{
        .sub_path = key_path,
        .data = &hex,
        .flags = .{
            .permissions = .fromMode(0o600),
        },
    });

    return out;
}

pub fn public_key_hex(config: *const Config) ![Ed25519.PublicKey.encoded_length * 2]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(try seed(config));

    return std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
}

/// `http://admin.localhost:<port>/auth/sign-on?token=…&return=<path>`: opened, it signs the
/// admin in and lands on `path` (a page of the site opens on the site's host, toolbar shown).
pub fn link(config: *const Config, site: Site, back: []const u8) ![]const u8 {
    std.debug.assert(back.len > 0 and back[0] == '/');
    std.debug.assert(site.local.email.len > 0);

    const now = std.Io.Clock.real.now(config.io);
    const now_ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
    var nonce: [16]u8 = undefined;

    config.io.random(&nonce);

    const claims = .{
        .aud = site.name,
        .sub = site.local.email,
        .exp = now_ms + lifetime_ms,
        .jti = &std.fmt.bytesToHex(nonce, .lower),
    };
    const json = try std.json.Stringify.valueAlloc(config.arena, claims, .{});
    const payload = try encode(config.arena, json);
    const pair = try Ed25519.KeyPair.generateDeterministic(try seed(config));
    const signature = try pair.sign(payload, null);
    const signed = try encode(config.arena, &signature.toBytes());
    const admin_address = try server.admin_origin(config.arena, site);
    const query = try percent(config.arena, back);

    return std.fmt.allocPrint(config.arena, "{s}/auth/sign-on?token={s}.{s}&return={s}", .{
        admin_address,
        payload,
        signed,
        query,
    });
}

fn encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    std.debug.assert(bytes.len > 0);

    const out = try arena.alloc(u8, base64.Encoder.calcSize(bytes.len));

    return base64.Encoder.encode(out, bytes);
}

fn percent(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);

    try std.Uri.Component.percentEncode(&out.writer, text, unreserved);

    return out.written();
}

fn unreserved(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '.' or char == '_' or
        char == '~' or char == '/';
}
