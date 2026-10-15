//! Compact decoded Warlock talent effects used by the SIMD combat kernels.
//! Rank parsing and scalar values are resolved at spec load time; this only
//! unpacks one u32 per fighter lane and applies a handful of vector formulas.
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;

pub const Effects = struct {
    agony_damage: V,
    corruption_damage: V,
    periodic_damage: V,
    siphon_life_damage: V,
    siphon_life_healing: V,
    shadow_damage: V,
    drain_life_damage: V,
    drain_life_healing: V,
    damage_taken: V,
    shadow_bolt_cast_time: V,
    shadow_bolt_mana: V,
    pet_damage: V,
    imp_firebolt_damage: V,
    shadowburn_shard_refund: V,
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

pub fn decode(encoded: U) Effects {
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

    const shadow_base = @as(V, @splat(1.0)) + @as(V, @splat(0.01)) * asFloat(shadow);
    const shadow_mult = shadow_base * (@as(V, @splat(1.0)) + @as(V, @splat(0.03)) * asFloat(soul_link));
    const periodic_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.01)) * asFloat(malediction);
    const drains_mult = @select(f32, drains == @as(U, @splat(1)), @as(V, @splat(1.07)),
        @select(f32, drains == @as(U, @splat(2)), @as(V, @splat(1.13)),
            @select(f32, drains >= @as(U, @splat(3)), @as(V, @splat(1.20)), @as(V, @splat(1.0)))));
    const mana_mult = @select(f32, cataclysm == @as(U, @splat(1)), @as(V, @splat(0.97)),
        @select(f32, cataclysm == @as(U, @splat(2)), @as(V, @splat(0.94)),
            @select(f32, cataclysm >= @as(U, @splat(3)), @as(V, @splat(0.90)), @as(V, @splat(1.0)))));
    const siphon_life_transfer_mult = shadow_mult * periodic_mult;

    return .{
        .agony_damage = shadow_mult * periodic_mult * (@as(V, @splat(1.0)) + @as(V, @splat(0.05)) * asFloat(agony)),
        .corruption_damage = shadow_mult * periodic_mult * (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(corruption)),
        .periodic_damage = periodic_mult,
        .siphon_life_damage = siphon_life_transfer_mult,
        // Siphon Life transfers the health it drains; its healing follows the
        // same damage modifiers as the periodic damage tick.
        .siphon_life_healing = siphon_life_transfer_mult,
        .shadow_damage = shadow_mult,
        // Drain Life deals periodic Shadow damage, so Malediction applies
        // alongside Shadow Mastery and Improved Drains.
        .drain_life_damage = shadow_mult * periodic_mult * drains_mult,
        .drain_life_healing = shadow_base * drains_mult,
        .damage_taken = @as(V, @splat(1.0)) - @as(V, @splat(0.02)) * asFloat(molten_skin),
        .shadow_bolt_cast_time = @as(V, @splat(1.8)) - @as(V, @splat(0.1)) * asFloat(bane),
        .shadow_bolt_mana = mana_mult,
        .pet_damage = (@as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(unholy)) *
            (@as(V, @splat(1.0)) + @as(V, @splat(0.03)) * asFloat(soul_link)),
        .imp_firebolt_damage = @as(V, @splat(60.0)) * (@as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(improved_imp)),
        .shadowburn_shard_refund = asFloat(shadow_and_flame) * @as(V, @splat(0.2)),
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

    const effects = decode(encoded);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effects.shadow_bolt_mana[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.97), effects.shadow_bolt_mana[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.94), effects.shadow_bolt_mana[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.10), effects.agony_damage[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), effects.shadow_bolt_cast_time[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.03 * 1.03), effects.corruption_damage[4], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.13), effects.drain_life_damage[5], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.03 * 1.03 * 1.13), effects.drain_life_damage[6], 0.0001);
}
