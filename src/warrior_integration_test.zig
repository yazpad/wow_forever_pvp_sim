const std = @import("std");
const sim = @import("search_sim.zig");
const spec = @import("spec.zig");
const warrior = @import("warrior_arena.zig");
const V = @Vector(16, f32);

fn near(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.001);
}
fn setup(d: anytype, comptime side: bool) !void {
    try d.setWarriorConfig(side, .{ .main_hand = .{ .min = 100, .max = 100, .speed = 2, .two_handed = true }, .attack_power = 0, .white_hit = 1, .special_hit = 1, .crit = 0, .starting_rage = 30 });
    for (0..16) |lane| d.arena.resetDuel(lane);
    const s = d.arena.combat();
    @memset(s.distance, 3);
    @memset(s.pos_x_a, -1.5);
    @memset(s.pos_x_b, 1.5);
}

test "Warrior storage is absent from legacy arenas and snapshots retain their measured size" {
    try std.testing.expect(sim.SnapshotFor(.priest, .warlock) == sim.Snapshot);
    try std.testing.expect(sim.SnapshotFor(.frost_mage, .priest) == sim.Snapshot);
    try std.testing.expectEqual(@as(usize, 956), @sizeOf(sim.Snapshot));
    try std.testing.expectEqual(@as(usize, 496), @sizeOf(@import("match_recorder.zig").RecordedFrame));
    try std.testing.expectEqual(@sizeOf(@import("match_recorder.zig").RecordedFrame) + 38 * @sizeOf(f32), @sizeOf(@import("match_recorder.zig").RecordedFrameFor(true)));
    try std.testing.expectEqual(@as(usize, 63), @import("action_catalog_generated.zig").MaxChoices);
    const LegacyArena = @import("multi_spec.zig").ArenaPool(.priest, .warlock);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(LegacyArena, "warrior")));
    try std.testing.expectEqual(@sizeOf(sim.Snapshot) + 4 * warrior.column_count, @sizeOf(sim.SnapshotFor(.warrior, .priest)));
    try std.testing.expectEqual(@sizeOf(sim.Snapshot) + 8 * warrior.column_count, @sizeOf(sim.SnapshotFor(.warrior, .warrior)));
}

test "Warrior auto swings, flat rage and queued Heroic Strike work on both sides" {
    inline for (.{ true, false }) |side| {
        var d = try sim.Duel(if (side) .warrior else .priest, if (side) .priest else .warrior).init(std.testing.allocator);
        defer d.deinit();
        try setup(&d, side);
        const s = d.arena.combat();
        const target = if (side) s.hp_b else s.hp_a;
        d.tick(6000);
        try near(1900, target[0]);
        try near(39, d.arena.warrior.floats(side, .rage, 0).*[0]);
        try near(2, d.arena.warrior.floats(side, .main_swing, 0).*[0]);
        d.arena.warrior.floats(side, .main_swing, 0).* = @splat(0);
        if (side) d.apply(@splat(.{ .ability = 1 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 1 }));
        try near(39, d.arena.warrior.floats(side, .rage, 0).*[0]);
        d.tick(6000);
        try near(1643, target[0]);
        try near(24, d.arena.warrior.floats(side, .rage, 0).*[0]);
        try near(0, d.arena.warrior.floats(side, .queued_strike, 0).*[0]);
        try near(0, (if (side) s.mana_a else s.mana_b)[0]);
    }
}

test "Warrior attacks respect range, control, armor, shields and Inner Fire charges" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    const s = d.arena.combat();
    s.distance[0] = 10;
    s.pos_x_b[0] = 8.5;
    s.fear_timer_a[1] = 2;
    s.stun_timer_a[2] = 2;
    s.armor_damage_reduction_b[3] = 0.5;
    s.action6_dur_b[4] = 30;
    d.arena.extra(.shield, false, 0).*[4] = 500;
    s.inner_fire_timer_b[5] = 600;
    s.inner_fire_charges_b[5] = 20;
    d.tick(6000);
    for (0..3) |lane| try near(2000, s.hp_b[lane]);
    try near(1950, s.hp_b[3]);
    try near(2000, s.hp_b[4]);
    try near(400, d.arena.extra(.shield, false, 0).*[4]);
    try near(39, d.arena.warrior.floats(true, .rage, 0).*[4]); // Absorbed white hit still landed.
    try near(19, s.inner_fire_charges_b[5]);
    try std.testing.expect(s.hp_b[5] > 1900 and s.hp_b[5] < 2000);
}

