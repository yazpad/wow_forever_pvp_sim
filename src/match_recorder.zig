const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");

const WarlockArenaPool = combat_spec.WarlockArenaPool;
const WarlockAction = combat_spec.WarlockAction;
const WarlockConstants = combat_spec.WarlockConstants;
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
    ProjectileImpact = 15,
    PetAttack = 16,
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
    projectiles: [32]f32 = @splat(0),
    pets: [10]f32 = @splat(0),
    // Appended aura timers, keeping existing replay frame columns stable.
    siphon_a: f32 = 0,
    siphon_b: f32 = 0,
    immolate_a: f32 = 0,
    immolate_b: f32 = 0,
    // Appended replay columns: Blink/Nova cooldown, shield, lockout, per side.
    frost: [8]f32 = [_]f32{0} ** 8,
    time_s: f32,
    dist: f32,
    pos_y_a: f32 = 0,
    pos_y_b: f32 = 0,
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
    action6_dur_a: f32,
    action6_dur_b: f32,
    action6_cd_a: f32,
    action6_cd_b: f32,
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
                f.action6_dur_a,    f.action6_dur_b,    f.action6_cd_a, f.action6_cd_b,
                f.death_coil_cd_a,   f.death_coil_cd_b,   f.fear_dr_a,     f.fear_dr_b,
                f.fear_dr_timer_a,   f.fear_dr_timer_b,   f.horror_dr_a,   f.horror_dr_b,
                f.horror_dr_timer_a, f.horror_dr_timer_b, f.action_a,      f.action_b,
            });
            for (f.frost) |value| try writer.print(",{d:0.3}", .{value});
            try writer.print(",{d:0.3},{d:0.3}", .{ f.pos_y_a, f.pos_y_b });
            for (f.projectiles) |value| try writer.print(",{d:0.3}", .{value});
            for (f.pets) |value| try writer.print(",{d:0.3}", .{value});
            try writer.print(",{d:0.2},{d:0.2}", .{ f.siphon_a, f.siphon_b });
            try writer.print(",{d:0.2},{d:0.2}", .{ f.immolate_a, f.immolate_b });
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
                f.action6_dur_a,    f.action6_dur_b,    f.action6_cd_a, f.action6_cd_b,
                f.death_coil_cd_a,   f.death_coil_cd_b,   f.fear_dr_a,     f.fear_dr_b,
                f.fear_dr_timer_a,   f.fear_dr_timer_b,   f.horror_dr_a,   f.horror_dr_b,
                f.horror_dr_timer_a, f.horror_dr_timer_b, f.action_a,      f.action_b,
            });
            for (f.frost) |value| try writer.print(",{d:0.3}", .{value});
            try writer.print(",{d:0.3},{d:0.3}", .{ f.pos_y_a, f.pos_y_b });
            for (f.projectiles) |value| try writer.print(",{d:0.3}", .{value});
            for (f.pets) |value| try writer.print(",{d:0.3}", .{value});
            try writer.print(",{d:0.2},{d:0.2}", .{ f.siphon_a, f.siphon_b });
            try writer.print(",{d:0.2},{d:0.2}", .{ f.immolate_a, f.immolate_b });
            try writer.writeAll(" },\n");
        }
        try writer.print("  }}\n}}\n", .{});
        try buf_writer.flush();
    }
};

/// High-fidelity Duel Recorder helpers
pub const MatchRecorder = struct {
    pub fn recordedSpeed(comptime side_a: bool, comptime source_class: Spec, state: *const WarlockArenaPool, dt: f32) f32 {
        const suffix = if (side_a) "_a" else "_b";
        const cast_id = @field(state, "cast_id" ++ suffix)[0];
        // Hard position freeze during stationary hard casts or channels
        if (cast_id > 0 and cast_id <= 5) return 0;
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
};

test "MatchTrajectory json and lua export" {
    const allocator = std.testing.allocator;
    var traj = try MatchTrajectory.init(allocator, "Unit A", "Unit B", 1500.0, 1500.0);
    defer traj.deinit();

    try traj.frames.append(.{
        .time_s = 0.01,
        .dist = 25.0,
        .pos_a = -12.5,
        .pos_b = 12.5,
        .hp_a = 2000.0,
        .hp_b = 2000.0,
        .mana_a = 1000.0,
        .mana_b = 1000.0,
        .speed_a = 0.0,
        .speed_b = 0.0,
        .cast_id_a = 0,
        .cast_id_b = 0,
        .cast_timer_a = 0.0,
        .cast_timer_b = 0.0,
        .cast_total_a = 0.0,
        .cast_total_b = 0.0,
        .agony_a = 0.0,
        .agony_b = 0.0,
        .corruption_a = 0.0,
        .corruption_b = 0.0,
        .fear_a = 0.0,
        .fear_b = 0.0,
        .horror_a = 0.0,
        .horror_b = 0.0,
        .action6_dur_a = 0.0,
        .action6_dur_b = 0.0,
        .action6_cd_a = 0.0,
        .action6_cd_b = 0.0,
        .death_coil_cd_a = 0.0,
        .death_coil_cd_b = 0.0,
        .fear_dr_a = 0.0,
        .fear_dr_b = 0.0,
        .fear_dr_timer_a = 0.0,
        .fear_dr_timer_b = 0.0,
        .horror_dr_a = 0.0,
        .horror_dr_b = 0.0,
        .horror_dr_timer_a = 0.0,
        .horror_dr_timer_b = 0.0,
        .action_a = 0,
        .action_b = 0,
    });

    const json_path = "tmp_test_traj.json";
    try traj.exportJson(json_path);
    defer std.fs.cwd().deleteFile(json_path) catch {};

    const lua_path = "tmp_test_traj.lua";
    try traj.exportLua(lua_path);
    defer std.fs.cwd().deleteFile(lua_path) catch {};
}
