//! Optional Warrior state and first melee kernel. Caster arenas allocate none
//! of these columns. Compact hit/avoid/crit probabilities match the existing
//! pet model; separate PvP dodge/parry/block/facing rules are still pending.
const std = @import("std");
const simd = @import("simd.zig");
const core = @import("warrior_core.zig");
const talents = @import("warrior_talents.zig");
const resolution = @import("spell_resolution.zig");
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
const both = simd.vAnd16;
const either = simd.vOr16;
fn v(x: f32) V {
    return @splat(x);
}
fn u(x: u32) U {
    return @splat(x);
}

pub const Column = enum { rage, stance, stance_cd, main_swing, off_swing, queued_strike, pending_damage, rng, hamstring, last_damage, last_outcome, charge_cd, intercept_cd, mortal_strike_cd, mortal_strike, rend, overpower_window, overpower_cd, execute_cd, pummel_cd, berserker_rage_cd, berserker_rage, bloodrage_cd, bloodrage_timer, bloodrage_phase, bloodthirst_cd, bloodthirst_speed, whirlwind_cd, death_wish_cd, death_wish, enrage, flurry_stacks, flurry_icd, raw_mh_white, raw_oh_white, raw_mh_special, raw_oh_special, rage_from_hits, rage_from_wrath };
pub const column_count = std.meta.fields(Column).len;
pub const ExecuteCooldown: f32 = 1.5;
pub const PummelCooldown: f32 = 10;
pub const PummelLockout: f32 = 4;
// Leave room to react to a fleeing target instead of landing on the range edge.
pub const GapCloseDistance: f32 = 3;

pub const MeleeTable = struct {
    dodge: f32 = 0,
    parry: f32 = 0,
    block: f32 = 0,
    block_value: f32 = 0,
    configured: bool = false,

    pub fn fromStats(stats: resolution.Stats) MeleeTable {
        const explicit = stats.melee_dodge_chance + stats.melee_parry_chance + stats.melee_block_chance > 0;
        if (explicit) return .{ .dodge = stats.melee_dodge_chance, .parry = stats.melee_parry_chance, .block = stats.melee_block_chance, .block_value = stats.melee_block_value, .configured = true };
        return .{ .dodge = stats.melee_avoidance_chance, .configured = stats.melee_avoidance_chance > 0 };
    }

    pub fn validate(self: MeleeTable) !void {
        if (!std.math.isFinite(self.dodge) or !std.math.isFinite(self.parry) or !std.math.isFinite(self.block) or !std.math.isFinite(self.block_value) or self.dodge < 0 or self.parry < 0 or self.block < 0 or self.block_value < 0 or self.dodge + self.parry + self.block > 1 or self.block_value > 10000 or (self.block > 0 and self.block_value <= 0)) return error.InvalidWarriorStats;
    }
};

pub const Weapon = struct {
    min: f32 = 180,
    max: f32 = 270,
    speed: f32 = 3.6,
    two_handed: bool = true,
    pub fn validate(self: Weapon) !void {
        if (!std.math.isFinite(self.min) or !std.math.isFinite(self.max) or !std.math.isFinite(self.speed) or self.min < 0 or self.max < self.min or self.max > 10000 or self.speed < 0.1 or self.speed > 10) return error.InvalidWarriorWeapon;
    }
};
pub const Config = struct {
    main_hand: Weapon = .{},
    off_hand: ?Weapon = null,
    attack_power: f32 = 700,
    white_hit: f32 = 0.95,
    special_hit: f32 = 0.95,
    crit: f32 = 0.05,
    starting_rage: f32 = 0,
    // Pinned reference formula; its coefficient remains provisional.
    damage_taken_rage: bool = true,
    starting_stance: core.Stance = .battle,
    build: talents.Build = .{},
    target_melee: MeleeTable = .{},

    pub fn validate(self: Config) !void {
        try self.main_hand.validate();
        if (self.off_hand) |weapon| {
            try weapon.validate();
            if (self.main_hand.two_handed or weapon.two_handed) return error.InvalidWarriorWeapon;
        }
        inline for (.{ "white_hit", "special_hit", "crit" }) |field| {
            const value = @field(self, field);
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidWarriorStats;
        }
        if (!std.math.isFinite(self.attack_power) or self.attack_power < 0 or self.attack_power > 10000 or !std.math.isFinite(self.starting_rage) or self.starting_rage < 0 or self.starting_rage > 130) return error.InvalidWarriorStats;
        try self.build.validate();
        try self.target_melee.validate();
    }
    fn effects(self: Config) talents.ResourceEffects {
        // Configuration is validated on installation, not in the hot loop.
        return .{
            .max_rage = v(100 + 10 * @as(f32, @floatFromInt(self.build.ranks[@intFromEnum(talents.Talent.boundlessRage)]))),
            .retained_rage = v(10 + 3 * @as(f32, @floatFromInt(self.build.ranks[@intFromEnum(talents.Talent.improvedTacticalMastery)]))),
            .offhand_rage_multiplier = v(1 + 0.2 * @as(f32, @floatFromInt(self.build.ranks[@intFromEnum(talents.Talent.dualWieldSpecialization)]))),
        };
    }
};

fn heroicStrikeCost(config: Config) f32 {
    return @max(@as(f32, 0), 15 - @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.improvedHeroicStrike)])));
}

