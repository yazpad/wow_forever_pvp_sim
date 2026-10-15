//! Fixed SoA queues: four homing missiles per caster, vectorized across duels.
const std = @import("std");
const simd = @import("simd.zig");
const V = simd.f32x16;
const B = simd.bool16;
pub const Slots = 4;
pub const BoltSpeed: f32 = 30;
pub const LanceSpeed: f32 = 40;
pub const CoilSpeed: f32 = 20;
pub const Hits = struct { conflagrate: V = @splat(0), bolt: V = @splat(0), lance: V = @splat(0), coil: V = @splat(0), immolate: V = @splat(0) };
fn splat(x: f32) V {
    return @splat(x);
}
fn select(mask: B, yes: V, no: V) V {
    return @select(f32, mask, yes, no);
}
fn column(state: anytype, comptime side_a: bool, comptime slot: usize, comptime kind: []const u8, i: usize) *align(4) V {
    const name = std.fmt.comptimePrint("projectile_{d}_{s}_{s}", .{ slot, kind, if (side_a) "a" else "b" });
    return @ptrCast(@field(state, name)[i..][0..16]);
}
pub fn available(state: anytype, comptime side_a: bool, i: usize) B {
    const suffix = if (side_a) "_a" else "_b";
    const count: V = @field(state, "projectile_count" ++ suffix)[i..][0..16].*;
    return count < splat(Slots);
}
pub fn launch(state: anytype, comptime side_a: bool, i: usize, comptime spell: u32, damage: V, mask: B) void {
    if (!@reduce(.Or, mask)) return;
    @import("movement_2d.zig").synchronize(state, i);
    const suffix = if (side_a) "_a" else "_b";
    const count: *align(4) V = @ptrCast(@field(state, "projectile_count" ++ suffix)[i..][0..16]);
    count.* += select(mask, splat(1), splat(0));
    var pending = mask;
    inline for (0..Slots) |slot| {
        const id = column(state, side_a, slot, "spell", i);
        const use = simd.vAnd16(pending, id.* == splat(0));
        id.* = select(use, splat(@floatFromInt(spell)), id.*);
        const payload = column(state, side_a, slot, "damage", i);
        payload.* = select(use, damage, payload.*);
        const x = column(state, side_a, slot, "x", i);
        const y = column(state, side_a, slot, "y", i);
        x.* = select(use, @field(state, "pos_x" ++ suffix)[i..][0..16].*, x.*);
        y.* = select(use, @field(state, "pos_y" ++ suffix)[i..][0..16].*, y.*);
        pending = simd.vAnd16(pending, simd.vNot16(use));
    }
    // Action masks reserve queue capacity before mana/GCD are committed.
    std.debug.assert(!@reduce(.Or, pending));
}
pub fn tick(state: anytype, comptime side_a: bool, i: usize, dt: f32) Hits {
    return tickImpl(state, side_a, i, dt, false);
}
// Benchmark/test candidate only. No reliable throughput gain was measured;
// production keeps the original loads and arithmetic.
pub fn tickCachedTargetsExperimental(state: anytype, comptime side_a: bool, i: usize, dt: f32) Hits {
    return tickImpl(state, side_a, i, dt, true);
}
fn tickImpl(state: anytype, comptime side_a: bool, i: usize, dt: f32, comptime optimized: bool) Hits {
    var hits: Hits = .{};
    const target = if (side_a) "_b" else "_a";
    const active: B = state.is_active[i..][0..16].* != @as(simd.u32x16, @splat(0));
    const own = if (side_a) "_a" else "_b";
    const count: *align(4) V = @ptrCast(@field(state, "projectile_count" ++ own)[i..][0..16]);
    if (!@reduce(.Or, simd.vAnd16(active, count.* > splat(0)))) return hits;
    // Positions cannot change while this queue advances. Cache them explicitly
    // because independent SoA slices otherwise leave aliasing ambiguous.
    const target_x: V = if (optimized) @field(state, "pos_x" ++ target)[i..][0..16].* else undefined;
    const target_y: V = if (optimized) @field(state, "pos_y" ++ target)[i..][0..16].* else undefined;
    inline for (0..Slots) |slot| {
        const id = column(state, side_a, slot, "spell", i);
        const live = simd.vAnd16(active, id.* > splat(0));
        if (@reduce(.Or, live)) {
            const x = column(state, side_a, slot, "x", i);
            const y = column(state, side_a, slot, "y", i);
            const damage = column(state, side_a, slot, "damage", i);
            const dx = (if (optimized) target_x else @as(V, @field(state, "pos_x" ++ target)[i..][0..16].*)) - x.*;
            const dy = (if (optimized) target_y else @as(V, @field(state, "pos_y" ++ target)[i..][0..16].*)) - y.*;
            const distance = @sqrt(dx * dx + dy * dy);
            const speed = select(id.* == splat(7), splat(CoilSpeed), select(id.* == splat(1), splat(LanceSpeed), splat(BoltSpeed)));
            const step = select(live, @min(splat(1), speed * splat(dt) / @max(distance, splat(0.00001))), splat(0));
            x.* += dx * step;
            y.* += dy * step;
            const hit = simd.vAnd16(live, distance <= speed * splat(dt));
            hits.immolate += select(simd.vAnd16(hit, id.* == splat(13)), damage.*, splat(0));
            hits.bolt += select(simd.vAnd16(hit, simd.vOr16(simd.vOr16(id.* == splat(4), id.* == splat(9)), simd.vOr16(id.* == splat(11), id.* == splat(12)))), damage.*, splat(0));
            hits.lance += select(simd.vAnd16(hit, id.* == splat(1)), damage.*, splat(0));
            hits.coil += select(simd.vAnd16(hit, id.* == splat(7)), damage.*, splat(0));
            count.* -= select(hit, splat(1), splat(0));
            id.* = select(hit, splat(0), id.*);
            damage.* = select(hit, splat(0), damage.*);
        }
    }
    return hits;
}

