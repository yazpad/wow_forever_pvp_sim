//! Counterfactual continuations using the production simulator and MCTS search.
const std = @import("std");
const sim = @import("search_sim.zig");
const mcts = @import("mcts.zig");
const spec = @import("spec.zig");
const identity = @import("simulator_identity_generated.zig");

pub const SavedOptions = struct {
    a: spec.Spec,
    b: spec.Spec,
    config: mcts.Config,
    warlock_talents_a: spec.WarlockTalentRanks = .{},
    warlock_talents_b: spec.WarlockTalentRanks = .{},
    action_mask_a: u32 = std.math.maxInt(u32),
    action_mask_b: u32 = std.math.maxInt(u32),
};
pub const Decision = struct { tick: u32, actions: [2]sim.Action, state: ?sim.Snapshot = null };
pub const SavedRun = struct {
    simulator_version: []const u8,
    simulator_fingerprint: ?[]const u8 = null,
    options: SavedOptions,
    initial_state: sim.Snapshot,
    decisions: []Decision,
};
pub const Result = struct {
    action: sim.Action,
    chosen: bool,
    wins: u32 = 0,
    losses: u32 = 0,
    draws: u32 = 0,
    unresolved: u32 = 0,
    mean_hp_margin: f32 = 0,
    score: f32 = 0,
    delta_vs_chosen: f32 = 0,
    paired_standard_error: f32 = 0,
};
pub const Settings = struct {
    rollouts: ?usize = null,
    workers: usize = 2,
    budget_multiplier: usize = 2,
    progress_file: ?[]const u8 = null,
};

pub fn continuationConfig(original: mcts.Config, settings: Settings, stop_file: ?[]const u8) !mcts.Config {
    if (settings.workers == 0 or settings.workers > 64 or settings.budget_multiplier == 0 or settings.budget_multiplier > 64) return error.InvalidAnalysisBudget;
    var config = original;
    config.rollouts = settings.rollouts orelse @max(4096, try std.math.mul(usize, original.rollouts, settings.budget_multiplier));
    if (config.rollouts == 0 or config.rollouts > 1048576) return error.InvalidAnalysisBudget;
    config.workers = @min(settings.workers, config.rollouts);
    // More simulations must not be squeezed into a smaller total tree merely
    // because the background job uses fewer CPU workers than the original run.
    const original_capacity = try std.math.mul(usize, original.nodes, original.workers);
    const target_capacity = @max(original_capacity, config.rollouts + config.workers);
    config.nodes = @max(original.nodes, std.math.divCeil(usize, target_capacity, config.workers) catch unreachable);
    config.milliseconds = 0; // Complete the explicit analysis budget.
    config.stop_file = stop_file;
    return config;
}
pub fn verifyEngine(run: SavedRun) !bool {
    if (run.simulator_fingerprint) |fingerprint| {
        if (!std.mem.eql(u8, fingerprint, identity.fingerprint)) return error.SimulatorSourceMismatch;
        return true;
    }
    return false;
}
fn writeJsonAtomic(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    {
        const file = try std.fs.cwd().createFile(temporary, .{});
        defer file.close();
        try std.json.stringify(value, .{}, file.writer());
    }
    try std.fs.cwd().rename(temporary, path);
}

