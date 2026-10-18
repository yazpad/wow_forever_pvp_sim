const std = @import("std");
const r = @import("spell_resolution.zig");
const simd = @import("simd.zig");
const combat = @import("combat_spec.zig");
const multi = @import("multi_spec.zig");
const search = @import("search_sim.zig");
const spec = @import("spec.zig");
const talents = @import("warlock_talents.zig");
const V = simd.f32x16;

test "spell resolution matches scalar rolls with distinct miss resist hit and crit outcomes" {
    var hit: V = undefined;
    var resist: V = undefined;
    var crit: V = undefined;
    var mask: simd.bool16 = @splat(true);
    var rolls: [3]V = undefined;
    for (0..16) |lane| {
        hit[lane] = if (lane % 4 == 0) 0 else 1;
        resist[lane] = if (lane % 4 == 1) 1 else 0;
        crit[lane] = if (lane % 4 == 3) 1 else 0;
        rolls[0][lane] = @as(f32, @floatFromInt(lane)) / 16;
        rolls[1][lane] = 0;
        rolls[2][lane] = 0.999999;
    }
    mask[15] = false;
    const resolved = r.resolveRolls(@splat(100), hit, resist, crit, @splat(2), rolls, mask);
    for (0..16) |lane| {
        const expected: r.Outcome = if (!mask[lane]) .none else if (rolls[0][lane] >= hit[lane]) .miss else if (rolls[1][lane] < resist[lane]) .resist else if (rolls[2][lane] < crit[lane]) .crit else .hit;
        try std.testing.expectEqual(@intFromEnum(expected), resolved.outcome[lane]);
        try std.testing.expectEqual(expected == .hit or expected == .crit, resolved.landed[lane]);
        const damage: f32 = switch (expected) {
            .hit => 100,
            .crit => 200,
            else => 0,
        };
        try std.testing.expectEqual(damage, resolved.damage[lane]);
    }
    const clamped = r.resolveRolls(@splat(100), @splat(2), @splat(-1), @splat(2), @splat(1.5), .{ @splat(0.99), @splat(0), @splat(0.99) }, @splat(true));
    try std.testing.expectEqual(@as(f32, 150), clamped.damage[0]);
}

test "combat stat probabilities reject invalid values" {
    try (r.Stats{}).validate();
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .spell_hit_chance = 1.01 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .fire_resist_chance = -0.1 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .spell_crit_chance = std.math.nan(f32) }).validate());
}

test "spell resolution talent ranks preserve neighbors and match scalar modifiers" {
    for (0..6) |rank| {
        const ranks = spec.WarlockTalentRanks{ .suppression = @intCast(rank), .malevolence = @intCast(rank), .ruin = @intCast(rank), .fire_and_brimstone = @intCast(@min(rank, 3)), .agonizing_flames = @intCast(@min(rank, 3)), .improved_sayaad = 3, .improved_felhunter = 2, .conflagrate = 1 };
        const fx = talents.decode(@splat(@truncate(ranks.encode())), @splat(@truncate(ranks.encode() >> 32)));
        const scalar = spec.CombatModifiers.fromWarlockRanks(ranks);
        inline for (.{ "spell_hit_bonus", "shadow_crit_bonus", "destruction_crit_multiplier", "conflagrate_crit_bonus", "searing_pain_crit_bonus", "destruction_damage_mult" }) |field|
            try std.testing.expectApproxEqAbs(@field(scalar, field), @field(fx, field)[0], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.3), fx.seduction_duration_mult[0], 0.0001);
        try std.testing.expectEqual(@as(f32, 20), fx.spell_lock_cooldown[0]);
    }
}