test "Overpower only opens on dodge and block reduces landed damage" {
    inline for (.{ @as(u8, 0), 1, 2 }) |kind| {
        var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
        defer d.deinit();
        try setup(&d, true);
        const stats: spec.CombatStats = switch (kind) {
            0 => .{ .melee_dodge_chance = 1 },
            1 => .{ .melee_parry_chance = 1 },
            2 => .{ .melee_block_chance = 1, .melee_block_value = 30 },
            else => unreachable,
        };
        try d.setCombatStats(false, stats);
        d.apply(@splat(.{ .ability = 2 }), @splat(.{}));
        const window = d.arena.warrior.floats(true, .overpower_window, 0).*[0];
        const expected_outcome: u32 = switch (kind) {
            0 => @intFromEnum(@import("spell_resolution.zig").Outcome.dodge),
            1 => @intFromEnum(@import("spell_resolution.zig").Outcome.parry),
            2 => @intFromEnum(@import("spell_resolution.zig").Outcome.block),
            else => unreachable,
        };
        try std.testing.expectEqual(expected_outcome, @as(u32, @intFromFloat(d.arena.warrior.floats(true, .last_outcome, 0).*[0])));
        if (kind == 0) {
            try near(5, window);
            d.arena.combat().gcd_a[0] = 0;
            try std.testing.expect(d.getActionMaskA(0)[7][0]);
            d.apply(@splat(.{ .ability = 7 }), @splat(.{}));
            try near(0, d.arena.warrior.floats(true, .overpower_window, 0).*[0]);
            try near(5, d.arena.warrior.floats(true, .overpower_cd, 0).*[0]);
        } else {
            try near(0, window);
            try std.testing.expect(!d.getActionMaskA(0)[7][0]);
            if (kind == 2) try near(15, d.arena.warrior.floats(true, .pending_damage, 0).*[0]);
        }
    }
}

test "Warrior miss falls back correctly, queued cost is deferred and cancels without spending" {
    var d = try sim.Duel(.warrior, .warlock).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    var config = d.arena.warrior.configs[0];
    config.white_hit = 0;
    config.special_hit = 0;
    try d.setWarriorConfig(true, config);
    d.apply(@splat(.{ .ability = 1 }), @splat(.{}));
    d.tick(6000);
    try near(27, d.arena.warrior.floats(true, .rage, 0).*[0]); // 80% refund on 15 rage.
    try near(2000, d.arena.combat().hp_b[0]);
    d.arena.combat().react_timer_a[0] = 0;
    d.apply(@splat(.{ .ability = 1 }), @splat(.{}));
    d.arena.combat().react_timer_a[0] = 0;
    d.apply(@splat(.{ .ability = 10 }), @splat(.{}));
    try near(0, d.arena.warrior.floats(true, .queued_strike, 0).*[0]);
    try near(27, d.arena.warrior.floats(true, .rage, 0).*[0]);
}

test "Warrior dual wield swings generate independent hand rage and half offhand damage" {
    var d = try sim.Duel(.warrior, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    try d.setWarriorConfig(true, .{ .main_hand = .{ .min = 100, .max = 100, .speed = 2, .two_handed = false }, .off_hand = .{ .min = 100, .max = 100, .speed = 2, .two_handed = false }, .attack_power = 0, .white_hit = 1, .crit = 0 });
    for (0..16) |lane| d.arena.resetDuel(lane);
    @memset(d.arena.combat().distance, 3);
    @memset(d.arena.combat().pos_x_a, -1.5);
    @memset(d.arena.combat().pos_x_b, 1.5);
    d.tick(6000);
    try near(1850, d.arena.combat().hp_b[0]);
    try near(10.38, d.arena.warrior.floats(true, .rage, 0).*[0]);
}

test "Warrior Hamstring gates stance, spends once, slows and expires" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    d.arena.warrior.floats(true, .main_swing, 0).* = @splat(100);
    d.apply(@splat(.{ .ability = 2 }), @splat(.{ .movement = 1 }));
    try near(20, d.arena.warrior.floats(true, .rage, 0).*[0]);
    try near(2000, d.arena.combat().hp_b[0]); // Simultaneous actions defer damage to physics.
    d.tick(6000);
    try near(1955, d.arena.combat().hp_b[0]);
    try near(1.535, d.arena.combat().pos_x_b[0]);
    d.arena.warrior.floats(true, .stance, 0).* = @splat(2);
    d.arena.combat().gcd_a[0] = 0;
    try std.testing.expect(!d.getActionMaskA(0)[2][0]);
    d.arena.warrior.floats(true, .hamstring, 0).* = @splat(0.01);
    d.tick(6000);
    try near(0, d.arena.warrior.floats(true, .hamstring, 0).*[0]);
}

