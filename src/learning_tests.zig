const std = @import("std");
const value = @import("learned_value.zig");
const sim = @import("search_sim.zig");
const mcts = @import("mcts.zig");
const Spec = @import("spec.zig").Spec;
const zero: value.Network = .{ .w = @splat(@splat(0)), .bias = @splat(0), .out = @splat(0), .out_bias = 0 };
const bundle: value.Bundle = .{ .fingerprint = "test", .mode = .class, .networks = .{ zero, zero } };

test "learning perspective reverses with actor roles and features survive snapshot restore" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |a| inline for (.{ Spec.warlock, Spec.frost_mage }) |b| {
        var d = try sim.Duel(a, b).init(std.testing.allocator);
        defer d.deinit();
        var reverse = try sim.Duel(b, a).init(std.testing.allocator);
        defer reverse.deinit();
        d.arena.combat().hp_a[0] = 1234;
        d.arena.combat().mana_b[0] = 321;
        reverse.arena.combat().hp_b[0] = 1234;
        reverse.arena.combat().mana_a[0] = 321;
        const x = value.features(a, b, true, &d, 0, 6000);
        try std.testing.expectEqualDeep(x, value.features(b, a, false, &reverse, 0, 6000));
        const snap = d.snapshot(0);
        d.restore(7, snap);
        try std.testing.expectEqualDeep(x, value.features(a, b, true, &d, 7, 6000));
        for (x) |v| try std.testing.expect(std.math.isFinite(v));
    };
}

test "learned death and timeout values are exact and missing models rejected" {
    var d = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    const cfg: mcts.Config = .{ .model = &bundle, .evaluator = .learned };
    d.arena.combat().hp_b[0] = 0;
    try std.testing.expectEqual(@as(f32, 1), mcts.evaluateLeaf(.warlock, .frost_mage, &d, 0, cfg));
    d.arena.combat().hp_a[0] = 0;
    try std.testing.expectEqual(@as(f32, 0), mcts.evaluateLeaf(.warlock, .frost_mage, &d, 0, cfg));
    d.arena.combat().hp_b[0] = 2000;
    try std.testing.expectEqual(@as(f32, -1), mcts.evaluateLeaf(.warlock, .frost_mage, &d, 0, cfg));
    d.arena.combat().hp_a[0] = 2000;
    d.ticks[0] = cfg.max_ticks;
    try std.testing.expectEqual(@as(f32, 0), mcts.evaluateLeaf(.warlock, .frost_mage, &d, 0, cfg));
    try std.testing.expectError(error.MissingLearnedModel, mcts.Search(.warlock, .frost_mage).init(std.testing.allocator, .{ .evaluator = .learned }));
}

test "zero mixture preserves bare MCTS root distribution" {
    var d = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    const cfg: mcts.Config = .{ .evaluator = .heuristic, .rollouts = 64, .nodes = 32, .max_ticks = 1000 };
    const baseline = try mcts.Search(.warlock, .frost_mage).init(std.testing.allocator, cfg);
    defer baseline.deinit();
    var learned_cfg = cfg;
    learned_cfg.model = &bundle;
    learned_cfg.evaluator = .learned;
    learned_cfg.learned_mix = 0;
    const candidate = try mcts.Search(.warlock, .frost_mage).init(std.testing.allocator, learned_cfg);
    defer candidate.deinit();
    var r1 = std.Random.DefaultPrng.init(42);
    var r2 = std.Random.DefaultPrng.init(42);
    const x = baseline.decide(d.snapshot(0), r1.random());
    const y = candidate.decide(d.snapshot(0), r2.random());
    try std.testing.expectEqualDeep(x.distributions, y.distributions);
    try std.testing.expectEqualDeep(x.actions, y.actions);
    try std.testing.expectEqualDeep(x.stats, y.stats);
}
