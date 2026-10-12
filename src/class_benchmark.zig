const std = @import("std");
const Spec = @import("spec.zig").Spec;
const ArenaPool = @import("multi_spec.zig").ArenaPool;
const PolicyGenome = @import("policy_simd.zig").PolicyGenome;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const out = std.io.getStdOut().writer();
    try out.writeAll("pair,combatant_ticks_per_second,policy_lanes_per_second\n");
    inline for (.{ Spec.warlock, Spec.frost_mage }) |a| {
        inline for (.{ Spec.warlock, Spec.frost_mage }) |b| {
            var arena = try ArenaPool(a, b).init(allocator, 16);
            defer arena.deinit();
            const state = arena.combat();
            var prng = std.Random.DefaultPrng.init(42);
            const genome = PolicyGenome.initRandom(prng.random());
            // Fixed number of ticks with identical cast completions, independent
            // of policy choices and match lengths. Setup writes are timed too.
            const iterations = 200_000;
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                @memset(state.hp_a, 2000);
                @memset(state.hp_b, 2000);
                @memset(state.is_active, 1);
                @memset(state.cast_id_a, 4);
                @memset(state.cast_id_b, 4);
                @memset(state.cast_timer_a, 0.01);
                @memset(state.cast_timer_b, 0.01);
                _ = arena.tickPhysics16(0.01, 0);
            }
            const tick_ns = timer.read();
            var obs = arena.getObservationsA(0);
            const masks = arena.getActionMaskA(0);
            const inferences = 20_000;
            timer.reset();
            var checksum: f32 = 0;
            for (0..inferences) |index| {
                obs[0] = @splat(@as(f32, @floatFromInt(index & 1023)) / 1024.0);
                const decision = genome.forward16(obs, masks);
                std.mem.doNotOptimizeAway(decision);
                checksum += decision.move_intents[0];
            }
            const policy_ns = timer.read();
            std.mem.doNotOptimizeAway(checksum);
            try out.print("{s}_vs_{s},{d:.0},{d:.0}\n", .{
                @tagName(a),                                                          @tagName(b), @as(f64, iterations * 32) * 1e9 / @as(f64, @floatFromInt(tick_ns)),
                @as(f64, inferences * 16) * 1e9 / @as(f64, @floatFromInt(policy_ns)),
            });
        }
    }
    // Run the actual trainer for end-to-end throughput. Its compilation unit
    // and metrics work match normal use, avoiding benchmark-only inlining effects.
    inline for (.{ Spec.warlock, Spec.frost_mage }) |class| {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "zig-out/bin/pvp_sim", "--class", @tagName(class), "--train-only", "--generations", "30", "--pop", "64", "--duels", "4", "--no-metrics" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) return error.TrainerFailed;
        const marker = "RL Duel Throughput:   ";
        const begin = (std.mem.indexOf(u8, result.stdout, marker) orelse return error.MissingThroughput) + marker.len;
        const rest = result.stdout[begin..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MissingThroughput;
        try out.print("{s}_league,{s}_duels_per_second\n", .{ @tagName(class), rest[0..end] });
    }
}
