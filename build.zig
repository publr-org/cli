const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    // The core, for Studio: `b.dependency("publr_cli", ...).module("publr_cli")`.
    const core = builder.addModule("publr_cli", .{
        .root_source_file = builder.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The build-on-publr skill `publr skill` writes, from `skills/`.
    module.addAnonymousImport("skill", .{
        .root_source_file = builder.path("skills/build-on-publr/SKILL.md"),
    });
    module.addAnonymousImport("skill_core_changes", .{
        .root_source_file = builder.path("skills/build-on-publr/references/core-changes.md"),
    });

    add_compiler(builder, module, target, optimize);

    const exe = builder.addExecutable(.{
        .name = "publr",
        .root_module = module,
    });

    builder.installArtifact(exe);

    const run = builder.addRunArtifact(exe);

    if (builder.args) |args| {
        run.addArgs(args);
    }

    builder.step("run", "Run publr").dependOn(&run.step);

    const test_step = builder.step("test", "Run the tests");

    for ([_]*std.Build.Module{ core, module }) |root| {
        const tests = builder.addTest(.{
            .root_module = root,
        });

        test_step.dependOn(&builder.addRunArtifact(tests).step);
    }

    test_step.dependOn(add_tidy(builder));
}

/// The compiler `plugin build` and `zig` carry (`publr_zig`, ../lib/zig): Zig built for
/// `target` without LLVM, which builds wasm32 only. Its archive is built by lib/zig, or
/// taken from `-Dtoolchain-archive=<file>` (CI keeps one per target); building for this
/// computer, `../lib/zig/zig-out/toolchain.tar.gz` is used when there is one
/// (`zig build toolchain` in lib/zig writes it), since building the compiler takes minutes.
fn add_compiler(
    builder: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const given = builder.option(
        []const u8,
        "toolchain-archive",
        "The compiler's archive, built before for this target by `zig build toolchain` in " ++
            "../lib/zig, used instead of building it",
    );
    const local = builder.pathFromRoot("../lib/zig/zig-out/toolchain.tar.gz");
    const has_local = if (std.Io.Dir.cwd().access(builder.graph.io, local, .{})) true else |_| false;
    const archive: ?[]const u8 = if (given) |path|
        (if (path.len == 0) null else path)
    else if (target.query.isNative() and has_local)
        local
    else
        null;
    const release = optimize != .Debug;
    const publr_zig = if (archive) |path|
        builder.dependency("publr_zig", .{
            .target = target,
            .release = release,
            .@"toolchain-archive" = path,
        })
    else
        builder.dependency("publr_zig", .{
            .target = target,
            .release = release,
        });

    module.addImport("publr_zig", publr_zig.module("publr_zig"));
}

/// The options rule of Publr's tidy (`STYLE.md`), alone, as `p` and Studio run it.
fn add_tidy(builder: *std.Build) *std.Build.Step {
    const tidy = builder.addExecutable(.{
        .name = "tidy",
        .root_module = builder.createModule(.{
            .root_source_file = .{
                .cwd_relative = builder.pathFromRoot("../publr/scripts/tidy.zig"),
            },
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = builder.addRunArtifact(tidy);

    run.addArgs(&.{ "--only=options", "build.zig", "src" });
    run.setCwd(builder.path("."));
    run.has_side_effects = true;

    builder.step("tidy", "The options rule of Publr's tidy").dependOn(&run.step);

    return &run.step;
}
