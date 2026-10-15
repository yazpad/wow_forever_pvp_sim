const std = @import("std");
const mcts_main = @import("mcts_main.zig");
const combat_soa = @import("combat_soa.zig");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var is_bench = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--simd-bench")) {
            is_bench = true;
            break;
        }
    }

    if (is_bench) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        const stdout = std.io.getStdOut().writer();

        const num_units = 100_000;
        try stdout.print("[Benchmark] Initializing {d} combatants in SoA layout...\n", .{num_units});
        var pool = try combat_soa.CombatantPool.init(allocator, num_units);
        defer pool.deinit();
        pool.seedRandom(num_units, 42);

        const num_ticks = 1_000;
        const dt: f32 = 0.016;
        try stdout.print("Simulating {d} ticks (dt = {d:0.3}s) for {d} units...\n", .{ num_ticks, dt, num_units });
        const start_tick_ns = std.time.nanoTimestamp();
        var last_alive: usize = 0;
        for (0..num_ticks) |_| {
            last_alive = pool.tickBatch(dt);
        }
        const end_tick_ns = std.time.nanoTimestamp();
        const tick_duration_s = @as(f64, @floatFromInt(end_tick_ns - start_tick_ns)) / 1e9;
        const total_evaluations = @as(f64, @floatFromInt(num_units * num_ticks));
        const evaluations_per_sec = total_evaluations / tick_duration_s;

        try stdout.print("  -> Completed in:      {d:0.3} seconds\n", .{tick_duration_s});
        try stdout.print("  -> Combatant Ticks:   {d:0.2} Million / sec\n", .{evaluations_per_sec / 1e6});
        try stdout.print("  -> Units Surviving:   {d} / {d}\n\n", .{ last_alive, num_units });
        return;
    }

    // Default: run MCTS fight engine
    try mcts_main.main();
}
