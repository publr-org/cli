//! A site moving between this computer and a Publr elsewhere, seen in the browser: the page
//! `publr clone` opens while a site comes down, and `publr deploy` while one goes up to
//! Cloud, drawn alone (no admin around it) on a server the command starts with this plugin
//! given (`serve --plugin`). The command tells it where the move is (`clone_progress.update`)
//! and reads what the person chose to bring down; the page reads the same
//! (`clone_progress.state`) and chooses (`clone_progress.choose`).
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "clone_progress",
    .version = "0.1.0",
};

/// Clone
///
/// Where the clone is: one record, written by the command as it goes.
pub const Clone = struct {
    /// `down` (a clone, coming to this computer) or `up` (a deploy, going to Cloud).
    direction: []const u8 = "down",
    /// The site's short name, for the page's title.
    name: []const u8 = "",
    /// The folder it goes into, as the page names it.
    folder: []const u8 = "",
    /// Down: `choosing`, `packing`, `downloading`, `unpacking`, `placeholders`, `starting`.
    /// Up: `updating` (when `update_first`), `packing`, `uploading`, `going_live`, `done`.
    /// Either: `failed`.
    phase: []const u8 = "packing",
    /// Up: the project is moved to the Publr Cloud runs first, a step of its own.
    update_first: bool = false,
    /// How far the site is packing it, in ten-thousandths.
    packed_through: u32 = 0,
    /// Bytes downloaded (or uploaded) so far.
    done_bytes: u64 = 0,
    /// Bytes the download (or upload) holds.
    total_bytes: u64 = 0,
    /// Media files placeholders stand in for.
    placeholders: u32 = 0,
    /// Bytes written into the folder while unpacking.
    unpacked_bytes: u64 = 0,
    /// Media files come down too.
    media: bool = true,
    /// What the database weighs.
    database_bytes: u64 = 0,
    /// How many media files the site has.
    media_files: u64 = 0,
    /// What its media files weigh.
    media_bytes: u64 = 0,
    /// What its apps weigh.
    apps_bytes: u64 = 0,
    /// What its plugins weigh.
    plugins_bytes: u64 = 0,
    /// Why it stopped, once failed.
    problem: []const u8 = "",
    /// How long it has taken, from the choice on.
    elapsed_ms: u64 = 0,
    /// What the person chose on the page: `all`, `none`, or empty while nobody has.
    chosen: []const u8 = "",
    /// Up, once done: where the site is live.
    address: []const u8 = "",
    /// Up, once done: its admin, signed in once (a sign-on link good for a minute).
    admin: []const u8 = "",
};

pub const Stored = publr.record.define(Clone, .{
    .name = "clone_progress.clone",
    .kind = .settings,
    .menu = .none,
});

const the_clone = publr.query.prepare(
    \\*[_type == "clone_progress.clone"][0]{ "id": _id, name, folder, phase, packed_through,
    \\  done_bytes, total_bytes, placeholders, unpacked_bytes, media, database_bytes,
    \\  media_files, media_bytes, apps_bytes, plugins_bytes, problem, elapsed_ms, chosen, direction,
    \\  address, admin, update_first }
, .{});

const Found = struct {
    id: []const u8,
    name: []const u8 = "",
    folder: []const u8 = "",
    phase: []const u8 = "packing",
    packed_through: u32 = 0,
    done_bytes: u64 = 0,
    total_bytes: u64 = 0,
    placeholders: u32 = 0,
    unpacked_bytes: u64 = 0,
    media: bool = true,
    database_bytes: u64 = 0,
    media_files: u64 = 0,
    media_bytes: u64 = 0,
    apps_bytes: u64 = 0,
    plugins_bytes: u64 = 0,
    problem: []const u8 = "",
    elapsed_ms: u64 = 0,
    chosen: []const u8 = "",
    direction: []const u8 = "down",
    address: []const u8 = "",
    admin: []const u8 = "",
    update_first: bool = false,
};

fn found_of(ctx: *publr.Ctx) publr.Error!?Found {
    return the_clone.execute(ctx, ?Found, .{});
}

