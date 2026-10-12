const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");
const match_recorder = @import("match_recorder.zig");
const gauntlet_mod = @import("gauntlet.zig");

const PolicyGenome = policy_simd.PolicyGenome;
const Spec = @import("spec.zig").Spec;
const spec_policy = @import("spec_policy.zig");
const multi_spec = @import("multi_spec.zig");
const WarlockArenaPool = combat_spec.WarlockArenaPool;
const WarlockConstants = combat_spec.WarlockConstants;
const VEC_LEN = simd.SimdConfig.VecLen16;
const MatchRecorder = match_recorder.MatchRecorder;
const GauntletBotKind = gauntlet_mod.GauntletBotKind;
const GauntletRunner = gauntlet_mod.GauntletRunner;

pub const ModelEntry = struct {
    spec: Spec = .warlock,
    file_name: []const u8,
    file_path: []const u8,
    display_name: []const u8,
    genome: PolicyGenome,
};

pub const MatchupResult = struct {
    duels: usize = 0,
    wins_a: usize = 0,
    wins_b: usize = 0,
    draws: usize = 0,
    avg_duration_s: f32 = 0.0,
    avg_hp_a: f32 = 0.0,
    avg_hp_b: f32 = 0.0,

    pub fn winRateA(self: MatchupResult) f32 {
        if (self.duels == 0) return 0.0;
        return @as(f32, @floatFromInt(self.wins_a)) / @as(f32, @floatFromInt(self.duels));
    }
};

