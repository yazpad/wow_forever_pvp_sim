//! Compact decoded Priest talent effects used by the SIMD combat kernels.
//! Rank parsing and scalar values are resolved at spec load time; this only
//! unpacks three u32 words per fighter lane and applies vector formulas.
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;

pub const Effects = struct {
    blackout_proc_chance: V,
    shadow_range_mult: V,
    shadow_hit_bonus: V,
    holy_hit_bonus: V,
    holy_crit_bonus: V,
    shadow_crit_multiplier: V,
    pushback_resist: V,
    shadow_damage_mult: V,
    holy_damage_mult: V,
    instant_damage_mult: V,
    healing_mult: V,
    renew_healing_mult: V,
    shield_absorb_mult: V,
    shield_cooldown: V,
    shield_mana_mult: V,
    instant_mana_mult: V,
    shadow_mana_mult: V,
    devouring_plague_mana_mult: V,
    swp_duration: V,
    mind_blast_cooldown: V,
    psychic_scream_cooldown: V,
    mind_flay_damage_mult: V,
    mind_flay_range: V,
    smite_cast_time: V,
    holy_fire_cast_time: V,
    power_in_light_mult: V,
    early_demise_crit_bonus: V,
    shadow_weaving_proc_chance: V,
    spell_damage_taken_mult: V,
    physical_damage_taken_mult: V,
    cc_duration_mult: V,
    renewed_hope_crit_bonus: V,
    divine_aegis_mult: V,
    has_shadowform: B,
};

fn rank(encoded: U, comptime shift: u5, comptime bits: u5) U {
    return (encoded >> @as(@Vector(16, u5), @splat(shift))) & @as(U, @splat((@as(u32, 1) << bits) - 1));
}

fn asFloat(value: U) V {
    return @floatFromInt(value);
}

pub fn mindFlayUnlocked(flags: U) B {
    return (flags & @as(U, @splat(@as(u32, 1) << 12))) != @as(U, @splat(0));
}

pub fn vampiricEmbraceUnlocked(flags: U) B {
    return (flags & @as(U, @splat(@as(u32, 1) << 15))) != @as(U, @splat(0));
}

pub fn silenceUnlocked(flags: U) B {
    return (flags & @as(U, @splat(@as(u32, 1) << 18))) != @as(U, @splat(0));
}

pub fn penanceUnlocked(encoded: U) B {
    return (encoded & @as(U, @splat(@as(u32, 1) << 16))) != @as(U, @splat(0));
}

pub fn innerFocusUnlocked(encoded: U) B {
    return (encoded & @as(U, @splat(@as(u32, 1) << 14))) != @as(U, @splat(0));
}

pub fn pushbackResistance(encoded_rank: U) V {
    return @select(f32, encoded_rank == @as(U, @splat(1)), @as(V, @splat(0.23)), @select(f32, encoded_rank == @as(U, @splat(2)), @as(V, @splat(0.47)), @select(f32, encoded_rank >= @as(U, @splat(3)), @as(V, @splat(0.70)), @as(V, @splat(0.0)))));
}

