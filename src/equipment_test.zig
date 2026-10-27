const std = @import("std");
const spec = @import("spec.zig");
const sim = @import("search_sim.zig");

test "geared resource maxima retain racial and talent contributions through staging and snapshots" {
    const allocator = std.testing.allocator;
    var fixtures = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("testdata/equipment_parity.json"), .{});
    defer fixtures.deinit();
    var input = fixtures.value.array.items[0].object.get("input").?;
    _ = input.object.swapRemove("gear_base_stats");
    try input.object.put("race", .{ .string = "gnome" });
    const trees = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"Affliction":{},"Demonology":{"105907":5,"105903":3},"Destruction":{}}
    , .{});
    defer trees.deinit();
    try input.object.put("trees", trees.value);
    const json = try std.json.stringifyAlloc(allocator, input, .{});
    defer allocator.free(json);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "gear.json", .data = json });
    const path = try tmp.dir.realpathAlloc(allocator, "gear.json");
    defer allocator.free(path);
    const cfg = try spec.loadSpecFile(allocator, path);
    defer allocator.free(cfg.name);
    defer allocator.free(cfg.id);
    try std.testing.expectEqual(@as(f32, 2670), cfg.combat_stats.max_health);
    try std.testing.expectEqual(@as(f32, 67), cfg.combat_stats.stamina);
    try std.testing.expectApproxEqAbs(@as(f32, 2640.75), cfg.combat_stats.max_mana, 0.001);

    var duel = try sim.Duel(.warlock, .warlock).init(allocator);
    defer duel.deinit();
    duel.setWarlockTalentRanksA(cfg.warlock_talents.encode());
    duel.setWarlockTalentRanksB(cfg.warlock_talents.encode());
    // The loader applies racials; installation adds supported talents once.
    inline for (.{ true, false }) |side| {
        for (0..2) |_| try duel.setCombatStats(side, cfg.combat_stats);
        const suffix = if (side) "_a" else "_b";
        inline for (.{ &duel.arena, &duel.scratch, &duel.original }) |pool| {
            const state = pool.combat();
            try std.testing.expectApproxEqAbs(@as(f32, 2770.5), @field(state, "max_health" ++ suffix)[0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 3036.8625), @field(state, "max_mana" ++ suffix)[0], 0.001);
        }
    }
    const snapshot = duel.snapshot(0);
    duel.restore(7, snapshot);
    const state = duel.arena.combat();
    try std.testing.expectEqual(state.max_health_a[0], state.max_health_a[7]);
    try std.testing.expectEqual(state.max_mana_b[0], state.max_mana_b[7]);
}

fn fixtureNumber(value: std.json.Value) f32 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| @floatCast(n),
        else => unreachable,
    };
}

test "reference profile resource maxima and crit reach all caster staging arenas" {
    const allocator = std.testing.allocator;
    const fixtures = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("testdata/reference_stats.json"), .{});
    defer fixtures.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "reference.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "reference.json");
    defer allocator.free(path);
    inline for (.{ spec.Spec.warlock, spec.Spec.frost_mage, spec.Spec.priest }) |class| {
        var duel = try sim.Duel(class, class).init(allocator);
        defer duel.deinit();
        for (fixtures.value.array.items) |fixture| {
            if (!std.mem.eql(u8, fixture.object.get("input").?.object.get("class").?.string, @tagName(class))) continue;
            const json = try std.json.stringifyAlloc(allocator, fixture.object.get("input").?, .{});
            defer allocator.free(json);
            try tmp.dir.writeFile(.{ .sub_path = "reference.json", .data = json });
            const cfg = try spec.loadSpecFile(allocator, path);
            defer allocator.free(cfg.name);
            defer allocator.free(cfg.id);
            duel.setWarlockTalentRanksA(cfg.warlock_talents.encode());
            duel.setWarlockTalentRanksB(cfg.warlock_talents.encode());
            const expected = fixture.object.get("runtime_expected").?.object;
            inline for (.{ true, false }) |side| {
                for (0..2) |_| try duel.setCombatStats(side, cfg.combat_stats);
                const suffix = if (side) "_a" else "_b";
                inline for (.{ &duel.arena, &duel.scratch, &duel.original }) |pool| {
                    const state = pool.combat();
                    inline for (.{ "max_health", "max_mana", "spell_crit_chance", "armor_damage_reduction" }) |field| {
                        try std.testing.expectApproxEqAbs(fixtureNumber(expected.get(field).?), @field(state, field ++ suffix)[0], 0.001);
                    }
                }
            }
        }
    }
}

