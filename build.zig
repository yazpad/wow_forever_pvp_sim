const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pvp_sim",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the PvP SIMD benchmark");
    run_step.dependOn(&run_cmd.step);

    const class_bench = b.addExecutable(.{
        .name = "class_benchmark",
        .root_source_file = b.path("src/class_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_class_bench = b.addRunArtifact(class_bench);
    run_class_bench.step.dependOn(b.getInstallStep());
    const class_bench_step = b.step("bench-classes", "Benchmark fixed ticks, inference, and class leagues");
    class_bench_step.dependOn(&run_class_bench.step);

    const test_step = b.step("test", "Run library tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