pub const Report = struct {
    decision: usize,
    tick: u32,
    side: u1,
    samples: usize,
    seed: u64,
    seed_stride: u64 = 0x9e3779b97f4a7c15,
    max_ticks: u32,
    hp: [2]f32,
    mana: [2]f32,
    chosen: sim.Action,
    opponent_action: sim.Action,
    policy: []const u8 = "production MCTS for both players at every subsequent decision; recorded opponent move fixed at the initial branch only",
    simulator_fingerprint: []const u8 = identity.fingerprint,
    engine_verified: bool,
    continuation_search: mcts.Config,
    search_decisions: u64,
    search_rollouts: u64,
    score_definition: []const u8 = "win=1, loss=0, draw/unresolved=0.5; unresolved counts are reported separately",
    results: []Result,
};
pub fn configure(duel: anytype, options: SavedOptions) void {
    duel.setWarlockTalentRanksA(if (options.a == .warlock) options.warlock_talents_a.encode() else 0);
    duel.setWarlockTalentRanksB(if (options.b == .warlock) options.warlock_talents_b.encode() else 0);
    duel.setActionMaskA(options.action_mask_a);
    duel.setActionMaskB(options.action_mask_b);
}
/// Replay commands, never re-run the original search or re-load mutable specs.
pub fn reconstruct(duel: anytype, run: SavedRun, index: usize) !sim.Snapshot {
    if (index >= run.decisions.len) return error.UnknownDecision;
    if (run.decisions[index].state) |state| {
        if (state.tick != run.decisions[index].tick) return error.InvalidDecisionSnapshot;
        duel.restore(0, state);
        return state;
    }
    duel.restore(0, run.initial_state);
    var previous = run.initial_state.tick;
    for (run.decisions[0 .. index + 1], 0..) |decision, j| {
        if (decision.tick < previous or decision.tick >= run.options.config.max_ticks) return error.InvalidDecisionTimeline;
        while (duel.ticks[0] < decision.tick) {
            if (duel.arena.combat().is_active[0] == 0) return error.ReplayEndedBeforeDecision;
            duel.tick(run.options.config.max_ticks);
        }
        if (j == index) return duel.snapshot(0);
        const aa: [16]sim.Action = @splat(decision.actions[0]);
        const bb: [16]sim.Action = @splat(decision.actions[1]);
        if (run.options.config.boundary == .event) duel.applyTactical(aa, bb) else duel.apply(aa, bb);
        previous = decision.tick;
    }
    unreachable;
}
fn cancelled(path: ?[]const u8) bool {
    if (path) |p| {
        std.fs.cwd().access(p, .{}) catch return false;
        return true;
    }
    return false;
}
pub fn analyze(comptime a: spec.Spec, comptime b: spec.Spec, comptime side: bool, allocator: std.mem.Allocator, run: SavedRun, index: usize, samples: usize, seed: u64, stop_file: ?[]const u8, settings: Settings) !Report {
    if (samples < 2 or samples > 4096) return error.InvalidSamples;
    var duel = try sim.Duel(a, b).init(allocator);
    defer duel.deinit();
    configure(&duel, run.options);
    const engine_verified = try verifyEngine(run);
    var config = try continuationConfig(run.options.config, settings, stop_file);
    config.seed = seed;
    const search = try mcts.Search(a, b).init(allocator, config);
    defer search.deinit();
    search.setWarlockTalentRanksA(if (a == .warlock) run.options.warlock_talents_a.encode() else 0);
    search.setWarlockTalentRanksB(if (b == .warlock) run.options.warlock_talents_b.encode() else 0);
    search.setActionMaskA(run.options.action_mask_a);
    search.setActionMaskB(run.options.action_mask_b);
    var search_decisions: u64 = 0;
    var search_rollouts: u64 = 0;
    const root = try reconstruct(&duel, run, index);
    const ready = if (run.options.config.boundary == .event) duel.readyTactical(side)[0] else duel.ready(side)[0];
    if (!ready) return error.PlayerNotReadyAtDecision;
    const masks = if (side) duel.getActionMaskA(0) else duel.getActionMaskB(0);
    const choices = if (run.options.config.boundary == .event) duel.choicesTactical(side, 0, masks) else duel.choices(side, 0, masks);
    const chosen = run.decisions[index].actions[if (side) 0 else 1];
    const opponent = run.decisions[index].actions[if (side) 1 else 0];
    var chosen_index: ?usize = null;
    for (choices.items[0..choices.len], 0..) |action, i| {
        if (action.ability == chosen.ability and action.movement == chosen.movement) chosen_index = i;
    }
    if (chosen_index == null) return error.RecordedActionIsNoLongerLegal;
    const hp = [2]f32{ duel.arena.combat().hp_a[0], duel.arena.combat().hp_b[0] };
    const mana = [2]f32{ duel.arena.combat().mana_a[0], duel.arena.combat().mana_b[0] };
    const results = try allocator.alloc(Result, choices.len);
    errdefer allocator.free(results);
    const outcomes = try allocator.alloc(f32, choices.len * samples);
    defer allocator.free(outcomes);
    // Evaluate the played move first; compare each alternative under the same
    // set of search seeds, resetting worker RNGs between continuations.
    for (0..choices.len) |ordinal| {
        const candidate = if (ordinal == 0) chosen_index.? else if (ordinal <= chosen_index.?) ordinal - 1 else ordinal;
        const action = choices.items[candidate];
        results[candidate] = .{ .action = action, .chosen = candidate == chosen_index.? };
        var margin: f32 = 0;
        for (0..samples) |sample| {
            if (cancelled(stop_file)) return error.AnalysisCancelled;
            if (settings.progress_file) |path| try writeJsonAtomic(allocator, path, .{
                .completed_candidates = ordinal,
                .total_candidates = choices.len,
                .completed_samples = sample,
                .samples = samples,
                .rollouts_per_decision = config.rollouts,
                .workers = config.workers,
                .search_decisions = search_decisions,
                .search_rollouts = search_rollouts,
            });
            duel.restore(0, root);
            @memset(duel.arena.combat().is_active[1..16], 0);
            const sample_seed = seed +% (@as(u64, @intCast(sample)) *% 0x9e3779b97f4a7c15);
            search.reseed(sample_seed);
            var committed_rng = std.Random.DefaultPrng.init(sample_seed ^ 0xbadc0ffee);
            const random = committed_rng.random();
            const aa: [16]sim.Action = @splat(if (side) action else opponent);
            const bb: [16]sim.Action = @splat(if (side) opponent else action);
            if (run.options.config.boundary == .event) duel.applyTactical(aa, bb) else duel.apply(aa, bb);
            const state = duel.arena.combat();
            // This is the same boundary -> joint search -> apply -> physics
            // sequence as mcts_main, with the branch's first actions fixed.
            while (state.is_active[0] != 0) {
                duel.tick(config.max_ticks);
                if (cancelled(stop_file)) return error.AnalysisCancelled;
                if (state.is_active[0] == 0) break;
                const ready_a = if (config.boundary == .event) duel.readyTactical(true)[0] else duel.ready(true)[0];
                const ready_b = if (config.boundary == .event) duel.readyTactical(false)[0] else duel.ready(false)[0];
                if (ready_a or ready_b) {
                    const decision = search.decide(duel.snapshot(0), random);
                    if (cancelled(stop_file)) return error.AnalysisCancelled;
                    search_decisions += 1;
                    search_rollouts += decision.stats.rollouts;
                    if (config.boundary == .event) {
                        duel.applyTactical(@splat(decision.actions[0]), @splat(decision.actions[1]));
                    } else duel.apply(@splat(decision.actions[0]), @splat(decision.actions[1]));
                }
            }
            const own = if (side) state.hp_a[0] else state.hp_b[0];
            const enemy = if (side) state.hp_b[0] else state.hp_a[0];
            var score: f32 = 0.5;
            if (own <= 0 and enemy <= 0) {
                results[candidate].draws += 1;
            } else if (enemy <= 0) {
                results[candidate].wins += 1;
                score = 1;
            } else if (own <= 0) {
                results[candidate].losses += 1;
                score = 0;
            } else results[candidate].unresolved += 1;
            outcomes[candidate * samples + sample] = score;
            results[candidate].score += score;
            margin += own - enemy;
        }
        results[candidate].mean_hp_margin = margin / @as(f32, @floatFromInt(samples));
        results[candidate].score /= @as(f32, @floatFromInt(samples));
    }
    for (results, 0..) |*result, candidate| {
        var sum: f32 = 0;
        var squares: f32 = 0;
        for (0..samples) |sample| {
            const delta = outcomes[candidate * samples + sample] - outcomes[chosen_index.? * samples + sample];
            sum += delta;
            squares += delta * delta;
        }
        const n: f32 = @floatFromInt(samples);
        result.delta_vs_chosen = sum / n;
        result.paired_standard_error = if (samples > 1) @sqrt(@max(0, (squares - sum * sum / n) / (n - 1) / n)) else 0;
    }
    return .{ .decision = index, .tick = run.decisions[index].tick, .side = if (side) 0 else 1, .samples = samples, .seed = seed, .max_ticks = run.options.config.max_ticks, .hp = hp, .mana = mana, .chosen = chosen, .opponent_action = opponent, .engine_verified = engine_verified, .continuation_search = config, .search_decisions = search_decisions, .search_rollouts = search_rollouts, .results = results };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next();
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var index: usize = 0;
    var side: u1 = 0;
    var samples: usize = 8;
    var settings: Settings = .{};
    var seed: u64 = 947;
    var stop_file: ?[]const u8 = null;
    while (args.next()) |arg| {
        const value = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--input")) input = value else if (std.mem.eql(u8, arg, "--output")) output = value else if (std.mem.eql(u8, arg, "--decision")) index = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--side")) side = try std.fmt.parseInt(u1, value, 10) else if (std.mem.eql(u8, arg, "--samples")) samples = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--rollouts")) settings.rollouts = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--workers")) settings.workers = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--budget-multiplier")) settings.budget_multiplier = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--seed")) seed = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--stop-file")) stop_file = value else return error.UnknownOption;
    }
    if (samples < 2 or samples > 4096) return error.InvalidSamples;
    if (input == null or output == null) return error.InputAndOutputRequired;
    if (std.mem.eql(u8, input.?, output.?)) return error.OutputMustDifferFromInput;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, input.?, 128 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(SavedRun, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const run = parsed.value;
    if (!std.mem.eql(u8, run.simulator_version, "mcts-simultaneous-v2-pets")) return error.IncompatibleSimulatorVersion;
    if (index >= run.decisions.len or run.options.config.max_ticks > 60000 or run.options.config.max_ticks == 0) return error.InvalidRun;
    settings.progress_file = try std.fmt.allocPrint(allocator, "{s}.progress.json", .{output.?});
    defer allocator.free(settings.progress_file.?);
    const report = switch (run.options.a) {
        .warlock => switch (run.options.b) {
            .warlock => if (side == 0) try analyze(.warlock, .warlock, true, allocator, run, index, samples, seed, stop_file, settings) else try analyze(.warlock, .warlock, false, allocator, run, index, samples, seed, stop_file, settings),
            .frost_mage => if (side == 0) try analyze(.warlock, .frost_mage, true, allocator, run, index, samples, seed, stop_file, settings) else try analyze(.warlock, .frost_mage, false, allocator, run, index, samples, seed, stop_file, settings),
        },
        .frost_mage => switch (run.options.b) {
            .warlock => if (side == 0) try analyze(.frost_mage, .warlock, true, allocator, run, index, samples, seed, stop_file, settings) else try analyze(.frost_mage, .warlock, false, allocator, run, index, samples, seed, stop_file, settings),
            .frost_mage => if (side == 0) try analyze(.frost_mage, .frost_mage, true, allocator, run, index, samples, seed, stop_file, settings) else try analyze(.frost_mage, .frost_mage, false, allocator, run, index, samples, seed, stop_file, settings),
        },
    };
    defer allocator.free(report.results);
    try writeJsonAtomic(allocator, output.?, report);
    try std.io.getStdOut().writer().print("Analyzed decision {d}, side {d}: {d} alternatives x {d} MCTS continuations ({d} rollouts/decision, {d} workers)\n", .{ index, side, report.results.len, samples, report.continuation_search.rollouts, report.continuation_search.workers });
}

