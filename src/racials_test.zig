const std = @import("std");
const sim = @import("search_sim.zig");
const racials = @import("racials.zig");
const resolution = @import("spell_resolution.zig");
const Race = @import("spec.zig").Race;
const V = @Vector(16, f32);

test "Will of the Forsaken clears Fear and Charm under control, preserving Horror, stun and DR" {
    inline for (.{ true, false }) |side| {
        var d = try sim.Duel(.priest, .warlock).init(std.testing.allocator);
        defer d.deinit();
        d.setRace(side, .undead);
        const s = d.arena.combat();
        const own = if (side) "_a" else "_b";
        @field(s, "fear_timer" ++ own)[0] = 4;
        @field(s, "fear_accum_dmg" ++ own)[0] = 50;
        @field(s, "fear_dr_tier" ++ own)[0] = 2;
        @field(s, "seduction_timer" ++ own)[0] = 3;
        @field(s, "seduced" ++ own)[0] = 1;
        try std.testing.expect((if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[20][0]);
        const before = d.snapshot(0);
        if (side) d.apply(@splat(.{ .ability = 20 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 20 }));
        try std.testing.expectEqual(@as(f32, 0), @field(s, "fear_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "seduction_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(u32, 0), @field(s, "seduced" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 2), @field(s, "fear_dr_tier" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 120), @field(s, "racial_cd" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 1.5), @field(s, "gcd" ++ own)[0]);
        const used = d.snapshot(0);
        d.restore(7, used);
        try std.testing.expectEqual(@as(f32, 120), @field(s, "racial_cd" ++ own)[7]);
        // Optimized staging must retain the same cleanse as the reference path.
        d.restore(0, before);
        if (side) d.applyMaskedReference(@splat(.{ .ability = 20 }), @splat(.{}), @splat(true), @splat(true)) else d.applyMaskedReference(@splat(.{}), @splat(.{ .ability = 20 }), @splat(true), @splat(true));
        const reference = d.snapshot(0);
        try std.testing.expectEqualSlices(u32, &used.words, &reference.words);
        try std.testing.expectEqualSlices(f32, &used.extras, &reference.extras);
        inline for (.{ "horror_timer", "stun_timer", "gcd", "racial_cd" }) |blocked| {
            d.restore(0, before);
            @field(s, blocked ++ own)[0] = 1;
            try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[20][0]);
        }
        d.restore(0, before);
        if (side) d.setActionMaskA(1) else d.setActionMaskB(1);
        try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[20][0]);
    }
}

test "Will of the Forsaken does not cleanse Mage Polymorph" {
    var d = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    d.setRace(true, .undead);
    d.arena.combat().fear_timer_a[0] = 5;
    d.apply(@splat(.{ .ability = 20 }), @splat(.{}));
    try std.testing.expectEqual(@as(f32, 5), d.arena.combat().fear_timer_a[0]);
}

test "Blood Fury scales owner power only, expires and retains cooldown across snapshots" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.setRace(true, .orc);
    const s = d.arena.combat();
    try d.setCombatStats(true, .{ .shadow_power = 500, .fire_power = 200 });
    d.apply(@splat(.{ .ability = 17 }), @splat(.{}));
    try std.testing.expectApproxEqAbs(@as(f32, 550), resolution.spellPower(s, true, 0, .shadow)[0], 0.001);
    try std.testing.expectEqual(@as(f32, 500), s.shadow_power_a[0]);
    try std.testing.expectEqual(@as(f32, 180), s.racial_cd_a[0]);
    try std.testing.expectEqual(@as(f32, 15), s.racial_power_timer_a[0]);
    try std.testing.expectEqual(@as(f32, 0), s.gcd_a[0]);
    try std.testing.expect(!d.getActionMaskA(0)[17][0]);
    try std.testing.expect(!d.getActionMaskB(0)[17][0]);
    const snapshot = d.snapshot(0);
    d.restore(7, snapshot);
    try std.testing.expectEqual(@intFromEnum(Race.orc), s.race_a[7]);
    try std.testing.expectEqual(@as(f32, 15), s.racial_power_timer_a[7]);
    racials.tick(s, 0, 15);
    try std.testing.expectEqual(@as(f32, 500), resolution.spellPower(s, true, 0, .shadow)[0]);
    try std.testing.expectEqual(@as(f32, 165), s.racial_cd_a[0]);
    s.racial_cd_a[0] = 0;
    try std.testing.expect(d.getActionMaskA(0)[17][0]);
}

test "Berserking advances Mage casts and Warlock channels without hasting cooldowns or pets" {
    var d = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    d.setRace(true, .troll);
    d.setRace(false, .troll);
    const s = d.arena.combat();
    d.apply(@splat(.{ .ability = 18 }), @splat(.{ .ability = 18 }));
    try std.testing.expectEqual(@as(f32, 10), s.racial_haste_timer_b[0]);
    s.cast_id_b[0] = 4;
    s.cast_timer_b[0] = 2;
    s.cast_total_b[0] = 2;
    s.cast_id_a[0] = 5;
    s.cast_timer_a[0] = 5;
    s.cast_total_a[0] = 5;
    _ = d.arena.tickPhysics16(0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.45), s.cast_timer_b[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.45), s.cast_timer_a[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), s.channel_elapsed_a[0], 0.0001);
    try std.testing.expectEqual(@as(f32, 179.5), s.racial_cd_b[0]);
    s.racial_haste_timer_b[0] = 0.1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.51), racials.castStep(s, false, 0, 0.5)[0], 0.0001);
}

