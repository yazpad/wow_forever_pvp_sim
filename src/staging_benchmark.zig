//! Matched action-staging benchmark. Snapshot restoration is outside timing.
//! zig run src/staging_benchmark.zig -O ReleaseFast
const std = @import("std");
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;
const mcts = @import("mcts.zig");
const fixtures = 32;
const repeats = 4000;
const Scenario = enum { natural, a_only, b_only, both };

fn run(comptime a: Spec, comptime b: Spec, comptime scenario: Scenario, staging_only: bool) !void {
    const D = sim.Duel(a, b);
    var source = try D.init(std.heap.page_allocator);
    defer source.deinit();
    var states: [fixtures]sim.Snapshot = undefined;
    var aa: [fixtures][16]sim.Action = undefined;
    var bb: [fixtures][16]sim.Action = undefined;
    var ra: [fixtures]@Vector(16, bool) = undefined;
    var rb: [fixtures]@Vector(16, bool) = undefined;
    var rng = std.Random.DefaultPrng.init(947);
    const random = rng.random();
    for (0..fixtures) |f| {
        // Heuristic continuation produces casts, CC, and missiles in flight.
        for (0..17) |_| {
            const ca = source.choices(true, 0, source.arena.getActionMaskA(0));
            const cb = source.choices(false, 0, source.arena.getActionMaskB(0));
            source.apply(@splat(mcts.rollout(a, true, &source, 0, ca, random, false)), @splat(mcts.rollout(b, false, &source, 0, cb, random, false)));
            source.tick(6000);
        }
        states[f] = source.snapshot(0);
        for (0..16) |lane| source.restore(lane, states[f]);
        ra[f] = source.ready(true);
        rb[f] = source.ready(false);
        if (scenario != .natural) for (0..16) |lane| {
            ra[f][lane] = scenario != .b_only and lane % 3 != 0;
            rb[f][lane] = scenario != .a_only and lane % 3 != 0;
        };
        const ca = source.choices(true, 0, source.arena.getActionMaskA(0));
        const cb = source.choices(false, 0, source.arena.getActionMaskB(0));
        for (0..16) |lane| {
            aa[f][lane] = ca.items[random.uintLessThan(u8, ca.len)];
            bb[f][lane] = cb.items[random.uintLessThan(u8, cb.len)];
        }
    }
    var duels: [fixtures]D = undefined;
    for (&duels) |*d| d.* = try D.init(std.heap.page_allocator);
    defer for (&duels) |*d| d.deinit();
    var ns = [2]u64{ 0, 0 };
    var timer = try std.time.Timer.start();
    for (0..repeats) |iteration| {
        // Reverse order each iteration to reduce warmup/clock bias.
        for (0..2) |index| {
            const mode = (iteration + index) % 2;
            for (&duels, 0..) |*d, f| for (0..16) |lane| d.restore(lane, states[f]);
            timer.reset();
            if (mode == 0) {
                if (staging_only) {
                    for (&duels, 0..) |*d, f| d.applyMaskedReference(aa[f], bb[f], ra[f], rb[f]);
                } else {
                    for (&duels, 0..) |*d, f| d.applyMaskedStagingBaseline(aa[f], bb[f], ra[f], rb[f]);
                }
            } else {
                if (staging_only) {
                    for (&duels, 0..) |*d, f| d.applyMaskedStagingBaseline(aa[f], bb[f], ra[f], rb[f]);
                } else {
                    for (&duels, 0..) |*d, f| d.applyMasked(aa[f], bb[f], ra[f], rb[f]);
                }
            }
            ns[mode] += timer.read();
            // Make all output observable and check complete state equality.
            if (iteration == repeats - 1) for (&duels, 0..) |*d, f| {
                for (0..16) |lane| source.restore(lane, states[f]);
                source.applyMaskedReference(aa[f], bb[f], ra[f], rb[f]);
                for (0..16) |lane| if (!std.meta.eql(source.snapshot(lane), d.snapshot(lane))) return error.StateMismatch;
            };
        }
    }
    try std.io.getStdOut().writer().print("{{\"spec_a\":\"{s}\",\"spec_b\":\"{s}\",\"scenario\":\"{s}\",\"calls\":{d},\"reference_ns\":{d},\"optimized_ns\":{d},\"speedup\":{d:.4}}}\n", .{ @tagName(a), @tagName(b), @tagName(scenario), fixtures * repeats, ns[0], ns[1], @as(f64, @floatFromInt(ns[0])) / @as(f64, @floatFromInt(ns[1])) });
}
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const staging_only = if (args.next()) |arg| std.mem.eql(u8, arg, "--staging-only") else false;
    inline for (.{ Scenario.natural, Scenario.a_only, Scenario.b_only, Scenario.both }) |scenario| {
        if (!staging_only or scenario == .natural) {
            try run(.warlock, .warlock, scenario, staging_only);
            try run(.warlock, .frost_mage, scenario, staging_only);
            try run(.frost_mage, .frost_mage, scenario, staging_only);
        }
    }
}