pub fn count(comptime a: bool, comptime b: bool) usize {
    return @as(usize, @intFromBool(a)) + @as(usize, @intFromBool(b));
}
pub fn Storage(comptime a: bool, comptime b: bool) type {
    const n = count(a, b);
    return struct {
        const Self = @This();
        pub const HasWarriorA = a;
        pub const HasWarriorB = b;
        words: []align(64) u32,
        capacity: usize,
        configs: [n]Config = @splat(.{}),
        recording: ?*[2]@import("warrior_recording.zig").Tick = null,
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const words = try allocator.alignedAlloc(u32, 64, capacity * n * column_count);
            @memset(words, 0);
            return .{ .words = words, .capacity = capacity };
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.words);
        }
        pub fn slot(comptime side: bool) usize {
            if ((side and !a) or (!side and !b)) @compileError("Not a Warrior side");
            return if (side or !a) 0 else 1;
        }
        pub fn floats(self: *const Self, comptime side: bool, comptime column: Column, i: usize) *align(64) V {
            const offset = (slot(side) * column_count + @intFromEnum(column)) * self.capacity + i;
            return @ptrCast(@alignCast(self.words[offset..][0..16]));
        }
        pub fn integers(self: *const Self, comptime side: bool, comptime column: Column, i: usize) *align(64) U {
            return @ptrCast(self.floats(side, column, i));
        }
        pub fn reset(self: *Self, lane: usize) void {
            inline for (.{ true, false }) |side| {
                if (comptime (if (side) a else b)) {
                    const config = self.configs[slot(side)];
                    inline for (0..column_count) |j| self.words[(slot(side) * column_count + j) * self.capacity + lane] = 0;
                    self.words[(slot(side) * column_count + @intFromEnum(Column.rage)) * self.capacity + lane] = @bitCast(@min(config.starting_rage, config.effects().max_rage[0]));
                    self.words[(slot(side) * column_count + @intFromEnum(Column.stance)) * self.capacity + lane] = @bitCast(@as(f32, @floatFromInt(@intFromEnum(config.starting_stance))));
                    self.words[(slot(side) * column_count + @intFromEnum(Column.rng)) * self.capacity + lane] = if (side) 0x9e3779b9 else 0x85ebca6b;
                }
            }
        }
    };
}

fn col(arena: anytype, comptime side: bool, comptime column: Column, i: usize) *align(64) V {
    return arena.warrior.floats(side, column, i);
}
fn base(arena: anytype, comptime side: bool, comptime field: []const u8, i: usize) *align(64) V {
    return arena.column(field, side, i);
}
fn stance(arena: anytype, comptime side: bool, i: usize) U {
    return @intFromFloat(col(arena, side, .stance, i).*);
}
pub fn modifiers(arena: anytype, comptime side: bool, i: usize) core.StanceEffects {
    var result = core.stanceEffects(stance(arena, side, i));
    const death_wish = col(arena, side, .death_wish, i).* > v(0);
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    result.melee_crit_bonus += v(0.01 * @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.cruelty)])));
    result.damage_dealt *= @select(f32, death_wish, v(1.2), v(1));
    result.damage_dealt *= @select(f32, col(arena, side, .enrage, i).* > v(0), v(1 + 0.02 * @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.enrage)]))), v(1));
    result.damage_taken *= @select(f32, death_wish, v(1.05), v(1));
    return result;
}
/// Death Wish protects against Fear, not Horror, Seduction or Polymorph.
pub fn fearImmune(arena: anytype, comptime side: bool, i: usize) B {
    if (comptime @TypeOf(arena.*).HasWarrior) {
        if (comptime (if (side) @TypeOf(arena.warrior).HasWarriorA else @TypeOf(arena.warrior).HasWarriorB)) {
            return col(arena, side, .death_wish, i).* > v(0);
        }
    }
    return @splat(false);
}
pub fn movementMultiplier(arena: anytype, comptime side: bool, i: usize) V {
    return @select(f32, col(arena, side, .bloodthirst_speed, i).* > v(0), v(1.1), v(1));
}
pub fn swingHaste(arena: anytype, comptime side: bool, i: usize) V {
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    return @select(f32, col(arena, side, .flurry_stacks, i).* > v(0), v(1 + 0.05 * @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.flurry)]))), v(1));
}
/// Resolved direct hit before armor/stance/absorption. Misses and full resists
/// pass zero. Periodic damage does not fire the reference OnSpellHitTaken hook.
pub fn receiveHit(arena: anytype, comptime side: bool, i: usize, raw: V) void {
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    const hit = both(living(arena, side, i), raw > v(0));
    if (!@reduce(.Or, hit)) return;
    if (config.damage_taken_rage) {
        const rage = col(arena, side, .rage, i);
        // Forever doubles damage-taken rage during Berserker Rage. The pinned
        // reference still marks this multiplier as needing client validation.
        const multiplier = @select(f32, col(arena, side, .berserker_rage, i).* > v(0), v(2), v(1));
        const gain = core.damageTakenRage(raw, base(arena, side, "max_health", i).*, hit) * multiplier;
        const next = @min(config.effects().max_rage, rage.* + gain);
        col(arena, side, .rage_from_hits, i).* += next - rage.*;
        rage.* = next;
    }
    if (config.build.ranks[@intFromEnum(talents.Talent.enrage)] > 0) {
        const proc = both(hit, roll(arena, side, i, hit) < v(0.3));
        col(arena, side, .enrage, i).* = @select(f32, proc, v(12), col(arena, side, .enrage, i).*);
    }
}
pub const raw_columns = .{ Column.raw_mh_white, Column.raw_oh_white, Column.raw_mh_special, Column.raw_oh_special };
pub fn clearRawHits(arena: anytype, comptime side: bool, i: usize) void {
    inline for (raw_columns) |column| col(arena, side, column, i).* = v(0);
}
fn controlled(arena: anytype, comptime side: bool, i: usize) B {
    const rage_immunity = col(arena, side, .berserker_rage, i).* > v(0);
    const fear = either(both(simd.vNot16(fearImmune(arena, side, i)), base(arena, side, "fear_timer", i).* > v(0)), base(arena, side, "horror_timer", i).* > v(0));
    const incapacitate = base(arena, side, "seduction_timer", i).* > v(0);
    return either(both(simd.vNot16(rage_immunity), either(fear, incapacitate)), base(arena, side, "stun_timer", i).* > v(0));
}
fn living(arena: anytype, comptime side: bool, i: usize) B {
    return both(arena.state.is_active[i..][0..16].* != u(0), both(base(arena, side, "hp", i).* > v(0), base(arena, !side, "hp", i).* > v(0)));
}

