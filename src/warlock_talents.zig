//! Compact decoded Warlock talent effects used by the SIMD combat kernels.
//! Rank parsing and scalar values are resolved at spec load time; this only
//! unpacks two u32 words per fighter lane and applies vector formulas.
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;

pub const Effects = struct {
    spell_hit_bonus: V,
    shadow_crit_bonus: V,
    affliction_crit_multiplier: V,
    fel_concentration_resist: V,
    intensity_resist: V,
    destruction_crit_multiplier: V,
    conflagrate_crit_bonus: V,
    agony_damage: V,
    corruption_damage: V,
    periodic_damage: V,
    siphon_life_damage: V,
    siphon_life_healing: V,
    shadow_damage: V,
    fire_damage: V,
    immolate_initial_damage: V,
    drain_life_damage: V,
    drain_life_healing: V,
    damage_taken: V,
    shadow_bolt_cast_time: V,
    shadow_bolt_mana: V,
    pet_damage: V,
    imp_firebolt_damage: V,
    shadowburn_shard_refund: V,
    seduction_duration_mult: V,
    spell_lock_cooldown: V,
    demonic_sacrifice: V,
    demonic_sacrifice_pet: V,
};

fn rank(encoded: U, comptime shift: u5, comptime bits: u5) U {
    return (encoded >> @as(@Vector(16, u5), @splat(shift))) & @as(U, @splat((@as(u32, 1) << bits) - 1));
}
fn asFloat(value: U) V {
    return @floatFromInt(value);
}

pub fn siphonUnlocked(encoded: U) @Vector(16, bool) {
    return (encoded & @as(U, @splat(@as(u32, 1) << 10))) != @as(U, @splat(0));
}

pub fn shadowburnUnlocked(encoded: U) @Vector(16, bool) {
    return (encoded & @as(U, @splat(@as(u32, 1) << 28))) != @as(U, @splat(0));
}

pub fn pushbackResistance(encoded_rank: U) V {
    return @select(f32, encoded_rank == @as(U, @splat(1)), @as(V, @splat(0.23)), @select(f32, encoded_rank == @as(U, @splat(2)), @as(V, @splat(0.47)), @select(f32, encoded_rank == @as(U, @splat(3)), @as(V, @splat(0.70)), @as(V, @splat(0)))));
}
pub fn decode(encoded: U, flags: U) Effects {
    const corruption = rank(encoded, 0, 3);
    const malediction = rank(encoded, 3, 3);
    const drains = rank(encoded, 6, 2);
    const agony = rank(encoded, 8, 2);
    const shadow = rank(encoded, 11, 3);
    const unholy = rank(encoded, 14, 3);
    const soul_link = rank(encoded, 17, 1);
    const bane = rank(encoded, 18, 3);
    const molten_skin = rank(encoded, 21, 3);
    const cataclysm = rank(encoded, 24, 2);
    const improved_imp = rank(encoded, 26, 2);
    const shadow_and_flame = rank(encoded, 29, 3);
    const aftermath = rank(flags, 5, 3);
    const demonic_sacrifice = asFloat(flags & @as(U, @splat(1)));
    const demonic_sacrifice_pet = asFloat(rank(flags, 2, 3));

    const shadow_base = @as(V, @splat(1.0)) + @as(V, @splat(0.01)) * asFloat(shadow);
    const shadow_mult = shadow_base * (@as(V, @splat(1.0)) + @as(V, @splat(0.03)) * asFloat(soul_link));
    const periodic_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.01)) * asFloat(malediction);
    const drains_mult = @select(f32, drains == @as(U, @splat(1)), @as(V, @splat(1.07)), @select(f32, drains == @as(U, @splat(2)), @as(V, @splat(1.13)), @select(f32, drains >= @as(U, @splat(3)), @as(V, @splat(1.20)), @as(V, @splat(1.0)))));
    const mana_mult = @select(f32, cataclysm == @as(U, @splat(1)), @as(V, @splat(0.97)), @select(f32, cataclysm == @as(U, @splat(2)), @as(V, @splat(0.94)), @select(f32, cataclysm >= @as(U, @splat(3)), @as(V, @splat(0.90)), @as(V, @splat(1.0)))));
    const siphon_life_transfer_mult = shadow_mult * periodic_mult;

    return .{
        .fel_concentration_resist = pushbackResistance(rank(flags, 26, 2)),
        .intensity_resist = pushbackResistance(rank(flags, 28, 2)),
        .affliction_crit_multiplier = @as(V, @splat(1.5)) + @as(V, @splat(0.5)) *
            @select(f32, rank(flags, 24, 2) == @as(U, @splat(1)), @as(V, @splat(0.33)), @select(f32, rank(flags, 24, 2) == @as(U, @splat(2)), @as(V, @splat(0.67)), @select(f32, rank(flags, 24, 2) == @as(U, @splat(3)), @as(V, @splat(1)), @as(V, @splat(0))))),
        .spell_hit_bonus = @as(V, @splat(0.01)) * asFloat(rank(flags, 13, 3)),
        .shadow_crit_bonus = @as(V, @splat(0.01)) * asFloat(rank(flags, 16, 3)),
        .destruction_crit_multiplier = @as(V, @splat(1.5)) + @as(V, @splat(0.10)) * asFloat(rank(flags, 19, 3)),
        .conflagrate_crit_bonus = @select(f32, rank(flags, 22, 2) == @as(U, @splat(1)), @as(V, @splat(0.08)), @select(f32, rank(flags, 22, 2) == @as(U, @splat(2)), @as(V, @splat(0.17)), @select(f32, rank(flags, 22, 2) == @as(U, @splat(3)), @as(V, @splat(0.25)), @as(V, @splat(0))))),
        .agony_damage = shadow_mult * periodic_mult * (@as(V, @splat(1.0)) + @as(V, @splat(0.05)) * asFloat(agony)),
        .corruption_damage = shadow_mult * periodic_mult * (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(corruption)),
        .periodic_damage = periodic_mult,
        .siphon_life_damage = siphon_life_transfer_mult,
        // Siphon Life transfers the health it drains; its healing follows the
        // same damage modifiers as the periodic damage tick.
        .siphon_life_healing = siphon_life_transfer_mult,
        .shadow_damage = shadow_mult,
        .fire_damage = @as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(shadow_and_flame),
        .immolate_initial_damage = (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(shadow_and_flame)) *
            (@as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(aftermath)),
        // Drain Life deals periodic Shadow damage, so Malediction applies
        // alongside Shadow Mastery and Improved Drains.
        .drain_life_damage = shadow_mult * periodic_mult * drains_mult,
        .drain_life_healing = shadow_base * drains_mult,
        .damage_taken = @as(V, @splat(1.0)) - @as(V, @splat(0.02)) * asFloat(molten_skin),
        .shadow_bolt_cast_time = @as(V, @splat(1.8)) - @as(V, @splat(0.1)) * asFloat(bane),
        .shadow_bolt_mana = mana_mult,
        .pet_damage = (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(unholy)) *
            (@as(V, @splat(1.0)) + @as(V, @splat(0.03)) * asFloat(soul_link)),
        .imp_firebolt_damage = @as(V, @splat(60.0)) * (@as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(improved_imp)) *
            (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(shadow_and_flame)),
        .shadowburn_shard_refund = asFloat(shadow_and_flame) * @as(V, @splat(0.2)),
        .seduction_duration_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(rank(flags, 9, 2)),
        .spell_lock_cooldown = @as(V, @splat(24.0)) - @as(V, @splat(2.0)) * asFloat(rank(flags, 11, 2)),
        .demonic_sacrifice = demonic_sacrifice,
        .demonic_sacrifice_pet = demonic_sacrifice_pet,
    };
}

