const std = @import("std");
const pets = @import("pets.zig");
const combat = @import("combat_spec.zig");
const sim = @import("search_sim.zig");
const multi = @import("multi_spec.zig");
const mcts = @import("mcts.zig");

test "frost telemetry reads individual lanes without SIMD alignment assumptions" {
    var arena = try multi.ArenaPool(.warlock, .frost_mage).init(std.testing.allocator, 32);
    defer arena.deinit();
    for (0..32) |lane| arena.extras[7 * 32 + lane] = @floatFromInt(lane * 10);
    for (0..32) |lane| try std.testing.expectEqual(@as(f32, @floatFromInt(lane * 10)), arena.frostTelemetry(false, lane)[2]);
}

test "pet types, reset, and HP survive independently of player resources" {
    var p = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer p.deinit();
    inline for ([_]pets.Kind{ .imp, .succubus, .felhunter, .voidwalker }) |kind| {
        pets.set(&p, true, 0, kind);
        try std.testing.expectEqual(kind, pets.Kind.parse(@tagName(kind)).?);
        try std.testing.expectEqual(kind.maxHp(), p.pet_hp_a[0]);
        p.mana_a[0] = 0;
        p.pet_hp_a[0] = 123;
        _ = p.tickPhysics16(0.01, 0);
        try std.testing.expectEqual(@as(f32, 123), p.pet_hp_a[0]);
        p.resetDuel(0);
        try std.testing.expectEqual(@as(u32, 0), p.pet_kind_a[0]);
        try std.testing.expectEqual(@as(f32, 0), p.pet_hp_a[0]);
    }
}

test "imp casts before damage, repeats, and restarts after leaving range" {
    var p = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer p.deinit();
    pets.set(&p, true, 0, .imp);
    for (0..199) |_| _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 2000), p.hp_b[0]);
    for (0..2) |_| _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1940), p.hp_b[0]);
    for (0..201) |_| _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1880), p.hp_b[0]);
    p.pet_timer_a[0] = 0.01;
    p.pet_x_a[0] = -100;
    _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, pets.AttackInterval), p.pet_timer_a[0]);
    try std.testing.expectEqual(@as(f32, 1880), p.hp_b[0]);
}

test "melee pets chase in 2D, stop at range, and hit only the player" {
    var p = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer p.deinit();
    pets.set(&p, true, 0, .succubus);
    pets.set(&p, false, 0, .voidwalker);
    p.pet_hp_b[0] = 0; // Disabled enemy pet still cannot be an attack target.
    const x = p.pet_x_a[0];
    const y = p.pet_y_a[0];
    _ = p.tickPhysics16(0.01, 0);
    try std.testing.expect(p.pet_x_a[0] > x);
    try std.testing.expect(p.pet_y_a[0] < y);
    try std.testing.expectEqual(@as(f32, 2000), p.hp_b[0]);
    for (0..330) |_| _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1950), p.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 0), p.pet_hp_b[0]);
    const stopped = p.pet_x_a[0];
    for (0..10) |_| _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectApproxEqAbs(stopped, p.pet_x_a[0], 0.001);
}

test "divergent SIMD lanes respect pet HP, owner HP, and duel activity" {
    var p = try combat.WarlockArenaPool.init(std.testing.allocator, 32);
    defer p.deinit();
    for (0..32) |lane| {
        pets.set(&p, true, lane, .imp);
        p.pet_timer_a[lane] = 0;
    }
    p.pet_hp_a[1] = 0;
    p.hp_a[2] = 0;
    p.is_active[3] = 0;
    _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1940), p.hp_b[0]);
    for (1..4) |lane| try std.testing.expectEqual(@as(f32, 2000), p.hp_b[lane]);
    try std.testing.expectEqual(@as(f32, 2000), p.hp_b[16]);
    try std.testing.expectEqual(@as(f32, 0), p.pet_timer_a[16]);
    try std.testing.expectEqual(@as(f32, 0), p.impact_pet_a[1]);
}

