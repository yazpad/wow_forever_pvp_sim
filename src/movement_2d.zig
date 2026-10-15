//! SIMD duel geometry. Voluntary movement is along the opponent axis only.
const simd = @import("simd.zig");
const V = simd.f32x16;
const B = simd.bool16;
const U = simd.u32x16;
fn splat(x: f32) V {
    return @splat(x);
}
fn select(mask: B, yes: V, no: V) V {
    return @select(f32, mask, yes, no);
}

fn column(values: []f32, i: usize) *align(4) V {
    return @ptrCast(values[i..][0..16]);
}

// Keep compatibility with callers that set the initial separation directly.
// Also supplies a stable heading when the two positions coincide.
pub fn synchronize(state: anytype, i: usize) void {
    const ax = column(state.pos_x_a, i);
    const ay = column(state.pos_y_a, i);
    const bx = column(state.pos_x_b, i);
    const by = column(state.pos_y_b, i);
    const dx = bx.* - ax.*;
    const dy = by.* - ay.*;
    const expected = column(state.distance, i).*;
    if (!@reduce(.Or, @abs(dx * dx + dy * dy - expected * expected) > splat(0.001))) return;
    const length = @sqrt(dx * dx + dy * dy);
    const nx = select(length > splat(0.00001), dx / @max(length, splat(0.00001)), splat(1));
    const ny = dy / @max(length, splat(0.00001));
    const half = (column(state.distance, i).* - length) * splat(0.5);
    ax.* -= nx * half;
    ay.* -= ny * half;
    bx.* += nx * half;
    by.* += ny * half;
}

pub fn refresh(state: anytype, i: usize, constrain: bool) V {
    const ax = column(state.pos_x_a, i);
    const ay = column(state.pos_y_a, i);
    const bx = column(state.pos_x_b, i);
    const by = column(state.pos_y_b, i);
    const dx = bx.* - ax.*;
    const dy = by.* - ay.*;
    const length = @sqrt(dx * dx + dy * dy);
    const distance = if (constrain) @min(splat(35), @max(splat(0), length)) else length;
    if (constrain and @reduce(.Or, distance != length)) {
        const nx = select(length > splat(0.00001), dx / @max(length, splat(0.00001)), splat(1));
        const ny = dy / @max(length, splat(0.00001));
        const half = (distance - length) * splat(0.5);
        ax.* -= nx * half;
        ay.* -= ny * half;
        bx.* += nx * half;
        by.* += ny * half;
    }
    column(state.distance, i).* = distance;
    return distance;
}

// Counter-hashed timer buckets change direction every 0.75 seconds without
// mutable RNG state, scalar lane loops, or trig. Snapshots replay exactly.
const Direction = struct { x: V, y: V };
fn wander(timer: V, comptime salt: u32) Direction {
    var h: U = @intFromFloat(@max(splat(0), @floor(timer / splat(0.75))));
    h = (h ^ @as(U, @splat(salt))) *% @as(U, @splat(0x9e3779b9));
    h ^= h >> @as(@Vector(16, u5), @splat(16));
    h *%= @as(U, @splat(0x85ebca6b));
    h ^= h >> @as(@Vector(16, u5), @splat(13));
    const diagonal = (h & @as(U, @splat(1))) != @as(U, @splat(0));
    const horizontal = (h & @as(U, @splat(2))) != @as(U, @splat(0));
    const x = select(diagonal, splat(0.70710678), select(horizontal, splat(1), splat(0)));
    const y = select(diagonal, splat(0.70710678), select(horizontal, splat(0), splat(1)));
    return .{ .x = select((h & @as(U, @splat(4))) != @as(U, @splat(0)), -x, x), .y = select((h & @as(U, @splat(8))) != @as(U, @splat(0)), -y, y) };
}

pub fn tick(state: anytype, i: usize, dt: f32, speed_a: V, speed_b: V, cc_a: B, cc_b: B, timer_a: V, timer_b: V) V {
    synchronize(state, i);
    const active = state.is_active[i..][0..16].* != @as(U, @splat(0));
    const dx = column(state.pos_x_b, i).* - column(state.pos_x_a, i).*;
    const dy = column(state.pos_y_b, i).* - column(state.pos_y_a, i).*;
    const length = @max(column(state.distance, i).*, splat(0.00001));
    const nx = select(column(state.distance, i).* > splat(0.00001), dx / length, splat(1));
    const ny = dy / length;
    const wa: Direction = if (@reduce(.Or, cc_a)) wander(timer_a, 0x12345) else .{ .x = splat(0), .y = splat(0) };
    const wb: Direction = if (@reduce(.Or, cc_b)) wander(timer_b, 0x12345) else .{ .x = splat(0), .y = splat(0) };
    const step_a = select(active, speed_a * splat(dt), splat(0));
    const step_b = select(active, speed_b * splat(dt), splat(0));
    column(state.pos_x_a, i).* += select(cc_a, -wa.x, -nx) * step_a;
    column(state.pos_y_a, i).* += select(cc_a, -wa.y, -ny) * step_a;
    column(state.pos_x_b, i).* += select(cc_b, wb.x, nx) * step_b;
    column(state.pos_y_b, i).* += select(cc_b, wb.y, ny) * step_b;
    return refresh(state, i, true);
}

pub fn blink(state: anytype, comptime side_a: bool, i: usize, displacement: V, mask: B, staged: bool) void {
    if (!@reduce(.Or, mask)) return;
    synchronize(state, i);
    const dx = column(state.pos_x_b, i).* - column(state.pos_x_a, i).*;
    const dy = column(state.pos_y_b, i).* - column(state.pos_y_a, i).*;
    const distance = column(state.distance, i).*;
    const nx = select(distance > splat(0.00001), dx / @max(distance, splat(0.00001)), splat(1));
    const ny = dy / @max(distance, splat(0.00001));
    const step = select(mask, displacement * splat(if (side_a) -1 else 1), splat(0));
    const suffix = if (side_a) "_a" else "_b";
    column(@field(state, "pos_x" ++ suffix), i).* += nx * step;
    column(@field(state, "pos_y" ++ suffix), i).* += ny * step;
    _ = refresh(state, i, !staged);
}