test "Warlock talent decode applies ranks independently per SIMD lane" {
    const std = @import("std");
    var encoded: U = @splat(0);
    encoded[0] = 0;
    encoded[1] = 1 << 24; // Cataclysm rank 1
    encoded[2] = 2 << 24; // Cataclysm rank 2
    encoded[3] = (2 << 8) | (3 << 18); // Improved Bane of Agony, Bane
    encoded[4] = (3 << 3) | (3 << 11); // Malediction, Shadow Mastery
    encoded[5] = (2 << 6); // Improved Drains
    encoded[6] = (3 << 3) | (3 << 11) | (2 << 6); // Malediction, Shadow Mastery, Improved Drains

    const effects = decode(encoded, @splat(0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effects.shadow_bolt_mana[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.97), effects.shadow_bolt_mana[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.94), effects.shadow_bolt_mana[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.10), effects.agony_damage[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), effects.shadow_bolt_cast_time[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.03 * 1.03), effects.corruption_damage[4], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.13), effects.drain_life_damage[5], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.03 * 1.03 * 1.13), effects.drain_life_damage[6], 0.0001);
}

test "Aftermath packed ranks match scalar modifiers and only amplify the initial hit" {
    const std = @import("std");
    const spec = @import("spec.zig");
    var encoded: U = @splat(0);
    var flags: U = @splat(0);
    for (0..6) |lane| {
        const ranks = spec.WarlockTalentRanks{ .aftermath = @intCast(lane), .shadow_and_flame = 5, .demonic_sacrifice = 1, .demonic_sacrifice_pet = 4 };
        encoded[lane] = @truncate(ranks.encode());
        flags[lane] = @truncate(ranks.encode() >> 32);
    }
    const effects = decode(encoded, flags);
    for (0..6) |lane| {
        const scalar = spec.CombatModifiers.fromWarlockRanks(.{ .aftermath = @intCast(lane), .shadow_and_flame = 5 });
        try std.testing.expectApproxEqAbs(scalar.immolate_initial_damage_mult, effects.immolate_initial_damage[lane], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), effects.fire_damage[lane], 0.0001);
        try std.testing.expectEqual(@as(f32, 1), effects.periodic_damage[lane]);
        try std.testing.expectEqual(@as(f32, 4), effects.demonic_sacrifice_pet[lane]);
    }
}

test "pet utility ranks preserve packed neighbors and match scalar effects" {
    const std = @import("std");
    const spec = @import("spec.zig");
    var encoded: U = @splat(0);
    var flags: U = @splat(0);
    for (0..16) |lane| {
        const ranks = spec.WarlockTalentRanks{ .improved_sayaad = @intCast(lane % 4), .improved_felhunter = @intCast(lane / 4), .conflagrate = 1, .aftermath = 5, .demonic_sacrifice_pet = 4 };
        encoded[lane] = @truncate(ranks.encode());
        flags[lane] = @truncate(ranks.encode() >> 32);
    }
    const effects = decode(encoded, flags);
    for (0..16) |lane| {
        const scalar = spec.CombatModifiers.fromWarlockRanks(.{ .improved_sayaad = @intCast(lane % 4), .improved_felhunter = @intCast(lane / 4) });
        try std.testing.expectApproxEqAbs(scalar.seduction_duration_mult, effects.seduction_duration_mult[lane], 0.0001);
        try std.testing.expectEqual(scalar.spell_lock_cooldown, effects.spell_lock_cooldown[lane]);
        try std.testing.expectApproxEqAbs(@as(f32, 1.5), effects.immolate_initial_damage[lane], 0.0001);
        try std.testing.expectEqual(@as(f32, 4), effects.demonic_sacrifice_pet[lane]);
    }
}
