const std = @import("std");
const mem = std.mem;
const policy_simd = @import("policy_simd.zig");

pub const ACTION_COUNT: usize = policy_simd.ACTION_DIM; // 9
const action_names = [_][]const u8{
    "Idle", "Agony", "Corruption", "Fear", "Shadow Bolt", "Drain Life", "Unending Resolve", "Death Coil", "Cancel Cast",
};

test "JSON telemetry exports empty history and preserves generation metrics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "metrics.json" });
    defer allocator.free(path);

    var logger = TrainingLogger.init(allocator);
    defer logger.deinit();
    try logger.exportJson(path);
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "metrics.json", 4096);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("total_generations").?.integer);
        try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("generations").?.array.items.len);
    }
    const metrics: GenerationMetrics = .{
        .generation = 7,
        .duration_ms = 12.5,
        .elo_min = 900,
        .elo_mean = 1100,
        .elo_median = 1050,
        .elo_max = 1400,
        .elo_stddev = 125,
        .match_duration_mean_seconds = 12.5,
        .match_duration_bins = .{ 1, 2, 3, 4, 5 },
        .fitness_best = 8,
        .fitness_mean = 3,
        .wins = 5,
        .losses = 2,
        .draws = 1,
        .total_duels = 8,
        .action_counts = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .move_advance_count = 4,
        .move_stand_count = 2,
        .move_kite_count = 9,
        .has_gauntlet = true,
        .gauntlet_win_rate = 0.625,
        .gauntlet_objective_elo = 1500,
    };
    try logger.record(metrics);
    try logger.record(metrics);
    try logger.exportJson(path);
    const bytes = try tmp.dir.readFileAlloc(allocator, "metrics.json", 8192);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), root.get("total_generations").?.integer);
    const names = root.get("action_names").?.array.items;
    try std.testing.expectEqual(ACTION_COUNT, names.len);
    for (names, action_names) |name, expected| try std.testing.expectEqualStrings(expected, name.string);
    const generations = root.get("generations").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), generations.len);
    for (generations) |generation| {
        const fields = generation.object;
        inline for (.{ "generation", "duration_ms", "elo_min", "elo_mean", "elo_median", "elo_max", "elo_stddev", "match_duration_mean_seconds", "fitness_best", "fitness_mean", "wins", "losses", "draws", "total_duels", "gauntlet_win_rate", "gauntlet_objective_elo" }) |key| {
            const value = fields.get(key).?;
            const number: f64 = switch (value) {
                .integer => |n| @floatFromInt(n),
                .float => |n| n,
                else => return error.UnexpectedJsonType,
            };
            try std.testing.expectEqual(@as(f64, @field(metrics, key)), number);
        }
        try std.testing.expect(fields.get("has_gauntlet").?.bool);
        for (fields.get("action_counts").?.array.items, metrics.action_counts) |count, expected| {
            try std.testing.expectEqual(@as(i64, @intCast(expected)), count.integer);
        }
        const bins = fields.get("match_duration_bins").?.array.items;
        for (bins, metrics.match_duration_bins) |bin, expected| try std.testing.expectEqual(@as(i64, @intCast(expected)), bin.integer);
        const movement = fields.get("movement").?.object;
        try std.testing.expectEqual(@as(i64, 4), movement.get("advance").?.integer);
        try std.testing.expectEqual(@as(i64, 2), movement.get("stand").?.integer);
        try std.testing.expectEqual(@as(i64, 9), movement.get("kite").?.integer);
    }
}

pub const GenerationMetrics = struct {
    generation: usize,
    duration_ms: f64,
    elo_min: f32,
    elo_mean: f32,
    elo_median: f32,
    elo_max: f32,
    elo_stddev: f32 = 0,
    match_duration_mean_seconds: f64 = 0,
    match_duration_bins: [5]usize = [_]usize{0} ** 5,
    fitness_best: f32,
    fitness_mean: f32,
    wins: usize,
    losses: usize,
    draws: usize,
    total_duels: usize,
    // Action frequencies (% of total action decisions in champion evaluation/duels)
    action_counts: [ACTION_COUNT]usize = [_]usize{0} ** ACTION_COUNT,
    move_advance_count: usize = 0,
    move_stand_count: usize = 0,
    move_kite_count: usize = 0,
    // Gauntlet objective benchmark snapshot (if evaluated this generation)
    has_gauntlet: bool = false,
    gauntlet_win_rate: f32 = 0.0,
    gauntlet_objective_elo: f32 = 0.0,
};