test "production direct casts resolve misses resists crits and Immolate application across matchups" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            inline for (.{ @as(u32, 4), 11, 12, 13 }) |spell| {
                const actor = if (side) pair[0] else pair[1];
                if (actor != .warlock and spell != 4) continue;
                var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
                defer arena.deinit();
                const state = arena.combat();
                const own = if (side) "_a" else "_b";
                const target = if (side) "_b" else "_a";
                for (0..16) |lane| {
                    r.setStats(state, side, lane, .{ .spell_hit_chance = if (lane % 4 == 0) 0 else 1, .spell_crit_chance = if (lane % 4 == 3) 1 else 0 });
                    const resist: f32 = if (lane % 4 == 1) 1 else 0;
                    r.setStats(state, !side, lane, .{ .shadow_resist_chance = resist, .fire_resist_chance = resist, .frost_resist_chance = resist });
                    const ranks = spec.WarlockTalentRanks{ .ruin = @intCast(lane / 4) };
                    @field(state, "talent_ranks" ++ own)[lane] = @truncate(ranks.encode());
                    @field(state, "talent_flags" ++ own)[lane] = @truncate(ranks.encode() >> 32);
                    @field(state, "cast_id" ++ own)[lane] = spell;
                    @field(state, "cast_timer" ++ own)[lane] = 0.001;
                    @field(state, "pet_kind" ++ own)[lane] = 0;
                    @field(state, "pet_kind" ++ target)[lane] = 0;
                }
                _ = arena.tickPhysics16(0.01, 0);
                var damage: [16]f32 = @splat(0);
                for (0..120) |_| {
                    _ = arena.tickPhysics16(0.01, 0);
                    for (0..16) |lane| damage[lane] += @field(state, "impact_bolt" ++ own)[lane];
                }
                const base: f32 = switch (spell) {
                    4 => combat.WarlockConstants.ShadowBoltDamage,
                    11 => combat.WarlockConstants.SearingPainDamage,
                    12 => combat.WarlockConstants.IncinerateDamage,
                    13 => combat.WarlockConstants.ImmolateInitialDamage,
                    else => unreachable,
                };
                for (0..16) |lane| {
                    const expected: f32 = switch (lane % 4) {
                        2 => base,
                        3 => base * (if (actor == .warlock) 1.5 + 0.1 * @as(f32, @floatFromInt(lane / 4)) else 1.5),
                        else => 0,
                    };
                    try std.testing.expectApproxEqAbs(expected, damage[lane], 0.001);
                    try std.testing.expectEqual(@as(u32, switch (lane % 4) {
                        0 => 1,
                        1 => 2,
                        2 => 3,
                        else => 4,
                    }), @field(state, "spell_outcome" ++ own)[lane]);
                    if (spell == 13) try std.testing.expectEqual(lane % 4 >= 2, @field(state, "immolate_timer" ++ target)[lane] > 0);
                    try std.testing.expectEqual(@as(f32, 0), @field(state, "projectile_count" ++ own)[lane]);
                }
            }
        }
    }
}

test "instant resolution survives simultaneous one-sided and scalar-to-SIMD snapshot replay" {
    var duel = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    duel.setWarlockTalentRanksA((spec.WarlockTalentRanks{ .conflagrate = 1, .ruin = 5, .fire_and_brimstone = 3 }).encode());
    duel.setWarlockTalentRanksB((spec.WarlockTalentRanks{ .conflagrate = 1 }).encode());
    try duel.setCombatStats(true, .{ .spell_hit_chance = 0.8, .spell_crit_chance = 0.5 });
    try duel.setCombatStats(false, .{ .spell_hit_chance = 0.8, .spell_crit_chance = 0.5, .fire_resist_chance = 0.2 });
    const state = duel.arena.combat();
    state.immolate_timer_a[0] = 10;
    state.immolate_timer_b[0] = 10;
    // Exercise a nondefault seed; immutable spec data and mutable roll state
    // must remain separate through both action staging paths.
    state.spell_rng_a[0] = 900;
    const before = duel.snapshot(0);
    inline for (.{ true, false }) |simultaneous| {
        duel.restore(0, before);
        duel.applyMasked(@splat(.{ .ability = 16 }), @splat(.{ .ability = 16 }), @splat(true), @splat(simultaneous));
        const after = duel.snapshot(0);
        try std.testing.expect(state.spell_rng_a[0] != 900);
        try std.testing.expectEqual(if (simultaneous) @as(f32, 900) else @as(f32, 1000), state.mana_b[0]);
        for (0..16) |lane| duel.restore(lane, before);
        duel.applyMasked(@splat(.{ .ability = 16 }), @splat(.{ .ability = 16 }), @splat(true), @splat(simultaneous));
        for (0..16) |lane| try std.testing.expectEqualDeep(after, duel.snapshot(lane));
    }
    duel.restore(0, before);
    const rng_before = state.spell_rng_a[0];
    duel.applyMasked(@splat(.{ .ability = 16 }), @splat(.{}), @splat(false), @splat(false));
    try std.testing.expectEqual(rng_before, state.spell_rng_a[0]);
}

