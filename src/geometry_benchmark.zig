//! Kernel timings; snapshot restoration is outside the measured interval.
const std = @import("std");
const sim = @import("search_sim.zig");
const geometry = @import("movement_2d.zig");
const projectiles = @import("projectiles.zig");
const D = sim.Duel(.warlock, .warlock);
const Scenario = enum { horizontal, two_dimensional, sparse };
const Kernel = enum { movement, homing };
const fixtures = 32;
const repeats = 2000;

noinline fn step(d: *D, comptime kernel: Kernel, comptime optimized: bool) void {
    if (kernel == .movement) {
        const speed: @Vector(16, f32) = @splat(4.5);
        if (optimized) {
            _ = geometry.tick(d.arena.combat(), 0, 0.01, speed, -speed, @splat(false), @splat(false), @splat(0), @splat(0));
        } else {
            _ = geometry.tick(d.arena.combat(), 0, 0.01, speed, -speed, @splat(false), @splat(false), @splat(0), @splat(0));
        }
    } else {
        inline for (.{ true, false }) |side| {
            const hits = if (optimized) projectiles.tickCachedTargetsExperimental(d.arena.combat(), side, 0, 0.01) else projectiles.tick(d.arena.combat(), side, 0, 0.01);
            // Make impact results observable along with the updated queues.
            const suffix = if (side) "_a" else "_b";
            @field(d.arena.combat(), "impact_bolt" ++ suffix)[0..16].* = hits.bolt;
            @field(d.arena.combat(), "impact_lance" ++ suffix)[0..16].* = hits.lance;
            @field(d.arena.combat(), "impact_coil" ++ suffix)[0..16].* = hits.coil;
        }
    }
}
fn run(comptime scenario: Scenario, comptime kernel: Kernel) !void {
    var duels: [fixtures]D = undefined;
    for (&duels) |*d| d.* = try D.init(std.heap.page_allocator);
    defer for (&duels) |*d| d.deinit();
    var snapshots: [fixtures][16]sim.Snapshot = undefined;
    for (&duels, 0..) |*d, f| {
        for (0..16) |lane| {
            const s = d.arena.combat();
            s.pos_x_a[lane] = -@as(f32, @floatFromInt(f + 1)) * 0.5;
            s.pos_x_b[lane] = -s.pos_x_a[lane];
            s.pos_y_a[lane] = 0;
            s.pos_y_b[lane] = if (scenario == .two_dimensional) @as(f32, @floatFromInt(lane + 1)) * 0.4 else 0;
            const dx = s.pos_x_b[lane] - s.pos_x_a[lane];
            const dy = s.pos_y_b[lane] - s.pos_y_a[lane];
            s.distance[lane] = @sqrt(dx * dx + dy * dy);
            s.is_active[lane] = if (scenario == .sparse and lane % 3 != 0) 0 else 1;
        }
        inline for (.{ true, false }) |side| {
            projectiles.launch(d.arena.combat(), side, 0, 4, @splat(240), @splat(true));
            if (scenario != .sparse) {
                projectiles.launch(d.arena.combat(), side, 0, 1, @splat(120), @splat(true));
                projectiles.launch(d.arena.combat(), side, 0, 7, @splat(180), @splat(true));
            }
        }
        for (0..16) |lane| snapshots[f][lane] = d.snapshot(lane);
    }
    var timer = try std.time.Timer.start();
    var ns = [2]u64{ 0, 0 };
    for (0..repeats) |iteration| for (0..2) |order| {
        const mode = (iteration + order) % 2;
        for (&duels, 0..) |*d, f| for (0..16) |lane| d.restore(lane, snapshots[f][lane]);
        timer.reset();
        if (mode == 0) {
            for (&duels) |*d| step(d, kernel, false);
        } else {
            for (&duels) |*d| step(d, kernel, true);
        }
        ns[mode] += timer.read();
    };
    // Exact outputs compared after timing, against the original kernel.
    var reference = try D.init(std.heap.page_allocator);
    defer reference.deinit();
    for (&duels, 0..) |*d, f| {
        for (0..16) |lane| {
            reference.restore(lane, snapshots[f][lane]);
            d.restore(lane, snapshots[f][lane]);
        }
        step(&reference, kernel, false);
        step(d, kernel, true);
        for (0..16) |lane| if (!std.meta.eql(reference.snapshot(lane), d.snapshot(lane))) return error.StateMismatch;
    }
    try std.io.getStdOut().writer().print("{{\"scenario\":\"{s}\",\"kernel\":\"{s}\",\"calls\":{d},\"reference_ns\":{d},\"optimized_ns\":{d},\"speedup\":{d:.4}}}\n", .{ @tagName(scenario), @tagName(kernel), fixtures * repeats, ns[0], ns[1], @as(f64, @floatFromInt(ns[0])) / @as(f64, @floatFromInt(ns[1])) });
}
pub fn main() !void {
    inline for (.{ Scenario.horizontal, Scenario.two_dimensional, Scenario.sparse }) |scenario| {
        try run(scenario, .movement);
        try run(scenario, .homing);
    }
}
