//! Discrete compact-kit periodic effects. DoT duration and natural channel
//! elapsed time provide snapshotted phase clocks, without an external scheduler.
const simd = @import("simd.zig");
const resolution = @import("spell_resolution.zig");
const talents = @import("warlock_talents.zig");
const V = simd.f32x16;
const B = simd.bool16;
fn v(x: f32) V {
    return @splat(x);
}

// Quantize countdowns to 10us to prevent float subtraction drift from moving a
// final tick to the next physics frame. No partial tick at expiry/cancellation.
pub fn remaining(old: V, dt: f32) V {
    return @max(v(0), @round((old - v(dt)) * v(100000)) / v(100000));
}
pub fn tickCount(old: V, next: V, duration: f32, interval: f32) V {
    const before = @floor((v(duration) - @min(v(duration), old)) / v(interval) + v(0.00001));
    const after = @floor((v(duration) - @min(v(duration), next)) / v(interval) + v(0.00001));
    return @select(f32, old > v(0), @max(v(0), after - before), v(0));
}
pub const Tick = struct { damage: V = @splat(0), healing: V = @splat(0) };
pub fn advance(state: anytype, comptime side: bool, i: usize, timer: anytype, dt: f32, comptime duration: f32, comptime interval: f32, dps: V, hps: V, mask: B, profile: resolution.Profile) Tick {
    const old: V = timer.*;
    if (!@reduce(.Or, old > v(0))) return .{};
    const next = remaining(old, dt);
    timer.* = next;
    return resolveTicks(state, side, i, @select(f32, mask, tickCount(old, next, duration, interval), v(0)), interval, dps, hps, profile);
}
fn resolveTicks(state: anytype, comptime side: bool, i: usize, ticks: V, interval: f32, dps: V, hps: V, profile: resolution.Profile) Tick {
    var count = ticks;
    var result: Tick = .{};
    while (@reduce(.Or, count > v(0))) {
        const rolled = resolution.periodic(state, side, i, v(interval), count > v(0), profile);
        result.damage += rolled.damage * dps;
        result.healing += rolled.damage * hps;
        count -= v(1);
    }
    return result;
}
// Channel pushback shortens the expiry, never advances tick phase. Only actual
// time spent channeling can earn a tick; removed tail time produces no ticks.
pub fn channel(state: anytype, comptime side: bool, i: usize, time_left: V, dt: f32, comptime duration: f32, comptime interval: f32, dps: V, hps: V, mask: B, profile: resolution.Profile) Tick {
    if (!@reduce(.Or, mask)) return .{};
    const elapsed = @field(state, "channel_elapsed" ++ (if (side) "_a" else "_b"));
    const old: V = elapsed[i..][0..16].*;
    const next = @min(v(duration), @round((old + @min(v(dt), @max(v(0), time_left))) * v(100000)) / v(100000));
    elapsed[i..][0..16].* = @select(f32, mask, next, old);
    return resolveTicks(state, side, i, @select(f32, mask, tickCount(v(duration) - old, v(duration) - next, duration, interval), v(0)), interval, dps, hps, profile);
}
pub fn shadowProfile(effects: talents.Effects) resolution.Profile {
    return .{ .school = .shadow, .crit_bonus = effects.shadow_crit_bonus, .crit_multiplier = effects.affliction_crit_multiplier };
}
pub fn application(state: anytype, comptime side: bool, i: usize, mask: B, hit_bonus: V, comptime school: resolution.School) B {
    return resolution.resolve(state, side, i, v(0), mask, .{ .school = school, .hit_bonus = hit_bonus, .can_crit = false, .partial = false }).landed;
}

// Binary control/interrupts have one all-or-nothing effect roll. Pet effects
// use pet stats/RNG and never inherit Suppression or other owner-only bonuses.
pub fn control(state: anytype, comptime side: bool, i: usize, mask: B, hit_bonus: V, school: resolution.School, pet: bool) B {
    return resolution.resolve(state, side, i, v(0), mask, .{ .school = school, .hit_bonus = hit_bonus, .can_crit = false, .binary = true, .pet = pet }).landed;
}
