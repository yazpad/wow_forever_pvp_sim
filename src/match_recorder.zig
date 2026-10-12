const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");

const WarlockArenaPool = combat_spec.WarlockArenaPool;
const WarlockAction = combat_spec.WarlockAction;
const WarlockConstants = combat_spec.WarlockConstants;
const PolicyGenome = policy_simd.PolicyGenome;
const Spec = @import("spec.zig").Spec;
const multi_spec = @import("multi_spec.zig");

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
    RootApplied = 12,
    Blink = 13,
    Counterspell = 14,
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
    // Appended replay columns: Blink/Nova cooldown, shield, lockout, per side.
    frost: [8]f32 = [_]f32{0} ** 8,
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
    spec_a: Spec = .warlock,
    spec_b: Spec = .warlock,
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
        try writer.print("    \"spec_a\": \"{s}\", \"spec_b\": \"{s}\",\n", .{ @tagName(self.spec_a), @tagName(self.spec_b) });
        try writer.print("    \"name_a\": \"{s}\", \"elo_a\": {d:0.1},\n", .{ self.name_a, self.elo_a });
        try writer.print("    \"name_b\": \"{s}\", \"elo_b\": {d:0.1},\n", .{ self.name_b, self.elo_b });
        try writer.print("    \"victor\": {d}, \"total_time\": {d:0.3},\n", .{ self.victor, self.total_time_s });
        try writer.print("    \"dmg_a\": {d:0.1}, \"dmg_b\": {d:0.1},\n", .{ self.total_dmg_a, self.total_dmg_b });
        try writer.print("    \"heal_a\": {d:0.1}, \"heal_b\": {d:0.1}\n  }},\n", .{ self.total_heal_a, self.total_heal_b });

        try writer.print("  \"events\": [\n", .{});
        for (self.events.items, 0..) |ev, idx| {
            try writer.print("    {{\"t\": {d:0.3}, \"src\": {d}, \"tgt\": {d}, \"kind\": {d}, \"spell\": {d}, \"amt\": {d:0.1}}}{s}\n", .{
                ev.time_s,                                        ev.source, ev.target, @intFromEnum(ev.kind), ev.spell_id, ev.amount,
                if (idx + 1 < self.events.items.len) "," else "",
            });
        }
        try writer.print("  ],\n  \"frames\": [\n", .{});

        for (self.frames.items, 0..) |f, idx| {
            try writer.print("    [{d:0.3},{d:0.2},{d:0.2},{d:0.2},{d:0.1},{d:0.1},{d:0.1},{d:0.1},{d:0.2},{d:0.2},{d},{d},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2}", .{
                f.time_s,       f.dist,         f.pos_a,        f.pos_b,
                f.hp_a,         f.hp_b,         f.mana_a,       f.mana_b,
                f.speed_a,      f.speed_b,      f.cast_id_a,    f.cast_id_b,
                f.cast_timer_a, f.cast_timer_b, f.cast_total_a, f.cast_total_b,
                f.agony_a,      f.agony_b,      f.corruption_a, f.corruption_b,
            });
            try writer.print(",{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d},{d}", .{
                f.fear_a,            f.fear_b,            f.horror_a,      f.horror_b,
                f.unending_dur_a,    f.unending_dur_b,    f.unending_cd_a, f.unending_cd_b,
                f.death_coil_cd_a,   f.death_coil_cd_b,   f.fear_dr_a,     f.fear_dr_b,
                f.fear_dr_timer_a,   f.fear_dr_timer_b,   f.horror_dr_a,   f.horror_dr_b,
                f.horror_dr_timer_a, f.horror_dr_timer_b, f.action_a,      f.action_b,
            });
            for (f.frost) |value| try writer.print(",{d:0.3}", .{value});
            try writer.print("]{s}\n", .{if (idx + 1 < self.frames.items.len) "," else ""});
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
        try writer.print("    spec_a = \"{s}\", spec_b = \"{s}\",\n", .{ @tagName(self.spec_a), @tagName(self.spec_b) });
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
                f.time_s,       f.dist,         f.pos_a,        f.pos_b,
                f.hp_a,         f.hp_b,         f.mana_a,       f.mana_b,
                f.speed_a,      f.speed_b,      f.cast_id_a,    f.cast_id_b,
                f.cast_timer_a, f.cast_timer_b, f.cast_total_a, f.cast_total_b,
                f.agony_a,      f.agony_b,      f.corruption_a, f.corruption_b,
            });
            try writer.print(",{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d:0.2},{d},{d}", .{
                f.fear_a,            f.fear_b,            f.horror_a,      f.horror_b,
                f.unending_dur_a,    f.unending_dur_b,    f.unending_cd_a, f.unending_cd_b,
                f.death_coil_cd_a,   f.death_coil_cd_b,   f.fear_dr_a,     f.fear_dr_b,
                f.fear_dr_timer_a,   f.fear_dr_timer_b,   f.horror_dr_a,   f.horror_dr_b,
                f.horror_dr_timer_a, f.horror_dr_timer_b, f.action_a,      f.action_b,
            });
            for (f.frost) |value| try writer.print(",{d:0.3}", .{value});
            try writer.writeAll(" },\n");
        }
        try writer.print("  }}\n}}\n", .{});
        try buf_writer.flush();
    }
};