test "Warrior snapshot restores divergent lanes and continues with identical RNG and queued attacks" {
    var source = try sim.Duel(.warrior, .warrior).init(std.testing.allocator);
    defer source.deinit();
    var restored = try sim.Duel(.warrior, .warrior).init(std.testing.allocator);
    defer restored.deinit();
    try setup(&source, true);
    try setup(&source, false);
    try setup(&restored, true);
    try setup(&restored, false);
    source.apply(@splat(.{ .ability = 1 }), @splat(.{ .ability = 14 }));
    const snapshot = source.snapshot(0);
    restored.restoreAll(snapshot);
    for (0..16) |lane| source.restore(lane, snapshot);
    for (0..250) |_| {
        source.tick(6000);
        restored.tick(6000);
        for (0..16) |lane| try std.testing.expectEqualDeep(source.snapshot(lane), restored.snapshot(lane));
    }
    restored.arena.warrior.floats(true, .rage, 0).*[3] = 73;
    const divergent = restored.snapshot(3);
    restored.restore(8, divergent);
    try std.testing.expectEqualDeep(divergent, restored.snapshot(8));
}

test "Warrior simultaneous and one-sided staging matches full reference across lane masks" {
    var fast = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer fast.deinit();
    var reference = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer reference.deinit();
    try setup(&fast, true);
    try setup(&reference, true);
    for (0..100) |step| {
        var ra: @Vector(16, bool) = undefined;
        var rb: @Vector(16, bool) = undefined;
        var aa: [16]sim.Action = undefined;
        var bb: [16]sim.Action = undefined;
        for (0..16) |lane| {
            ra[lane] = lane % 3 != 0;
            rb[lane] = step % 3 == 0 and lane % 2 == 0;
            aa[lane] = .{ .ability = switch (step % 5) {
                0 => 1,
                1 => 14,
                2 => 15,
                3 => 2,
                else => 10,
            }, .movement = -1 };
            bb[lane] = .{ .ability = if (step % 2 == 0) 6 else 1 };
        }
        fast.applyMasked(aa, bb, ra, rb);
        reference.applyMaskedReference(aa, bb, ra, rb);
        for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
        fast.tick(6000);
        reference.tick(6000);
        for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
    }
}

test "Warrior melee causes cast pushback only after absorption and splits Soul Link damage" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    const s = d.arena.combat();
    s.cast_id_b[0] = 14;
    s.cast_id_b[1] = 14;
    s.cast_total_b[0] = 2;
    s.cast_total_b[1] = 2;
    s.cast_timer_b[0] = 1;
    s.cast_timer_b[1] = 1;
    s.action6_dur_b[1] = 30;
    d.arena.extra(.shield, false, 0).*[1] = 500;
    d.tick(6000);
    try std.testing.expect(s.cast_timer_b[0] > 1.5);
    try std.testing.expect(s.cast_timer_b[1] < 1);
    var linked = try sim.Duel(.warrior, .warlock).init(std.testing.allocator);
    defer linked.deinit();
    try setup(&linked, true);
    linked.arena.combat().soul_link_b[0] = 1;
    linked.arena.combat().pet_hp_b[0] = 500;
    linked.tick(6000);
    try near(1930, linked.arena.combat().hp_b[0]);
    try near(470, linked.arena.combat().pet_hp_b[0]);
}