test "analysis reconstructs saved commands exactly for mirror and mixed matchups" {
    inline for (.{ spec.Spec.warlock, spec.Spec.frost_mage }) |b| {
        var duel = try sim.Duel(.warlock, b).init(std.testing.allocator);
        defer duel.deinit();
        const options = SavedOptions{ .a = .warlock, .b = b, .config = .{ .max_ticks = 300, .boundary = .event } };
        configure(&duel, options);
        const initial = duel.snapshot(0);
        const decisions = [_]Decision{
            .{ .tick = 0, .actions = .{ .{ .ability = 2 }, .{ .ability = 4 } } },
            .{ .tick = 100, .actions = .{ .{}, .{} } },
        };
        duel.applyTactical(@splat(decisions[0].actions[0]), @splat(decisions[0].actions[1]));
        for (0..100) |_| duel.tick(300);
        const expected = duel.snapshot(0);
        const run = SavedRun{ .simulator_version = "mcts-simultaneous-v2-pets", .options = options, .initial_state = initial, .decisions = @constCast(&decisions) };
        const actual = try reconstruct(&duel, run, 1);
        try std.testing.expectEqualDeep(expected, actual);
        var with_snapshot = decisions;
        with_snapshot[1].state = expected;
        const exact_run = SavedRun{ .simulator_version = run.simulator_version, .options = options, .initial_state = initial, .decisions = &with_snapshot };
        try std.testing.expectEqualDeep(expected, try reconstruct(&duel, exact_run, 1));
        with_snapshot[1].state.?.tick += 1;
        try std.testing.expectError(error.InvalidDecisionSnapshot, reconstruct(&duel, exact_run, 1));
        try std.testing.expectError(error.UnknownDecision, reconstruct(&duel, run, 2));
    }
}