// Proportionally account for shields/overkill alongside periodic damage.
pub fn recordHits(state: anytype, comptime side_a: bool, i: usize, hits: Hits, mitigation: V, incoming: V, applied: V) void {
    const suffix = if (side_a) "_a" else "_b";
    const zero: simd.u32x16 = @splat(0);
    @field(state, "impact_mask" ++ suffix)[i..][0..16].* =
        @select(u32, (hits.bolt + hits.immolate) > splat(0), @as(simd.u32x16, @splat(1)), zero) |
        @select(u32, hits.lance > splat(0), @as(simd.u32x16, @splat(2)), zero) |
        @select(u32, hits.coil > splat(0), @as(simd.u32x16, @splat(4)), zero) |
        @select(u32, hits.conflagrate > splat(0), @as(simd.u32x16, @splat(8)), zero);
    if (!@reduce(.Or, hits.bolt + hits.lance + hits.coil + hits.immolate + hits.conflagrate > splat(0))) {
        inline for (.{ "bolt", "lance", "coil", "conflagrate" }) |kind|
            @field(state, "impact_" ++ kind ++ suffix)[i..][0..16].* = @as(V, @splat(0));
        return;
    }
    const ratio = mitigation * select(incoming > splat(0), applied / @max(incoming, splat(0.00001)), splat(0));
    inline for (.{ "bolt", "lance", "coil", "conflagrate" }) |kind|
        @field(state, "impact_" ++ kind ++ suffix)[i..][0..16].* = (if (comptime std.mem.eql(u8, kind, "bolt")) hits.bolt + hits.immolate else @field(hits, kind)) * ratio;
}
pub fn telemetry(state: anytype, lane: usize) [32]f32 {
    var result: [32]f32 = undefined;
    inline for (.{ true, false }, 0..) |side, side_index| inline for (0..Slots) |slot| inline for (.{ "spell", "damage", "x", "y" }, 0..) |kind, k| {
        const name = std.fmt.comptimePrint("projectile_{d}_{s}_{s}", .{ slot, kind, if (side) "a" else "b" });
        result[side_index * 16 + slot * 4 + k] = @field(state, name)[lane];
    };
    return result;
}

pub fn pendingEffects(state: anytype, comptime side_a: bool, lane: usize) struct { damage: f32, healing: f32 } {
    const own = if (side_a) "a" else "b";
    var result: struct { damage: f32, healing: f32 } = .{ .damage = @field(state, "conflagrate_pending_" ++ own)[lane], .healing = 0 };
    if (@field(state, "projectile_count_" ++ own)[lane] == 0) return .{ .damage = result.damage, .healing = result.healing };
    inline for (0..Slots) |slot| {
        const prefix = std.fmt.comptimePrint("projectile_{d}_", .{slot});
        result.damage += @field(state, prefix ++ "damage_" ++ own)[lane];
        if (@field(state, prefix ++ "spell_" ++ own)[lane] == 7) result.healing += 300;
    }
    return .{ .damage = result.damage, .healing = result.healing };
}
