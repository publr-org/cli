//! The Zig compiler the command carries (`publr_zig`), for building sandboxed plugins where
//! no Zig is installed. It is written out once per computer into the command's cache and run
//! as a child process, so a crash or a runaway compile ends that process only. It carries no
//! LLVM: it builds wasm32 and nothing else, and is never pointed at another target.

const std = @import("std");
const builtin = @import("builtin");
const publr_zig = @import("publr_zig");

/// How a `wasm32` module is built with it, after Publr's recipe and its compiler_rt.
pub const wasm_flags = publr_zig.wasm_flags;
/// How a module is built with a Zig that has LLVM (`PUBLR_PLUGIN_ZIG`): LLVM, its linker.
const llvm_flags = [_][]const u8{ "-fno-ubsan-rt", "-fno-entry" };
/// The one target it builds.
pub const wasm_target = "wasm32-freestanding";

pub const Toolchain = struct {
    compiler: []const u8,
    compiler_rt: []const u8,
    /// Its own cache, beside it.
    cache: []const u8,
};

/// Where it goes: `$PUBLR_CACHE_DIR`, else the system's cache folder (`~/Library/Caches/Publr`
/// on macOS, `$XDG_CACHE_HOME/publr` or `~/.cache/publr` elsewhere).
pub fn cache_dir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("PUBLR_CACHE_DIR")) |given| {
        if (given.len > 0) {
            return given;
        }
    }

    const home = environ.get("HOME") orelse return error.NoHome;

    std.debug.assert(home.len > 0);

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(arena, &.{ home, "Library", "Caches", "Publr" }),
        else => if (environ.get("XDG_CACHE_HOME")) |xdg|
            std.fs.path.join(arena, &.{ xdg, "publr" })
        else
            std.fs.path.join(arena, &.{ home, ".cache", "publr" }),
    };
}

/// The compiler, written out first if it is not there yet.
pub fn unpack(init: std.process.Init) !Toolchain {
    const arena = init.arena.allocator();
    const parent = try cache_dir(arena, init.environ_map);
    const unpacked = try publr_zig.unpack(init.io, arena, parent);

    std.debug.assert(unpacked.compiler.len > parent.len);

    return .{
        .compiler = unpacked.compiler,
        .compiler_rt = unpacked.compiler_rt,
        .cache = try std.fs.path.join(arena, &.{ parent, "zig-cache" }),
    };
}

/// Whether `args` build for wasm32 only: every `-target` names it and one does. The compiler
/// carries no LLVM; pointed at a native target it grows without bound, so nothing else runs.
pub fn wasm_only(args: []const []const u8) bool {
    var targets: u32 = 0;

    for (args, 0..) |arg, index| {
        if (std.mem.startsWith(u8, arg, "-target=") or std.mem.startsWith(u8, arg, "-mcpu=native")) {
            return false;
        }

        if (!std.mem.eql(u8, arg, "-target")) {
            continue;
        }

        if (index + 1 == args.len or !std.mem.eql(u8, args[index + 1], wasm_target)) {
            return false;
        }

        targets += 1;
    }

    return targets > 0;
}

/// The compiler run on Publr's recipe (`plugin prepare`'s `args`), with what is its own after
/// it: its compiler_rt, its wasm flags, its cache. Its exit code; its messages go to stderr.
pub fn compile(init: std.process.Init, tools: Toolchain, args: []const []const u8) !u8 {
    std.debug.assert(args.len > 0);

    if (!wasm_only(args)) {
        std.debug.print("publr plugin build: the build is not for {s} only; refused\n", .{wasm_target});
        return 1;
    }

    const arena = init.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;

    // A Zig with LLVM, named for builds Publr ships (its plugins server): LLVM optimising
    // for speed, as a plugin runs metered and LLVM's code takes a few times fewer
    // instructions. The carried compiler has none.
    if (init.environ_map.get("PUBLR_PLUGIN_ZIG")) |llvm_zig| if (llvm_zig.len > 0) {
        try argv.append(arena, llvm_zig);

        for (args) |word| {
            if (std.mem.eql(u8, word, "-Osmall")) {
                try argv.appendSlice(arena, &.{ "-OReleaseFast", "-fstrip" });
            } else {
                try argv.append(arena, word);
            }
        }

        try argv.appendSlice(arena, &llvm_flags);
        try argv.appendSlice(arena, &.{ "--cache-dir", tools.cache, "--global-cache-dir", tools.cache });

        return wait(init, argv.items);
    };

    try argv.append(arena, tools.compiler);
    try argv.appendSlice(arena, args);
    try argv.append(arena, tools.compiler_rt);
    try argv.appendSlice(arena, &wasm_flags);
    try argv.appendSlice(arena, &.{ "--cache-dir", tools.cache, "--global-cache-dir", tools.cache });

    return wait(init, argv.items);
}

fn wait(init: std.process.Init, argv: []const []const u8) !u8 {
    std.debug.assert(argv.len > 0);

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
    });

    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => |term| {
            std.debug.print("publr plugin build: the compiler stopped: {any}\n", .{term});
            return 1;
        },
    };
}

/// Subcommands that compile nothing: they run whatever the target.
const no_codegen = [_][]const u8{ "version", "env", "help", "zen", "fmt", "ast-check", "targets" };

/// `publr zig <args>`: the compiler, with the arguments as given, for wasm32 only (it carries
/// no LLVM); its exit code is the command's. What compiles nothing (`fmt`, `version`) runs
/// as given.
pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const informational = args.len > 0 and for (no_codegen) |word| {
        if (std.mem.eql(u8, args[0], word)) {
            break true;
        }
    } else false;

    if (!informational and !wasm_only(args)) {
        std.debug.print("publr zig: builds for {s} only (-target {s}); it carries no LLVM\n", .{
            wasm_target,
            wasm_target,
        });
        return 2;
    }

    const tools = unpack(init) catch |err| {
        std.debug.print("publr zig: the compiler could not be written out ({t}); " ++
            "set PUBLR_CACHE_DIR to a writable folder\n", .{err});
        return 1;
    };
    const arena = init.arena.allocator();
    const argv = try arena.alloc([]const u8, args.len + 1);

    argv[0] = tools.compiler;
    @memcpy(argv[1..], args);

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
    });

    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 1,
    };
}

test "a build is wasm32 only, or refused" {
    try std.testing.expect(wasm_only(&.{ "build-exe", "-target", "wasm32-freestanding", "-Mroot=a.zig" }));
    try std.testing.expect(!wasm_only(&.{ "build-exe", "-Mroot=a.zig" }));
    try std.testing.expect(!wasm_only(&.{ "build-exe", "-target", "aarch64-macos", "-Mroot=a.zig" }));
    try std.testing.expect(!wasm_only(&.{ "-target", "wasm32-freestanding", "-target", "native" }));
    try std.testing.expect(!wasm_only(&.{ "run", "a.zig" }));
}
