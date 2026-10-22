//! Headless integration fixture, not a saved visualizer replay or balance test.
const std = @import("std");
const sim = @import("search_sim.zig");
const mcts = @import("mcts.zig");

pub fn main() !void {
    var duel = try sim.Duel(.warrior, .priest).init(std.heap.page_allocator);
    defer duel.deinit();
    try duel.setWarriorConfig(true, .{});
    for (0..16) |lane| duel.arena.resetDuel(lane);
    const s = duel.arena.combat();
    @memset(s.distance, 15);
    @memset(s.pos_x_a, -7.5);
    @memset(s.pos_x_b, 7.5);
    var rng = std.Random.DefaultPrng.init(947);
    var tick: u32 = 0;
    var damage: f32 = 0;
    var heroic: usize = 0;
    var hamstring: usize = 0;
    while (tick < 6000 and s.is_active[0] != 0) : (tick += 1) {
        const ra = duel.ready(true);
        const rb = duel.ready(false);
        var aa: [16]sim.Action = @splat(.{});
        var bb: [16]sim.Action = @splat(.{});
        const masks_a = duel.getActionMaskA(0);
        const masks_b = duel.getActionMaskB(0);
        for (0..16) |lane| {
            if (ra[lane]) aa[lane] = mcts.rolloutFast(.warrior, true, &duel, lane, masks_a, rng.random(), false, null);
            if (rb[lane]) bb[lane] = mcts.rolloutFast(.priest, false, &duel, lane, masks_b, rng.random(), false, null);
        }
        heroic += @intFromBool(ra[0] and aa[0].ability == 1);
        hamstring += @intFromBool(ra[0] and aa[0].ability == 2);
        duel.applyMasked(aa, bb, ra, rb);
        duel.tick(6000);
        damage += duel.arena.warrior.floats(true, .last_damage, 0).*[0];
    }
    try std.io.getStdOut().writer().print("{{\"fixture\":\"staged_warrior_vs_priest\",\"seconds\":{d:.2},\"warrior_hp\":{d:.2},\"priest_hp\":{d:.2},\"rage\":{d:.2},\"melee_before_shields\":{d:.2},\"heroic_queues\":{d},\"hamstrings\":{d},\"caster_snapshot_bytes\":{d},\"warrior_snapshot_bytes\":{d}}}\n", .{ @as(f32, @floatFromInt(tick)) * 0.01, s.hp_a[0], s.hp_b[0], duel.arena.warrior.floats(true, .rage, 0).*[0], damage, heroic, hamstring, @sizeOf(sim.Snapshot), @sizeOf(@TypeOf(duel.snapshot(0))) });
}