pub fn masks(arena: anytype, comptime side: bool, i: usize) [@import("action_catalog_generated.zig").ActionCount]B {
    var result: [@import("action_catalog_generated.zig").ActionCount]B = @splat(@as(B, @splat(false)));
    const free = both(living(arena, side, i), simd.vNot16(controlled(arena, side, i)));
    result[0] = @splat(true);
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    // Queueing reserves a future swing, but still requires its cost now.
    result[1] = both(free, both(col(arena, side, .queued_strike, i).* == v(0), col(arena, side, .rage, i).* >= v(heroicStrikeCost(config))));
    result[2] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .rage, i).* >= v(10), both(arena.state.distance[i..][0..16].* <= v(5), stance(arena, side, i) != u(2)))));
    const distance = arena.state.distance[i..][0..16].*;
    const defensive_charge = both(stance(arena, side, i) == u(2), @splat(config.build.ranks[@intFromEnum(talents.Talent.vanguard)] > 0));
    const charge_stance = either(stance(arena, side, i) == u(1), defensive_charge);
    result[3] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .charge_cd, i).* <= v(0), both(charge_stance, both(distance >= v(8), distance <= v(25))))));
    result[4] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .intercept_cd, i).* <= v(0), both(stance(arena, side, i) == u(4), both(col(arena, side, .rage, i).* >= v(10), both(distance >= v(8), distance <= v(25)))))));
    result[5] = both(free, both(@splat(config.build.ranks[@intFromEnum(talents.Talent.mortalStrike)] > 0), both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .mortal_strike_cd, i).* <= v(0), both(col(arena, side, .rage, i).* >= v(30), both(distance <= v(5), stance(arena, side, i) == u(1)))))));
    result[6] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .rage, i).* >= v(10), both(distance <= v(5), stance(arena, side, i) == u(1)))));
    result[7] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .overpower_window, i).* > v(0), both(col(arena, side, .overpower_cd, i).* <= v(0), both(col(arena, side, .rage, i).* >= v(5), both(distance <= v(5), stance(arena, side, i) == u(1)))))));
    result[8] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .execute_cd, i).* <= v(0), both(col(arena, side, .rage, i).* >= v(15), both(distance <= v(5), base(arena, !side, "hp", i).* <= base(arena, !side, "max_health", i).* * v(0.2))))));
    result[9] = both(free, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .pummel_cd, i).* <= v(0), both(stance(arena, side, i) == u(4), both(col(arena, side, .rage, i).* >= v(10), both(distance <= v(5), base(arena, !side, "cast_timer", i).* > v(0)))))));
    const fear_or_incapacitate = either(either(base(arena, side, "fear_timer", i).* > v(0), base(arena, side, "horror_timer", i).* > v(0)), base(arena, side, "seduction_timer", i).* > v(0));
    const rage_action_allowed = both(base(arena, side, "stun_timer", i).* <= v(0), either(simd.vNot16(controlled(arena, side, i)), fear_or_incapacitate));
    result[11] = both(living(arena, side, i), both(rage_action_allowed, both(base(arena, side, "gcd", i).* <= v(0), both(col(arena, side, .berserker_rage_cd, i).* <= v(0), stance(arena, side, i) == u(4)))));
    // Bloodrage is off-GCD in the pinned reference.
    result[12] = both(free, col(arena, side, .bloodrage_cd, i).* <= v(0));
    result[10] = both(living(arena, side, i), col(arena, side, .queued_strike, i).* > v(0));
    const gcd_ready = both(free, base(arena, side, "gcd", i).* <= v(0));
    result[16] = both(gcd_ready, both(@splat(config.build.ranks[@intFromEnum(talents.Talent.bloodthirst)] > 0), both(col(arena, side, .bloodthirst_cd, i).* <= v(0), both(col(arena, side, .rage, i).* >= v(30), distance <= v(5)))));
    result[23] = both(gcd_ready, both(stance(arena, side, i) == u(4), both(col(arena, side, .whirlwind_cd, i).* <= v(0), both(col(arena, side, .rage, i).* >= v(25), distance <= v(8)))));
    result[24] = both(gcd_ready, both(@splat(config.build.ranks[@intFromEnum(talents.Talent.deathWish)] > 0), both(col(arena, side, .death_wish_cd, i).* <= v(0), col(arena, side, .rage, i).* >= v(10))));
    inline for (.{ 13, 14, 15 }, .{ 1, 2, 4 }) |id, value| result[id] = both(free, both(col(arena, side, .stance_cd, i).* <= v(0), stance(arena, side, i) != u(value)));
    return result;
}

