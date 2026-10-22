//! Initial SIMD warrior resource/stance/weapon primitives, isolated from caster
//! arenas until the melee kernel and snapshot plumbing are complete.
//! Sources and unresolved reference assumptions: data/warrior_sources/README.md.
const simd = @import("simd.zig");
const talents = @import("warrior_talents.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;

pub const Stance = enum(u32) { battle = 1, defensive = 2, berserker = 4 };

/// Stored as independent vectors so eventual arena storage can use aligned SoA
/// columns. Configuration is passed in; this struct contains dynamic state only.
pub const State = struct {
    rage: V = @splat(0),
    stance: U = @splat(@intFromEnum(Stance.battle)),
    stance_cooldown: V = @splat(0),

    pub fn reset(self: *State, starting_rage: V, starting_stance: U, max_rage: V) void {
        self.* = .{ .rage = @min(@max(starting_rage, splat(0)), max_rage), .stance = starting_stance };
    }

    /// Returns effective gain (overflow is lost). Dead/inactive lanes are masked
    /// by the caller, as are proc eligibility and immunity rules.
    pub fn gain(self: *State, amount: V, max_rage: V, eligible: B) V {
        const before = self.rage;
        self.rage = @select(f32, eligible, @min(max_rage, before + @max(amount, splat(0))), before);
        return self.rage - before;
    }

    /// No partial payment: illegal/ineligible lanes retain their rage. The
    /// returned mask controls execution and any later outcome-specific refund.
    pub fn spend(self: *State, cost: V, eligible: B) B {
        const allowed = simd.vAnd16(eligible, simd.vAnd16(cost >= splat(0), self.rage >= cost));
        self.rage -= @select(f32, allowed, cost, splat(0));
        return allowed;
    }

    /// An off-GCD stance change shares a one-second stance cooldown and caps,
    /// rather than grants, retained rage. CC/action legality comes from caller.
    pub fn switchStance(self: *State, desired: U, retained_rage: V, eligible: B) B {
        const valid = simd.vOr16(desired == ids(.battle), simd.vOr16(desired == ids(.defensive), desired == ids(.berserker)));
        const allowed = simd.vAnd16(eligible, simd.vAnd16(valid, simd.vAnd16(self.stance != desired, self.stance_cooldown <= splat(0))));
        self.stance = @select(u32, allowed, desired, self.stance);
        self.rage = @select(f32, allowed, @min(self.rage, retained_rage), self.rage);
        self.stance_cooldown = @select(f32, allowed, splat(1), self.stance_cooldown);
        return allowed;
    }

    pub fn tick(self: *State, dt: V, active: B) void {
        self.stance_cooldown = @select(f32, active, @max(splat(0), self.stance_cooldown - @max(dt, splat(0))), self.stance_cooldown);
    }
};

fn splat(value: f32) V {
    return @splat(value);
}
fn ids(value: Stance) U {
    return @splat(@intFromEnum(value));
}

pub const StanceEffects = struct { damage_dealt: V, damage_taken: V, melee_crit_bonus: V };

/// Multipliers are derived from stance; never multiply permanent stats on each
/// switch, which would accumulate rounding and leak bonuses between stances.
pub fn stanceEffects(stance: U) StanceEffects {
    return .{
        .damage_dealt = @select(f32, stance == ids(.defensive), splat(0.9), splat(1)),
        .damage_taken = @select(f32, stance == ids(.defensive), splat(0.9), @select(f32, stance == ids(.berserker), splat(1.1), splat(1))),
        .melee_crit_bonus = @select(f32, stance == ids(.berserker), splat(0.03), splat(0)),
    };
}

/// Forever pays flat rage per landed white swing using BASE weapon speed, with
/// no damage/crit/AP input. Base-versus-hasted speed is a reference assumption.
/// Miss/dodge/parry and special attacks must pass eligible=false. A landed
/// absorbed/fully blocked swing remains eligible per the reference rage.go.
pub fn whiteHitRage(base_speed: V, two_handed: B, offhand: B, effects: talents.ResourceEffects, eligible: B) V {
    const per_second = @select(f32, two_handed, splat(4.5), splat(3.46));
    const hand_multiplier = @select(f32, offhand, splat(0.5) * effects.offhand_rage_multiplier, splat(1));
    return @select(f32, eligible, @max(splat(0), base_speed) * per_second * hand_multiplier, splat(0));
}

/// Provisional reference formula, NOT independently verified client behavior.
/// Input is raw pre-armor damage; caller must exclude misses and full resists.
pub fn damageTakenRage(raw_damage: V, max_health: V, eligible: B) V {
    const allowed = simd.vAnd16(eligible, max_health > splat(0));
    const safe_health = @select(f32, max_health > splat(0), max_health, splat(1));
    return @select(f32, allowed, @max(splat(0), raw_damage) * splat(10) / safe_health, splat(0));
}

/// Base weapon roll plus AP/14 * speed. White attacks use actual base speed;
/// normalized specials use 1.7 dagger / 2.4 one-hand / 3.3 two-hand. The caller
/// supplies the roll and normalization explicitly, keeping RNG state external.
pub fn weaponDamage(min_damage: V, max_damage: V, roll: V, attack_power: V, ap_speed: V) V {
    const base = min_damage + (max_damage - min_damage) * @min(splat(1), @max(splat(0), roll));
    return @max(splat(0), base + attack_power * ap_speed / splat(14));
}