test "Conflagrate misses and resists spend resources without damage or on-hit procs" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            const encoded = (spec.WarlockTalentRanks{ .conflagrate = 1, .ruin = 5, .aftermath = 5, .shadow_and_flame = 5 }).encode();
            for (0..16) |lane| {
                @field(state, "talent_ranks" ++ own)[lane] = @truncate(encoded);
                @field(state, "talent_flags" ++ own)[lane] = @truncate(encoded >> 32);
                @field(state, "immolate_timer" ++ target)[lane] = 10;
                r.setStats(state, side, lane, .{ .spell_hit_chance = if (lane % 4 == 0) 0 else 1, .spell_crit_chance = if (lane % 4 == 2) 1 else 0 });
                r.setStats(state, !side, lane, .{ .fire_resist_chance = if (lane % 4 == 1) 1 else 0 });
            }
            const idle_rng = @field(state, "spell_rng" ++ own)[15];
            state.is_active[15] = 0;
            var actions: simd.u32x16 = @splat(16);
            actions[15] = 0; // Raw mirror kernels expect caller-validated actions.
            if (side) arena.applyActionA(0, actions, @splat(0)) else arena.applyActionB(0, actions, @splat(0));
            for (0..15) |lane| {
                const landed = lane % 4 >= 2;
                const expected: f32 = if (landed) combat.WarlockConstants.ConflagrateDamage * 1.1 * (if (lane % 4 == 2) @as(f32, 2) else 1) else 0;
                try std.testing.expectApproxEqAbs(expected, @field(state, "conflagrate_pending" ++ own)[lane], 0.001);
                try std.testing.expectEqual(@as(f32, 900), @field(state, "mana" ++ own)[lane]);
                try std.testing.expectEqual(@as(f32, 10), @field(state, "conflagrate_cd" ++ own)[lane]);
                try std.testing.expectEqual(@as(f32, if (landed) 5 else 0), @field(state, "daze_timer" ++ target)[lane]);
                try std.testing.expectEqual(@as(f32, if (landed) 20 else 0), @field(state, "shadow_flame_timer" ++ own)[lane]);
            }
            try std.testing.expectEqual(idle_rng, @field(state, "spell_rng" ++ own)[15]);
            try std.testing.expectEqual(@as(f32, 1000), @field(state, "mana" ++ own)[15]);
        }
    }
}

test "missed Death Coil has no pending heal damage or Horror" {
    var arena = try multi.ArenaPool(.warlock, .frost_mage).init(std.testing.allocator, 16);
    defer arena.deinit();
    const state = arena.combat();
    r.setStats(state, true, 0, .{ .spell_hit_chance = 0 });
    state.hp_a[0] = 1000;
    state.pet_kind_a[0] = 0;
    arena.applyActionA(0, @splat(7), @splat(0));
    const pending = @import("projectiles.zig").pendingEffects(state, true, 0);
    try std.testing.expectEqual(@as(f32, 0), pending.damage);
    try std.testing.expectEqual(@as(f32, 0), pending.healing);
    for (0..200) |_| _ = arena.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1000), state.hp_a[0]);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 0), state.horror_timer_b[0]);
}

test "school resistance penetration and level model matches scalar calculation and partial buckets" {
    var resistance: V = undefined;
    var penetration: V = undefined;
    var level: V = undefined;
    var target: V = undefined;
    var rolls: V = undefined;
    for (0..16) |lane| {
        resistance[lane] = @as(f32, @floatFromInt(lane)) * 25;
        penetration[lane] = if (lane % 2 == 0) 50 else 0;
        level[lane] = 60;
        target[lane] = if (lane % 3 == 0) 63 else 60;
        rolls[lane] = @as(f32, @floatFromInt(lane)) / 16;
    }
    const mean = r.resistanceMean(resistance, penetration, level, target);
    const partial = r.partialFraction(mean, rolls);
    for (0..16) |lane| {
        const expected = @min(@as(f32, 0.75), (@max(@as(f32, 0), resistance[lane] - penetration[lane]) + @max(@as(f32, 0), target[lane] - level[lane]) * 5) * 0.75 / (5 * level[lane]));
        try std.testing.expectApproxEqAbs(expected, mean[lane], 0.00001);
        const buckets = expected * 4;
        const fraction = (@floor(buckets) + @as(f32, if (rolls[lane] < buckets - @floor(buckets)) 1 else 0)) / 4;
        try std.testing.expectEqual(fraction, partial[lane]);
    }
    try (r.Stats{ .level = 60, .shadow_resistance = 300, .spell_penetration = 100 }).validate();
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .level = 0 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .level = 60.5 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .shadow_resistance = -1 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (r.Stats{ .pet_hit_chance = 2 }).validate());
}