/// High-fidelity Duel Recorder
pub const MatchRecorder = struct {
    fn recordedSpeed(comptime side_a: bool, comptime source_class: Spec, state: *const WarlockArenaPool, dt: f32) f32 {
        const suffix = if (side_a) "_a" else "_b";
        const move = @field(state, "move_intent" ++ suffix)[0];
        var speed: f32 = if (move < 0) -WarlockConstants.ForwardSpeed else if (move > 0) WarlockConstants.BackpedalSpeed else 0;
        if (@field(state, "fear_timer" ++ suffix)[0] > dt or @field(state, "horror_timer" ++ suffix)[0] > dt)
            speed = if (source_class == .frost_mage) 0 else WarlockConstants.ForwardSpeed;
        if (source_class == .frost_mage) {
            if (@field(state, "agony_timer" ++ suffix)[0] > 0) speed = 0;
            if (@field(state, "corruption_timer" ++ suffix)[0] > 0) speed *= @import("spec.zig").Frost.SlowMultiplier;
        }
        return if (side_a) -speed else speed;
    }

    /// Evaluation-only recorder shared by every pairing containing a Mage.
    /// B can be a neural policy or a fixed Warlock gauntlet bot.
    pub fn recordPair(comptime a: Spec, comptime b: Spec, allocator: mem.Allocator, p_a: *const PolicyGenome, p_b: anytype, elo_b: f32, name_a: []const u8, name_b: []const u8, max_seconds: f32, dt: f32) !MatchTrajectory {
        if (a == .warlock and b == .warlock) return recordDuel(allocator, p_a, p_b, name_a, name_b, max_seconds, dt);
        var arena = try multi_spec.ArenaPool(a, b).init(allocator, 16);
        defer arena.deinit();
        for (0..16) |lane| arena.resetDuel(lane);
        const state = arena.combat();
        var traj = try MatchTrajectory.init(allocator, name_a, name_b, p_a.elo, elo_b);
        errdefer traj.deinit();
        traj.spec_a = a;
        traj.spec_b = b;
        var pos_a: f32 = -12.5;
        var pos_b: f32 = 12.5;
        const ticks: usize = @intFromFloat(max_seconds / dt);
        for (0..ticks) |tick| {
            if (state.is_active[0] == 0) break;
            const time_s = @as(f32, @floatFromInt(tick + 1)) * dt;
            const old_cast_a = state.cast_id_a[0];
            const old_cast_b = state.cast_id_b[0];
            const old_defensive_a = state.unending_dur_a[0];
            const old_defensive_b = state.unending_dur_b[0];
            const old_hp_a = state.hp_a[0];
            const old_hp_b = state.hp_b[0];
            const old_fear_a = state.fear_timer_a[0];
            const old_fear_b = state.fear_timer_b[0];
            const old_root_a = state.agony_timer_a[0];
            const old_root_b = state.agony_timer_b[0];
            var action_a: u32 = 0;
            var action_b: u32 = 0;
            const distance_before_a = state.distance[0];
            if (arena.needsDecisionA(0)[0]) {
                const out = p_a.forward16(arena.getObservationsA(0), arena.getActionMaskA(0));
                action_a = out.actions[0];
                arena.applyActionA(0, out.actions, out.move_intents);
            }
            pos_a -= state.distance[0] - distance_before_a;
            const distance_before_b = state.distance[0];
            if (arena.needsDecisionB(0)[0]) {
                const out = p_b.forward16(arena.getObservationsB(0), arena.getActionMaskB(0));
                action_b = out.actions[0];
                arena.applyActionB(0, out.actions, out.move_intents);
            }
            pos_b += state.distance[0] - distance_before_b;
            const cast_a = state.cast_id_a[0];
            const cast_b = state.cast_id_b[0];
            const remaining_a = state.cast_timer_a[0];
            const remaining_b = state.cast_timer_b[0];
            const speed_a = recordedSpeed(true, b, state, dt);
            const speed_b = recordedSpeed(false, a, state, dt);
            _ = arena.tickPhysics16(dt, 0);
            const half_distance = state.distance[0] * 0.5;
            const center = std.math.clamp((pos_a + pos_b + (speed_a + speed_b) * dt) * 0.5, -17.5 + half_distance, 17.5 - half_distance);
            pos_a = center - half_distance;
            pos_b = center + half_distance;
            inline for (.{ true, false }) |side| {
                const source: u8 = if (side) 0 else 1;
                const target: u8 = 1 - source;
                const actor = if (side) a else b;
                const action = if (side) action_a else action_b;
                const old_hp = if (side) old_hp_b else old_hp_a;
                const new_hp = if (side) state.hp_b[0] else state.hp_a[0];
                const own_old_hp = if (side) old_hp_a else old_hp_b;
                const own_hp = if (side) state.hp_a[0] else state.hp_b[0];
                const cast = if (side) cast_a else cast_b;
                const old_cast = if (side) old_cast_a else old_cast_b;
                const current_cast = if (side) state.cast_id_a[0] else state.cast_id_b[0];
                const remaining = if (side) remaining_a else remaining_b;
                if (action != 0) {
                    try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = .ActionUsed, .spell_id = action, .amount = 0 });
                    if (actor == .frost_mage and (action == 5 or action == 7))
                        try traj.events.append(.{ .time_s = time_s, .source = source, .target = if (action == 5) source else target, .kind = if (action == 5) .Blink else .Counterspell, .spell_id = action, .amount = 0 });
                }
                if (old_cast != 0 and cast == 0)
                    try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = .CastInterrupt, .spell_id = old_cast, .amount = 0 });
                if (old_cast == 0 and cast != 0)
                    try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = .CastStart, .spell_id = cast, .amount = if (side) state.cast_total_a[0] else state.cast_total_b[0] });
                const old_defensive = if (side) old_defensive_a else old_defensive_b;
                const defensive = if (side) state.unending_dur_a[0] else state.unending_dur_b[0];
                if (defensive > old_defensive) try traj.events.append(.{ .time_s = time_s, .source = source, .target = source, .kind = .DefensiveActivated, .spell_id = 6, .amount = defensive });
                if (cast != 0 and current_cast == 0)
                    try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = if (remaining <= dt) .CastComplete else .CastInterrupt, .spell_id = cast, .amount = 0 });
                const damage = @max(0, old_hp - new_hp);
                if (side) traj.total_dmg_a += damage else traj.total_dmg_b += damage;
                if (damage > 0) try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = if (actor == .frost_mage or (cast == 4 and current_cast == 0) or action == 7) .DamageHit else .DamageDot, .spell_id = if (cast == 4 and current_cast == 0) 4 else if (action != 0) action else 1, .amount = damage });
                const heal = @max(0, own_hp - own_old_hp);
                if (side) traj.total_heal_a += heal else traj.total_heal_b += heal;
                if (heal > 0) try traj.events.append(.{ .time_s = time_s, .source = source, .target = source, .kind = .Heal, .spell_id = if (action == 7) 7 else 5, .amount = heal });
                const fear = if (side) state.fear_timer_b[0] else state.fear_timer_a[0];
                const old_fear = if (side) old_fear_b else old_fear_a;
                if (fear > old_fear) try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = .FearApplied, .spell_id = 3, .amount = fear });
                const root = if (side) state.agony_timer_b[0] else state.agony_timer_a[0];
                const old_root = if (side) old_root_b else old_root_a;
                if (actor == .frost_mage and root > old_root) try traj.events.append(.{ .time_s = time_s, .source = source, .target = target, .kind = .RootApplied, .spell_id = 2, .amount = root });
            }
            const fa = arena.frostTelemetry(true, 0);
            const fb = arena.frostTelemetry(false, 0);
            try traj.frames.append(.{
                .frost = .{ fa[0], fb[0], fa[1], fb[1], fa[2], fb[2], fa[3], fb[3] },
                .time_s = time_s,
                .dist = state.distance[0],
                .pos_a = pos_a,
                .pos_b = pos_b,
                .hp_a = state.hp_a[0],
                .hp_b = state.hp_b[0],
                .mana_a = state.mana_a[0],
                .mana_b = state.mana_b[0],
                .speed_a = speed_a,
                .speed_b = speed_b,
                .cast_id_a = state.cast_id_a[0],
                .cast_id_b = state.cast_id_b[0],
                .cast_timer_a = state.cast_timer_a[0],
                .cast_timer_b = state.cast_timer_b[0],
                .cast_total_a = state.cast_total_a[0],
                .cast_total_b = state.cast_total_b[0],
                .agony_a = state.agony_timer_a[0],
                .agony_b = state.agony_timer_b[0],
                .corruption_a = state.corruption_timer_a[0],
                .corruption_b = state.corruption_timer_b[0],
                .fear_a = state.fear_timer_a[0],
                .fear_b = state.fear_timer_b[0],
                .horror_a = state.horror_timer_a[0],
                .horror_b = state.horror_timer_b[0],
                .unending_dur_a = state.unending_dur_a[0],
                .unending_dur_b = state.unending_dur_b[0],
                .unending_cd_a = state.unending_cd_a[0],
                .unending_cd_b = state.unending_cd_b[0],
                .death_coil_cd_a = state.death_coil_cd_a[0],
                .death_coil_cd_b = state.death_coil_cd_b[0],
                .fear_dr_a = state.fear_dr_tier_a[0],
                .fear_dr_b = state.fear_dr_tier_b[0],
                .fear_dr_timer_a = state.fear_dr_timer_a[0],
                .fear_dr_timer_b = state.fear_dr_timer_b[0],
                .horror_dr_a = state.horror_dr_tier_a[0],
                .horror_dr_b = state.horror_dr_tier_b[0],
                .horror_dr_timer_a = state.horror_dr_timer_a[0],
                .horror_dr_timer_b = state.horror_dr_timer_b[0],
                .action_a = action_a,
                .action_b = action_b,
            });
        }
        if (traj.frames.items.len > 0) traj.total_time_s = traj.frames.items[traj.frames.items.len - 1].time_s;
        traj.victor = if (state.hp_b[0] <= 0 and state.hp_a[0] > 0) 0 else if (state.hp_a[0] <= 0 and state.hp_b[0] > 0) 1 else 2;
        return traj;
    }

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

