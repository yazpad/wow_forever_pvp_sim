const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const warlock_talents = @import("warlock_talents.zig");
const action_catalog = @import("action_catalog_generated.zig");

const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const i32x16 = simd.i32x16;
const bool16 = simd.bool16;
const select16 = simd.select16;
const vAnd16 = simd.vAnd16;
const vOr16 = simd.vOr16;
const vNot16 = simd.vNot16;
const VEC_LEN = simd.SimdConfig.VecLen16;
const ALIGNMENT = simd.SimdConfig.Alignment;

/// Generated from visualizer/data/action_catalog.json to keep action IDs synchronized.
pub const WarlockAction = action_catalog.WarlockAction;

/// Movement intention commanded by policy or maneuver
pub const MoveIntent = enum(i32) {
    Advance = -1, // Close distance towards target (-7.0 m/s)
    Stand = 0, // Stand stationary (0.0 m/s)
    Kite = 1, // Kite away at normal run speed (+7.0 m/s)
};

pub const WarlockConstants = struct {
    pub const MaxHp: f32 = 2000.0;
    pub const MaxMana: f32 = 1000.0;
    pub const ManaRegenPerSec: f32 = 15.0;

    pub const ForwardSpeed: f32 = 7.0; // m/s
    pub const MinDistance: f32 = 0.0; // m (no artificial minimum collision boundary)
    pub const MaxDistance: f32 = 35.0; // m (arena boundary)

    pub const StandardGcd: f32 = 1.0; // seconds
    pub const ReactionInterval: f32 = 0.100; // 100ms cognitive interval

    // Spell Parameters
    pub const AgonyMana: f32 = 30.0;
    pub const AgonyDuration: f32 = 18.0;
    pub const AgonyDps: f32 = 30.0; // base DPS

    pub const CorruptionMana: f32 = 40.0;
    pub const CorruptionDuration: f32 = 14.0;
    pub const CorruptionDps: f32 = 50.0;

    pub const SiphonLifeMana: f32 = 45.0;
    pub const SiphonLifeDuration: f32 = 30.0;
    pub const SiphonLifeDps: f32 = 25.0;
    pub const SiphonLifeHps: f32 = 25.0;
    pub const SiphonLifeRange: f32 = 30.0;

    pub const FearMana: f32 = 60.0;
    pub const FearCastTime: f32 = 1.5;
    pub const FearDuration: f32 = 4.0;
    pub const FearBreakDmgThreshold: f32 = 250.0;
    pub const FearRange: f32 = 20.0;

    pub const ShadowBoltMana: f32 = 50.0;
    pub const ShadowBoltCastTime: f32 = 1.8;
    pub const ShadowBoltDamage: f32 = 240.0;

    pub const DrainLifeMana: f32 = 70.0;
    pub const DrainLifeDuration: f32 = 3.0;
    pub const DrainLifeDps: f32 = 70.0;
    pub const DrainLifeHps: f32 = 60.0;
    pub const DrainLifeRange: f32 = 25.0;

    pub const HealthstoneCooldown: f32 = 120.0;
    pub const HealthstoneHeal: f32 = 1200.0;

    pub const DeathCoilMana: f32 = 50.0;
    pub const DeathCoilCooldown: f32 = 45.0;
    pub const DeathCoilDuration: f32 = 3.0; // 3.0s Horror
    pub const DeathCoilDamage: f32 = 180.0;
    pub const DeathCoilHeal: f32 = 300.0;
    pub const DeathCoilRange: f32 = 30.0;
    pub const SeductionCooldown: f32 = 15.0;
    pub const SeductionCastTime: f32 = 1.5;
    pub const SeductionDuration: f32 = 15.0;
    pub const SeductionRange: f32 = 30.0;
    pub const SpellLockCooldown: f32 = 24.0;
    pub const SpellLockRange: f32 = 30.0;
    pub const SpellLockDuration: f32 = 4.0;

    pub const ShadowburnMana: f32 = 245.0;
    pub const ShadowburnCooldown: f32 = 15.0;
    pub const ShadowburnDamage: f32 = 148.0;
    pub const ShadowburnRange: f32 = 30.0;
    pub const SearingPainMana: f32 = 40.0;
    pub const SearingPainCastTime: f32 = 1.5;
    pub const SearingPainDamage: f32 = 130.0;
    pub const SearingPainRange: f32 = 20.0;
    pub const IncinerateMana: f32 = 90.0;
    pub const IncinerateCastTime: f32 = 2.5;
    pub const IncinerateDamage: f32 = 220.0;
    pub const ImmolateMana: f32 = 90.0;
    pub const ImmolateCastTime: f32 = 2.0;
    pub const ImmolateInitialDamage: f32 = 110.0;
    pub const ImmolateDuration: f32 = 15.0;
    pub const ImmolateDps: f32 = 28.0;
    // Base damage follows the checked-in Conflagrate talent tooltip (88-111).
    // Like the other compact-kit constants, spell-rank tuning is separate.
    pub const ConflagrateMana: f32 = 100.0;
    pub const ConflagrateDamage: f32 = 99.5;
    pub const ConflagrateCooldown: f32 = 10.0;
    pub const ConflagrateRange: f32 = 30.0;
    pub const FireSpellRange: f32 = 30.0;

    pub const DrResetDuration: f32 = 18.0; // DR window resets after 18s without new CC
};

/// Helper to branchlessly compute Diminishing Returns multiplier:
/// Tier 0 = 1.0 (Full), Tier 1 = 0.5 (Half), Tier 2 = 0.25 (Quarter), Tier >= 3 = 0.0 (Immune)
pub inline fn getDrMultiplier(tier: f32x16) f32x16 {
    const v_zeros: f32x16 = @splat(0.0);
    const v_half: f32x16 = @splat(0.5);
    const v_quarter: f32x16 = @splat(0.25);
    const v_one: f32x16 = @splat(1.0);

    return select16(tier < @as(f32x16, @splat(0.5)), v_one, select16(tier < @as(f32x16, @splat(1.5)), v_half, select16(tier < @as(f32x16, @splat(2.5)), v_quarter, v_zeros)));
}