test "Soul Link shares incoming damage, fear breaks, overkill, and simultaneous death" {
    var p = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer p.deinit();
    pets.set(&p, true, 0, .imp);
    pets.set(&p, false, 0, .imp);
    p.soul_link_b[0] = 1;
    p.pet_timer_a[0] = 0;
    p.fear_timer_b[0] = 3;
    p.fear_accum_dmg_b[0] = 240;
    _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1958), p.hp_b[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 482), p.pet_hp_b[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), p.impact_pet_a[0], 0.001);
    try std.testing.expectEqual(@as(f32, 0), p.fear_timer_b[0]);
    pets.set(&p, false, 0, .imp);
    p.pet_timer_a[0] = 0;
    p.pet_timer_b[0] = 0;
    p.hp_a[0] = 10;
    p.hp_b[0] = 10;
    _ = p.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 0), p.hp_a[0]);
    try std.testing.expectEqual(@as(f32, 0), p.hp_b[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.impact_pet_a[0], 0.001);
    try std.testing.expectEqual(@as(u32, 0), p.is_active[0]);
}

test "mixed spec shields absorb pet hits and controlled owners do not control pets" {
    inline for (.{ true, false }) |warlock_a| {
        const A = multi.ArenaPool(if (warlock_a) .warlock else .frost_mage, if (warlock_a) .frost_mage else .warlock);
        var arena = try A.init(std.testing.allocator, 16);
        defer arena.deinit();
        const p = arena.combat();
        const target = if (warlock_a) "_b" else "_a";
        pets.set(p, warlock_a, 0, .imp);
        @field(p, if (warlock_a) "pet_timer_a" else "pet_timer_b")[0] = 0;
        @field(p, "action6_dur" ++ target)[0] = 5;
        const shield = (if (warlock_a) @as(usize, 5) else 0) + 2;
        arena.extras[shield * p.capacity] = 100;
        _ = arena.tickPhysics16(0.01, 0);
        try std.testing.expectEqual(@as(f32, 2000), @field(p, "hp" ++ target)[0]);
        try std.testing.expectEqual(@as(f32, 40), arena.extras[shield * p.capacity]);
        try std.testing.expectEqual(@as(f32, 0), @field(p, if (warlock_a) "impact_pet_a" else "impact_pet_b")[0]);
    }
    var arena = try multi.ArenaPool(.warlock, .frost_mage).init(std.testing.allocator, 16);
    defer arena.deinit();
    const p = arena.combat();
    // An already-active pet on a polymorphed owner still acts autonomously.
    pets.set(p, true, 0, .imp);
    p.pet_timer_a[0] = 0;
    p.fear_timer_a[0] = 3;
    _ = arena.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 1940), p.hp_b[0]);
}

test "pet snapshots replay exactly through both action staging paths without new choices" {
    var fast = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer fast.deinit();
    var reference = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer reference.deinit();
    const before = fast.choices(true, 0, fast.arena.getActionMaskA(0));
    const p = fast.arena.combat();
    for (0..16) |lane| {
        pets.set(p, true, lane, if (lane % 2 == 0) .imp else .succubus);
        p.pet_hp_a[lane] = @floatFromInt(100 + lane);
        p.pet_timer_a[lane] = @as(f32, @floatFromInt(lane)) * 0.1;
        reference.restore(lane, fast.snapshot(lane));
    }
    try std.testing.expectEqualDeep(before, fast.choices(true, 0, fast.arena.getActionMaskA(0)));
    const saved = fast.snapshot(0);
    var end: sim.Snapshot = undefined;
    for (0..2) |pass| {
        for (0..220) |step| {
            const aa: [16]sim.Action = @splat(.{ .ability = 2 });
            const bb: [16]sim.Action = @splat(.{});
            const ra: @Vector(16, bool) = @splat(true);
            const rb: @Vector(16, bool) = @splat(step % 2 == 0);
            fast.applyMasked(aa, bb, ra, rb);
            reference.applyMaskedReference(aa, bb, ra, rb);
            fast.tick(6000);
            reference.tick(6000);
            for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
        }
        if (pass == 0) end = fast.snapshot(0) else try std.testing.expectEqualDeep(end, fast.snapshot(0));
        fast.restore(0, saved);
        reference.restore(0, saved);
    }
    const search = try mcts.Search(.warlock, .frost_mage).init(std.testing.allocator, .{ .rollouts = 32, .nodes = 16, .depth = 2, .max_ticks = 100 });
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(7);
    const r = search.decide(saved, rng.random());
    try std.testing.expectEqual(@as(u64, 32), r.stats.rollouts);
    try std.testing.expect(r.choices[0].len <= 27);
    try std.testing.expectEqualDeep(saved, fast.snapshot(0));
}

