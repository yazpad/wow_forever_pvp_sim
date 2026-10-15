const std = @import("std");
const combat = @import("combat_spec.zig");
const multi = @import("multi_spec.zig");
const spec = @import("spec.zig");
const search = @import("search_sim.zig");
const C = combat.WarlockConstants;
const action = @intFromEnum(combat.WarlockAction.Conflagrate);

fn ranks(state: *combat.WarlockArenaPool, comptime side: bool, lane: usize, value: spec.WarlockTalentRanks) void {
    @field(state, "talent_ranks" ++ (if (side) "_a" else "_b"))[lane] = @truncate(value.encode());
    @field(state, "talent_flags" ++ (if (side) "_a" else "_b"))[lane] = @truncate(value.encode() >> 32);
}

test "Conflagrate masks enforce talent Immolate range resources CC cast GCD and Fire lockout per lane" {
    var pool = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    inline for (.{ true, false }) |side| {
        pool.resetAll();
        const own = if (side) "_a" else "_b";
        const enemy = if (side) "_b" else "_a";
        for (0..16) |lane| {
            ranks(&pool, side, lane, .{ .conflagrate = 1 });
            @field(pool, "immolate_timer" ++ enemy)[lane] = 10;
        }
        ranks(&pool, side, 1, .{});
        @field(pool, "immolate_timer" ++ enemy)[2] = 0;
        pool.distance[3] = C.ConflagrateRange + 0.01;
        @field(pool, "mana" ++ own)[4] = C.ConflagrateMana - 0.01;
        @field(pool, "gcd" ++ own)[5] = 0.01;
        @field(pool, "cast_id" ++ own)[6] = 4;
        @field(pool, "fear_timer" ++ own)[7] = 1;
        @field(pool, "horror_timer" ++ own)[8] = 1;
        @field(pool, "seduction_timer" ++ own)[9] = 1;
        @field(pool, "conflagrate_cd" ++ own)[10] = 0.01;
        @field(pool, "fire_lockout" ++ own)[11] = 1;
        @field(pool, "shadow_lockout" ++ own)[12] = 1; // Fire remains available.
        @field(pool, "mana" ++ own)[13] = C.ConflagrateMana;
        const masks = if (side) pool.getActionMaskA(0) else pool.getActionMaskB(0);
        try std.testing.expect(masks[action][0]);
        for (1..12) |lane| try std.testing.expect(!masks[action][lane]);
        for (12..16) |lane| try std.testing.expect(masks[action][lane]);
    }
}

test "Conflagrate resolves immediately without a missile and consumes only Immolate across matchups" {
    inline for (.{ spec.Spec.warlock, spec.Spec.frost_mage }) |a| inline for (.{ spec.Spec.warlock, spec.Spec.frost_mage }) |b| {
        if (a == .frost_mage and b == .frost_mage) continue;
        var arena = try multi.ArenaPool(a, b).init(std.testing.allocator, 16);
        defer arena.deinit();
        inline for (.{ true, false }) |side| {
            if ((if (side) a else b) != .warlock) continue;
            for (0..16) |lane| arena.resetDuel(lane);
            const state = arena.combat();
            const own = if (side) "_a" else "_b";
            const enemy = if (side) "_b" else "_a";
            for (0..16) |lane| {
                ranks(state, side, lane, .{ .conflagrate = 1 });
                @field(state, "immolate_timer" ++ enemy)[lane] = 10;
            }
            if (side) arena.applyActionA(0, @splat(action), @splat(0)) else arena.applyActionB(0, @splat(action), @splat(0));
            try std.testing.expectEqual(@as(f32, 1000 - C.ConflagrateMana), @field(state, "mana" ++ own)[0]);
            try std.testing.expectEqual(C.StandardGcd, @field(state, "gcd" ++ own)[0]);
            try std.testing.expectEqual(C.ConflagrateCooldown, @field(state, "conflagrate_cd" ++ own)[0]);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "immolate_timer" ++ enemy)[0]);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "projectile_count" ++ own)[0]);
            _ = arena.tickPhysics16(0.01, 0);
            try std.testing.expectApproxEqAbs(@as(f32, 2000) - C.ConflagrateDamage, @field(state, "hp" ++ enemy)[0], 0.001);
            try std.testing.expectApproxEqAbs(C.ConflagrateDamage, @field(state, "impact_conflagrate" ++ own)[0], 0.001);
            _ = arena.tickPhysics16(0.01, 0);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "impact_conflagrate" ++ own)[0]);
            try std.testing.expectApproxEqAbs(@as(f32, 2000) - C.ConflagrateDamage, @field(state, "hp" ++ enemy)[0], 0.001);
        }
    };
}

