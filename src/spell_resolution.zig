//! Shared probability-based spell resolution. Rates are fractions, not ratings.
//! Applications roll once at launch/use; landed periodic effects roll per tick.
const std = @import("std");
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
pub const School = enum { shadow, fire, frost, arcane, holy };
pub const Outcome = enum(u32) { none, miss, resist, hit, crit };
pub const Stats = struct {
    max_health: f32 = 2000,
    // Total stamina before talents; max_health already includes its base HP.
    stamina: f32 = 0,
    max_mana: f32 = 1000,
    shadow_power: f32 = 0,
    fire_power: f32 = 0,
    frost_power: f32 = 0,

    // Preserve the compact kit's former baseline unless a spec supplies stats.
    spell_hit_chance: f32 = 1,
    spell_crit_chance: f32 = 0,
    shadow_resist_chance: f32 = 0,
    fire_resist_chance: f32 = 0,
    frost_resist_chance: f32 = 0,
    arcane_resist_chance: f32 = 0,

    // Raw school resistance and penetration use a documented compact level model.
    // Hit/crit remain normalized probabilities; combat rating inputs are rejected.
    level: f32 = 60,
    spell_penetration: f32 = 0,
    shadow_resistance: f32 = 0,
    fire_resistance: f32 = 0,
    frost_resistance: f32 = 0,
    arcane_resistance: f32 = 0,
    pet_hit_chance: f32 = 1,
    pet_crit_chance: f32 = 0,
    melee_avoidance_chance: f32 = 0,
    armor_damage_reduction: f32 = 0,

    pub fn validate(self: Stats) !void {
        inline for (std.meta.fields(Stats)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidCombatStats;
            if (comptime std.mem.eql(u8, field.name, "level")) {
                if (value < 1 or value > 100 or @floor(value) != value) return error.InvalidCombatStats;
            } else if (comptime std.mem.startsWith(u8, field.name, "max_")) {
                if (value < 1 or value > 100000) return error.InvalidCombatStats;
            } else if (comptime std.mem.eql(u8, field.name, "stamina")) {
                if (value > 10000) return error.InvalidCombatStats;
            } else if (comptime std.mem.endsWith(u8, field.name, "_power")) {
                if (value > 10000) return error.InvalidCombatStats;
            } else if (comptime std.mem.endsWith(u8, field.name, "_resistance") or std.mem.eql(u8, field.name, "spell_penetration")) {
                if (value > 10000) return error.InvalidCombatStats;
            } else if (value > 1) return error.InvalidCombatStats;
        }
    }
};
pub fn spellPower(state: anytype, comptime side: bool, i: usize, comptime school: School) V {
    const field_prefix = if (school == .holy) "shadow" else @tagName(school);
    return (@field(state, field_prefix ++ "_power" ++ (if (side) "_a" else "_b"))[i..][0..16].* + @import("demon_passives.zig").knowledge(state, side, i)) * @import("racials.zig").powerMultiplier(state, side, i);
}
pub const Profile = struct {
    school: School,
    hit_bonus: V = @splat(0),
    crit_bonus: V = @splat(0),
    crit_multiplier: V = @splat(1.5),
    can_crit: bool = true,
    binary: bool = false,
    partial: bool = true,
    pet: bool = false,
};
pub const Result = struct { damage: V, landed: B, outcome: U };
fn v(x: f32) V {
    return @splat(x);
}
fn chance(x: V) V {
    return @min(v(1), @max(v(0), x));
}
// Kept separate from the generator so scalar/reference tests can use identical
// supplied rolls without assuming SIMD arithmetic or generator implementation.
pub fn resolveRolls(damage: V, hit_chance: V, resist_chance: V, crit_chance: V, crit_multiplier: V, rolls: [3]V, mask: B) Result {
    const hit = simd.vAnd16(mask, rolls[0] < chance(hit_chance));
    const landed = simd.vAnd16(hit, rolls[1] >= chance(resist_chance));
    const crit = simd.vAnd16(landed, rolls[2] < chance(crit_chance));
    return .{
        .damage = @select(f32, landed, damage * @select(f32, crit, crit_multiplier, v(1)), v(0)),
        .landed = landed,
        .outcome = @select(u32, mask, @select(u32, hit, @select(u32, landed, @select(u32, crit, @as(U, @splat(@intFromEnum(Outcome.crit))), @as(U, @splat(@intFromEnum(Outcome.hit)))), @as(U, @splat(@intFromEnum(Outcome.resist)))), @as(U, @splat(@intFromEnum(Outcome.miss)))), @as(U, @splat(0))),
    };
}
fn rollFor(state: anytype, comptime side: bool, i: usize, mask: B, pet: bool) V {
    const values = if (pet) @field(state, "pet_rng" ++ (if (side) "_a" else "_b")) else @field(state, "spell_rng" ++ (if (side) "_a" else "_b"));
    return rollValues(values, i, mask);
}
pub fn rollSpell(state: anytype, comptime side: bool, i: usize, mask: B) V {
    return rollFor(state, side, i, mask, false);
}
fn rollValues(values: anytype, i: usize, mask: B) V {
    const old: U = values[i..][0..16].*;
    var next = @select(u32, old == @as(U, @splat(0)), @as(U, @splat(0x6d2b79f5)), old);
    next ^= next << @as(@Vector(16, u5), @splat(13));
    next ^= next >> @as(@Vector(16, u5), @splat(17));
    next ^= next << @as(@Vector(16, u5), @splat(5));
    values[i..][0..16].* = @select(u32, mask, next, old);
    return @as(V, @floatFromInt(next >> @as(@Vector(16, u5), @splat(8)))) * v(1.0 / 16777216.0);
}
pub fn resolve(state: anytype, comptime side: bool, i: usize, damage: V, mask: B, profile: Profile) Result {
    const acting = simd.vAnd16(mask, state.is_active[i..][0..16].* != @as(U, @splat(0)));
    if (!@reduce(.Or, acting)) return .{ .damage = v(0), .landed = @splat(false), .outcome = @splat(0) };
    const own = if (side) "_a" else "_b";
    const target = if (side) "_b" else "_a";
    const hit: V = if (profile.pet) @field(state, "pet_hit_chance" ++ own)[i..][0..16].* else @field(state, "spell_hit_chance" ++ own)[i..][0..16].*;
    const crit: V = if (profile.pet) @field(state, "pet_crit_chance" ++ own)[i..][0..16].* else @field(state, "spell_crit_chance" ++ own)[i..][0..16].*;
    const resist: V = switch (profile.school) {
        .holy => v(0),
        inline else => |school| @field(state, @tagName(school) ++ "_resist_chance" ++ target)[i..][0..16].*,
    };
    const average = averageResistance(state, side, i, profile.school);
    const result = resolveRolls(damage, hit + profile.hit_bonus, if (profile.binary) v(1) - (v(1) - resist) * (v(1) - average) else resist, if (profile.can_crit) crit + profile.crit_bonus else v(0), profile.crit_multiplier, .{ rollFor(state, side, i, acting, profile.pet), rollFor(state, side, i, acting, profile.pet), rollFor(state, side, i, acting, profile.pet) }, acting);
    const outcome = if (profile.pet) @field(state, "pet_outcome" ++ own) else @field(state, "spell_outcome" ++ own);
    outcome[i..][0..16].* = @select(u32, acting, result.outcome, outcome[i..][0..16].*);
    return if (profile.partial and !profile.binary) applyPartial(state, side, i, result, acting, profile) else result;
}
pub fn setStats(state: anytype, comptime side: bool, lane: usize, stats: Stats) void {
    inline for (std.meta.fields(Stats)) |field| {
        // Stamina is resolved at setup; combat only needs the resulting HP.
        if (comptime !std.mem.eql(u8, field.name, "stamina")) @field(state, field.name ++ (if (side) "_a" else "_b"))[lane] = @field(stats, field.name);
    }
}