test "Mage recording matches SIMD combat and exports tagged Lua and JSON" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(88);
    const genome = PolicyGenome.initRandom(prng.random());
    inline for (.{ Spec.warlock, Spec.frost_mage }) |opponent| {
        var traj = try MatchRecorder.recordPair(.frost_mage, opponent, allocator, &genome, &genome, genome.elo, "Mage", "Opponent", 3, 0.01);
        defer traj.deinit();
        var arena = try multi_spec.ArenaPool(.frost_mage, opponent).init(allocator, 16);
        defer arena.deinit();
        for (0..16) |lane| arena.resetDuel(lane);
        for (traj.frames.items) |frame| {
            if (arena.needsDecisionA(0)[0]) {
                const out = genome.forward16(arena.getObservationsA(0), arena.getActionMaskA(0));
                arena.applyActionA(0, out.actions, out.move_intents);
            }
            if (arena.needsDecisionB(0)[0]) {
                const out = genome.forward16(arena.getObservationsB(0), arena.getActionMaskB(0));
                arena.applyActionB(0, out.actions, out.move_intents);
            }
            _ = arena.tickPhysics16(0.01, 0);
            try std.testing.expectEqual(arena.combat().hp_a[0], frame.hp_a);
            try std.testing.expectEqual(arena.combat().hp_b[0], frame.hp_b);
            try std.testing.expectEqual(arena.combat().distance[0], frame.dist);
        }
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "match.json" });
        defer allocator.free(path);
        try traj.exportJson(path);
        const bytes = try tmp.dir.readFileAlloc(allocator, "match.json", 1024 * 1024);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("frost_mage", parsed.value.object.get("meta").?.object.get("spec_a").?.string);
        try std.testing.expectEqual(@as(usize, 48), parsed.value.object.get("frames").?.array.items[0].array.items.len);
    }
}
