const std = @import("std");
const mem = std.mem;
const spec_mod = @import("spec.zig");
const spec_policy = @import("spec_policy.zig");
const Spec = spec_mod.Spec;
const SpecConfig = spec_mod.SpecConfig;
const CANONICAL_SPECS = spec_mod.CANONICAL_SPECS;
const TalentBuild = spec_mod.TalentBuild;

pub const ModelStatus = struct {
    file_path: []const u8,
    file_name: []const u8,
    spec: Spec,
    elo: f32,
    modified_timestamp: i128,
};

pub const SpecBaseStatus = struct {
    config: SpecConfig,
    has_base: bool = false,
    base_model: ?ModelStatus = null,
};

pub const PairMatchupStatus = struct {
    spec_a: SpecConfig,
    spec_b: SpecConfig,
    has_model: bool = false,
    model: ?ModelStatus = null,
};

pub const OverallMetaHealth = struct {
    total_canonical_specs: usize,
    trained_bases_count: usize,
    total_possible_pairs: usize,
    trained_pairs_count: usize,
    base_coverage_pct: f32,
    pair_coverage_pct: f32,
};

pub const SpecHealthMonitor = struct {
    allocator: mem.Allocator,
    base_statuses: std.ArrayList(SpecBaseStatus),
    pair_statuses: std.ArrayList(PairMatchupStatus),
    discovered_models: std.ArrayList(ModelStatus),

    pub fn init(allocator: mem.Allocator) SpecHealthMonitor {
        return .{
            .allocator = allocator,
            .base_statuses = std.ArrayList(SpecBaseStatus).init(allocator),
            .pair_statuses = std.ArrayList(PairMatchupStatus).init(allocator),
            .discovered_models = std.ArrayList(ModelStatus).init(allocator),
        };
    }

    pub fn deinit(self: *SpecHealthMonitor) void {
        for (self.discovered_models.items) |m| {
            self.allocator.free(m.file_path);
            self.allocator.free(m.file_name);
        }
        self.discovered_models.deinit();
        self.base_statuses.deinit();
        self.pair_statuses.deinit();
    }

    /// Scan directory (e.g. "models/" or "training_runs/") for available models
    pub fn scanModels(self: *SpecHealthMonitor, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".bin")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                errdefer self.allocator.free(full_path);

                const file = std.fs.cwd().openFile(full_path, .{}) catch {
                    self.allocator.free(full_path);
                    continue;
                };
                const stat = file.stat() catch {
                    file.close();
                    self.allocator.free(full_path);
                    continue;
                };
                file.close();

                const model = spec_policy.load(full_path) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const f_name = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(f_name);

                try self.discovered_models.append(.{
                    .file_path = full_path,
                    .file_name = f_name,
                    .spec = model.spec,
                    .elo = model.genome.elo,
                    .modified_timestamp = stat.mtime,
                });
            }
        }
    }

    /// Analyze spec bases and spec-vs-spec matchup coverage
    pub fn analyze(self: *SpecHealthMonitor) !OverallMetaHealth {
        self.base_statuses.clearRetainingCapacity();
        self.pair_statuses.clearRetainingCapacity();

        // 1. Check base models for each canonical spec
        for (CANONICAL_SPECS) |canonical| {
            var base_status = SpecBaseStatus{ .config = canonical };

            for (self.discovered_models.items) |m| {
                const name_lower = m.file_name;
                const matches_id = mem.indexOf(u8, name_lower, canonical.id) != null;
                // Specific spec token matching:
                const matches_tokens = switch (canonical.class) {
                    .warlock => if (mem.indexOf(u8, canonical.id, "affliction") != null)
                        (mem.indexOf(u8, name_lower, "affliction") != null)
                    else if (mem.indexOf(u8, canonical.id, "soul_link") != null)
                        (mem.indexOf(u8, name_lower, "soul_link") != null)
                    else if (mem.indexOf(u8, canonical.id, "destro") != null)
                        (mem.indexOf(u8, name_lower, "destro") != null)
                    else
                        false,
                    .frost_mage => (mem.indexOf(u8, name_lower, "frost") != null and mem.indexOf(u8, name_lower, "mage") != null),
                };

                // Exclude pairwise models that have "_vs_"
                const is_pairwise = mem.indexOf(u8, name_lower, "_vs_") != null;

                if (!is_pairwise and m.spec == canonical.class and (matches_id or matches_tokens)) {
                    base_status.has_base = true;
                    base_status.base_model = m;
                    break;
                }
            }

            try self.base_statuses.append(base_status);
        }

        // 2. Check pairwise models for all pairs
        for (CANONICAL_SPECS) |spec_a| {
            for (CANONICAL_SPECS) |spec_b| {
                if (std.mem.eql(u8, spec_a.id, spec_b.id)) continue;

                var pair_status = PairMatchupStatus{
                    .spec_a = spec_a,
                    .spec_b = spec_b,
                };

                for (self.discovered_models.items) |m| {
                    const name = m.file_name;
                    // Check if file is of pattern: {spec_a}_vs_{spec_b}.bin
                    const has_a = mem.indexOf(u8, name, spec_a.id) != null;
                    const has_b = mem.indexOf(u8, name, spec_b.id) != null;
                    const has_vs = mem.indexOf(u8, name, "vs") != null;

                    if (has_a and has_b and has_vs) {
                        pair_status.has_model = true;
                        pair_status.model = m;
                        break;
                    }
                }

                try self.pair_statuses.append(pair_status);
            }
        }

        // 3. Compute summary health
        var trained_bases: usize = 0;
        for (self.base_statuses.items) |b| {
            if (b.has_base) trained_bases += 1;
        }

        var trained_pairs: usize = 0;
        for (self.pair_statuses.items) |p| {
            if (p.has_model) trained_pairs += 1;
        }

        const total_specs = CANONICAL_SPECS.len;
        const total_pairs = self.pair_statuses.items.len;

        return .{
            .total_canonical_specs = total_specs,
            .trained_bases_count = trained_bases,
            .total_possible_pairs = total_pairs,
            .trained_pairs_count = trained_pairs,
            .base_coverage_pct = if (total_specs > 0) (@as(f32, @floatFromInt(trained_bases)) / @as(f32, @floatFromInt(total_specs))) * 100.0 else 0.0,
            .pair_coverage_pct = if (total_pairs > 0) (@as(f32, @floatFromInt(trained_pairs)) / @as(f32, @floatFromInt(total_pairs))) * 100.0 else 0.0,
        };
    }

    /// Render human-readable ASCII report to any writer
    pub fn renderReport(self: *const SpecHealthMonitor, health: OverallMetaHealth, writer: anytype) !void {
        try writer.print("\n=========================================================================================\n", .{});
        try writer.print("                           SPEC & PAIRWISE HEALTH MONITOR\n", .{});
        try writer.print("=========================================================================================\n\n", .{});

        try writer.print("--- Canonical Specs & Base Foundations ({d}/{d} Trained, {d:0.1}% Coverage) ---\n", .{
            health.trained_bases_count, health.total_canonical_specs, health.base_coverage_pct,
        });
        try writer.print("{s:<24} | {s:<10} | {s:<10} | {s:<8} | {s}\n", .{ "Spec Name", "Class", "Talents", "Base", "Model Details" });
        try writer.print("-------------------------+------------+------------+----------+--------------------------\n", .{});

        for (self.base_statuses.items) |b| {
            const status_str = if (b.has_base) "[TRAINED]" else "[MISSING]";
            var talents_buf: [32]u8 = undefined;
            const t_str = try std.fmt.bufPrint(&talents_buf, "{d}/{d}/{d}", .{ b.config.talents.tree1, b.config.talents.tree2, b.config.talents.tree3 });

            if (b.base_model) |m| {
                try writer.print("{s:<24} | {s:<10} | {s:<10} | {s:<8} | {s} (Elo {d:0.0})\n", .{
                    b.config.name, @tagName(b.config.class), t_str, status_str, m.file_name, m.elo,
                });
            } else {
                try writer.print("{s:<24} | {s:<10} | {s:<10} | {s:<8} | <none>\n", .{
                    b.config.name, @tagName(b.config.class), t_str, status_str,
                });
            }
        }

        try writer.print("\n--- Spec vs Spec Pairwise Matchup Models ({d}/{d} Trained, {d:0.1}% Coverage) ---\n", .{
            health.trained_pairs_count, health.total_possible_pairs, health.pair_coverage_pct,
        });
        try writer.print("{s:<24} vs {s:<24} | {s:<8} | {s}\n", .{ "Spec A", "Spec B", "Status", "Specialist Model" });
        try writer.print("-------------------------+--------------------------+----------+-------------------------\n", .{});

        for (self.pair_statuses.items) |p| {
            const status_str = if (p.has_model) "[TRAINED]" else "[MISSING]";
            if (p.model) |m| {
                try writer.print("{s:<24} vs {s:<24} | {s:<8} | {s}\n", .{
                    p.spec_a.name, p.spec_b.name, status_str, m.file_name,
                });
            } else {
                try writer.print("{s:<24} vs {s:<24} | {s:<8} | <unspecialized>\n", .{
                    p.spec_a.name, p.spec_b.name, status_str,
                });
            }
        }
        try writer.print("=========================================================================================\n\n", .{});
    }

    /// Export status as high-speed Lua format for visualizer ingestion
    pub fn exportLua(self: *const SpecHealthMonitor, health: OverallMetaHealth, out_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        var buf_writer = std.io.bufferedWriter(file.writer());
        const w = buf_writer.writer();

        try w.writeAll("return {\n");
        try w.print("  summary = {{ total_specs = {d}, trained_bases = {d}, base_pct = {d:0.1}, total_pairs = {d}, trained_pairs = {d}, pair_pct = {d:0.1} }},\n", .{
            health.total_canonical_specs, health.trained_bases_count, health.base_coverage_pct, health.total_possible_pairs, health.trained_pairs_count, health.pair_coverage_pct,
        });

        try w.writeAll("  specs = {\n");
        for (self.base_statuses.items, 1..) |b, idx| {
            try w.print("    [{d}] = {{ id = \"{s}\", name = \"{s}\", class = \"{s}\", talents = \"{d}/{d}/{d}\", has_base = {s}", .{
                idx, b.config.id, b.config.name, @tagName(b.config.class), b.config.talents.tree1, b.config.talents.tree2, b.config.talents.tree3, if (b.has_base) "true" else "false",
            });
            if (b.base_model) |m| {
                try w.print(", model = \"{s}\", elo = {d:0.1} }},\n", .{ m.file_name, m.elo });
            } else {
                try w.writeAll(" },\n");
            }
        }
        try w.writeAll("  },\n");

        try w.writeAll("  pairs = {\n");
        for (self.pair_statuses.items, 1..) |p, idx| {
            try w.print("    [{d}] = {{ spec_a = \"{s}\", spec_b = \"{s}\", has_model = {s}", .{
                idx, p.spec_a.id, p.spec_b.id, if (p.has_model) "true" else "false",
            });
            if (p.model) |m| {
                try w.print(", model = \"{s}\", elo = {d:0.1} }},\n", .{ m.file_name, m.elo });
            } else {
                try w.writeAll(" },\n");
            }
        }
        try w.writeAll("  },\n");
        try w.writeAll("}\n");
        try buf_writer.flush();
    }
};

test "SpecHealthMonitor empty check" {
    var monitor = SpecHealthMonitor.init(std.testing.allocator);
    defer monitor.deinit();

    const health = try monitor.analyze();
    try std.testing.expectEqual(CANONICAL_SPECS.len, health.total_canonical_specs);
    try std.testing.expectEqual(@as(usize, 0), health.trained_bases_count);
}
