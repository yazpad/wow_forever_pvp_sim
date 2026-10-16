const std = @import("std");
const simd = @import("simd.zig");
const combat = @import("combat_spec.zig");
const multi = @import("multi_spec.zig");
const spec = @import("spec.zig");
const talents = @import("warlock_talents.zig");
const pushback = @import("pushback.zig");
const projectiles = @import("projectiles.zig");
const search = @import("search_sim.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
const C = combat.WarlockConstants;
fn near(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}
fn setup(state: *combat.WarlockArenaPool, comptime side: bool, cast: u32, total: f32, left: f32) void {
    @memset(state.pet_kind_a, 0);
    @memset(state.pet_kind_b, 0);
    @memset(state.pos_x_a, 0);
    @memset(state.pos_x_b, 0);
    @memset(state.pos_y_a, 0);
    @memset(state.pos_y_b, 0);
    @memset(state.distance, 0);
    const own = if (side) "_a" else "_b";
    @memset(@field(state, "cast_id" ++ own), cast);
    @memset(@field(state, "cast_timer" ++ own), left);
    @memset(@field(state, "cast_total" ++ own), total);
}
fn missile(state: *combat.WarlockArenaPool, comptime source: bool, comptime spell: u32, damage: f32) void {
    projectiles.launch(state, source, 0, spell, @splat(damage), @splat(true));
}
fn scalarRoll(seed: u32) f32 {
    var next = if (seed == 0) @as(u32, 0x6d2b79f5) else seed;
    next ^= next << 13;
    next ^= next >> 17;
    next ^= next << 5;
    return @as(f32, @floatFromInt(next >> 8)) / 16777216;
}

test "pushback scalar oracle clamps to cast start diminishes to 200ms and respects resistance" {
    var left: V = undefined;
    var total: V = @splat(3);
    var count: U = undefined;
    var channel: B = undefined;
    var chance: V = undefined;
    var rolls: V = undefined;
    var eligible: B = @splat(true);
    for (0..16) |lane| {
        left[lane] = if (lane % 4 == 0) 2.9 else if (lane % 4 == 1) 0.1 else 1;
        count[lane] = @intCast(lane % 6);
        channel[lane] = lane % 2 != 0;
        chance[lane] = if (lane % 3 == 0) 0.7 else 0;
        rolls[lane] = if (lane % 4 == 0) 0.1 else 0.9;
    }
    eligible[15] = false;
    total[15] = 0;
    const result = pushback.resolveRolls(left, total, count, channel, chance, rolls, eligible);
    for (0..16) |lane| {
        const applied = eligible[lane] and rolls[lane] >= chance[lane];
        const delay = @max(@as(f32, 0.2), 1 - @as(f32, @floatFromInt(@min(count[lane], 4))) * 0.2);
        const expected = if (!applied) left[lane] else if (channel[lane]) @max(@as(f32, 0), left[lane] - delay) else @min(total[lane], left[lane] + delay);
        try near(expected, result.remaining[lane]);
        try std.testing.expectEqual(if (applied) @min(@as(u32, 4), count[lane] + 1) else count[lane], result.count[lane]);
    }
    const capped = pushback.resolveRolls(@splat(2.9), @splat(3), @splat(0), @splat(false), @splat(0), @splat(0), @splat(true));
    try near(3, capped.remaining[0]);
    const late_hit = pushback.resolveRolls(@splat(0.01), @splat(3), @splat(4), @splat(false), @splat(0), @splat(0), @splat(true));
    try near(0.21, late_hit.remaining[0]);
    const immune = pushback.resolveRolls(@splat(1), @splat(3), @splat(0), @splat(false), @splat(1), @splat(0.999), @splat(true));
    try near(1, immune.remaining[0]);
    try std.testing.expectEqual(@as(u32, 0), immune.count[0]);
}

test "Fel Concentration and Intensity decode all ranks per lane and apply to eligible spells only" {
    var low: U = undefined;
    var high: U = undefined;
    for (0..16) |lane| {
        const ranks = spec.WarlockTalentRanks{ .fel_concentration = @intCast(lane % 4), .intensity = @intCast(lane / 4), .pandemic = 3, .malevolence = 5, .ruin = 5, .fire_and_brimstone = 3 };
        low[lane] = @truncate(ranks.encode());
        high[lane] = @truncate(ranks.encode() >> 32);
    }
    const fx = talents.decode(low, high);
    for (0..16) |lane| {
        const expected = spec.CombatModifiers.fromWarlockRanks(.{ .fel_concentration = @intCast(lane % 4), .intensity = @intCast(lane / 4) });
        try near(expected.fel_concentration_resist, fx.fel_concentration_resist[lane]);
        try near(expected.intensity_resist, fx.intensity_resist[lane]);
        try near(2, fx.affliction_crit_multiplier[lane]);
        try near(2, fx.destruction_crit_multiplier[lane]);
        try near(0.25, fx.conflagrate_crit_bonus[lane]);
    }
    inline for (.{ @as(u32, 3), 4, 5, 11, 12, 13 }) |cast| {
        const chance = pushback.resistanceFor(true, @splat(cast), fx);
        for (0..16) |lane| try near(if (cast == 5) fx.fel_concentration_resist[lane] else if (cast == 3) 0 else fx.intensity_resist[lane], chance[lane]);
        try near(0, pushback.resistanceFor(false, @splat(cast), fx)[0]);
    }
}

test "direct missile impacts push back normal casts and shorten channels on both sides of every matchup" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock }, .{ .frost_mage, .frost_mage } }) |pair| {
        inline for (.{ true, false }) |side| {
            const actor = if (side) pair[0] else pair[1];
            const own = if (side) "_a" else "_b";
            inline for (.{ @as(u32, 3), 4, 5, 11, 12, 13 }) |cast| {
                if (actor == .frost_mage and cast != 3 and cast != 4) continue;
                var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
                defer arena.deinit();
                const state = arena.combat();
                setup(state, side, cast, if (cast == 5) 3 else 1.8, 1.1);
                missile(state, !side, 4, 10);
                _ = arena.tickPhysics16(0.01, 0);
                try near(if (cast == 5) 0.09 else 1.79, @field(state, "cast_timer" ++ own)[0]);
                try std.testing.expectEqual(@as(u32, 1), @field(state, "cast_pushback_count" ++ own)[0]);
                try std.testing.expectEqual(cast, @field(state, "cast_id" ++ own)[0]);
            }
        }
    }
}

