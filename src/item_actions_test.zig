const std = @import("std");
const sim = @import("search_sim.zig");
const items = @import("item_actions.zig");
const Spec = @import("spec.zig").Spec;
const V = @Vector(16, bool);
fn near(a: f32, b: f32) !void {
    try std.testing.expectApproxEqAbs(a, b, 0.001);
}

test "Greater Insignia cleanses control off GCD on both sides without removing damage or resetting DR" {
    inline for (.{ .{ Spec.warlock, Spec.frost_mage }, .{ Spec.priest, Spec.warrior } }) |pair| {
        inline for (.{ true, false }) |side| {
            var duel = try sim.Duel(pair[0], pair[1]).init(std.testing.allocator);
            defer duel.deinit();
            duel.setPvpTrinket(side, items.alliance_id);
            const s = duel.arena.combat();
            const suffix = if (side) "_a" else "_b";
            const opponent = if (side) pair[1] else pair[0];
            for (0..16) |lane| {
                @field(s, "fear_timer" ++ suffix)[lane] = 3;
                @field(s, "horror_timer" ++ suffix)[lane] = 2;
                @field(s, "seduction_timer" ++ suffix)[lane] = 1;
                @field(s, "seduced" ++ suffix)[lane] = 1;
                @field(s, "stun_timer" ++ suffix)[lane] = 4;
                @field(s, "agony_timer" ++ suffix)[lane] = 10;
                @field(s, "corruption_timer" ++ suffix)[lane] = 20;
                @field(s, "gcd" ++ suffix)[lane] = 0.9;
                @field(s, "react_timer" ++ suffix)[lane] = 0.8;
                @field(s, "mana" ++ suffix)[lane] = 500;
                @field(s, "fear_dr_tier" ++ suffix)[lane] = 2;
                @field(s, "fear_dr_timer" ++ suffix)[lane] = 12;
            }
            if (opponent == .warrior) duel.arena.warrior.floats(!side, .hamstring, 0).* = @splat(9);
            if (opponent == .priest) duel.arena.extra(.lockout, side, 0).* = @splat(5);
            try std.testing.expect((if (side) duel.readyTactical(true) else duel.readyTactical(false))[0]);
            var ready: V = @splat(false);
            for (0..16) |lane| ready[lane] = lane % 2 == 0;
            const actions: [16]sim.Action = @splat(.{ .ability = items.action_id });
            const idle: [16]sim.Action = @splat(.{});
            duel.applyMasked(if (side) actions else idle, if (side) idle else actions, if (side) ready else @splat(false), if (side) @as(V, @splat(false)) else ready);
            for (0..16) |lane| {
                const used = lane % 2 == 0;
                try near(if (used) 300 else 0, @field(s, "item_cd" ++ suffix)[lane]);
                try near(if (used) 0 else 3, @field(s, "fear_timer" ++ suffix)[lane]);
                try near(if (used) 0 else 2, @field(s, "horror_timer" ++ suffix)[lane]);
                try near(if (used) 0 else 1, @field(s, "seduction_timer" ++ suffix)[lane]);
                try near(if (used) 0 else 4, @field(s, "stun_timer" ++ suffix)[lane]);
                try near(if (used and opponent == .frost_mage) 0 else 10, @field(s, "agony_timer" ++ suffix)[lane]);
                try near(if (used and opponent == .frost_mage) 0 else 20, @field(s, "corruption_timer" ++ suffix)[lane]);
                try near(0.9, @field(s, "gcd" ++ suffix)[lane]);
                try near(500, @field(s, "mana" ++ suffix)[lane]);
                try near(2, @field(s, "fear_dr_tier" ++ suffix)[lane]);
                try near(12, @field(s, "fear_dr_timer" ++ suffix)[lane]);
            }
            const after = duel.snapshot(0);
            duel.restore(7, after);
            try near(300, @field(s, "item_cd" ++ suffix)[7]);
            try std.testing.expectEqual(items.alliance_id, @field(s, "item_id" ++ suffix)[7]);
            @field(s, "fear_timer" ++ suffix)[0] = 5;
            duel.applyMasked(if (side) actions else idle, if (side) idle else actions, if (side) @splat(true) else @splat(false), if (side) @as(V, @splat(false)) else @splat(true));
            try near(5, @field(s, "fear_timer" ++ suffix)[0]);
            items.tick(s, 0, 299.5);
            try near(0.5, @field(s, "item_cd" ++ suffix)[0]);
            items.tick(s, 0, 1);
            try near(0, @field(s, "item_cd" ++ suffix)[0]);
        }
    }
}

test "Greater Insignia cannot activate unequipped and restores exactly across staging paths" {
    var fast = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer fast.deinit();
    var reference = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer reference.deinit();
    fast.arena.combat().horror_timer_a[0] = 3;
    try std.testing.expect(!fast.getActionMaskA(0)[items.action_id][0]);
    fast.setPvpTrinket(true, items.horde_id);
    const before = fast.snapshot(0);
    for (0..16) |lane| reference.restore(lane, fast.snapshot(lane));
    const actions: [16]sim.Action = @splat(.{ .ability = items.action_id });
    const idle: [16]sim.Action = @splat(.{});
    fast.applyMasked(actions, idle, @splat(true), @splat(false));
    reference.applyMaskedReference(actions, idle, @splat(true), @splat(false));
    for (0..16) |lane| try std.testing.expectEqualDeep(fast.snapshot(lane), reference.snapshot(lane));
    const after = fast.snapshot(0);
    fast.restore(0, before);
    fast.applyMasked(actions, idle, @splat(true), @splat(false));
    try std.testing.expectEqualDeep(after, fast.snapshot(0));
    fast.arena.resetDuel(0);
    try near(0, fast.arena.combat().item_cd_a[0]);
    try std.testing.expectEqual(@as(u32, 0), fast.arena.combat().item_id_a[0]);
}