test "partial resists affect direct and periodic damage but applications and binary control stay whole" {
    var state = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer state.deinit();
    for (0..16) |lane| r.setStats(&state, false, lane, .{ .fire_resistance = 100, .shadow_resistance = 100 });
    const direct = r.resolve(&state, true, 0, @splat(100), @splat(true), .{ .school = .fire });
    const periodic_hit = r.periodic(&state, true, 0, @splat(100), @splat(true), .{ .school = .shadow });
    for (0..16) |lane| {
        try std.testing.expectEqual(@as(f32, 75), direct.damage[lane]);
        try std.testing.expectEqual(@as(f32, 75), periodic_hit.damage[lane]);
    }
    const before = state.spell_rng_a[0];
    const application = r.resolve(&state, true, 0, @splat(0), @splat(true), .{ .school = .shadow, .partial = false, .can_crit = false });
    try std.testing.expect(application.landed[0]);
    try std.testing.expect(state.spell_rng_a[0] != before);
    const binary = r.resolve(&state, true, 0, @splat(100), @splat(true), .{ .school = .shadow, .binary = true, .can_crit = false });
    for (0..16) |lane| try std.testing.expect(binary.damage[lane] == 0 or binary.damage[lane] == 100);
}

test "pet attacks use pet stats separate RNG and melee avoidance armor without owner talent leakage" {
    var state = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer state.deinit();
    const pets = @import("pets.zig");
    @memset(state.pos_x_a, 0);
    @memset(state.pos_x_b, 0);
    @memset(state.pos_y_a, 0);
    @memset(state.pos_y_b, 0);
    for (0..16) |lane| {
        r.setStats(&state, true, lane, .{ .spell_hit_chance = 0, .spell_crit_chance = 0, .pet_hit_chance = if (lane % 4 == 0) 0 else 1, .pet_crit_chance = 1 });
        r.setStats(&state, false, lane, .{ .fire_resist_chance = if (lane % 4 == 1) 1 else 0, .melee_avoidance_chance = if (lane % 4 == 1) 1 else 0, .armor_damage_reduction = 0.5 });
        pets.set(&state, true, lane, .imp);
        state.pet_timer_a[lane] = 0;
    }
    const owner_rng = state.spell_rng_a[0];
    const fire = pets.tick(&state, true, 0, 0.01, @splat(60));
    for (0..16) |lane| try std.testing.expectEqual(@as(f32, if (lane % 4 < 2) 0 else 90), fire[lane]);
    try std.testing.expectEqual(owner_rng, state.spell_rng_a[0]);
    for (0..16) |lane| pets.set(&state, true, lane, .felhunter);
    const melee = pets.tick(&state, true, 0, 0.01, @splat(60));
    for (0..16) |lane| try std.testing.expectEqual(@as(f32, if (lane % 4 < 2) 0 else 40), melee[lane]);
}

test "failed applications channels and control preserve landed effects and do not consume DR" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            inline for (.{ @as(u32, 1), 2, 5, 8 }) |action| {
                var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
                defer arena.deinit();
                const state = arena.combat();
                const ranks = spec.WarlockTalentRanks{ .siphon_life = 1 };
                @memset(@field(state, "talent_ranks" ++ own), @truncate(ranks.encode()));
                @memset(state.pet_kind_a, 0);
                @memset(state.pet_kind_b, 0);
                for (0..16) |lane| {
                    r.setStats(state, side, lane, .{ .spell_hit_chance = if (lane % 2 == 0) 0 else 1 });
                    r.setStats(state, !side, lane, .{ .shadow_resist_chance = if (lane % 2 == 1) 1 else 0 });
                }
                if (side) arena.applyActionA(0, @splat(action), @splat(0)) else arena.applyActionB(0, @splat(action), @splat(0));
                for (0..16) |lane| {
                    try std.testing.expect(@field(state, "mana" ++ own)[lane] < 1000);
                    try std.testing.expectEqual(@as(f32, 0), @field(state, "agony_timer" ++ target)[lane]);
                    try std.testing.expectEqual(@as(f32, 0), @field(state, "corruption_timer" ++ target)[lane]);
                    try std.testing.expectEqual(@as(f32, 0), @field(state, "siphon_timer" ++ target)[lane]);
                    try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_id" ++ own)[lane]);
                }
            }
            var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            @memset(state.pet_kind_a, 0);
            @memset(state.pet_kind_b, 0);
            for (0..16) |lane| r.setStats(state, side, lane, .{ .spell_hit_chance = 0 });
            if (side) arena.applyActionA(0, @splat(3), @splat(0)) else arena.applyActionB(0, @splat(3), @splat(0));
            _ = arena.tickPhysics16(2, 0);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "fear_timer" ++ target)[0]);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "fear_dr_tier" ++ target)[0]);
        }
    }
}