pub fn apply(arena: anytype, comptime side: bool, i: usize, requested: U, movement: V) void {
    const legal = masks(arena, side, i);
    var actions = u(0);
    inline for (0..legal.len) |id| actions = @select(u32, both(requested == u(id), legal[id]), u(id), actions);
    base(arena, side, "move_intent", i).* = @select(f32, controlled(arena, side, i), v(0), movement);
    base(arena, side, "react_timer", i).* = v(@import("combat_spec.zig").WarlockConstants.ReactionInterval);
    const queue = col(arena, side, .queued_strike, i);
    queue.* = @select(f32, actions == u(1), v(1), @select(f32, actions == u(10), v(0), queue.*));
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    var resource: core.State = .{ .rage = col(arena, side, .rage, i).*, .stance = stance(arena, side, i), .stance_cooldown = col(arena, side, .stance_cd, i).* };
    inline for (.{ 13, 14, 15 }, .{ 1, 2, 4 }) |id, value| _ = resource.switchStance(u(value), config.effects().retained_rage, actions == u(id));
    col(arena, side, .rage, i).* = resource.rage;
    col(arena, side, .stance, i).* = @floatFromInt(resource.stance);
    col(arena, side, .stance_cd, i).* = resource.stance_cooldown;
    const hamstring = actions == u(2);
    if (@reduce(.Or, hamstring)) {
        const hit = strike(arena, side, i, v(45), hamstring, config.special_hit, false, 0);
        col(arena, side, .pending_damage, i).* += hit.damage;
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[2] += hit.damage[0];
        };
        col(arena, side, .hamstring, i).* = @select(f32, both(hit.landed, @import("racials.zig").canImpair(&arena.state, !side, i)), v(15), col(arena, side, .hamstring, i).*);
        // An avoided/missed special refunds 80% of its rage cost.
        col(arena, side, .rage, i).* -= @select(f32, hamstring, @select(f32, hit.landed, v(10), v(2)), v(0));
        base(arena, side, "gcd", i).* = @select(f32, hamstring, v(1.5), base(arena, side, "gcd", i).*);
    }
    const charge = actions == u(3);
    const intercept = actions == u(4);
    const mortal_strike = actions == u(5);
    if (@reduce(.Or, charge) or @reduce(.Or, intercept)) {
        const chosen = either(charge, intercept);
        const distance: V = @bitCast(arena.state.distance[i..][0..16].*);
        const safe_distance = @max(v(0.001), distance);
        const pos_x_a: V = @bitCast(arena.state.pos_x_a[i..][0..16].*);
        const pos_x_b: V = @bitCast(arena.state.pos_x_b[i..][0..16].*);
        const pos_y_a: V = @bitCast(arena.state.pos_y_a[i..][0..16].*);
        const pos_y_b: V = @bitCast(arena.state.pos_y_b[i..][0..16].*);
        const dx = pos_x_b - pos_x_a;
        const dy = pos_y_b - pos_y_a;
        const target_x = if (side) pos_x_b - dx * v(GapCloseDistance) / safe_distance else pos_x_a + dx * v(GapCloseDistance) / safe_distance;
        const target_y = if (side) pos_y_b - dy * v(GapCloseDistance) / safe_distance else pos_y_a + dy * v(GapCloseDistance) / safe_distance;
        if (side) {
            arena.state.pos_x_a[i..][0..16].* = @select(f32, chosen, target_x, arena.state.pos_x_a[i..][0..16].*);
            arena.state.pos_y_a[i..][0..16].* = @select(f32, chosen, target_y, arena.state.pos_y_a[i..][0..16].*);
        } else {
            arena.state.pos_x_b[i..][0..16].* = @select(f32, chosen, target_x, arena.state.pos_x_b[i..][0..16].*);
            arena.state.pos_y_b[i..][0..16].* = @select(f32, chosen, target_y, arena.state.pos_y_b[i..][0..16].*);
        }
        arena.state.distance[i..][0..16].* = @select(f32, chosen, v(GapCloseDistance), distance);
        base(arena, side, "gcd", i).* = @select(f32, chosen, v(1.5), base(arena, side, "gcd", i).*);
        col(arena, side, .charge_cd, i).* = @select(f32, charge, v(15), col(arena, side, .charge_cd, i).*);
        const intercept_talent = @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.improvedIntercept)]));
        col(arena, side, .intercept_cd, i).* = @select(f32, intercept, v(30 - 5 * intercept_talent), col(arena, side, .intercept_cd, i).*);
        col(arena, side, .rage, i).* = @min(config.effects().max_rage, col(arena, side, .rage, i).* + @select(f32, charge, v(9 + 3 * @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.improvedCharge)]))), v(0))) - @select(f32, intercept, v(10), v(0));
        if (@reduce(.Or, intercept)) {
            const hit = strike(arena, side, i, v(65), intercept, config.special_hit, false, 0);
            col(arena, side, .pending_damage, i).* += hit.damage;
            stun(arena, side, i, hit.landed, 3);
            if (i == 0) if (arena.warrior.recording) |record| {
                record[if (side) 0 else 1].damage[4] += hit.damage[0];
            };
        }
        stun(arena, side, i, charge, 1);
    }
    if (@reduce(.Or, mortal_strike)) {
        const weapon = config.main_hand;
        const normalized_speed: f32 = if (weapon.two_handed) 3.3 else 2.4;
        const damage = core.weaponDamage(v(weapon.min), v(weapon.max), roll(arena, side, i, mortal_strike), v(config.attack_power), v(normalized_speed)) + v(160);
        const hit = strike(arena, side, i, damage, mortal_strike, config.special_hit, false, 0);
        col(arena, side, .pending_damage, i).* += hit.damage;
        col(arena, side, .mortal_strike_cd, i).* = @select(f32, mortal_strike, v(6), col(arena, side, .mortal_strike_cd, i).*);
        col(arena, side, .mortal_strike, i).* = @select(f32, hit.landed, v(10), col(arena, side, .mortal_strike, i).*);
        // Mortal Strike refunds 80% of its rage cost when it misses or is avoided.
        col(arena, side, .rage, i).* -= @select(f32, mortal_strike, @select(f32, hit.landed, v(30), v(6)), v(0));
        base(arena, side, "gcd", i).* = @select(f32, mortal_strike, v(1.5), base(arena, side, "gcd", i).*);
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[5] += hit.damage[0];
        };
    }
    const bloodthirst = actions == u(16);
    if (@reduce(.Or, bloodthirst)) {
        const hit = strike(arena, side, i, v(48 + 0.35 * config.attack_power), bloodthirst, config.special_hit, false, 0);
        col(arena, side, .pending_damage, i).* += hit.damage;
        col(arena, side, .rage, i).* -= @select(f32, bloodthirst, @select(f32, hit.landed, v(30), v(6)), v(0));
        col(arena, side, .bloodthirst_cd, i).* = @select(f32, bloodthirst, v(6), col(arena, side, .bloodthirst_cd, i).*);
        // The movement aura accompanies a landed attack; Blood Craze healing is separate.
        col(arena, side, .bloodthirst_speed, i).* = @select(f32, hit.landed, v(10), col(arena, side, .bloodthirst_speed, i).*);
        base(arena, side, "gcd", i).* = @select(f32, bloodthirst, v(1.5), base(arena, side, "gcd", i).*);
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[16] += hit.damage[0];
        };
    }
    const whirlwind = actions == u(23);
    if (@reduce(.Or, whirlwind)) {
        const weapon = config.main_hand;
        const damage = core.weaponDamage(v(weapon.min), v(weapon.max), roll(arena, side, i, whirlwind), v(config.attack_power), v(if (weapon.two_handed) 3.3 else 2.4));
        var dealt = strike(arena, side, i, damage, whirlwind, config.special_hit, false, 0).damage;
        if (config.off_hand) |off| {
            if (config.build.ranks[@intFromEnum(talents.Talent.ragingBlows)] > 0) {
                const off_damage = core.weaponDamage(v(off.min), v(off.max), roll(arena, side, i, whirlwind), v(config.attack_power), v(2.4));
                dealt += strike(arena, side, i, off_damage, whirlwind, config.special_hit, true, 0).damage;
            }
        }
        col(arena, side, .pending_damage, i).* += dealt;
        // Whirlwind has no miss refund in the reference implementation.
        col(arena, side, .rage, i).* -= @select(f32, whirlwind, v(25), v(0));
        col(arena, side, .whirlwind_cd, i).* = @select(f32, whirlwind, v(10), col(arena, side, .whirlwind_cd, i).*);
        base(arena, side, "gcd", i).* = @select(f32, whirlwind, v(1.5), base(arena, side, "gcd", i).*);
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[23] += dealt[0];
        };
    }
    const death_wish = actions == u(24);
    col(arena, side, .rage, i).* -= @select(f32, death_wish, v(10), v(0));
    col(arena, side, .death_wish, i).* = @select(f32, death_wish, v(30), col(arena, side, .death_wish, i).*);
    col(arena, side, .death_wish_cd, i).* = @select(f32, death_wish, v(180), col(arena, side, .death_wish_cd, i).*);
    base(arena, side, "gcd", i).* = @select(f32, death_wish, v(1.5), base(arena, side, "gcd", i).*);
    const execute = actions == u(8);
    if (@reduce(.Or, execute)) {
        const extra_rage = @min(v(30), @max(v(0), col(arena, side, .rage, i).* - v(15)));
        const hit = strike(arena, side, i, v(600) + extra_rage * v(15), execute, config.special_hit, false, 0);
        col(arena, side, .pending_damage, i).* += hit.damage;
        col(arena, side, .rage, i).* -= @select(f32, execute, @select(f32, hit.landed, v(15) + extra_rage, v(3)), v(0));
        col(arena, side, .execute_cd, i).* = @select(f32, execute, v(ExecuteCooldown), col(arena, side, .execute_cd, i).*);
        base(arena, side, "gcd", i).* = @select(f32, execute, v(1.5), base(arena, side, "gcd", i).*);
        if (i == 0) {
            if (arena.warrior.recording) |record| record[if (side) 0 else 1].damage[8] += hit.damage[0];
        }
    }
    const pummel = actions == u(9);
    if (@reduce(.Or, pummel)) {
        const hit = strike(arena, side, i, v(50), pummel, config.special_hit, false, 0);
        col(arena, side, .pending_damage, i).* += hit.damage;
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[9] += hit.damage[0];
        };
        const target_cast = base(arena, !side, "cast_timer", i);
        const interrupted = both(hit.landed, target_cast.* > v(0));
        target_cast.* = @select(f32, interrupted, v(0), target_cast.*);
        base(arena, !side, "cast_total", i).* = @select(f32, interrupted, v(0), base(arena, !side, "cast_total", i).*);
        arena.extra(.lockout, !side, i).* = @select(f32, interrupted, v(PummelLockout), arena.extra(.lockout, !side, i).*);
        col(arena, side, .rage, i).* -= @select(f32, pummel, @select(f32, hit.landed, v(10), v(2)), v(0));
        col(arena, side, .pummel_cd, i).* = @select(f32, pummel, v(PummelCooldown), col(arena, side, .pummel_cd, i).*);
        base(arena, side, "gcd", i).* = @select(f32, pummel, v(1.5), base(arena, side, "gcd", i).*);
    }
    const berserker_rage = actions == u(11);
    if (@reduce(.Or, berserker_rage)) {
        base(arena, side, "fear_timer", i).* = @select(f32, berserker_rage, v(0), base(arena, side, "fear_timer", i).*);
        base(arena, side, "horror_timer", i).* = @select(f32, berserker_rage, v(0), base(arena, side, "horror_timer", i).*);
        base(arena, side, "seduction_timer", i).* = @select(f32, berserker_rage, v(0), base(arena, side, "seduction_timer", i).*);
        const talent_rage: f32 = switch (config.build.ranks[@intFromEnum(talents.Talent.improvedBerserkerRage)]) {
            1 => 5,
            2 => 10,
            else => 0,
        };
        col(arena, side, .rage, i).* = @min(config.effects().max_rage, col(arena, side, .rage, i).* + @select(f32, berserker_rage, v(talent_rage), v(0)));
        col(arena, side, .berserker_rage, i).* = @select(f32, berserker_rage, v(10), col(arena, side, .berserker_rage, i).*);
        col(arena, side, .berserker_rage_cd, i).* = @select(f32, berserker_rage, v(30), col(arena, side, .berserker_rage_cd, i).*);
        base(arena, side, "gcd", i).* = @select(f32, berserker_rage, v(1.5), base(arena, side, "gcd", i).*);
    }
    const bloodrage = actions == u(12);
    if (@reduce(.Or, bloodrage)) {
        const rank: u8 = config.build.ranks[@intFromEnum(talents.Talent.improvedBloodrage)];
        const rage_multiplier: f32 = switch (rank) {
            1 => 1.25,
            2 => 1.5,
            else => 1,
        };
        col(arena, side, .rage, i).* = @min(config.effects().max_rage, col(arena, side, .rage, i).* + @select(f32, bloodrage, v(10 * rage_multiplier), v(0)));
        col(arena, side, .bloodrage_timer, i).* = @select(f32, bloodrage, v(10), col(arena, side, .bloodrage_timer, i).*);
        col(arena, side, .bloodrage_phase, i).* = @select(f32, bloodrage, v(0), col(arena, side, .bloodrage_phase, i).*);
        col(arena, side, .bloodrage_cd, i).* = @select(f32, bloodrage, v(60), col(arena, side, .bloodrage_cd, i).*);
    }
    const overpower = actions == u(7);
    if (@reduce(.Or, overpower)) {
        const weapon = config.main_hand;
        const normalized_speed: f32 = if (weapon.two_handed) 3.3 else 2.4;
        const talent_rank = config.build.ranks[@intFromEnum(talents.Talent.improvedOverpower)];
        const crit_bonus: f32 = switch (talent_rank) {
            1 => 0.25,
            2 => 0.50,
            else => 0,
        };
        const damage = core.weaponDamage(v(weapon.min), v(weapon.max), roll(arena, side, i, overpower), v(config.attack_power), v(normalized_speed)) + v(35);
        const hit = strike(arena, side, i, damage, overpower, config.special_hit, false, crit_bonus);
        col(arena, side, .pending_damage, i).* += hit.damage;
        col(arena, side, .overpower_window, i).* = @select(f32, overpower, v(0), col(arena, side, .overpower_window, i).*);
        col(arena, side, .overpower_cd, i).* = @select(f32, overpower, v(5), col(arena, side, .overpower_cd, i).*);
        col(arena, side, .rage, i).* -= @select(f32, overpower, @select(f32, hit.landed, v(5), v(1)), v(0));
        base(arena, side, "gcd", i).* = @select(f32, overpower, v(1.5), base(arena, side, "gcd", i).*);
        if (i == 0) if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[7] += hit.damage[0];
        };
    }
    const rend = actions == u(6);
    if (@reduce(.Or, rend)) {
        const hit = meleeApplication(arena, side, i, rend);
        col(arena, side, .rend, i).* = @select(f32, hit, v(21), col(arena, side, .rend, i).*);
        col(arena, side, .rage, i).* -= @select(f32, rend, @select(f32, hit, v(10), v(2)), v(0));
        base(arena, side, "gcd", i).* = @select(f32, rend, v(1.5), base(arena, side, "gcd", i).*);
    }
}