test "MCTS analysis reports unfinished samples separately and replays seeded continuations reproducibly" {
    var duel = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    const decisions = [_]Decision{.{ .tick = 0, .actions = .{ .{}, .{} } }};
    const run = SavedRun{
        .simulator_version = "mcts-simultaneous-v2-pets",
        .options = .{ .a = .warlock, .b = .warlock, .config = .{ .max_ticks = 12 }, .action_mask_a = 1, .action_mask_b = 1 },
        .initial_state = duel.snapshot(0),
        .decisions = @constCast(&decisions),
    };
    const first = try analyze(.warlock, .warlock, true, std.testing.allocator, run, 0, 3, 947, null, .{ .rollouts = 16, .workers = 1 });
    defer std.testing.allocator.free(first.results);
    const second = try analyze(.warlock, .warlock, true, std.testing.allocator, run, 0, 3, 947, null, .{ .rollouts = 16, .workers = 1 });
    defer std.testing.allocator.free(second.results);
    try std.testing.expectEqualDeep(first.results, second.results);
    try std.testing.expect(first.search_decisions > 0);
    try std.testing.expect(first.search_rollouts > 0);
    try std.testing.expectEqual(@as(usize, 16), first.continuation_search.rollouts);
    for (first.results) |result| {
        try std.testing.expectEqual(@as(u32, 3), result.unresolved);
        try std.testing.expectEqual(@as(u32, 0), result.wins + result.losses + result.draws);
        try std.testing.expectEqual(@as(f32, 0.5), result.score);
        try std.testing.expectEqual(@as(f32, 0), result.delta_vs_chosen);
    }
    try std.testing.expectError(error.InvalidSamples, analyze(.warlock, .warlock, true, std.testing.allocator, run, 0, 0, 947, null, .{ .rollouts = 16, .workers = 1 }));
}

