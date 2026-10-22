const std = @import("std");
const core = @import("warrior_core.zig");
const talents = @import("warrior_talents.zig");
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;

fn near(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "warrior Forever tree rejects illegal ranks, tiers, prerequisites and point totals" {
    var build: talents.Build = .{};
    try build.validate();
    try std.testing.expectError(error.InvalidRank, build.set(.mortalStrike, 2));
    try build.set(.mortalStrike, 1);
    try std.testing.expectError(error.MissingTierPoints, build.validate());

    // 5 points in row zero unlock row one, but Anger Management additionally
    // requires all five points of Improved Tactical Mastery.
    build = .{};
    try build.set(.deflection, 5);
    try build.set(.improvedHeroicStrike, 3);
    try build.set(.improvedRend, 2);
    try build.set(.angerManagement, 1);
    try std.testing.expectError(error.MissingPrerequisite, build.validate());
    try build.set(.improvedTacticalMastery, 5);
    try build.validate();

    // Complete Arms is 47 points in this Forever tree. Four points in Fury
    // are legal, a fifth must fail the global cap even across different trees.
    build = .{};
    for (talents.data.definitions, 0..) |definition, index| {
        if (definition.tree == 0) build.ranks[index] = definition.max_rank;
    }
    try build.set(.cruelty, 4);
    _ = try build.pack();
    try build.set(.cruelty, 5);
    try std.testing.expectError(error.TooManyPoints, build.pack());

    build.ranks = @splat(5);
    try std.testing.expectError(error.InvalidRank, build.validate());
    for (talents.data.definitions, 0..) |definition, index| build.ranks[index] = definition.max_rank;
    try std.testing.expectError(error.TooManyPoints, build.validate());
}

test "warrior packed ranks preserve all talents independently and decode divergent SIMD lanes" {
    // Exercise the entire layout (including padding and the fourth word), not
    // only the first few implemented effects. Raw packing is intentionally
    // tested separately from legality of a complete 51-point build.
    inline for (std.meta.fields(talents.Talent)) |field| {
        const talent: talents.Talent = @enumFromInt(field.value);
        const definition = talents.data.definitions[field.value];
        var words: talents.Packed = @splat(0);
        words[definition.word] = @as(u32, definition.max_rank) << definition.shift;
        for (std.meta.tags(talents.Talent)) |other| {
            try std.testing.expectEqual(if (other == talent) definition.max_rank else @as(u8, 0), talents.rank(words, other));
        }
        var vectors: [4]U = @splat(@as(U, @splat(0)));
        for (0..16) |lane| vectors[definition.word][lane] = @as(u32, @intCast(lane % (definition.max_rank + 1))) << definition.shift;
        const decoded = talents.rankVector(vectors, talent);
        for (0..16) |lane| try near(@floatFromInt(lane % (definition.max_rank + 1)), decoded[lane]);
    }
    var build: talents.Build = .{};
    try build.set(.deflection, 5);
    try build.set(.improvedTacticalMastery, 5);
    try build.set(.angerManagement, 1);
    const encoded = try build.pack();
    try std.testing.expectEqual(@as(u8, 5), talents.rank(encoded, .improvedTacticalMastery));
    try std.testing.expectEqual(@as(u8, 1), talents.rank(encoded, .angerManagement));
}

test "warrior stance changes cap rage, share cooldown, respect masks and do not compound stats" {
    var state: core.State = .{};
    var desired: U = @splat(@intFromEnum(core.Stance.defensive));
    desired[2] = 99;
    desired[3] = @intFromEnum(core.Stance.battle);
    var eligible: B = @splat(true);
    eligible[1] = false;
    state.rage = @splat(80);
    state.rage[4] = 7;
    const switched = state.switchStance(desired, @splat(25), eligible);
    try std.testing.expect(switched[0]);
    for (1..4) |lane| {
        try std.testing.expect(!switched[lane]);
        try near(80, state.rage[lane]);
    }
    try near(25, state.rage[0]);
    try near(7, state.rage[4]);
    try near(1, state.stance_cooldown[0]);
    try std.testing.expect(!state.switchStance(@splat(@intFromEnum(core.Stance.berserker)), @splat(10), @splat(true))[0]);
    state.tick(@splat(1), @splat(true));
    try std.testing.expect(state.switchStance(@splat(@intFromEnum(core.Stance.berserker)), @splat(10), @splat(true))[0]);
    try near(10, state.rage[0]);
    const effects = core.stanceEffects(state.stance);
    try near(1, effects.damage_dealt[0]);
    try near(1.1, effects.damage_taken[0]);
    try near(0.03, effects.melee_crit_bonus[0]);
    state.tick(@splat(1), @splat(true));
    _ = state.switchStance(@splat(@intFromEnum(core.Stance.defensive)), @splat(25), @splat(true));
    const defense = core.stanceEffects(state.stance);
    try near(0.9, defense.damage_dealt[0]);
    try near(0.9, defense.damage_taken[0]);
    try near(0, defense.melee_crit_bonus[0]);
    try near(10, state.rage[0]);
}

test "warrior rage payments, overflow, reset and immutable talent resource effects" {
    var build: talents.Build = .{};
    try build.set(.deflection, 5);
    try build.set(.improvedTacticalMastery, 5);
    const encoded = try build.pack();
    var words: [4]U = undefined;
    for (encoded, 0..) |word, index| words[index] = @splat(word);
    var effects = talents.resources(words);
    try near(25, effects.retained_rage[0]);
    try near(100, effects.max_rage[0]);
    try near(1, effects.offhand_rage_multiplier[0]);
    // Different ranks in each lane cover Boundless Rage's raised cap.
    const cap_definition = talents.data.definitions[@intFromEnum(talents.Talent.boundlessRage)];
    words[cap_definition.word][0] |= @as(u32, 3) << cap_definition.shift;
    effects = talents.resources(words);
    var state: core.State = .{};
    state.reset(@splat(200), @splat(@intFromEnum(core.Stance.battle)), effects.max_rage);
    try near(130, state.rage[0]);
    try near(100, state.rage[1]);
    const gain = state.gain(@splat(50), effects.max_rage, @splat(true));
    try near(0, gain[0]);
    state.rage[0] = 20;
    var cost: V = @splat(101);
    cost[0] = 20;
    cost[2] = -1;
    const spent = state.spend(cost, @splat(true));
    try std.testing.expect(spent[0]);
    try std.testing.expect(!spent[1] and !spent[2]);
    try near(0, state.rage[0]);
    try near(100, state.rage[1]);
    state.reset(@splat(-10), @splat(@intFromEnum(core.Stance.defensive)), effects.max_rage);
    try near(0, state.rage[0]);
    try near(0, state.stance_cooldown[0]);
}

test "warrior Forever white-hit rage follows reference log samples and hand multipliers" {
    var effects = talents.resources(@splat(@as(U, @splat(0))));
    var speeds: V = @splat(2.1);
    speeds[1] = 2.5;
    speeds[2] = 3.2;
    speeds[3] = 3.3;
    speeds[4] = 3.5;
    var two_hand: B = @splat(false);
    for (2..5) |lane| two_hand[lane] = true;
    var offhand: B = @splat(false);
    offhand[5] = true;
    offhand[6] = true;
    effects.offhand_rage_multiplier[6] = 2;
    var landed: B = @splat(true);
    landed[7] = false;
    const rage = core.whiteHitRage(speeds, two_hand, offhand, effects, landed);
    for ([_]f32{ 7.266, 8.65, 14.4, 14.85, 15.75 }, 0..) |expected, lane| try near(expected, rage[lane]);
    try near(3.633, rage[5]);
    try near(7.266, rage[6]);
    try near(0, rage[7]);
    var health: V = @splat(5000);
    health[1] = 0;
    const taken = core.damageTakenRage(@splat(1000), health, landed);
    try near(2, taken[0]);
    try near(0, taken[1]);
    try near(0, taken[7]);
}

test "warrior weapon damage separates real-speed autos and normalized specials" {
    const auto = core.weaponDamage(@splat(100), @splat(200), @splat(0.5), @splat(1400), @splat(3.8));
    const special = core.weaponDamage(@splat(100), @splat(200), @splat(0.5), @splat(1400), @splat(3.3));
    try near(530, auto[0]);
    try near(480, special[0]);
}