test "simultaneous pet utility uses current pet streams stats and failed effects preserve casts and DR" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            inline for (.{ @as(u32, 14), 15 }) |action| {
                var duel = try search.Duel(pair[0], pair[1]).init(std.testing.allocator);
                defer duel.deinit();
                const state = duel.arena.combat();
                const own = if (side) "_a" else "_b";
                const target = if (side) "_b" else "_a";
                const pets = @import("pets.zig");
                for (0..16) |lane| {
                    pets.set(state, side, lane, if (action == 14) .succubus else .felhunter);
                    r.setStats(state, side, lane, .{ .spell_hit_chance = 0, .pet_hit_chance = if (lane % 3 == 0) 0 else 1 });
                    r.setStats(state, !side, lane, .{ .shadow_resist_chance = if (lane % 3 == 1) 1 else 0 });
                    @field(state, "pet_rng" ++ own)[lane] = @intCast(900 + lane);
                    @field(state, "cast_id" ++ target)[lane] = 4;
                    @field(state, "cast_timer" ++ target)[lane] = 2;
                    @field(state, "cast_total" ++ target)[lane] = 2;
                }
                const before = duel.snapshot(0);
                duel.applyMasked(@splat(.{ .ability = if (side) action else 0 }), @splat(.{ .ability = if (side) 0 else action }), @splat(true), @splat(true));
                if (action == 14) _ = duel.arena.tickPhysics16(1.5, 0);
                for (0..16) |lane| {
                    const landed = lane % 3 == 2;
                    try std.testing.expectEqual(!landed, @field(state, "cast_id" ++ target)[lane] == 4);
                    if (action == 15 and landed) try std.testing.expectEqual(@as(f32, 0), @field(state, "react_timer" ++ target)[lane]);
                    if (action == 14) {
                        try std.testing.expectEqual(landed, @field(state, "seduction_timer" ++ target)[lane] > 0);
                        try std.testing.expectEqual(@as(f32, if (landed) 1 else 0), @field(state, "seduction_dr_tier" ++ target)[lane]);
                    }
                }
                const after = duel.snapshot(0);
                duel.restore(0, before);
                duel.applyMasked(@splat(.{ .ability = if (side) action else 0 }), @splat(.{ .ability = if (side) 0 else action }), @splat(true), @splat(true));
                if (action == 14) _ = duel.arena.tickPhysics16(1.5, 0);
                try std.testing.expectEqualDeep(after, duel.snapshot(0));
            }
        }
    }
}

