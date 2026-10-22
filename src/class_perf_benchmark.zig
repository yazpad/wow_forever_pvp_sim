//! Stable caster workload for before/after class-integration comparisons.
const std = @import("std");
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;

fn run(comptime a: Spec, comptime b: Spec) !void {
    var duel = try sim.Duel(a, b).init(std.heap.page_allocator);
    defer duel.deinit();
    const state = duel.arena.combat();
    @memset(state.distance, 15);
    @memset(state.pos_x_a, -7.5);
    @memset(state.pos_x_b, 7.5);
    @memset(state.cast_id_a, 4);
    @memset(state.cast_timer_a, 1.5);
    @memset(state.cast_total_a, 1.5);
    @memset(state.cast_id_b, 4);
    @memset(state.cast_timer_b, 1.5);
    @memset(state.cast_total_b, 1.5);
    const initial = duel.snapshot(0);
    const count = 30000;
    var checksum: f32 = 0;
    var timer = try std.time.Timer.start();
    for (0..count) |i| {
        if (i % 128 == 0) duel.restoreAll(initial);
        duel.tick(6000);
        checksum += state.hp_a[i % 16];
    }
    const tick_ns = timer.read();
    timer.reset();
    for (0..count) |i| {
        const snapshot = duel.snapshot(i % 16);
        duel.restoreAll(snapshot);
        std.mem.doNotOptimizeAway(&duel);
    }
    const copy_ns = timer.read();
    try std.io.getStdOut().writer().print("{{\"a\":\"{s}\",\"b\":\"{s}\",\"snapshot_bytes\":{d},\"choices\":{d},\"tick_ns\":{d:.2},\"copy_ns\":{d:.2},\"checksum\":{d}}}\n", .{ @tagName(a), @tagName(b), @sizeOf(@TypeOf(initial)), @import("action_catalog_generated.zig").MaxChoices, @as(f64, @floatFromInt(tick_ns)) / count, @as(f64, @floatFromInt(copy_ns)) / count, checksum });
}

pub fn main() !void {
    for (0..5) |_| {
        try run(.warlock, .warlock);
        try run(.priest, .warlock);
        try run(.frost_mage, .priest);
    }
}