// Applications resolve hit/full resist once; landed periodic effects roll only
// crit and partial mitigation on each tick. Owner hit bonuses must not
// make an already-landed DoT miss again.
pub fn periodic(state: anytype, comptime side: bool, i: usize, damage: V, mask: B, profile: Profile) Result {
    const acting = simd.vAnd16(mask, state.is_active[i..][0..16].* != @as(U, @splat(0)));
    if (!@reduce(.Or, acting)) return .{ .damage = v(0), .landed = @splat(false), .outcome = @splat(0) };
    const crit: V = @field(state, "spell_crit_chance" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    const result = resolveRolls(damage, v(1), v(0), if (profile.can_crit) crit + profile.crit_bonus else v(0), profile.crit_multiplier, .{ v(0), v(1), rollFor(state, side, i, acting, profile.pet) }, acting);
    const outcome = @field(state, "spell_outcome" ++ (if (side) "_a" else "_b"));
    outcome[i..][0..16].* = @select(u32, acting, result.outcome, outcome[i..][0..16].*);
    return applyPartial(state, side, i, result, acting, profile);
}

// Compact resistance model: penetration removes gear resistance, not the
// level-difference contribution. Adjacent 25% buckets preserve the mean; this
// distribution is an explicit simulator approximation, not an authentic table.
pub fn resistanceMean(resistance: V, penetration: V, caster_level: V, target_level: V) V {
    const effective = @max(v(0), resistance - penetration) + @max(v(0), target_level - caster_level) * v(5);
    return @min(v(0.75), effective * v(0.75) / (v(5) * @max(v(1), caster_level)));
}
fn averageResistance(state: anytype, comptime side: bool, i: usize, school: School) V {
    if (school == .holy) return v(0);
    const own = if (side) "_a" else "_b";
    const target = if (side) "_b" else "_a";
    const resistance: V = switch (school) {
        .holy => unreachable,
        inline else => |value| @field(state, @tagName(value) ++ "_resistance" ++ target)[i..][0..16].*,
    };
    return resistanceMean(resistance, @field(state, "spell_penetration" ++ own)[i..][0..16].*, @field(state, "level" ++ own)[i..][0..16].*, @field(state, "level" ++ target)[i..][0..16].*);
}
pub fn partialFraction(mean: V, supplied_roll: V) V {
    const buckets = chance(mean) * v(4);
    const lower = @floor(buckets);
    return (lower + @select(f32, supplied_roll < buckets - lower, v(1), v(0))) * v(0.25);
}
fn applyPartial(state: anytype, comptime side: bool, i: usize, result: Result, acting: B, profile: Profile) Result {
    const mean = averageResistance(state, side, i, profile.school);
    const eligible = simd.vAnd16(acting, simd.vAnd16(result.landed, mean > v(0)));
    if (!@reduce(.Or, eligible)) return result;
    const fraction = partialFraction(mean, rollFor(state, side, i, eligible, profile.pet));
    var reduced = result;
    reduced.damage *= @select(f32, eligible, v(1) - fraction, v(1));
    return reduced;
}
pub fn petMelee(state: anytype, comptime side: bool, i: usize, damage: V, mask: B) V {
    const own = if (side) "_a" else "_b";
    const target = if (side) "_b" else "_a";
    const acting = simd.vAnd16(mask, state.is_active[i..][0..16].* != @as(U, @splat(0)));
    if (!@reduce(.Or, acting)) return v(0);
    const hit: V = @field(state, "pet_hit_chance" ++ own)[i..][0..16].*;
    const avoid: V = @field(state, "melee_avoidance_chance" ++ target)[i..][0..16].*;
    const crit: V = @field(state, "pet_crit_chance" ++ own)[i..][0..16].*;
    const armor: V = @field(state, "armor_damage_reduction" ++ target)[i..][0..16].*;
    return resolveRolls(damage, hit, avoid, crit, v(2), .{ rollFor(state, side, i, acting, true), rollFor(state, side, i, acting, true), rollFor(state, side, i, acting, true) }, acting).damage * (v(1) - armor);
}

pub fn pushbackRoll(state: anytype, comptime side: bool, i: usize, mask: B) V {
    return rollValues(@field(state, "pushback_rng" ++ (if (side) "_a" else "_b")), i, mask);
}