test "every periodic source including channel damage never pushes back casts or consumes resistance RNG" {
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[1] else pair[0]) != .warlock) continue;
            const own = if (side) "_a" else "_b";
            const enemy = if (side) "_b" else "_a";
            inline for (.{ "agony", "corruption", "immolate", "siphon", "drain" }) |effect| {
                var arena = try multi.ArenaPool(pair[0], pair[1]).init(std.testing.allocator, 16);
                defer arena.deinit();
                const state = arena.combat();
                setup(state, side, 4, 1.8, 1.1);
                @memset(@field(state, "talent_flags" ++ own), @as(u32, 3) << 28);
                if (comptime std.mem.eql(u8, effect, "drain")) {
                    @memset(@field(state, "cast_id" ++ enemy), 5);
                    @memset(@field(state, "cast_timer" ++ enemy), 2.01);
                    @memset(@field(state, "cast_total" ++ enemy), 3);
                    @memset(@field(state, "channel_elapsed" ++ enemy), 0.99);
                } else {
                    const duration: f32 = if (std.mem.eql(u8, effect, "agony")) C.AgonyDuration else if (std.mem.eql(u8, effect, "corruption")) C.CorruptionDuration else if (std.mem.eql(u8, effect, "immolate")) C.ImmolateDuration else C.SiphonLifeDuration;
                    const interval: f32 = if (std.mem.eql(u8, effect, "agony") or std.mem.eql(u8, effect, "corruption")) 2 else 3;
                    @memset(@field(state, effect ++ "_timer" ++ own), duration - interval + 0.01);
                }
                const rng = @field(state, "pushback_rng" ++ own)[0];
                _ = arena.tickPhysics16(0.01, 0);
                try std.testing.expect(@field(state, "hp" ++ own)[0] < 2000);
                try near(1.09, @field(state, "cast_timer" ++ own)[0]);
                try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_pushback_count" ++ own)[0]);
                try std.testing.expectEqual(rng, @field(state, "pushback_rng" ++ own)[0]);
            }
        }
    }
}

