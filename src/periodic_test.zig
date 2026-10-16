const std = @import("std");
const combat = @import("combat_spec.zig");
const multi = @import("multi_spec.zig");
const periodic = @import("periodic.zig");
const r = @import("spell_resolution.zig");
const spec = @import("spec.zig");
const search = @import("search_sim.zig");
const simd = @import("simd.zig");
const V = simd.f32x16;
const C = combat.WarlockConstants;

fn disablePets(state: *combat.WarlockArenaPool) void {
    @memset(state.pet_kind_a, 0);
    @memset(state.pet_kind_b, 0);
}

test "periodic phase clock has delayed first tick exact final tick and no fractional ticks" {
    for ([_]f32{ 0.01, 0.02, 0.1, 0.25, 1 }) |dt| {
        var clock: V = @splat(18);
        var ticks: f32 = 0;
        const steps: usize = @intFromFloat(@round(18 / dt));
        for (0..steps) |step| {
            const next = periodic.remaining(clock, dt);
            ticks += periodic.tickCount(clock, next, 18, 2)[0];
            clock = next;
            if (step == 0 and dt < 2) try std.testing.expectEqual(@as(f32, 0), ticks);
        }
        try std.testing.expectEqual(@as(f32, 9), ticks);
        try std.testing.expectEqual(@as(f32, 0), clock[0]);
        try std.testing.expectEqual(@as(f32, 0), periodic.tickCount(clock, clock, 18, 2)[0]);
    }
    try std.testing.expectEqual(@as(f32, 2), periodic.tickCount(@splat(18), @splat(13), 18, 2)[0]);
}

test "production DoT ticks and RNG match across physics steps sides and matchups" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            inline for (.{ .{ "agony_timer", C.AgonyDuration, C.AgonyDps }, .{ "corruption_timer", C.CorruptionDuration, C.CorruptionDps }, .{ "immolate_timer", C.ImmolateDuration, C.ImmolateDps }, .{ "siphon_timer", C.SiphonLifeDuration, C.SiphonLifeDps } }) |effect| {
                var expected_hp: f32 = 0;
                var expected_rng: u32 = 0;
                for ([_]f32{ 0.01, 0.02, 0.1, 0.25 }) |dt| {
                    var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
                    defer arena.deinit();
                    const state = arena.combat();
                    disablePets(state);
                    @memset(@field(state, effect[0] ++ target), effect[1]);
                    // Nontrivial crit probability exercises per-tick RNG, not
                    // just equivalent expected DPS with forced critical rolls.
                    for (0..16) |lane| r.setStats(state, side, lane, .{ .spell_crit_chance = 0.37 });
                    const steps: usize = @intFromFloat(@round(effect[1] / dt));
                    for (0..steps) |_| _ = arena.tickPhysics16(dt, 0);
                    const hp = @field(state, "hp" ++ target)[0];
                    const rng = @field(state, "spell_rng" ++ own)[0];
                    if (dt == 0.01) {
                        expected_hp = hp;
                        expected_rng = rng;
                    }
                    try std.testing.expectApproxEqAbs(expected_hp, hp, 0.002);
                    try std.testing.expectEqual(expected_rng, rng);
                    try std.testing.expectEqual(@as(f32, 0), @field(state, effect[0] ++ target)[0]);
                    try std.testing.expect(hp < C.MaxHp - effect[1] * effect[2] + 0.01);
                }
            }
        }
    }
}