pub fn decode(encoded: U, flags: U, extra: U) Effects {
    // Low 32-bit word (encoded)
    const power_in_light = rank(encoded, 0, 3);
    const twin_disciplines = rank(encoded, 3, 3);
    const silent_resolve = rank(encoded, 6, 2);
    const holy_precision = rank(encoded, 8, 2);
    const imp_pws = rank(encoded, 10, 2);
    const mental_agility = rank(encoded, 12, 2);
    const soul_warding = rank(encoded, 15, 1);
    const twilight_focus = rank(encoded, 17, 2);
    const imp_renew = rank(encoded, 19, 2);
    const holy_spec = rank(encoded, 21, 3);
    const spell_warding = rank(encoded, 24, 3);
    const divine_fury = rank(encoded, 27, 3);
    const searing_light = rank(encoded, 30, 2);

    // High 32-bit word (flags)
    const spiritual_healing = rank(flags, 0, 2);
    const shadow_focus = rank(flags, 2, 3);
    const imp_swp = rank(flags, 5, 2);
    const imp_mb = rank(flags, 7, 3);
    const imp_scream = rank(flags, 10, 2);
    const imp_mind_flay = rank(flags, 13, 2);
    const shadow_weaving = rank(flags, 16, 2);
    const devouring_contagion = rank(flags, 19, 2);
    const early_demise = rank(flags, 21, 2);
    const darkness = rank(flags, 23, 3);
    const shadowform_rank = rank(flags, 26, 1);
    const renewed_hope = rank(flags, 27, 3);
    const divine_aegis = rank(flags, 30, 2);

    const has_shadowform: B = shadowform_rank != @as(U, @splat(0));

    // Twin Disciplines: +1%/rank instant cast damage and healing
    const instant_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.01)) * asFloat(twin_disciplines);

    // Mental Agility: -3% / -7% / -10% mana cost on instant spells, Smite, Holy Fire
    const mental_agility_mult = @select(f32, mental_agility == @as(U, @splat(1)), @as(V, @splat(0.97)), @select(f32, mental_agility == @as(U, @splat(2)), @as(V, @splat(0.93)), @select(f32, mental_agility >= @as(U, @splat(3)), @as(V, @splat(0.90)), @as(V, @splat(1.0)))));

    // Improved Power Word: Shield: +7% / +14% / +20% absorb
    const imp_pws_mult = @select(f32, imp_pws == @as(U, @splat(1)), @as(V, @splat(1.07)), @select(f32, imp_pws == @as(U, @splat(2)), @as(V, @splat(1.14)), @select(f32, imp_pws >= @as(U, @splat(3)), @as(V, @splat(1.20)), @as(V, @splat(1.0)))));

    // Soul Warding: -4s cooldown and -15% mana cost on PW:S
    const has_soul_warding: B = soul_warding != @as(U, @splat(0));
    const shield_cd = @select(f32, has_soul_warding, @as(V, @splat(11.0)), @as(V, @splat(15.0)));
    const shield_mana = mental_agility_mult * @select(f32, has_soul_warding, @as(V, @splat(0.85)), @as(V, @splat(1.0)));

    // Searing Light: +2% / +5% Holy damage
    const searing_light_mult = @select(f32, searing_light == @as(U, @splat(1)), @as(V, @splat(1.02)), @select(f32, searing_light >= @as(U, @splat(2)), @as(V, @splat(1.05)), @as(V, @splat(1.0))));

    // Spiritual Healing: +3% / +7% / +10% healing
    const spiritual_healing_mult = @select(f32, spiritual_healing == @as(U, @splat(1)), @as(V, @splat(1.03)), @select(f32, spiritual_healing == @as(U, @splat(2)), @as(V, @splat(1.07)), @select(f32, spiritual_healing >= @as(U, @splat(3)), @as(V, @splat(1.10)), @as(V, @splat(1.0)))));

    // Improved Renew: +5% / +10% / +15% Renew healing
    const imp_renew_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.05)) * asFloat(imp_renew);

    // Darkness (+2%/rank all Shadow damage) * Shadowform (+10% Shadow damage)
    const darkness_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(darkness);
    const shadowform_dmg_mult = @select(f32, has_shadowform, @as(V, @splat(1.10)), @as(V, @splat(1.0)));
    const shadow_damage_mult = darkness_mult * shadowform_dmg_mult;

    // Shadowform: -50% Shadow mana cost (applied multiplicatively after Mental Agility in Forever)
    const shadow_mana_mult = @select(f32, has_shadowform, @as(V, @splat(0.50)), @as(V, @splat(1.0)));

    // Devouring Contagion: -25% / -50% Devouring Plague mana cost
    const contagion_mult = @select(f32, devouring_contagion == @as(U, @splat(1)), @as(V, @splat(0.75)), @select(f32, devouring_contagion >= @as(U, @splat(2)), @as(V, @splat(0.50)), @as(V, @splat(1.0))));

    // Shadow Weaving proc chance: 33% / 67% / 100%
    const sw_proc = @select(f32, shadow_weaving == @as(U, @splat(1)), @as(V, @splat(0.33)), @select(f32, shadow_weaving == @as(U, @splat(2)), @as(V, @splat(0.67)), @select(f32, shadow_weaving >= @as(U, @splat(3)), @as(V, @splat(1.0)), @as(V, @splat(0.0)))));

    const divine_fury_red = @as(V, @splat(0.1)) * asFloat(divine_fury);

    return .{
        .blackout_proc_chance = @as(V, @splat(0.02)) * asFloat(rank(extra, 0, 3)),
        .shadow_range_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(rank(extra, 3, 2)),
        .shadow_hit_bonus = @as(V, @splat(0.01)) * asFloat(shadow_focus),
        .holy_hit_bonus = @as(V, @splat(0.06)) * asFloat(holy_precision),
        .holy_crit_bonus = @as(V, @splat(0.01)) * asFloat(holy_spec),
        .shadow_crit_multiplier = @select(f32, has_shadowform, @as(V, @splat(2.0)), @as(V, @splat(1.5))),
        .pushback_resist = pushbackResistance(twilight_focus),
        .shadow_damage_mult = shadow_damage_mult,
        .holy_damage_mult = searing_light_mult,
        .instant_damage_mult = instant_mult,
        .healing_mult = spiritual_healing_mult,
        .renew_healing_mult = spiritual_healing_mult * instant_mult * imp_renew_mult,
        .shield_absorb_mult = imp_pws_mult * instant_mult,
        .shield_cooldown = shield_cd,
        .shield_mana_mult = shield_mana,
        .instant_mana_mult = mental_agility_mult,
        .shadow_mana_mult = shadow_mana_mult,
        .devouring_plague_mana_mult = mental_agility_mult * contagion_mult * shadow_mana_mult,
        .swp_duration = @as(V, @splat(18.0)) + @as(V, @splat(3.0)) * asFloat(imp_swp),
        .mind_blast_cooldown = @as(V, @splat(8.0)) - @as(V, @splat(0.5)) * asFloat(imp_mb),
        .psychic_scream_cooldown = @as(V, @splat(30.0)) - @as(V, @splat(2.0)) * asFloat(imp_scream),
        .mind_flay_damage_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.10)) * asFloat(imp_mind_flay),
        .mind_flay_range = @as(V, @splat(20.0)) + @as(V, @splat(5.0)) * asFloat(imp_mind_flay),
        .smite_cast_time = @max(@as(V, @splat(0.0)), @as(V, @splat(2.5)) - divine_fury_red),
        .holy_fire_cast_time = @max(@as(V, @splat(0.0)), @as(V, @splat(@import("spec.zig").Priest.HolyFireCast)) - divine_fury_red),
        .power_in_light_mult = @as(V, @splat(1.0)) + @as(V, @splat(0.02)) * asFloat(power_in_light),
        .early_demise_crit_bonus = @as(V, @splat(0.15)) * asFloat(early_demise),
        .shadow_weaving_proc_chance = sw_proc,
        .spell_damage_taken_mult = @as(V, @splat(1.0)) - @as(V, @splat(0.02)) * asFloat(spell_warding),
        .physical_damage_taken_mult = @select(f32, has_shadowform, @as(V, @splat(0.85)), @as(V, @splat(1.0))),
        .cc_duration_mult = @as(V, @splat(1.0)) - @as(V, @splat(0.05)) * asFloat(silent_resolve),
        .renewed_hope_crit_bonus = @as(V, @splat(0.02)) * asFloat(renewed_hope),
        .divine_aegis_mult = @as(V, @splat(0.05)) * asFloat(divine_aegis),
        .has_shadowform = has_shadowform,
    };
}