test "Warrior item metadata drives hand swings and shields stay out of the offhand attack path" {
    const allocator = std.testing.allocator;
    const fixtures = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("testdata/warrior_equipment.json"), .{});
    defer fixtures.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "warrior.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "warrior.json");
    defer allocator.free(path);
    for (fixtures.value.array.items[0..3]) |fixture| {
        const json = try std.json.stringifyAlloc(allocator, fixture.object.get("input").?, .{});
        defer allocator.free(json);
        try tmp.dir.writeFile(.{ .sub_path = "warrior.json", .data = json });
        const cfg = try spec.loadSpecFile(allocator, path);
        defer allocator.free(cfg.name);
        defer allocator.free(cfg.id);
        var duel = try sim.Duel(.warrior, .warrior).init(allocator);
        defer duel.deinit();
        var attacker = cfg.warrior;
        attacker.white_hit = 1;
        attacker.crit = 0;
        try duel.setWarriorConfig(true, attacker);
        try duel.setWarriorConfig(false, cfg.warrior);
        for (0..16) |lane| duel.arena.resetDuel(lane);
        try duel.setCombatStats(true, cfg.combat_stats);
        var target_stats = cfg.combat_stats;
        // Guaranteed block isolates shield damage reduction from RNG/avoidance.
        target_stats.melee_dodge_chance = 0;
        target_stats.melee_block_chance = if (cfg.warrior.shield) 1 else 0;
        try duel.setCombatStats(false, target_stats);
        const state = duel.arena.combat();
        @memset(state.distance, 3);
        @memset(state.pos_x_a, -1.5);
        @memset(state.pos_x_b, 1.5);
        const hp_before = state.hp_b[0];
        duel.tick(6000);
        try std.testing.expectApproxEqAbs(cfg.warrior.main_hand.speed, duel.arena.warrior.floats(true, .main_swing, 0).*[0], 0.001);
        const ap_bonus = cfg.warrior.attack_power * cfg.warrior.main_hand.speed / 14;
        const block = if (cfg.warrior.shield) cfg.combat_stats.melee_block_value else @as(f32, 0);
        var minimum = cfg.warrior.main_hand.min + ap_bonus - block;
        var maximum = cfg.warrior.main_hand.max + ap_bonus - block;
        if (cfg.warrior.off_hand) |weapon| {
            const off_ap = cfg.warrior.attack_power * weapon.speed / 14;
            minimum += (weapon.min + off_ap) * 0.5;
            maximum += (weapon.max + off_ap) * 0.5;
            try std.testing.expectApproxEqAbs(weapon.speed, duel.arena.warrior.floats(true, .off_swing, 0).*[0], 0.001);
        } else try std.testing.expectEqual(@as(f32, 0), duel.arena.warrior.floats(true, .off_swing, 0).*[0]);
        const damage = duel.arena.warrior.floats(true, .last_damage, 0).*[0];
        try std.testing.expect(damage >= minimum * (1 - cfg.combat_stats.armor_damage_reduction) - 0.001);
        try std.testing.expect(damage <= maximum * (1 - cfg.combat_stats.armor_damage_reduction) + 0.001);
        if (cfg.warrior.shield) {
            try std.testing.expectEqual(@as(f32, 1), duel.arena.warrior.configs[0].target_melee.block);
            try std.testing.expectApproxEqAbs(cfg.combat_stats.melee_block_value, duel.arena.warrior.configs[0].target_melee.block_value, 0.001);
        }
        try std.testing.expectApproxEqAbs(damage, hp_before - state.hp_b[0], 0.001);
        const snapshot = duel.snapshot(0);
        duel.restore(7, snapshot);
        try std.testing.expectEqual(state.max_health_b[0], state.max_health_b[7]);
    }
}