/// 64-byte aligned Structure-of-Arrays combat pool for Vectorized Warlock PvP Duels.
/// Every batch contains `capacity` duel pairs (A vs B).
pub const WarlockArenaPool = struct {
    pub const SpecA: @import("spec.zig").Spec = .warlock;
    pub const SpecB: @import("spec.zig").Spec = .warlock;
    count: usize,
    capacity: usize,
    allocator: mem.Allocator,

    // Autonomous pet slots: no pet mana or player targeting/action choices.
    pet_kind_a: []align(ALIGNMENT) u32,
    pet_hp_a: []align(ALIGNMENT) f32,
    pet_timer_a: []align(ALIGNMENT) f32,
    pet_x_a: []align(ALIGNMENT) f32,
    pet_y_a: []align(ALIGNMENT) f32,
    impact_pet_a: []align(ALIGNMENT) f32,
    soul_link_a: []align(ALIGNMENT) u32,
    talent_ranks_a: []align(ALIGNMENT) u32,
    talent_flags_a: []align(ALIGNMENT) u32,
    talent_extra_a: []align(ALIGNMENT) u32,
    pet_kind_b: []align(ALIGNMENT) u32,
    pet_hp_b: []align(ALIGNMENT) f32,
    pet_timer_b: []align(ALIGNMENT) f32,
    pet_x_b: []align(ALIGNMENT) f32,
    pet_y_b: []align(ALIGNMENT) f32,
    impact_pet_b: []align(ALIGNMENT) f32,
    soul_link_b: []align(ALIGNMENT) u32,
    talent_ranks_b: []align(ALIGNMENT) u32,
    talent_flags_b: []align(ALIGNMENT) u32,
    talent_extra_b: []align(ALIGNMENT) u32,

    // Shared Arena Geometry between A and B
    distance: []align(ALIGNMENT) f32, // meters between Unit A and Unit B

    pos_x_a: []align(ALIGNMENT) f32,
    pos_y_a: []align(ALIGNMENT) f32,
    pos_x_b: []align(ALIGNMENT) f32,
    pos_y_b: []align(ALIGNMENT) f32,

    projectile_0_spell_a: []align(ALIGNMENT) f32,
    projectile_0_damage_a: []align(ALIGNMENT) f32,
    projectile_0_x_a: []align(ALIGNMENT) f32,
    projectile_0_y_a: []align(ALIGNMENT) f32,
    projectile_1_spell_a: []align(ALIGNMENT) f32,
    projectile_1_damage_a: []align(ALIGNMENT) f32,
    projectile_1_x_a: []align(ALIGNMENT) f32,
    projectile_1_y_a: []align(ALIGNMENT) f32,
    projectile_2_spell_a: []align(ALIGNMENT) f32,
    projectile_2_damage_a: []align(ALIGNMENT) f32,
    projectile_2_x_a: []align(ALIGNMENT) f32,
    projectile_2_y_a: []align(ALIGNMENT) f32,
    projectile_3_spell_a: []align(ALIGNMENT) f32,
    projectile_3_damage_a: []align(ALIGNMENT) f32,
    projectile_3_x_a: []align(ALIGNMENT) f32,
    projectile_3_y_a: []align(ALIGNMENT) f32,
    projectile_0_spell_b: []align(ALIGNMENT) f32,
    projectile_0_damage_b: []align(ALIGNMENT) f32,
    projectile_0_x_b: []align(ALIGNMENT) f32,
    projectile_0_y_b: []align(ALIGNMENT) f32,
    projectile_1_spell_b: []align(ALIGNMENT) f32,
    projectile_1_damage_b: []align(ALIGNMENT) f32,
    projectile_1_x_b: []align(ALIGNMENT) f32,
    projectile_1_y_b: []align(ALIGNMENT) f32,
    projectile_2_spell_b: []align(ALIGNMENT) f32,
    projectile_2_damage_b: []align(ALIGNMENT) f32,
    projectile_2_x_b: []align(ALIGNMENT) f32,
    projectile_2_y_b: []align(ALIGNMENT) f32,
    projectile_3_spell_b: []align(ALIGNMENT) f32,
    projectile_3_damage_b: []align(ALIGNMENT) f32,
    projectile_3_x_b: []align(ALIGNMENT) f32,
    projectile_3_y_b: []align(ALIGNMENT) f32,
    impact_bolt_a: []align(ALIGNMENT) f32,
    impact_lance_a: []align(ALIGNMENT) f32,
    impact_coil_a: []align(ALIGNMENT) f32,
    impact_bolt_b: []align(ALIGNMENT) f32,
    impact_lance_b: []align(ALIGNMENT) f32,
    impact_coil_b: []align(ALIGNMENT) f32,

    projectile_count_a: []align(ALIGNMENT) f32,
    projectile_count_b: []align(ALIGNMENT) f32,

    impact_mask_a: []align(ALIGNMENT) u32,
    impact_mask_b: []align(ALIGNMENT) u32,

    // Unit A SoA Columns
    race_a: []align(ALIGNMENT) u32,
    priest_pi_cd_a: []align(ALIGNMENT) f32,
    priest_pi_timer_a: []align(ALIGNMENT) f32,
    racial_cd_a: []align(ALIGNMENT) f32,
    racial_power_timer_a: []align(ALIGNMENT) f32,
    racial_haste_timer_a: []align(ALIGNMENT) f32,
    racial_escape_timer_a: []align(ALIGNMENT) f32,
    hp_a: []align(ALIGNMENT) f32,
    mana_a: []align(ALIGNMENT) f32,
    gcd_a: []align(ALIGNMENT) f32,
    react_timer_a: []align(ALIGNMENT) f32, // seconds until next cognitive decision
    move_intent_a: []align(ALIGNMENT) f32, // -1 (advance), 0 (stationary), +1 (kite)

    cast_id_a: []align(ALIGNMENT) u32, // 0 = none, 3 = Fear, 4 = ShadowBolt, 5 = DrainLife
    cast_pushback_count_a: []align(ALIGNMENT) u32, // successful pushbacks, saturates at 4
    cast_timer_a: []align(ALIGNMENT) f32, // remaining seconds on active cast
    cast_total_a: []align(ALIGNMENT) f32, // total duration of cast
    channel_elapsed_a: []align(ALIGNMENT) f32, // natural channel time; independent of shortened expiry

    // Debuffs on A (inflicted by B)
    agony_timer_a: []align(ALIGNMENT) f32,
    immolate_timer_a: []align(ALIGNMENT) f32,
    corruption_timer_a: []align(ALIGNMENT) f32,
    siphon_timer_a: []align(ALIGNMENT) f32,
    fear_timer_a: []align(ALIGNMENT) f32,
    fear_accum_dmg_a: []align(ALIGNMENT) f32,
    stun_timer_a: []align(ALIGNMENT) f32,
    stun_dr_tier_a: []align(ALIGNMENT) f32,
    stun_dr_timer_a: []align(ALIGNMENT) f32,
    horror_timer_a: []align(ALIGNMENT) f32,
    seduction_timer_a: []align(ALIGNMENT) f32,

    // Buffs / Cooldowns on A
    action6_cd_a: []align(ALIGNMENT) f32,
    action6_dur_a: []align(ALIGNMENT) f32,
    death_coil_cd_a: []align(ALIGNMENT) f32,
    shadowburn_cd_a: []align(ALIGNMENT) f32,
    conflagrate_cd_a: []align(ALIGNMENT) f32,
    conflagrate_pending_a: []align(ALIGNMENT) f32,
    daze_timer_a: []align(ALIGNMENT) f32,
    shadow_flame_timer_a: []align(ALIGNMENT) f32,
    isb_timer_a: []align(ALIGNMENT) f32,
    isb_charges_a: []align(ALIGNMENT) f32,
    isb_vuln_a: []align(ALIGNMENT) f32,
    impact_conflagrate_a: []align(ALIGNMENT) f32,
    conflagrate_rng_a: []align(ALIGNMENT) u32,
    spell_rng_a: []align(ALIGNMENT) u32,
    pushback_rng_a: []align(ALIGNMENT) u32,
    pet_rng_a: []align(ALIGNMENT) u32,
    spell_outcome_a: []align(ALIGNMENT) u32,
    pet_outcome_a: []align(ALIGNMENT) u32,
    spell_hit_chance_a: []align(ALIGNMENT) f32,
    max_health_a: []align(ALIGNMENT) f32,
    max_mana_a: []align(ALIGNMENT) f32,
    shadow_power_a: []align(ALIGNMENT) f32,
    fire_power_a: []align(ALIGNMENT) f32,
    frost_power_a: []align(ALIGNMENT) f32,
    level_a: []align(ALIGNMENT) f32,
    spell_penetration_a: []align(ALIGNMENT) f32,
    shadow_resistance_a: []align(ALIGNMENT) f32,
    fire_resistance_a: []align(ALIGNMENT) f32,
    frost_resistance_a: []align(ALIGNMENT) f32,
    arcane_resistance_a: []align(ALIGNMENT) f32,
    pet_hit_chance_a: []align(ALIGNMENT) f32,
    pet_crit_chance_a: []align(ALIGNMENT) f32,
    melee_avoidance_chance_a: []align(ALIGNMENT) f32,
    armor_damage_reduction_a: []align(ALIGNMENT) f32,
    spell_crit_chance_a: []align(ALIGNMENT) f32,
    shadow_resist_chance_a: []align(ALIGNMENT) f32,
    fire_resist_chance_a: []align(ALIGNMENT) f32,
    frost_resist_chance_a: []align(ALIGNMENT) f32,
    arcane_resist_chance_a: []align(ALIGNMENT) f32,
    seduction_cd_a: []align(ALIGNMENT) f32,
    shadow_lockout_a: []align(ALIGNMENT) f32,
    fire_lockout_a: []align(ALIGNMENT) f32,
    seduction_cast_a: []align(ALIGNMENT) f32,
    seduced_a: []align(ALIGNMENT) u32,
    soul_shards_a: []align(ALIGNMENT) f32,

    // Diminishing Returns tracking on A
    fear_dr_tier_a: []align(ALIGNMENT) f32, // 0.0=100%, 1.0=50%, 2.0=25%, 3.0=Immune
    fear_dr_timer_a: []align(ALIGNMENT) f32, // countdown from 18s
    horror_dr_tier_a: []align(ALIGNMENT) f32, // 0.0=100%, 1.0=50%, 2.0=25%, 3.0=Immune
    horror_dr_timer_a: []align(ALIGNMENT) f32, // countdown from 18s
    seduction_dr_tier_a: []align(ALIGNMENT) f32,
    seduction_dr_timer_a: []align(ALIGNMENT) f32,

    // Unit B SoA Columns
    race_b: []align(ALIGNMENT) u32,
    priest_pi_cd_b: []align(ALIGNMENT) f32,
    priest_pi_timer_b: []align(ALIGNMENT) f32,
    racial_cd_b: []align(ALIGNMENT) f32,
    racial_power_timer_b: []align(ALIGNMENT) f32,
    racial_haste_timer_b: []align(ALIGNMENT) f32,
    racial_escape_timer_b: []align(ALIGNMENT) f32,
    hp_b: []align(ALIGNMENT) f32,
    mana_b: []align(ALIGNMENT) f32,
    gcd_b: []align(ALIGNMENT) f32,
    react_timer_b: []align(ALIGNMENT) f32,
    move_intent_b: []align(ALIGNMENT) f32,

    cast_id_b: []align(ALIGNMENT) u32,
    cast_pushback_count_b: []align(ALIGNMENT) u32,
    cast_timer_b: []align(ALIGNMENT) f32,
    cast_total_b: []align(ALIGNMENT) f32,
    channel_elapsed_b: []align(ALIGNMENT) f32,

    // Debuffs on B (inflicted by A)
    agony_timer_b: []align(ALIGNMENT) f32,
    immolate_timer_b: []align(ALIGNMENT) f32,
    corruption_timer_b: []align(ALIGNMENT) f32,
    siphon_timer_b: []align(ALIGNMENT) f32,
    fear_timer_b: []align(ALIGNMENT) f32,
    fear_accum_dmg_b: []align(ALIGNMENT) f32,
    stun_timer_b: []align(ALIGNMENT) f32,
    stun_dr_tier_b: []align(ALIGNMENT) f32,
    stun_dr_timer_b: []align(ALIGNMENT) f32,
    horror_timer_b: []align(ALIGNMENT) f32,
    seduction_timer_b: []align(ALIGNMENT) f32,

    // Buffs / Cooldowns on B
    action6_cd_b: []align(ALIGNMENT) f32,
    action6_dur_b: []align(ALIGNMENT) f32,
    death_coil_cd_b: []align(ALIGNMENT) f32,
    shadowburn_cd_b: []align(ALIGNMENT) f32,
    conflagrate_cd_b: []align(ALIGNMENT) f32,
    conflagrate_pending_b: []align(ALIGNMENT) f32,
    daze_timer_b: []align(ALIGNMENT) f32,
    shadow_flame_timer_b: []align(ALIGNMENT) f32,
    isb_timer_b: []align(ALIGNMENT) f32,
    isb_charges_b: []align(ALIGNMENT) f32,
    isb_vuln_b: []align(ALIGNMENT) f32,
    impact_conflagrate_b: []align(ALIGNMENT) f32,
    conflagrate_rng_b: []align(ALIGNMENT) u32,
    spell_rng_b: []align(ALIGNMENT) u32,
    pushback_rng_b: []align(ALIGNMENT) u32,
    pet_rng_b: []align(ALIGNMENT) u32,
    spell_outcome_b: []align(ALIGNMENT) u32,
    pet_outcome_b: []align(ALIGNMENT) u32,
    spell_hit_chance_b: []align(ALIGNMENT) f32,
    max_health_b: []align(ALIGNMENT) f32,
    max_mana_b: []align(ALIGNMENT) f32,
    shadow_power_b: []align(ALIGNMENT) f32,
    fire_power_b: []align(ALIGNMENT) f32,
    frost_power_b: []align(ALIGNMENT) f32,
    level_b: []align(ALIGNMENT) f32,
    spell_penetration_b: []align(ALIGNMENT) f32,
    shadow_resistance_b: []align(ALIGNMENT) f32,
    fire_resistance_b: []align(ALIGNMENT) f32,
    frost_resistance_b: []align(ALIGNMENT) f32,
    arcane_resistance_b: []align(ALIGNMENT) f32,
    pet_hit_chance_b: []align(ALIGNMENT) f32,
    pet_crit_chance_b: []align(ALIGNMENT) f32,
    melee_avoidance_chance_b: []align(ALIGNMENT) f32,
    armor_damage_reduction_b: []align(ALIGNMENT) f32,
    spell_crit_chance_b: []align(ALIGNMENT) f32,
    shadow_resist_chance_b: []align(ALIGNMENT) f32,
    fire_resist_chance_b: []align(ALIGNMENT) f32,
    frost_resist_chance_b: []align(ALIGNMENT) f32,
    arcane_resist_chance_b: []align(ALIGNMENT) f32,
    seduction_cd_b: []align(ALIGNMENT) f32,
    shadow_lockout_b: []align(ALIGNMENT) f32,
    fire_lockout_b: []align(ALIGNMENT) f32,
    seduction_cast_b: []align(ALIGNMENT) f32,
    seduced_b: []align(ALIGNMENT) u32,
    soul_shards_b: []align(ALIGNMENT) f32,

    // Diminishing Returns tracking on B
    fear_dr_tier_b: []align(ALIGNMENT) f32,
    fear_dr_timer_b: []align(ALIGNMENT) f32,
    horror_dr_tier_b: []align(ALIGNMENT) f32,
    horror_dr_timer_b: []align(ALIGNMENT) f32,
    seduction_dr_tier_b: []align(ALIGNMENT) f32,
    seduction_dr_timer_b: []align(ALIGNMENT) f32,

    // Duel State: 1 = active, 0 = duel concluded
    is_active: []align(ALIGNMENT) u32,

    pub fn init(allocator: mem.Allocator, capacity: usize) !WarlockArenaPool {
        const padded_cap = (capacity + VEC_LEN - 1) & ~@as(usize, VEC_LEN - 1);

        const pet_kind_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_kind_a);
        const pet_hp_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_hp_a);
        const pet_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_timer_a);
        const pet_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_x_a);
        const pet_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_y_a);
        const impact_pet_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_pet_a);
        const soul_link_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(soul_link_a);
        const talent_ranks_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_ranks_a);
        const talent_flags_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_flags_a);
        const talent_extra_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_extra_a);
        const pet_kind_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_kind_b);
        const pet_hp_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_hp_b);
        const pet_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_timer_b);
        const pet_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_x_b);
        const pet_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_y_b);
        const impact_pet_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_pet_b);
        const soul_link_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(soul_link_b);
        const talent_ranks_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_ranks_b);
        const talent_flags_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_flags_b);
        const talent_extra_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(talent_extra_b);

        const dist = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dist);

        const pos_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pos_x_a);
        const pos_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pos_y_a);
        const pos_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pos_x_b);
        const pos_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pos_y_b);

        const projectile_0_spell_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_spell_a);
        const projectile_0_damage_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_damage_a);
        const projectile_0_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_x_a);
        const projectile_0_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_y_a);
        const projectile_1_spell_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_spell_a);
        const projectile_1_damage_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_damage_a);
        const projectile_1_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_x_a);
        const projectile_1_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_y_a);
        const projectile_2_spell_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_spell_a);
        const projectile_2_damage_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_damage_a);
        const projectile_2_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_x_a);
        const projectile_2_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_y_a);
        const projectile_3_spell_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_spell_a);
        const projectile_3_damage_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_damage_a);
        const projectile_3_x_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_x_a);
        const projectile_3_y_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_y_a);
        const projectile_0_spell_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_spell_b);
        const projectile_0_damage_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_damage_b);
        const projectile_0_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_x_b);
        const projectile_0_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_0_y_b);
        const projectile_1_spell_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_spell_b);
        const projectile_1_damage_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_damage_b);
        const projectile_1_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_x_b);
        const projectile_1_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_1_y_b);
        const projectile_2_spell_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_spell_b);
        const projectile_2_damage_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_damage_b);
        const projectile_2_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_x_b);
        const projectile_2_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_2_y_b);
        const projectile_3_spell_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_spell_b);
        const projectile_3_damage_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_damage_b);
        const projectile_3_x_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_x_b);
        const projectile_3_y_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_3_y_b);
        const impact_bolt_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_bolt_a);
        const impact_lance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_lance_a);
        const impact_coil_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_coil_a);
        const impact_bolt_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_bolt_b);
        const impact_lance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_lance_b);
        const impact_coil_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_coil_b);

        const projectile_count_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_count_a);
        const projectile_count_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(projectile_count_b);

        const impact_mask_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_mask_a);
        const impact_mask_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_mask_b);

        const race_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(race_a);
        const priest_pi_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(priest_pi_cd_a);
        const priest_pi_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(priest_pi_timer_a);
        const racial_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_cd_a);
        const racial_power_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_power_timer_a);
        const racial_haste_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_haste_timer_a);
        const racial_escape_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_escape_timer_a);
        const hp_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(hp_a);
        const mana_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(mana_a);
        const gcd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(gcd_a);
        const react_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(react_a);
        const move_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(move_a);

        const cid_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(cid_a);
        const ctmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ctmr_a);
        const ctot_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ctot_a);

        const ago_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ago_a);
        const immolate_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(immolate_a);
        const crp_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(crp_a);
        const siph_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(siph_a);
        const fear_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_a);
        const fear_dmg_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dmg_a);
        const stun_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_timer_a);
        const stun_dr_tier_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_dr_tier_a);
        const stun_dr_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_dr_timer_a);
        const horror_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_a);
        const seduction_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_a);

        const un_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_cd_a);
        const un_dur_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_dur_a);
        const dc_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dc_cd_a);
        const shadowburn_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadowburn_cd_a);
        const conflagrate_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_cd_a);
        const conflagrate_pending_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_pending_a);
        const daze_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(daze_timer_a);
        const shadow_flame_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_flame_timer_a);
        const isb_timer_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_timer_a);
        const isb_charges_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_charges_a);
        const isb_vuln_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_vuln_a);
        const impact_conflagrate_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_conflagrate_a);
        const conflagrate_rng_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_rng_a);
        const spell_rng_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_rng_a);
        const cast_pushback_count_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(cast_pushback_count_a);
        const channel_elapsed_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(channel_elapsed_a);
        const pushback_rng_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pushback_rng_a);
        const pet_rng_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_rng_a);
        const spell_outcome_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_outcome_a);
        const pet_outcome_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_outcome_a);
        const spell_hit_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_hit_chance_a);
        const max_health_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(max_health_a);
        const max_mana_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(max_mana_a);
        const shadow_power_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_power_a);
        const fire_power_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_power_a);
        const frost_power_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_power_a);
        const level_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(level_a);
        const spell_penetration_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_penetration_a);
        const shadow_resistance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_resistance_a);
        const fire_resistance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_resistance_a);
        const frost_resistance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_resistance_a);
        const arcane_resistance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(arcane_resistance_a);
        const pet_hit_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_hit_chance_a);
        const pet_crit_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_crit_chance_a);
        const melee_avoidance_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(melee_avoidance_chance_a);
        const armor_damage_reduction_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(armor_damage_reduction_a);
        const spell_crit_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_crit_chance_a);
        const shadow_resist_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_resist_chance_a);
        const fire_resist_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_resist_chance_a);
        const frost_resist_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_resist_chance_a);
        const arcane_resist_chance_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(arcane_resist_chance_a);
        const seduction_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_cd_a);
        const shadow_lockout_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_lockout_a);
        const fire_lockout_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_lockout_a);
        const seduction_cast_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_cast_a);
        const seduced_a = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduced_a);
        const soul_shards_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(soul_shards_a);

        const fear_dr_t_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_t_a);
        const fear_dr_tmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_tmr_a);
        const horror_dr_t_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_t_a);
        const horror_dr_tmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_tmr_a);
        const seduction_dr_t_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_dr_t_a);
        const seduction_dr_tmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_dr_tmr_a);

        const race_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(race_b);
        const priest_pi_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(priest_pi_cd_b);
        const priest_pi_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(priest_pi_timer_b);
        const racial_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_cd_b);
        const racial_power_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_power_timer_b);
        const racial_haste_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_haste_timer_b);
        const racial_escape_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(racial_escape_timer_b);
        const hp_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(hp_b);
        const mana_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(mana_b);
        const gcd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(gcd_b);
        const react_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(react_b);
        const move_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(move_b);

        const cid_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(cid_b);
        const ctmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ctmr_b);
        const ctot_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ctot_b);

        const ago_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(ago_b);
        const immolate_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(immolate_b);
        const crp_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(crp_b);
        const siph_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(siph_b);
        const fear_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_b);
        const fear_dmg_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dmg_b);
        const stun_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_timer_b);
        const stun_dr_tier_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_dr_tier_b);
        const stun_dr_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(stun_dr_timer_b);
        const horror_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_b);
        const seduction_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_b);

        const un_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_cd_b);
        const un_dur_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_dur_b);
        const dc_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dc_cd_b);
        const shadowburn_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadowburn_cd_b);
        const conflagrate_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_cd_b);
        const conflagrate_pending_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_pending_b);
        const daze_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(daze_timer_b);
        const shadow_flame_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_flame_timer_b);
        const isb_timer_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_timer_b);
        const isb_charges_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_charges_b);
        const isb_vuln_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(isb_vuln_b);
        const impact_conflagrate_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(impact_conflagrate_b);
        const conflagrate_rng_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(conflagrate_rng_b);
        const spell_rng_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_rng_b);
        const cast_pushback_count_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(cast_pushback_count_b);
        const channel_elapsed_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(channel_elapsed_b);
        const pushback_rng_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pushback_rng_b);
        const pet_rng_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_rng_b);
        const spell_outcome_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_outcome_b);
        const pet_outcome_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_outcome_b);
        const spell_hit_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_hit_chance_b);
        const max_health_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(max_health_b);
        const max_mana_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(max_mana_b);
        const shadow_power_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_power_b);
        const fire_power_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_power_b);
        const frost_power_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_power_b);
        const level_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(level_b);
        const spell_penetration_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_penetration_b);
        const shadow_resistance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_resistance_b);
        const fire_resistance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_resistance_b);
        const frost_resistance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_resistance_b);
        const arcane_resistance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(arcane_resistance_b);
        const pet_hit_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_hit_chance_b);
        const pet_crit_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(pet_crit_chance_b);
        const melee_avoidance_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(melee_avoidance_chance_b);
        const armor_damage_reduction_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(armor_damage_reduction_b);
        const spell_crit_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(spell_crit_chance_b);
        const shadow_resist_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_resist_chance_b);
        const fire_resist_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_resist_chance_b);
        const frost_resist_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(frost_resist_chance_b);
        const arcane_resist_chance_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(arcane_resist_chance_b);
        const seduction_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_cd_b);
        const shadow_lockout_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shadow_lockout_b);
        const fire_lockout_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fire_lockout_b);
        const seduction_cast_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_cast_b);
        const seduced_b = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduced_b);
        const soul_shards_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(soul_shards_b);

        const fear_dr_t_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_t_b);
        const fear_dr_tmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_tmr_b);
        const horror_dr_t_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_t_b);
        const horror_dr_tmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_tmr_b);
        const seduction_dr_t_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_dr_t_b);
        const seduction_dr_tmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(seduction_dr_tmr_b);

        const is_act = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(is_act);

        var pool = WarlockArenaPool{
            .count = 0,
            .capacity = padded_cap,
            .allocator = allocator,
            .distance = dist,
            .impact_mask_a = impact_mask_a,
            .impact_mask_b = impact_mask_b,

            .projectile_count_a = projectile_count_a,
            .projectile_count_b = projectile_count_b,

            .projectile_0_spell_a = projectile_0_spell_a,
            .projectile_0_damage_a = projectile_0_damage_a,
            .projectile_0_x_a = projectile_0_x_a,
            .projectile_0_y_a = projectile_0_y_a,
            .projectile_1_spell_a = projectile_1_spell_a,
            .projectile_1_damage_a = projectile_1_damage_a,
            .projectile_1_x_a = projectile_1_x_a,
            .projectile_1_y_a = projectile_1_y_a,
            .projectile_2_spell_a = projectile_2_spell_a,
            .projectile_2_damage_a = projectile_2_damage_a,
            .projectile_2_x_a = projectile_2_x_a,
            .projectile_2_y_a = projectile_2_y_a,
            .projectile_3_spell_a = projectile_3_spell_a,
            .projectile_3_damage_a = projectile_3_damage_a,
            .projectile_3_x_a = projectile_3_x_a,
            .projectile_3_y_a = projectile_3_y_a,
            .projectile_0_spell_b = projectile_0_spell_b,
            .projectile_0_damage_b = projectile_0_damage_b,
            .projectile_0_x_b = projectile_0_x_b,
            .projectile_0_y_b = projectile_0_y_b,
            .projectile_1_spell_b = projectile_1_spell_b,
            .projectile_1_damage_b = projectile_1_damage_b,
            .projectile_1_x_b = projectile_1_x_b,
            .projectile_1_y_b = projectile_1_y_b,
            .projectile_2_spell_b = projectile_2_spell_b,
            .projectile_2_damage_b = projectile_2_damage_b,
            .projectile_2_x_b = projectile_2_x_b,
            .projectile_2_y_b = projectile_2_y_b,
            .projectile_3_spell_b = projectile_3_spell_b,
            .projectile_3_damage_b = projectile_3_damage_b,
            .projectile_3_x_b = projectile_3_x_b,
            .projectile_3_y_b = projectile_3_y_b,
            .impact_bolt_a = impact_bolt_a,
            .impact_lance_a = impact_lance_a,
            .impact_coil_a = impact_coil_a,
            .impact_bolt_b = impact_bolt_b,
            .impact_lance_b = impact_lance_b,
            .impact_coil_b = impact_coil_b,

            .pos_x_a = pos_x_a,
            .pos_y_a = pos_y_a,
            .pos_x_b = pos_x_b,
            .pos_y_b = pos_y_b,

            .race_a = race_a,
            .priest_pi_cd_a = priest_pi_cd_a,
            .priest_pi_timer_a = priest_pi_timer_a,
            .racial_cd_a = racial_cd_a,
            .racial_power_timer_a = racial_power_timer_a,
            .racial_haste_timer_a = racial_haste_timer_a,
            .racial_escape_timer_a = racial_escape_timer_a,
            .hp_a = hp_a,
            .mana_a = mana_a,
            .gcd_a = gcd_a,
            .react_timer_a = react_a,
            .move_intent_a = move_a,
            .cast_id_a = cid_a,
            .cast_pushback_count_a = cast_pushback_count_a,
            .cast_timer_a = ctmr_a,
            .cast_total_a = ctot_a,
            .channel_elapsed_a = channel_elapsed_a,
            .agony_timer_a = ago_a,
            .immolate_timer_a = immolate_a,
            .corruption_timer_a = crp_a,
            .siphon_timer_a = siph_a,
            .fear_timer_a = fear_a,
            .fear_accum_dmg_a = fear_dmg_a,
            .stun_timer_a = stun_timer_a,
            .stun_dr_tier_a = stun_dr_tier_a,
            .stun_dr_timer_a = stun_dr_timer_a,
            .horror_timer_a = horror_a,
            .seduction_timer_a = seduction_a,
            .action6_cd_a = un_cd_a,
            .action6_dur_a = un_dur_a,
            .death_coil_cd_a = dc_cd_a,
            .shadowburn_cd_a = shadowburn_cd_a,
            .conflagrate_cd_a = conflagrate_cd_a,
            .conflagrate_pending_a = conflagrate_pending_a,
            .daze_timer_a = daze_timer_a,
            .shadow_flame_timer_a = shadow_flame_timer_a,
            .isb_timer_a = isb_timer_a,
            .isb_charges_a = isb_charges_a,
            .isb_vuln_a = isb_vuln_a,
            .impact_conflagrate_a = impact_conflagrate_a,
            .conflagrate_rng_a = conflagrate_rng_a,
            .spell_rng_a = spell_rng_a,
            .pushback_rng_a = pushback_rng_a,
            .pet_rng_a = pet_rng_a,
            .spell_outcome_a = spell_outcome_a,
            .pet_outcome_a = pet_outcome_a,
            .spell_hit_chance_a = spell_hit_chance_a,
            .max_health_a = max_health_a,
            .max_mana_a = max_mana_a,
            .shadow_power_a = shadow_power_a,
            .fire_power_a = fire_power_a,
            .frost_power_a = frost_power_a,
            .level_a = level_a,
            .spell_penetration_a = spell_penetration_a,
            .shadow_resistance_a = shadow_resistance_a,
            .fire_resistance_a = fire_resistance_a,
            .frost_resistance_a = frost_resistance_a,
            .arcane_resistance_a = arcane_resistance_a,
            .pet_hit_chance_a = pet_hit_chance_a,
            .pet_crit_chance_a = pet_crit_chance_a,
            .melee_avoidance_chance_a = melee_avoidance_chance_a,
            .armor_damage_reduction_a = armor_damage_reduction_a,
            .spell_crit_chance_a = spell_crit_chance_a,
            .shadow_resist_chance_a = shadow_resist_chance_a,
            .fire_resist_chance_a = fire_resist_chance_a,
            .frost_resist_chance_a = frost_resist_chance_a,
            .arcane_resist_chance_a = arcane_resist_chance_a,
            .seduction_cd_a = seduction_cd_a,
            .shadow_lockout_a = shadow_lockout_a,
            .fire_lockout_a = fire_lockout_a,
            .seduction_cast_a = seduction_cast_a,
            .seduced_a = seduced_a,
            .soul_shards_a = soul_shards_a,
            .fear_dr_tier_a = fear_dr_t_a,
            .fear_dr_timer_a = fear_dr_tmr_a,
            .horror_dr_tier_a = horror_dr_t_a,
            .horror_dr_timer_a = horror_dr_tmr_a,
            .seduction_dr_tier_a = seduction_dr_t_a,
            .seduction_dr_timer_a = seduction_dr_tmr_a,

            .race_b = race_b,
            .priest_pi_cd_b = priest_pi_cd_b,
            .priest_pi_timer_b = priest_pi_timer_b,
            .racial_cd_b = racial_cd_b,
            .racial_power_timer_b = racial_power_timer_b,
            .racial_haste_timer_b = racial_haste_timer_b,
            .racial_escape_timer_b = racial_escape_timer_b,
            .hp_b = hp_b,
            .mana_b = mana_b,
            .gcd_b = gcd_b,
            .react_timer_b = react_b,
            .move_intent_b = move_b,
            .cast_id_b = cid_b,
            .cast_pushback_count_b = cast_pushback_count_b,
            .cast_timer_b = ctmr_b,
            .cast_total_b = ctot_b,
            .channel_elapsed_b = channel_elapsed_b,
            .agony_timer_b = ago_b,
            .immolate_timer_b = immolate_b,
            .corruption_timer_b = crp_b,
            .siphon_timer_b = siph_b,
            .fear_timer_b = fear_b,
            .fear_accum_dmg_b = fear_dmg_b,
            .stun_timer_b = stun_timer_b,
            .stun_dr_tier_b = stun_dr_tier_b,
            .stun_dr_timer_b = stun_dr_timer_b,
            .horror_timer_b = horror_b,
            .seduction_timer_b = seduction_b,
            .action6_cd_b = un_cd_b,
            .action6_dur_b = un_dur_b,
            .death_coil_cd_b = dc_cd_b,
            .shadowburn_cd_b = shadowburn_cd_b,
            .conflagrate_cd_b = conflagrate_cd_b,
            .conflagrate_pending_b = conflagrate_pending_b,
            .daze_timer_b = daze_timer_b,
            .shadow_flame_timer_b = shadow_flame_timer_b,
            .isb_timer_b = isb_timer_b,
            .isb_charges_b = isb_charges_b,
            .isb_vuln_b = isb_vuln_b,
            .impact_conflagrate_b = impact_conflagrate_b,
            .conflagrate_rng_b = conflagrate_rng_b,
            .spell_rng_b = spell_rng_b,
            .pushback_rng_b = pushback_rng_b,
            .pet_rng_b = pet_rng_b,
            .spell_outcome_b = spell_outcome_b,
            .pet_outcome_b = pet_outcome_b,
            .spell_hit_chance_b = spell_hit_chance_b,
            .max_health_b = max_health_b,
            .max_mana_b = max_mana_b,
            .shadow_power_b = shadow_power_b,
            .fire_power_b = fire_power_b,
            .frost_power_b = frost_power_b,
            .level_b = level_b,
            .spell_penetration_b = spell_penetration_b,
            .shadow_resistance_b = shadow_resistance_b,
            .fire_resistance_b = fire_resistance_b,
            .frost_resistance_b = frost_resistance_b,
            .arcane_resistance_b = arcane_resistance_b,
            .pet_hit_chance_b = pet_hit_chance_b,
            .pet_crit_chance_b = pet_crit_chance_b,
            .melee_avoidance_chance_b = melee_avoidance_chance_b,
            .armor_damage_reduction_b = armor_damage_reduction_b,
            .spell_crit_chance_b = spell_crit_chance_b,
            .shadow_resist_chance_b = shadow_resist_chance_b,
            .fire_resist_chance_b = fire_resist_chance_b,
            .frost_resist_chance_b = frost_resist_chance_b,
            .arcane_resist_chance_b = arcane_resist_chance_b,
            .seduction_cd_b = seduction_cd_b,
            .shadow_lockout_b = shadow_lockout_b,
            .fire_lockout_b = fire_lockout_b,
            .seduction_cast_b = seduction_cast_b,
            .seduced_b = seduced_b,
            .soul_shards_b = soul_shards_b,
            .fear_dr_tier_b = fear_dr_t_b,
            .fear_dr_timer_b = fear_dr_tmr_b,
            .horror_dr_tier_b = horror_dr_t_b,
            .horror_dr_timer_b = horror_dr_tmr_b,
            .seduction_dr_tier_b = seduction_dr_t_b,
            .seduction_dr_timer_b = seduction_dr_tmr_b,
            .pet_kind_a = pet_kind_a,
            .pet_hp_a = pet_hp_a,
            .pet_timer_a = pet_timer_a,
            .pet_x_a = pet_x_a,
            .pet_y_a = pet_y_a,
            .impact_pet_a = impact_pet_a,
            .soul_link_a = soul_link_a,
            .talent_ranks_a = talent_ranks_a,
            .talent_flags_a = talent_flags_a,
            .talent_extra_a = talent_extra_a,
            .pet_kind_b = pet_kind_b,
            .pet_hp_b = pet_hp_b,
            .pet_timer_b = pet_timer_b,
            .pet_x_b = pet_x_b,
            .pet_y_b = pet_y_b,
            .impact_pet_b = impact_pet_b,
            .soul_link_b = soul_link_b,
            .talent_ranks_b = talent_ranks_b,
            .talent_flags_b = talent_flags_b,
            .talent_extra_b = talent_extra_b,
            .is_active = is_act,
        };

        pool.resetAll();
        return pool;
    }

    pub fn deinit(self: *WarlockArenaPool) void {
        self.allocator.free(self.pet_kind_a);
        self.allocator.free(self.pet_hp_a);
        self.allocator.free(self.pet_timer_a);
        self.allocator.free(self.pet_x_a);
        self.allocator.free(self.pet_y_a);
        self.allocator.free(self.impact_pet_a);
        self.allocator.free(self.soul_link_a);
        self.allocator.free(self.talent_ranks_a);
        self.allocator.free(self.talent_flags_a);
        self.allocator.free(self.talent_extra_a);
        self.allocator.free(self.pet_kind_b);
        self.allocator.free(self.pet_hp_b);
        self.allocator.free(self.pet_timer_b);
        self.allocator.free(self.pet_x_b);
        self.allocator.free(self.pet_y_b);
        self.allocator.free(self.impact_pet_b);
        self.allocator.free(self.soul_link_b);
        self.allocator.free(self.talent_ranks_b);
        self.allocator.free(self.talent_flags_b);
        self.allocator.free(self.talent_extra_b);

        self.allocator.free(self.distance);
        self.allocator.free(self.impact_mask_a);
        self.allocator.free(self.impact_mask_b);

        self.allocator.free(self.projectile_count_a);
        self.allocator.free(self.projectile_count_b);

        self.allocator.free(self.projectile_0_spell_a);
        self.allocator.free(self.projectile_0_damage_a);
        self.allocator.free(self.projectile_0_x_a);
        self.allocator.free(self.projectile_0_y_a);
        self.allocator.free(self.projectile_1_spell_a);
        self.allocator.free(self.projectile_1_damage_a);
        self.allocator.free(self.projectile_1_x_a);
        self.allocator.free(self.projectile_1_y_a);
        self.allocator.free(self.projectile_2_spell_a);
        self.allocator.free(self.projectile_2_damage_a);
        self.allocator.free(self.projectile_2_x_a);
        self.allocator.free(self.projectile_2_y_a);
        self.allocator.free(self.projectile_3_spell_a);
        self.allocator.free(self.projectile_3_damage_a);
        self.allocator.free(self.projectile_3_x_a);
        self.allocator.free(self.projectile_3_y_a);
        self.allocator.free(self.projectile_0_spell_b);
        self.allocator.free(self.projectile_0_damage_b);
        self.allocator.free(self.projectile_0_x_b);
        self.allocator.free(self.projectile_0_y_b);
        self.allocator.free(self.projectile_1_spell_b);
        self.allocator.free(self.projectile_1_damage_b);
        self.allocator.free(self.projectile_1_x_b);
        self.allocator.free(self.projectile_1_y_b);
        self.allocator.free(self.projectile_2_spell_b);
        self.allocator.free(self.projectile_2_damage_b);
        self.allocator.free(self.projectile_2_x_b);
        self.allocator.free(self.projectile_2_y_b);
        self.allocator.free(self.projectile_3_spell_b);
        self.allocator.free(self.projectile_3_damage_b);
        self.allocator.free(self.projectile_3_x_b);
        self.allocator.free(self.projectile_3_y_b);
        self.allocator.free(self.impact_bolt_a);
        self.allocator.free(self.impact_lance_a);
        self.allocator.free(self.impact_coil_a);
        self.allocator.free(self.impact_bolt_b);
        self.allocator.free(self.impact_lance_b);
        self.allocator.free(self.impact_coil_b);

        self.allocator.free(self.pos_x_a);
        self.allocator.free(self.pos_y_a);
        self.allocator.free(self.pos_x_b);
        self.allocator.free(self.pos_y_b);

        self.allocator.free(self.race_a);
        self.allocator.free(self.priest_pi_cd_a);
        self.allocator.free(self.priest_pi_timer_a);
        self.allocator.free(self.racial_cd_a);
        self.allocator.free(self.racial_power_timer_a);
        self.allocator.free(self.racial_haste_timer_a);
        self.allocator.free(self.racial_escape_timer_a);
        self.allocator.free(self.hp_a);
        self.allocator.free(self.mana_a);
        self.allocator.free(self.gcd_a);
        self.allocator.free(self.react_timer_a);
        self.allocator.free(self.move_intent_a);
        self.allocator.free(self.cast_id_a);
        self.allocator.free(self.cast_pushback_count_a);
        self.allocator.free(self.cast_timer_a);
        self.allocator.free(self.cast_total_a);
        self.allocator.free(self.channel_elapsed_a);
        self.allocator.free(self.agony_timer_a);
        self.allocator.free(self.immolate_timer_a);
        self.allocator.free(self.corruption_timer_a);
        self.allocator.free(self.siphon_timer_a);
        self.allocator.free(self.fear_timer_a);
        self.allocator.free(self.fear_accum_dmg_a);
        self.allocator.free(self.stun_timer_a);
        self.allocator.free(self.stun_dr_tier_a);
        self.allocator.free(self.stun_dr_timer_a);
        self.allocator.free(self.horror_timer_a);
        self.allocator.free(self.seduction_timer_a);
        self.allocator.free(self.action6_cd_a);
        self.allocator.free(self.action6_dur_a);
        self.allocator.free(self.death_coil_cd_a);
        self.allocator.free(self.shadowburn_cd_a);
        self.allocator.free(self.conflagrate_cd_a);
        self.allocator.free(self.conflagrate_pending_a);
        self.allocator.free(self.daze_timer_a);
        self.allocator.free(self.shadow_flame_timer_a);
        self.allocator.free(self.isb_timer_a);
        self.allocator.free(self.isb_charges_a);
        self.allocator.free(self.isb_vuln_a);
        self.allocator.free(self.impact_conflagrate_a);
        self.allocator.free(self.conflagrate_rng_a);
        self.allocator.free(self.spell_rng_a);
        self.allocator.free(self.pushback_rng_a);
        self.allocator.free(self.pet_rng_a);
        self.allocator.free(self.spell_outcome_a);
        self.allocator.free(self.pet_outcome_a);
        self.allocator.free(self.spell_hit_chance_a);
        self.allocator.free(self.max_health_a);
        self.allocator.free(self.max_mana_a);
        self.allocator.free(self.shadow_power_a);
        self.allocator.free(self.fire_power_a);
        self.allocator.free(self.frost_power_a);
        self.allocator.free(self.level_a);
        self.allocator.free(self.spell_penetration_a);
        self.allocator.free(self.shadow_resistance_a);
        self.allocator.free(self.fire_resistance_a);
        self.allocator.free(self.frost_resistance_a);
        self.allocator.free(self.arcane_resistance_a);
        self.allocator.free(self.pet_hit_chance_a);
        self.allocator.free(self.pet_crit_chance_a);
        self.allocator.free(self.melee_avoidance_chance_a);
        self.allocator.free(self.armor_damage_reduction_a);
        self.allocator.free(self.spell_crit_chance_a);
        self.allocator.free(self.shadow_resist_chance_a);
        self.allocator.free(self.fire_resist_chance_a);
        self.allocator.free(self.frost_resist_chance_a);
        self.allocator.free(self.arcane_resist_chance_a);
        self.allocator.free(self.seduction_cd_a);
        self.allocator.free(self.shadow_lockout_a);
        self.allocator.free(self.fire_lockout_a);
        self.allocator.free(self.seduction_cast_a);
        self.allocator.free(self.seduced_a);
        self.allocator.free(self.soul_shards_a);
        self.allocator.free(self.fear_dr_tier_a);
        self.allocator.free(self.fear_dr_timer_a);
        self.allocator.free(self.horror_dr_tier_a);
        self.allocator.free(self.horror_dr_timer_a);
        self.allocator.free(self.seduction_dr_tier_a);
        self.allocator.free(self.seduction_dr_timer_a);

        self.allocator.free(self.race_b);
        self.allocator.free(self.priest_pi_cd_b);
        self.allocator.free(self.priest_pi_timer_b);
        self.allocator.free(self.racial_cd_b);
        self.allocator.free(self.racial_power_timer_b);
        self.allocator.free(self.racial_haste_timer_b);
        self.allocator.free(self.racial_escape_timer_b);
        self.allocator.free(self.hp_b);
        self.allocator.free(self.mana_b);
        self.allocator.free(self.gcd_b);
        self.allocator.free(self.react_timer_b);
        self.allocator.free(self.move_intent_b);
        self.allocator.free(self.cast_id_b);
        self.allocator.free(self.cast_pushback_count_b);
        self.allocator.free(self.cast_timer_b);
        self.allocator.free(self.cast_total_b);
        self.allocator.free(self.channel_elapsed_b);
        self.allocator.free(self.agony_timer_b);
        self.allocator.free(self.immolate_timer_b);
        self.allocator.free(self.corruption_timer_b);
        self.allocator.free(self.siphon_timer_b);
        self.allocator.free(self.fear_timer_b);
        self.allocator.free(self.fear_accum_dmg_b);
        self.allocator.free(self.stun_timer_b);
        self.allocator.free(self.stun_dr_tier_b);
        self.allocator.free(self.stun_dr_timer_b);
        self.allocator.free(self.horror_timer_b);
        self.allocator.free(self.seduction_timer_b);
        self.allocator.free(self.action6_cd_b);
        self.allocator.free(self.action6_dur_b);
        self.allocator.free(self.death_coil_cd_b);
        self.allocator.free(self.shadowburn_cd_b);
        self.allocator.free(self.conflagrate_cd_b);
        self.allocator.free(self.conflagrate_pending_b);
        self.allocator.free(self.daze_timer_b);
        self.allocator.free(self.shadow_flame_timer_b);
        self.allocator.free(self.isb_timer_b);
        self.allocator.free(self.isb_charges_b);
        self.allocator.free(self.isb_vuln_b);
        self.allocator.free(self.impact_conflagrate_b);
        self.allocator.free(self.conflagrate_rng_b);
        self.allocator.free(self.spell_rng_b);
        self.allocator.free(self.pushback_rng_b);
        self.allocator.free(self.pet_rng_b);
        self.allocator.free(self.spell_outcome_b);
        self.allocator.free(self.pet_outcome_b);
        self.allocator.free(self.spell_hit_chance_b);
        self.allocator.free(self.max_health_b);
        self.allocator.free(self.max_mana_b);
        self.allocator.free(self.shadow_power_b);
        self.allocator.free(self.fire_power_b);
        self.allocator.free(self.frost_power_b);
        self.allocator.free(self.level_b);
        self.allocator.free(self.spell_penetration_b);
        self.allocator.free(self.shadow_resistance_b);
        self.allocator.free(self.fire_resistance_b);
        self.allocator.free(self.frost_resistance_b);
        self.allocator.free(self.arcane_resistance_b);
        self.allocator.free(self.pet_hit_chance_b);
        self.allocator.free(self.pet_crit_chance_b);
        self.allocator.free(self.melee_avoidance_chance_b);
        self.allocator.free(self.armor_damage_reduction_b);
        self.allocator.free(self.spell_crit_chance_b);
        self.allocator.free(self.shadow_resist_chance_b);
        self.allocator.free(self.fire_resist_chance_b);
        self.allocator.free(self.frost_resist_chance_b);
        self.allocator.free(self.arcane_resist_chance_b);
        self.allocator.free(self.seduction_cd_b);
        self.allocator.free(self.shadow_lockout_b);
        self.allocator.free(self.fire_lockout_b);
        self.allocator.free(self.seduction_cast_b);
        self.allocator.free(self.seduced_b);
        self.allocator.free(self.soul_shards_b);
        self.allocator.free(self.fear_dr_tier_b);
        self.allocator.free(self.fear_dr_timer_b);
        self.allocator.free(self.horror_dr_tier_b);
        self.allocator.free(self.horror_dr_timer_b);
        self.allocator.free(self.seduction_dr_tier_b);
        self.allocator.free(self.seduction_dr_timer_b);
        self.allocator.free(self.is_active);
    }

    pub fn resetAll(self: *WarlockArenaPool) void {
        @memset(self.pet_kind_a, 0);
        @memset(self.pet_hp_a, 0);
        @memset(self.pet_timer_a, 0);
        @memset(self.pet_x_a, 0);
        @memset(self.pet_y_a, 0);
        @memset(self.impact_pet_a, 0);
        @memset(self.soul_link_a, 0);
        @memset(self.talent_ranks_a, 0);
        @memset(self.talent_flags_a, 0);
        @memset(self.talent_extra_a, 0);
        @memset(self.pet_kind_b, 0);
        @memset(self.pet_hp_b, 0);
        @memset(self.pet_timer_b, 0);
        @memset(self.pet_x_b, 0);
        @memset(self.pet_y_b, 0);
        @memset(self.impact_pet_b, 0);
        @memset(self.soul_link_b, 0);
        @memset(self.talent_ranks_b, 0);
        @memset(self.talent_flags_b, 0);
        @memset(self.talent_extra_b, 0);

        @memset(self.pos_x_a, -12.5);
        @memset(self.pos_y_a, 0);
        @memset(self.pos_x_b, 12.5);
        @memset(self.pos_y_b, 0);
        @memset(self.projectile_0_spell_a, 0);
        @memset(self.projectile_0_damage_a, 0);
        @memset(self.projectile_0_x_a, 0);
        @memset(self.projectile_0_y_a, 0);
        @memset(self.projectile_1_spell_a, 0);
        @memset(self.projectile_1_damage_a, 0);
        @memset(self.projectile_1_x_a, 0);
        @memset(self.projectile_1_y_a, 0);
        @memset(self.projectile_2_spell_a, 0);
        @memset(self.projectile_2_damage_a, 0);
        @memset(self.projectile_2_x_a, 0);
        @memset(self.projectile_2_y_a, 0);
        @memset(self.projectile_3_spell_a, 0);
        @memset(self.projectile_3_damage_a, 0);
        @memset(self.projectile_3_x_a, 0);
        @memset(self.projectile_3_y_a, 0);
        @memset(self.projectile_0_spell_b, 0);
        @memset(self.projectile_0_damage_b, 0);
        @memset(self.projectile_0_x_b, 0);
        @memset(self.projectile_0_y_b, 0);
        @memset(self.projectile_1_spell_b, 0);
        @memset(self.projectile_1_damage_b, 0);
        @memset(self.projectile_1_x_b, 0);
        @memset(self.projectile_1_y_b, 0);
        @memset(self.projectile_2_spell_b, 0);
        @memset(self.projectile_2_damage_b, 0);
        @memset(self.projectile_2_x_b, 0);
        @memset(self.projectile_2_y_b, 0);
        @memset(self.projectile_3_spell_b, 0);
        @memset(self.projectile_3_damage_b, 0);
        @memset(self.projectile_3_x_b, 0);
        @memset(self.projectile_3_y_b, 0);
        @memset(self.impact_bolt_a, 0);
        @memset(self.impact_lance_a, 0);
        @memset(self.impact_coil_a, 0);
        @memset(self.impact_bolt_b, 0);
        @memset(self.impact_lance_b, 0);
        @memset(self.impact_coil_b, 0);
        @memset(self.projectile_count_a, 0);
        @memset(self.projectile_count_b, 0);
        @memset(self.impact_mask_a, 0);
        @memset(self.impact_mask_b, 0);
        @memset(self.distance, 25.0); // start 25m apart

        @memset(self.race_a, 0);
        @memset(self.priest_pi_cd_a, 0);
        @memset(self.priest_pi_timer_a, 0);
        @memset(self.racial_cd_a, 0);
        @memset(self.racial_power_timer_a, 0);
        @memset(self.racial_haste_timer_a, 0);
        @memset(self.racial_escape_timer_a, 0);
        @memset(self.hp_a, WarlockConstants.MaxHp);
        @memset(self.mana_a, WarlockConstants.MaxMana);
        @memset(self.gcd_a, 0.0);
        @memset(self.react_timer_a, 0.0);
        @memset(self.move_intent_a, 0.0);
        @memset(self.cast_id_a, 0);
        @memset(self.cast_pushback_count_a, 0);
        @memset(self.cast_timer_a, 0.0);
        @memset(self.cast_total_a, 0.0);
        @memset(self.channel_elapsed_a, 0.0);
        @memset(self.agony_timer_a, 0.0);
        @memset(self.immolate_timer_a, 0.0);
        @memset(self.corruption_timer_a, 0.0);
        @memset(self.siphon_timer_a, 0.0);
        @memset(self.fear_timer_a, 0.0);
        @memset(self.fear_accum_dmg_a, 0.0);
        @memset(self.stun_timer_a, 0.0);
        @memset(self.stun_dr_tier_a, 0.0);
        @memset(self.stun_dr_timer_a, 0.0);
        @memset(self.horror_timer_a, 0.0);
        @memset(self.seduction_timer_a, 0.0);
        @memset(self.action6_cd_a, 0.0);
        @memset(self.action6_dur_a, 0.0);
        @memset(self.death_coil_cd_a, 0.0);
        @memset(self.shadowburn_cd_a, 0.0);
        @memset(self.conflagrate_cd_a, 0.0);
        @memset(self.conflagrate_pending_a, 0.0);
        @memset(self.daze_timer_a, 0.0);
        @memset(self.shadow_flame_timer_a, 0.0);
        @memset(self.isb_timer_a, 0.0);
        @memset(self.isb_charges_a, 0.0);
        @memset(self.isb_vuln_a, 0.0);
        @memset(self.impact_conflagrate_a, 0.0);
        @memset(self.conflagrate_rng_a, 0x12345678);
        @memset(self.spell_rng_a, 0x6d2b79f5);
        @memset(self.pushback_rng_a, 0x6d2b79f5);
        @memset(self.pet_rng_a, 0x6d2b79f5);
        @memset(self.spell_outcome_a, 0);
        @memset(self.pet_outcome_a, 0);
        @memset(self.spell_hit_chance_a, 1);
        @memset(self.max_health_a, 2000);
        @memset(self.max_mana_a, 1000);
        @memset(self.shadow_power_a, 0);
        @memset(self.fire_power_a, 0);
        @memset(self.frost_power_a, 0);
        @memset(self.level_a, 60);
        @memset(self.spell_penetration_a, 0);
        @memset(self.shadow_resistance_a, 0);
        @memset(self.fire_resistance_a, 0);
        @memset(self.frost_resistance_a, 0);
        @memset(self.arcane_resistance_a, 0);
        @memset(self.pet_hit_chance_a, 1);
        @memset(self.pet_crit_chance_a, 0);
        @memset(self.melee_avoidance_chance_a, 0);
        @memset(self.armor_damage_reduction_a, 0);
        @memset(self.spell_crit_chance_a, 0);
        @memset(self.shadow_resist_chance_a, 0);
        @memset(self.fire_resist_chance_a, 0);
        @memset(self.frost_resist_chance_a, 0);
        @memset(self.arcane_resist_chance_a, 0);
        @memset(self.seduction_cd_a, 0.0);
        @memset(self.shadow_lockout_a, 0.0);
        @memset(self.fire_lockout_a, 0.0);
        @memset(self.seduction_cast_a, 0.0);
        @memset(self.seduced_a, 0);
        @memset(self.soul_shards_a, 1.0);
        @memset(self.fear_dr_tier_a, 0.0);
        @memset(self.fear_dr_timer_a, 0.0);
        @memset(self.horror_dr_tier_a, 0.0);
        @memset(self.horror_dr_timer_a, 0.0);
        @memset(self.seduction_dr_tier_a, 0.0);
        @memset(self.seduction_dr_timer_a, 0.0);

        @memset(self.race_b, 0);
        @memset(self.priest_pi_cd_b, 0);
        @memset(self.priest_pi_timer_b, 0);
        @memset(self.racial_cd_b, 0);
        @memset(self.racial_power_timer_b, 0);
        @memset(self.racial_haste_timer_b, 0);
        @memset(self.racial_escape_timer_b, 0);
        @memset(self.hp_b, WarlockConstants.MaxHp);
        @memset(self.mana_b, WarlockConstants.MaxMana);
        @memset(self.gcd_b, 0.0);
        @memset(self.react_timer_b, 0.0);
        @memset(self.move_intent_b, 0.0);
        @memset(self.cast_id_b, 0);
        @memset(self.cast_pushback_count_b, 0);
        @memset(self.cast_timer_b, 0.0);
        @memset(self.cast_total_b, 0.0);
        @memset(self.channel_elapsed_b, 0.0);
        @memset(self.agony_timer_b, 0.0);
        @memset(self.immolate_timer_b, 0.0);
        @memset(self.corruption_timer_b, 0.0);
        @memset(self.siphon_timer_b, 0.0);
        @memset(self.fear_timer_b, 0.0);
        @memset(self.fear_accum_dmg_b, 0.0);
        @memset(self.stun_timer_b, 0.0);
        @memset(self.stun_dr_tier_b, 0.0);
        @memset(self.stun_dr_timer_b, 0.0);
        @memset(self.horror_timer_b, 0.0);
        @memset(self.seduction_timer_b, 0.0);
        @memset(self.action6_cd_b, 0.0);
        @memset(self.action6_dur_b, 0.0);
        @memset(self.death_coil_cd_b, 0.0);
        @memset(self.shadowburn_cd_b, 0.0);
        @memset(self.conflagrate_cd_b, 0.0);
        @memset(self.conflagrate_pending_b, 0.0);
        @memset(self.daze_timer_b, 0.0);
        @memset(self.shadow_flame_timer_b, 0.0);
        @memset(self.isb_timer_b, 0.0);
        @memset(self.isb_charges_b, 0.0);
        @memset(self.isb_vuln_b, 0.0);
        @memset(self.impact_conflagrate_b, 0.0);
        @memset(self.conflagrate_rng_b, 0x12345678);
        @memset(self.spell_rng_b, 0xa341316c);
        @memset(self.pushback_rng_b, 0xa341316c);
        @memset(self.pet_rng_b, 0xa341316c);
        @memset(self.spell_outcome_b, 0);
        @memset(self.pet_outcome_b, 0);
        @memset(self.spell_hit_chance_b, 1);
        @memset(self.max_health_b, 2000);
        @memset(self.max_mana_b, 1000);
        @memset(self.shadow_power_b, 0);
        @memset(self.fire_power_b, 0);
        @memset(self.frost_power_b, 0);
        @memset(self.level_b, 60);
        @memset(self.spell_penetration_b, 0);
        @memset(self.shadow_resistance_b, 0);
        @memset(self.fire_resistance_b, 0);
        @memset(self.frost_resistance_b, 0);
        @memset(self.arcane_resistance_b, 0);
        @memset(self.pet_hit_chance_b, 1);
        @memset(self.pet_crit_chance_b, 0);
        @memset(self.melee_avoidance_chance_b, 0);
        @memset(self.armor_damage_reduction_b, 0);
        @memset(self.spell_crit_chance_b, 0);
        @memset(self.shadow_resist_chance_b, 0);
        @memset(self.fire_resist_chance_b, 0);
        @memset(self.frost_resist_chance_b, 0);
        @memset(self.arcane_resist_chance_b, 0);
        @memset(self.seduction_cd_b, 0.0);
        @memset(self.shadow_lockout_b, 0.0);
        @memset(self.fire_lockout_b, 0.0);
        @memset(self.seduction_cast_b, 0.0);
        @memset(self.seduced_b, 0);
        @memset(self.soul_shards_b, 1.0);
        @memset(self.fear_dr_tier_b, 0.0);
        @memset(self.fear_dr_timer_b, 0.0);
        @memset(self.horror_dr_tier_b, 0.0);
        @memset(self.horror_dr_timer_b, 0.0);
        @memset(self.seduction_dr_tier_b, 0.0);
        @memset(self.seduction_dr_timer_b, 0.0);

        @memset(self.is_active, 1);
    }

    pub fn combat(self: *WarlockArenaPool) *WarlockArenaPool {
        return self;
    }

    pub fn resetDuel(self: *WarlockArenaPool, i: usize) void {
        @import("pets.zig").set(self, true, i, .none);
        @import("pets.zig").set(self, false, i, .none);
        self.soul_link_a[i] = 0;
        self.soul_link_b[i] = 0;
        self.talent_ranks_a[i] = 0;
        self.talent_ranks_b[i] = 0;
        self.talent_flags_a[i] = 0;
        self.talent_extra_a[i] = 0;
        self.talent_flags_b[i] = 0;
        self.talent_extra_b[i] = 0;
        self.pos_x_a[i] = -12.5;
        self.pos_y_a[i] = 0;
        self.pos_x_b[i] = 12.5;
        self.pos_y_b[i] = 0;
        self.projectile_0_spell_a[i] = 0;
        self.projectile_0_damage_a[i] = 0;
        self.projectile_0_x_a[i] = 0;
        self.projectile_0_y_a[i] = 0;
        self.projectile_1_spell_a[i] = 0;
        self.projectile_1_damage_a[i] = 0;
        self.projectile_1_x_a[i] = 0;
        self.projectile_1_y_a[i] = 0;
        self.projectile_2_spell_a[i] = 0;
        self.projectile_2_damage_a[i] = 0;
        self.projectile_2_x_a[i] = 0;
        self.projectile_2_y_a[i] = 0;
        self.projectile_3_spell_a[i] = 0;
        self.projectile_3_damage_a[i] = 0;
        self.projectile_3_x_a[i] = 0;
        self.projectile_3_y_a[i] = 0;
        self.projectile_0_spell_b[i] = 0;
        self.projectile_0_damage_b[i] = 0;
        self.projectile_0_x_b[i] = 0;
        self.projectile_0_y_b[i] = 0;
        self.projectile_1_spell_b[i] = 0;
        self.projectile_1_damage_b[i] = 0;
        self.projectile_1_x_b[i] = 0;
        self.projectile_1_y_b[i] = 0;
        self.projectile_2_spell_b[i] = 0;
        self.projectile_2_damage_b[i] = 0;
        self.projectile_2_x_b[i] = 0;
        self.projectile_2_y_b[i] = 0;
        self.projectile_3_spell_b[i] = 0;
        self.projectile_3_damage_b[i] = 0;
        self.projectile_3_x_b[i] = 0;
        self.projectile_3_y_b[i] = 0;
        self.impact_bolt_a[i] = 0;
        self.impact_lance_a[i] = 0;
        self.impact_coil_a[i] = 0;
        self.impact_bolt_b[i] = 0;
        self.impact_lance_b[i] = 0;
        self.impact_coil_b[i] = 0;
        self.projectile_count_a[i] = 0;
        self.projectile_count_b[i] = 0;
        self.impact_mask_a[i] = 0;
        self.impact_mask_b[i] = 0;
        self.distance[i] = 25.0;
        self.race_a[i] = 0;
        self.priest_pi_cd_a[i] = 0;
        self.priest_pi_timer_a[i] = 0;
        self.racial_cd_a[i] = 0;
        self.racial_power_timer_a[i] = 0;
        self.racial_haste_timer_a[i] = 0;
        self.racial_escape_timer_a[i] = 0;
        self.hp_a[i] = WarlockConstants.MaxHp;
        self.mana_a[i] = WarlockConstants.MaxMana;
        self.gcd_a[i] = 0.0;
        self.react_timer_a[i] = 0.0;
        self.move_intent_a[i] = 0.0;
        self.cast_id_a[i] = 0;
        self.cast_pushback_count_a[i] = 0;
        self.cast_timer_a[i] = 0.0;
        self.cast_total_a[i] = 0.0;
        self.channel_elapsed_a[i] = 0.0;
        self.agony_timer_a[i] = 0.0;
        self.immolate_timer_a[i] = 0.0;
        self.corruption_timer_a[i] = 0.0;
        self.siphon_timer_a[i] = 0.0;
        self.fear_timer_a[i] = 0.0;
        self.fear_accum_dmg_a[i] = 0.0;
        self.stun_timer_a[i] = 0.0;
        self.stun_dr_tier_a[i] = 0.0;
        self.stun_dr_timer_a[i] = 0.0;
        self.horror_timer_a[i] = 0.0;
        self.seduction_timer_a[i] = 0.0;
        self.action6_cd_a[i] = 0.0;
        self.action6_dur_a[i] = 0.0;
        self.death_coil_cd_a[i] = 0.0;
        self.shadowburn_cd_a[i] = 0.0;
        self.conflagrate_cd_a[i] = 0.0;
        self.conflagrate_pending_a[i] = 0.0;
        self.daze_timer_a[i] = 0.0;
        self.shadow_flame_timer_a[i] = 0.0;
        self.isb_timer_a[i] = 0.0;
        self.isb_charges_a[i] = 0.0;
        self.isb_vuln_a[i] = 0.0;
        self.impact_conflagrate_a[i] = 0.0;
        self.conflagrate_rng_a[i] = 0x12345678;
        self.spell_rng_a[i] = 0x6d2b79f5;
        self.pushback_rng_a[i] = 0x6d2b79f5;
        self.pet_rng_a[i] = 0x6d2b79f5;
        self.spell_outcome_a[i] = 0;
        self.pet_outcome_a[i] = 0;
        self.spell_hit_chance_a[i] = 1;
        self.max_health_a[i] = 2000;
        self.max_mana_a[i] = 1000;
        self.shadow_power_a[i] = 0;
        self.fire_power_a[i] = 0;
        self.frost_power_a[i] = 0;
        self.level_a[i] = 60;
        self.spell_penetration_a[i] = 0;
        self.shadow_resistance_a[i] = 0;
        self.fire_resistance_a[i] = 0;
        self.frost_resistance_a[i] = 0;
        self.arcane_resistance_a[i] = 0;
        self.pet_hit_chance_a[i] = 1;
        self.pet_crit_chance_a[i] = 0;
        self.melee_avoidance_chance_a[i] = 0;
        self.armor_damage_reduction_a[i] = 0;
        self.spell_crit_chance_a[i] = 0;
        self.shadow_resist_chance_a[i] = 0;
        self.fire_resist_chance_a[i] = 0;
        self.frost_resist_chance_a[i] = 0;
        self.arcane_resist_chance_a[i] = 0;
        self.seduction_cd_a[i] = 0.0;
        self.shadow_lockout_a[i] = 0.0;
        self.fire_lockout_a[i] = 0.0;
        self.seduction_cast_a[i] = 0.0;
        self.seduced_a[i] = 0;
        self.soul_shards_a[i] = 1.0;
        self.fear_dr_tier_a[i] = 0.0;
        self.fear_dr_timer_a[i] = 0.0;
        self.horror_dr_tier_a[i] = 0.0;
        self.horror_dr_timer_a[i] = 0.0;
        self.seduction_dr_tier_a[i] = 0.0;
        self.seduction_dr_timer_a[i] = 0.0;

        self.race_b[i] = 0;
        self.priest_pi_cd_b[i] = 0;
        self.priest_pi_timer_b[i] = 0;
        self.racial_cd_b[i] = 0;
        self.racial_power_timer_b[i] = 0;
        self.racial_haste_timer_b[i] = 0;
        self.racial_escape_timer_b[i] = 0;
        self.hp_b[i] = WarlockConstants.MaxHp;
        self.mana_b[i] = WarlockConstants.MaxMana;
        self.gcd_b[i] = 0.0;
        self.react_timer_b[i] = 0.0;
        self.move_intent_b[i] = 0.0;
        self.cast_id_b[i] = 0;
        self.cast_pushback_count_b[i] = 0;
        self.cast_timer_b[i] = 0.0;
        self.cast_total_b[i] = 0.0;
        self.channel_elapsed_b[i] = 0.0;
        self.agony_timer_b[i] = 0.0;
        self.immolate_timer_b[i] = 0.0;
        self.corruption_timer_b[i] = 0.0;
        self.siphon_timer_b[i] = 0.0;
        self.fear_timer_b[i] = 0.0;
        self.fear_accum_dmg_b[i] = 0.0;
        self.stun_timer_b[i] = 0.0;
        self.stun_dr_tier_b[i] = 0.0;
        self.stun_dr_timer_b[i] = 0.0;
        self.horror_timer_b[i] = 0.0;
        self.seduction_timer_b[i] = 0.0;
        self.action6_cd_b[i] = 0.0;
        self.action6_dur_b[i] = 0.0;
        self.death_coil_cd_b[i] = 0.0;
        self.shadowburn_cd_b[i] = 0.0;
        self.conflagrate_cd_b[i] = 0.0;
        self.conflagrate_pending_b[i] = 0.0;
        self.daze_timer_b[i] = 0.0;
        self.shadow_flame_timer_b[i] = 0.0;
        self.isb_timer_b[i] = 0.0;
        self.isb_charges_b[i] = 0.0;
        self.isb_vuln_b[i] = 0.0;
        self.impact_conflagrate_b[i] = 0.0;
        self.conflagrate_rng_b[i] = 0x12345678;
        self.spell_rng_b[i] = 0xa341316c;
        self.pushback_rng_b[i] = 0xa341316c;
        self.pet_rng_b[i] = 0xa341316c;
        self.spell_outcome_b[i] = 0;
        self.pet_outcome_b[i] = 0;
        self.spell_hit_chance_b[i] = 1;
        self.max_health_b[i] = 2000;
        self.max_mana_b[i] = 1000;
        self.shadow_power_b[i] = 0;
        self.fire_power_b[i] = 0;
        self.frost_power_b[i] = 0;
        self.level_b[i] = 60;
        self.spell_penetration_b[i] = 0;
        self.shadow_resistance_b[i] = 0;
        self.fire_resistance_b[i] = 0;
        self.frost_resistance_b[i] = 0;
        self.arcane_resistance_b[i] = 0;
        self.pet_hit_chance_b[i] = 1;
        self.pet_crit_chance_b[i] = 0;
        self.melee_avoidance_chance_b[i] = 0;
        self.armor_damage_reduction_b[i] = 0;
        self.spell_crit_chance_b[i] = 0;
        self.shadow_resist_chance_b[i] = 0;
        self.fire_resist_chance_b[i] = 0;
        self.frost_resist_chance_b[i] = 0;
        self.arcane_resist_chance_b[i] = 0;
        self.seduction_cd_b[i] = 0.0;
        self.shadow_lockout_b[i] = 0.0;
        self.fire_lockout_b[i] = 0.0;
        self.seduction_cast_b[i] = 0.0;
        self.seduced_b[i] = 0;
        self.soul_shards_b[i] = 1.0;
        self.fear_dr_tier_b[i] = 0.0;
        self.fear_dr_timer_b[i] = 0.0;
        self.horror_dr_tier_b[i] = 0.0;
        self.horror_dr_timer_b[i] = 0.0;
        self.seduction_dr_tier_b[i] = 0.0;
        self.seduction_dr_timer_b[i] = 0.0;

        self.is_active[i] = 1;
    }

    /// Extract 24 normalized observation features across 16 lanes for Unit A
    pub fn getObservationsA(self: *const WarlockArenaPool, i: usize) [24]f32x16 {
        const v_zeros: f32x16 = @splat(0.0);
        const v_ones: f32x16 = @splat(1.0);
        const inv_hp: f32x16 = @splat(1.0 / WarlockConstants.MaxHp);
        const inv_mana: f32x16 = @splat(1.0 / WarlockConstants.MaxMana);
        const inv_dist: f32x16 = @splat(1.0 / WarlockConstants.MaxDistance);
        const inv_agony: f32x16 = @splat(1.0 / WarlockConstants.AgonyDuration);
        const inv_corr: f32x16 = @splat(1.0 / WarlockConstants.CorruptionDuration);
        const inv_def_cd: f32x16 = @splat(1.0 / WarlockConstants.HealthstoneCooldown);
        const inv_dc_cd: f32x16 = @splat(1.0 / WarlockConstants.DeathCoilCooldown);

        const hp_a: f32x16 = self.hp_a[i..][0..VEC_LEN].*;
        const hp_b: f32x16 = self.hp_b[i..][0..VEC_LEN].*;
        const mana_a: f32x16 = self.mana_a[i..][0..VEC_LEN].*;
        const mana_b: f32x16 = self.mana_b[i..][0..VEC_LEN].*;
        const dist: f32x16 = self.distance[i..][0..VEC_LEN].*;
        const gcd_a: f32x16 = self.gcd_a[i..][0..VEC_LEN].*;
        const c_id_a: u32x16 = self.cast_id_a[i..][0..VEC_LEN].*;
        const c_tmr_a: f32x16 = self.cast_timer_a[i..][0..VEC_LEN].*;
        const c_tot_a: f32x16 = self.cast_total_a[i..][0..VEC_LEN].*;

        const c_id_b: u32x16 = self.cast_id_b[i..][0..VEC_LEN].*;
        const c_tmr_b: f32x16 = self.cast_timer_b[i..][0..VEC_LEN].*;
        const c_tot_b: f32x16 = self.cast_total_b[i..][0..VEC_LEN].*;

        const ago_b: f32x16 = self.agony_timer_b[i..][0..VEC_LEN].*; // DOT on enemy
        const crp_b: f32x16 = self.corruption_timer_b[i..][0..VEC_LEN].*; // DOT on enemy
        const fear_b: f32x16 = self.fear_timer_b[i..][0..VEC_LEN].*;
        const fear_a: f32x16 = self.fear_timer_a[i..][0..VEC_LEN].*;
        const horror_b: f32x16 = self.horror_timer_b[i..][0..VEC_LEN].*;
        const horror_a: f32x16 = self.horror_timer_a[i..][0..VEC_LEN].*;

        const un_cd_a: f32x16 = self.action6_cd_a[i..][0..VEC_LEN].*;
        const un_dur_a: f32x16 = self.action6_dur_a[i..][0..VEC_LEN].*;
        const un_dur_b: f32x16 = self.action6_dur_b[i..][0..VEC_LEN].*;
        const dc_cd_a: f32x16 = self.death_coil_cd_a[i..][0..VEC_LEN].*;
        const fear_dr_b: f32x16 = self.fear_dr_tier_b[i..][0..VEC_LEN].*;
        const move_a: f32x16 = self.move_intent_a[i..][0..VEC_LEN].*;

        var obs: [24]f32x16 = undefined;
        obs[0] = hp_a * inv_hp;
        obs[1] = mana_a * inv_mana;
        obs[2] = hp_b * inv_hp;
        obs[3] = mana_b * inv_mana;
        obs[4] = dist * inv_dist;
        obs[5] = gcd_a; // gcd is already 0.0 - 1.0s

        const a_is_casting: bool16 = c_id_a > @as(u32x16, @splat(0));
        obs[6] = select16(a_is_casting, v_ones, v_zeros);
        obs[7] = select16(a_is_casting, c_tmr_a / @max(v_ones * @as(f32x16, @splat(0.001)), c_tot_a), v_zeros);

        const b_is_casting: bool16 = c_id_b > @as(u32x16, @splat(0));
        obs[8] = select16(b_is_casting, v_ones, v_zeros);
        obs[9] = @as(f32x16, @floatFromInt(c_id_b)) * @as(f32x16, @splat(0.1));
        obs[10] = select16(b_is_casting, c_tmr_b / @max(v_ones * @as(f32x16, @splat(0.001)), c_tot_b), v_zeros);

        obs[11] = ago_b * inv_agony;
        obs[12] = crp_b * inv_corr;
        obs[13] = select16(fear_b > v_zeros, v_ones, v_zeros);
        obs[14] = select16(fear_a > v_zeros, v_ones, v_zeros);

        obs[15] = un_cd_a * inv_def_cd;
        obs[16] = select16(un_dur_a > v_zeros, v_ones, v_zeros);
        obs[17] = select16(un_dur_b > v_zeros, v_ones, v_zeros);
        obs[18] = move_a;
        obs[19] = (hp_a - hp_b) * inv_hp; // relative advantage
        obs[20] = dc_cd_a * inv_dc_cd;
        obs[21] = select16(vOr16(vOr16(fear_a > v_zeros, horror_a > v_zeros), self.seduction_timer_a[i..][0..VEC_LEN].* > v_zeros), v_ones, v_zeros);
        obs[22] = select16(vOr16(vOr16(fear_b > v_zeros, horror_b > v_zeros), self.seduction_timer_b[i..][0..VEC_LEN].* > v_zeros), v_ones, v_zeros);
        obs[23] = fear_dr_b * @as(f32x16, @splat(1.0 / 3.0));

        return obs;
    }

    /// Extract 24 normalized observation features across 16 lanes for Unit B (symmetric)
    pub fn getObservationsB(self: *const WarlockArenaPool, i: usize) [24]f32x16 {
        const v_zeros: f32x16 = @splat(0.0);
        const v_ones: f32x16 = @splat(1.0);
        const inv_hp: f32x16 = @splat(1.0 / WarlockConstants.MaxHp);
        const inv_mana: f32x16 = @splat(1.0 / WarlockConstants.MaxMana);
        const inv_dist: f32x16 = @splat(1.0 / WarlockConstants.MaxDistance);
        const inv_agony: f32x16 = @splat(1.0 / WarlockConstants.AgonyDuration);
        const inv_corr: f32x16 = @splat(1.0 / WarlockConstants.CorruptionDuration);
        const inv_def_cd: f32x16 = @splat(1.0 / WarlockConstants.HealthstoneCooldown);
        const inv_dc_cd: f32x16 = @splat(1.0 / WarlockConstants.DeathCoilCooldown);

        const hp_b: f32x16 = self.hp_b[i..][0..VEC_LEN].*;
        const hp_a: f32x16 = self.hp_a[i..][0..VEC_LEN].*;
        const mana_b: f32x16 = self.mana_b[i..][0..VEC_LEN].*;
        const mana_a: f32x16 = self.mana_a[i..][0..VEC_LEN].*;
        const dist: f32x16 = self.distance[i..][0..VEC_LEN].*;
        const gcd_b: f32x16 = self.gcd_b[i..][0..VEC_LEN].*;
        const c_id_b: u32x16 = self.cast_id_b[i..][0..VEC_LEN].*;
        const c_tmr_b: f32x16 = self.cast_timer_b[i..][0..VEC_LEN].*;
        const c_tot_b: f32x16 = self.cast_total_b[i..][0..VEC_LEN].*;

        const c_id_a: u32x16 = self.cast_id_a[i..][0..VEC_LEN].*;
        const c_tmr_a: f32x16 = self.cast_timer_a[i..][0..VEC_LEN].*;
        const c_tot_a: f32x16 = self.cast_total_a[i..][0..VEC_LEN].*;

        const ago_a: f32x16 = self.agony_timer_a[i..][0..VEC_LEN].*; // DOT on enemy (A)
        const crp_a: f32x16 = self.corruption_timer_a[i..][0..VEC_LEN].*; // DOT on enemy (A)
        const fear_a: f32x16 = self.fear_timer_a[i..][0..VEC_LEN].*;
        const fear_b: f32x16 = self.fear_timer_b[i..][0..VEC_LEN].*;
        const horror_a: f32x16 = self.horror_timer_a[i..][0..VEC_LEN].*;
        const horror_b: f32x16 = self.horror_timer_b[i..][0..VEC_LEN].*;

        const un_cd_b: f32x16 = self.action6_cd_b[i..][0..VEC_LEN].*;
        const un_dur_b: f32x16 = self.action6_dur_b[i..][0..VEC_LEN].*;
        const un_dur_a: f32x16 = self.action6_dur_a[i..][0..VEC_LEN].*;
        const dc_cd_b: f32x16 = self.death_coil_cd_b[i..][0..VEC_LEN].*;
        const fear_dr_a: f32x16 = self.fear_dr_tier_a[i..][0..VEC_LEN].*;
        const move_b: f32x16 = self.move_intent_b[i..][0..VEC_LEN].*;

        var obs: [24]f32x16 = undefined;
        obs[0] = hp_b * inv_hp;
        obs[1] = mana_b * inv_mana;
        obs[2] = hp_a * inv_hp;
        obs[3] = mana_a * inv_mana;
        obs[4] = dist * inv_dist;
        obs[5] = gcd_b;

        const b_is_casting: bool16 = c_id_b > @as(u32x16, @splat(0));
        obs[6] = select16(b_is_casting, v_ones, v_zeros);
        obs[7] = select16(b_is_casting, c_tmr_b / @max(v_ones * @as(f32x16, @splat(0.001)), c_tot_b), v_zeros);

        const a_is_casting: bool16 = c_id_a > @as(u32x16, @splat(0));
        obs[8] = select16(a_is_casting, v_ones, v_zeros);
        obs[9] = @as(f32x16, @floatFromInt(c_id_a)) * @as(f32x16, @splat(0.1));
        obs[10] = select16(a_is_casting, c_tmr_a / @max(v_ones * @as(f32x16, @splat(0.001)), c_tot_a), v_zeros);

        obs[11] = ago_a * inv_agony;
        obs[12] = crp_a * inv_corr;
        obs[13] = select16(fear_a > v_zeros, v_ones, v_zeros);
        obs[14] = select16(fear_b > v_zeros, v_ones, v_zeros);

        obs[15] = un_cd_b * inv_def_cd;
        obs[16] = select16(un_dur_b > v_zeros, v_ones, v_zeros);
        obs[17] = select16(un_dur_a > v_zeros, v_ones, v_zeros);
        obs[18] = move_b;
        obs[19] = (hp_b - hp_a) * inv_hp;
        obs[20] = dc_cd_b * inv_dc_cd;
        obs[21] = select16(vOr16(vOr16(fear_b > v_zeros, horror_b > v_zeros), self.seduction_timer_b[i..][0..VEC_LEN].* > v_zeros), v_ones, v_zeros);
        obs[22] = select16(vOr16(vOr16(fear_a > v_zeros, horror_a > v_zeros), self.seduction_timer_a[i..][0..VEC_LEN].* > v_zeros), v_ones, v_zeros);
        obs[23] = fear_dr_a * @as(f32x16, @splat(1.0 / 3.0));

        return obs;
    }

    /// Check if decision is required for Unit A (reaction timer hit 0 or hard stop triggered)
    pub fn needsDecisionA(self: *const WarlockArenaPool, i: usize) bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const react_done = self.react_timer_a[i..][0..VEC_LEN].* <= v_zeros;
        const gcd_done = self.gcd_a[i..][0..VEC_LEN].* <= v_zeros;
        const cast_done = vAnd16(
            self.cast_id_a[i..][0..VEC_LEN].* > @as(u32x16, @splat(0)),
            self.cast_timer_a[i..][0..VEC_LEN].* <= v_zeros,
        );
        return vOr16(react_done, vOr16(gcd_done, cast_done));
    }

    /// Event-driven tactical decision boundary for Unit A (casts, GCD, interrupts, CC, defensives)
    pub fn needsTacticalDecisionA(self: *const WarlockArenaPool, i: usize) bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const gcd_done = self.gcd_a[i..][0..VEC_LEN].* <= v_zeros;
        const is_casting = self.cast_id_a[i..][0..VEC_LEN].* > @as(u32x16, @splat(0));
        const cast_done = vAnd16(
            is_casting,
            self.cast_timer_a[i..][0..VEC_LEN].* <= v_zeros,
        );
        // During an active cast, no tactical decision is needed unless the cast is done
        const react_trigger = self.react_timer_a[i..][0..VEC_LEN].* <= v_zeros;
        return vOr16(cast_done, vAnd16(vNot16(is_casting), vAnd16(react_trigger, gcd_done)));
    }

    /// Check if decision is required for Unit B
    pub fn needsDecisionB(self: *const WarlockArenaPool, i: usize) bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const react_done = self.react_timer_b[i..][0..VEC_LEN].* <= v_zeros;
        const gcd_done = self.gcd_b[i..][0..VEC_LEN].* <= v_zeros;
        const cast_done = vAnd16(
            self.cast_id_b[i..][0..VEC_LEN].* > @as(u32x16, @splat(0)),
            self.cast_timer_b[i..][0..VEC_LEN].* <= v_zeros,
        );
        return vOr16(react_done, vOr16(gcd_done, cast_done));
    }

    /// Event-driven tactical decision boundary for Unit B
    pub fn needsTacticalDecisionB(self: *const WarlockArenaPool, i: usize) bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const gcd_done = self.gcd_b[i..][0..VEC_LEN].* <= v_zeros;
        const is_casting = self.cast_id_b[i..][0..VEC_LEN].* > @as(u32x16, @splat(0));
        const cast_done = vAnd16(
            is_casting,
            self.cast_timer_b[i..][0..VEC_LEN].* <= v_zeros,
        );
        const react_trigger = self.react_timer_b[i..][0..VEC_LEN].* <= v_zeros;
        return vOr16(cast_done, vAnd16(vNot16(is_casting), vAnd16(react_trigger, gcd_done)));
    }

    /// Branchless action mask: returns bool16 array for action legality across 16 lanes
    pub fn getActionMaskA(self: *const WarlockArenaPool, i: usize) [WarlockAction.COUNT]bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const hp = self.hp_a[i..][0..VEC_LEN].*;
        const mana = self.mana_a[i..][0..VEC_LEN].*;
        const mana_mult = warlock_talents.decode(self.talent_ranks_a[i..][0..VEC_LEN].*, self.talent_flags_a[i..][0..VEC_LEN].*).shadow_bolt_mana;
        const gcd = self.gcd_a[i..][0..VEC_LEN].*;
        const dist = self.distance[i..][0..VEC_LEN].*;
        const cast_id = self.cast_id_a[i..][0..VEC_LEN].*;
        const is_casting = cast_id > @as(u32x16, @splat(0));
        const target_is_casting = self.cast_id_b[i..][0..VEC_LEN].* > @as(u32x16, @splat(0));
        const fear = self.fear_timer_a[i..][0..VEC_LEN].*;
        const horror = self.horror_timer_a[i..][0..VEC_LEN].*;
        const seduction = @max(@as(f32x16, self.seduction_timer_a[i..][0..VEC_LEN].*), @as(f32x16, self.stun_timer_a[i..][0..VEC_LEN].*));
        const is_cc = vOr16(vOr16(fear > v_zeros, horror > v_zeros), seduction > v_zeros);
        const gcd_free = gcd <= v_zeros;
        const can_act = vAnd16(vNot16(is_cc), vNot16(is_casting));

        var masks: [WarlockAction.COUNT]bool16 = undefined;

        // 0. Idle / Maneuver: Legal unless CC'd
        masks[@intFromEnum(WarlockAction.IdleOrManeuver)] = vNot16(is_cc);

        // 1. Agony: Instant, range 35m, cost 30 mana, needs gcd_free
        masks[@intFromEnum(WarlockAction.Agony)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.AgonyMana))));

        // 2. Corruption: Instant, range 35m, cost 40 mana, needs gcd_free
        masks[@intFromEnum(WarlockAction.Corruption)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.CorruptionMana))));

        // 3. Fear: Hard cast, stationary, range 20m, cost 60 mana
        const in_fear_range = dist <= @as(f32x16, @splat(WarlockConstants.FearRange));
        masks[@intFromEnum(WarlockAction.Fear)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_fear_range, mana >= @as(f32x16, @splat(WarlockConstants.FearMana)))));

        // 4. Shadow Bolt: Hard cast, stationary, range 35m, cost 50 mana
        masks[@intFromEnum(WarlockAction.ShadowBolt)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)) * mana_mult));

        // 5. Drain Life: Channeled, stationary, range 25m, cost 70 mana
        const in_drain_range = dist <= @as(f32x16, @splat(WarlockConstants.DrainLifeRange));
        masks[@intFromEnum(WarlockAction.DrainLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_drain_range, mana >= @as(f32x16, @splat(WarlockConstants.DrainLifeMana)))));

        // 6. Healthstone: usable below max health, once per duel.
        const un_cd = self.action6_cd_a[i..][0..VEC_LEN].*;
        masks[@intFromEnum(WarlockAction.Healthstone)] = vAnd16(vNot16(is_cc), vAnd16(un_cd <= v_zeros, hp < @as(f32x16, self.max_health_a[i..][0..VEC_LEN].*)));

        // 7. Death Coil: Instant, range 30m, 45s CD, 50 mana
        const dc_cd = self.death_coil_cd_a[i..][0..VEC_LEN].*;
        const in_dc_range = dist <= @as(f32x16, @splat(WarlockConstants.DeathCoilRange));
        masks[@intFromEnum(WarlockAction.DeathCoil)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_dc_range, vAnd16(dc_cd <= v_zeros, mana >= @as(f32x16, @splat(WarlockConstants.DeathCoilMana))))));

        // 8. Siphon Life: Instant, range 30m, cost 45 mana, needs gcd_free
        const in_siphon_range = dist <= @as(f32x16, @splat(WarlockConstants.SiphonLifeRange));
        masks[@intFromEnum(WarlockAction.SiphonLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_siphon_range, mana >= @as(f32x16, @splat(WarlockConstants.SiphonLifeMana)))));
        masks[@intFromEnum(WarlockAction.SiphonLife)] = vAnd16(masks[@intFromEnum(WarlockAction.SiphonLife)], warlock_talents.siphonUnlocked(self.talent_ranks_a[i..][0..VEC_LEN].*));

        const sb_cd = self.shadowburn_cd_a[i..][0..VEC_LEN].*;
        const shards = self.soul_shards_a[i..][0..VEC_LEN].*;
        const in_sb_range = dist <= @as(f32x16, @splat(WarlockConstants.ShadowburnRange));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_sb_range, vAnd16(sb_cd <= v_zeros, vAnd16(shards >= @as(f32x16, @splat(1)), mana >= @as(f32x16, @splat(WarlockConstants.ShadowburnMana)) * mana_mult)))));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(masks[@intFromEnum(WarlockAction.Shadowburn)], warlock_talents.shadowburnUnlocked(self.talent_ranks_a[i..][0..VEC_LEN].*));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(masks[@intFromEnum(WarlockAction.Shadowburn)], @import("projectiles.zig").available(self, true, i));

        // 10. Cancel Cast: Only legal if actively casting!
        masks[@intFromEnum(WarlockAction.CancelCast)] = is_casting;

        const fire_room = @import("projectiles.zig").available(self, true, i);
        const in_sp_range = dist <= @as(f32x16, @splat(WarlockConstants.SearingPainRange));
        masks[@intFromEnum(WarlockAction.SearingPain)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_sp_range, mana >= @as(f32x16, @splat(WarlockConstants.SearingPainMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.SearingPain)] = vAnd16(masks[@intFromEnum(WarlockAction.SearingPain)], fire_room);
        masks[@intFromEnum(WarlockAction.Incinerate)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.FireSpellRange)), mana >= @as(f32x16, @splat(WarlockConstants.IncinerateMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.Incinerate)] = vAnd16(masks[@intFromEnum(WarlockAction.Incinerate)], fire_room);
        masks[@intFromEnum(WarlockAction.Immolate)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.FireSpellRange)), mana >= @as(f32x16, @splat(WarlockConstants.ImmolateMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.Immolate)] = vAnd16(masks[@intFromEnum(WarlockAction.Immolate)], fire_room);

        masks[@intFromEnum(WarlockAction.Conflagrate)] = @import("conflagrate.zig").legal(self, true, i, vAnd16(can_act, gcd_free));

        const succubus_a = @import("pets.zig").Kind.succubus;
        const pet_seduce = vAnd16(self.pet_kind_a[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(succubus_a))), self.pet_hp_a[i..][0..VEC_LEN].* > v_zeros);
        masks[@intFromEnum(WarlockAction.Seduction)] = vAnd16(pet_seduce, vAnd16(self.seduction_cd_a[i..][0..VEC_LEN].* <= v_zeros, dist <= @as(f32x16, @splat(WarlockConstants.SeductionRange))));
        const pet_felhunter_a = vAnd16(self.pet_kind_a[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(@import("pets.zig").Kind.felhunter))), self.pet_hp_a[i..][0..VEC_LEN].* > v_zeros);
        masks[@intFromEnum(WarlockAction.SpellLock)] = vAnd16(target_is_casting, vAnd16(pet_felhunter_a, vAnd16(self.seduction_cd_a[i..][0..VEC_LEN].* <= v_zeros, dist <= @as(f32x16, @splat(WarlockConstants.SpellLockRange)))));

        const shadow_unlocked = self.shadow_lockout_a[i..][0..VEC_LEN].* <= v_zeros;
        const fire_unlocked = self.fire_lockout_a[i..][0..VEC_LEN].* <= v_zeros;
        inline for (.{ 1, 2, 3, 4, 5, 7, 8, 9 }) |slot| masks[slot] = vAnd16(masks[slot], shadow_unlocked);
        inline for (.{ 11, 12, 13, 16 }) |slot| masks[slot] = vAnd16(masks[slot], fire_unlocked);

        const projectile_room = @import("projectiles.zig").available(self, true, i);
        masks[4] = vAnd16(masks[4], projectile_room);
        masks[7] = vAnd16(masks[7], projectile_room);
        @import("racials.zig").fillMasks(self, true, i, &masks);
        return masks;
    }

    /// Branchless action mask for Unit B
    pub fn getActionMaskB(self: *const WarlockArenaPool, i: usize) [WarlockAction.COUNT]bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const hp = self.hp_b[i..][0..VEC_LEN].*;
        const mana = self.mana_b[i..][0..VEC_LEN].*;
        const mana_mult = warlock_talents.decode(self.talent_ranks_b[i..][0..VEC_LEN].*, self.talent_flags_b[i..][0..VEC_LEN].*).shadow_bolt_mana;
        const gcd = self.gcd_b[i..][0..VEC_LEN].*;
        const dist = self.distance[i..][0..VEC_LEN].*;
        const cast_id = self.cast_id_b[i..][0..VEC_LEN].*;
        const is_casting = cast_id > @as(u32x16, @splat(0));
        const target_is_casting = self.cast_id_a[i..][0..VEC_LEN].* > @as(u32x16, @splat(0));
        const fear = self.fear_timer_b[i..][0..VEC_LEN].*;
        const horror = self.horror_timer_b[i..][0..VEC_LEN].*;
        const seduction = @max(@as(f32x16, self.seduction_timer_b[i..][0..VEC_LEN].*), @as(f32x16, self.stun_timer_b[i..][0..VEC_LEN].*));
        const is_cc = vOr16(vOr16(fear > v_zeros, horror > v_zeros), seduction > v_zeros);
        const gcd_free = gcd <= v_zeros;
        const can_act = vAnd16(vNot16(is_cc), vNot16(is_casting));

        var masks: [WarlockAction.COUNT]bool16 = undefined;

        // 0. Idle / Maneuver: Legal unless CC'd
        masks[@intFromEnum(WarlockAction.IdleOrManeuver)] = vNot16(is_cc);

        // 1. Agony: Instant, range 35m, cost 30 mana, needs gcd_free
        masks[@intFromEnum(WarlockAction.Agony)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.AgonyMana))));

        // 2. Corruption: Instant, range 35m, cost 40 mana, needs gcd_free
        masks[@intFromEnum(WarlockAction.Corruption)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.CorruptionMana))));

        // 3. Fear: Hard cast, stationary, range 20m, cost 60 mana
        const in_fear_range = dist <= @as(f32x16, @splat(WarlockConstants.FearRange));
        masks[@intFromEnum(WarlockAction.Fear)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_fear_range, mana >= @as(f32x16, @splat(WarlockConstants.FearMana)))));

        // 4. Shadow Bolt: Hard cast, stationary, range 35m, cost 50 mana
        masks[@intFromEnum(WarlockAction.ShadowBolt)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)) * mana_mult));

        // 5. Drain Life: Channeled, stationary, range 25m, cost 70 mana
        const in_drain_range = dist <= @as(f32x16, @splat(WarlockConstants.DrainLifeRange));
        masks[@intFromEnum(WarlockAction.DrainLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_drain_range, mana >= @as(f32x16, @splat(WarlockConstants.DrainLifeMana)))));

        // 6. Healthstone: usable below max health, once per duel.
        const un_cd = self.action6_cd_b[i..][0..VEC_LEN].*;
        masks[@intFromEnum(WarlockAction.Healthstone)] = vAnd16(vNot16(is_cc), vAnd16(un_cd <= v_zeros, hp < @as(f32x16, self.max_health_b[i..][0..VEC_LEN].*)));

        // 7. Death Coil: Instant, range 30m, 45s CD, 50 mana
        const dc_cd = self.death_coil_cd_b[i..][0..VEC_LEN].*;
        const in_dc_range = dist <= @as(f32x16, @splat(WarlockConstants.DeathCoilRange));
        masks[@intFromEnum(WarlockAction.DeathCoil)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_dc_range, vAnd16(dc_cd <= v_zeros, mana >= @as(f32x16, @splat(WarlockConstants.DeathCoilMana))))));

        // 8. Siphon Life: Instant, range 30m, cost 45 mana, needs gcd_free
        const in_siphon_range = dist <= @as(f32x16, @splat(WarlockConstants.SiphonLifeRange));
        masks[@intFromEnum(WarlockAction.SiphonLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_siphon_range, mana >= @as(f32x16, @splat(WarlockConstants.SiphonLifeMana)))));
        masks[@intFromEnum(WarlockAction.SiphonLife)] = vAnd16(masks[@intFromEnum(WarlockAction.SiphonLife)], warlock_talents.siphonUnlocked(self.talent_ranks_b[i..][0..VEC_LEN].*));

        const sb_cd = self.shadowburn_cd_b[i..][0..VEC_LEN].*;
        const shards = self.soul_shards_b[i..][0..VEC_LEN].*;
        const in_sb_range = dist <= @as(f32x16, @splat(WarlockConstants.ShadowburnRange));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_sb_range, vAnd16(sb_cd <= v_zeros, vAnd16(shards >= @as(f32x16, @splat(1)), mana >= @as(f32x16, @splat(WarlockConstants.ShadowburnMana)) * mana_mult)))));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(masks[@intFromEnum(WarlockAction.Shadowburn)], warlock_talents.shadowburnUnlocked(self.talent_ranks_b[i..][0..VEC_LEN].*));
        masks[@intFromEnum(WarlockAction.Shadowburn)] = vAnd16(masks[@intFromEnum(WarlockAction.Shadowburn)], @import("projectiles.zig").available(self, false, i));

        // 10. Cancel Cast: Only legal if actively casting!
        masks[@intFromEnum(WarlockAction.CancelCast)] = is_casting;
        const fire_room = @import("projectiles.zig").available(self, false, i);
        const in_sp_range = dist <= @as(f32x16, @splat(WarlockConstants.SearingPainRange));
        masks[@intFromEnum(WarlockAction.SearingPain)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_sp_range, mana >= @as(f32x16, @splat(WarlockConstants.SearingPainMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.SearingPain)] = vAnd16(masks[@intFromEnum(WarlockAction.SearingPain)], fire_room);
        masks[@intFromEnum(WarlockAction.Incinerate)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.FireSpellRange)), mana >= @as(f32x16, @splat(WarlockConstants.IncinerateMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.Incinerate)] = vAnd16(masks[@intFromEnum(WarlockAction.Incinerate)], fire_room);
        masks[@intFromEnum(WarlockAction.Immolate)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.FireSpellRange)), mana >= @as(f32x16, @splat(WarlockConstants.ImmolateMana)) * mana_mult)));
        masks[@intFromEnum(WarlockAction.Immolate)] = vAnd16(masks[@intFromEnum(WarlockAction.Immolate)], fire_room);

        masks[@intFromEnum(WarlockAction.Conflagrate)] = @import("conflagrate.zig").legal(self, false, i, vAnd16(can_act, gcd_free));

        const succubus_b = @import("pets.zig").Kind.succubus;
        const pet_seduce = vAnd16(self.pet_kind_b[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(succubus_b))), self.pet_hp_b[i..][0..VEC_LEN].* > v_zeros);
        masks[@intFromEnum(WarlockAction.Seduction)] = vAnd16(pet_seduce, vAnd16(self.seduction_cd_b[i..][0..VEC_LEN].* <= v_zeros, dist <= @as(f32x16, @splat(WarlockConstants.SeductionRange))));
        const pet_felhunter_b = vAnd16(self.pet_kind_b[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(@import("pets.zig").Kind.felhunter))), self.pet_hp_b[i..][0..VEC_LEN].* > v_zeros);
        masks[@intFromEnum(WarlockAction.SpellLock)] = vAnd16(target_is_casting, vAnd16(pet_felhunter_b, vAnd16(self.seduction_cd_b[i..][0..VEC_LEN].* <= v_zeros, dist <= @as(f32x16, @splat(WarlockConstants.SpellLockRange)))));

        const shadow_unlocked = self.shadow_lockout_b[i..][0..VEC_LEN].* <= v_zeros;
        const fire_unlocked = self.fire_lockout_b[i..][0..VEC_LEN].* <= v_zeros;
        inline for (.{ 1, 2, 3, 4, 5, 7, 8, 9 }) |slot| masks[slot] = vAnd16(masks[slot], shadow_unlocked);
        inline for (.{ 11, 12, 13, 16 }) |slot| masks[slot] = vAnd16(masks[slot], fire_unlocked);

        const projectile_room = @import("projectiles.zig").available(self, false, i);
        masks[4] = vAnd16(masks[4], projectile_room);
        masks[7] = vAnd16(masks[7], projectile_room);
        @import("racials.zig").fillMasks(self, false, i, &masks);
        return masks;
    }

    /// Apply commanded actions to Unit A across 16 lanes
    pub fn applyActionA(self: *WarlockArenaPool, i: usize, actions: u32x16, move_intents: f32x16) void {
        self.applyActionAImpl(i, actions, move_intents, false);
    }
    /// Stage an action against an immutable pre-action state; caller merges and clamps.
    pub fn stageActionA(self: *WarlockArenaPool, i: usize, actions: u32x16, move_intents: f32x16) void {
        self.applyActionAImpl(i, actions, move_intents, true);
    }
    fn applyActionAImpl(
        self: *WarlockArenaPool,
        i: usize,
        actions: u32x16,
        move_intents: f32x16,
        comptime staged: bool,
    ) void {
        _ = staged;
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_gcd_std: f32x16 = @max(@as(f32x16, @splat(1)), @as(f32x16, @splat(WarlockConstants.StandardGcd)) / @import("racials.zig").hasteMultiplier(self, true, i));
        const v_react_std: f32x16 = @splat(WarlockConstants.ReactionInterval);
        var effects_a = warlock_talents.decodeExtended(self.talent_ranks_a[i..][0..VEC_LEN].*, self.talent_flags_a[i..][0..VEC_LEN].*, self.talent_extra_a[i..][0..VEC_LEN].*);
        @import("conflagrate.zig").buffEffects(self, true, i, &effects_a);

        var hp_a = self.hp_a[i..][0..VEC_LEN].*;
        const hp_b = self.hp_b[i..][0..VEC_LEN].*;
        var mana_a = self.mana_a[i..][0..VEC_LEN].*;
        var gcd_a = self.gcd_a[i..][0..VEC_LEN].*;
        var cast_id = self.cast_id_a[i..][0..VEC_LEN].*;
        var cast_tmr = self.cast_timer_a[i..][0..VEC_LEN].*;
        var cast_tot = self.cast_total_a[i..][0..VEC_LEN].*;
        var un_cd = self.action6_cd_a[i..][0..VEC_LEN].*;
        const un_dur = self.action6_dur_a[i..][0..VEC_LEN].*;
        var dc_cd_a = self.death_coil_cd_a[i..][0..VEC_LEN].*;
        var sb_cd_a = self.shadowburn_cd_a[i..][0..VEC_LEN].*;
        var shards_a = self.soul_shards_a[i..][0..VEC_LEN].*;
        var move_a = self.move_intent_a[i..][0..VEC_LEN].*;

        // Debuffs applied to Target B
        var ago_b = self.agony_timer_b[i..][0..VEC_LEN].*;
        var immolate_b: f32x16 = self.immolate_timer_b[i..][0..VEC_LEN].*;
        var crp_b = self.corruption_timer_b[i..][0..VEC_LEN].*;
        var siph_b = self.siphon_timer_b[i..][0..VEC_LEN].*;
        const horror_b = self.horror_timer_b[i..][0..VEC_LEN].*;
        const horror_dr_t_b = self.horror_dr_tier_b[i..][0..VEC_LEN].*;
        const horror_dr_tmr_b = self.horror_dr_timer_b[i..][0..VEC_LEN].*;

        // Reset reaction timer upon choosing an action
        self.react_timer_a[i..][0..VEC_LEN].* = v_react_std;
        const starts_cast = vOr16(vAnd16(actions >= @as(u32x16, @splat(3)), actions <= @as(u32x16, @splat(5))), vAnd16(actions >= @as(u32x16, @splat(10)), actions <= @as(u32x16, @splat(13))));
        @import("pushback.zig").reset(self, true, i, starts_cast);

        // 1. Maneuver intent:
        const was_casting_a = cast_id > v_zeros_u32;
        const is_act_cancel: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.CancelCast)));
        const allow_movement_a = vOr16(vNot16(was_casting_a), is_act_cancel);
        move_a = select16(allow_movement_a, move_intents, v_zeros);

        // Cancel Cast
        cast_id = @select(u32, is_act_cancel, v_zeros_u32, cast_id);
        cast_tmr = select16(is_act_cancel, v_zeros, cast_tmr);
        cast_tot = select16(is_act_cancel, v_zeros, cast_tot);

        // Action 1: Agony (Instant while moving)
        const is_act1: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Agony)));
        ago_b = select16(@import("periodic.zig").application(self, true, i, is_act1, effects_a.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.AgonyDuration)), ago_b);
        mana_a = select16(is_act1, mana_a - @as(f32x16, @splat(WarlockConstants.AgonyMana)), mana_a);
        gcd_a = select16(is_act1, v_gcd_std, gcd_a);

        // Action 2: Corruption (Instant while moving)
        const is_act2: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Corruption)));
        crp_b = select16(@import("periodic.zig").application(self, true, i, is_act2, effects_a.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.CorruptionDuration)), crp_b);
        mana_a = select16(is_act2, mana_a - @as(f32x16, @splat(WarlockConstants.CorruptionMana)), mana_a);
        gcd_a = select16(is_act2, v_gcd_std, gcd_a);

        // Action 3: Fear (1.5s Hard cast, stationary; mana spent on completion)
        const is_act3: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Fear)));
        cast_id = @select(u32, is_act3, @as(u32x16, @splat(3)), cast_id);
        cast_tmr = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tmr);
        cast_tot = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tot);
        gcd_a = select16(is_act3, v_gcd_std, gcd_a);
        move_a = select16(is_act3, v_zeros, move_a); // Must stand still to cast

        // Action 4: Shadow Bolt (1.8s Hard cast, stationary; mana spent on completion)
        const is_act4: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.ShadowBolt)));
        cast_id = @select(u32, is_act4, @as(u32x16, @splat(4)), cast_id);
        cast_tmr = select16(is_act4, effects_a.shadow_bolt_cast_time, cast_tmr);
        cast_tot = select16(is_act4, effects_a.shadow_bolt_cast_time, cast_tot);
        gcd_a = select16(is_act4, v_gcd_std, gcd_a);
        move_a = select16(is_act4, v_zeros, move_a);

        // Action 5: Drain Life (3.0s Channel, stationary)
        const is_act5: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DrainLife)));
        const drain_landed_a = @import("periodic.zig").application(self, true, i, is_act5, effects_a.spell_hit_bonus, .shadow);
        cast_id = @select(u32, drain_landed_a, @as(u32x16, @splat(5)), cast_id);
        cast_tmr = select16(drain_landed_a, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tmr);
        cast_tot = select16(drain_landed_a, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tot);
        mana_a = select16(is_act5, mana_a - @as(f32x16, @splat(WarlockConstants.DrainLifeMana)), mana_a);
        gcd_a = select16(is_act5, v_gcd_std, gcd_a);
        move_a = select16(is_act5, v_zeros, move_a);

        // Action 6: Major Healthstone (instant, off GCD).
        const is_act6: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Healthstone)));
        hp_a = @min(@as(f32x16, self.max_health_a[i..][0..VEC_LEN].*), hp_a + select16(is_act6, @as(f32x16, @splat(WarlockConstants.HealthstoneHeal)), v_zeros));
        un_cd = select16(is_act6, @as(f32x16, @splat(WarlockConstants.HealthstoneCooldown)), un_cd);

        // Action 7: Death Coil (instant launch; damage/heal/Horror on impact)
        const is_act_dc: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DeathCoil)));
        mana_a = select16(is_act_dc, mana_a - @as(f32x16, @splat(WarlockConstants.DeathCoilMana)), mana_a);
        gcd_a = select16(is_act_dc, v_gcd_std, gcd_a);
        dc_cd_a = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilCooldown)), dc_cd_a);

        @import("projectiles.zig").launchClass(self, true, i, 7, (@as(f32x16, @splat(WarlockConstants.DeathCoilDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.214))) * effects_a.shadow_damage, is_act_dc, .warlock);

        // Action 8: Siphon Life (Instant DOT, castable while moving)
        const is_act_siph: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SiphonLife)));
        siph_b = select16(@import("periodic.zig").application(self, true, i, is_act_siph, effects_a.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.SiphonLifeDuration)), siph_b);
        mana_a = select16(is_act_siph, mana_a - @as(f32x16, @splat(WarlockConstants.SiphonLifeMana)), mana_a);
        gcd_a = select16(is_act_siph, v_gcd_std, gcd_a);

        const is_act_shadowburn = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Shadowburn)));
        mana_a = select16(is_act_shadowburn, mana_a - @as(f32x16, @splat(WarlockConstants.ShadowburnMana)) * effects_a.shadow_bolt_mana, mana_a);
        gcd_a = select16(is_act_shadowburn, v_gcd_std, gcd_a);
        sb_cd_a = select16(is_act_shadowburn, @as(f32x16, @splat(WarlockConstants.ShadowburnCooldown)), sb_cd_a);
        shards_a = select16(is_act_shadowburn, @max(v_zeros, shards_a - @as(f32x16, @splat(1.0)) + effects_a.shadowburn_shard_refund), shards_a);
        @import("projectiles.zig").launchClass(self, true, i, 9, (@as(f32x16, @splat(WarlockConstants.ShadowburnDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.42857142857142855))) * effects_a.shadow_damage, is_act_shadowburn, .warlock);

        const is_sp = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SearingPain)));
        cast_id = @select(u32, is_sp, @as(u32x16, @splat(11)), cast_id);
        cast_tmr = select16(is_sp, @as(f32x16, @splat(WarlockConstants.SearingPainCastTime)), cast_tmr);
        cast_tot = select16(is_sp, @as(f32x16, @splat(WarlockConstants.SearingPainCastTime)), cast_tot);
        gcd_a = select16(is_sp, v_gcd_std, gcd_a);
        move_a = select16(is_sp, v_zeros, move_a);
        const is_inc = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Incinerate)));
        cast_id = @select(u32, is_inc, @as(u32x16, @splat(12)), cast_id);
        cast_tmr = select16(is_inc, @as(f32x16, @splat(WarlockConstants.IncinerateCastTime)), cast_tmr);
        cast_tot = select16(is_inc, @as(f32x16, @splat(WarlockConstants.IncinerateCastTime)), cast_tot);
        gcd_a = select16(is_inc, v_gcd_std, gcd_a);
        move_a = select16(is_inc, v_zeros, move_a);
        const is_immolate = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Immolate)));
        cast_id = @select(u32, is_immolate, @as(u32x16, @splat(13)), cast_id);
        cast_tmr = select16(is_immolate, @as(f32x16, @splat(WarlockConstants.ImmolateCastTime)), cast_tmr);
        cast_tot = select16(is_immolate, @as(f32x16, @splat(WarlockConstants.ImmolateCastTime)), cast_tot);
        gcd_a = select16(is_immolate, v_gcd_std, gcd_a);
        move_a = select16(is_immolate, v_zeros, move_a);

        const conflag = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Conflagrate)));
        @import("conflagrate.zig").apply(self, true, i, conflag, effects_a, &immolate_b);
        mana_a = select16(conflag, mana_a - @as(f32x16, @splat(WarlockConstants.ConflagrateMana)) * effects_a.shadow_bolt_mana, mana_a);
        gcd_a = select16(conflag, v_gcd_std, gcd_a);

        self.hp_a[i..][0..VEC_LEN].* = hp_a;
        self.hp_b[i..][0..VEC_LEN].* = hp_b;
        self.mana_a[i..][0..VEC_LEN].* = mana_a;
        self.gcd_a[i..][0..VEC_LEN].* = gcd_a;
        self.cast_id_a[i..][0..VEC_LEN].* = cast_id;
        self.cast_timer_a[i..][0..VEC_LEN].* = cast_tmr;
        self.cast_total_a[i..][0..VEC_LEN].* = cast_tot;
        self.action6_cd_a[i..][0..VEC_LEN].* = un_cd;
        self.action6_dur_a[i..][0..VEC_LEN].* = un_dur;
        self.death_coil_cd_a[i..][0..VEC_LEN].* = dc_cd_a;
        self.shadowburn_cd_a[i..][0..VEC_LEN].* = sb_cd_a;
        self.soul_shards_a[i..][0..VEC_LEN].* = shards_a;
        self.move_intent_a[i..][0..VEC_LEN].* = move_a;
        self.agony_timer_b[i..][0..VEC_LEN].* = ago_b;
        self.immolate_timer_b[i..][0..VEC_LEN].* = immolate_b;
        self.corruption_timer_b[i..][0..VEC_LEN].* = crp_b;
        self.siphon_timer_b[i..][0..VEC_LEN].* = siph_b;
        self.horror_timer_b[i..][0..VEC_LEN].* = horror_b;
        self.horror_dr_tier_b[i..][0..VEC_LEN].* = horror_dr_t_b;
        self.horror_dr_timer_b[i..][0..VEC_LEN].* = horror_dr_tmr_b;
        const seduce_a = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Seduction)));
        self.seduction_cast_a[i..][0..VEC_LEN].* = select16(seduce_a, @as(f32x16, @splat(WarlockConstants.SeductionCastTime)), self.seduction_cast_a[i..][0..VEC_LEN].*);
        self.seduction_cd_a[i..][0..VEC_LEN].* = select16(seduce_a, @as(f32x16, @splat(WarlockConstants.SeductionCooldown)), self.seduction_cd_a[i..][0..VEC_LEN].*);
        const spell_lock_a = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SpellLock)));
        self.seduction_cd_a[i..][0..VEC_LEN].* = select16(spell_lock_a, effects_a.spell_lock_cooldown, self.seduction_cd_a[i..][0..VEC_LEN].*);
        const interrupted_b = @import("periodic.zig").control(self, true, i, vAnd16(spell_lock_a, self.cast_id_b[i..][0..VEC_LEN].* != v_zeros_u32), @as(f32x16, @splat(0)), .shadow, true);
        self.applySpellLock(false, i, interrupted_b);
        self.cast_id_b[i..][0..VEC_LEN].* = @select(u32, interrupted_b, v_zeros_u32, self.cast_id_b[i..][0..VEC_LEN].*);
        self.cast_timer_b[i..][0..VEC_LEN].* = select16(interrupted_b, v_zeros, self.cast_timer_b[i..][0..VEC_LEN].*);
        self.cast_total_b[i..][0..VEC_LEN].* = select16(interrupted_b, v_zeros, self.cast_total_b[i..][0..VEC_LEN].*);
        self.react_timer_b[i..][0..VEC_LEN].* = select16(interrupted_b, v_zeros, self.react_timer_b[i..][0..VEC_LEN].*);
        @import("racials.zig").apply(self, true, i, actions, .warlock);
    }

    /// Capture the interrupted school before clearing the cast. Separate timers
    /// keep school restrictions independent and participate in combat snapshots.
    fn applySpellLock(self: *WarlockArenaPool, comptime target_a: bool, i: usize, interrupted: bool16) void {
        if (!@reduce(.Or, interrupted)) return;
        const suffix = if (target_a) "_a" else "_b";
        const cast = @field(self, "cast_id" ++ suffix)[i..][0..VEC_LEN].*;
        const fire = vAnd16(interrupted, vAnd16(cast >= @as(u32x16, @splat(11)), cast <= @as(u32x16, @splat(13))));
        const shadow = vAnd16(interrupted, vAnd16(cast >= @as(u32x16, @splat(3)), cast <= @as(u32x16, @splat(5))));
        inline for (.{ "shadow", "fire" }) |school| {
            const timer = @field(self, school ++ "_lockout" ++ suffix)[i..][0..VEC_LEN];
            timer.* = select16(if (comptime std.mem.eql(u8, school, "fire")) fire else shadow, @as(f32x16, @splat(WarlockConstants.SpellLockDuration)), timer.*);
        }
    }

    /// Symmetric Action application for Unit B
    pub fn applyActionB(self: *WarlockArenaPool, i: usize, actions: u32x16, move_intents: f32x16) void {
        self.applyActionBImpl(i, actions, move_intents, false);
    }
    /// Stage an action against an immutable pre-action state; caller merges and clamps.
    pub fn stageActionB(self: *WarlockArenaPool, i: usize, actions: u32x16, move_intents: f32x16) void {
        self.applyActionBImpl(i, actions, move_intents, true);
    }
    fn applyActionBImpl(
        self: *WarlockArenaPool,
        i: usize,
        actions: u32x16,
        move_intents: f32x16,
        comptime staged: bool,
    ) void {
        _ = staged;
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_gcd_std: f32x16 = @max(@as(f32x16, @splat(1)), @as(f32x16, @splat(WarlockConstants.StandardGcd)) / @import("racials.zig").hasteMultiplier(self, false, i));
        const v_react_std: f32x16 = @splat(WarlockConstants.ReactionInterval);
        var effects_b = warlock_talents.decodeExtended(self.talent_ranks_b[i..][0..VEC_LEN].*, self.talent_flags_b[i..][0..VEC_LEN].*, self.talent_extra_b[i..][0..VEC_LEN].*);
        @import("conflagrate.zig").buffEffects(self, false, i, &effects_b);

        const hp_a = self.hp_a[i..][0..VEC_LEN].*;
        var hp_b = self.hp_b[i..][0..VEC_LEN].*;
        var mana_b = self.mana_b[i..][0..VEC_LEN].*;
        var gcd_b = self.gcd_b[i..][0..VEC_LEN].*;
        var cast_id = self.cast_id_b[i..][0..VEC_LEN].*;
        var cast_tmr = self.cast_timer_b[i..][0..VEC_LEN].*;
        var cast_tot = self.cast_total_b[i..][0..VEC_LEN].*;
        var un_cd = self.action6_cd_b[i..][0..VEC_LEN].*;
        const un_dur = self.action6_dur_b[i..][0..VEC_LEN].*;
        var dc_cd_b = self.death_coil_cd_b[i..][0..VEC_LEN].*;
        var sb_cd_b = self.shadowburn_cd_b[i..][0..VEC_LEN].*;
        var shards_b = self.soul_shards_b[i..][0..VEC_LEN].*;
        var move_b = self.move_intent_b[i..][0..VEC_LEN].*;

        var ago_a = self.agony_timer_a[i..][0..VEC_LEN].*;
        var immolate_a: f32x16 = self.immolate_timer_a[i..][0..VEC_LEN].*;
        var crp_a = self.corruption_timer_a[i..][0..VEC_LEN].*;
        var siph_a = self.siphon_timer_a[i..][0..VEC_LEN].*;
        const horror_a = self.horror_timer_a[i..][0..VEC_LEN].*;
        const horror_dr_t_a = self.horror_dr_tier_a[i..][0..VEC_LEN].*;
        const horror_dr_tmr_a = self.horror_dr_timer_a[i..][0..VEC_LEN].*;

        self.react_timer_b[i..][0..VEC_LEN].* = v_react_std;
        const starts_cast = vOr16(vAnd16(actions >= @as(u32x16, @splat(3)), actions <= @as(u32x16, @splat(5))), vAnd16(actions >= @as(u32x16, @splat(10)), actions <= @as(u32x16, @splat(13))));
        @import("pushback.zig").reset(self, false, i, starts_cast);

        const was_casting_b = cast_id > v_zeros_u32;
        const is_act_cancel: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.CancelCast)));
        const allow_movement_b = vOr16(vNot16(was_casting_b), is_act_cancel);
        move_b = select16(allow_movement_b, move_intents, v_zeros);

        // Cancel Cast
        cast_id = @select(u32, is_act_cancel, v_zeros_u32, cast_id);
        cast_tmr = select16(is_act_cancel, v_zeros, cast_tmr);
        cast_tot = select16(is_act_cancel, v_zeros, cast_tot);

        // Agony
        const is_act1: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Agony)));
        ago_a = select16(@import("periodic.zig").application(self, false, i, is_act1, effects_b.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.AgonyDuration)), ago_a);
        mana_b = select16(is_act1, mana_b - @as(f32x16, @splat(WarlockConstants.AgonyMana)), mana_b);
        gcd_b = select16(is_act1, v_gcd_std, gcd_b);

        // Corruption
        const is_act2: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Corruption)));
        crp_a = select16(@import("periodic.zig").application(self, false, i, is_act2, effects_b.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.CorruptionDuration)), crp_a);
        mana_b = select16(is_act2, mana_b - @as(f32x16, @splat(WarlockConstants.CorruptionMana)), mana_b);
        gcd_b = select16(is_act2, v_gcd_std, gcd_b);

        // Fear
        const is_act3: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Fear)));
        cast_id = @select(u32, is_act3, @as(u32x16, @splat(3)), cast_id);
        cast_tmr = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tmr);
        cast_tot = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tot);
        gcd_b = select16(is_act3, v_gcd_std, gcd_b);
        move_b = select16(is_act3, v_zeros, move_b);

        // Shadow Bolt
        const is_act4: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.ShadowBolt)));
        cast_id = @select(u32, is_act4, @as(u32x16, @splat(4)), cast_id);
        cast_tmr = select16(is_act4, effects_b.shadow_bolt_cast_time, cast_tmr);
        cast_tot = select16(is_act4, effects_b.shadow_bolt_cast_time, cast_tot);
        gcd_b = select16(is_act4, v_gcd_std, gcd_b);
        move_b = select16(is_act4, v_zeros, move_b);

        // Drain Life
        const is_act5: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DrainLife)));
        const drain_landed_b = @import("periodic.zig").application(self, false, i, is_act5, effects_b.spell_hit_bonus, .shadow);
        cast_id = @select(u32, drain_landed_b, @as(u32x16, @splat(5)), cast_id);
        cast_tmr = select16(drain_landed_b, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tmr);
        cast_tot = select16(drain_landed_b, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tot);
        mana_b = select16(is_act5, mana_b - @as(f32x16, @splat(WarlockConstants.DrainLifeMana)), mana_b);
        gcd_b = select16(is_act5, v_gcd_std, gcd_b);
        move_b = select16(is_act5, v_zeros, move_b);

        // Major Healthstone
        const is_act6: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Healthstone)));
        hp_b = @min(@as(f32x16, self.max_health_b[i..][0..VEC_LEN].*), hp_b + select16(is_act6, @as(f32x16, @splat(WarlockConstants.HealthstoneHeal)), v_zeros));
        un_cd = select16(is_act6, @as(f32x16, @splat(WarlockConstants.HealthstoneCooldown)), un_cd);

        // Death Coil
        const is_act_dc: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DeathCoil)));
        mana_b = select16(is_act_dc, mana_b - @as(f32x16, @splat(WarlockConstants.DeathCoilMana)), mana_b);
        gcd_b = select16(is_act_dc, v_gcd_std, gcd_b);
        dc_cd_b = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilCooldown)), dc_cd_b);

        @import("projectiles.zig").launchClass(self, false, i, 7, (@as(f32x16, @splat(WarlockConstants.DeathCoilDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.214))) * effects_b.shadow_damage, is_act_dc, .warlock);

        // Siphon Life
        const is_act_siph: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SiphonLife)));
        siph_a = select16(@import("periodic.zig").application(self, false, i, is_act_siph, effects_b.spell_hit_bonus, .shadow), @as(f32x16, @splat(WarlockConstants.SiphonLifeDuration)), siph_a);
        mana_b = select16(is_act_siph, mana_b - @as(f32x16, @splat(WarlockConstants.SiphonLifeMana)), mana_b);
        gcd_b = select16(is_act_siph, v_gcd_std, gcd_b);

        const is_act_shadowburn = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Shadowburn)));
        mana_b = select16(is_act_shadowburn, mana_b - @as(f32x16, @splat(WarlockConstants.ShadowburnMana)) * effects_b.shadow_bolt_mana, mana_b);
        gcd_b = select16(is_act_shadowburn, v_gcd_std, gcd_b);
        sb_cd_b = select16(is_act_shadowburn, @as(f32x16, @splat(WarlockConstants.ShadowburnCooldown)), sb_cd_b);
        shards_b = select16(is_act_shadowburn, @max(v_zeros, shards_b - @as(f32x16, @splat(1.0)) + effects_b.shadowburn_shard_refund), shards_b);
        @import("projectiles.zig").launchClass(self, false, i, 9, (@as(f32x16, @splat(WarlockConstants.ShadowburnDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.42857142857142855))) * effects_b.shadow_damage, is_act_shadowburn, .warlock);

        const is_sp = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SearingPain)));
        cast_id = @select(u32, is_sp, @as(u32x16, @splat(11)), cast_id);
        cast_tmr = select16(is_sp, @as(f32x16, @splat(WarlockConstants.SearingPainCastTime)), cast_tmr);
        cast_tot = select16(is_sp, @as(f32x16, @splat(WarlockConstants.SearingPainCastTime)), cast_tot);
        gcd_b = select16(is_sp, v_gcd_std, gcd_b);
        move_b = select16(is_sp, v_zeros, move_b);
        const is_inc = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Incinerate)));
        cast_id = @select(u32, is_inc, @as(u32x16, @splat(12)), cast_id);
        cast_tmr = select16(is_inc, @as(f32x16, @splat(WarlockConstants.IncinerateCastTime)), cast_tmr);
        cast_tot = select16(is_inc, @as(f32x16, @splat(WarlockConstants.IncinerateCastTime)), cast_tot);
        gcd_b = select16(is_inc, v_gcd_std, gcd_b);
        move_b = select16(is_inc, v_zeros, move_b);
        const is_immolate = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Immolate)));
        cast_id = @select(u32, is_immolate, @as(u32x16, @splat(13)), cast_id);
        cast_tmr = select16(is_immolate, @as(f32x16, @splat(WarlockConstants.ImmolateCastTime)), cast_tmr);
        cast_tot = select16(is_immolate, @as(f32x16, @splat(WarlockConstants.ImmolateCastTime)), cast_tot);
        gcd_b = select16(is_immolate, v_gcd_std, gcd_b);
        move_b = select16(is_immolate, v_zeros, move_b);

        self.hp_a[i..][0..VEC_LEN].* = hp_a;
        const conflag = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Conflagrate)));
        @import("conflagrate.zig").apply(self, false, i, conflag, effects_b, &immolate_a);
        mana_b = select16(conflag, mana_b - @as(f32x16, @splat(WarlockConstants.ConflagrateMana)) * effects_b.shadow_bolt_mana, mana_b);
        gcd_b = select16(conflag, v_gcd_std, gcd_b);

        self.hp_b[i..][0..VEC_LEN].* = hp_b;
        self.mana_b[i..][0..VEC_LEN].* = mana_b;
        self.gcd_b[i..][0..VEC_LEN].* = gcd_b;
        self.cast_id_b[i..][0..VEC_LEN].* = cast_id;
        self.cast_timer_b[i..][0..VEC_LEN].* = cast_tmr;
        self.cast_total_b[i..][0..VEC_LEN].* = cast_tot;
        self.action6_cd_b[i..][0..VEC_LEN].* = un_cd;
        self.action6_dur_b[i..][0..VEC_LEN].* = un_dur;
        self.death_coil_cd_b[i..][0..VEC_LEN].* = dc_cd_b;
        self.shadowburn_cd_b[i..][0..VEC_LEN].* = sb_cd_b;
        self.soul_shards_b[i..][0..VEC_LEN].* = shards_b;
        self.move_intent_b[i..][0..VEC_LEN].* = move_b;
        self.agony_timer_a[i..][0..VEC_LEN].* = ago_a;
        self.immolate_timer_a[i..][0..VEC_LEN].* = immolate_a;
        self.corruption_timer_a[i..][0..VEC_LEN].* = crp_a;
        self.siphon_timer_a[i..][0..VEC_LEN].* = siph_a;
        self.horror_timer_a[i..][0..VEC_LEN].* = horror_a;
        self.horror_dr_tier_a[i..][0..VEC_LEN].* = horror_dr_t_a;
        self.horror_dr_timer_a[i..][0..VEC_LEN].* = horror_dr_tmr_a;
        const seduce_b = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Seduction)));
        self.seduction_cast_b[i..][0..VEC_LEN].* = select16(seduce_b, @as(f32x16, @splat(WarlockConstants.SeductionCastTime)), self.seduction_cast_b[i..][0..VEC_LEN].*);
        self.seduction_cd_b[i..][0..VEC_LEN].* = select16(seduce_b, @as(f32x16, @splat(WarlockConstants.SeductionCooldown)), self.seduction_cd_b[i..][0..VEC_LEN].*);
        const spell_lock_b = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.SpellLock)));
        self.seduction_cd_b[i..][0..VEC_LEN].* = select16(spell_lock_b, effects_b.spell_lock_cooldown, self.seduction_cd_b[i..][0..VEC_LEN].*);
        const interrupted_a = @import("periodic.zig").control(self, false, i, vAnd16(spell_lock_b, self.cast_id_a[i..][0..VEC_LEN].* != v_zeros_u32), @as(f32x16, @splat(0)), .shadow, true);
        self.applySpellLock(true, i, interrupted_a);
        self.cast_id_a[i..][0..VEC_LEN].* = @select(u32, interrupted_a, v_zeros_u32, self.cast_id_a[i..][0..VEC_LEN].*);
        self.cast_timer_a[i..][0..VEC_LEN].* = select16(interrupted_a, v_zeros, self.cast_timer_a[i..][0..VEC_LEN].*);
        self.cast_total_a[i..][0..VEC_LEN].* = select16(interrupted_a, v_zeros, self.cast_total_a[i..][0..VEC_LEN].*);
        self.react_timer_a[i..][0..VEC_LEN].* = select16(interrupted_a, v_zeros, self.react_timer_a[i..][0..VEC_LEN].*);
        @import("racials.zig").apply(self, false, i, actions, .warlock);
    }

    /// Vectorized Physics & Combat Tick (dt = 0.010s / 100Hz)
    /// Ticks timers, updates distance, resolves casts, DOTs, CC, and mitigation branchlessly.
    pub fn tickPhysics(self: *WarlockArenaPool, dt: f32) usize {
        return self.tickPhysicsRange(dt, 0, self.capacity);
    }

    /// Tick only the requested aligned SIMD batch; other arena lanes stay untouched.
    pub fn tickPhysics16(self: *WarlockArenaPool, dt: f32, offset: usize) usize {
        std.debug.assert(offset % VEC_LEN == 0 and offset + VEC_LEN <= self.capacity);
        return self.tickPhysicsRange(dt, offset, offset + VEC_LEN);
    }

    pub fn tickPhysics16WithEffects(self: *WarlockArenaPool, dt: f32, offset: usize, effects_a: *const warlock_talents.Effects, effects_b: *const warlock_talents.Effects) usize {
        std.debug.assert(offset % VEC_LEN == 0 and offset + VEC_LEN <= self.capacity);
        return self.tickPhysicsRangeWithEffects(dt, offset, offset + VEC_LEN, effects_a, effects_b);
    }

    fn tickPhysicsRange(self: *WarlockArenaPool, dt: f32, start: usize, end: usize) usize {
        return self.tickPhysicsRangeWithEffects(dt, start, end, null, null);
    }

    fn tickPhysicsRangeWithEffects(self: *WarlockArenaPool, dt: f32, start: usize, end: usize, provided_a: ?*const warlock_talents.Effects, provided_b: ?*const warlock_talents.Effects) usize {
        const v_dt: f32x16 = @splat(dt);
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_ones_u32: u32x16 = @splat(1);

        var active_duels_sum: usize = 0;
        var i: usize = start;

        while (i < end) : (i += VEC_LEN) {
            const active_mask: bool16 = self.is_active[i..][0..VEC_LEN].* > v_zeros_u32;
            if (!@reduce(.Or, active_mask)) continue;
            var effects_a = if (provided_a) |fx| fx.* else warlock_talents.decodeExtended(self.talent_ranks_a[i..][0..VEC_LEN].*, self.talent_flags_a[i..][0..VEC_LEN].*, self.talent_extra_a[i..][0..VEC_LEN].*);
            @import("conflagrate.zig").tickEffects(self, true, i, dt, &effects_a);
            var effects_b = if (provided_b) |fx| fx.* else warlock_talents.decodeExtended(self.talent_ranks_b[i..][0..VEC_LEN].*, self.talent_flags_b[i..][0..VEC_LEN].*, self.talent_extra_b[i..][0..VEC_LEN].*);
            @import("conflagrate.zig").tickEffects(self, false, i, dt, &effects_b);

            const sacrifice_a = vAnd16(effects_a.demonic_sacrifice > v_zeros, effects_a.demonic_sacrifice_pet > v_zeros);
            const sacrifice_b = vAnd16(effects_b.demonic_sacrifice > v_zeros, effects_b.demonic_sacrifice_pet > v_zeros);
            const PetKind = @import("pets.zig").Kind;
            const is_imp_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.imp)))));
            const is_succ_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.succubus)))));
            const is_vw_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.voidwalker)))));
            const is_fh_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.felhunter)))));
            const is_imp_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.imp)))));
            const is_succ_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.succubus)))));
            const is_vw_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.voidwalker)))));
            const is_fh_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == @as(f32x16, @splat(@floatFromInt(@intFromEnum(PetKind.felhunter)))));
            effects_a.shadow_damage *= select16(is_imp_a, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));
            effects_b.shadow_damage *= select16(is_imp_b, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));
            const shadow_sac_mult_a = select16(is_imp_a, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));
            const shadow_sac_mult_b = select16(is_imp_b, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));
            effects_a.agony_damage *= shadow_sac_mult_a;
            effects_a.corruption_damage *= shadow_sac_mult_a;
            effects_a.drain_life_damage *= shadow_sac_mult_a;
            effects_a.drain_life_healing *= shadow_sac_mult_a;
            effects_a.siphon_life_damage *= shadow_sac_mult_a;
            effects_a.siphon_life_healing *= shadow_sac_mult_a;
            effects_b.agony_damage *= shadow_sac_mult_b;
            effects_b.corruption_damage *= shadow_sac_mult_b;
            effects_b.drain_life_damage *= shadow_sac_mult_b;
            effects_b.drain_life_healing *= shadow_sac_mult_b;
            effects_b.siphon_life_damage *= shadow_sac_mult_b;
            effects_b.siphon_life_healing *= shadow_sac_mult_b;
            effects_a.fire_damage *= select16(is_succ_a, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));
            effects_b.fire_damage *= select16(is_succ_b, @as(f32x16, @splat(1.15)), @as(f32x16, @splat(1.0)));

            // Load State
            var dist = self.distance[i..][0..VEC_LEN].*;
            var hp_a = self.hp_a[i..][0..VEC_LEN].*;
            var hp_b = self.hp_b[i..][0..VEC_LEN].*;
            var mana_a = self.mana_a[i..][0..VEC_LEN].*;
            var mana_b = self.mana_b[i..][0..VEC_LEN].*;
            var gcd_a = self.gcd_a[i..][0..VEC_LEN].*;
            var gcd_b = self.gcd_b[i..][0..VEC_LEN].*;
            var r_tmr_a = self.react_timer_a[i..][0..VEC_LEN].*;
            var r_tmr_b = self.react_timer_b[i..][0..VEC_LEN].*;
            const move_a = self.move_intent_a[i..][0..VEC_LEN].*;
            const move_b = self.move_intent_b[i..][0..VEC_LEN].*;

            var c_id_a = self.cast_id_a[i..][0..VEC_LEN].*;
            var c_tmr_a = self.cast_timer_a[i..][0..VEC_LEN].*;
            var c_tot_a = self.cast_total_a[i..][0..VEC_LEN].*;

            var c_id_b = self.cast_id_b[i..][0..VEC_LEN].*;
            var c_tmr_b = self.cast_timer_b[i..][0..VEC_LEN].*;
            var c_tot_b = self.cast_total_b[i..][0..VEC_LEN].*;

            var ago_a = self.agony_timer_a[i..][0..VEC_LEN].*;
            var immolate_a: f32x16 = self.immolate_timer_a[i..][0..VEC_LEN].*;
            var crp_a = self.corruption_timer_a[i..][0..VEC_LEN].*;
            var siph_a = self.siphon_timer_a[i..][0..VEC_LEN].*;
            var fear_a = self.fear_timer_a[i..][0..VEC_LEN].*;
            var fear_dmg_a = self.fear_accum_dmg_a[i..][0..VEC_LEN].*;
            var seduction_a = self.seduction_timer_a[i..][0..VEC_LEN].*;
            var seduced_a: u32x16 = self.seduced_a[i..][0..VEC_LEN].*;
            var horror_a = self.horror_timer_a[i..][0..VEC_LEN].*;

            var ago_b = self.agony_timer_b[i..][0..VEC_LEN].*;
            var immolate_b: f32x16 = self.immolate_timer_b[i..][0..VEC_LEN].*;
            var crp_b = self.corruption_timer_b[i..][0..VEC_LEN].*;
            var siph_b = self.siphon_timer_b[i..][0..VEC_LEN].*;
            var fear_b = self.fear_timer_b[i..][0..VEC_LEN].*;
            var fear_dmg_b = self.fear_accum_dmg_b[i..][0..VEC_LEN].*;
            var seduction_b = self.seduction_timer_b[i..][0..VEC_LEN].*;
            var seduced_b: u32x16 = self.seduced_b[i..][0..VEC_LEN].*;
            var horror_b = self.horror_timer_b[i..][0..VEC_LEN].*;

            var un_cd_a = self.action6_cd_a[i..][0..VEC_LEN].*;
            var un_dur_a = self.action6_dur_a[i..][0..VEC_LEN].*;
            var dc_cd_a = self.death_coil_cd_a[i..][0..VEC_LEN].*;
            var sb_cd_a = self.shadowburn_cd_a[i..][0..VEC_LEN].*;
            var seduction_cd_a = self.seduction_cd_a[i..][0..VEC_LEN].*;
            var seduction_cast_a = self.seduction_cast_a[i..][0..VEC_LEN].*;
            var fear_dr_t_a = self.fear_dr_tier_a[i..][0..VEC_LEN].*;
            var fear_dr_tmr_a = self.fear_dr_timer_a[i..][0..VEC_LEN].*;
            var horror_dr_t_a = self.horror_dr_tier_a[i..][0..VEC_LEN].*;
            var horror_dr_tmr_a = self.horror_dr_timer_a[i..][0..VEC_LEN].*;
            var seduction_dr_t_a = self.seduction_dr_tier_a[i..][0..VEC_LEN].*;
            var seduction_dr_tmr_a = self.seduction_dr_timer_a[i..][0..VEC_LEN].*;

            var un_cd_b = self.action6_cd_b[i..][0..VEC_LEN].*;
            var un_dur_b = self.action6_dur_b[i..][0..VEC_LEN].*;
            var dc_cd_b = self.death_coil_cd_b[i..][0..VEC_LEN].*;
            var sb_cd_b = self.shadowburn_cd_b[i..][0..VEC_LEN].*;
            var seduction_cd_b = self.seduction_cd_b[i..][0..VEC_LEN].*;
            var seduction_cast_b = self.seduction_cast_b[i..][0..VEC_LEN].*;
            var fear_dr_t_b = self.fear_dr_tier_b[i..][0..VEC_LEN].*;
            var fear_dr_tmr_b = self.fear_dr_timer_b[i..][0..VEC_LEN].*;
            var horror_dr_t_b = self.horror_dr_tier_b[i..][0..VEC_LEN].*;
            var horror_dr_tmr_b = self.horror_dr_timer_b[i..][0..VEC_LEN].*;
            var seduction_dr_t_b = self.seduction_dr_tier_b[i..][0..VEC_LEN].*;
            var seduction_dr_tmr_b = self.seduction_dr_timer_b[i..][0..VEC_LEN].*;

            // Most batches have no school lockout. Avoid dirtying those columns
            // on every 10ms tick when no lane needs a countdown.
            inline for (.{ "shadow_lockout_a", "fire_lockout_a", "shadow_lockout_b", "fire_lockout_b", "isb_timer_a", "isb_timer_b" }) |name| {
                const timer = @field(self, name)[i..][0..VEC_LEN];
                if (@reduce(.Or, timer.* > v_zeros)) timer.* = @max(v_zeros, timer.* - v_dt);
            }

            // 1. Advance general timers
            gcd_a = @max(v_zeros, gcd_a - v_dt);
            gcd_b = @max(v_zeros, gcd_b - v_dt);
            r_tmr_a = @max(v_zeros, r_tmr_a - v_dt);
            r_tmr_b = @max(v_zeros, r_tmr_b - v_dt);
            un_cd_a = @max(v_zeros, un_cd_a - v_dt);
            un_cd_b = @max(v_zeros, un_cd_b - v_dt);
            sb_cd_a = @max(v_zeros, sb_cd_a - v_dt);
            sb_cd_b = @max(v_zeros, sb_cd_b - v_dt);
            seduction_cd_a = @max(v_zeros, seduction_cd_a - v_dt);
            seduction_cd_b = @max(v_zeros, seduction_cd_b - v_dt);
            const seduction_casting_a = seduction_cast_a > v_zeros;
            const seduction_casting_b = seduction_cast_b > v_zeros;
            seduction_cast_a = @max(v_zeros, seduction_cast_a - v_dt);
            seduction_cast_b = @max(v_zeros, seduction_cast_b - v_dt);
            const seduction_cast_done_a = vAnd16(seduction_casting_a, seduction_cast_a <= v_zeros);
            const seduction_cast_done_b = vAnd16(seduction_casting_b, seduction_cast_b <= v_zeros);
            un_dur_a = @max(v_zeros, un_dur_a - v_dt);
            un_dur_b = @max(v_zeros, un_dur_b - v_dt);
            dc_cd_a = @max(v_zeros, dc_cd_a - v_dt);
            dc_cd_b = @max(v_zeros, dc_cd_b - v_dt);
            fear_a = @max(v_zeros, fear_a - v_dt);
            fear_b = @max(v_zeros, fear_b - v_dt);
            seduction_a = @max(v_zeros, seduction_a - v_dt);
            seduction_b = @max(v_zeros, seduction_b - v_dt);
            seduced_a = @select(u32, seduction_a > v_zeros, seduced_a, v_zeros_u32);
            seduced_b = @select(u32, seduction_b > v_zeros, seduced_b, v_zeros_u32);

            horror_a = @max(v_zeros, horror_a - v_dt);
            horror_b = @max(v_zeros, horror_b - v_dt);

            // DR Timer progression when CC is inactive
            const fear_dr_ticking_a = vAnd16(fear_a <= v_zeros, fear_dr_t_a > v_zeros);
            fear_dr_tmr_a = select16(fear_dr_ticking_a, @max(v_zeros, fear_dr_tmr_a - v_dt), fear_dr_tmr_a);
            const fear_dr_reset_a = vAnd16(fear_dr_ticking_a, fear_dr_tmr_a <= v_zeros);
            fear_dr_t_a = select16(fear_dr_reset_a, v_zeros, fear_dr_t_a);
            const seduction_dr_ticking_a = vAnd16(seduction_a <= v_zeros, seduction_dr_t_a > v_zeros);
            seduction_dr_tmr_a = select16(seduction_dr_ticking_a, @max(v_zeros, seduction_dr_tmr_a - v_dt), seduction_dr_tmr_a);
            seduction_dr_t_a = select16(vAnd16(seduction_dr_ticking_a, seduction_dr_tmr_a <= v_zeros), v_zeros, seduction_dr_t_a);

            const fear_dr_ticking_b = vAnd16(fear_b <= v_zeros, fear_dr_t_b > v_zeros);
            fear_dr_tmr_b = select16(fear_dr_ticking_b, @max(v_zeros, fear_dr_tmr_b - v_dt), fear_dr_tmr_b);
            const fear_dr_reset_b = vAnd16(fear_dr_ticking_b, fear_dr_tmr_b <= v_zeros);
            fear_dr_t_b = select16(fear_dr_reset_b, v_zeros, fear_dr_t_b);
            const seduction_dr_ticking_b = vAnd16(seduction_b <= v_zeros, seduction_dr_t_b > v_zeros);
            seduction_dr_tmr_b = select16(seduction_dr_ticking_b, @max(v_zeros, seduction_dr_tmr_b - v_dt), seduction_dr_tmr_b);
            seduction_dr_t_b = select16(vAnd16(seduction_dr_ticking_b, seduction_dr_tmr_b <= v_zeros), v_zeros, seduction_dr_t_b);

            const horror_dr_ticking_a = vAnd16(horror_a <= v_zeros, horror_dr_t_a > v_zeros);
            horror_dr_tmr_a = select16(horror_dr_ticking_a, @max(v_zeros, horror_dr_tmr_a - v_dt), horror_dr_tmr_a);
            const horror_dr_reset_a = vAnd16(horror_dr_ticking_a, horror_dr_tmr_a <= v_zeros);
            horror_dr_t_a = select16(horror_dr_reset_a, v_zeros, horror_dr_t_a);

            const horror_dr_ticking_b = vAnd16(horror_b <= v_zeros, horror_dr_t_b > v_zeros);
            horror_dr_tmr_b = select16(horror_dr_ticking_b, @max(v_zeros, horror_dr_tmr_b - v_dt), horror_dr_tmr_b);
            const horror_dr_reset_b = vAnd16(horror_dr_ticking_b, horror_dr_tmr_b <= v_zeros);
            horror_dr_t_b = select16(horror_dr_reset_b, v_zeros, horror_dr_t_b);

            // Mana passive regen
            const regen: f32x16 = @splat(WarlockConstants.ManaRegenPerSec * dt);
            mana_a = @min(@as(f32x16, self.max_mana_a[i..][0..VEC_LEN].*), mana_a + regen + @select(f32, is_vw_a, @as(f32x16, self.max_mana_a[i..][0..VEC_LEN].*) * @as(f32x16, @splat(0.02 * dt / 4.0)), v_zeros));
            mana_b = @min(@as(f32x16, self.max_mana_b[i..][0..VEC_LEN].*), mana_b + regen + @select(f32, is_vw_b, @as(f32x16, self.max_mana_b[i..][0..VEC_LEN].*) * @as(f32x16, @splat(0.02 * dt / 4.0)), v_zeros));
            hp_a = @min(@as(f32x16, self.max_health_a[i..][0..VEC_LEN].*), hp_a + @select(f32, is_fh_a, @as(f32x16, self.max_health_a[i..][0..VEC_LEN].*) * @as(f32x16, @splat(0.03 * dt / 4.0)), v_zeros));
            hp_b = @min(@as(f32x16, self.max_health_b[i..][0..VEC_LEN].*), hp_b + @select(f32, is_fh_b, @as(f32x16, self.max_health_b[i..][0..VEC_LEN].*) * @as(f32x16, @splat(0.03 * dt / 4.0)), v_zeros));

            // 2. Movement & Relative Distance Update
            const speed_a = select16(move_a < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_a > v_zeros, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), v_zeros));
            const speed_b = select16(move_b < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_b > v_zeros, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), v_zeros));

            // While feared or horrified, unit runs away involuntarily!
            const fear_cc_a = vOr16(fear_a > v_zeros, horror_a > v_zeros);
            const fear_cc_b = vOr16(fear_b > v_zeros, horror_b > v_zeros);
            const cc_a = vOr16(fear_cc_a, seduction_a > v_zeros);
            const cc_b = vOr16(fear_cc_b, seduction_b > v_zeros);
            const controlled_speed_a = select16(fear_cc_a, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), speed_a);
            const controlled_speed_b = select16(fear_cc_b, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), speed_b);
            const effective_speed_a = select16(seduction_a > v_zeros, v_zeros, controlled_speed_a) * @import("conflagrate.zig").speed(self, true, i);
            const effective_speed_b = select16(seduction_b > v_zeros, v_zeros, controlled_speed_b) * @import("conflagrate.zig").speed(self, false, i);

            // 3. Movement cast cancel check:
            const a_is_stationary_casting = vAnd16(c_id_a > v_zeros_u32, c_id_a <= @as(u32x16, @splat(5)));
            const a_moved = effective_speed_a != v_zeros;
            const cancel_a = vAnd16(a_is_stationary_casting, vOr16(a_moved, cc_a));
            c_id_a = @select(u32, cancel_a, v_zeros_u32, c_id_a);
            c_tmr_a = select16(cancel_a, v_zeros, c_tmr_a);
            c_tot_a = select16(cancel_a, v_zeros, c_tot_a);

            const b_is_stationary_casting = vAnd16(c_id_b > v_zeros_u32, c_id_b <= @as(u32x16, @splat(5)));
            const b_moved = effective_speed_b != v_zeros;
            const cancel_b = vAnd16(b_is_stationary_casting, vOr16(b_moved, cc_b));
            c_id_b = @select(u32, cancel_b, v_zeros_u32, c_id_b);
            c_tmr_b = select16(cancel_b, v_zeros, c_tmr_b);
            c_tot_b = select16(cancel_b, v_zeros, c_tot_b);

            @import("conflagrate.zig").tickDaze(self, i, dt);
            dist = @import("movement_2d.zig").tick(self, i, dt, effective_speed_a, effective_speed_b, fear_cc_a, fear_cc_b, @max(@as(f32x16, fear_a), @as(f32x16, horror_a)), @max(@as(f32x16, fear_b), @as(f32x16, horror_b)));

            var hits_a = @import("projectiles.zig").tick(self, true, i, dt);
            hits_a.conflagrate = @import("conflagrate.zig").takeDamage(self, true, i);
            var hits_b = @import("projectiles.zig").tick(self, false, i, dt);
            hits_b.conflagrate = @import("conflagrate.zig").takeDamage(self, false, i);

            // 4. Damage Mitigation Factor:
            const mit_a = effects_a.damage_taken;
            const mit_b = effects_b.damage_taken;
            const pet_mit_a = @import("demon_passives.zig").petMitigation(self, true, i, mit_a);
            const pet_mit_b = @import("demon_passives.zig").petMitigation(self, false, i, mit_b);

            if (@reduce(.Or, hits_a.coil > v_zeros)) {
                const coil_hit_a = hits_a.coil > v_zeros;
                hp_a = @min(@as(f32x16, self.max_health_a[i..][0..VEC_LEN].*), hp_a + select16(coil_hit_a, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros));
                const coil_dur_a = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * getDrMultiplier(horror_dr_t_b);
                horror_b = select16(vAnd16(coil_hit_a, coil_dur_a > v_zeros), coil_dur_a, horror_b);
                horror_dr_t_b = select16(coil_hit_a, @min(@as(f32x16, @splat(3)), horror_dr_t_b + @as(f32x16, @splat(1))), horror_dr_t_b);
                horror_dr_tmr_b = select16(coil_hit_a, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_b);
                const coil_cancel_b = vAnd16(coil_hit_a, coil_dur_a > v_zeros);
                c_id_b = @select(u32, coil_cancel_b, v_zeros_u32, c_id_b);
                c_tmr_b = select16(coil_cancel_b, v_zeros, c_tmr_b);
                c_tot_b = select16(coil_cancel_b, v_zeros, c_tot_b);
                r_tmr_b = select16(coil_cancel_b, v_zeros, r_tmr_b);
            }
            if (@reduce(.Or, hits_b.coil > v_zeros)) {
                const coil_hit_b = hits_b.coil > v_zeros;
                hp_b = @min(@as(f32x16, self.max_health_b[i..][0..VEC_LEN].*), hp_b + select16(coil_hit_b, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros));
                const coil_dur_b = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * getDrMultiplier(horror_dr_t_a);
                horror_a = select16(vAnd16(coil_hit_b, coil_dur_b > v_zeros), coil_dur_b, horror_a);
                horror_dr_t_a = select16(coil_hit_b, @min(@as(f32x16, @splat(3)), horror_dr_t_a + @as(f32x16, @splat(1))), horror_dr_t_a);
                horror_dr_tmr_a = select16(coil_hit_b, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_a);
                const coil_cancel_a = vAnd16(coil_hit_b, coil_dur_b > v_zeros);
                c_id_a = @select(u32, coil_cancel_a, v_zeros_u32, c_id_a);
                c_tmr_a = select16(coil_cancel_a, v_zeros, c_tmr_a);
                c_tot_a = select16(coil_cancel_a, v_zeros, c_tot_a);
                r_tmr_a = select16(coil_cancel_a, v_zeros, r_tmr_a);
            }

            // Direct impacts can delay a live cast before it completes this step.
            const pet_a = @import("pets.zig").tick(self, true, i, dt, effects_a.imp_firebolt_damage) * effects_a.pet_damage;
            const pet_b = @import("pets.zig").tick(self, false, i, dt, effects_b.imp_firebolt_damage) * effects_b.pet_damage;
            @import("pushback.zig").apply(self, true, true, i, hits_b, pet_b, mit_a, v_zeros, effects_a, c_id_a, &c_tmr_a, c_tot_a);
            @import("pushback.zig").apply(self, false, true, i, hits_a, pet_a, mit_b, v_zeros, effects_b, c_id_b, &c_tmr_b, c_tot_b);

            // 5. Discrete periodic ticks (first tick after one full interval).
            const tick_ago_a = @import("periodic.zig").advance(self, false, i, &ago_a, dt, WarlockConstants.AgonyDuration, 2, (@as(f32x16, @splat(WarlockConstants.AgonyDps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.041666666666666664))) * effects_b.agony_damage, v_zeros, active_mask, @import("periodic.zig").shadowProfile(effects_b));
            const dmg_ago_a = tick_ago_a.damage * mit_a;
            const tick_crp_a = @import("periodic.zig").advance(self, false, i, &crp_a, dt, WarlockConstants.CorruptionDuration, 2, (@as(f32x16, @splat(WarlockConstants.CorruptionDps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.05555555555555555))) * effects_b.corruption_damage, v_zeros, active_mask, @import("periodic.zig").shadowProfile(effects_b));
            const dmg_crp_a = tick_crp_a.damage * mit_a;
            const tick_immolate_a = @import("periodic.zig").advance(self, false, i, &immolate_a, dt, WarlockConstants.ImmolateDuration, 3, (@as(f32x16, @splat(WarlockConstants.ImmolateDps)) + @import("spell_resolution.zig").spellPower(self, false, i, .fire) * @as(f32x16, @splat(0.043333333333333335))) * effects_b.periodic_damage * effects_b.fire_damage, v_zeros, active_mask, .{ .school = .fire, .crit_multiplier = effects_b.destruction_crit_multiplier });
            const dmg_immolate_a = tick_immolate_a.damage * mit_a;
            const tick_siph_a = @import("periodic.zig").advance(self, false, i, &siph_a, dt, WarlockConstants.SiphonLifeDuration, 3, (@as(f32x16, @splat(WarlockConstants.SiphonLifeDps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.016666666666666666))) * effects_b.siphon_life_damage, (@as(f32x16, @splat(WarlockConstants.SiphonLifeHps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.016666666666666666))) * effects_b.siphon_life_healing, active_mask, @import("periodic.zig").shadowProfile(effects_b));
            const dmg_siph_a = tick_siph_a.damage * mit_a;
            hp_b = @min(@as(f32x16, self.max_health_b[i..][0..VEC_LEN].*), hp_b + tick_siph_a.healing);
            const tick_ago_b = @import("periodic.zig").advance(self, true, i, &ago_b, dt, WarlockConstants.AgonyDuration, 2, (@as(f32x16, @splat(WarlockConstants.AgonyDps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.041666666666666664))) * effects_a.agony_damage, v_zeros, active_mask, @import("periodic.zig").shadowProfile(effects_a));
            const dmg_ago_b = tick_ago_b.damage * mit_b;
            const tick_crp_b = @import("periodic.zig").advance(self, true, i, &crp_b, dt, WarlockConstants.CorruptionDuration, 2, (@as(f32x16, @splat(WarlockConstants.CorruptionDps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.05555555555555555))) * effects_a.corruption_damage, v_zeros, active_mask, @import("periodic.zig").shadowProfile(effects_a));
            const dmg_crp_b = tick_crp_b.damage * mit_b;
            const tick_immolate_b = @import("periodic.zig").advance(self, true, i, &immolate_b, dt, WarlockConstants.ImmolateDuration, 3, (@as(f32x16, @splat(WarlockConstants.ImmolateDps)) + @import("spell_resolution.zig").spellPower(self, true, i, .fire) * @as(f32x16, @splat(0.043333333333333335))) * effects_a.periodic_damage * effects_a.fire_damage, v_zeros, active_mask, .{ .school = .fire, .crit_multiplier = effects_a.destruction_crit_multiplier });
            const dmg_immolate_b = tick_immolate_b.damage * mit_b;
            const tick_siph_b = @import("periodic.zig").advance(self, true, i, &siph_b, dt, WarlockConstants.SiphonLifeDuration, 3, (@as(f32x16, @splat(WarlockConstants.SiphonLifeDps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.016666666666666666))) * effects_a.siphon_life_damage, (@as(f32x16, @splat(WarlockConstants.SiphonLifeHps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.016666666666666666))) * effects_a.siphon_life_healing, active_mask, @import("periodic.zig").shadowProfile(effects_a));
            const dmg_siph_b = tick_siph_b.damage * mit_b;
            hp_a = @min(@as(f32x16, self.max_health_a[i..][0..VEC_LEN].*), hp_a + tick_siph_b.healing);

            // 6. Cast Execution & Drain Life Channeling:
            // --- Unit A Cast Progress ---
            const a_casting = c_id_a > v_zeros_u32;
            const drain_clock_a: f32x16 = c_tmr_a;
            c_tmr_a = select16(a_casting, @import("periodic.zig").remaining(c_tmr_a, @import("racials.zig").castStep(self, true, i, dt)), v_zeros);
            const a_cast_finished = vAnd16(a_casting, c_tmr_a <= v_zeros);

            const a_drain_active = vAnd16(a_casting, c_id_a == @as(u32x16, @splat(5)));
            const drain_tick_a = @import("periodic.zig").channel(self, true, i, drain_clock_a, @import("racials.zig").castStep(self, true, i, dt), WarlockConstants.DrainLifeDuration, 1, (@as(f32x16, @splat(WarlockConstants.DrainLifeDps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.1))) * effects_a.drain_life_damage, (@as(f32x16, @splat(WarlockConstants.DrainLifeHps)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.1))) * effects_a.drain_life_healing, a_drain_active, @import("periodic.zig").shadowProfile(effects_a));
            const a_drain_dmg = drain_tick_a.damage * mit_b;
            hp_a = @min(@as(f32x16, self.max_health_a[i..][0..VEC_LEN].*), hp_a + drain_tick_a.healing);

            const a_sb_cost = @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)) * effects_a.shadow_bolt_mana;
            const a_sb_hit = vAnd16(a_cast_finished, vAnd16(c_id_a == @as(u32x16, @splat(4)), mana_a >= a_sb_cost));
            mana_a = select16(a_sb_hit, mana_a - a_sb_cost, mana_a);
            @import("projectiles.zig").launchClass(self, true, i, 4, (@as(f32x16, @splat(WarlockConstants.ShadowBoltDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .shadow) * @as(f32x16, @splat(0.8571428571428571))) * effects_a.shadow_damage, a_sb_hit, .warlock);
            if (@reduce(.Or, a_sb_hit)) {
                const a_sb_crit = vAnd16(a_sb_hit, vAnd16(self.spell_outcome_a[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(@import("spell_resolution.zig").Outcome.crit))), effects_a.improved_shadow_bolt_mult > v_zeros));
                self.isb_timer_b[i..][0..VEC_LEN].* = select16(a_sb_crit, @as(f32x16, @splat(12.0)), self.isb_timer_b[i..][0..VEC_LEN].*);
                self.isb_charges_b[i..][0..VEC_LEN].* = select16(a_sb_crit, @as(f32x16, @splat(4.0)), self.isb_charges_b[i..][0..VEC_LEN].*);
                self.isb_vuln_b[i..][0..VEC_LEN].* = select16(a_sb_crit, effects_a.improved_shadow_bolt_mult, self.isb_vuln_b[i..][0..VEC_LEN].*);
            }
            const a_sp_cost = @as(f32x16, @splat(WarlockConstants.SearingPainMana)) * effects_a.shadow_bolt_mana;
            const a_sp_hit = vAnd16(a_cast_finished, vAnd16(c_id_a == @as(u32x16, @splat(11)), mana_a >= a_sp_cost));
            mana_a = select16(a_sp_hit, mana_a - a_sp_cost, mana_a);
            @import("projectiles.zig").launchClass(self, true, i, 11, (@as(f32x16, @splat(WarlockConstants.SearingPainDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .fire) * @as(f32x16, @splat(0.42857142857142855))) * effects_a.fire_damage, a_sp_hit, .warlock);
            const a_inc_cost = @as(f32x16, @splat(WarlockConstants.IncinerateMana)) * effects_a.shadow_bolt_mana;
            const a_inc_hit = vAnd16(a_cast_finished, vAnd16(c_id_a == @as(u32x16, @splat(12)), mana_a >= a_inc_cost));
            mana_a = select16(a_inc_hit, mana_a - a_inc_cost, mana_a);
            const a_inc_bonus = select16(immolate_b > v_zeros, @as(f32x16, @splat(1.25)), @as(f32x16, @splat(1.0)));
            @import("projectiles.zig").launchClass(self, true, i, 12, (@as(f32x16, @splat(WarlockConstants.IncinerateDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .fire) * @as(f32x16, @splat(0.7142857142857143))) * a_inc_bonus * effects_a.fire_damage, a_inc_hit, .warlock);
            const a_immolate_cost = @as(f32x16, @splat(WarlockConstants.ImmolateMana)) * effects_a.shadow_bolt_mana;
            const a_immolate_hit = vAnd16(a_cast_finished, vAnd16(c_id_a == @as(u32x16, @splat(13)), mana_a >= a_immolate_cost));
            mana_a = select16(a_immolate_hit, mana_a - a_immolate_cost, mana_a);
            @import("projectiles.zig").launchClass(self, true, i, 13, (@as(f32x16, @splat(WarlockConstants.ImmolateInitialDamage)) + @import("spell_resolution.zig").spellPower(self, true, i, .fire) * @as(f32x16, @splat(0.2))) * effects_a.immolate_initial_damage, a_immolate_hit, .warlock);

            const a_fear_cost = @as(f32x16, @splat(WarlockConstants.FearMana));
            const a_fear_cast_done = vAnd16(a_cast_finished, vAnd16(c_id_a == @as(u32x16, @splat(3)), mana_a >= a_fear_cost));
            mana_a = select16(a_fear_cast_done, mana_a - a_fear_cost, mana_a);
            const a_fear_hit = @import("periodic.zig").control(self, true, i, a_fear_cast_done, effects_a.spell_hit_bonus, .shadow, false);
            const a_fear_dr_mult = getDrMultiplier(fear_dr_t_b);
            const a_fear_dur = @as(f32x16, @splat(WarlockConstants.FearDuration)) * a_fear_dr_mult;
            fear_b = select16(a_fear_hit, a_fear_dur, fear_b);
            fear_dr_t_b = select16(a_fear_hit, @min(@as(f32x16, @splat(3.0)), fear_dr_t_b + @as(f32x16, @splat(1.0))), fear_dr_t_b);
            fear_dr_tmr_b = select16(a_fear_hit, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), fear_dr_tmr_b);
            fear_dmg_b = select16(a_fear_hit, v_zeros, fear_dmg_b);

            c_id_a = @select(u32, a_cast_finished, v_zeros_u32, c_id_a);
            c_tmr_a = select16(a_cast_finished, v_zeros, c_tmr_a);
            c_tot_a = select16(a_cast_finished, v_zeros, c_tot_a);
            r_tmr_a = select16(a_cast_finished, v_zeros, r_tmr_a);

            // --- Unit B Cast Progress ---
            const b_casting = c_id_b > v_zeros_u32;
            const drain_clock_b: f32x16 = c_tmr_b;
            c_tmr_b = select16(b_casting, @import("periodic.zig").remaining(c_tmr_b, @import("racials.zig").castStep(self, false, i, dt)), v_zeros);
            const b_cast_finished = vAnd16(b_casting, c_tmr_b <= v_zeros);

            const b_drain_active = vAnd16(b_casting, c_id_b == @as(u32x16, @splat(5)));
            const drain_tick_b = @import("periodic.zig").channel(self, false, i, drain_clock_b, @import("racials.zig").castStep(self, false, i, dt), WarlockConstants.DrainLifeDuration, 1, (@as(f32x16, @splat(WarlockConstants.DrainLifeDps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.1))) * effects_b.drain_life_damage, (@as(f32x16, @splat(WarlockConstants.DrainLifeHps)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.1))) * effects_b.drain_life_healing, b_drain_active, @import("periodic.zig").shadowProfile(effects_b));
            const b_drain_dmg = drain_tick_b.damage * mit_a;
            hp_b = @min(@as(f32x16, self.max_health_b[i..][0..VEC_LEN].*), hp_b + drain_tick_b.healing);

            const b_sb_cost = @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)) * effects_b.shadow_bolt_mana;
            const b_sb_hit = vAnd16(b_cast_finished, vAnd16(c_id_b == @as(u32x16, @splat(4)), mana_b >= b_sb_cost));
            mana_b = select16(b_sb_hit, mana_b - b_sb_cost, mana_b);
            @import("projectiles.zig").launchClass(self, false, i, 4, (@as(f32x16, @splat(WarlockConstants.ShadowBoltDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .shadow) * @as(f32x16, @splat(0.8571428571428571))) * effects_b.shadow_damage, b_sb_hit, .warlock);
            if (@reduce(.Or, b_sb_hit)) {
                const b_sb_crit = vAnd16(b_sb_hit, vAnd16(self.spell_outcome_b[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(@import("spell_resolution.zig").Outcome.crit))), effects_b.improved_shadow_bolt_mult > v_zeros));
                self.isb_timer_a[i..][0..VEC_LEN].* = select16(b_sb_crit, @as(f32x16, @splat(12.0)), self.isb_timer_a[i..][0..VEC_LEN].*);
                self.isb_charges_a[i..][0..VEC_LEN].* = select16(b_sb_crit, @as(f32x16, @splat(4.0)), self.isb_charges_a[i..][0..VEC_LEN].*);
                self.isb_vuln_a[i..][0..VEC_LEN].* = select16(b_sb_crit, effects_b.improved_shadow_bolt_mult, self.isb_vuln_a[i..][0..VEC_LEN].*);
            }
            const b_sp_cost = @as(f32x16, @splat(WarlockConstants.SearingPainMana)) * effects_b.shadow_bolt_mana;
            const b_sp_hit = vAnd16(b_cast_finished, vAnd16(c_id_b == @as(u32x16, @splat(11)), mana_b >= b_sp_cost));
            mana_b = select16(b_sp_hit, mana_b - b_sp_cost, mana_b);
            @import("projectiles.zig").launchClass(self, false, i, 11, (@as(f32x16, @splat(WarlockConstants.SearingPainDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .fire) * @as(f32x16, @splat(0.42857142857142855))) * effects_b.fire_damage, b_sp_hit, .warlock);
            const b_inc_cost = @as(f32x16, @splat(WarlockConstants.IncinerateMana)) * effects_b.shadow_bolt_mana;
            const b_inc_hit = vAnd16(b_cast_finished, vAnd16(c_id_b == @as(u32x16, @splat(12)), mana_b >= b_inc_cost));
            mana_b = select16(b_inc_hit, mana_b - b_inc_cost, mana_b);
            const b_inc_bonus = select16(immolate_a > v_zeros, @as(f32x16, @splat(1.25)), @as(f32x16, @splat(1.0)));
            @import("projectiles.zig").launchClass(self, false, i, 12, (@as(f32x16, @splat(WarlockConstants.IncinerateDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .fire) * @as(f32x16, @splat(0.7142857142857143))) * b_inc_bonus * effects_b.fire_damage, b_inc_hit, .warlock);
            const b_immolate_cost = @as(f32x16, @splat(WarlockConstants.ImmolateMana)) * effects_b.shadow_bolt_mana;
            const b_immolate_hit = vAnd16(b_cast_finished, vAnd16(c_id_b == @as(u32x16, @splat(13)), mana_b >= b_immolate_cost));
            mana_b = select16(b_immolate_hit, mana_b - b_immolate_cost, mana_b);
            @import("projectiles.zig").launchClass(self, false, i, 13, (@as(f32x16, @splat(WarlockConstants.ImmolateInitialDamage)) + @import("spell_resolution.zig").spellPower(self, false, i, .fire) * @as(f32x16, @splat(0.2))) * effects_b.immolate_initial_damage, b_immolate_hit, .warlock);

            const b_fear_cost = @as(f32x16, @splat(WarlockConstants.FearMana));
            const b_fear_cast_done = vAnd16(b_cast_finished, vAnd16(c_id_b == @as(u32x16, @splat(3)), mana_b >= b_fear_cost));
            mana_b = select16(b_fear_cast_done, mana_b - b_fear_cost, mana_b);
            const b_fear_hit = @import("periodic.zig").control(self, false, i, b_fear_cast_done, effects_b.spell_hit_bonus, .shadow, false);
            const b_fear_dr_mult = getDrMultiplier(fear_dr_t_a);
            const b_fear_dur = @as(f32x16, @splat(WarlockConstants.FearDuration)) * b_fear_dr_mult;
            fear_a = select16(b_fear_hit, b_fear_dur, fear_a);
            fear_dr_t_a = select16(b_fear_hit, @min(@as(f32x16, @splat(3.0)), fear_dr_t_a + @as(f32x16, @splat(1.0))), fear_dr_t_a);
            fear_dr_tmr_a = select16(b_fear_hit, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), fear_dr_tmr_a);
            fear_dmg_a = select16(b_fear_hit, v_zeros, fear_dmg_a);

            c_id_b = @select(u32, b_cast_finished, v_zeros_u32, c_id_b);
            c_tmr_b = select16(b_cast_finished, v_zeros, c_tmr_b);
            c_tot_b = select16(b_cast_finished, v_zeros, c_tot_b);
            r_tmr_b = select16(b_cast_finished, v_zeros, r_tmr_b);

            const succubus_kind = @import("pets.zig").Kind.succubus;
            const seduce_hit_a = @import("periodic.zig").control(self, true, i, vAnd16(seduction_cast_done_a, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.SeductionRange)), vAnd16(self.pet_kind_a[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(succubus_kind))), self.pet_hp_a[i..][0..VEC_LEN].* > v_zeros))), @as(f32x16, @splat(0)), .shadow, true);
            const seduce_hit_b = @import("periodic.zig").control(self, false, i, vAnd16(seduction_cast_done_b, vAnd16(dist <= @as(f32x16, @splat(WarlockConstants.SeductionRange)), vAnd16(self.pet_kind_b[i..][0..VEC_LEN].* == @as(u32x16, @splat(@intFromEnum(succubus_kind))), self.pet_hp_b[i..][0..VEC_LEN].* > v_zeros))), @as(f32x16, @splat(0)), .shadow, true);
            const seduce_dur_a = @as(f32x16, @splat(WarlockConstants.SeductionDuration)) * effects_a.seduction_duration_mult * getDrMultiplier(seduction_dr_t_b);
            const seduce_dur_b = @as(f32x16, @splat(WarlockConstants.SeductionDuration)) * effects_b.seduction_duration_mult * getDrMultiplier(seduction_dr_t_a);
            const seduce_applied_a = vAnd16(seduce_hit_a, seduce_dur_a > v_zeros);
            const seduce_applied_b = vAnd16(seduce_hit_b, seduce_dur_b > v_zeros);
            seduction_b = select16(seduce_applied_a, seduce_dur_a, seduction_b);
            seduction_a = select16(seduce_applied_b, seduce_dur_b, seduction_a);
            seduced_b = @select(u32, seduce_applied_a, @as(u32x16, @splat(1)), seduced_b);
            seduced_a = @select(u32, seduce_applied_b, @as(u32x16, @splat(1)), seduced_a);
            seduction_dr_t_b = select16(seduce_hit_a, @min(@as(f32x16, @splat(3.0)), seduction_dr_t_b + @as(f32x16, @splat(1.0))), seduction_dr_t_b);
            seduction_dr_tmr_b = select16(seduce_hit_a, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), seduction_dr_tmr_b);
            seduction_dr_t_a = select16(seduce_hit_b, @min(@as(f32x16, @splat(3.0)), seduction_dr_t_a + @as(f32x16, @splat(1.0))), seduction_dr_t_a);
            seduction_dr_tmr_a = select16(seduce_hit_b, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), seduction_dr_tmr_a);
            c_id_b = @select(u32, seduce_applied_a, v_zeros_u32, c_id_b);
            c_tmr_b = select16(seduce_applied_a, v_zeros, c_tmr_b);
            c_tot_b = select16(seduce_applied_a, v_zeros, c_tot_b);
            c_id_a = @select(u32, seduce_applied_b, v_zeros_u32, c_id_a);
            c_tmr_a = select16(seduce_applied_b, v_zeros, c_tmr_a);
            c_tot_a = select16(seduce_applied_b, v_zeros, c_tot_a);

            // Improved Shadow Bolt (ISB) vulnerability on Shadow damage taken
            const v_ones: f32x16 = @splat(1.0);
            const isb_active_a = vAnd16(self.isb_timer_a[i..][0..VEC_LEN].* > v_zeros, self.isb_charges_a[i..][0..VEC_LEN].* > v_zeros);
            const isb_mult_a = select16(isb_active_a, v_ones + self.isb_vuln_a[i..][0..VEC_LEN].*, v_ones);
            const isb_active_b = vAnd16(self.isb_timer_b[i..][0..VEC_LEN].* > v_zeros, self.isb_charges_b[i..][0..VEC_LEN].* > v_zeros);
            const isb_mult_b = select16(isb_active_b, v_ones + self.isb_vuln_b[i..][0..VEC_LEN].*, v_ones);

            const eff_dmg_ago_a = dmg_ago_a * isb_mult_a;
            const eff_dmg_crp_a = dmg_crp_a * isb_mult_a;
            const eff_dmg_siph_a = dmg_siph_a * isb_mult_a;
            const eff_b_drain_dmg = b_drain_dmg * isb_mult_a;
            const eff_b_sb_dmg = ((hits_b.bolt * isb_mult_a) + hits_b.lance + (hits_b.coil * isb_mult_a) + hits_b.conflagrate) * mit_a;

            const eff_dmg_ago_b = dmg_ago_b * isb_mult_b;
            const eff_dmg_crp_b = dmg_crp_b * isb_mult_b;
            const eff_dmg_siph_b = dmg_siph_b * isb_mult_b;
            const eff_a_drain_dmg = a_drain_dmg * isb_mult_b;
            const eff_a_sb_dmg = ((hits_a.bolt * isb_mult_b) + hits_a.lance + (hits_a.coil * isb_mult_b) + hits_a.conflagrate) * mit_b;

            // Consume charges on Shadow damage instances
            const shadow_hit_on_a = vOr16(dmg_ago_a > v_zeros, vOr16(dmg_crp_a > v_zeros, vOr16(dmg_siph_a > v_zeros, vOr16(b_drain_dmg > v_zeros, vOr16(hits_b.bolt > v_zeros, hits_b.coil > v_zeros)))));
            const shadow_hit_on_b = vOr16(dmg_ago_b > v_zeros, vOr16(dmg_crp_b > v_zeros, vOr16(dmg_siph_b > v_zeros, vOr16(a_drain_dmg > v_zeros, vOr16(hits_a.bolt > v_zeros, hits_a.coil > v_zeros)))));
            const new_charges_a = @max(v_zeros, self.isb_charges_a[i..][0..VEC_LEN].* - select16(shadow_hit_on_a, v_ones, v_zeros));
            self.isb_charges_a[i..][0..VEC_LEN].* = select16(isb_active_a, new_charges_a, self.isb_charges_a[i..][0..VEC_LEN].*);
            self.isb_timer_a[i..][0..VEC_LEN].* = select16(vAnd16(isb_active_a, new_charges_a <= v_zeros), v_zeros, self.isb_timer_a[i..][0..VEC_LEN].*);
            const new_charges_b = @max(v_zeros, self.isb_charges_b[i..][0..VEC_LEN].* - select16(shadow_hit_on_b, v_ones, v_zeros));
            self.isb_charges_b[i..][0..VEC_LEN].* = select16(isb_active_b, new_charges_b, self.isb_charges_b[i..][0..VEC_LEN].*);
            self.isb_timer_b[i..][0..VEC_LEN].* = select16(vAnd16(isb_active_b, new_charges_b <= v_zeros), v_zeros, self.isb_timer_b[i..][0..VEC_LEN].*);

            // 7. Apply Damage to HP
            const total_dmg_to_a = eff_dmg_ago_a + eff_dmg_crp_a + dmg_immolate_a + hits_b.immolate * mit_a + eff_dmg_siph_a + eff_b_drain_dmg + eff_b_sb_dmg + pet_b * pet_mit_a;
            const total_dmg_to_b = eff_dmg_ago_b + eff_dmg_crp_b + dmg_immolate_b + hits_a.immolate * mit_b + eff_dmg_siph_b + eff_a_drain_dmg + eff_a_sb_dmg + pet_a * pet_mit_b;
            seduction_a = select16(total_dmg_to_a > v_zeros, v_zeros, seduction_a);
            seduction_b = select16(total_dmg_to_b > v_zeros, v_zeros, seduction_b);
            seduced_a = @select(u32, total_dmg_to_a > v_zeros, v_zeros_u32, seduced_a);
            seduced_b = @select(u32, total_dmg_to_b > v_zeros, v_zeros_u32, seduced_b);
            immolate_a = select16(hits_b.immolate > v_zeros, @as(f32x16, @splat(WarlockConstants.ImmolateDuration)), immolate_a);
            immolate_b = select16(hits_a.immolate > v_zeros, @as(f32x16, @splat(WarlockConstants.ImmolateDuration)), immolate_b);
            const incoming_a = total_dmg_to_a;
            const incoming_b = total_dmg_to_b;

            // Soul Link damage split (30% transferred to active pet)
            const pet_live_a = self.pet_hp_a[i..][0..VEC_LEN].* > v_zeros;
            const sl_active_a = vAnd16(pet_live_a, self.soul_link_a[i..][0..VEC_LEN].* != v_zeros_u32);
            const sl_split_a = select16(sl_active_a, total_dmg_to_a * @as(f32x16, @splat(0.30)), v_zeros);
            const direct_dmg_a = total_dmg_to_a - sl_split_a;
            self.pet_hp_a[i..][0..VEC_LEN].* = @max(v_zeros, self.pet_hp_a[i..][0..VEC_LEN].* - sl_split_a);

            const pet_live_b = self.pet_hp_b[i..][0..VEC_LEN].* > v_zeros;
            const sl_active_b = vAnd16(pet_live_b, self.soul_link_b[i..][0..VEC_LEN].* != v_zeros_u32);
            const sl_split_b = select16(sl_active_b, total_dmg_to_b * @as(f32x16, @splat(0.30)), v_zeros);
            const direct_dmg_b = total_dmg_to_b - sl_split_b;
            self.pet_hp_b[i..][0..VEC_LEN].* = @max(v_zeros, self.pet_hp_b[i..][0..VEC_LEN].* - sl_split_b);

            @import("projectiles.zig").recordHits(self, false, i, hits_b, mit_a, incoming_a, @min(@as(f32x16, hp_a), total_dmg_to_a));
            @import("pets.zig").recordDamage(self, false, i, pet_b * pet_mit_a, incoming_a, @min(@as(f32x16, hp_a), total_dmg_to_a));
            hp_a = @max(v_zeros, hp_a - direct_dmg_a);
            @import("projectiles.zig").recordHits(self, true, i, hits_a, mit_b, incoming_b, @min(@as(f32x16, hp_b), total_dmg_to_b));
            @import("pets.zig").recordDamage(self, true, i, pet_a * pet_mit_b, incoming_b, @min(@as(f32x16, hp_b), total_dmg_to_b));
            hp_b = @max(v_zeros, hp_b - direct_dmg_b);

            // Fear damage break threshold check
            fear_dmg_a = fear_dmg_a + total_dmg_to_a;
            fear_a = select16(fear_dmg_a >= @as(f32x16, @splat(WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_a);

            fear_dmg_b = fear_dmg_b + total_dmg_to_b;
            fear_b = select16(fear_dmg_b >= @as(f32x16, @splat(WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_b);

            @import("pushback.zig").reset(self, true, i, c_id_a == v_zeros_u32);
            @import("pushback.zig").reset(self, false, i, c_id_b == v_zeros_u32);

            // 8. Duel Liveness & Writeback
            const duel_alive = vAnd16(hp_a > v_zeros, hp_b > v_zeros);
            const v_duel_act: u32x16 = @select(u32, duel_alive, v_ones_u32, v_zeros_u32);

            self.distance[i..][0..VEC_LEN].* = dist;
            self.hp_a[i..][0..VEC_LEN].* = hp_a;
            self.hp_b[i..][0..VEC_LEN].* = hp_b;
            self.mana_a[i..][0..VEC_LEN].* = mana_a;
            self.mana_b[i..][0..VEC_LEN].* = mana_b;
            self.gcd_a[i..][0..VEC_LEN].* = gcd_a;
            self.gcd_b[i..][0..VEC_LEN].* = gcd_b;
            self.react_timer_a[i..][0..VEC_LEN].* = r_tmr_a;
            self.react_timer_b[i..][0..VEC_LEN].* = r_tmr_b;

            self.cast_id_a[i..][0..VEC_LEN].* = c_id_a;
            self.cast_timer_a[i..][0..VEC_LEN].* = c_tmr_a;
            self.cast_total_a[i..][0..VEC_LEN].* = c_tot_a;

            self.cast_id_b[i..][0..VEC_LEN].* = c_id_b;
            self.cast_timer_b[i..][0..VEC_LEN].* = c_tmr_b;
            self.cast_total_b[i..][0..VEC_LEN].* = c_tot_b;

            self.agony_timer_a[i..][0..VEC_LEN].* = ago_a;
            self.immolate_timer_a[i..][0..VEC_LEN].* = immolate_a;
            self.corruption_timer_a[i..][0..VEC_LEN].* = crp_a;
            self.siphon_timer_a[i..][0..VEC_LEN].* = siph_a;
            self.fear_timer_a[i..][0..VEC_LEN].* = fear_a;
            self.seduction_timer_a[i..][0..VEC_LEN].* = seduction_a;
            self.fear_accum_dmg_a[i..][0..VEC_LEN].* = fear_dmg_a;
            self.seduced_a[i..][0..VEC_LEN].* = seduced_a;
            self.horror_timer_a[i..][0..VEC_LEN].* = horror_a;

            self.agony_timer_b[i..][0..VEC_LEN].* = ago_b;
            self.immolate_timer_b[i..][0..VEC_LEN].* = immolate_b;
            self.corruption_timer_b[i..][0..VEC_LEN].* = crp_b;
            self.siphon_timer_b[i..][0..VEC_LEN].* = siph_b;
            self.fear_timer_b[i..][0..VEC_LEN].* = fear_b;
            self.seduction_timer_b[i..][0..VEC_LEN].* = seduction_b;
            self.fear_accum_dmg_b[i..][0..VEC_LEN].* = fear_dmg_b;
            self.seduced_b[i..][0..VEC_LEN].* = seduced_b;
            self.horror_timer_b[i..][0..VEC_LEN].* = horror_b;

            self.action6_cd_a[i..][0..VEC_LEN].* = un_cd_a;
            self.action6_dur_a[i..][0..VEC_LEN].* = un_dur_a;
            self.death_coil_cd_a[i..][0..VEC_LEN].* = dc_cd_a;
            self.shadowburn_cd_a[i..][0..VEC_LEN].* = sb_cd_a;
            self.seduction_cd_a[i..][0..VEC_LEN].* = seduction_cd_a;
            self.seduction_cast_a[i..][0..VEC_LEN].* = seduction_cast_a;
            self.fear_dr_tier_a[i..][0..VEC_LEN].* = fear_dr_t_a;
            self.fear_dr_timer_a[i..][0..VEC_LEN].* = fear_dr_tmr_a;
            self.seduction_dr_tier_a[i..][0..VEC_LEN].* = seduction_dr_t_a;
            self.seduction_dr_timer_a[i..][0..VEC_LEN].* = seduction_dr_tmr_a;
            self.horror_dr_tier_a[i..][0..VEC_LEN].* = horror_dr_t_a;
            self.horror_dr_timer_a[i..][0..VEC_LEN].* = horror_dr_tmr_a;

            self.action6_cd_b[i..][0..VEC_LEN].* = un_cd_b;
            self.action6_dur_b[i..][0..VEC_LEN].* = un_dur_b;
            self.death_coil_cd_b[i..][0..VEC_LEN].* = dc_cd_b;
            self.shadowburn_cd_b[i..][0..VEC_LEN].* = sb_cd_b;
            self.seduction_cd_b[i..][0..VEC_LEN].* = seduction_cd_b;
            self.seduction_cast_b[i..][0..VEC_LEN].* = seduction_cast_b;
            self.fear_dr_tier_b[i..][0..VEC_LEN].* = fear_dr_t_b;
            self.fear_dr_timer_b[i..][0..VEC_LEN].* = fear_dr_tmr_b;
            self.seduction_dr_tier_b[i..][0..VEC_LEN].* = seduction_dr_t_b;
            self.seduction_dr_timer_b[i..][0..VEC_LEN].* = seduction_dr_tmr_b;
            self.horror_dr_tier_b[i..][0..VEC_LEN].* = horror_dr_t_b;
            self.horror_dr_timer_b[i..][0..VEC_LEN].* = horror_dr_tmr_b;

            self.is_active[i..][0..VEC_LEN].* = v_duel_act;
            @import("racials.zig").tick(self, i, dt);

            active_duels_sum += @reduce(.Add, v_duel_act);
        }

        return active_duels_sum;
    }
};

test "WarlockArenaPool initialization and tick" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 32);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 32), pool.capacity);
    const active = pool.tickPhysics(0.010);
    try std.testing.expectEqual(@as(usize, 32), active);
}

