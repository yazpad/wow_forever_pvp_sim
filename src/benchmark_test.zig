const builtin = @import("builtin");
const std = @import("std");
const simd = @import("simd.zig");
const combat_soa = @import("combat_soa.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");
const league_mod = @import("league.zig");

test "Vectorization compile-time static assertions" {
    // 1. Assert 64-byte hardware cache line & AVX-512 alignment
    try std.testing.expectEqual(@as(usize, 64), simd.SimdConfig.Alignment);
    try std.testing.expectEqual(@as(usize, 16), simd.SimdConfig.VecLen16);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(simd.f32x16));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(simd.u32x16));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(simd.f32x16));

    comptime {
        for (.{ combat_soa.CombatantPool, combat_spec.WarlockArenaPool }) |Pool| {
            for (@typeInfo(Pool).@"struct".fields) |field| {
                switch (@typeInfo(field.type)) {
                    .pointer => |ptr| {
                        if (ptr.size == .slice and ptr.alignment != 64)
                            @compileError("SoA column must have 64-byte alignment: " ++ field.name);
                    },
                    else => {},
                }
            }
        }
        if (@typeInfo(simd.f32x16).vector.len != 16)
            @compileError("Combat vectors must contain 16 lanes");
    }

    // 2. Assert PolicyGenome is compact (< 4 KB to comfortably fit in L1 cache)
    try std.testing.expect(@sizeOf(policy_simd.PolicyGenome) < 4096);
    try std.testing.expectEqual(@as(usize, 24), policy_simd.IN_DIM);
    try std.testing.expectEqual(@as(usize, 24), policy_simd.HIDDEN_DIM);
    try std.testing.expectEqual(@as(usize, 9), policy_simd.ACTION_DIM);
}

test "Throughput regression floor check" {
    const allocator = std.testing.allocator;

    // 1. Raw CombatantPool Batch Ticking
    const test_units = 16_384;
    var pool = try combat_soa.CombatantPool.init(allocator, test_units);
    defer pool.deinit();
    pool.seedRandom(test_units, 42);

    const num_ticks = 500;
    const start_tick = std.time.nanoTimestamp();
    var alive: usize = 0;
    for (0..num_ticks) |_| {
        alive = pool.tickBatch(0.016);
    }
    const end_tick = std.time.nanoTimestamp();
    const tick_duration_s = @as(f64, @floatFromInt(end_tick - start_tick)) / 1e9;
    const ticks_per_sec = @as(f64, @floatFromInt(test_units * num_ticks)) / tick_duration_s;

    try std.testing.expect(alive <= test_units);

    // In debug test mode, throughput is lower than ReleaseFast, but must exceed 50 Million ticks/s
    try std.testing.expect(ticks_per_sec >= (if (builtin.mode == .ReleaseFast) @as(f64, 1_000_000_000) else 50_000_000));

    // 2. Vectorized RL League Play Batch Execution
    var league = try league_mod.League.init(allocator, .{
        .pop_size = 16,
        .hall_of_fame_capacity = 4,
        .duels_per_agent = 1,
        .max_duel_seconds = 30.0,
        .physics_dt = 0.010,
    }, 123);
    defer league.deinit();

    const start_league = std.time.nanoTimestamp();
    league.stepGeneration();
    const end_league = std.time.nanoTimestamp();
    const league_s = @as(f64, @floatFromInt(end_league - start_league)) / 1e9;
    const duels_per_sec = @as(f64, @floatFromInt(league.total_duels_simulated)) / league_s;

    try std.testing.expect(duels_per_sec >= (if (builtin.mode == .ReleaseFast) @as(f64, 20_000) else 500)); // Baseline in debug mode
}

