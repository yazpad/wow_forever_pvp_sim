const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const generate_action_catalog = b.addSystemCommand(&.{ "python3", "scripts/generate_action_catalog.py" });
    generate_action_catalog.setCwd(b.path("."));
    generate_action_catalog.addFileInput(b.path("scripts/generate_action_catalog.py"));
    generate_action_catalog.addFileInput(b.path("visualizer/data/action_catalog.json"));

    const exe = b.addExecutable(.{
        .name = "pvp_sim",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&generate_action_catalog.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run MCTS PvP fight generator or SIMD benchmark");
    run_step.dependOn(&run_cmd.step);

    const mcts = b.addExecutable(.{
        .name = "mcts_fight",
        .root_source_file = b.path("src/mcts_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcts.step.dependOn(&generate_action_catalog.step);
    b.installArtifact(mcts);
    const run_mcts = b.addRunArtifact(mcts);
    if (b.args) |args| run_mcts.addArgs(args);
    b.step("mcts", "Generate or benchmark a simultaneous MCTS fight").dependOn(&run_mcts.step);

    const test_step = b.step("test", "Run library tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
