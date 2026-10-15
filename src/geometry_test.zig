const std = @import("std");
const sim = @import("search_sim.zig");
const geometry = @import("movement_2d.zig");
const missiles = @import("projectiles.zig");
const V = @Vector(16, f32);

test "cached homing targets preserve every snapshot bit across movement and impacts" {
    var fast = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer fast.deinit();
    var reference = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer reference.deinit();
    for (0..16) |lane| {
        fast.arena.combat().distance[lane] = @floatFromInt(lane * 2);
        fast.arena.combat().is_active[lane] = if (lane % 5 == 0) 0 else 1;
        reference.restore(lane, fast.snapshot(lane));
    }
    for (0..2000) |step| {
        // Include matching geometry, compatibility distance edits, CC wander,
        // sparse queues, impacts, and movement past arena limits.
        if (step % 200 == 0) for (0..16) |lane| {
            fast.arena.combat().distance[lane] = @floatFromInt(lane * 2);
            reference.arena.combat().distance[lane] = fast.arena.combat().distance[lane];
        };
        var cc: @Vector(16, bool) = @splat(false);
        if (step % 400 > 200) cc[step % 16] = true;
        const speed: V = @splat(if (step % 100 < 50) 7 else -4.5);
        const timer: V = @splat(@as(f32, @floatFromInt(step)) * 0.01);
        const result = geometry.tick(fast.arena.combat(), 0, 0.01, speed, -speed, cc, cc, timer, timer);
        const expected = geometry.tick(reference.arena.combat(), 0, 0.01, speed, -speed, cc, cc, timer, timer);
        try std.testing.expectEqualDeep(@as(@Vector(16, u32), @bitCast(expected)), @as(@Vector(16, u32), @bitCast(result)));
        inline for (.{ true, false }) |side| {
            if (step % 80 == 0) {
                var mask: @Vector(16, bool) = undefined;
                for (0..16) |lane| mask[lane] = lane % 3 != 0;
                const room = missiles.available(fast.arena.combat(), side, 0);
                const launch_mask = @import("simd.zig").vAnd16(mask, room);
                missiles.launch(fast.arena.combat(), side, 0, 4, @splat(240), launch_mask);
                missiles.launch(reference.arena.combat(), side, 0, 4, @splat(240), launch_mask);
            }
            const hits = missiles.tickCachedTargetsExperimental(fast.arena.combat(), side, 0, 0.01);
            const expected_hits = missiles.tick(reference.arena.combat(), side, 0, 0.01);
            try std.testing.expectEqualDeep(expected_hits, hits);
        }
        for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
    }
}