test "Drain Life ticks at one second includes final tick and cancellation discards unfinished tick" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            disablePets(state);
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @memset(@field(state, "hp" ++ own), 1000);
            for (0..16) |lane| r.setStats(state, side, lane, .{ .spell_crit_chance = 1 });
            if (side) arena.applyActionA(0, @splat(5), @splat(0)) else arena.applyActionB(0, @splat(5), @splat(0));
            _ = arena.tickPhysics16(0.99, 0);
            try std.testing.expectEqual(@as(f32, 2000), @field(state, "hp" ++ target)[0]);
            _ = arena.tickPhysics16(0.01, 0);
            try std.testing.expectApproxEqAbs(2000 - 1.5 * C.DrainLifeDps, @field(state, "hp" ++ target)[0], 0.001);
            try std.testing.expectApproxEqAbs(1000 + 1.5 * C.DrainLifeHps, @field(state, "hp" ++ own)[0], 0.001);
            _ = arena.tickPhysics16(2, 0);
            try std.testing.expectApproxEqAbs(2000 - 4.5 * C.DrainLifeDps, @field(state, "hp" ++ target)[0], 0.001);
            try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_id" ++ own)[0]);
            @memset(@field(state, "gcd" ++ own), 0);
            if (side) arena.applyActionA(0, @splat(5), @splat(0)) else arena.applyActionB(0, @splat(5), @splat(0));
            _ = arena.tickPhysics16(0.5, 0);
            if (side) arena.applyActionA(0, @splat(10), @splat(0)) else arena.applyActionB(0, @splat(10), @splat(0));
            const before = @field(state, "hp" ++ target)[0];
            _ = arena.tickPhysics16(1, 0);
            try std.testing.expectEqual(before, @field(state, "hp" ++ target)[0]);
        }
    }
}

test "failed DoT refresh preserves schedule while spending resources and successful refresh restarts" {
    var duel = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    const state = duel.arena.combat();
    disablePets(state);
    state.agony_timer_b[0] = 17;
    try duel.setCombatStats(true, .{ .spell_hit_chance = 0 });
    duel.applyMasked(@splat(.{ .ability = 1 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(@as(f32, 17), state.agony_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 1000 - C.AgonyMana), state.mana_a[0]);
    try std.testing.expectEqual(C.StandardGcd, state.gcd_a[0]);
    try duel.setCombatStats(true, .{});
    @memset(state.gcd_a, 0);
    duel.applyMasked(@splat(.{ .ability = 1 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(C.AgonyDuration, state.agony_timer_b[0]);
    _ = duel.arena.tickPhysics16(1, 0);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    _ = duel.arena.tickPhysics16(1, 0);
    try std.testing.expectEqual(@as(f32, 2000 - 2 * C.AgonyDps), state.hp_b[0]);
}

test "Pandemic packed ranks match scalar modifiers without changing adjacent talents" {
    for (0..4) |rank| {
        const ranks = spec.WarlockTalentRanks{ .pandemic = @intCast(rank), .malevolence = 5, .ruin = 4, .fire_and_brimstone = 3 };
        const fx = @import("warlock_talents.zig").decode(@splat(@truncate(ranks.encode())), @splat(@truncate(ranks.encode() >> 32)));
        try std.testing.expectEqual(spec.CombatModifiers.fromWarlockRanks(ranks).affliction_crit_multiplier, fx.affliction_crit_multiplier[0]);
        try std.testing.expectApproxEqAbs(@as(f32, 0.05), fx.shadow_crit_bonus[0], 0.00001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.9), fx.destruction_crit_multiplier[0], 0.00001);
        try std.testing.expectEqual(@as(f32, 0.25), fx.conflagrate_crit_bonus[0]);
    }
}

test "periodic crit and partial resistance continuation restores exactly across SIMD lanes" {
    var duel = try search.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer duel.deinit();
    duel.setWarlockTalentRanksA((spec.WarlockTalentRanks{ .pandemic = 3, .malevolence = 5 }).encode());
    try duel.setCombatStats(true, .{ .spell_crit_chance = 0.35, .spell_penetration = 10 });
    try duel.setCombatStats(false, .{ .shadow_resistance = 70 });
    const state = duel.arena.combat();
    disablePets(state);
    state.corruption_timer_b[0] = C.CorruptionDuration;
    state.agony_timer_b[0] = C.AgonyDuration;
    _ = duel.arena.tickPhysics16(0.7, 0);
    const before = duel.snapshot(0);
    for (0..16) |lane| duel.restore(lane, before);
    for (0..250) |_| _ = duel.arena.tickPhysics16(0.01, 0);
    const after = duel.snapshot(0);
    for (0..16) |lane| try std.testing.expectEqualDeep(after, duel.snapshot(lane));
    for (0..16) |lane| duel.restore(lane, before);
    for (0..250) |_| _ = duel.arena.tickPhysics16(0.01, 0);
    for (0..16) |lane| try std.testing.expectEqualDeep(after, duel.snapshot(lane));
}