fn meleeApplication(arena: anytype, comptime side: bool, i: usize, mask: B) B {
    if (!@reduce(.Or, mask)) return @splat(false);
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    const table = config.target_melee;
    const dodge = if (table.configured) v(table.dodge) else base(arena, !side, "melee_avoidance_chance", i).*;
    const result = resolution.meleeRolls(v(0), v(config.special_hit), dodge, v(table.parry), v(table.block), v(table.block_value), v(0), v(2), .{ roll(arena, side, i, mask), roll(arena, side, i, mask), roll(arena, side, i, mask) }, mask);
    col(arena, side, .last_outcome, i).* = @select(f32, mask, @as(V, @floatFromInt(result.outcome)), col(arena, side, .last_outcome, i).*);
    const dodged = both(mask, result.outcome == u(@intFromEnum(resolution.Outcome.dodge)));
    col(arena, side, .overpower_window, i).* = @select(f32, dodged, v(5), col(arena, side, .overpower_window, i).*);
    return result.landed;
}

fn stun(arena: anytype, comptime side: bool, i: usize, landed: B, base_duration: f32) void {
    if (!@reduce(.Or, landed)) return;
    const tier = base(arena, !side, "stun_dr_tier", i);
    const reset = base(arena, !side, "stun_dr_timer", i);
    const duration = v(base_duration) * @import("combat_spec.zig").getDrMultiplier(tier.*);
    const applied = both(landed, duration > v(0));
    const timer = base(arena, !side, "stun_timer", i);
    timer.* = @select(f32, applied, @max(timer.*, duration), timer.*);
    tier.* = @select(f32, applied, @min(v(3), tier.* + v(1)), tier.*);
    reset.* = @select(f32, applied, v(@import("combat_spec.zig").WarlockConstants.DrResetDuration), reset.*);
    const cast_id = arena.castIds(!side, i);
    cast_id.* = @select(u32, applied, u(0), cast_id.*);
    inline for (.{ "cast_timer", "cast_total", "move_intent", "react_timer" }) |field| {
        const value = arena.column(field, !side, i);
        value.* = @select(f32, applied, v(0), value.*);
    }
}

