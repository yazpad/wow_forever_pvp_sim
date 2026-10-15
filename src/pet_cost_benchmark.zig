//! Synthetic incremental pet physics cost, NOT implemented pet mechanics.
//! zig run src/pet_cost_benchmark.zig -O ReleaseFast
const std = @import("std");
const combat = @import("combat_spec.zig");
const sim = @import("search_sim.zig");
const V = @Vector(16, f32);
fn v(x: f32) V {
    return @splat(x);
}
const Kind = enum { baseline, imp, succubus };
noinline fn physics(arena: *combat.WarlockArenaPool) void {
    _ = arena.tickPhysics16(0.01, 0);
}
const Pet = struct {
    hp: V = @splat(500),
    mana: V = @splat(1000),
    timer: V = @splat(0),
    x: V = @splat(0),
    y: V = @splat(0),
    cc: V = @splat(0),
    cooldown: V = @splat(0),
    fn tick(p: *Pet, comptime kind: Kind, target_x: V, target_y: V, hp: V) V {
        p.timer = @max(v(0), p.timer - v(0.01));
        p.cc = @max(v(0), p.cc - v(0.01));
        p.cooldown = @max(v(0), p.cooldown - v(0.01));
        p.mana = @min(v(1000), p.mana + v(0.15));
        const dx = target_x - p.x;
        const dy = target_y - p.y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (kind == .succubus) {
            const step = @min(v(0.07), dist) / @max(v(0.001), dist);
            p.x += dx * step;
            p.y += dy * step;
        }
        var active = p.hp > v(0);
        inline for (.{ p.cc == v(0), p.timer == v(0), p.mana >= v(20), dist < v(if (kind == .imp) 30 else 3) }) |mask| {
            active = @select(bool, active, mask, @as(@Vector(16, bool), @splat(false)));
        }
        p.timer = @select(f32, active, v(2), p.timer);
        p.mana -= @select(f32, active, v(20), v(0));
        return hp - @select(f32, active, v(40), v(0));
    }
};
noinline fn run(kind: Kind) !void {
    var arena = try combat.WarlockArenaPool.init(std.heap.page_allocator, 16);
    defer arena.deinit();
    var pets = [2]Pet{ .{}, .{} };
    var timer = try std.time.Timer.start();
    const iterations = 300000;
    for (0..iterations) |i| {
        // Keep all lanes alive; identical player workload across variants.
        arena.hp_a[0..16].* = v(2000);
        arena.hp_b[0..16].* = v(2000);
        arena.is_active[0..16].* = @splat(1);
        physics(&arena);
        switch (kind) {
            .baseline => {},
            inline else => |k| {
                arena.hp_b[0..16].* = pets[0].tick(k, arena.pos_x_b[0..16].*, arena.pos_y_b[0..16].*, arena.hp_b[0..16].*);
                arena.hp_a[0..16].* = pets[1].tick(k, arena.pos_x_a[0..16].*, arena.pos_y_a[0..16].*, arena.hp_a[0..16].*);
            },
        }
        // Opaque uses prevent deleting pet state and repeated combat work.
        std.mem.doNotOptimizeAway(&pets);
        std.mem.doNotOptimizeAway(arena.hp_a.ptr);
        std.mem.doNotOptimizeAway(i);
    }
    const ns = timer.read();
    try std.io.getStdOut().writer().print("{{\"case\":\"{s}\",\"ns_per_16_duel_tick\":{d:.3},\"snapshot_bytes\":{d},\"columns\":{d}}}\n", .{ @tagName(kind), @as(f64, @floatFromInt(ns)) / iterations, @sizeOf(sim.Snapshot), sim.columns });
}
pub fn main() !void {
    // Rotate ordering across samples to expose timing noise.
    inline for (0..6) |i| {
        if (i % 2 == 0) {
            try run(.baseline);
            try run(.imp);
            try run(.succubus);
        } else {
            try run(.succubus);
            try run(.imp);
            try run(.baseline);
        }
    }
}