test "Greater Insignia resolves after simultaneous control applications without lasting immunity" {
    var duel = try sim.Duel(.warlock, .priest).init(std.testing.allocator);
    defer duel.deinit();
    duel.setPvpTrinket(true, items.alliance_id);
    const s = duel.arena.combat();
    s.horror_timer_a[0] = 1;
    @memset(s.distance, 3);
    @memset(s.spell_hit_chance_b, 1);
    @memset(s.shadow_resist_chance_a, 0);
    const trinket: [16]sim.Action = @splat(.{ .ability = items.action_id });
    const scream: [16]sim.Action = @splat(.{ .ability = 3 });
    duel.applyMasked(trinket, scream, @splat(true), @splat(true));
    try near(0, s.fear_timer_a[0]);
    try near(0, s.horror_timer_a[0]);
    try near(300, s.item_cd_a[0]);
    // The item removes control; it does not erase the spell's DR bookkeeping.
    try std.testing.expect(s.fear_dr_tier_a[0] > 0);
    s.fear_timer_a[0] = 4;
    try std.testing.expect(!duel.getActionMaskA(0)[items.action_id][0]);
    try near(4, s.fear_timer_a[0]);
}

test "Greater Insignia preserves casts and does not consume mana GCD or racial cooldown" {
    var d = try sim.Duel(.frost_mage, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    d.setPvpTrinket(true, items.alliance_id);
    const s = d.arena.combat();
    s.agony_timer_a[0] = 3;
    s.cast_id_a[0] = 4;
    s.cast_timer_a[0] = 1;
    s.cast_total_a[0] = 2.5;
    s.gcd_a[0] = 1;
    s.react_timer_a[0] = 0.7;
    s.mana_a[0] = 500;
    s.five_sec_timer_a[0] = 3;
    s.racial_cd_a[0] = 99;
    d.applyTactical(@splat(.{ .ability = items.action_id }), @splat(.{}));
    try near(300, s.item_cd_a[0]);
    try near(0, s.agony_timer_a[0]);
    try std.testing.expectEqual(@as(u32, 4), s.cast_id_a[0]);
    try near(1, s.cast_timer_a[0]);
    try near(2.5, s.cast_total_a[0]);
    try near(1, s.gcd_a[0]);
    try near(500, s.mana_a[0]);
    try near(3, s.five_sec_timer_a[0]);
    try near(99, s.racial_cd_a[0]);
}

test "MCTS sees the equipped trinket through worker snapshots and selects a control break" {
    var d = try sim.Duel(.warlock, .priest).init(std.testing.allocator);
    defer d.deinit();
    d.setPvpTrinket(true, items.alliance_id);
    d.arena.combat().horror_timer_a[0] = 3;
    const search = try @import("mcts.zig").Search(.warlock, .priest).init(std.testing.allocator, .{ .rollouts = 64, .nodes = 32, .depth = 1, .max_ticks = 20, .evaluator = .heuristic });
    defer search.deinit();
    search.setActionMaskA(@as(u32, 1) << items.action_id);
    search.setActionMaskB(0);
    const before = d.snapshot(0);
    var rng = std.Random.DefaultPrng.init(3);
    const result = search.decide(before, rng.random());
    try std.testing.expectEqual(items.action_id, result.actions[0].ability);
    try std.testing.expect(result.stats.rollouts > 0);
    try std.testing.expectEqualDeep(before, d.snapshot(0));
}

test "item replay metadata and appended cooldown columns retain starting loadouts" {
    const recorder = @import("match_recorder.zig");
    inline for (.{ false, true }) |warrior| {
        var trajectory = try recorder.MatchTrajectoryFor(warrior).init(std.testing.allocator, "A", "B", 0, 0);
        defer trajectory.deinit();
        trajectory.pvp_trinket_a = items.alliance_id;
        var frame = std.mem.zeroes(recorder.RecordedFrameFor(warrior));
        frame.item_cd_a = 299.99;
        frame.action_a = items.action_id;
        try trajectory.frames.append(frame);
        try trajectory.events.append(.{ .time_s = 0, .source = 0, .target = 0, .kind = .ItemActivated, .spell_id = items.action_id, .amount = 0 });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const folder = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(folder);
        const path = try std.fs.path.join(std.testing.allocator, &.{ folder, "item.json" });
        defer std.testing.allocator.free(path);
        try trajectory.exportJson(path);
        const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const meta = root.get("meta").?.object;
        try std.testing.expectEqual(@as(i64, items.alliance_id), meta.get("pvp_trinket_a").?.integer);
        const index: usize = @intCast(meta.get("item_cooldown_column").?.integer);
        try std.testing.expectEqual(@as(usize, if (warrior) 163 else 125), index);
        const rows = root.get("frames").?.array.items[0].array.items;
        try std.testing.expectApproxEqAbs(@as(f64, 299.99), rows[index - 1].float, 0.001);
        try std.testing.expectEqual(@as(i64, 19), root.get("events").?.array.items[0].object.get("k").?.integer);
    }
}