test "Single SIMD batch physics leaves neighboring duels untouched" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 48);
    defer pool.deinit();
    for (0..48) |lane| pool.resetDuel(lane);
    const before_a = pool.mana_a[0];
    const before_b = pool.mana_a[32];
    pool.mana_a[16] = 0;
    _ = pool.tickPhysics16(0.01, 16);
    try std.testing.expectEqual(before_a, pool.mana_a[0]);
    try std.testing.expectEqual(before_b, pool.mana_a[32]);
    try std.testing.expect(pool.mana_a[16] > 0);
}

test "projectile speed delays damage according to distance" {
    inline for (.{ @as(f32, 10), @as(f32, 30) }) |distance| {
        var pool = try WarlockArenaPool.init(std.testing.allocator, 16);
        defer pool.deinit();
        @memset(pool.distance, distance);
        @memset(pool.pos_x_a, -distance * 0.5);
        @memset(pool.pos_x_b, distance * 0.5);
        @import("projectiles.zig").launchClass(&pool, true, 0, 4, @splat(240), @splat(true), .warlock);
        _ = pool.tickPhysics16(0.3, 0);
        try std.testing.expectEqual(@as(f32, 2000), pool.hp_b[0]);
        try std.testing.expectApproxEqAbs(-distance * 0.5 + 9, pool.projectile_0_x_a[0], 0.0001);
        _ = pool.tickPhysics16(distance / 30 - 0.3 + 0.001, 0);
        try std.testing.expectEqual(@as(f32, 1760), pool.hp_b[0]);
        try std.testing.expectEqual(@as(f32, 0), pool.projectile_0_spell_a[0]);
        try std.testing.expectEqual(@as(f32, 240), pool.impact_bolt_a[0]);
    }
}