test "Escape Artist cleanses and prevents roots and slows but preserves Warlock DOTs" {
    inline for (.{ true, false }) |gnome_a| {
        var d = try sim.Duel(.frost_mage, .frost_mage).init(std.testing.allocator);
        defer d.deinit();
        d.setRace(gnome_a, .gnome);
        const s = d.arena.combat();
        const own = if (gnome_a) "_a" else "_b";
        const other = if (gnome_a) "_b" else "_a";
        @field(s, "agony_timer" ++ own)[0] = 3;
        @field(s, "corruption_timer" ++ own)[0] = 4;
        @field(s, "daze_timer" ++ own)[0] = 2; // Daze is a separate mechanic.
        if (gnome_a) d.apply(@splat(.{ .ability = 19 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 19 }));
        try std.testing.expectEqual(@as(f32, 0), @field(s, "agony_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "corruption_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 2), @field(s, "daze_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 1.5), @field(s, "gcd" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 120), @field(s, "racial_cd" ++ own)[0]);
        s.distance[0] = 5;
        if (gnome_a) d.apply(@splat(.{}), @splat(.{ .ability = 2 })) else d.apply(@splat(.{ .ability = 2 }), @splat(.{}));
        try std.testing.expectEqual(@as(f32, 0), @field(s, "agony_timer" ++ own)[0]);
        s.pos_x_a[0] = 0;
        s.pos_x_b[0] = 0;
        s.distance[0] = 0;
        // A launched Frostbolt must still damage even when its slow is immune.
        @import("projectiles.zig").launchClass(s, !gnome_a, 0, 4, @as(V, @splat(100)), @splat(true), .frost_mage);
        s.distance[0] = 0;
        _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "corruption_timer" ++ own)[0]);
        try std.testing.expect(@field(s, "hp" ++ own)[0] < 2000);
        racials.tick(s, 0, 3);
        @field(s, "gcd" ++ other)[0] = 0;
        d.arena.extras[(if (gnome_a) @as(usize, 5) else 0) * 16 + 0] = 0; // Blink column; Nova CD follows.
        d.arena.extras[((if (gnome_a) @as(usize, 5) else 0) + 1) * 16] = 0;
        if (gnome_a) d.apply(@splat(.{}), @splat(.{ .ability = 2 })) else d.apply(@splat(.{ .ability = 2 }), @splat(.{}));
        try std.testing.expect(@field(s, "agony_timer" ++ own)[0] > 0);
    }
    var w = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer w.deinit();
    w.setRace(true, .gnome);
    const s = w.arena.combat();
    s.agony_timer_a[0] = 10;
    s.corruption_timer_a[0] = 10;
    w.apply(@splat(.{ .ability = 19 }), @splat(.{}));
    try std.testing.expectEqual(@as(f32, 10), s.agony_timer_a[0]);
    try std.testing.expectEqual(@as(f32, 10), s.corruption_timer_a[0]);
}

test "racial actions respect race, CC, death, GCD and configured loadout" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.setRace(true, .orc);
    d.setRace(false, .gnome);
    const s = d.arena.combat();
    s.gcd_a[0] = 1;
    s.gcd_b[0] = 1;
    try std.testing.expect(d.getActionMaskA(0)[17][0]);
    try std.testing.expect(!d.getActionMaskB(0)[19][0]);
    s.fear_timer_a[0] = 3;
    try std.testing.expect(!d.getActionMaskA(0)[17][0]);
    s.fear_timer_a[0] = 0;
    s.hp_a[0] = 0;
    try std.testing.expect(!d.getActionMaskA(0)[17][0]);
    s.hp_a[0] = 2000;
    d.setActionMaskA(1);
    try std.testing.expect(!d.getActionMaskA(0)[17][0]);
}

test "Escape Artist wins simultaneous Nova and optimized staging agrees with reference" {
    var fast = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer fast.deinit();
    var reference = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer reference.deinit();
    fast.setRace(true, .gnome);
    fast.arena.combat().distance[0] = 5;
    const before = fast.snapshot(0);
    reference.restoreAll(before);
    fast.applyMasked(@splat(.{ .ability = 19 }), @splat(.{ .ability = 2 }), @splat(true), @splat(true));
    reference.applyMaskedReference(@splat(.{ .ability = 19 }), @splat(.{ .ability = 2 }), @splat(true), @splat(true));
    try std.testing.expectEqual(@as(f32, 0), fast.arena.combat().agony_timer_a[0]);
    const actual = fast.snapshot(0);
    const expected = reference.snapshot(0);
    try std.testing.expectEqualSlices(u32, &expected.words, &actual.words);
    try std.testing.expectEqualSlices(f32, &expected.extras, &actual.extras);
}