test "Priest talent decode applies ranks independently per SIMD lane" {
    const std = @import("std");
    const spec = @import("spec.zig");
    var encoded: U = @splat(0);
    var flags: U = @splat(0);

    const shadow_ranks = spec.PriestTalentRanks{
        .twin_disciplines = 5,
        .improved_power_word_shield = 3,
        .mental_agility = 3,
        .shadow_focus = 5,
        .improved_shadow_word_pain = 2,
        .improved_mind_blast = 5,
        .mind_flay = 1,
        .improved_mind_flay = 2,
        .vampiric_embrace = 1,
        .shadow_weaving = 3,
        .silence = 1,
        .devouring_contagion = 2,
        .early_demise = 2,
        .darkness = 5,
        .shadowform = 1,
    };
    const disc_ranks = spec.PriestTalentRanks{
        .power_in_light = 5,
        .silent_resolve = 3,
        .holy_precision = 3,
        .inner_focus = 1,
        .soul_warding = 1,
        .penance = 1,
        .twilight_focus = 3,
        .holy_specialization = 5,
        .spell_warding = 5,
        .divine_fury = 5,
        .searing_light = 2,
    };

    encoded[0] = 0;
    flags[0] = 0;
    encoded[1] = @truncate(shadow_ranks.encode());
    flags[1] = @truncate(shadow_ranks.encode() >> 32);
    encoded[2] = @truncate(disc_ranks.encode());
    flags[2] = @truncate(disc_ranks.encode() >> 32);

    const effects = decode(encoded, flags, @splat(0));

    // Lane 0: baseline
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effects.shadow_damage_mult[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), effects.shadow_crit_multiplier[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), effects.swp_duration[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), effects.mind_blast_cooldown[0], 0.0001);
    try std.testing.expect(!effects.has_shadowform[0]);

    // Lane 1: Deep Shadow
    try std.testing.expectApproxEqAbs(@as(f32, 1.10 * 1.10), effects.shadow_damage_mult[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), effects.shadow_crit_multiplier[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), effects.swp_duration[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), effects.mind_blast_cooldown[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.20), effects.mind_flay_damage_mult[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), effects.mind_flay_range[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.90 * 0.50 * 0.50), effects.devouring_plague_mana_mult[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), effects.early_demise_crit_bonus[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effects.shadow_weaving_proc_chance[1], 0.0001);
    try std.testing.expect(effects.has_shadowform[1]);
    try std.testing.expect(mindFlayUnlocked(flags)[1]);
    try std.testing.expect(vampiricEmbraceUnlocked(flags)[1]);
    try std.testing.expect(silenceUnlocked(flags)[1]);

    // Lane 2: Disc / Smite
    try std.testing.expectApproxEqAbs(@as(f32, 1.10), effects.power_in_light_mult[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.18), effects.holy_hit_bonus[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), effects.holy_crit_bonus[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), effects.pushback_resist[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), effects.shield_cooldown[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), effects.smite_cast_time[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), effects.holy_fire_cast_time[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), effects.holy_damage_mult[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.90), effects.spell_damage_taken_mult[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), effects.cc_duration_mult[2], 0.0001);
    try std.testing.expect(penanceUnlocked(encoded)[2]);
    try std.testing.expect(innerFocusUnlocked(encoded)[2]);
}