test "missiles home in 2D and retain constant speed after target displacement" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 32);
    defer pool.deinit();
    @import("projectiles.zig").launchClass(&pool, true, 0, 4, @splat(240), @splat(true), .warlock);
    _ = pool.tickPhysics16(0.1, 0);
    pool.pos_y_b[0] = 10;
    _ = @import("movement_2d.zig").refresh(&pool, 0, true);
    const x = pool.projectile_0_x_a[0];
    const y = pool.projectile_0_y_a[0];
    _ = pool.tickPhysics16(0.1, 0);
    const dx = pool.projectile_0_x_a[0] - x;
    const dy = pool.projectile_0_y_a[0] - y;
    try std.testing.expect(dy > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 3), @sqrt(dx * dx + dy * dy), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), pool.projectile_0_spell_a[16]);
    try std.testing.expectEqual(@as(f32, 2000), pool.hp_b[16]);
}

test "healthstone does not mitigate damage on impact" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    pool.applyActionA(0, @splat(7), @splat(0));
    _ = pool.tickPhysics16(0.1, 0);
    try std.testing.expectEqual(@as(f32, 2000), pool.hp_b[0]);
    pool.applyActionB(0, @splat(6), @splat(0));
    _ = pool.tickPhysics16(1.2, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 2000 - WarlockConstants.DeathCoilDamage), pool.hp_b[0], 0.0001);
    try std.testing.expect(pool.horror_timer_b[0] > 0);
}