fn roll(arena: anytype, comptime side: bool, i: usize, mask: B) V {
    const rng = arena.warrior.integers(side, .rng, i);
    const old = rng.*;
    var next = @select(u32, old == u(0), u(0x6d2b79f5), old);
    next ^= next << @as(@Vector(16, u5), @splat(13));
    next ^= next >> @as(@Vector(16, u5), @splat(17));
    next ^= next << @as(@Vector(16, u5), @splat(5));
    rng.* = @select(u32, mask, next, old);
    return @as(V, @floatFromInt(next >> @as(@Vector(16, u5), @splat(8)))) * v(1.0 / 16777216.0);
}

fn strike(arena: anytype, comptime side: bool, i: usize, damage: V, mask: B, hit_chance: f32, comptime offhand: bool, crit_bonus: f32) resolution.Result {
    return strikeImpl(arena, side, i, damage, mask, hit_chance, offhand, crit_bonus, false);
}
fn strikeImpl(arena: anytype, comptime side: bool, i: usize, damage: V, mask: B, hit_chance: f32, comptime offhand: bool, crit_bonus: f32, comptime white: bool) resolution.Result {
    if (!@reduce(.Or, mask)) return .{ .damage = v(0), .landed = @splat(false), .outcome = u(0) };
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    const crit = v(config.crit + crit_bonus) + modifiers(arena, side, i).melee_crit_bonus;
    const table = config.target_melee;
    const dodge = if (table.configured) v(table.dodge) else base(arena, !side, "melee_avoidance_chance", i).*;
    const off_rank = @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.dualWieldSpecialization)]));
    const hit_bonus = 0.01 * @as(f32, @floatFromInt(config.build.ranks[@intFromEnum(talents.Talent.precision)])) + (if (offhand) 0.02 * off_rank else @as(f32, 0));
    const hand_mult = if (offhand) 0.5 * (1 + 0.05 * off_rank) else @as(f32, 1);
    const resolved = resolution.meleeRolls(damage * modifiers(arena, side, i).damage_dealt * v(hand_mult), v(@min(1, hit_chance + hit_bonus)), dodge, v(table.parry), v(table.block), v(table.block_value), crit, v(2), .{ roll(arena, side, i, mask), roll(arena, side, i, mask), roll(arena, side, i, mask) }, mask);
    const raw_column: Column = if (white) (if (offhand) .raw_oh_white else .raw_mh_white) else (if (offhand) .raw_oh_special else .raw_mh_special);
    col(arena, side, raw_column, i).* += resolved.damage;
    if (config.build.ranks[@intFromEnum(talents.Talent.flurry)] > 0) {
        const critical = both(mask, resolved.outcome == u(@intFromEnum(resolution.Outcome.crit)));
        col(arena, side, .flurry_stacks, i).* = @select(f32, critical, v(3), col(arena, side, .flurry_stacks, i).*);
    }
    const dodged = both(mask, resolved.outcome == u(@intFromEnum(resolution.Outcome.dodge)));
    col(arena, side, .overpower_window, i).* = @select(f32, dodged, v(5), col(arena, side, .overpower_window, i).*);
    const armor = base(arena, !side, "armor_damage_reduction", i).*;
    const inner_timer = base(arena, !side, "inner_fire_timer", i);
    const inner_charges = base(arena, !side, "inner_fire_charges", i);
    const inner = both(inner_timer.* > v(0), inner_charges.* > v(0));
    const armor_value = armor * v(5500) / @max(v(0.001), v(1) - armor);
    const bonus = v(@import("spec.zig").Priest.InnerFireArmor);
    const effective_armor = @select(f32, inner, (armor_value + bonus) / (armor_value + bonus + v(5500)), armor);
    const consumed = both(inner, resolved.landed);
    inner_charges.* = @select(f32, consumed, @max(v(0), inner_charges.* - v(1)), inner_charges.*);
    inner_timer.* = @select(f32, both(consumed, inner_charges.* <= v(0)), v(0), inner_timer.*);
    col(arena, side, .last_outcome, i).* = @select(f32, mask, @as(V, @floatFromInt(resolved.outcome)), col(arena, side, .last_outcome, i).*);
    return .{ .damage = resolved.damage * (v(1) - effective_armor), .landed = resolved.landed, .outcome = resolved.outcome };
}

