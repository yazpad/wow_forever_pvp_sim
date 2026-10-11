const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");

const WarlockArenaPool = combat_spec.WarlockArenaPool;
const WarlockAction = combat_spec.WarlockAction;
const WarlockConstants = combat_spec.WarlockConstants;
const PolicyGenome = policy_simd.PolicyGenome;

pub const EventKind = enum(u8) {
    ActionUsed = 0,
    CastStart = 1,
    CastComplete = 2,
    CastInterrupt = 3,
    DamageHit = 4,
    DamageDot = 5,
    Heal = 6,
    FearApplied = 7,
    FearBroken = 8,
    DefensiveActivated = 9,
    DeathCoil = 10,
    HorrorApplied = 11,
};

pub const RecordedEvent = struct {
    time_s: f32,
    source: u8, // 0 = Unit A, 1 = Unit B
    target: u8, // 0 = Unit A, 1 = Unit B
    kind: EventKind,
    spell_id: u32,
    amount: f32,
};

pub const RecordedFrame = struct {
    time_s: f32,
    dist: f32,
    pos_a: f32,
    pos_b: f32,
    hp_a: f32,
    hp_b: f32,
    mana_a: f32,
    mana_b: f32,
    speed_a: f32,
    speed_b: f32,
    cast_id_a: u32,
    cast_id_b: u32,
    cast_timer_a: f32,
    cast_timer_b: f32,
    cast_total_a: f32,
    cast_total_b: f32,
    agony_a: f32,
    agony_b: f32,
    corruption_a: f32,
    corruption_b: f32,
    fear_a: f32,
    fear_b: f32,
    horror_a: f32,
    horror_b: f32,
    unending_dur_a: f32,
    unending_dur_b: f32,
    unending_cd_a: f32,
    unending_cd_b: f32,
    death_coil_cd_a: f32,
    death_coil_cd_b: f32,
    fear_dr_a: f32,
    fear_dr_b: f32,
    fear_dr_timer_a: f32,
    fear_dr_timer_b: f32,
    horror_dr_a: f32,
    horror_dr_b: f32,
    horror_dr_timer_a: f32,
    horror_dr_timer_b: f32,
    action_a: u32,
    action_b: u32,
};

