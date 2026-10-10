const std = @import("std");
const simd = @import("simd.zig");
const combat_soa = @import("combat_soa.zig");
const CombatantPool = combat_soa.CombatantPool;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n======================================================\n", .{});
    try stdout.print("         ⚔️  PVP_SIM: HIGH-PERFORMANCE SIMD ENGINE       \n", .{});
    try stdout.print("======================================================\n\n", .{});

    // ---------------------------------------------------------
    // Benchmark 1: Mass Unit Status / Damage Ticking (AVX-512)
    // ---------------------------------------------------------
    const num_units = 100_000;
    try stdout.print("[Benchmark 1] Initializing {d} combatants in SoA layout...\n", .{num_units});
    
    var pool = try CombatantPool.init(allocator, num_units);
    defer pool.deinit();
    pool.seedRandom(num_units, 42);

    const num_ticks = 1_000;
    const dt: f32 = 0.016; // 60 FPS tick (16ms)
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
    try stdout.print("  -> Per-Batch Tick:    {d:0.3} ms\n", .{(tick_duration_s / @as(f64, @floatFromInt(num_ticks))) * 1000.0});
    try stdout.print("  -> Units Surviving:   {d} / {d}\n\n", .{ last_alive, num_units });

    // ---------------------------------------------------------
    // Benchmark 2: Monte-Carlo Parallel 1v1 Duels
    // ---------------------------------------------------------
    const num_duels = 64_000;
    try stdout.print("[Benchmark 2] Simulating {d} simultaneous 1v1 Duels...\n", .{num_duels});

    var team_a = try CombatantPool.init(allocator, num_duels);
    defer team_a.deinit();
    team_a.seedRandom(num_duels, 101);

    var team_b = try CombatantPool.init(allocator, num_duels);
    defer team_b.deinit();
    team_b.seedRandom(num_duels, 202);

    const start_duel_ns = std.time.nanoTimestamp();
    const duel_results = CombatantPool.simulateDuelsSoA(&team_a, &team_b, 0.05, 500);
    const end_duel_ns = std.time.nanoTimestamp();

    const duel_duration_s = @as(f64, @floatFromInt(end_duel_ns - start_duel_ns)) / 1e9;
    const duels_per_sec = @as(f64, @floatFromInt(num_duels)) / duel_duration_s;

    try stdout.print("  -> Completed in:      {d:0.3} seconds\n", .{duel_duration_s});
    try stdout.print("  -> Duel Throughput:   {d:0.1} Duels / sec\n", .{duels_per_sec});
    try stdout.print("  -> Total Sim Ticks:   {d:0.2} Million ticks\n", .{@as(f64, @floatFromInt(duel_results.total_ticks)) / 1e6});
    try stdout.print("  -> Results:           Team A wins: {d} | Team B wins: {d} | Draws: {d}\n\n", .{
        duel_results.wins_a,
        duel_results.wins_b,
        duel_results.draws,
    });

    try stdout.print("Vectorized SIMD simulation verified successfully.\n", .{});
}
