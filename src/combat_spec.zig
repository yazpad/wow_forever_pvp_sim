const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");

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

/// Actions available to the Warlock spec (and future caster/hybrid specs)
pub const WarlockAction = enum(u32) {
    IdleOrManeuver = 0,    // Move or hold distance without casting
    Agony = 1,             // Instant DOT, castable while moving
    Corruption = 2,        // Instant DOT, castable while moving
    Fear = 3,              // 1.5s Hard cast, stationary only, interrupts & CCs target
    ShadowBolt = 4,        // 1.8s Hard cast, stationary only, heavy direct damage
    DrainLife = 5,         // 3.0s Channel, stationary only, siphon damage + self-heal
    UnendingResolve = 6,   // Instant defensive buff, 45s CD, -40% damage taken for 6s
    DeathCoil = 7,         // Instant 30m, 45s CD, 180 dmg, 300 heal, 3s Horror CC
    CancelCast = 8,        // Instant cancel active cast (fake-casting / emergency run)

    pub const COUNT: usize = 9;
};

/// Movement intention commanded by policy or maneuver
pub const MoveIntent = enum(i32) {
    Advance = -1, // Close distance towards target (-7.0 m/s)
    Stand = 0,    // Stand stationary (0.0 m/s)
    Kite = 1,     // Backpedal/kite away (+4.5 m/s)
};

pub const WarlockConstants = struct {
    pub const MaxHp: f32 = 2000.0;
    pub const MaxMana: f32 = 1000.0;
    pub const ManaRegenPerSec: f32 = 15.0;

    pub const ForwardSpeed: f32 = 7.0;  // m/s
    pub const BackpedalSpeed: f32 = 4.5; // m/s
    pub const MinDistance: f32 = 1.0;   // m (melee point-blank)
    pub const MaxDistance: f32 = 35.0;  // m (arena boundary)

    pub const StandardGcd: f32 = 1.0;   // seconds
    pub const ReactionInterval: f32 = 0.100; // 100ms cognitive interval

    // Spell Parameters
    pub const AgonyMana: f32 = 30.0;
    pub const AgonyDuration: f32 = 18.0;
    pub const AgonyDps: f32 = 30.0; // base DPS

    pub const CorruptionMana: f32 = 40.0;
    pub const CorruptionDuration: f32 = 14.0;
    pub const CorruptionDps: f32 = 50.0;

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

    pub const UnendingResolveCooldown: f32 = 45.0;
    pub const UnendingResolveDuration: f32 = 6.0;
    pub const UnendingResolveDamageReduction: f32 = 0.40; // 40% reduction

    pub const DeathCoilMana: f32 = 50.0;
    pub const DeathCoilCooldown: f32 = 45.0;
    pub const DeathCoilDuration: f32 = 3.0; // 3.0s Horror
    pub const DeathCoilDamage: f32 = 180.0;
    pub const DeathCoilHeal: f32 = 300.0;
    pub const DeathCoilRange: f32 = 30.0;

    pub const DrResetDuration: f32 = 18.0; // DR window resets after 18s without new CC
};

/// Helper to branchlessly compute Diminishing Returns multiplier:
/// Tier 0 = 1.0 (Full), Tier 1 = 0.5 (Half), Tier 2 = 0.25 (Quarter), Tier >= 3 = 0.0 (Immune)
pub inline fn getDrMultiplier(tier: f32x16) f32x16 {
    const v_zeros: f32x16 = @splat(0.0);
    const v_half: f32x16 = @splat(0.5);
    const v_quarter: f32x16 = @splat(0.25);
    const v_one: f32x16 = @splat(1.0);

    return select16(tier < @as(f32x16, @splat(0.5)), v_one,
           select16(tier < @as(f32x16, @splat(1.5)), v_half,
           select16(tier < @as(f32x16, @splat(2.5)), v_quarter,
           v_zeros)));
}