test "missed Mage control spends cooldown without applying root interrupt or diminishing returns" {
    var duel = try search.Duel(.frost_mage, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    try duel.setCombatStats(true, .{ .spell_hit_chance = 0 });
    const state = duel.arena.combat();
    state.cast_id_b[0] = 4;
    state.cast_timer_b[0] = 1;
    state.cast_total_b[0] = 1.8;
    state.react_timer_b[0] = 0.05;
    duel.applyMasked(@splat(.{ .ability = 7 }), @splat(.{}), @splat(true), @splat(true));
    try std.testing.expectEqual(@as(u32, 4), state.cast_id_b[0]);
    try std.testing.expectEqual(@as(f32, 1), state.cast_timer_b[0]);
    try std.testing.expectEqual(combat.WarlockConstants.ReactionInterval, state.react_timer_b[0]);
    try std.testing.expect(state.death_coil_cd_a[0] > 0);
    const extras = duel.arena.frostTelemetry(false, 0);
    try std.testing.expectEqual(@as(f32, 0), extras[3]);
    state.distance[0] = 5;
    state.pos_x_a[0] = -2.5;
    state.pos_x_b[0] = 2.5;
    @memset(state.react_timer_a, 0);
    duel.applyMasked(@splat(.{ .ability = 2 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(@as(f32, 0), state.agony_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 0), state.horror_dr_tier_b[0]);
    try std.testing.expect(duel.arena.frostTelemetry(true, 0)[1] > 0);
}

test "Improved Shadow Bolt applies on SB crit, amplifies shadow damage, and consumes charges" {
    var duel = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();

    const ranks_a = spec.WarlockTalentRanks{ .improved_shadow_bolt = 5 };
    const encoded_ranks_a: u32 = @truncate(ranks_a.encode());
    const encoded_flags_a: u32 = @truncate(ranks_a.encode() >> 32);

    const state = duel.arena.combat();
    state.talent_ranks_a[0] = encoded_ranks_a;
    state.talent_flags_a[0] = encoded_flags_a;

    // Guaranteed hit and crit for caster A
    try duel.setCombatStats(true, .{
        .spell_hit_chance = 1.0,
        .spell_crit_chance = 1.0,
    });
    try duel.setCombatStats(false, .{
        .shadow_resist_chance = 0.0,
    });

    state.distance[0] = 10.0;
    state.pos_x_a[0] = -5.0;
    state.pos_x_b[0] = 5.0;

    // Start Shadow Bolt cast for Unit A
    duel.applyMasked(@splat(.{ .ability = 4 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(@as(u32, 4), state.cast_id_a[0]);

    // Fast-forward cast completion
    _ = duel.arena.tickPhysics16(3.0, 0);

    // After SB crit lands, ISB debuff should be active on Unit B: 12s timer, 4 charges, 20% vuln (0.20)
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), state.isb_timer_b[0], 0.05);
    try std.testing.expectEqual(@as(f32, 4.0), state.isb_charges_b[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), state.isb_vuln_b[0], 0.001);

    // Now test shadow damage amplification and charge consumption:
    // Cast Corruption (ability 2, instant DoT)
    const hp_before_dot = state.hp_b[0];
    duel.applyMasked(@splat(.{ .ability = 2 }), @splat(.{}), @splat(true), @splat(false));

    // Tick physics to let a corruption tick happen (Corruption ticks every 3s in base sim)
    _ = duel.arena.tickPhysics16(3.0, 0);

    // Debuff charges should have decremented by 1 upon taking shadow damage tick
    try std.testing.expectEqual(@as(f32, 3.0), state.isb_charges_b[0]);
    const dot_damage = hp_before_dot - state.hp_b[0];
    // Corruption tick base is ~66.67. With 20% ISB amp, damage should be amplified by ~1.20x
    try std.testing.expect(dot_damage > 70.0);
}

test "Agonizing Flames provides Searing Pain crit bonus and Destruction damage bonus" {
    var duel = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();

    // Rank 3 Agonizing Flames (+10% Searing Pain crit, +10% Destruction damage)
    const ranks_a = spec.WarlockTalentRanks{ .agonizing_flames = 3 };
    const encoded_ranks_a: u32 = @truncate(ranks_a.encode());
    const encoded_flags_a: u32 = @truncate(ranks_a.encode() >> 32);

    const state = duel.arena.combat();
    state.talent_ranks_a[0] = encoded_ranks_a;
    state.talent_flags_a[0] = encoded_flags_a;

    // Base crit chance is 0.05. With rank 3 Agonizing Flames (+0.10), Searing Pain effective crit chance is 0.15.
    try duel.setCombatStats(true, .{
        .spell_hit_chance = 1.0,
        .spell_crit_chance = 0.05,
    });
    try duel.setCombatStats(false, .{
        .fire_resist_chance = 0.0,
    });

    state.distance[0] = 10.0;
    state.pos_x_a[0] = -5.0;
    state.pos_x_b[0] = 5.0;

    // Start Searing Pain cast for Unit A (ability 11)
    duel.applyMasked(@splat(.{ .ability = 11 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(@as(u32, 11), state.cast_id_a[0]);

    // Fast-forward cast completion
    _ = duel.arena.tickPhysics16(2.0, 0);

    // Baseline Searing Pain damage is 130.0. With rank 3 Agonizing Flames (+10%), base damage is 143.0.
    // If not crit, impact damage is 143.0. If crit, impact damage is 143.0 * 1.5 = 214.5.
    const proj_damage = state.projectile_0_damage_a[0];
    const is_crit = state.spell_outcome_a[0] == @intFromEnum(@import("spell_resolution.zig").Outcome.crit);
    if (is_crit) {
        try std.testing.expectApproxEqAbs(@as(f32, 143.0 * 1.5), proj_damage, 0.01);
    } else {
        try std.testing.expectApproxEqAbs(@as(f32, 143.0), proj_damage, 0.01);
    }
}