test "MatchRecorder evaluation throughput and zero-leak export" {
    const allocator = std.testing.allocator;
    const match_recorder = @import("match_recorder.zig");
    const MatchRecorder = match_recorder.MatchRecorder;

    var prng = std.Random.DefaultPrng.init(999);
    const rand = prng.random();
    const g_a = policy_simd.PolicyGenome.initRandom(rand);
    const g_b = policy_simd.PolicyGenome.initRandom(rand);

    const start_ns = std.time.nanoTimestamp();
    var traj = try MatchRecorder.recordDuel(allocator, &g_a, &g_b, "TestA", "TestB", 10.0, 0.010);
    defer traj.deinit();
    const end_ns = std.time.nanoTimestamp();

    const record_duration_ms = @as(f64, @floatFromInt(end_ns - start_ns)) / 1e6;

    // A 1000-tick evaluation duel should record rapidly (< 50ms even in debug)
    try std.testing.expect(record_duration_ms < 50.0);
    try std.testing.expect(traj.frames.items.len > 0);

    // Test Lua generation
    const test_lua = "tmp_perf_test.lua";
    try traj.exportLua(test_lua);
    defer std.fs.cwd().deleteFile(test_lua) catch {};

    const file_stat = try std.fs.cwd().statFile(test_lua);
    try std.testing.expect(file_stat.size > 100);
}

test "Gauntlet benchmark throughput and objective scoring" {
    const allocator = std.testing.allocator;
    const gauntlet = @import("gauntlet.zig");

    var prng = std.Random.DefaultPrng.init(555);
    const champ = policy_simd.PolicyGenome.initRandom(prng.random());

    var runner = try gauntlet.GauntletRunner.init(allocator);
    defer runner.deinit();

    const start_ns = std.time.nanoTimestamp();
    const report = runner.evaluateChampion(&champ, 32, 10.0, 0.010);
    const end_ns = std.time.nanoTimestamp();

    const elapsed_s = @as(f64, @floatFromInt(end_ns - start_ns)) / 1e9;
    const gauntlet_duels_per_sec = @as(f64, @floatFromInt(report.total_duels)) / elapsed_s;

    try std.testing.expectEqual(@as(u32, 128), report.total_duels);
    try std.testing.expect(gauntlet_duels_per_sec > 100.0);
    try std.testing.expect(report.objective_elo >= 400.0 and report.objective_elo <= 3000.0);

    // Test Match trajectory recording against Gauntlet bot
    var traj = try gauntlet.GauntletRunner.recordDuelVsBot(allocator, &champ, .AggroRusher, "TestChampion", 5.0, 0.010);
    defer traj.deinit();
    try std.testing.expect(traj.frames.items.len > 0);
}

test "Raw duel throughput regression floor" {
    const count = 64_000;
    var a = try combat_soa.CombatantPool.init(std.testing.allocator, count);
    defer a.deinit();
    var b = try combat_soa.CombatantPool.init(std.testing.allocator, count);
    defer b.deinit();
    a.seedRandom(count, 101);
    b.seedRandom(count, 202);
    var timer = try std.time.Timer.start();
    const results = combat_soa.CombatantPool.simulateDuelsSoA(&a, &b, 0.05, 500);
    const elapsed = timer.read();
    try std.testing.expectEqual(@as(usize, count), results.wins_a + results.wins_b + results.draws);
    const rate = @as(f64, count) * 1e9 / @as(f64, @floatFromInt(elapsed));
    try std.testing.expect(rate >= (if (builtin.mode == .ReleaseFast) @as(f64, 1_000_000) else 10_000));
}

test "Frost Mage keeps compact policies and ReleaseFast neural throughput floor" {
    const Arena = @import("multi_spec.zig").ArenaPool(.frost_mage, .frost_mage);
    comptime {
        for (@typeInfo(Arena).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .pointer => |ptr| if (ptr.size == .slice and ptr.alignment != 64) {
                    @compileError("Mage SoA storage must have 64-byte alignment");
                },
                else => {},
            }
        }
    }
    var league = try league_mod.FrostMageLeague.init(std.testing.allocator, .{
        .pop_size = 16,
        .duels_per_agent = 1,
        .max_duel_seconds = 30,
    }, 123);
    defer league.deinit();
    var timer = try std.time.Timer.start();
    league.stepGeneration();
    const elapsed = timer.read();
    const rate = @as(f64, @floatFromInt(league.total_duels_simulated)) * 1e9 / @as(f64, @floatFromInt(elapsed));
    try std.testing.expect(rate >= (if (builtin.mode == .ReleaseFast) @as(f64, 20_000) else 500));
    try std.testing.expectEqual(@as(usize, 24), policy_simd.IN_DIM);
    try std.testing.expectEqual(@as(usize, 9), policy_simd.ACTION_DIM);
}