pub const TrainingLogger = struct {
    allocator: mem.Allocator,
    history: std.ArrayList(GenerationMetrics),

    pub fn init(allocator: mem.Allocator) TrainingLogger {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(GenerationMetrics).init(allocator),
        };
    }

    pub fn deinit(self: *TrainingLogger) void {
        self.history.deinit();
    }

    pub fn record(self: *TrainingLogger, metrics: GenerationMetrics) !void {
        try self.history.append(metrics);
    }

    /// JSON uses zero-based action IDs as array offsets; Lua uses explicit IDs.
    pub fn exportJson(self: *const TrainingLogger, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        var buffered = std.io.bufferedWriter(file.writer());
        const w = buffered.writer();
        try w.print("{{\"total_generations\":{d},\"action_names\":", .{self.history.items.len});
        try std.json.stringify(action_names, .{}, w);
        try w.writeAll(",\"outcome_scope\":\"initiating_agent\",\"generations\":[");
        for (self.history.items, 0..) |m, i| {
            if (i != 0) try w.writeByte(',');
            try std.json.stringify(.{
                .generation = m.generation,
                .duration_ms = m.duration_ms,
                .elo_min = m.elo_min,
                .elo_mean = m.elo_mean,
                .elo_median = m.elo_median,
                .elo_max = m.elo_max,
                .elo_stddev = m.elo_stddev,
                .match_duration_mean_seconds = m.match_duration_mean_seconds,
                .match_duration_bins = m.match_duration_bins,
                .fitness_best = m.fitness_best,
                .fitness_mean = m.fitness_mean,
                .wins = m.wins,
                .losses = m.losses,
                .draws = m.draws,
                .total_duels = m.total_duels,
                .action_counts = m.action_counts,
                .movement = .{ .advance = m.move_advance_count, .stand = m.move_stand_count, .kite = m.move_kite_count },
                .has_gauntlet = m.has_gauntlet,
                .gauntlet_win_rate = m.gauntlet_win_rate,
                .gauntlet_objective_elo = m.gauntlet_objective_elo,
            }, .{}, w);
        }
        try w.writeAll("]}\n");
        try buffered.flush();
    }

    /// Export metrics to high-performance native Lua table format for Love2D
    pub fn exportLua(self: *const TrainingLogger, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        var buf_writer = std.io.bufferedWriter(file.writer());
        const w = buf_writer.writer();

        try w.writeAll("return {\n  outcome_scope = \"initiating_agent\",\n");
        try w.print("  total_generations = {d},\n", .{self.history.items.len});
        try w.writeAll("  action_names = {\n");
        for (action_names, 0..) |name, idx| {
            try w.print("    [{d}] = \"{s}\",\n", .{ idx, name });
        }
        try w.writeAll("  },\n");

        try w.writeAll("  generations = {\n");
        for (self.history.items) |m| {
            try w.writeAll("    {\n");
            try w.print("      generation = {d},\n", .{m.generation});
            try w.print("      duration_ms = {d:0.2},\n", .{m.duration_ms});
            try w.print("      elo_min = {d:0.1},\n", .{m.elo_min});
            try w.print("      elo_mean = {d:0.1},\n", .{m.elo_mean});
            try w.print("      elo_median = {d:0.1},\n", .{m.elo_median});
            try w.print("      elo_max = {d:0.1},\n", .{m.elo_max});
            try w.print("      elo_stddev = {d:0.1},\n", .{m.elo_stddev});
            try w.print("      fitness_best = {d:0.1},\n", .{m.fitness_best});
            try w.print("      fitness_mean = {d:0.1},\n", .{m.fitness_mean});
            try w.print("      wins = {d}, losses = {d}, draws = {d},\n", .{ m.wins, m.losses, m.draws });
            try w.print("      total_duels = {d},\n", .{m.total_duels});

            try w.print("      match_duration_mean_seconds = {d:0.3},\n", .{m.match_duration_mean_seconds});
            try w.writeAll("      match_duration_bins = { ");
            for (m.match_duration_bins) |count| try w.print("{d}, ", .{count});
            try w.writeAll("},\n");

            // Action counts
            try w.writeAll("      action_counts = { ");
            for (m.action_counts) |cnt| {
                try w.print("{d}, ", .{cnt});
            }
            try w.writeAll("},\n");

            // Movement counts
            try w.print("      movement = {{ advance = {d}, stand = {d}, kite = {d} }},\n", .{ m.move_advance_count, m.move_stand_count, m.move_kite_count });

            // Gauntlet
            try w.print("      has_gauntlet = {s},\n", .{if (m.has_gauntlet) "true" else "false"});
            try w.print("      gauntlet_win_rate = {d:0.4},\n", .{m.gauntlet_win_rate});
            try w.print("      gauntlet_objective_elo = {d:0.1},\n", .{m.gauntlet_objective_elo});

            try w.writeAll("    },\n");
        }
        try w.writeAll("  }\n");
        try w.writeAll("}\n");

        try buf_writer.flush();
    }
};