test "Spell Lock preserves school lockout through simultaneous actions and snapshots" {
    inline for (.{ true, false }) |attacker_a| {
        inline for (.{ @as(u32, 3), 4, 5, 11, 12, 13 }) |cast_id| {
            var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
            defer d.deinit();
            const state = d.arena.combat();
            @memset(state.distance, 15);
            const target = if (attacker_a) "_b" else "_a";
            pets.set(state, attacker_a, 0, .felhunter);
            @field(state, "cast_id" ++ target)[0] = cast_id;
            @field(state, "cast_timer" ++ target)[0] = 1;
            @field(state, "cast_total" ++ target)[0] = 2;
            // A simultaneous Cancel Cast must not erase the enemy's lockout.
            const lock: sim.Action = .{ .ability = 15 };
            const cancel: sim.Action = .{ .ability = 10 };
            d.applyMasked(@splat(if (attacker_a) lock else cancel), @splat(if (attacker_a) cancel else lock), @splat(true), @splat(true));
            try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_id" ++ target)[0]);
            const shadow = cast_id <= 5;
            const timer = if (shadow) "shadow_lockout" else "fire_lockout";
            try std.testing.expectEqual(combat.WarlockConstants.SpellLockDuration, @field(state, timer ++ target)[0]);
            const masks = if (attacker_a) d.getActionMaskB(0) else d.getActionMaskA(0);
            inline for (.{ 1, 2, 3, 4, 5, 7 }) |slot| try std.testing.expectEqual(!shadow, masks[slot][0]);
            inline for (.{ 11, 12, 13 }) |slot| try std.testing.expectEqual(shadow, masks[slot][0]);
            try std.testing.expect(masks[0][0]);
            // Adjacent lanes must remain unaffected.
            try std.testing.expectEqual(@as(f32, 0), @field(state, timer ++ target)[1]);
            const snapshot = d.snapshot(0);
            _ = d.arena.tickPhysics16(3.99, 0);
            try std.testing.expect(@field(state, timer ++ target)[0] > 0);
            _ = d.arena.tickPhysics16(0.02, 0);
            try std.testing.expectEqual(@as(f32, 0), @field(state, timer ++ target)[0]);
            d.restore(0, snapshot);
            try std.testing.expectEqual(combat.WarlockConstants.SpellLockDuration, @field(state, timer ++ target)[0]);
            state.resetDuel(0);
            try std.testing.expectEqual(@as(f32, 0), @field(state, timer ++ target)[0]);
        }
    }
}

test "Aftermath scales Immolate projectile hits in mirrors and mixed matchups on either side" {
    inline for (.{ multi.ArenaPool(.warlock, .warlock), multi.ArenaPool(.warlock, .frost_mage), multi.ArenaPool(.frost_mage, .warlock) }) |Arena| {
        var arena = try Arena.init(std.testing.allocator, 16);
        defer arena.deinit();
        const state = arena.combat();
        inline for (.{ true, false }) |side| {
            const suffix = if (side) "_a" else "_b";
            for (0..6) |lane| {
                const ranks = @import("spec.zig").WarlockTalentRanks{ .aftermath = @intCast(lane), .shadow_and_flame = 5 };
                @field(state, "talent_ranks" ++ suffix)[lane] = @truncate(ranks.encode());
                @field(state, "talent_flags" ++ suffix)[lane] = @truncate(ranks.encode() >> 32);
                @field(state, "cast_id" ++ suffix)[lane] = 13;
                @field(state, "cast_timer" ++ suffix)[lane] = 0.001;
            }
        }
        _ = arena.tickPhysics16(0.01, 0);
        var impacts_a: [6]f32 = @splat(0);
        var impacts_b: [6]f32 = @splat(0);
        for (0..150) |_| {
            _ = arena.tickPhysics16(0.01, 0);
            for (0..6) |lane| {
                impacts_a[lane] += state.impact_bolt_a[lane];
                impacts_b[lane] += state.impact_bolt_b[lane];
            }
        }
        for (0..6) |lane| {
            const expected = combat.WarlockConstants.ImmolateInitialDamage * 1.1 * (1.0 + 0.1 * @as(f32, @floatFromInt(lane)));
            // Only the Warlock side in mixed matchups launches Immolate.
            if (Arena == multi.ArenaPool(.warlock, .warlock) or Arena == multi.ArenaPool(.warlock, .frost_mage))
                try std.testing.expectApproxEqAbs(expected, impacts_a[lane], 0.001);
            if (Arena == multi.ArenaPool(.warlock, .warlock) or Arena == multi.ArenaPool(.frost_mage, .warlock))
                try std.testing.expectApproxEqAbs(expected, impacts_b[lane], 0.001);
        }
    }
}

