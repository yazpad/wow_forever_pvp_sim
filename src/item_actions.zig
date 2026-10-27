//! Pinned Forever Greater Insignia: instant cleanse, independent 300s cooldown.
const std = @import("std");
const simd = @import("simd.zig");
const Spec = @import("spec.zig").Spec;
const V = simd.f32x16;
const U = simd.u32x16;
const B = simd.bool16;
pub const action_id: u32 = 26;
pub const alliance_id: u32 = 274445;
pub const horde_id: u32 = 274444;
pub const cooldown: f32 = 300;
pub fn supported(id: u32) bool {
    return id == alliance_id or id == horde_id;
}

pub fn fromGear(value: std.json.Value) !u32 {
    if (value != .object) return error.InvalidEquipment;
    var result: u32 = 0;
    inline for (.{ "trinket1", "trinket2" }) |slot| {
        if (value.object.get(slot)) |item| {
            if (item != .integer or item.integer < 0 or item.integer > std.math.maxInt(u32)) return error.InvalidItemId;
            const id: u32 = @intCast(item.integer);
            if (supported(id)) {
                if (result != 0) return error.DuplicateItemEffect;
                result = id;
            }
        }
    }
    return result;
}
fn v(n: f32) V {
    return @splat(n);
}
fn column(state: anytype, comptime name: []const u8, comptime side: bool, i: usize) *align(64) V {
    return @ptrCast(@alignCast(@field(state, name ++ (if (side) "_a" else "_b"))[i..][0..16]));
}
pub fn legal(arena: anytype, comptime side: bool, i: usize, comptime opponent: Spec) B {
    const state = &arena.state;
    const ids: U = @field(state, if (side) "item_id_a" else "item_id_b")[i..][0..16].*;
    const equipped = simd.vOr16(ids == @as(U, @splat(alliance_id)), ids == @as(U, @splat(horde_id)));
    if (!@reduce(.Or, equipped)) return @splat(false);
    var impaired: B = @splat(false);
    inline for (.{ "fear_timer", "horror_timer", "seduction_timer", "stun_timer" }) |name|
        impaired = simd.vOr16(impaired, column(state, name, side, i).* > v(0));
    if (opponent == .frost_mage) inline for (.{ "agony_timer", "corruption_timer" }) |name| {
        impaired = simd.vOr16(impaired, column(state, name, side, i).* > v(0));
    };
    // Priest Silence has a distinct class source; Counterspell/school lockouts
    // are interrupts and are not removed by a control-break item.
    if (opponent == .priest) impaired = simd.vOr16(impaired, arena.extra(.lockout, side, i).* > v(0));
    if (opponent == .warrior) impaired = simd.vOr16(impaired, arena.warrior.floats(!side, .hamstring, i).* > v(0));
    const alive = simd.vAnd16(state.is_active[i..][0..16].* != @as(U, @splat(0)), simd.vAnd16(column(state, "hp", side, i).* > v(0), column(state, "hp", !side, i).* > v(0)));
    return simd.vAnd16(equipped, simd.vAnd16(alive, simd.vAnd16(column(state, "item_cd", side, i).* <= v(0), impaired)));
}
pub fn cleanse(arena: anytype, comptime side: bool, i: usize, used: B, comptime opponent: Spec) void {
    if (!@reduce(.Or, used)) return;
    inline for (.{ "fear_timer", "fear_accum_dmg", "horror_timer", "seduction_timer", "stun_timer" }) |name| {
        const target = column(&arena.state, name, side, i);
        target.* = @select(f32, used, v(0), target.*);
    }
    const seduced: *align(64) U = @ptrCast(@alignCast(@field(arena.state, if (side) "seduced_a" else "seduced_b")[i..][0..16]));
    seduced.* = @select(u32, used, @as(U, @splat(0)), seduced.*);
    if (opponent == .frost_mage) {
        inline for (.{ "agony_timer", "corruption_timer" }) |name| {
            const target = column(&arena.state, name, side, i);
            target.* = @select(f32, used, v(0), target.*);
        }
        const damage = arena.extra(.root_damage, side, i);
        damage.* = @select(f32, used, v(0), damage.*);
    }
    if (opponent == .priest) {
        const silence = arena.extra(.lockout, side, i);
        silence.* = @select(f32, used, v(0), silence.*);
    }
    if (opponent == .warrior) {
        const slow = arena.warrior.floats(!side, .hamstring, i);
        slow.* = @select(f32, used, v(0), slow.*);
    }
}
pub fn apply(arena: anytype, comptime side: bool, i: usize, actions: U, comptime opponent: Spec) void {
    const used = simd.vAnd16(actions == @as(U, @splat(action_id)), legal(arena, side, i, opponent));
    const cd = column(&arena.state, "item_cd", side, i);
    cd.* = @select(f32, used, v(cooldown), cd.*);
    cleanse(arena, side, i, used, opponent);
}
pub fn reconcile(arena: anytype, original: anytype, comptime side: bool, actions: U, ready: B, comptime opponent: Spec) void {
    const used = simd.vAnd16(ready, simd.vAnd16(actions == @as(U, @splat(action_id)), simd.vAnd16(column(original, "item_cd", side, 0).* <= v(0), column(&arena.state, "item_cd", side, 0).* > v(0))));
    // Explicit simultaneous-action policy: the instant cleanse resolves after
    // same-boundary control applications; DR bookkeeping and later CC survive.
    cleanse(arena, side, 0, used, opponent);
}
pub fn tick(state: anytype, i: usize, dt: f32) void {
    inline for (.{ true, false }) |side| {
        const cd = column(state, "item_cd", side, i);
        cd.* = @max(v(0), cd.* - v(dt));
    }
}