test "same-frame direct hits count separately and can delay a cast that would otherwise finish" {
    var arena = try multi.ArenaPool(.warlock, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    const state = arena.combat();
    setup(state, true, 4, 3, 0.005);
    missile(state, false, 4, 10);
    missile(state, false, 13, 10);
    _ = arena.tickPhysics16(0.01, 0);
    try near(1.795, state.cast_timer_a[0]);
    try std.testing.expectEqual(@as(u32, 2), state.cast_pushback_count_a[0]);
    try std.testing.expectEqual(@as(u32, 4), state.cast_id_a[0]);
    try near(0, state.projectile_count_a[0]);
}

test "pet attacks and Conflagrate cause pushback while zero-damage missiles do not" {
    inline for (.{ true, false }) |side| {
        const own = if (side) "_a" else "_b";
        const enemy = if (side) "_b" else "_a";
        inline for (.{ "pet", "conflagrate", "miss" }) |source| {
            var arena = try multi.ArenaPool(.warlock, .warlock).init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            setup(state, side, 4, 1.8, 1.1);
            if (comptime std.mem.eql(u8, source, "pet")) {
                for (0..16) |lane| @import("pets.zig").set(state, !side, lane, .imp);
                @memset(@field(state, "pet_timer" ++ enemy), 0);
            } else if (comptime std.mem.eql(u8, source, "conflagrate")) {
                @memset(@field(state, "conflagrate_pending" ++ enemy), 10);
            } else missile(state, !side, 4, 0);
            _ = arena.tickPhysics16(0.01, 0);
            const missed = std.mem.eql(u8, source, "miss");
            try near(if (missed) 1.09 else 1.79, @field(state, "cast_timer" ++ own)[0]);
            try std.testing.expectEqual(@as(u32, if (missed) 0 else 1), @field(state, "cast_pushback_count" ++ own)[0]);
        }
    }
}

test "fully absorbed hits do not push back even when a concurrent DoT breaks the shield" {
    var arena = try multi.ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    arena.applyActionA(0, @splat(6), @splat(0));
    const state = arena.combat();
    setup(state, true, 4, 1.5, 1.1);
    // The direct hit leaves 10 shield points. The corruption tick overflows
    // that remainder; neither event should cause pushback.
    missile(state, false, 4, spec.Frost.BarrierAbsorb - 10);
    @memset(state.corruption_timer_a, C.CorruptionDuration - 2 + 0.01);
    _ = arena.tickPhysics16(0.01, 0);
    try std.testing.expect(state.hp_a[0] < 2000);
    try near(1.09, state.cast_timer_a[0]);
    try std.testing.expectEqual(@as(u32, 0), state.cast_pushback_count_a[0]);
    missile(state, false, 4, 10);
    _ = arena.tickPhysics16(0.01, 0);
    try near(1.49, state.cast_timer_a[0]);
    try std.testing.expectEqual(@as(u32, 1), state.cast_pushback_count_a[0]);
}

test "shortened channels discard tail ticks without advancing phase and resist rolls are independent" {
    inline for (.{ true, false }) |side| {
        const own = if (side) "_a" else "_b";
        const enemy = if (side) "_b" else "_a";
        var arena = try multi.ArenaPool(.warlock, .warlock).init(std.testing.allocator, 16);
        defer arena.deinit();
        const state = arena.combat();
        setup(state, side, 5, 3, 2.75);
        @memset(@field(state, "channel_elapsed" ++ own), 0.25);
        @memset(@field(state, "hp" ++ own), 1000);
        // Different resistance ranks and seeds must agree with a scalar roll.
        for (0..16) |lane| {
            const ranks = spec.WarlockTalentRanks{ .fel_concentration = @intCast(lane % 4) };
            @field(state, "talent_ranks" ++ own)[lane] = @truncate(ranks.encode());
            @field(state, "talent_flags" ++ own)[lane] = @truncate(ranks.encode() >> 32);
            @field(state, "pushback_rng" ++ own)[lane] = if (lane % 2 == 0) 1 else 0x6d2b79f5;
        }
        missile(state, !side, 4, 10);
        _ = arena.tickPhysics16(0.01, 0);
        for (0..16) |lane| {
            const seed: u32 = if (lane % 2 == 0) 1 else 0x6d2b79f5;
            const resisted = scalarRoll(seed) < spec.pushbackResistance(@intCast(lane % 4));
            try near(if (resisted) 2.74 else 1.74, @field(state, "cast_timer" ++ own)[lane]);
            try near(0.26, @field(state, "channel_elapsed" ++ own)[lane]);
            try std.testing.expectEqual(@as(u32, if (resisted) 0 else 1), @field(state, "cast_pushback_count" ++ own)[lane]);
            try near(2000, @field(state, "hp" ++ enemy)[lane]);
        }
        // Lane 0 has no resistance: it should finish at natural time 2s,
        // delivering only the ticks at natural times 1s and 2s.
        _ = arena.tickPhysics16(1.74, 0);
        try near(2000 - 2 * C.DrainLifeDps, @field(state, "hp" ++ enemy)[0]);
        try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_id" ++ own)[0]);
        try near(0, @field(state, "channel_elapsed" ++ own)[0]);
        try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_pushback_count" ++ own)[0]);
    }
}

test "new casts reset pushback state and snapshots reproduce resistance and channel phase" {
    var duel = try search.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer duel.deinit();
    duel.setWarlockTalentRanksA((spec.WarlockTalentRanks{ .fel_concentration = 3, .intensity = 3 }).encode());
    const state = duel.arena.combat();
    setup(state, true, 0, 0, 0);
    @memset(state.cast_pushback_count_a, 4);
    @memset(state.channel_elapsed_a, 2);
    duel.applyMasked(@splat(.{ .ability = 5 }), @splat(.{}), @splat(true), @splat(false));
    try std.testing.expectEqual(@as(u32, 0), state.cast_pushback_count_a[0]);
    try near(0, state.channel_elapsed_a[0]);
    _ = duel.arena.tickPhysics16(0.5, 0);
    missile(state, false, 4, 10);
    const before = duel.snapshot(0);
    for (0..16) |lane| duel.restore(lane, before);
    _ = duel.arena.tickPhysics16(0.01, 0);
    _ = duel.arena.tickPhysics16(0.6, 0);
    const after = duel.snapshot(0);
    for (0..16) |lane| try std.testing.expectEqualDeep(after, duel.snapshot(lane));
    for (0..16) |lane| duel.restore(lane, before);
    _ = duel.arena.tickPhysics16(0.01, 0);
    _ = duel.arena.tickPhysics16(0.6, 0);
    for (0..16) |lane| try std.testing.expectEqualDeep(after, duel.snapshot(lane));
}

test "periodic damage never shortens a Drain Life channel" {
    inline for (.{ true, false }) |side| {
        const own = if (side) "_a" else "_b";
        var arena = try multi.ArenaPool(.warlock, .warlock).init(std.testing.allocator, 16);
        defer arena.deinit();
        const state = arena.combat();
        setup(state, side, 5, 3, 2.01);
        @memset(@field(state, "channel_elapsed" ++ own), 0.99);
        @memset(@field(state, "corruption_timer" ++ own), C.CorruptionDuration - 2 + 0.01);
        const rng = @field(state, "pushback_rng" ++ own)[0];
        _ = arena.tickPhysics16(0.01, 0);
        try near(2, @field(state, "cast_timer" ++ own)[0]);
        try near(1, @field(state, "channel_elapsed" ++ own)[0]);
        try std.testing.expectEqual(@as(u32, 0), @field(state, "cast_pushback_count" ++ own)[0]);
        try std.testing.expectEqual(rng, @field(state, "pushback_rng" ++ own)[0]);
    }
}

test "Intensity rolls on direct damage to Destruction casts but never protects Fear" {
    inline for (.{ true, false }) |side| {
        inline for (.{ @as(u32, 3), 4 }) |cast| {
            const own = if (side) "_a" else "_b";
            var arena = try multi.ArenaPool(.warlock, .warlock).init(std.testing.allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            setup(state, side, cast, 3, 1.1);
            for (0..16) |lane| {
                const ranks = spec.WarlockTalentRanks{ .intensity = @intCast(lane % 4), .fel_concentration = 3 };
                @field(state, "talent_ranks" ++ own)[lane] = @truncate(ranks.encode());
                @field(state, "talent_flags" ++ own)[lane] = @truncate(ranks.encode() >> 32);
                @field(state, "pushback_rng" ++ own)[lane] = 0x6d2b79f5;
            }
            missile(state, !side, 4, 10);
            _ = arena.tickPhysics16(0.01, 0);
            for (0..16) |lane| {
                const protected = cast == 4 and scalarRoll(0x6d2b79f5) < spec.pushbackResistance(@intCast(lane % 4));
                try near(if (protected) 1.09 else 2.09, @field(state, "cast_timer" ++ own)[lane]);
                try std.testing.expectEqual(@as(u32, if (protected) 0 else 1), @field(state, "cast_pushback_count" ++ own)[lane]);
                if (cast == 3) try std.testing.expectEqual(@as(u32, 0x6d2b79f5), @field(state, "pushback_rng" ++ own)[lane]);
            }
        }
    }
}