/// 64-byte aligned Structure-of-Arrays combat pool for Vectorized Warlock PvP Duels.
/// Every batch contains `capacity` duel pairs (A vs B).
pub const WarlockArenaPool = struct {
    count: usize,
    capacity: usize,
    allocator: mem.Allocator,

    // Shared Arena Geometry between A and B
    distance: []align(ALIGNMENT) f32, // meters between Unit A and Unit B

    // Unit A SoA Columns
    hp_a: []align(ALIGNMENT) f32,
    mana_a: []align(ALIGNMENT) f32,
    gcd_a: []align(ALIGNMENT) f32,
    react_timer_a: []align(ALIGNMENT) f32, // seconds until next cognitive decision
    move_intent_a: []align(ALIGNMENT) f32, // -1 (advance), 0 (stationary), +1 (kite)

    cast_id_a: []align(ALIGNMENT) u32,     // 0 = none, 3 = Fear, 4 = ShadowBolt, 5 = DrainLife
    cast_timer_a: []align(ALIGNMENT) f32,  // remaining seconds on active cast
    cast_total_a: []align(ALIGNMENT) f32,  // total duration of cast

    // Debuffs on A (inflicted by B)
    agony_timer_a: []align(ALIGNMENT) f32,
    corruption_timer_a: []align(ALIGNMENT) f32,
    fear_timer_a: []align(ALIGNMENT) f32,
    fear_accum_dmg_a: []align(ALIGNMENT) f32,
    horror_timer_a: []align(ALIGNMENT) f32,

    // Buffs / Cooldowns on A
    unending_cd_a: []align(ALIGNMENT) f32,
    unending_dur_a: []align(ALIGNMENT) f32,
    death_coil_cd_a: []align(ALIGNMENT) f32,

    // Diminishing Returns tracking on A
    fear_dr_tier_a: []align(ALIGNMENT) f32,   // 0.0=100%, 1.0=50%, 2.0=25%, 3.0=Immune
    fear_dr_timer_a: []align(ALIGNMENT) f32,  // countdown from 18s
    horror_dr_tier_a: []align(ALIGNMENT) f32, // 0.0=100%, 1.0=50%, 2.0=25%, 3.0=Immune
    horror_dr_timer_a: []align(ALIGNMENT) f32, // countdown from 18s

    // Unit B SoA Columns
    hp_b: []align(ALIGNMENT) f32,
    mana_b: []align(ALIGNMENT) f32,
    gcd_b: []align(ALIGNMENT) f32,
    react_timer_b: []align(ALIGNMENT) f32,
    move_intent_b: []align(ALIGNMENT) f32,

    cast_id_b: []align(ALIGNMENT) u32,
    cast_timer_b: []align(ALIGNMENT) f32,
    cast_total_b: []align(ALIGNMENT) f32,

    // Debuffs on B (inflicted by A)
    agony_timer_b: []align(ALIGNMENT) f32,
    corruption_timer_b: []align(ALIGNMENT) f32,
    fear_timer_b: []align(ALIGNMENT) f32,
    fear_accum_dmg_b: []align(ALIGNMENT) f32,
    horror_timer_b: []align(ALIGNMENT) f32,

    // Buffs / Cooldowns on B
    unending_cd_b: []align(ALIGNMENT) f32,
    unending_dur_b: []align(ALIGNMENT) f32,
    death_coil_cd_b: []align(ALIGNMENT) f32,

    // Diminishing Returns tracking on B
    fear_dr_tier_b: []align(ALIGNMENT) f32,
    fear_dr_timer_b: []align(ALIGNMENT) f32,
    horror_dr_tier_b: []align(ALIGNMENT) f32,
    horror_dr_timer_b: []align(ALIGNMENT) f32,

    // Duel State: 1 = active, 0 = duel concluded
    is_active: []align(ALIGNMENT) u32,

    pub fn init(allocator: mem.Allocator, capacity: usize) !WarlockArenaPool {
        const padded_cap = (capacity + VEC_LEN - 1) & ~@as(usize, VEC_LEN - 1);

        const dist = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dist);

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
        const crp_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(crp_a);
        const fear_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_a);
        const fear_dmg_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dmg_a);
        const horror_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_a);

        const un_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_cd_a);
        const un_dur_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_dur_a);
        const dc_cd_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dc_cd_a);

        const fear_dr_t_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_t_a);
        const fear_dr_tmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_tmr_a);
        const horror_dr_t_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_t_a);
        const horror_dr_tmr_a = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_tmr_a);

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
        const crp_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(crp_b);
        const fear_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_b);
        const fear_dmg_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dmg_b);
        const horror_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_b);

        const un_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_cd_b);
        const un_dur_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(un_dur_b);
        const dc_cd_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dc_cd_b);

        const fear_dr_t_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_t_b);
        const fear_dr_tmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(fear_dr_tmr_b);
        const horror_dr_t_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_t_b);
        const horror_dr_tmr_b = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(horror_dr_tmr_b);

        const is_act = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(is_act);

        var pool = WarlockArenaPool{
            .count = 0,
            .capacity = padded_cap,
            .allocator = allocator,
            .distance = dist,
            .hp_a = hp_a,
            .mana_a = mana_a,
            .gcd_a = gcd_a,
            .react_timer_a = react_a,
            .move_intent_a = move_a,
            .cast_id_a = cid_a,
            .cast_timer_a = ctmr_a,
            .cast_total_a = ctot_a,
            .agony_timer_a = ago_a,
            .corruption_timer_a = crp_a,
            .fear_timer_a = fear_a,
            .fear_accum_dmg_a = fear_dmg_a,
            .horror_timer_a = horror_a,
            .unending_cd_a = un_cd_a,
            .unending_dur_a = un_dur_a,
            .death_coil_cd_a = dc_cd_a,
            .fear_dr_tier_a = fear_dr_t_a,
            .fear_dr_timer_a = fear_dr_tmr_a,
            .horror_dr_tier_a = horror_dr_t_a,
            .horror_dr_timer_a = horror_dr_tmr_a,

            .hp_b = hp_b,
            .mana_b = mana_b,
            .gcd_b = gcd_b,
            .react_timer_b = react_b,
            .move_intent_b = move_b,
            .cast_id_b = cid_b,
            .cast_timer_b = ctmr_b,
            .cast_total_b = ctot_b,
            .agony_timer_b = ago_b,
            .corruption_timer_b = crp_b,
            .fear_timer_b = fear_b,
            .fear_accum_dmg_b = fear_dmg_b,
            .horror_timer_b = horror_b,
            .unending_cd_b = un_cd_b,
            .unending_dur_b = un_dur_b,
            .death_coil_cd_b = dc_cd_b,
            .fear_dr_tier_b = fear_dr_t_b,
            .fear_dr_timer_b = fear_dr_tmr_b,
            .horror_dr_tier_b = horror_dr_t_b,
            .horror_dr_timer_b = horror_dr_tmr_b,
            .is_active = is_act,
        };

        pool.resetAll();
        return pool;
    }

    pub fn deinit(self: *WarlockArenaPool) void {
        self.allocator.free(self.distance);
        self.allocator.free(self.hp_a);
        self.allocator.free(self.mana_a);
        self.allocator.free(self.gcd_a);
        self.allocator.free(self.react_timer_a);
        self.allocator.free(self.move_intent_a);
        self.allocator.free(self.cast_id_a);
        self.allocator.free(self.cast_timer_a);
        self.allocator.free(self.cast_total_a);
        self.allocator.free(self.agony_timer_a);
        self.allocator.free(self.corruption_timer_a);
        self.allocator.free(self.fear_timer_a);
        self.allocator.free(self.fear_accum_dmg_a);
        self.allocator.free(self.horror_timer_a);
        self.allocator.free(self.unending_cd_a);
        self.allocator.free(self.unending_dur_a);
        self.allocator.free(self.death_coil_cd_a);
        self.allocator.free(self.fear_dr_tier_a);
        self.allocator.free(self.fear_dr_timer_a);
        self.allocator.free(self.horror_dr_tier_a);
        self.allocator.free(self.horror_dr_timer_a);

        self.allocator.free(self.hp_b);
        self.allocator.free(self.mana_b);
        self.allocator.free(self.gcd_b);
        self.allocator.free(self.react_timer_b);
        self.allocator.free(self.move_intent_b);
        self.allocator.free(self.cast_id_b);
        self.allocator.free(self.cast_timer_b);
        self.allocator.free(self.cast_total_b);
        self.allocator.free(self.agony_timer_b);
        self.allocator.free(self.corruption_timer_b);
        self.allocator.free(self.fear_timer_b);
        self.allocator.free(self.fear_accum_dmg_b);
        self.allocator.free(self.horror_timer_b);
        self.allocator.free(self.unending_cd_b);
        self.allocator.free(self.unending_dur_b);
        self.allocator.free(self.death_coil_cd_b);
        self.allocator.free(self.fear_dr_tier_b);
        self.allocator.free(self.fear_dr_timer_b);
        self.allocator.free(self.horror_dr_tier_b);
        self.allocator.free(self.horror_dr_timer_b);
        self.allocator.free(self.is_active);
    }

    pub fn resetAll(self: *WarlockArenaPool) void {
        @memset(self.distance, 25.0); // start 25m apart

        @memset(self.hp_a, WarlockConstants.MaxHp);
        @memset(self.mana_a, WarlockConstants.MaxMana);
        @memset(self.gcd_a, 0.0);
        @memset(self.react_timer_a, 0.0);
        @memset(self.move_intent_a, 0.0);
        @memset(self.cast_id_a, 0);
        @memset(self.cast_timer_a, 0.0);
        @memset(self.cast_total_a, 0.0);
        @memset(self.agony_timer_a, 0.0);
        @memset(self.corruption_timer_a, 0.0);
        @memset(self.fear_timer_a, 0.0);
        @memset(self.fear_accum_dmg_a, 0.0);
        @memset(self.horror_timer_a, 0.0);
        @memset(self.unending_cd_a, 0.0);
        @memset(self.unending_dur_a, 0.0);
        @memset(self.death_coil_cd_a, 0.0);
        @memset(self.fear_dr_tier_a, 0.0);
        @memset(self.fear_dr_timer_a, 0.0);
        @memset(self.horror_dr_tier_a, 0.0);
        @memset(self.horror_dr_timer_a, 0.0);

        @memset(self.hp_b, WarlockConstants.MaxHp);
        @memset(self.mana_b, WarlockConstants.MaxMana);
        @memset(self.gcd_b, 0.0);
        @memset(self.react_timer_b, 0.0);
        @memset(self.move_intent_b, 0.0);
        @memset(self.cast_id_b, 0);
        @memset(self.cast_timer_b, 0.0);
        @memset(self.cast_total_b, 0.0);
        @memset(self.agony_timer_b, 0.0);
        @memset(self.corruption_timer_b, 0.0);
        @memset(self.fear_timer_b, 0.0);
        @memset(self.fear_accum_dmg_b, 0.0);
        @memset(self.horror_timer_b, 0.0);
        @memset(self.unending_cd_b, 0.0);
        @memset(self.unending_dur_b, 0.0);
        @memset(self.death_coil_cd_b, 0.0);
        @memset(self.fear_dr_tier_b, 0.0);
        @memset(self.fear_dr_timer_b, 0.0);
        @memset(self.horror_dr_tier_b, 0.0);
        @memset(self.horror_dr_timer_b, 0.0);

        @memset(self.is_active, 1);
    }

    pub fn resetDuel(self: *WarlockArenaPool, i: usize) void {
        self.distance[i] = 25.0;
        self.hp_a[i] = WarlockConstants.MaxHp;
        self.mana_a[i] = WarlockConstants.MaxMana;
        self.gcd_a[i] = 0.0;
        self.react_timer_a[i] = 0.0;
        self.move_intent_a[i] = 0.0;
        self.cast_id_a[i] = 0;
        self.cast_timer_a[i] = 0.0;
        self.cast_total_a[i] = 0.0;
        self.agony_timer_a[i] = 0.0;
        self.corruption_timer_a[i] = 0.0;
        self.fear_timer_a[i] = 0.0;
        self.fear_accum_dmg_a[i] = 0.0;
        self.horror_timer_a[i] = 0.0;
        self.unending_cd_a[i] = 0.0;
        self.unending_dur_a[i] = 0.0;
        self.death_coil_cd_a[i] = 0.0;
        self.fear_dr_tier_a[i] = 0.0;
        self.fear_dr_timer_a[i] = 0.0;
        self.horror_dr_tier_a[i] = 0.0;
        self.horror_dr_timer_a[i] = 0.0;

        self.hp_b[i] = WarlockConstants.MaxHp;
        self.mana_b[i] = WarlockConstants.MaxMana;
        self.gcd_b[i] = 0.0;
        self.react_timer_b[i] = 0.0;
        self.move_intent_b[i] = 0.0;
        self.cast_id_b[i] = 0;
        self.cast_timer_b[i] = 0.0;
        self.cast_total_b[i] = 0.0;
        self.agony_timer_b[i] = 0.0;
        self.corruption_timer_b[i] = 0.0;
        self.fear_timer_b[i] = 0.0;
        self.fear_accum_dmg_b[i] = 0.0;
        self.horror_timer_b[i] = 0.0;
        self.unending_cd_b[i] = 0.0;
        self.unending_dur_b[i] = 0.0;
        self.death_coil_cd_b[i] = 0.0;
        self.fear_dr_tier_b[i] = 0.0;
        self.fear_dr_timer_b[i] = 0.0;
        self.horror_dr_tier_b[i] = 0.0;
        self.horror_dr_timer_b[i] = 0.0;

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
        const inv_def_cd: f32x16 = @splat(1.0 / WarlockConstants.UnendingResolveCooldown);
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

        const un_cd_a: f32x16 = self.unending_cd_a[i..][0..VEC_LEN].*;
        const un_dur_a: f32x16 = self.unending_dur_a[i..][0..VEC_LEN].*;
        const un_dur_b: f32x16 = self.unending_dur_b[i..][0..VEC_LEN].*;
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
        obs[21] = select16(vOr16(fear_a > v_zeros, horror_a > v_zeros), v_ones, v_zeros);
        obs[22] = select16(vOr16(fear_b > v_zeros, horror_b > v_zeros), v_ones, v_zeros);
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
        const inv_def_cd: f32x16 = @splat(1.0 / WarlockConstants.UnendingResolveCooldown);
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

        const un_cd_b: f32x16 = self.unending_cd_b[i..][0..VEC_LEN].*;
        const un_dur_b: f32x16 = self.unending_dur_b[i..][0..VEC_LEN].*;
        const un_dur_a: f32x16 = self.unending_dur_a[i..][0..VEC_LEN].*;
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
        obs[21] = select16(vOr16(fear_b > v_zeros, horror_b > v_zeros), v_ones, v_zeros);
        obs[22] = select16(vOr16(fear_a > v_zeros, horror_a > v_zeros), v_ones, v_zeros);
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

    /// Branchless action mask: returns bool16 array for action legality across 16 lanes
    pub fn getActionMaskA(self: *const WarlockArenaPool, i: usize) [WarlockAction.COUNT]bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const mana = self.mana_a[i..][0..VEC_LEN].*;
        const gcd = self.gcd_a[i..][0..VEC_LEN].*;
        const dist = self.distance[i..][0..VEC_LEN].*;
        const cast_id = self.cast_id_a[i..][0..VEC_LEN].*;
        const is_casting = cast_id > @as(u32x16, @splat(0));
        const fear = self.fear_timer_a[i..][0..VEC_LEN].*;
        const horror = self.horror_timer_a[i..][0..VEC_LEN].*;
        const is_cc = vOr16(fear > v_zeros, horror > v_zeros);
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
        masks[@intFromEnum(WarlockAction.ShadowBolt)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.ShadowBoltMana))));

        // 5. Drain Life: Channeled, stationary, range 25m, cost 70 mana
        const in_drain_range = dist <= @as(f32x16, @splat(WarlockConstants.DrainLifeRange));
        masks[@intFromEnum(WarlockAction.DrainLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_drain_range, mana >= @as(f32x16, @splat(WarlockConstants.DrainLifeMana)))));

        // 6. Unending Resolve: Instant, off GCD or on GCD (0 GCD cost), CD <= 0
        const un_cd = self.unending_cd_a[i..][0..VEC_LEN].*;
        masks[@intFromEnum(WarlockAction.UnendingResolve)] = vAnd16(vNot16(is_cc), un_cd <= v_zeros);

        // 7. Death Coil: Instant, range 30m, 45s CD, 50 mana
        const dc_cd = self.death_coil_cd_a[i..][0..VEC_LEN].*;
        const in_dc_range = dist <= @as(f32x16, @splat(WarlockConstants.DeathCoilRange));
        masks[@intFromEnum(WarlockAction.DeathCoil)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_dc_range, vAnd16(dc_cd <= v_zeros, mana >= @as(f32x16, @splat(WarlockConstants.DeathCoilMana))))));

        // 8. Cancel Cast: Only legal if actively casting!
        masks[@intFromEnum(WarlockAction.CancelCast)] = is_casting;

        return masks;
    }

    /// Branchless action mask for Unit B
    pub fn getActionMaskB(self: *const WarlockArenaPool, i: usize) [WarlockAction.COUNT]bool16 {
        const v_zeros: f32x16 = @splat(0.0);
        const mana = self.mana_b[i..][0..VEC_LEN].*;
        const gcd = self.gcd_b[i..][0..VEC_LEN].*;
        const dist = self.distance[i..][0..VEC_LEN].*;
        const cast_id = self.cast_id_b[i..][0..VEC_LEN].*;
        const is_casting = cast_id > @as(u32x16, @splat(0));
        const fear = self.fear_timer_b[i..][0..VEC_LEN].*;
        const horror = self.horror_timer_b[i..][0..VEC_LEN].*;
        const is_cc = vOr16(fear > v_zeros, horror > v_zeros);
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
        masks[@intFromEnum(WarlockAction.ShadowBolt)] = vAnd16(can_act, vAnd16(gcd_free, mana >= @as(f32x16, @splat(WarlockConstants.ShadowBoltMana))));

        // 5. Drain Life: Channeled, stationary, range 25m, cost 70 mana
        const in_drain_range = dist <= @as(f32x16, @splat(WarlockConstants.DrainLifeRange));
        masks[@intFromEnum(WarlockAction.DrainLife)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_drain_range, mana >= @as(f32x16, @splat(WarlockConstants.DrainLifeMana)))));

        // 6. Unending Resolve: Instant, off GCD or on GCD (0 GCD cost), CD <= 0
        const un_cd = self.unending_cd_b[i..][0..VEC_LEN].*;
        masks[@intFromEnum(WarlockAction.UnendingResolve)] = vAnd16(vNot16(is_cc), un_cd <= v_zeros);

        // 7. Death Coil: Instant, range 30m, 45s CD, 50 mana
        const dc_cd = self.death_coil_cd_b[i..][0..VEC_LEN].*;
        const in_dc_range = dist <= @as(f32x16, @splat(WarlockConstants.DeathCoilRange));
        masks[@intFromEnum(WarlockAction.DeathCoil)] = vAnd16(can_act, vAnd16(gcd_free, vAnd16(in_dc_range, vAnd16(dc_cd <= v_zeros, mana >= @as(f32x16, @splat(WarlockConstants.DeathCoilMana))))));

        // 8. Cancel Cast: Only legal if actively casting!
        masks[@intFromEnum(WarlockAction.CancelCast)] = is_casting;

        return masks;
    }

    /// Apply commanded actions to Unit A across 16 lanes
    pub fn applyActionA(
        self: *WarlockArenaPool,
        i: usize,
        actions: u32x16,
        move_intents: f32x16,
    ) void {
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_gcd_std: f32x16 = @splat(WarlockConstants.StandardGcd);
        const v_react_std: f32x16 = @splat(WarlockConstants.ReactionInterval);

        var hp_a = self.hp_a[i..][0..VEC_LEN].*;
        var hp_b = self.hp_b[i..][0..VEC_LEN].*;
        var mana_a = self.mana_a[i..][0..VEC_LEN].*;
        var gcd_a = self.gcd_a[i..][0..VEC_LEN].*;
        var cast_id = self.cast_id_a[i..][0..VEC_LEN].*;
        var cast_tmr = self.cast_timer_a[i..][0..VEC_LEN].*;
        var cast_tot = self.cast_total_a[i..][0..VEC_LEN].*;
        var un_cd = self.unending_cd_a[i..][0..VEC_LEN].*;
        var un_dur = self.unending_dur_a[i..][0..VEC_LEN].*;
        var dc_cd_a = self.death_coil_cd_a[i..][0..VEC_LEN].*;
        var move_a = self.move_intent_a[i..][0..VEC_LEN].*;

        // Debuffs applied to Target B
        var ago_b = self.agony_timer_b[i..][0..VEC_LEN].*;
        var crp_b = self.corruption_timer_b[i..][0..VEC_LEN].*;
        var horror_b = self.horror_timer_b[i..][0..VEC_LEN].*;
        var horror_dr_t_b = self.horror_dr_tier_b[i..][0..VEC_LEN].*;
        var horror_dr_tmr_b = self.horror_dr_timer_b[i..][0..VEC_LEN].*;

        // Reset reaction timer upon choosing an action
        self.react_timer_a[i..][0..VEC_LEN].* = v_react_std;

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
        ago_b = select16(is_act1, @as(f32x16, @splat(WarlockConstants.AgonyDuration)), ago_b);
        mana_a = select16(is_act1, mana_a - @as(f32x16, @splat(WarlockConstants.AgonyMana)), mana_a);
        gcd_a = select16(is_act1, v_gcd_std, gcd_a);

        // Action 2: Corruption (Instant while moving)
        const is_act2: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Corruption)));
        crp_b = select16(is_act2, @as(f32x16, @splat(WarlockConstants.CorruptionDuration)), crp_b);
        mana_a = select16(is_act2, mana_a - @as(f32x16, @splat(WarlockConstants.CorruptionMana)), mana_a);
        gcd_a = select16(is_act2, v_gcd_std, gcd_a);

        // Action 3: Fear (1.5s Hard cast, stationary)
        const is_act3: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Fear)));
        cast_id = @select(u32, is_act3, @as(u32x16, @splat(3)), cast_id);
        cast_tmr = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tmr);
        cast_tot = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tot);
        mana_a = select16(is_act3, mana_a - @as(f32x16, @splat(WarlockConstants.FearMana)), mana_a);
        gcd_a = select16(is_act3, v_gcd_std, gcd_a);
        move_a = select16(is_act3, v_zeros, move_a); // Must stand still to cast

        // Action 4: Shadow Bolt (1.8s Hard cast, stationary)
        const is_act4: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.ShadowBolt)));
        cast_id = @select(u32, is_act4, @as(u32x16, @splat(4)), cast_id);
        cast_tmr = select16(is_act4, @as(f32x16, @splat(WarlockConstants.ShadowBoltCastTime)), cast_tmr);
        cast_tot = select16(is_act4, @as(f32x16, @splat(WarlockConstants.ShadowBoltCastTime)), cast_tot);
        mana_a = select16(is_act4, mana_a - @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)), mana_a);
        gcd_a = select16(is_act4, v_gcd_std, gcd_a);
        move_a = select16(is_act4, v_zeros, move_a);

        // Action 5: Drain Life (3.0s Channel, stationary)
        const is_act5: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DrainLife)));
        cast_id = @select(u32, is_act5, @as(u32x16, @splat(5)), cast_id);
        cast_tmr = select16(is_act5, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tmr);
        cast_tot = select16(is_act5, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tot);
        mana_a = select16(is_act5, mana_a - @as(f32x16, @splat(WarlockConstants.DrainLifeMana)), mana_a);
        gcd_a = select16(is_act5, v_gcd_std, gcd_a);
        move_a = select16(is_act5, v_zeros, move_a);

        // Action 6: Unending Resolve (Defensive instant)
        const is_act6: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.UnendingResolve)));
        un_dur = select16(is_act6, @as(f32x16, @splat(WarlockConstants.UnendingResolveDuration)), un_dur);
        un_cd = select16(is_act6, @as(f32x16, @splat(WarlockConstants.UnendingResolveCooldown)), un_cd);

        // Action 7: Death Coil (Instant, 30m range, 45s CD, deals damage, heals, Horror CC)
        const is_act_dc: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DeathCoil)));
        mana_a = select16(is_act_dc, mana_a - @as(f32x16, @splat(WarlockConstants.DeathCoilMana)), mana_a);
        gcd_a = select16(is_act_dc, v_gcd_std, gcd_a);
        dc_cd_a = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilCooldown)), dc_cd_a);

        const mit_b = select16(self.unending_dur_b[i..][0..VEC_LEN].* > v_zeros, @as(f32x16, @splat(1.0 - WarlockConstants.UnendingResolveDamageReduction)), @as(f32x16, @splat(1.0)));
        const dc_dmg = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilDamage)) * mit_b, v_zeros);
        hp_b = @max(v_zeros, hp_b - dc_dmg);

        const dc_heal = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros);
        hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + dc_heal);

        const horror_dr_mult_b = getDrMultiplier(horror_dr_t_b);
        const horror_dur_b = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * horror_dr_mult_b;
        horror_b = select16(is_act_dc, horror_dur_b, horror_b);
        horror_dr_t_b = select16(is_act_dc, @min(@as(f32x16, @splat(3.0)), horror_dr_t_b + @as(f32x16, @splat(1.0))), horror_dr_t_b);
        horror_dr_tmr_b = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_b);

        // Interrupt enemy cast if affected by Horror
        const cancel_b_cast = vAnd16(is_act_dc, horror_dur_b > v_zeros);
        var cid_b = self.cast_id_b[i..][0..VEC_LEN].*;
        var ctmr_b = self.cast_timer_b[i..][0..VEC_LEN].*;
        var ctot_b = self.cast_total_b[i..][0..VEC_LEN].*;
        cid_b = @select(u32, cancel_b_cast, v_zeros_u32, cid_b);
        ctmr_b = select16(cancel_b_cast, v_zeros, ctmr_b);
        ctot_b = select16(cancel_b_cast, v_zeros, ctot_b);
        self.cast_id_b[i..][0..VEC_LEN].* = cid_b;
        self.cast_timer_b[i..][0..VEC_LEN].* = ctmr_b;
        self.cast_total_b[i..][0..VEC_LEN].* = ctot_b;

        self.hp_a[i..][0..VEC_LEN].* = hp_a;
        self.hp_b[i..][0..VEC_LEN].* = hp_b;
        self.mana_a[i..][0..VEC_LEN].* = mana_a;
        self.gcd_a[i..][0..VEC_LEN].* = gcd_a;
        self.cast_id_a[i..][0..VEC_LEN].* = cast_id;
        self.cast_timer_a[i..][0..VEC_LEN].* = cast_tmr;
        self.cast_total_a[i..][0..VEC_LEN].* = cast_tot;
        self.unending_cd_a[i..][0..VEC_LEN].* = un_cd;
        self.unending_dur_a[i..][0..VEC_LEN].* = un_dur;
        self.death_coil_cd_a[i..][0..VEC_LEN].* = dc_cd_a;
        self.move_intent_a[i..][0..VEC_LEN].* = move_a;
        self.agony_timer_b[i..][0..VEC_LEN].* = ago_b;
        self.corruption_timer_b[i..][0..VEC_LEN].* = crp_b;
        self.horror_timer_b[i..][0..VEC_LEN].* = horror_b;
        self.horror_dr_tier_b[i..][0..VEC_LEN].* = horror_dr_t_b;
        self.horror_dr_timer_b[i..][0..VEC_LEN].* = horror_dr_tmr_b;
    }

    /// Symmetric Action application for Unit B
    pub fn applyActionB(
        self: *WarlockArenaPool,
        i: usize,
        actions: u32x16,
        move_intents: f32x16,
    ) void {
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_gcd_std: f32x16 = @splat(WarlockConstants.StandardGcd);
        const v_react_std: f32x16 = @splat(WarlockConstants.ReactionInterval);

        var hp_a = self.hp_a[i..][0..VEC_LEN].*;
        var hp_b = self.hp_b[i..][0..VEC_LEN].*;
        var mana_b = self.mana_b[i..][0..VEC_LEN].*;
        var gcd_b = self.gcd_b[i..][0..VEC_LEN].*;
        var cast_id = self.cast_id_b[i..][0..VEC_LEN].*;
        var cast_tmr = self.cast_timer_b[i..][0..VEC_LEN].*;
        var cast_tot = self.cast_total_b[i..][0..VEC_LEN].*;
        var un_cd = self.unending_cd_b[i..][0..VEC_LEN].*;
        var un_dur = self.unending_dur_b[i..][0..VEC_LEN].*;
        var dc_cd_b = self.death_coil_cd_b[i..][0..VEC_LEN].*;
        var move_b = self.move_intent_b[i..][0..VEC_LEN].*;

        var ago_a = self.agony_timer_a[i..][0..VEC_LEN].*;
        var crp_a = self.corruption_timer_a[i..][0..VEC_LEN].*;
        var horror_a = self.horror_timer_a[i..][0..VEC_LEN].*;
        var horror_dr_t_a = self.horror_dr_tier_a[i..][0..VEC_LEN].*;
        var horror_dr_tmr_a = self.horror_dr_timer_a[i..][0..VEC_LEN].*;

        self.react_timer_b[i..][0..VEC_LEN].* = v_react_std;

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
        ago_a = select16(is_act1, @as(f32x16, @splat(WarlockConstants.AgonyDuration)), ago_a);
        mana_b = select16(is_act1, mana_b - @as(f32x16, @splat(WarlockConstants.AgonyMana)), mana_b);
        gcd_b = select16(is_act1, v_gcd_std, gcd_b);

        // Corruption
        const is_act2: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Corruption)));
        crp_a = select16(is_act2, @as(f32x16, @splat(WarlockConstants.CorruptionDuration)), crp_a);
        mana_b = select16(is_act2, mana_b - @as(f32x16, @splat(WarlockConstants.CorruptionMana)), mana_b);
        gcd_b = select16(is_act2, v_gcd_std, gcd_b);

        // Fear
        const is_act3: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.Fear)));
        cast_id = @select(u32, is_act3, @as(u32x16, @splat(3)), cast_id);
        cast_tmr = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tmr);
        cast_tot = select16(is_act3, @as(f32x16, @splat(WarlockConstants.FearCastTime)), cast_tot);
        mana_b = select16(is_act3, mana_b - @as(f32x16, @splat(WarlockConstants.FearMana)), mana_b);
        gcd_b = select16(is_act3, v_gcd_std, gcd_b);
        move_b = select16(is_act3, v_zeros, move_b);

        // Shadow Bolt
        const is_act4: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.ShadowBolt)));
        cast_id = @select(u32, is_act4, @as(u32x16, @splat(4)), cast_id);
        cast_tmr = select16(is_act4, @as(f32x16, @splat(WarlockConstants.ShadowBoltCastTime)), cast_tmr);
        cast_tot = select16(is_act4, @as(f32x16, @splat(WarlockConstants.ShadowBoltCastTime)), cast_tot);
        mana_b = select16(is_act4, mana_b - @as(f32x16, @splat(WarlockConstants.ShadowBoltMana)), mana_b);
        gcd_b = select16(is_act4, v_gcd_std, gcd_b);
        move_b = select16(is_act4, v_zeros, move_b);

        // Drain Life
        const is_act5: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DrainLife)));
        cast_id = @select(u32, is_act5, @as(u32x16, @splat(5)), cast_id);
        cast_tmr = select16(is_act5, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tmr);
        cast_tot = select16(is_act5, @as(f32x16, @splat(WarlockConstants.DrainLifeDuration)), cast_tot);
        mana_b = select16(is_act5, mana_b - @as(f32x16, @splat(WarlockConstants.DrainLifeMana)), mana_b);
        gcd_b = select16(is_act5, v_gcd_std, gcd_b);
        move_b = select16(is_act5, v_zeros, move_b);

        // Unending Resolve
        const is_act6: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.UnendingResolve)));
        un_dur = select16(is_act6, @as(f32x16, @splat(WarlockConstants.UnendingResolveDuration)), un_dur);
        un_cd = select16(is_act6, @as(f32x16, @splat(WarlockConstants.UnendingResolveCooldown)), un_cd);

        // Death Coil
        const is_act_dc: bool16 = actions == @as(u32x16, @splat(@intFromEnum(WarlockAction.DeathCoil)));
        mana_b = select16(is_act_dc, mana_b - @as(f32x16, @splat(WarlockConstants.DeathCoilMana)), mana_b);
        gcd_b = select16(is_act_dc, v_gcd_std, gcd_b);
        dc_cd_b = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilCooldown)), dc_cd_b);

        const mit_a = select16(self.unending_dur_a[i..][0..VEC_LEN].* > v_zeros, @as(f32x16, @splat(1.0 - WarlockConstants.UnendingResolveDamageReduction)), @as(f32x16, @splat(1.0)));
        const dc_dmg = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilDamage)) * mit_a, v_zeros);
        hp_a = @max(v_zeros, hp_a - dc_dmg);

        const dc_heal = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros);
        hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + dc_heal);

        const horror_dr_mult_a = getDrMultiplier(horror_dr_t_a);
        const horror_dur_a = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * horror_dr_mult_a;
        horror_a = select16(is_act_dc, horror_dur_a, horror_a);
        horror_dr_t_a = select16(is_act_dc, @min(@as(f32x16, @splat(3.0)), horror_dr_t_a + @as(f32x16, @splat(1.0))), horror_dr_t_a);
        horror_dr_tmr_a = select16(is_act_dc, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_a);

        // Interrupt A's active cast if hit by Death Coil Horror
        const cancel_a_cast = vAnd16(is_act_dc, horror_dur_a > v_zeros);
        var cid_a = self.cast_id_a[i..][0..VEC_LEN].*;
        var ctmr_a = self.cast_timer_a[i..][0..VEC_LEN].*;
        var ctot_a = self.cast_total_a[i..][0..VEC_LEN].*;
        cid_a = @select(u32, cancel_a_cast, v_zeros_u32, cid_a);
        ctmr_a = select16(cancel_a_cast, v_zeros, ctmr_a);
        ctot_a = select16(cancel_a_cast, v_zeros, ctot_a);
        self.cast_id_a[i..][0..VEC_LEN].* = cid_a;
        self.cast_timer_a[i..][0..VEC_LEN].* = ctmr_a;
        self.cast_total_a[i..][0..VEC_LEN].* = ctot_a;

        self.hp_a[i..][0..VEC_LEN].* = hp_a;
        self.hp_b[i..][0..VEC_LEN].* = hp_b;
        self.mana_b[i..][0..VEC_LEN].* = mana_b;
        self.gcd_b[i..][0..VEC_LEN].* = gcd_b;
        self.cast_id_b[i..][0..VEC_LEN].* = cast_id;
        self.cast_timer_b[i..][0..VEC_LEN].* = cast_tmr;
        self.cast_total_b[i..][0..VEC_LEN].* = cast_tot;
        self.unending_cd_b[i..][0..VEC_LEN].* = un_cd;
        self.unending_dur_b[i..][0..VEC_LEN].* = un_dur;
        self.death_coil_cd_b[i..][0..VEC_LEN].* = dc_cd_b;
        self.move_intent_b[i..][0..VEC_LEN].* = move_b;
        self.agony_timer_a[i..][0..VEC_LEN].* = ago_a;
        self.corruption_timer_a[i..][0..VEC_LEN].* = crp_a;
        self.horror_timer_a[i..][0..VEC_LEN].* = horror_a;
        self.horror_dr_tier_a[i..][0..VEC_LEN].* = horror_dr_t_a;
        self.horror_dr_timer_a[i..][0..VEC_LEN].* = horror_dr_tmr_a;
    }

    /// Vectorized Physics & Combat Tick (dt = 0.010s / 100Hz)
    /// Ticks timers, updates distance, resolves casts, DOTs, CC, and mitigation branchlessly.
    pub fn tickPhysics(self: *WarlockArenaPool, dt: f32) usize {
        const v_dt: f32x16 = @splat(dt);
        const v_zeros: f32x16 = @splat(0.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_ones_u32: u32x16 = @splat(1);
        const v_min_dist: f32x16 = @splat(WarlockConstants.MinDistance);
        const v_max_dist: f32x16 = @splat(WarlockConstants.MaxDistance);

        var active_duels_sum: usize = 0;
        var i: usize = 0;

        while (i < self.capacity) : (i += VEC_LEN) {
            const active_mask: bool16 = self.is_active[i..][0..VEC_LEN].* > v_zeros_u32;
            if (!@reduce(.Or, active_mask)) continue;

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
            var crp_a = self.corruption_timer_a[i..][0..VEC_LEN].*;
            var fear_a = self.fear_timer_a[i..][0..VEC_LEN].*;
            var fear_dmg_a = self.fear_accum_dmg_a[i..][0..VEC_LEN].*;
            var horror_a = self.horror_timer_a[i..][0..VEC_LEN].*;

            var ago_b = self.agony_timer_b[i..][0..VEC_LEN].*;
            var crp_b = self.corruption_timer_b[i..][0..VEC_LEN].*;
            var fear_b = self.fear_timer_b[i..][0..VEC_LEN].*;
            var fear_dmg_b = self.fear_accum_dmg_b[i..][0..VEC_LEN].*;
            var horror_b = self.horror_timer_b[i..][0..VEC_LEN].*;

            var un_cd_a = self.unending_cd_a[i..][0..VEC_LEN].*;
            var un_dur_a = self.unending_dur_a[i..][0..VEC_LEN].*;
            var dc_cd_a = self.death_coil_cd_a[i..][0..VEC_LEN].*;
            var fear_dr_t_a = self.fear_dr_tier_a[i..][0..VEC_LEN].*;
            var fear_dr_tmr_a = self.fear_dr_timer_a[i..][0..VEC_LEN].*;
            var horror_dr_t_a = self.horror_dr_tier_a[i..][0..VEC_LEN].*;
            var horror_dr_tmr_a = self.horror_dr_timer_a[i..][0..VEC_LEN].*;

            var un_cd_b = self.unending_cd_b[i..][0..VEC_LEN].*;
            var un_dur_b = self.unending_dur_b[i..][0..VEC_LEN].*;
            var dc_cd_b = self.death_coil_cd_b[i..][0..VEC_LEN].*;
            var fear_dr_t_b = self.fear_dr_tier_b[i..][0..VEC_LEN].*;
            var fear_dr_tmr_b = self.fear_dr_timer_b[i..][0..VEC_LEN].*;
            var horror_dr_t_b = self.horror_dr_tier_b[i..][0..VEC_LEN].*;
            var horror_dr_tmr_b = self.horror_dr_timer_b[i..][0..VEC_LEN].*;

            // 1. Advance general timers
            gcd_a = @max(v_zeros, gcd_a - v_dt);
            gcd_b = @max(v_zeros, gcd_b - v_dt);
            r_tmr_a = @max(v_zeros, r_tmr_a - v_dt);
            r_tmr_b = @max(v_zeros, r_tmr_b - v_dt);
            un_cd_a = @max(v_zeros, un_cd_a - v_dt);
            un_cd_b = @max(v_zeros, un_cd_b - v_dt);
            un_dur_a = @max(v_zeros, un_dur_a - v_dt);
            un_dur_b = @max(v_zeros, un_dur_b - v_dt);
            dc_cd_a = @max(v_zeros, dc_cd_a - v_dt);
            dc_cd_b = @max(v_zeros, dc_cd_b - v_dt);
            fear_a = @max(v_zeros, fear_a - v_dt);
            fear_b = @max(v_zeros, fear_b - v_dt);
            horror_a = @max(v_zeros, horror_a - v_dt);
            horror_b = @max(v_zeros, horror_b - v_dt);

            // DR Timer progression when CC is inactive
            const fear_dr_ticking_a = vAnd16(fear_a <= v_zeros, fear_dr_t_a > v_zeros);
            fear_dr_tmr_a = select16(fear_dr_ticking_a, @max(v_zeros, fear_dr_tmr_a - v_dt), fear_dr_tmr_a);
            const fear_dr_reset_a = vAnd16(fear_dr_ticking_a, fear_dr_tmr_a <= v_zeros);
            fear_dr_t_a = select16(fear_dr_reset_a, v_zeros, fear_dr_t_a);

            const fear_dr_ticking_b = vAnd16(fear_b <= v_zeros, fear_dr_t_b > v_zeros);
            fear_dr_tmr_b = select16(fear_dr_ticking_b, @max(v_zeros, fear_dr_tmr_b - v_dt), fear_dr_tmr_b);
            const fear_dr_reset_b = vAnd16(fear_dr_ticking_b, fear_dr_tmr_b <= v_zeros);
            fear_dr_t_b = select16(fear_dr_reset_b, v_zeros, fear_dr_t_b);

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
            mana_a = @min(@as(f32x16, @splat(WarlockConstants.MaxMana)), mana_a + regen);
            mana_b = @min(@as(f32x16, @splat(WarlockConstants.MaxMana)), mana_b + regen);

            // 2. Movement & Relative Distance Update
            const speed_a = select16(move_a < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_a > v_zeros, @as(f32x16, @splat(WarlockConstants.BackpedalSpeed)), v_zeros));
            const speed_b = select16(move_b < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_b > v_zeros, @as(f32x16, @splat(WarlockConstants.BackpedalSpeed)), v_zeros));

            // While feared or horrified, unit runs away involuntarily!
            const cc_a = vOr16(fear_a > v_zeros, horror_a > v_zeros);
            const cc_b = vOr16(fear_b > v_zeros, horror_b > v_zeros);
            const effective_speed_a = select16(cc_a, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), speed_a);
            const effective_speed_b = select16(cc_b, @as(f32x16, @splat(WarlockConstants.ForwardSpeed)), speed_b);

            dist = simd.clamp16(dist + (effective_speed_a + effective_speed_b) * v_dt, v_min_dist, v_max_dist);

            // 3. Movement cast cancel check:
            const a_is_stationary_casting = vAnd16(c_id_a > v_zeros_u32, c_id_a <= @as(u32x16, @splat(5)));
            const a_moved = effective_speed_a != v_zeros;
            const cancel_a = vAnd16(a_is_stationary_casting, a_moved);
            c_id_a = @select(u32, cancel_a, v_zeros_u32, c_id_a);
            c_tmr_a = select16(cancel_a, v_zeros, c_tmr_a);
            c_tot_a = select16(cancel_a, v_zeros, c_tot_a);

            const b_is_stationary_casting = vAnd16(c_id_b > v_zeros_u32, c_id_b <= @as(u32x16, @splat(5)));
            const b_moved = effective_speed_b != v_zeros;
            const cancel_b = vAnd16(b_is_stationary_casting, b_moved);
            c_id_b = @select(u32, cancel_b, v_zeros_u32, c_id_b);
            c_tmr_b = select16(cancel_b, v_zeros, c_tmr_b);
            c_tot_b = select16(cancel_b, v_zeros, c_tot_b);

            // 4. Damage Mitigation Factor:
            const mit_a = select16(un_dur_a > v_zeros, @as(f32x16, @splat(1.0 - WarlockConstants.UnendingResolveDamageReduction)), @as(f32x16, @splat(1.0)));
            const mit_b = select16(un_dur_b > v_zeros, @as(f32x16, @splat(1.0 - WarlockConstants.UnendingResolveDamageReduction)), @as(f32x16, @splat(1.0)));

            // 5. DOT Ticking:
            const has_ago_a = ago_a > v_zeros;
            ago_a = @max(v_zeros, ago_a - v_dt);
            const dmg_ago_a = select16(has_ago_a, @as(f32x16, @splat(WarlockConstants.AgonyDps * dt)) * mit_a, v_zeros);

            const has_crp_a = crp_a > v_zeros;
            crp_a = @max(v_zeros, crp_a - v_dt);
            const dmg_crp_a = select16(has_crp_a, @as(f32x16, @splat(WarlockConstants.CorruptionDps * dt)) * mit_a, v_zeros);

            const has_ago_b = ago_b > v_zeros;
            ago_b = @max(v_zeros, ago_b - v_dt);
            const dmg_ago_b = select16(has_ago_b, @as(f32x16, @splat(WarlockConstants.AgonyDps * dt)) * mit_b, v_zeros);

            const has_crp_b = crp_b > v_zeros;
            crp_b = @max(v_zeros, crp_b - v_dt);
            const dmg_crp_b = select16(has_crp_b, @as(f32x16, @splat(WarlockConstants.CorruptionDps * dt)) * mit_b, v_zeros);

            // 6. Cast Execution & Drain Life Channeling:
            // --- Unit A Cast Progress ---
            const a_casting = c_id_a > v_zeros_u32;
            c_tmr_a = select16(a_casting, c_tmr_a - v_dt, v_zeros);
            const a_cast_finished = vAnd16(a_casting, c_tmr_a <= v_zeros);

            const a_drain_active = vAnd16(a_casting, c_id_a == @as(u32x16, @splat(5)));
            const a_drain_dmg = select16(a_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeDps * dt)) * mit_b, v_zeros);
            const a_drain_heal = select16(a_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeHps * dt)), v_zeros);
            hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + a_drain_heal);

            const a_sb_hit = vAnd16(a_cast_finished, c_id_a == @as(u32x16, @splat(4)));
            const a_sb_dmg = select16(a_sb_hit, @as(f32x16, @splat(WarlockConstants.ShadowBoltDamage)) * mit_b, v_zeros);

            const a_fear_hit = vAnd16(a_cast_finished, c_id_a == @as(u32x16, @splat(3)));
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
            c_tmr_b = select16(b_casting, c_tmr_b - v_dt, v_zeros);
            const b_cast_finished = vAnd16(b_casting, c_tmr_b <= v_zeros);

            const b_drain_active = vAnd16(b_casting, c_id_b == @as(u32x16, @splat(5)));
            const b_drain_dmg = select16(b_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeDps * dt)) * mit_a, v_zeros);
            const b_drain_heal = select16(b_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeHps * dt)), v_zeros);
            hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + b_drain_heal);

            const b_sb_hit = vAnd16(b_cast_finished, c_id_b == @as(u32x16, @splat(4)));
            const b_sb_dmg = select16(b_sb_hit, @as(f32x16, @splat(WarlockConstants.ShadowBoltDamage)) * mit_a, v_zeros);

            const b_fear_hit = vAnd16(b_cast_finished, c_id_b == @as(u32x16, @splat(3)));
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

            // 7. Apply Damage to HP
            const total_dmg_to_a = dmg_ago_a + dmg_crp_a + b_drain_dmg + b_sb_dmg;
            const total_dmg_to_b = dmg_ago_b + dmg_crp_b + a_drain_dmg + a_sb_dmg;

            hp_a = @max(v_zeros, hp_a - total_dmg_to_a);
            hp_b = @max(v_zeros, hp_b - total_dmg_to_b);

            // Fear damage break threshold check
            fear_dmg_a = fear_dmg_a + total_dmg_to_a;
            fear_a = select16(fear_dmg_a >= @as(f32x16, @splat(WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_a);

            fear_dmg_b = fear_dmg_b + total_dmg_to_b;
            fear_b = select16(fear_dmg_b >= @as(f32x16, @splat(WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_b);

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
            self.corruption_timer_a[i..][0..VEC_LEN].* = crp_a;
            self.fear_timer_a[i..][0..VEC_LEN].* = fear_a;
            self.fear_accum_dmg_a[i..][0..VEC_LEN].* = fear_dmg_a;
            self.horror_timer_a[i..][0..VEC_LEN].* = horror_a;

            self.agony_timer_b[i..][0..VEC_LEN].* = ago_b;
            self.corruption_timer_b[i..][0..VEC_LEN].* = crp_b;
            self.fear_timer_b[i..][0..VEC_LEN].* = fear_b;
            self.fear_accum_dmg_b[i..][0..VEC_LEN].* = fear_dmg_b;
            self.horror_timer_b[i..][0..VEC_LEN].* = horror_b;

            self.unending_cd_a[i..][0..VEC_LEN].* = un_cd_a;
            self.unending_dur_a[i..][0..VEC_LEN].* = un_dur_a;
            self.death_coil_cd_a[i..][0..VEC_LEN].* = dc_cd_a;
            self.fear_dr_tier_a[i..][0..VEC_LEN].* = fear_dr_t_a;
            self.fear_dr_timer_a[i..][0..VEC_LEN].* = fear_dr_tmr_a;
            self.horror_dr_tier_a[i..][0..VEC_LEN].* = horror_dr_t_a;
            self.horror_dr_timer_a[i..][0..VEC_LEN].* = horror_dr_tmr_a;

            self.unending_cd_b[i..][0..VEC_LEN].* = un_cd_b;
            self.unending_dur_b[i..][0..VEC_LEN].* = un_dur_b;
            self.death_coil_cd_b[i..][0..VEC_LEN].* = dc_cd_b;
            self.fear_dr_tier_b[i..][0..VEC_LEN].* = fear_dr_t_b;
            self.fear_dr_timer_b[i..][0..VEC_LEN].* = fear_dr_tmr_b;
            self.horror_dr_tier_b[i..][0..VEC_LEN].* = horror_dr_t_b;
            self.horror_dr_timer_b[i..][0..VEC_LEN].* = horror_dr_tmr_b;

            self.is_active[i..][0..VEC_LEN].* = v_duel_act;

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