test "healthstone is unavailable at full health and heals up to 1200" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();

    try std.testing.expect(!pool.getActionMaskA(0)[@intFromEnum(WarlockAction.Healthstone)][0]);
    try std.testing.expect(!pool.getActionMaskB(0)[@intFromEnum(WarlockAction.Healthstone)][0]);

    pool.hp_a[0] = 700;
    pool.hp_b[0] = 1999;
    try std.testing.expect(pool.getActionMaskA(0)[@intFromEnum(WarlockAction.Healthstone)][0]);
    try std.testing.expect(pool.getActionMaskB(0)[@intFromEnum(WarlockAction.Healthstone)][0]);

    pool.applyActionA(0, @splat(@intFromEnum(WarlockAction.Healthstone)), @splat(0));
    pool.applyActionB(0, @splat(@intFromEnum(WarlockAction.Healthstone)), @splat(0));
    try std.testing.expectEqual(@as(f32, 1900), pool.hp_a[0]);
    try std.testing.expectEqual(WarlockConstants.MaxHp, pool.hp_b[0]);
    try std.testing.expectEqual(WarlockConstants.HealthstoneCooldown, pool.action6_cd_a[0]);
    try std.testing.expectEqual(WarlockConstants.HealthstoneCooldown, pool.action6_cd_b[0]);
}

test "fixed projectile queue masks launches when full and frees slots on impact" {
    var pool = try WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    for (0..4) |_| @import("projectiles.zig").launchClass(&pool, true, 0, 4, @splat(240), @splat(true), .warlock);
    try std.testing.expectEqual(@as(f32, 4), pool.projectile_count_a[0]);
    try std.testing.expect(!pool.getActionMaskA(0)[4][0]);
    try std.testing.expect(!pool.getActionMaskA(0)[7][0]);
    _ = pool.tickPhysics16(0.9, 0);
    try std.testing.expectEqual(@as(f32, 1040), pool.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 0), pool.projectile_count_a[0]);
    try std.testing.expect(pool.getActionMaskA(0)[4][0]);
    try std.testing.expectEqual(@as(u32, 1), pool.impact_mask_a[0]);
}