test "Aftermath dazes and Shadow and Flame preserves Immolate and buffs Shadow damage with expiry" {
    var pool = try combat.WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    ranks(&pool, true, 0, .{ .conflagrate = 1, .aftermath = 5, .shadow_and_flame = 5 });
    pool.immolate_timer_b[0] = 15;
    pool.applyActionA(0, @splat(action), @splat(0));
    try std.testing.expectEqual(@as(f32, 15), pool.immolate_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 5), pool.daze_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 20), pool.shadow_flame_timer_a[0]);
    var effects = @import("warlock_talents.zig").decode(pool.talent_ranks_a[0..16].*, pool.talent_flags_a[0..16].*);
    @import("conflagrate.zig").buffEffects(&pool, true, 0, &effects);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), effects.shadow_damage[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), effects.corruption_damage[0], 0.0001);
    const x = pool.pos_x_b[0];
    pool.move_intent_b[0] = -1;
    _ = pool.tickPhysics16(1, 0);
    try std.testing.expectApproxEqAbs(C.ForwardSpeed * 0.5, x - pool.pos_x_b[0], 0.001);
    try std.testing.expectEqual(@as(f32, 4), pool.daze_timer_b[0]);
    // Buffed Shadowburn gets the same modifier as cast/periodic damage.
    pool.applyActionA(0, @splat(9), @splat(0));
    try std.testing.expectApproxEqAbs(C.ShadowburnDamage * 1.1, pool.projectile_0_damage_a[0], 0.001);
    _ = pool.tickPhysics16(20, 0);
    try std.testing.expectEqual(@as(f32, 0), pool.shadow_flame_timer_a[0]);
    try std.testing.expectEqual(@as(f32, 0), pool.daze_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 0), pool.conflagrate_cd_a[0]);
    pool.resetDuel(0);
    try std.testing.expectEqual(@as(f32, 0), pool.conflagrate_pending_a[0]);
}

test "Conflagrate proc RNG and simultaneous damage survive snapshot replay" {
    var duel = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    const encoded = (spec.WarlockTalentRanks{ .conflagrate = 1, .aftermath = 3, .shadow_and_flame = 3 }).encode();
    duel.setWarlockTalentRanksA(encoded);
    duel.setWarlockTalentRanksB(encoded);
    const state = duel.arena.combat();
    for (0..16) |lane| {
        state.immolate_timer_a[lane] = 10;
        state.immolate_timer_b[lane] = 10;
    }
    const before = duel.snapshot(0);
    const actions: [16]search.Action = @splat(.{ .ability = action });
    duel.applyMasked(actions, actions, @splat(true), @splat(true));
    const applied = duel.snapshot(0);
    duel.tick(6000);
    const after = duel.snapshot(0);
    try std.testing.expect(state.impact_conflagrate_a[0] > 0);
    try std.testing.expect(state.impact_conflagrate_b[0] > 0);
    duel.restore(0, before);
    duel.applyMasked(actions, actions, @splat(true), @splat(true));
    try std.testing.expectEqualDeep(applied, duel.snapshot(0));
    duel.tick(6000);
    try std.testing.expectEqualDeep(after, duel.snapshot(0));
}

test "Conflagrate damage respects barriers Molten Skin Soul Link and simultaneous death" {
    var mixed = try multi.ArenaPool(.warlock, .frost_mage).init(std.testing.allocator, 16);
    defer mixed.deinit();
    const state = mixed.combat();
    ranks(state, true, 0, .{ .conflagrate = 1 });
    state.immolate_timer_b[0] = 10;
    mixed.applyActionB(0, @splat(6), @splat(0));
    mixed.applyActionA(0, @splat(action), @splat(0));
    const barrier = mixed.frostTelemetry(false, 0)[2];
    _ = mixed.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    try std.testing.expectApproxEqAbs(barrier - C.ConflagrateDamage, mixed.frostTelemetry(false, 0)[2], 0.001);

    var mirror = try search.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer mirror.deinit();
    const s = mirror.arena.combat();
    mirror.setWarlockTalentRanksA((spec.WarlockTalentRanks{ .conflagrate = 1, .molten_skin = 5 }).encode());
    mirror.setWarlockTalentRanksB((spec.WarlockTalentRanks{ .conflagrate = 1, .molten_skin = 5 }).encode());
    for (0..16) |lane| {
        s.immolate_timer_a[lane] = 10;
        s.immolate_timer_b[lane] = 10;
    }
    @import("pets.zig").set(s, false, 0, .imp);
    s.soul_link_b[0] = 1;
    s.hp_a[1] = 1;
    s.hp_b[1] = 1;
    const actions: [16]search.Action = @splat(.{ .ability = action });
    mirror.applyMasked(actions, actions, @splat(true), @splat(true));
    mirror.tick(6000);
    try std.testing.expectApproxEqAbs(@as(f32, 2000) - C.ConflagrateDamage * 0.9 * 0.7, s.hp_b[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 500) - C.ConflagrateDamage * 0.9 * 0.3, s.pet_hp_b[0], 0.001);
    try std.testing.expectEqual(@as(f32, 0), s.hp_a[1]);
    try std.testing.expectEqual(@as(f32, 0), s.hp_b[1]);
}