pub const SpecMatrixEvaluator = struct {
    allocator: mem.Allocator,
    models: std.ArrayList(ModelEntry),
    // matrix[i][j]: Model i vs Model j
    // matrix_bot[i][bot]: Model i vs Bot archetype
    matrix: std.ArrayList(std.ArrayList(MatchupResult)),
    bot_matrix: std.ArrayList([GauntletBotKind.COUNT]MatchupResult),

    pub fn init(allocator: mem.Allocator) SpecMatrixEvaluator {
        return .{
            .allocator = allocator,
            .models = std.ArrayList(ModelEntry).init(allocator),
            .matrix = std.ArrayList(std.ArrayList(MatchupResult)).init(allocator),
            .bot_matrix = std.ArrayList([GauntletBotKind.COUNT]MatchupResult).init(allocator),
        };
    }

    pub fn deinit(self: *SpecMatrixEvaluator) void {
        for (self.models.items) |m| {
            self.allocator.free(m.file_name);
            self.allocator.free(m.file_path);
            self.allocator.free(m.display_name);
        }
        self.models.deinit();

        for (self.matrix.items) |*row| {
            row.deinit();
        }
        self.matrix.deinit();
        self.bot_matrix.deinit();
    }

    /// Load all valid .bin models from a directory
    pub fn loadModelsFromDir(self: *SpecMatrixEvaluator, dir_path: []const u8) !usize {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        var count: usize = 0;
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".bin")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                errdefer self.allocator.free(full_path);

                const model = spec_policy.load(full_path) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const f_name = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(f_name);

                // Create friendly display name from file name (strip .bin, replace _ with space)
                const disp = try self.allocator.dupe(u8, entry.name[0 .. entry.name.len - 4]);
                for (disp) |*c| {
                    if (c.* == '_') c.* = ' ';
                }

                try self.models.append(.{
                    .file_name = f_name,
                    .file_path = full_path,
                    .display_name = disp,
                    .genome = model.genome,
                    .spec = model.spec,
                });
                count += 1;
            }
        }
        return count;
    }

    /// Run SIMD batch matches across all Model vs Model and Model vs Bot matchups
    pub fn evaluateAll(
        self: *SpecMatrixEvaluator,
        duels_per_matchup: usize,
        record_matches_dir: ?[]const u8,
    ) !void {
        const n = self.models.items.len;
        if (n == 0) return;

        // 1. Initialize matrix tables
        for (0..n) |_| {
            var row = std.ArrayList(MatchupResult).init(self.allocator);
            try row.appendNTimes(MatchupResult{}, n);
            try self.matrix.append(row);

            const bot_row: [GauntletBotKind.COUNT]MatchupResult = [_]MatchupResult{MatchupResult{}} ** GauntletBotKind.COUNT;
            try self.bot_matrix.append(bot_row);
        }

        // 2. Model vs Model Evaluation
        for (0..n) |i| {
            for (0..n) |j| {
                if (i == j) {
                    self.matrix.items[i].items[j] = MatchupResult{
                        .duels = 0,
                        .wins_a = 0,
                        .wins_b = 0,
                        .draws = 0,
                        .avg_duration_s = 0.0,
                    };
                    continue;
                }

                const res = try self.modelMatchup(self.models.items[i], self.models.items[j], duels_per_matchup);

                self.matrix.items[i].items[j] = res;

                // Optionally record representative fight trajectory
                if (record_matches_dir) |out_dir| {
                    var match_file_buf: [256]u8 = undefined;
                    const clean_name_a = self.models.items[i].file_name[0 .. self.models.items[i].file_name.len - 4];
                    const clean_name_b = self.models.items[j].file_name[0 .. self.models.items[j].file_name.len - 4];
                    const match_path = try std.fmt.bufPrint(&match_file_buf, "{s}/match_{s}_vs_{s}.lua", .{ out_dir, clean_name_a, clean_name_b });

                    var traj = try self.recordModels(self.models.items[i], self.models.items[j]);
                    defer traj.deinit();
                    try traj.exportLua(match_path);
                }
            }
        }

        // 3. Model vs Gauntlet Bot Evaluation
        for (0..n) |i| {
            for (0..GauntletBotKind.COUNT) |b_idx| {
                const bot_kind: GauntletBotKind = @enumFromInt(@as(u32, @intCast(b_idx)));
                const bot = gauntlet_mod.GauntletBot.init(bot_kind);
                const res = try switch (self.models.items[i].spec) {
                    .warlock => matchup(.warlock, .warlock, self.allocator, &self.models.items[i].genome, &bot, duels_per_matchup),
                    .frost_mage => matchup(.frost_mage, .warlock, self.allocator, &self.models.items[i].genome, &bot, duels_per_matchup),
                };

                self.bot_matrix.items[i][b_idx] = res;

                if (record_matches_dir) |out_dir| {
                    var match_file_buf: [256]u8 = undefined;
                    const clean_name_a = self.models.items[i].file_name[0 .. self.models.items[i].file_name.len - 4];
                    const match_path = try std.fmt.bufPrint(&match_file_buf, "{s}/match_{s}_vs_{s}.lua", .{ out_dir, clean_name_a, @tagName(bot_kind) });

                    var traj = try switch (self.models.items[i].spec) {
                        .warlock => GauntletRunner.recordDuelVsBot(self.allocator, &self.models.items[i].genome, bot_kind, self.models.items[i].display_name, 35, 0.01),
                        .frost_mage => gauntlet_mod.GauntletFor(.frost_mage).recordDuelVsBot(self.allocator, &self.models.items[i].genome, bot_kind, self.models.items[i].display_name, 35, 0.01),
                    };
                    defer traj.deinit();
                    try traj.exportLua(match_path);
                }
            }
        }
    }

    fn matchup(comptime a: Spec, comptime b: Spec, allocator: mem.Allocator, p_a: *const PolicyGenome, p_b: anytype, duels: usize) !MatchupResult {
        var arena = try multi_spec.ArenaPool(a, b).init(allocator, VEC_LEN);
        defer arena.deinit();
        const dt: f32 = 0.01;
        const max_ticks: usize = 3000;
        const num_batches = (duels + VEC_LEN - 1) / VEC_LEN;
        var res = MatchupResult{};
        for (0..num_batches) |_| {
            for (0..VEC_LEN) |lane| arena.resetDuel(lane);
            var elapsed_ticks: usize = 0;
            var lane_ticks = [_]usize{max_ticks} ** VEC_LEN;

            while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
                const act_mask = arena.combat().is_active[0..VEC_LEN].* > @as(simd.u32x16, @splat(0));
                if (!@reduce(.Or, act_mask)) break;

                const dec_a = arena.needsDecisionA(0);
                if (@reduce(.Or, dec_a)) {
                    const obs_a = arena.getObservationsA(0);
                    const masks_a = arena.getActionMaskA(0);
                    const out_a = p_a.forward16(obs_a, masks_a);
                    arena.applyActionA(0, out_a.actions, out_a.move_intents);
                }

                const dec_b = arena.needsDecisionB(0);
                if (@reduce(.Or, dec_b)) {
                    const obs_b = arena.getObservationsB(0);
                    const masks_b = arena.getActionMaskB(0);
                    const out_b = p_b.forward16(obs_b, masks_b);
                    arena.applyActionB(0, out_b.actions, out_b.move_intents);
                }

                _ = arena.tickPhysics16(dt, 0);
                for (0..VEC_LEN) |lane| if (act_mask[lane] and arena.combat().is_active[lane] == 0) {
                    lane_ticks[lane] = elapsed_ticks + 1;
                };
            }

            for (0..VEC_LEN) |lane| {
                res.duels += 1;
                const hp_a = arena.combat().hp_a[lane];
                const hp_b = arena.combat().hp_b[lane];
                res.avg_hp_a += hp_a;
                res.avg_hp_b += hp_b;
                res.avg_duration_s += @as(f32, @floatFromInt(lane_ticks[lane])) * dt;

                if (hp_a > 0.0 and hp_b <= 0.0) {
                    res.wins_a += 1;
                } else if (hp_b > 0.0 and hp_a <= 0.0) {
                    res.wins_b += 1;
                } else {
                    res.draws += 1;
                }
            }
        }

        if (res.duels > 0) {
            const d_f = @as(f32, @floatFromInt(res.duels));
            res.avg_duration_s /= d_f;
            res.avg_hp_a /= d_f;
            res.avg_hp_b /= d_f;
        }

        return res;
    }
    fn modelMatchup(self: *SpecMatrixEvaluator, a: ModelEntry, b: ModelEntry, duels: usize) !MatchupResult {
        return switch (a.spec) {
            .warlock => switch (b.spec) {
                .warlock => matchup(.warlock, .warlock, self.allocator, &a.genome, &b.genome, duels),
                .frost_mage => matchup(.warlock, .frost_mage, self.allocator, &a.genome, &b.genome, duels),
            },
            .frost_mage => switch (b.spec) {
                .warlock => matchup(.frost_mage, .warlock, self.allocator, &a.genome, &b.genome, duels),
                .frost_mage => matchup(.frost_mage, .frost_mage, self.allocator, &a.genome, &b.genome, duels),
            },
        };
    }
    fn recordModels(self: *SpecMatrixEvaluator, a: ModelEntry, b: ModelEntry) !match_recorder.MatchTrajectory {
        return switch (a.spec) {
            .warlock => switch (b.spec) {
                .warlock => MatchRecorder.recordDuel(self.allocator, &a.genome, &b.genome, a.display_name, b.display_name, 35, 0.01),
                .frost_mage => MatchRecorder.recordPair(.warlock, .frost_mage, self.allocator, &a.genome, &b.genome, b.genome.elo, a.display_name, b.display_name, 35, 0.01),
            },
            .frost_mage => switch (b.spec) {
                .warlock => MatchRecorder.recordPair(.frost_mage, .warlock, self.allocator, &a.genome, &b.genome, b.genome.elo, a.display_name, b.display_name, 35, 0.01),
                .frost_mage => MatchRecorder.recordPair(.frost_mage, .frost_mage, self.allocator, &a.genome, &b.genome, b.genome.elo, a.display_name, b.display_name, 35, 0.01),
            },
        };
    }

    /// Export matrix and all matchup entries to high-performance Lua table format
    pub fn exportLua(self: *const SpecMatrixEvaluator, out_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        var buf_writer = std.io.bufferedWriter(file.writer());
        const w = buf_writer.writer();

        try w.writeAll("return {\n");

        // Models list
        try w.writeAll("  models = {\n");
        for (self.models.items, 0..) |m, idx| {
            try w.print("    [{d}] = {{ id = {d}, name = \"{s}\", file = \"{s}\", spec = \"{s}\", elo = {d:0.1} }},\n", .{ idx + 1, idx + 1, m.display_name, m.file_name, @tagName(m.spec), m.genome.elo });
        }
        try w.writeAll("  },\n");

        // Bots list
        try w.writeAll("  bots = {\n");
        for (0..GauntletBotKind.COUNT) |b_idx| {
            const kind: GauntletBotKind = @enumFromInt(@as(u32, @intCast(b_idx)));
            try w.print("    [{d}] = {{ name = \"{s}\", icon = \"{s}\", baseline_elo = {d:0.0} }},\n", .{ b_idx + 1, kind.getName(), kind.getIcon(), kind.getBaselineElo() });
        }
        try w.writeAll("  },\n");

        // Pairwise Model Matrix
        try w.writeAll("  matrix = {\n");
        for (self.matrix.items, 0..) |row, i| {
            try w.print("    [{d}] = {{\n", .{i + 1});
            for (row.items, 0..) |res, j| {
                try w.print("      [{d}] = {{ duels = {d}, win_rate = {d:0.3}, wins_a = {d}, wins_b = {d}, draws = {d}, avg_time = {d:0.2}, hp_a = {d:0.0}, hp_b = {d:0.0} }},\n", .{ j + 1, res.duels, res.winRateA(), res.wins_a, res.wins_b, res.draws, res.avg_duration_s, res.avg_hp_a, res.avg_hp_b });
            }
            try w.writeAll("    },\n");
        }
        try w.writeAll("  },\n");

        // Model vs Bot Matrix
        try w.writeAll("  bot_matrix = {\n");
        for (self.bot_matrix.items, 0..) |bot_row, i| {
            try w.print("    [{d}] = {{\n", .{i + 1});
            for (bot_row, 0..) |res, b_idx| {
                try w.print("      [{d}] = {{ duels = {d}, win_rate = {d:0.3}, wins_a = {d}, wins_b = {d}, draws = {d}, avg_time = {d:0.2}, hp_a = {d:0.0}, hp_b = {d:0.0} }},\n", .{ b_idx + 1, res.duels, res.winRateA(), res.wins_a, res.wins_b, res.draws, res.avg_duration_s, res.avg_hp_a, res.avg_hp_b });
            }
            try w.writeAll("    },\n");
        }
        try w.writeAll("  },\n");

        try w.writeAll("}\n");
        try buf_writer.flush();
    }
};