fn clone_of(found: Found) Clone {
    return .{
        .name = found.name,
        .folder = found.folder,
        .phase = found.phase,
        .packed_through = found.packed_through,
        .done_bytes = found.done_bytes,
        .total_bytes = found.total_bytes,
        .placeholders = found.placeholders,
        .unpacked_bytes = found.unpacked_bytes,
        .media = found.media,
        .database_bytes = found.database_bytes,
        .media_files = found.media_files,
        .media_bytes = found.media_bytes,
        .apps_bytes = found.apps_bytes,
        .plugins_bytes = found.plugins_bytes,
        .problem = found.problem,
        .elapsed_ms = found.elapsed_ms,
        .chosen = found.chosen,
        .direction = found.direction,
        .address = found.address,
        .admin = found.admin,
        .update_first = found.update_first,
    };
}

pub const UpdateIn = Clone;

pub const UpdateOut = struct {
    /// What the person chose on the page: `all`, `none`, or empty while nobody has.
    chosen: []const u8,
};

/// Where the move is now, from the command; answers what the person chose so far.
///
/// Administrators. The choice is the page's: an update keeps the one made.
///
/// Example:
///   in: { "name": "shop", "folder": "Publr/shop", "phase": "downloading", "done_bytes": 1024, "total_bytes": 4096 }
///   out: { "chosen": "all" }
pub const Update = publr.operation.define(UpdateIn, UpdateOut, .{
    .name = "update",
    .kind = .write,
    .run = update,
});

fn update(ctx: *publr.Ctx, in: UpdateIn) publr.Error!UpdateOut {
    std.debug.assert(in.phase.len > 0);

    var value = in;
    const found = try found_of(ctx);

    if (found) |held| {
        value.chosen = held.chosen;
        try Stored.save(ctx, try Stored.get(ctx, held.id, .{}), value);
    } else {
        value.chosen = "";
        _ = try Stored.create(ctx, value);
    }

    return .{
        .chosen = value.chosen,
    };
}

pub const StateIn = struct {};

/// One part of the bar.
pub const Mark = struct {
    /// Its name: Database, Media, Apps, Plugins.
    label: []const u8,
    /// Where it starts, as a CSS percentage.
    at: []const u8,
    /// How wide it is, as a CSS percentage.
    span: []const u8,
    /// Where it starts, out of 100.
    start: f64,
    /// How wide it is, out of 100.
    width: f64,
    /// What it weighs.
    bytes: f64,
};

pub const StateOut = struct {
    /// Where the clone is.
    clone: Clone,
    /// The bar's parts with media.
    marks_all: []const Mark,
    /// The bar's parts without media (database and setup only).
    marks_setup: []const Mark,
};

/// Where the clone is, as the page draws it.
///
/// Administrators.
///
/// Example:
///   in: {}
///   out: { "clone": { "phase": "choosing", "name": "shop" }, "marks_all": [], "marks_setup": [] }
pub const State = publr.operation.define(StateIn, StateOut, .{
    .name = "state",
    .kind = .read,
    .run = state,
});

fn state(ctx: *publr.Ctx, _: StateIn) publr.Error!StateOut {
    std.debug.assert(ctx.now().ms >= 0);

    const now = clone_of(try found_of(ctx) orelse .{ .id = "" });

    return .{
        .clone = now,
        .marks_all = try marks_of(Mark, ctx, now, true),
        .marks_setup = try marks_of(Mark, ctx, now, false),
    };
}

pub const ChooseIn = struct {
    /// `all`: media files too; `none`: placeholders stand in for them.
    media: []const u8,
};

pub const ChooseOut = struct {
    /// What comes down: `all` or `none`.
    chosen: []const u8,
};

/// What comes down, chosen on the page while the clone waits for it.
///
/// Administrators. Refused once it is chosen, and for anything but `all` or `none`.
///
/// Example:
///   in: { "media": "all" }
///   out: { "chosen": "all" }
pub const Choose = publr.operation.define(ChooseIn, ChooseOut, .{
    .name = "choose",
    .kind = .write,
    .run = choose,
});

fn choose(ctx: *publr.Ctx, in: ChooseIn) publr.Error!ChooseOut {
    const known = std.mem.eql(u8, in.media, "all") or std.mem.eql(u8, in.media, "none");

    if (!known) {
        return error.Invalid;
    }

    const held = try found_of(ctx) orelse return error.Conflict;

    if (!std.mem.eql(u8, held.phase, "choosing") or held.chosen.len > 0) {
        return error.Conflict;
    }

    var value = clone_of(held);

    value.chosen = in.media;
    value.media = std.mem.eql(u8, in.media, "all");
    try Stored.save(ctx, try Stored.get(ctx, held.id, .{}), value);

    return .{
        .chosen = in.media,
    };
}