test "analysis preserves search policy and increases budget without reducing aggregate tree capacity" {
    const original = mcts.Config{ .rollouts = 16384, .workers = 16, .nodes = 4096, .algorithm = .uct, .evaluator = .rollout, .boundary = .tick, .truncation_ticks = 77, .milliseconds = 50 };
    const config = try continuationConfig(original, .{}, null);
    try std.testing.expectEqual(@as(usize, 32768), config.rollouts);
    try std.testing.expectEqual(@as(usize, 2), config.workers);
    try std.testing.expect(config.nodes * config.workers >= original.nodes * original.workers);
    try std.testing.expectEqual(original.algorithm, config.algorithm);
    try std.testing.expectEqual(original.evaluator, config.evaluator);
    try std.testing.expectEqual(original.boundary, config.boundary);
    try std.testing.expectEqual(original.truncation_ticks, config.truncation_ticks);
    try std.testing.expectEqual(@as(u64, 0), config.milliseconds);
    try std.testing.expectError(error.InvalidAnalysisBudget, continuationConfig(original, .{ .workers = 0 }, null));
}

test "source verification distinguishes matching mismatched and legacy fights" {
    var run: SavedRun = .{
        .simulator_version = "mcts-simultaneous-v2-pets",
        .options = .{ .a = .warlock, .b = .warlock, .config = .{} },
        .initial_state = undefined,
        .decisions = &.{},
    };
    try std.testing.expect(!try verifyEngine(run));
    run.simulator_fingerprint = identity.fingerprint;
    try std.testing.expect(try verifyEngine(run));
    run.simulator_fingerprint = "different source";
    try std.testing.expectError(error.SimulatorSourceMismatch, verifyEngine(run));
}