test "pet utility talents apply by lane and side in mirrors and mixed combat" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            const Arena = multi.ArenaPool(pair[0], pair[1]);
            var arena = try Arena.init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            const owner = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @memset(state.distance, 15);
            for (0..16) |lane| {
                const ranks = @import("spec.zig").WarlockTalentRanks{ .improved_sayaad = @intCast(lane % 4), .improved_felhunter = @intCast(lane % 4) };
                @field(state, "talent_ranks" ++ owner)[lane] = @truncate(ranks.encode());
                @field(state, "talent_flags" ++ owner)[lane] = @truncate(ranks.encode() >> 32);
                pets.set(state, side, lane, .succubus);
                @field(state, "pet_timer" ++ owner)[lane] = 100;
                @field(state, "seduction_cast" ++ owner)[lane] = 0.001;
                @field(state, "seduction_dr_tier" ++ target)[lane] = @floatFromInt(lane / 4);
                @field(state, "seduction_dr_timer" ++ target)[lane] = 15;
            }
            _ = arena.tickPhysics16(0.01, 0);
            for (0..16) |lane| {
                const dr: f32 = switch (lane / 4) {
                    0 => 1,
                    1 => 0.5,
                    2 => 0.25,
                    else => 0,
                };
                const expected = 15 * (1 + 0.1 * @as(f32, @floatFromInt(lane % 4))) * dr;
                try std.testing.expectApproxEqAbs(expected, @field(state, "seduction_timer" ++ target)[lane], 0.001);
                @field(state, "seduction_timer" ++ target)[lane] = 0;
                pets.set(state, side, lane, .felhunter);
                // Slot 4 is Shadow Bolt for Warlock and Frostbolt for Mage.
                @field(state, "cast_id" ++ target)[lane] = 4;
                @field(state, "cast_timer" ++ target)[lane] = 1;
            }
            if (side) arena.applyActionA(0, @splat(15), @splat(0)) else arena.applyActionB(0, @splat(15), @splat(0));
            for (0..16) |lane| {
                try std.testing.expectEqual(24 - 2 * @as(f32, @floatFromInt(lane % 4)), @field(state, "seduction_cd" ++ owner)[lane]);
                try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_id" ++ target)[lane]);
            }
        }
    }
}

test "Warlock masks disable catalog placeholders on both sides and every SIMD lane" {
    var duel = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    const state = duel.arena.combat();
    for (0..16) |lane| {
        state.race_a[lane] = @intCast(lane % 5);
        state.race_b[lane] = @intCast((lane + 1) % 5);
        state.horror_timer_a[lane] = if (lane % 2 == 0) 3 else 0;
        state.horror_timer_b[lane] = if (lane % 2 == 1) 3 else 0;
        pets.set(state, true, lane, if (lane % 3 == 0) .succubus else .imp);
        pets.set(state, false, lane, if (lane % 3 == 0) .felhunter else .voidwalker);
    }
    // Check the raw builders as well as the class-aware wrapper: later filters
    // must never receive uninitialized legality bits from an unused slot.
    const Mask = [combat.WarlockAction.COUNT]@Vector(16, bool);
    for ([_]Mask{ state.getActionMaskA(0), state.getActionMaskB(0), duel.getActionMaskA(0), duel.getActionMaskB(0) }) |masks| {
        inline for (std.meta.fields(combat.WarlockAction)) |field| {
            if (comptime std.mem.startsWith(u8, field.name, "Unused")) {
                for (0..16) |lane| try std.testing.expect(!masks[field.value][lane]);
            }
        }
    }
}
