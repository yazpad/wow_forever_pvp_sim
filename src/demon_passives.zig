//! Forever pet-dependent passives. Read live state rather than cached effects.
const simd = @import("simd.zig");
const V = simd.f32x16;
const U = simd.u32x16;
fn v(x: f32) V {
    return @splat(x);
}
fn col(state: anytype, comptime name: []const u8, comptime side: bool, i: usize) V {
    return @field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16].*;
}
fn rank(state: anytype, comptime side: bool, i: usize, comptime shift: u5, comptime mask: u32) V {
    const extra: U = @field(state, "talent_extra" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    return @floatFromInt((extra >> @as(@Vector(16, u5), @splat(shift))) & @as(U, @splat(mask)));
}
fn active(state: anytype, comptime side: bool, i: usize) @Vector(16, bool) {
    const kinds: U = @field(state, "pet_kind" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    return simd.vAnd16(kinds != @as(U, @splat(0)), simd.vAnd16(col(state, "pet_hp", side, i) > v(0), col(state, "hp", side, i) > v(0)));
}
pub fn knowledge(state: anytype, comptime side: bool, i: usize) V {
    const r = rank(state, side, i, 15, 3);
    const fraction = @select(f32, r == v(1), v(0.33), @select(f32, r == v(2), v(0.67), @select(f32, r == v(3), v(1), v(0))));
    return @select(f32, active(state, side, i), fraction * col(state, "level", side, i), v(0));
}
fn kindBonus(state: anytype, comptime side: bool, i: usize, comptime kind: u32) V {
    const kinds: U = @field(state, "pet_kind" ++ (if (side) "_a" else "_b"))[i..][0..16].*;
    return @select(f32, simd.vAnd16(active(state, side, i), kinds == @as(U, @splat(kind))), rank(state, side, i, 17, 7) * v(0.02), v(0));
}
pub fn magicTaken(state: anytype, comptime side: bool, i: usize) V {
    return v(1) - kindBonus(state, side, i, 3);
}
pub fn physicalTaken(state: anytype, comptime side: bool, i: usize) V {
    return v(1) - kindBonus(state, side, i, 4);
}
/// Owner effects. Pet Fire damage is handled at the pet attack source.
pub fn effects(state: anytype, comptime side: bool, i: usize, fx: *@import("warlock_talents.zig").Effects) void {
    const fire = v(1) + kindBonus(state, side, i, 1);
    const shadow = v(1) + kindBonus(state, side, i, 2);
    fx.fire_damage *= fire;
    fx.immolate_initial_damage *= fire;
    inline for (.{ "shadow_damage", "agony_damage", "corruption_damage", "drain_life_damage", "drain_life_healing", "siphon_life_damage", "siphon_life_healing" }) |name| @field(fx, name) *= shadow;
    fx.damage_taken *= magicTaken(state, side, i);
}
pub fn petFireMultiplier(state: anytype, comptime side: bool, i: usize) V {
    return v(1) + kindBonus(state, side, i, 1);
}
// Pet melee is Physical; the current kit has no pet Shadow damage spell.
pub fn petMitigation(state: anytype, comptime target: bool, i: usize, magic_mitigation: V) V {
    const attacker: U = @field(state, "pet_kind" ++ (if (target) "_b" else "_a"))[i..][0..16].*;
    const melee = magic_mitigation / magicTaken(state, target, i) * physicalTaken(state, target, i);
    return @select(f32, attacker == @as(U, @splat(1)), magic_mitigation, melee);
}

test "demon passives decode each pet and rank dynamically across both sides" {
    const std = @import("std");
    const spec = @import("spec.zig");
    const talents = @import("warlock_talents.zig");
    const resolution = @import("spell_resolution.zig");
    var pool = try @import("combat_spec.zig").WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    inline for (.{ true, false }) |side| {
        const suffix = if (side) "_a" else "_b";
        for (0..6) |md| {
            for (0..16) |lane| {
                const ranks = spec.WarlockTalentRanks{ .demonic_knowledge = @intCast(lane % 4), .master_demonologist = @intCast(md), .demonic_embrace = 5, .fel_vitality = 3 };
                const words = ranks.encode();
                @field(pool, "talent_extra" ++ suffix)[lane] = @truncate(words >> 64);
                @field(pool, "pet_kind" ++ suffix)[lane] = @intCast(lane % 5);
                @field(pool, "pet_hp" ++ suffix)[lane] = if (lane < 10) 500 else 0;
                @field(pool, "level" ++ suffix)[lane] = 60;
                @field(pool, "shadow_power" ++ suffix)[lane] = 100;
            }
            const power = resolution.spellPower(&pool, side, 0, .shadow);
            const magic = magicTaken(&pool, side, 0);
            const physical = physicalTaken(&pool, side, 0);
            var fx = talents.decode(@splat(0), @splat(0));
            effects(&pool, side, 0, &fx);
            for (0..16) |lane| {
                const live = lane < 10 and lane % 5 != 0;
                const fraction: f32 = switch (lane % 4) {
                    1 => 0.33,
                    2 => 0.67,
                    3 => 1,
                    else => 0,
                };
                try std.testing.expectApproxEqAbs(@as(f32, 100) + (if (live) fraction * 60 else 0), power[lane], 0.001);
                const bonus: f32 = @as(f32, @floatFromInt(md)) * 0.02;
                try std.testing.expectApproxEqAbs(@as(f32, 1) - (if (live and lane % 5 == 3) bonus else 0), magic[lane], 0.001);
                try std.testing.expectApproxEqAbs(@as(f32, 1) - (if (live and lane % 5 == 4) bonus else 0), physical[lane], 0.001);
                try std.testing.expectApproxEqAbs(@as(f32, 1) + (if (live and lane % 5 == 1) bonus else 0), fx.fire_damage[lane], 0.001);
                try std.testing.expectApproxEqAbs(@as(f32, 1) + (if (live and lane % 5 == 2) bonus else 0), fx.corruption_damage[lane], 0.001);
            }
        }
    }
}

test "demon passives affect cached search ticks and disappear on pet death with snapshot replay" {
    const std = @import("std");
    const search = @import("search_sim.zig");
    const spec = @import("spec.zig");
    inline for (.{ .{ .warlock, .warlock }, .{ .warlock, .frost_mage }, .{ .frost_mage, .warlock } }) |pair| {
        inline for (.{ true, false }) |side| {
            if ((if (side) pair[0] else pair[1]) != .warlock) continue;
            var duel = try search.Duel(pair[0], pair[1]).init(std.testing.allocator);
            defer duel.deinit();
            const words = (spec.WarlockTalentRanks{ .demonic_knowledge = 3, .master_demonologist = 5 }).encode();
            if (side) duel.setWarlockTalentRanksA(words) else duel.setWarlockTalentRanksB(words);
            const state = duel.arena.combat();
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @field(state, "pet_kind" ++ own)[0] = 2;
            @field(state, "pet_hp" ++ own)[0] = 500;
            @field(state, "pet_timer" ++ own)[0] = 100;
            @field(state, "pet_kind" ++ target)[0] = 0;
            @field(state, "corruption_timer" ++ target)[0] = 14;
            const before = duel.snapshot(0);
            // One 2-second Corruption tick, with level-60 Knowledge and Succubus MD.
            for (0..200) |_| duel.tick(1000);
            const expected: f32 = (50 + 60.0 / 18.0) * 2 * 1.1;
            try std.testing.expectApproxEqAbs(@as(f32, 2000) - expected, @field(state, "hp" ++ target)[0], 0.02);
            const after = duel.snapshot(0);
            duel.restore(0, before);
            for (0..200) |_| duel.tick(1000);
            try std.testing.expectEqualDeep(after, duel.snapshot(0));
            duel.restore(0, before);
            @field(state, "pet_hp" ++ own)[0] = 0;
            for (0..200) |_| duel.tick(1000);
            try std.testing.expectApproxEqAbs(@as(f32, 1900), @field(state, "hp" ++ target)[0], 0.02);
        }
    }
}

test "demon passives mitigate incoming pet magic and physical attacks separately" {
    const std = @import("std");
    var pool = try @import("combat_spec.zig").WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    inline for (.{ true, false }) |target| {
        const own = if (target) "_a" else "_b";
        const enemy = if (target) "_b" else "_a";
        inline for (.{ @as(u32, 1), @as(u32, 2) }) |source_kind| {
            pool.resetAll();
            for (0..16) |lane| {
                const words = (@import("spec.zig").WarlockTalentRanks{ .master_demonologist = 5 }).encode();
                @field(pool, "talent_extra" ++ own)[lane] = @truncate(words >> 64);
                @field(pool, "pet_kind" ++ own)[lane] = if (lane % 2 == 0) 3 else 4;
                @field(pool, "pet_hp" ++ own)[lane] = 500;
                @field(pool, "pet_timer" ++ own)[lane] = 100;
                @field(pool, "pet_kind" ++ enemy)[lane] = source_kind;
                @field(pool, "pet_hp" ++ enemy)[lane] = 500;
                @field(pool, "pet_timer" ++ enemy)[lane] = 0;
                @field(pool, "pet_x" ++ enemy)[lane] = @field(pool, "pos_x" ++ own)[lane];
                @field(pool, "pet_y" ++ enemy)[lane] = @field(pool, "pos_y" ++ own)[lane];
            }
            _ = pool.tickPhysics16(0.01, 0);
            for (0..16) |lane| {
                const reduced = (source_kind == 1 and lane % 2 == 0) or (source_kind == 2 and lane % 2 == 1);
                const base: f32 = if (source_kind == 1) 60 else 50;
                const expected: f32 = 2000 - base * (if (reduced) @as(f32, 0.9) else 1);
                try std.testing.expectApproxEqAbs(expected, @field(pool, "hp" ++ own)[lane], 0.001);
            }
        }
    }
}

test "demon passives add Knowledge to Imp spell damage before Improved Imp and Master Demonologist" {
    const std = @import("std");
    const spec = @import("spec.zig");
    const talents = @import("warlock_talents.zig");
    const pets = @import("pets.zig");
    var pool = try @import("combat_spec.zig").WarlockArenaPool.init(std.testing.allocator, 16);
    defer pool.deinit();
    inline for (.{ true, false }) |side| {
        pool.resetAll();
        const own = if (side) "_a" else "_b";
        const enemy = if (side) "_b" else "_a";
        for (0..16) |lane| {
            const ranks = spec.WarlockTalentRanks{ .demonic_knowledge = @intCast(lane % 4), .master_demonologist = 5, .improved_imp = 3 };
            const words = ranks.encode();
            @field(pool, "talent_ranks" ++ own)[lane] = @truncate(words);
            @field(pool, "talent_flags" ++ own)[lane] = @truncate(words >> 32);
            @field(pool, "talent_extra" ++ own)[lane] = @truncate(words >> 64);
            pets.set(&pool, side, lane, .imp);
            @field(pool, "pet_x" ++ own)[lane] = @field(pool, "pos_x" ++ enemy)[lane];
            @field(pool, "pet_y" ++ own)[lane] = @field(pool, "pos_y" ++ enemy)[lane];
        }
        const fx = talents.decode(@field(pool, "talent_ranks" ++ own)[0..16].*, @field(pool, "talent_flags" ++ own)[0..16].*);
        const damage = pets.tick(&pool, side, 0, 2, fx.imp_firebolt_damage);
        for (0..16) |lane| {
            const fraction: f32 = switch (lane % 4) {
                1 => 0.33,
                2 => 0.67,
                3 => 1,
                else => 0,
            };
            const expected = (60 + fraction * 60 * (2.0 / 3.5)) * 1.3 * 1.1;
            try std.testing.expectApproxEqAbs(expected, damage[lane], 0.001);
        }
    }
}