test "Warrior MCTS workers receive immutable configuration and restore extended snapshots" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    const search = try @import("mcts.zig").Search(.warrior, .priest).init(std.testing.allocator, .{ .rollouts = 8, .workers = 2, .nodes = 64, .depth = 8, .evaluator = .heuristic, .truncation_ticks = 3 });
    defer search.deinit();
    try search.setWarriorConfig(true, d.arena.warrior.configs[0]);
    for (search.workers) |*worker| try near(100, worker.duel.arena.warrior.configs[0].main_hand.min);
    var rng = std.Random.DefaultPrng.init(42);
    const result = search.decide(d.snapshot(0), rng.random());
    try std.testing.expect(result.stats.rollouts > 0);
    try std.testing.expect(d.getActionMaskA(0)[result.actions[0].ability][0]);
}

test "Warrior starter presets preserve explicit weapons, talent ranks and capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const two = try spec.loadSpecFile(arena.allocator(), "specs/warrior_two_hand.json");
    const dual = try spec.loadSpecFile(arena.allocator(), "specs/warrior_dual_wield.json");
    try std.testing.expect(two.class == .warrior and two.pet == .none);
    try std.testing.expect(two.warrior.main_hand.two_handed and two.warrior.off_hand == null);
    try std.testing.expect(!dual.warrior.main_hand.two_handed and dual.warrior.off_hand != null);
    try near(0.76, dual.warrior.white_hit);
    try near(4000, two.combat_stats.max_health);
    try std.testing.expectEqual(@as(u8, 3), two.warrior.build.ranks[@intFromEnum(@import("warrior_talents.zig").Talent.improvedHeroicStrike)]);
    try std.testing.expect(two.action_mask & (@as(u32, 1) << 1) != 0);
    // Extended kernel actions must survive the separate preset capability filter.
    inline for (.{ 3, 4, 6, 7, 8, 9, 11, 12 }) |id| {
        try std.testing.expect(two.action_mask & (@as(u32, 1) << id) != 0);
    }
    const fury = try spec.loadSpecFile(arena.allocator(), "specs/warrior_fury.json");
    inline for (.{ 4, 16, 23, 24 }) |id| {
        try std.testing.expect(fury.action_mask & (@as(u32, 1) << id) != 0);
    }
    try std.testing.expect(fury.action_mask & (@as(u32, 1) << 5) == 0);
    try std.testing.expect(two.action_mask & (@as(u32, 1) << 16) == 0);
    try std.testing.expect(two.action_mask & (@as(u32, 1) << 24) == 0);
    try std.testing.expect(two.action_mask & (@as(u32, 1) << 21) == 0); // Replay-only auto attack ID.
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realpathAlloc(arena.allocator(), ".");
    const preset = try std.fs.path.join(arena.allocator(), &.{ path, "preset.json" });
    // Empty Lua tables export as arrays. They still represent an empty tree.
    try temp.dir.writeFile(.{ .sub_path = "preset.json", .data = "{\"class\":\"warrior\",\"trees\":{\"Arms\":[],\"Fury\":[],\"Protection\":[]},\"warrior\":{\"starting_stance\":\"defensive\",\"starting_rage\":50}}" });
    const loaded = try spec.loadSpecFile(arena.allocator(), preset);
    try std.testing.expect(loaded.warrior.starting_stance == .defensive);
    try near(50, loaded.warrior.starting_rage);
    try temp.dir.writeFile(.{ .sub_path = "preset.json", .data = "{\"class\":\"warrior\",\"trees\":{\"Arms\":{\"99999\":1},\"Fury\":[],\"Protection\":[]}}" });
    try std.testing.expectError(error.UnknownTalent, spec.loadSpecFile(arena.allocator(), preset));
    try temp.dir.writeFile(.{ .sub_path = "preset.json", .data = "{\"class\":\"warrior\",\"warrior\":{\"build\":{}}}" });
    try std.testing.expectError(error.InvalidWarriorConfig, spec.loadSpecFile(arena.allocator(), preset));
}