test "SpecMatrixEvaluator load and empty check" {
    var eval = SpecMatrixEvaluator.init(std.testing.allocator);
    defer eval.deinit();

    _ = eval.loadModelsFromDir("models") catch {};
    try std.testing.expect(eval.models.items.len >= 0);
}

test "Matrix loads class tags and evaluates both asymmetric pairings and bot rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    var prng = std.Random.DefaultPrng.init(5);
    const genome = PolicyGenome.initRandom(prng.random());
    inline for (.{ Spec.warlock, Spec.frost_mage }) |class| {
        const path = try std.fs.path.join(allocator, &.{ dir, @tagName(class) ++ ".bin" });
        defer allocator.free(path);
        try spec_policy.save(&genome, class, path);
    }
    var evaluator = SpecMatrixEvaluator.init(allocator);
    defer evaluator.deinit();
    try std.testing.expectEqual(@as(usize, 2), try evaluator.loadModelsFromDir(dir));
    try std.testing.expect(evaluator.models.items[0].spec != evaluator.models.items[1].spec);
    try evaluator.evaluateAll(16, null);
    try std.testing.expectEqual(@as(usize, 16), evaluator.matrix.items[0].items[1].duels);
    try std.testing.expectEqual(@as(usize, 16), evaluator.matrix.items[1].items[0].duels);
    for (evaluator.bot_matrix.items) |row| for (row) |result| try std.testing.expectEqual(@as(usize, 16), result.duels);
}
