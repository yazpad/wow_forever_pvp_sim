const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const generate_action_catalog = b.addSystemCommand(&.{ "python3", "scripts/generate_action_catalog.py" });
    generate_action_catalog.setCwd(b.path("."));
    generate_action_catalog.addFileInput(b.path("scripts/generate_action_catalog.py"));
    generate_action_catalog.addFileInput(b.path("visualizer/data/action_catalog.json"));

    const generate_identity = b.addSystemCommand(&.{ "python3", "scripts/generate_simulator_identity.py" });
    generate_identity.setCwd(b.path("."));
    generate_identity.step.dependOn(&generate_action_catalog.step);

    const exe = b.addExecutable(.{
        .name = "pvp_sim",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&generate_identity.step);
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
    mcts.step.dependOn(&generate_identity.step);
    b.installArtifact(mcts);
    const run_mcts = b.addRunArtifact(mcts);
    if (b.args) |args| run_mcts.addArgs(args);
    b.step("mcts", "Generate or benchmark a simultaneous MCTS fight").dependOn(&run_mcts.step);

    const analysis = b.addExecutable(.{
        .name = "fight_analysis",
        .root_source_file = b.path("src/fight_analysis.zig"),
        .target = target,
        .optimize = optimize,
    });
    analysis.step.dependOn(&generate_identity.step);
    b.installArtifact(analysis);

    const learning = b.addExecutable(.{
        .name = "learning_arena",
        .root_source_file = b.path("src/learning_arena.zig"),
        .target = target,
        .optimize = optimize,
    });
    learning.step.dependOn(&generate_identity.step);
    b.installArtifact(learning);

    const neuro = b.addExecutable(.{
        .name = "neuro_arena",
        .root_source_file = b.path("src/neuro_arena.zig"),
        .target = target,
        .optimize = optimize,
    });
    neuro.step.dependOn(&generate_identity.step);
    b.installArtifact(neuro);
    const run_neuro = b.addRunArtifact(neuro);
    if (b.args) |args| run_neuro.addArgs(args);
    b.step("neuro", "Run alternating neuroevolution self-play arena").dependOn(&run_neuro.step);

    const test_step = b.step("test", "Run library tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.step.dependOn(&generate_identity.step);
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