fn swing(arena: anytype, comptime side: bool, i: usize, comptime offhand: bool, dt: f32, eligible: B) V {
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    const weapon = if (offhand) config.off_hand orelse return v(0) else config.main_hand;
    const timer = col(arena, side, if (offhand) .off_swing else .main_swing, i);
    timer.* = @select(f32, living(arena, side, i), @max(v(0), timer.* - v(dt) * swingHaste(arena, side, i)), timer.*);
    const ready = both(eligible, timer.* <= v(0));
    if (!@reduce(.Or, ready)) return v(0);
    const rage = col(arena, side, .rage, i);
    const heroic_cost = heroicStrikeCost(config);
    const heroic = if (offhand) @as(B, @splat(false)) else both(ready, both(col(arena, side, .queued_strike, i).* > v(0), rage.* >= v(heroic_cost)));
    const white_attempt = both(ready, simd.vNot16(heroic));
    // White-hit proc flags also cover the queued Heroic Strike replacement.
    const consume = both(ready, both(col(arena, side, .flurry_stacks, i).* > v(0), col(arena, side, .flurry_icd, i).* <= v(0)));
    col(arena, side, .flurry_stacks, i).* = @select(f32, consume, @max(v(0), col(arena, side, .flurry_stacks, i).* - v(1)), col(arena, side, .flurry_stacks, i).*);
    col(arena, side, .flurry_icd, i).* = @select(f32, consume, v(0.5), col(arena, side, .flurry_icd, i).*);
    const damage = core.weaponDamage(v(weapon.min), v(weapon.max), roll(arena, side, i, ready), v(config.attack_power), v(weapon.speed)) + @select(f32, heroic, v(157), v(0));
    // Specials and white swings have explicitly configured hit probabilities;
    // dual-wield white miss penalties are not silently guessed from Vanilla.
    const whites = strikeImpl(arena, side, i, damage, white_attempt, config.white_hit, offhand, 0, true);
    const special = if (offhand) resolution.Result{ .damage = v(0), .landed = @splat(false), .outcome = u(0) } else strike(arena, side, i, damage, heroic, config.special_hit, false, 0);
    const generated = core.whiteHitRage(v(weapon.speed), @splat(weapon.two_handed), @splat(offhand), config.effects(), whites.landed);
    var wrath = v(0);
    const wrath_rank = config.build.ranks[@intFromEnum(talents.Talent.unbridledWrath)];
    if (wrath_rank > 0) {
        // Queued Heroic Strike has the white-hit proc flag too. It can proc
        // Unbridled Wrath, while its combined flags exclude normal white rage.
        const proc_eligible = either(whites.landed, special.landed);
        wrath = @select(f32, both(proc_eligible, roll(arena, side, i, proc_eligible) < v(0.12 * @as(f32, @floatFromInt(wrath_rank)))), v(if (config.main_hand.two_handed) 2 else 1), v(0));
    }
    // Spend/refund Heroic Strike before its on-hit resource procs, matching
    // the reference ordering and avoiding lost proc rage at the cap.
    const after_cost = rage.* - @select(f32, heroic, @select(f32, special.landed, v(heroic_cost), v(heroic_cost * 0.2)), v(0));
    const after_white = @min(config.effects().max_rage, after_cost + generated);
    const after_wrath = @min(config.effects().max_rage, after_white + wrath);
    col(arena, side, .rage_from_wrath, i).* += after_wrath - after_white;
    rage.* = after_wrath;
    if (!offhand) col(arena, side, .queued_strike, i).* = @select(f32, ready, v(0), col(arena, side, .queued_strike, i).*);
    timer.* = @select(f32, ready, v(weapon.speed), timer.*);
    if (i == 0) if (arena.warrior.recording) |record| {
        record[if (side) 0 else 1].damage[if (offhand) 22 else if (heroic[0]) 1 else 21] += whites.damage[0] + special.damage[0];
    };
    return whites.damage + special.damage;
}