test "Warrior recording attributes effective melee to hands and retains all telemetry columns" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    var record: [2]@import("warrior_recording.zig").Tick = .{ .{}, .{} };
    d.arena.warrior.recording = &record;
    d.arena.extra(.shield, false, 0).* = @splat(60);
    d.arena.combat().action6_dur_b[0] = 20;
    d.tick(6000);
    try near(40, record[0].damage[21]);
    try near(0, record[1].damage[21]);
    const recording = @import("match_recorder.zig");
    const telemetry = recording.warriorTelemetry(&d.arena, .warrior, true);
    try near(39, telemetry[0]);
    try near(1, telemetry[1]);
    try near(2, telemetry[2]);
    d.arena.warrior.floats(true, .main_swing, 0).* = @splat(0);
    d.arena.combat().react_timer_a[0] = 0;
    d.apply(@splat(.{ .ability = 1 }), @splat(.{}));
    record = .{ .{}, .{} };
    d.tick(6000);
    try near(257, record[0].damage[1]);
    try near(0, record[0].damage[21]);
}

test "Warrior saved analysis metadata reconstructs the extended state without mutable presets" {
    const analysis = @import("fight_analysis.zig");
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    const Run = analysis.SavedRunFor(.warrior, .priest);
    const snapshot = d.snapshot(0);
    const run: Run = .{ .simulator_version = "mcts-simultaneous-v2-pets", .options = .{ .a = .warrior, .b = .priest, .config = .{}, .warrior_a = d.arena.warrior.configs[0] }, .initial_state = snapshot, .decisions = &.{} };
    const bytes = try std.json.stringifyAlloc(std.testing.allocator, run, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Run, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try analysis.configure(&d, parsed.value.options);
    d.restoreAll(parsed.value.initial_state);
    try std.testing.expectEqualDeep(snapshot, d.snapshot(0));
    try near(100, d.arena.warrior.configs[0].main_hand.min);
    try std.testing.expect(sim.SnapshotFor(.priest, .warlock) == sim.Snapshot);
}

test "Fury passive crits refresh Flurry and haste advances swings without changing base rage speed" {
    var allocations = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocations.deinit();
    const loaded = try spec.loadSpecFile(allocations.allocator(), "specs/warrior_fury_passives.json");
    var config = loaded.warrior;
    config.main_hand = .{ .min = 100, .max = 100, .speed = 2, .two_handed = false };
    config.off_hand = .{ .min = 100, .max = 100, .speed = 2, .two_handed = false };
    config.attack_power = 0;
    config.white_hit = 0.97; // Precision makes main-hand hits certain.
    config.crit = 1;
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try d.setWarriorConfig(true, config);
    try d.setCombatStats(true, loaded.combat_stats);
    for (0..16) |lane| d.arena.resetDuel(lane);
    @memset(d.arena.combat().distance, 3);
    @memset(d.arena.combat().pos_x_a, -1.5);
    @memset(d.arena.combat().pos_x_b, 1.5);
    d.arena.warrior.integers(true, .rng, 0).* = @splat(1);
    d.tick(6000);
    try near(1675, d.arena.combat().hp_b[0]); // 200 MH + 125 OH (5/5 DW specialization).
    try near(3, d.arena.warrior.floats(true, .flurry_stacks, 0).*[0]);
    try near(1.25, warrior.swingHaste(&d.arena, true, 0)[0]);
    try near(2, d.arena.warrior.floats(true, .main_swing, 0).*[0]);
    d.tick(6000);
    try near(1.9875, d.arena.warrior.floats(true, .main_swing, 0).*[0]);
    var wrath_gained: f32 = 0;
    for (0..16) |lane| wrath_gained += d.arena.warrior.floats(true, .rage_from_wrath, 0).*[lane];
    try std.testing.expect(wrath_gained > 0);
    const snapshot = d.snapshot(0);
    d.tick(6000);
    const continued = d.snapshot(0);
    d.restore(0, snapshot);
    d.tick(6000);
    try std.testing.expectEqualDeep(continued, d.snapshot(0));
}

test "Fury incoming hit rage caps per lane and Enrage procs independently of the rage switch" {
    var allocations = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocations.deinit();
    const loaded = try spec.loadSpecFile(allocations.allocator(), "specs/warrior_fury_passives.json");
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try d.setWarriorConfig(true, loaded.warrior);
    try d.setCombatStats(true, loaded.combat_stats);
    for (0..16) |lane| d.arena.resetDuel(lane);
    d.arena.warrior.integers(true, .rng, 0).* = @splat(1);
    d.arena.warrior.floats(true, .rage, 0).* = @splat(129);
    var raw: V = @splat(1000);
    raw[1] = 0;
    warrior.receiveHit(&d.arena, true, 0, raw);
    try near(130, d.arena.warrior.floats(true, .rage, 0).*[0]);
    try near(1, d.arena.warrior.floats(true, .rage_from_hits, 0).*[0]);
    try near(12, d.arena.warrior.floats(true, .enrage, 0).*[0]);
    try near(129, d.arena.warrior.floats(true, .rage, 0).*[1]);
    try near(0, d.arena.warrior.floats(true, .enrage, 0).*[1]);
    var config = loaded.warrior;
    config.damage_taken_rage = false;
    try d.setWarriorConfig(true, config);
    d.arena.warrior.integers(true, .rng, 0).* = @splat(1);
    warrior.receiveHit(&d.arena, true, 0, @splat(1000));
    try near(129, d.arena.warrior.floats(true, .rage, 0).*[1]);
    try near(12, d.arena.warrior.floats(true, .enrage, 0).*[1]);
}

test "Warrior movement decisions continue during GCD while instant abilities stay on cooldown" {
    var d = try sim.Duel(.warrior, .warrior).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    try setup(&d, false);
    const state = d.arena.combat();
    state.gcd_a[0] = 1.4;
    state.gcd_b[0] = 1.4;
    state.react_timer_a[0] = 0;
    state.react_timer_b[0] = 0;
    try std.testing.expect(d.readyTactical(true)[0] and d.readyTactical(false)[0]);
    try std.testing.expect(!d.getActionMaskA(0)[2][0] and !d.getActionMaskB(0)[2][0]);
    const before = state.pos_x_a[0];
    d.applyTactical(@splat(.{ .movement = -1 }), @splat(.{}));
    d.tick(6000);
    try std.testing.expect(state.pos_x_a[0] > before);
    try std.testing.expect(state.gcd_a[0] > 1);
    try std.testing.expect(!d.readyTactical(true)[0]); // Keep the reaction interval.
    for (0..15) |_| d.tick(6000);
    try std.testing.expect(d.readyTactical(true)[0] and state.gcd_a[0] > 1);

    var caster = try sim.Duel(.priest, .warlock).init(std.testing.allocator);
    defer caster.deinit();
    caster.arena.combat().gcd_a[0] = 1;
    caster.arena.combat().react_timer_a[0] = 0;
    try std.testing.expect(!caster.readyTactical(true)[0]);
}

test "Warrior gap closers preserve movement and instant melee attacks can land while walking" {
    var d = try sim.Duel(.warrior, .priest).init(std.testing.allocator);
    defer d.deinit();
    try setup(&d, true);
    const state = d.arena.combat();
    state.pos_x_a[0] = -7.5;
    state.pos_x_b[0] = 7.5;
    state.distance[0] = 15;
    d.applyTactical(@splat(.{ .ability = 3, .movement = -1 }), @splat(.{}));
    try near(warrior.GapCloseDistance, state.distance[0]);
    try near(-1, state.move_intent_a[0]);
    const charge_x = state.pos_x_a[0];
    d.tick(6000);
    try std.testing.expect(state.pos_x_a[0] > charge_x);
    try std.testing.expect(state.distance[0] < 5);

    state.gcd_a[0] = 0;
    state.react_timer_a[0] = 0;
    d.arena.warrior.floats(true, .rage, 0).*[0] = 30;
    const hp_before = state.hp_b[0];
    const x_before = state.pos_x_a[0];
    d.applyTactical(@splat(.{ .ability = 2, .movement = -1 }), @splat(.{}));
    d.tick(6000);
    try std.testing.expect(state.hp_b[0] < hp_before);
    try std.testing.expect(state.pos_x_a[0] > x_before);
    try near(0, @floatFromInt(state.cast_id_a[0]));
}