pub const PageIn = struct {
    /// The address's query string
    query: []const u8 = "",
    /// The path the project is served under
    base: []const u8 = "",
};

pub const PageOut = struct {
    /// The page's markup
    html: []const u8,
};

/// Draws the move's progress page.
///
/// Administrators.
///
/// Example:
///   in: {}
///   out: { "html": "<!doctype html>" }
pub const Page = publr.operation.define(PageIn, PageOut, .{
    .name = "page",
    .kind = .read,
    .run = page,
});

fn page(ctx: *publr.Ctx, in: PageIn) publr.Error!PageOut {
    std.debug.assert(in.query.len <= 4096);

    const now = clone_of(try found_of(ctx) orelse .{ .id = "" });
    const View = publr.views.all.CloneProgress;

    return .{
        .html = try publr.views.render(ctx, in.base, View, .{
            .name = now.name,
            .folder = now.folder,
            .direction = now.direction,
            .marks_all = try marks_of(View.Marks_allItem, ctx, now, true),
            .marks_setup = try marks_of(View.Marks_setupItem, ctx, now, false),
        }),
    };
}

const share_min_percent: f64 = 12;

/// The bar's parts as the site weighs them, in order (database, media when it comes, apps,
/// plugins): each where it starts and its share of the bar, every part at least
/// `share_min_percent` wide so its name can be read, the rest shared by weight. None for a
/// site that did not say.
fn marks_of(comptime Item: type, ctx: *publr.Ctx, now: Clone, media: bool) publr.Error![]const Item {
    const up = std.mem.eql(u8, now.direction, "up");
    // A deploy's bar is its steps, as the page moves through them: packing here a tenth, the
    // upload most of it, Cloud the rest; moving it to Cloud's Publr first, a tenth before them.
    const parts = if (up and now.update_first) [_]struct {
        []const u8,
        u64,
    }{
        .{ "Updating", 10 },
        .{ "Packing", 10 },
        .{ "Uploading", 70 },
        .{ "Going live", 10 },
    } else if (up) [_]struct {
        []const u8,
        u64,
    }{
        .{ "Packing", 10 },
        .{ "Uploading", 80 },
        .{ "Going live", 10 },
        .{ "", 0 },
    } else [_]struct {
        []const u8,
        u64,
    }{
        .{ "Database", now.database_bytes },
        .{ "Media", if (media) now.media_bytes else 0 },
        .{ "Apps", now.apps_bytes },
        .{ "Plugins", now.plugins_bytes },
    };
    var total: u64 = 0;
    var small_count: f64 = 0;
    var large_bytes: f64 = 0;

    for (parts) |part| {
        total += part[1];
    }

    if (total == 0) {
        return &.{};
    }

    for (parts) |part| {
        const weight = @as(f64, @floatFromInt(part[1])) * 100 / @as(f64, @floatFromInt(total));

        if (part[1] > 0 and weight < share_min_percent) {
            small_count += 1;
        } else {
            large_bytes += @floatFromInt(part[1]);
        }
    }

    const left = 100 - small_count * share_min_percent;
    var marks: std.ArrayList(Item) = .empty;
    var at: f64 = 0;

    for (parts) |part| {
        if (part[1] == 0) {
            continue;
        }

        const bytes: f64 = @floatFromInt(part[1]);
        const weight = bytes * 100 / @as(f64, @floatFromInt(total));
        const share = if (weight < share_min_percent or large_bytes == 0)
            share_min_percent
        else
            bytes * left / large_bytes;

        try marks.append(ctx.arena(), .{
            .label = part[0],
            .at = try std.fmt.allocPrint(ctx.arena(), "{d:.2}%", .{at}),
            .span = try std.fmt.allocPrint(ctx.arena(), "{d:.2}%", .{share}),
            .start = at,
            .width = share,
            .bytes = bytes,
        });
        at += share;
    }

    return marks.items;
}

const progress_page: publr.plugin.Page = .{
    .path = "progress",
    .label = "Progress",
    .icon = "sync",
    .operation = Page,
    .menu = .none,
    .bare = true,
};

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Stored},
    .operations = &.{ Update, State, Choose, Page },
    .pages = &.{progress_page},
});