pub fn tick(arena: anytype, comptime side: bool, i: usize, dt: f32) V {
    const active = living(arena, side, i);
    col(arena, side, .stance_cd, i).* = @select(f32, active, @max(v(0), col(arena, side, .stance_cd, i).* - v(dt)), col(arena, side, .stance_cd, i).*);
    inline for (.{ .charge_cd, .intercept_cd, .mortal_strike_cd, .mortal_strike, .rend, .overpower_window, .overpower_cd, .execute_cd, .pummel_cd, .berserker_rage_cd, .berserker_rage, .bloodrage_cd, .bloodthirst_cd, .bloodthirst_speed, .whirlwind_cd, .death_wish_cd, .death_wish, .enrage, .flurry_icd }) |timer| col(arena, side, timer, i).* = @select(f32, active, @max(v(0), col(arena, side, timer, i).* - v(dt)), col(arena, side, timer, i).*);
    const bloodrage_timer = col(arena, side, .bloodrage_timer, i);
    const bloodrage_phase = col(arena, side, .bloodrage_phase, i);
    const bloodrage_elapsed = @select(f32, active, @min(bloodrage_timer.*, v(dt)), v(0));
    const bloodrage_accumulated = bloodrage_phase.* + bloodrage_elapsed;
    const bloodrage_ticks = @select(f32, active, @floor(bloodrage_accumulated + v(0.00001)), v(0));
    const bloodrage_rank: u8 = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)].build.ranks[@intFromEnum(talents.Talent.improvedBloodrage)];
    const bloodrage_multiplier: f32 = switch (bloodrage_rank) {
        1 => 1.25,
        2 => 1.5,
        else => 1,
    };
    col(arena, side, .rage, i).* = @min(arena.warrior.configs[@TypeOf(arena.warrior).slot(side)].effects().max_rage, col(arena, side, .rage, i).* + bloodrage_ticks * v(bloodrage_multiplier));
    bloodrage_timer.* = @select(f32, active, @max(v(0), bloodrage_timer.* - v(dt)), bloodrage_timer.*);
    bloodrage_phase.* = @select(f32, bloodrage_timer.* > v(0), bloodrage_accumulated - bloodrage_ticks, v(0));
    const rage_immunity = col(arena, side, .berserker_rage, i).* > v(0);
    base(arena, side, "fear_timer", i).* = @select(f32, either(rage_immunity, fearImmune(arena, side, i)), v(0), base(arena, side, "fear_timer", i).*);
    base(arena, side, "horror_timer", i).* = @select(f32, rage_immunity, v(0), base(arena, side, "horror_timer", i).*);
    base(arena, side, "seduction_timer", i).* = @select(f32, rage_immunity, v(0), base(arena, side, "seduction_timer", i).*);
    const slow = col(arena, side, .hamstring, i);
    slow.* = @select(f32, active, @max(v(0), slow.* - v(dt)), slow.*);
    slow.* = @select(f32, @import("racials.zig").canImpair(&arena.state, !side, i), slow.*, v(0));
    const eligible = both(active, both(simd.vNot16(controlled(arena, side, i)), arena.state.distance[i..][0..16].* <= v(5)));
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    const rend_ticks = @import("periodic.zig").advance(
        &arena.state,
        side,
        i,
        col(arena, side, .rend, i),
        dt,
        21,
        3,
        v(7),
        v(0),
        active,
        .{ .school = .holy, .crit_bonus = v(config.crit), .crit_multiplier = v(2), .can_crit = true, .partial = false },
    );
    const rend_bonus: f32 = switch (config.build.ranks[@intFromEnum(talents.Talent.improvedRend)]) {
        1 => 0.12,
        2 => 0.23,
        3 => 0.35,
        else => 0,
    };
    const rend_damage = rend_ticks.damage * v(1 + rend_bonus) * modifiers(arena, side, i).damage_dealt;
    if (i == 0) {
        if (arena.warrior.recording) |record| {
            record[if (side) 0 else 1].damage[6] += rend_damage[0];
        }
    }
    const damage = swing(arena, side, i, false, dt, eligible) + swing(arena, side, i, true, dt, eligible) + @select(f32, active, col(arena, side, .pending_damage, i).*, v(0)) + rend_damage;
    col(arena, side, .pending_damage, i).* = v(0);
    col(arena, side, .last_damage, i).* = damage;
    return damage;
}

pub fn observations(arena: anytype, comptime side: bool, i: usize, original: [24]V) [24]V {
    var result = original;
    const config = arena.warrior.configs[@TypeOf(arena.warrior).slot(side)];
    result[1] = col(arena, side, .rage, i).* / config.effects().max_rage;
    result[9] = col(arena, side, .main_swing, i).* / v(config.main_hand.speed);
    result[11] = col(arena, side, .queued_strike, i).*;
    result[12] = col(arena, side, .hamstring, i).* / v(15);
    result[13] = col(arena, side, .stance_cd, i).*;
    result[14] = @select(f32, stance(arena, side, i) == u(1), v(1), v(0));
    result[15] = @select(f32, stance(arena, side, i) == u(2), v(1), v(0));
    result[16] = @select(f32, stance(arena, side, i) == u(4), v(1), v(0));
    result[17] = col(arena, side, .charge_cd, i).* / v(15);
    result[18] = col(arena, side, .intercept_cd, i).* / v(30);
    result[19] = col(arena, side, .mortal_strike_cd, i).* / v(6);
    result[20] = col(arena, side, .mortal_strike, i).* / v(10);
    result[21] = col(arena, side, .overpower_window, i).* / v(5);
    result[22] = col(arena, side, .overpower_cd, i).* / v(5);
    result[23] = col(arena, side, .berserker_rage, i).* / v(10);
    return result;
}

/// Healing received is reduced by an active enemy Warrior Mortal Strike.
pub fn healingTakenMultiplier(arena: anytype, comptime side: bool, i: usize) V {
    if (comptime @TypeOf(arena.*).HasWarrior) {
        const opponent_is_warrior = if (side) @TypeOf(arena.warrior).HasWarriorB else @TypeOf(arena.warrior).HasWarriorA;
        if (comptime opponent_is_warrior) {
            return @select(f32, col(arena, !side, .mortal_strike, i).* > v(0), v(0.5), v(1));
        }
    }
    return v(1);
}
