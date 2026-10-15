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