pub const MatchTrajectory = struct {
    allocator: mem.Allocator,
    name_a: []const u8,
    name_b: []const u8,
    elo_a: f32,
    elo_b: f32,
    victor: u8, // 0 = A, 1 = B, 2 = Draw
    total_time_s: f32,
    total_dmg_a: f32,
    total_dmg_b: f32,
    total_heal_a: f32,
    total_heal_b: f32,
    frames: std.ArrayList(RecordedFrame),
    events: std.ArrayList(RecordedEvent),

    pub fn init(allocator: mem.Allocator, name_a: []const u8, name_b: []const u8, elo_a: f32, elo_b: f32) !MatchTrajectory {
        const owned_name_a = try allocator.dupe(u8, name_a);
        errdefer allocator.free(owned_name_a);
        const owned_name_b = try allocator.dupe(u8, name_b);
        errdefer allocator.free(owned_name_b);

        return MatchTrajectory{
            .allocator = allocator,
            .name_a = owned_name_a,
            .name_b = owned_name_b,
            .elo_a = elo_a,
            .elo_b = elo_b,
            .victor = 2,
            .total_time_s = 0.0,
            .total_dmg_a = 0.0,
            .total_dmg_b = 0.0,
            .total_heal_a = 0.0,
            .total_heal_b = 0.0,
            .frames = std.ArrayList(RecordedFrame).init(allocator),
            .events = std.ArrayList(RecordedEvent).init(allocator),
        };
    }

    pub fn deinit(self: *MatchTrajectory) void {
        self.allocator.free(self.name_a);
        self.allocator.free(self.name_b);
        self.frames.deinit();
        self.events.deinit();
    }

    pub fn exportJson(self: *const MatchTrajectory, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        var buf_writer = std.io.bufferedWriter(file.writer());
        const writer = buf_writer.writer();

        try writer.print("{{\n  \"meta\": {{\n", .{});
        try writer.print("    \"name_a\": \"{s}\", \"elo_a\": {d:0.1},\n", .{ self.name_a, self.elo_a });
        try writer.print("    \"name_b\": \"{s}\", \"elo_b\": {d:0.1},\n", .{ self.name_b, self.elo_b });
        try writer.print("    \"victor\": {d}, \"total_time\": {d:0.3},\n", .{ self.victor, self.total_time_s });
        try writer.print("    \"dmg_a\": {d:0.1}, \"dmg_b\": {d:0.1},\n", .{ self.total_dmg_a, self.total_dmg_b });
        try writer.print("    \"heal_a\": {d:0.1}, \"heal_b\": {d:0.1}\n  }},\n", .{ self.total_heal_a, self.total_heal_b });

        try writer.print("  \"events\": [\n", .{});
        for (self.events.items, 0..) |ev, idx| {
            try writer.print("    {{\"t\": {d:0.3}, \"src\": {d}, \"tgt\": {d}, \"kind\": {d}, \"spell\": {d}, \"amt\": {d:0.1}}}{s}\n", .{
                ev.time_s, ev.source, ev.target, @intFromEnum(ev.kind), ev.spell_id, ev.amount,
                if (idx + 1 < self.events.items.len) "," else "",
            });
        }
        try writer.print("  ],\n  \"frames\": [\n", .{});

        for (self.frames.items, 0..) |f, idx| {
            try writer.print("    [{d:0.3},{d:0.2},{d:0.2},{d:0.2},{d:0.1},{d:0.1},{d:0.1},{d:0.1},{d:0.2},{d:0.2},{d},{d},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2}", .{
                f.time_s, f.dist, f.pos_a, f.pos_b,
                f.hp_a, f.hp_b, f.mana_a, f.mana_b,
                f.speed_a, f.speed_b,
                f.cast_id_a, f.cast_id_b, f.cast_timer_a, f.cast_timer_b, f.cast_total_a, f.cast_total_b,
                f.agony_a, f.agony_b, f.corruption_a, f.corruption_b,
            });
            try writer.print(",{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d},{d}]{s}\n", .{
                f.fear_a, f.fear_b, f.horror_a, f.horror_b,
                f.unending_dur_a, f.unending_dur_b, f.unending_cd_a, f.unending_cd_b,
                f.death_coil_cd_a, f.death_coil_cd_b,
                f.fear_dr_a, f.fear_dr_b, f.fear_dr_timer_a, f.fear_dr_timer_b,
                f.horror_dr_a, f.horror_dr_b, f.horror_dr_timer_a, f.horror_dr_timer_b,
                f.action_a, f.action_b,
                if (idx + 1 < self.frames.items.len) "," else "",
            });
        }
        try writer.print("  ]\n}}\n", .{});
        try buf_writer.flush();
    }

    pub fn exportLua(self: *const MatchTrajectory, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        var buf_writer = std.io.bufferedWriter(file.writer());
        const writer = buf_writer.writer();

        try writer.print("return {{\n  meta = {{\n", .{});
        try writer.print("    name_a = \"{s}\", elo_a = {d:0.1},\n", .{ self.name_a, self.elo_a });
        try writer.print("    name_b = \"{s}\", elo_b = {d:0.1},\n", .{ self.name_b, self.elo_b });
        try writer.print("    victor = {d}, total_time = {d:0.3},\n", .{ self.victor, self.total_time_s });
        try writer.print("    dmg_a = {d:0.1}, dmg_b = {d:0.1},\n", .{ self.total_dmg_a, self.total_dmg_b });
        try writer.print("    heal_a = {d:0.1}, heal_b = {d:0.1}\n  }},\n", .{ self.total_heal_a, self.total_heal_b });

        try writer.print("  events = {{\n", .{});
        for (self.events.items) |ev| {
            try writer.print("    {{ t = {d:0.3}, s = {d}, tg = {d}, k = {d}, sp = {d}, a = {d:0.1} }},\n", .{
                ev.time_s, ev.source, ev.target, @intFromEnum(ev.kind), ev.spell_id, ev.amount,
            });
        }
        try writer.print("  }},\n  frames = {{\n", .{});

        for (self.frames.items) |f| {
            try writer.print("    {{ {d:0.3},{d:0.2},{d:0.2},{d:0.2},{d:0.1},{d:0.1},{d:0.1},{d:0.1},{d:0.2},{d:0.2},{d},{d},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2}", .{
                f.time_s, f.dist, f.pos_a, f.pos_b,
                f.hp_a, f.hp_b, f.mana_a, f.mana_b,
                f.speed_a, f.speed_b,
                f.cast_id_a, f.cast_id_b, f.cast_timer_a, f.cast_timer_b, f.cast_total_a, f.cast_total_b,
                f.agony_a, f.agony_b, f.corruption_a, f.corruption_b,
            });
            try writer.print(",{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d},{d} }},\n", .{
                f.fear_a, f.fear_b, f.horror_a, f.horror_b,
                f.unending_dur_a, f.unending_dur_b, f.unending_cd_a, f.unending_cd_b,
                f.death_coil_cd_a, f.death_coil_cd_b,
                f.fear_dr_a, f.fear_dr_b, f.fear_dr_timer_a, f.fear_dr_timer_b,
                f.horror_dr_a, f.horror_dr_b, f.horror_dr_timer_a, f.horror_dr_timer_b,
                f.action_a, f.action_b,
            });
        }
        try writer.print("  }}\n}}\n", .{});
        try buf_writer.flush();
    }
};

/// High-fidelity Duel Recorder
pub const MatchRecorder = struct {
    pub fn recordDuel(
        allocator: mem.Allocator,
        p_a: *const PolicyGenome,
        p_b: *const PolicyGenome,
        name_a: []const u8,
        name_b: []const u8,
        max_seconds: f32,
        dt: f32,
    ) !MatchTrajectory {
        var arena = try WarlockArenaPool.init(allocator, 16);
        defer arena.deinit();

        arena.resetDuel(0);

        var traj = try MatchTrajectory.init(allocator, name_a, name_b, p_a.elo, p_b.elo);
        errdefer traj.deinit();

        const max_ticks: usize = @intFromFloat(max_seconds / dt);
        var elapsed_ticks: usize = 0;

        // Starting arena positions along 1D line:
        // Center = 0m, initial distance = 25m, so Unit A starts at -12.5m, Unit B starts at +12.5m
        var pos_a: f32 = -12.5;
        var pos_b: f32 = 12.5;

        var last_act_a: u32 = 0;
        var last_act_b: u32 = 0;

        // Track previous state for event detection
        var prev_hp_a = arena.hp_a[0];
        var prev_hp_b = arena.hp_b[0];
        var prev_cid_a: u32 = arena.cast_id_a[0];
        var prev_cid_b: u32 = arena.cast_id_b[0];
        var prev_ctmr_a: f32 = arena.cast_timer_a[0];
        var prev_ctmr_b: f32 = arena.cast_timer_b[0];
        var prev_fear_a = arena.fear_timer_a[0];
        var prev_fear_b = arena.fear_timer_b[0];
        var prev_horror_a = arena.horror_timer_a[0];
        var prev_horror_b = arena.horror_timer_b[0];
        var prev_un_a = arena.unending_dur_a[0];
        var prev_un_b = arena.unending_dur_b[0];

        // Periodic event accumulators
        var accum_dot_to_a: f32 = 0.0;
        var accum_dot_to_b: f32 = 0.0;
        var last_dot_time_a: f32 = 0.0;
        var last_dot_time_b: f32 = 0.0;

        var accum_drain_dmg_a: f32 = 0.0;
        var accum_drain_dmg_b: f32 = 0.0;
        var accum_drain_heal_a: f32 = 0.0;
        var accum_drain_heal_b: f32 = 0.0;
        var last_drain_time_a: f32 = 0.0;
        var last_drain_time_b: f32 = 0.0;

        while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
            const cur_hp_a = arena.hp_a[0];
            const cur_hp_b = arena.hp_b[0];
            if (cur_hp_a <= 0.0 or cur_hp_b <= 0.0) break;

            const time_s = @as(f32, @floatFromInt(elapsed_ticks)) * dt;

            // 1. Policy Decision for A
            const dec_a = arena.needsDecisionA(0);
            var act_a_triggered = false;
            if (dec_a[0]) {
                const obs_a = arena.getObservationsA(0);
                const masks_a = arena.getActionMaskA(0);
                const out_a = p_a.forward16(obs_a, masks_a);
                last_act_a = out_a.actions[0];
                act_a_triggered = true;
                arena.applyActionA(0, out_a.actions, out_a.move_intents);

                if (last_act_a != 0) {
                    const is_dc = (last_act_a == @intFromEnum(WarlockAction.DeathCoil));
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 0,
                        .target = 1,
                        .kind = if (is_dc) .DeathCoil else .ActionUsed,
                        .spell_id = last_act_a,
                        .amount = if (is_dc) WarlockConstants.DeathCoilDamage else 0.0,
                    });
                }
            }

            // 2. Policy Decision for B
            const dec_b = arena.needsDecisionB(0);
            var act_b_triggered = false;
            if (dec_b[0]) {
                const obs_b = arena.getObservationsB(0);
                const masks_b = arena.getActionMaskB(0);
                const out_b = p_b.forward16(obs_b, masks_b);
                last_act_b = out_b.actions[0];
                act_b_triggered = true;
                arena.applyActionB(0, out_b.actions, out_b.move_intents);

                if (last_act_b != 0) {
                    const is_dc = (last_act_b == @intFromEnum(WarlockAction.DeathCoil));
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 1,
                        .target = 0,
                        .kind = if (is_dc) .DeathCoil else .ActionUsed,
                        .spell_id = last_act_b,
                        .amount = if (is_dc) WarlockConstants.DeathCoilDamage else 0.0,
                    });
                }
            }

            // Pre-tick cast IDs
            const pre_c_a = arena.cast_id_a[0];
            const pre_c_b = arena.cast_id_b[0];
            prev_ctmr_a = arena.cast_timer_a[0];
            prev_ctmr_b = arena.cast_timer_b[0];

            // 3. Step Physics (100 Hz / 10ms)
            _ = arena.tickPhysics(dt);

            // Post-tick state
            const post_hp_a = arena.hp_a[0];
            const post_hp_b = arena.hp_b[0];
            const post_c_a = arena.cast_id_a[0];
            const post_c_b = arena.cast_id_b[0];
            const post_fear_a = arena.fear_timer_a[0];
            const post_fear_b = arena.fear_timer_b[0];
            const post_horror_a = arena.horror_timer_a[0];
            const post_horror_b = arena.horror_timer_b[0];
            const post_un_a = arena.unending_dur_a[0];
            const post_un_b = arena.unending_dur_b[0];

            // Update spatial positions
            const move_intent_a = arena.move_intent_a[0];
            const move_intent_b = arena.move_intent_b[0];

            var spd_a: f32 = 0.0;
            if (move_intent_a < 0.0) spd_a = WarlockConstants.ForwardSpeed else if (move_intent_a > 0.0) spd_a = -WarlockConstants.BackpedalSpeed;
            if (post_fear_a > 0.0 or post_horror_a > 0.0) spd_a = -WarlockConstants.ForwardSpeed;

            var spd_b: f32 = 0.0;
            if (move_intent_b < 0.0) spd_b = -WarlockConstants.ForwardSpeed else if (move_intent_b > 0.0) spd_b = WarlockConstants.BackpedalSpeed;
            if (post_fear_b > 0.0 or post_horror_b > 0.0) spd_b = WarlockConstants.ForwardSpeed;

            pos_a = std.math.clamp(pos_a + spd_a * dt, -17.5, 17.5);
            pos_b = std.math.clamp(pos_b + spd_b * dt, -17.5, 17.5);

            // Enforce minimum distance
            if (pos_b - pos_a < WarlockConstants.MinDistance) {
                const center = (pos_a + pos_b) * 0.5;
                pos_a = center - WarlockConstants.MinDistance * 0.5;
                pos_b = center + WarlockConstants.MinDistance * 0.5;
            }

            // 4. Detect Events
            // Cast start for A
            if (prev_cid_a == 0 and pre_c_a != 0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 1,
                    .kind = .CastStart,
                    .spell_id = pre_c_a,
                    .amount = arena.cast_total_a[0],
                });
            }
            // Cast completed for A
            if (pre_c_a != 0 and post_c_a == 0 and prev_ctmr_a <= dt * 1.5) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 1,
                    .kind = .CastComplete,
                    .spell_id = pre_c_a,
                    .amount = 0.0,
                });
            } else if (pre_c_a != 0 and post_c_a == 0 and prev_ctmr_a > dt * 1.5) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 1,
                    .kind = .CastInterrupt,
                    .spell_id = pre_c_a,
                    .amount = 0.0,
                });
            }

            // Cast start for B
            if (prev_cid_b == 0 and pre_c_b != 0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 0,
                    .kind = .CastStart,
                    .spell_id = pre_c_b,
                    .amount = arena.cast_total_b[0],
                });
            }
            // Cast completed for B
            if (pre_c_b != 0 and post_c_b == 0 and prev_ctmr_b <= dt * 1.5) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 0,
                    .kind = .CastComplete,
                    .spell_id = pre_c_b,
                    .amount = 0.0,
                });
            } else if (pre_c_b != 0 and post_c_b == 0 and prev_ctmr_b > dt * 1.5) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 0,
                    .kind = .CastInterrupt,
                    .spell_id = pre_c_b,
                    .amount = 0.0,
                });
            }

            // Damage to A (dealt by B)
            if (prev_hp_a > post_hp_a) {
                const dmg = prev_hp_a - post_hp_a;
                traj.total_dmg_b += dmg;

                if (pre_c_b == 4 and post_c_b == 0 and prev_ctmr_b <= dt * 1.5) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 1,
                        .target = 0,
                        .kind = .DamageHit,
                        .spell_id = 4,
                        .amount = dmg,
                    });
                } else if (pre_c_b == 5) {
                    accum_drain_dmg_a += dmg;
                    if (time_s - last_drain_time_b >= 0.50 and accum_drain_dmg_a > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 1,
                            .target = 0,
                            .kind = .DamageDot,
                            .spell_id = 5,
                            .amount = accum_drain_dmg_a,
                        });
                        accum_drain_dmg_a = 0.0;
                        last_drain_time_b = time_s;
                    }
                } else if (act_b_triggered and last_act_b == @intFromEnum(WarlockAction.DeathCoil)) {
                    // Direct damage from Death Coil
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 1,
                        .target = 0,
                        .kind = .DamageHit,
                        .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                        .amount = dmg,
                    });
                } else {
                    accum_dot_to_a += dmg;
                    if (time_s - last_dot_time_a >= 1.0 and accum_dot_to_a > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 1,
                            .target = 0,
                            .kind = .DamageDot,
                            .spell_id = 1,
                            .amount = accum_dot_to_a,
                        });
                        accum_dot_to_a = 0.0;
                        last_dot_time_a = time_s;
                    }
                }
            }

            // Damage to B (dealt by A)
            if (prev_hp_b > post_hp_b) {
                const dmg = prev_hp_b - post_hp_b;
                traj.total_dmg_a += dmg;

                if (pre_c_a == 4 and post_c_a == 0 and prev_ctmr_a <= dt * 1.5) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 0,
                        .target = 1,
                        .kind = .DamageHit,
                        .spell_id = 4,
                        .amount = dmg,
                    });
                } else if (pre_c_a == 5) {
                    accum_drain_dmg_b += dmg;
                    if (time_s - last_drain_time_a >= 0.50 and accum_drain_dmg_b > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 0,
                            .target = 1,
                            .kind = .DamageDot,
                            .spell_id = 5,
                            .amount = accum_drain_dmg_b,
                        });
                        accum_drain_dmg_b = 0.0;
                        last_drain_time_a = time_s;
                    }
                } else if (act_a_triggered and last_act_a == @intFromEnum(WarlockAction.DeathCoil)) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 0,
                        .target = 1,
                        .kind = .DamageHit,
                        .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                        .amount = dmg,
                    });
                } else {
                    accum_dot_to_b += dmg;
                    if (time_s - last_dot_time_b >= 1.0 and accum_dot_to_b > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 0,
                            .target = 1,
                            .kind = .DamageDot,
                            .spell_id = 1,
                            .amount = accum_dot_to_b,
                        });
                        accum_dot_to_b = 0.0;
                        last_dot_time_b = time_s;
                    }
                }
            }

            // Heals to A (Drain Life / Death Coil)
            if (post_hp_a > prev_hp_a) {
                const heal = post_hp_a - prev_hp_a;
                traj.total_heal_a += heal;
                if (act_a_triggered and last_act_a == @intFromEnum(WarlockAction.DeathCoil)) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 0,
                        .target = 0,
                        .kind = .Heal,
                        .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                        .amount = heal,
                    });
                } else {
                    accum_drain_heal_a += heal;
                    if (time_s - last_drain_time_a >= 0.50 and accum_drain_heal_a > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 0,
                            .target = 0,
                            .kind = .Heal,
                            .spell_id = 5,
                            .amount = accum_drain_heal_a,
                        });
                        accum_drain_heal_a = 0.0;
                    }
                }
            }

            // Heals to B (Drain Life / Death Coil)
            if (post_hp_b > prev_hp_b) {
                const heal = post_hp_b - prev_hp_b;
                traj.total_heal_b += heal;
                if (act_b_triggered and last_act_b == @intFromEnum(WarlockAction.DeathCoil)) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 1,
                        .target = 1,
                        .kind = .Heal,
                        .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                        .amount = heal,
                    });
                } else {
                    accum_drain_heal_b += heal;
                    if (time_s - last_drain_time_b >= 0.50 and accum_drain_heal_b > 1.0) {
                        try traj.events.append(.{
                            .time_s = time_s,
                            .source = 1,
                            .target = 1,
                            .kind = .Heal,
                            .spell_id = 5,
                            .amount = accum_drain_heal_b,
                        });
                        accum_drain_heal_b = 0.0;
                    }
                }
            }

            // Fear / Horror A applied
            if (prev_fear_a == 0.0 and post_fear_a > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 0,
                    .kind = .FearApplied,
                    .spell_id = 3,
                    .amount = post_fear_a,
                });
            }
            if (prev_horror_a == 0.0 and post_horror_a > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 0,
                    .kind = .HorrorApplied,
                    .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                    .amount = post_horror_a,
                });
            }

            // Fear / Horror B applied
            if (prev_fear_b == 0.0 and post_fear_b > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 1,
                    .kind = .FearApplied,
                    .spell_id = 3,
                    .amount = post_fear_b,
                });
            }
            if (prev_horror_b == 0.0 and post_horror_b > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 1,
                    .kind = .HorrorApplied,
                    .spell_id = @intFromEnum(WarlockAction.DeathCoil),
                    .amount = post_horror_b,
                });
            }

            // Defensive A
            if (prev_un_a == 0.0 and post_un_a > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 0,
                    .target = 0,
                    .kind = .DefensiveActivated,
                    .spell_id = 6,
                    .amount = post_un_a,
                });
            }

            // Defensive B
            if (prev_un_b == 0.0 and post_un_b > 0.0) {
                try traj.events.append(.{
                    .time_s = time_s,
                    .source = 1,
                    .target = 1,
                    .kind = .DefensiveActivated,
                    .spell_id = 6,
                    .amount = post_un_b,
                });
            }

            // 5. Append Recorded Frame
            try traj.frames.append(.{
                .time_s = time_s,
                .dist = arena.distance[0],
                .pos_a = pos_a,
                .pos_b = pos_b,
                .hp_a = post_hp_a,
                .hp_b = post_hp_b,
                .mana_a = arena.mana_a[0],
                .mana_b = arena.mana_b[0],
                .speed_a = spd_a,
                .speed_b = spd_b,
                .cast_id_a = post_c_a,
                .cast_id_b = post_c_b,
                .cast_timer_a = arena.cast_timer_a[0],
                .cast_timer_b = arena.cast_timer_b[0],
                .cast_total_a = arena.cast_total_a[0],
                .cast_total_b = arena.cast_total_b[0],
                .agony_a = arena.agony_timer_a[0],
                .agony_b = arena.agony_timer_b[0],
                .corruption_a = arena.corruption_timer_a[0],
                .corruption_b = arena.corruption_timer_b[0],
                .fear_a = post_fear_a,
                .fear_b = post_fear_b,
                .horror_a = post_horror_a,
                .horror_b = post_horror_b,
                .unending_dur_a = post_un_a,
                .unending_dur_b = post_un_b,
                .unending_cd_a = arena.unending_cd_a[0],
                .unending_cd_b = arena.unending_cd_b[0],
                .death_coil_cd_a = arena.death_coil_cd_a[0],
                .death_coil_cd_b = arena.death_coil_cd_b[0],
                .fear_dr_a = arena.fear_dr_tier_a[0],
                .fear_dr_b = arena.fear_dr_tier_b[0],
                .fear_dr_timer_a = arena.fear_dr_timer_a[0],
                .fear_dr_timer_b = arena.fear_dr_timer_b[0],
                .horror_dr_a = arena.horror_dr_tier_a[0],
                .horror_dr_b = arena.horror_dr_tier_b[0],
                .horror_dr_timer_a = arena.horror_dr_timer_a[0],
                .horror_dr_timer_b = arena.horror_dr_timer_b[0],
                .action_a = if (act_a_triggered) last_act_a else 0,
                .action_b = if (act_b_triggered) last_act_b else 0,
            });

            // Update prev vars
            prev_hp_a = post_hp_a;
            prev_hp_b = post_hp_b;
            prev_cid_a = post_c_a;
            prev_cid_b = post_c_b;
            prev_fear_a = post_fear_a;
            prev_fear_b = post_fear_b;
            prev_horror_a = post_horror_a;
            prev_horror_b = post_horror_b;
            prev_un_a = post_un_a;
            prev_un_b = post_un_b;
        }

        traj.total_time_s = @as(f32, @floatFromInt(elapsed_ticks)) * dt;
        if (arena.hp_a[0] > 0.0 and arena.hp_b[0] <= 0.0) {
            traj.victor = 0; // A wins
        } else if (arena.hp_b[0] > 0.0 and arena.hp_a[0] <= 0.0) {
            traj.victor = 1; // B wins
        } else {
            traj.victor = 2; // Draw
        }

        return traj;
    }
};

test "MatchRecorder produces valid trajectory" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1234);
    const rand = prng.random();

    const g_a = PolicyGenome.initRandom(rand);
    const g_b = PolicyGenome.initRandom(rand);

    var traj = try MatchRecorder.recordDuel(allocator, &g_a, &g_b, "Champion A", "Champion B", 5.0, 0.010);
    defer traj.deinit();

    try std.testing.expect(traj.frames.items.len > 0);
    try std.testing.expect(traj.frames.items.len <= 501);
    try std.testing.expect(traj.total_time_s > 0.0);

    // Test JSON export
    const json_path = "tmp_test_match.json";
    try traj.exportJson(json_path);
    defer std.fs.cwd().deleteFile(json_path) catch {};

    // Test Lua export
    const lua_path = "tmp_test_match.lua";
    try traj.exportLua(lua_path);
    defer std.fs.cwd().deleteFile(lua_path) catch {};
}
