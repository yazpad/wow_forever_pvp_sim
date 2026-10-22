//! High-Throughput Alternating Neuroevolution Self-Play Runner (Fictitious Play / PSRO).
//! Alternates freezing Spec B to evolve Spec A, then freezing Spec A to evolve Spec B,
//! maintaining a Hall of Fame to prevent cyclical rock-paper-scissors amnesia.
const std = @import("std");
const mcts_main = @import("mcts_main.zig");
const neuro_policy = @import("neuro_policy.zig");
const neuro_evolution = @import("neuro_evolution.zig");
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;
const pets = @import("pets.zig");

const Policy = neuro_policy.Policy;
const Population = neuro_evolution.Population;
const HallOfFame = neuro_evolution.HallOfFame;

pub const ArenaOptions = struct {
    base: mcts_main.Options = .{
        .output = "matches/neuro_custom.lua",
    },
    fights_per_epoch: usize = 100_000,
    epochs: usize = 10,
    population_size: usize = 128,
    convergence_threshold: f32 = 0.02,
    output_weights: []const u8 = "matches/neuro_champion",
    output_replay: ?[]const u8 = null,
    /// When > 0, skip training and bulk-evaluate `--policy-a` vs `--policy-b` over this many fights.
    evaluate: usize = 0,
    /// Summary JSON path for `--evaluate` (default: `<output-weights>_eval.json`).
    output_eval: ?[]const u8 = null,
    jitter: neuro_evolution.Jitter = .{},
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var opts: ArenaOptions = .{};
    opts.base.config.workers = std.Thread.getCpuCount() catch 8;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(
                "neuro_arena [--spec-a warlock|frost_mage|priest] [--spec-b ...] [--fights-per-epoch 100000] [--epochs 10] [--population-size 128] [--workers 8] [--convergence-threshold 0.02] [--output-replay matches/neuro_custom.lua] [--output-weights matches/neuro_champion]\n" ++
                    "Bulk evaluation (no training): neuro_arena --evaluate 1000 --policy-a A.nepl --policy-b B.nepl [--seed N] [--jitter-start-lag SEC] [--jitter-pos YARDS] [--output-eval matches/neuro_champion_eval.json]\n",
            );
            return;
        }
        const value = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--evaluate")) {
            opts.evaluate = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--output-eval")) {
            opts.output_eval = value;
        } else if (std.mem.eql(u8, arg, "--jitter-start-lag")) {
            opts.jitter.start_lag = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, arg, "--jitter-pos")) {
            opts.jitter.pos = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, arg, "--fights-per-epoch")) {
            opts.fights_per_epoch = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--epochs")) {
            opts.epochs = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--population-size")) {
            opts.population_size = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--convergence-threshold")) {
            opts.convergence_threshold = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, arg, "--output-replay")) {
            opts.output_replay = value;
            opts.base.output = value;
        } else if (std.mem.eql(u8, arg, "--output-weights")) {
            opts.output_weights = value;
        } else if (!try mcts_main.applyOption(&opts.base, arg, value)) {
            return error.UnknownOption;
        }
    }

    try mcts_main.finalize(&opts.base);
    switch (opts.base.a) {
        inline else => |spec_a| switch (opts.base.b) {
            inline else => |spec_b| if (opts.evaluate > 0)
                try runEvaluate(spec_a, spec_b, opts)
            else
                try runArena(spec_a, spec_b, opts),
        },
    }
}

fn initBaseDuel(comptime a: Spec, comptime b: Spec, allocator: std.mem.Allocator, o: mcts_main.Options) !sim.Duel(a, b) {
    var d = try sim.Duel(a, b).init(allocator);
    errdefer d.deinit();
    d.staggerOpening();
    const state = d.arena.combat();
    state.distance[0] = o.distance;
    state.pos_x_a[0] = o.x_a orelse (-o.distance * 0.5);
    state.pos_y_a[0] = o.y_a orelse 0;
    state.pos_x_b[0] = o.x_b orelse (o.distance * 0.5);
    state.pos_y_b[0] = o.y_b orelse 0;
    state.hp_a[0] = o.hp_a;
    state.hp_b[0] = o.hp_b;
    const active_pet_a = if (a == .warlock and o.warlock_talents_a.demonic_sacrifice > 0 and o.warlock_talents_a.demonic_sacrifice_pet != 0 and o.warlock_talents_a.demonic_pact == 0) pets.Kind.none else o.pet_a.?;
    const active_pet_b = if (b == .warlock and o.warlock_talents_b.demonic_sacrifice > 0 and o.warlock_talents_b.demonic_sacrifice_pet != 0 and o.warlock_talents_b.demonic_pact == 0) pets.Kind.none else o.pet_b.?;
    const encoded_a = switch (a) {
        .warlock => o.warlock_talents_a.encode(),
        .priest => o.priest_talents_a.encode(),
        .frost_mage => 0,
    };
    const encoded_b = switch (b) {
        .warlock => o.warlock_talents_b.encode(),
        .priest => o.priest_talents_b.encode(),
        .frost_mage => 0,
    };
    d.setWarlockTalentRanksA(encoded_a);
    d.setWarlockTalentRanksB(encoded_b);
    pets.set(state, true, 0, active_pet_a);
    pets.set(state, false, 0, active_pet_b);
    d.setRace(true, o.race_a);
    d.setRace(false, o.race_b);
    try d.setCombatStats(true, o.combat_stats_a);
    try d.setCombatStats(false, o.combat_stats_b);
    state.mana_a[0] = state.max_mana_a[0];
    state.mana_b[0] = state.max_mana_b[0];
    state.hp_a[0] = if (o.hp_a_set) @min(o.hp_a, state.max_health_a[0]) else state.max_health_a[0];
    state.hp_b[0] = if (o.hp_b_set) @min(o.hp_b, state.max_health_b[0]) else state.max_health_b[0];
    d.setActionMaskA(o.action_mask_a);
    d.setActionMaskB(o.action_mask_b);
    return d;
}

fn WorkerContext(comptime a: Spec, comptime b: Spec) type {
    return struct {
        const Self = @This();
        duel: sim.Duel(a, b),
        base_snapshot: sim.Snapshot,
        max_ticks: u32,
        next_idx: *std.atomic.Value(usize),
        individuals: []neuro_evolution.Individual,
        batches_per_ind: usize,
        evolving_a: bool,
        hof: *const HallOfFame,
        epoch_seed: u64,

        pub fn run(self: *Self) void {
            while (true) {
                const idx = self.next_idx.fetchAdd(1, .monotonic);
                if (idx >= self.individuals.len) break;
                var ind = &self.individuals[idx];
                ind.resetStats();

                var prng = std.Random.DefaultPrng.init(self.epoch_seed ^ (@as(u64, idx) *% 0x9e3779b97f4a7c15));
                const rng = prng.random();

                for (0..self.batches_per_ind) |b_idx| {
                    const opp = self.hof.sampleOpponent(rng);
                    const pol_a = if (self.evolving_a) &ind.policy else opp;
                    const pol_b = if (self.evolving_a) opp else &ind.policy;
                    const batch_seed = self.epoch_seed ^ (@as(u64, idx) << 16) ^ @as(u64, b_idx);
                    const res = neuro_evolution.evaluateBatch16(
                        a,
                        b,
                        &self.duel,
                        self.base_snapshot,
                        pol_a,
                        pol_b,
                        self.evolving_a,
                        self.max_ticks,
                        batch_seed,
                    );
                    ind.fitness += res.fitness_sum;
                    ind.wins += res.wins;
                    ind.losses += res.losses;
                    ind.draws += res.draws;
                    ind.ticks += res.ticks;
                    ind.matches += res.matches;
                }

                if (ind.matches > 0) {
                    const denom = @as(f64, @floatFromInt(ind.matches));
                    ind.fitness /= denom;
                    ind.win_rate = (@as(f64, @floatFromInt(ind.wins)) + 0.5 * @as(f64, @floatFromInt(ind.draws))) / denom;
                }
            }
        }
    };
}

/// Scores one archived policy against every policy in the opponent archive.
/// Each matchup uses 16 seeded fights, making final selection independent of
/// which side happened to evolve last.
fn scoreAgainstArchive(
    comptime a: Spec,
    comptime b: Spec,
    duel: *sim.Duel(a, b),
    base_snapshot: sim.Snapshot,
    candidate: *const Policy,
    opponents: *const HallOfFame,
    candidate_is_a: bool,
    max_ticks: u32,
    seed: u64,
) f64 {
    if (opponents.len == 0) return -std.math.inf(f64);

    var total: f64 = 0.0;
    for (opponents.champions[0..opponents.len], 0..) |*opponent, idx| {
        const policy_a = if (candidate_is_a) candidate else opponent;
        const policy_b = if (candidate_is_a) opponent else candidate;
        const res = neuro_evolution.evaluateBatch16(
            a,
            b,
            duel,
            base_snapshot,
            policy_a,
            policy_b,
            candidate_is_a,
            max_ticks,
            seed ^ (@as(u64, idx) *% 0x9e3779b97f4a7c15),
        );
        total += res.fitness_sum / @as(f64, @floatFromInt(res.matches));
    }
    return total / @as(f64, @floatFromInt(opponents.len));
}

/// Measures a champion pair over 112 fights with small per-fight opening and
/// position variation. Seven SIMD batches keep this evaluation inexpensive.
fn evaluateJitteredPair(
    comptime a: Spec,
    comptime b: Spec,
    duel: *sim.Duel(a, b),
    base_snapshot: sim.Snapshot,
    policy_a: *const Policy,
    policy_b: *const Policy,
    max_ticks: u32,
    seed: u64,
) f64 {
    var wins_a: u64 = 0;
    var draws: u64 = 0;
    var matches: u64 = 0;
    for (0..7) |batch| {
        const res = neuro_evolution.evaluateBatch16Ex(
            a,
            b,
            duel,
            base_snapshot,
            policy_a,
            policy_b,
            true,
            max_ticks,
            seed ^ (@as(u64, batch) *% 0x9e3779b97f4a7c15),
            .{ .start_lag = 0.25, .pos = 1.0 },
            null,
        );
        wins_a += res.wins;
        draws += res.draws;
        matches += res.matches;
    }
    return (@as(f64, @floatFromInt(wins_a)) + 0.5 * @as(f64, @floatFromInt(draws))) /
        @as(f64, @floatFromInt(matches));
}

fn runArena(comptime a: Spec, comptime b: Spec, opts: ArenaOptions) !void {
    const allocator = std.heap.page_allocator;
    const pop_size = @max(8, opts.population_size);
    const workers = @max(1, @min(opts.base.config.workers, pop_size));
    // Use 2 SIMD batches (32 fights) per individual per generation so each epoch runs many generations!
    const batches_per_ind: usize = 2;
    const fights_per_gen = pop_size * batches_per_ind * 16;
    const gens_per_epoch = @max(4, (opts.fights_per_epoch + fights_per_gen - 1) / fights_per_gen);
    const actual_fights_per_epoch = fights_per_gen * gens_per_epoch;

    var base_duel = try initBaseDuel(a, b, allocator, opts.base);
    defer base_duel.deinit();
    const base_snapshot = base_duel.snapshot(0);

    var pop_a = try Population.init(allocator, pop_size, opts.base.config.seed ^ 0x1111_2222);
    defer pop_a.deinit();
    var pop_b = try Population.init(allocator, pop_size, opts.base.config.seed ^ 0x3333_4444);
    defer pop_b.deinit();

    var hof_a = HallOfFame.init();
    var hof_b = HallOfFame.init();

    var prng = std.Random.DefaultPrng.init(opts.base.config.seed ^ 0x5555_6666);
    const rng = prng.random();

    var champ_a = pop_a.individuals[0].policy;
    var champ_b = pop_b.individuals[0].policy;
    hof_a.add(champ_a);
    hof_b.add(champ_b);

    const WCtx = WorkerContext(a, b);
    var contexts = try allocator.alloc(WCtx, workers);
    defer allocator.free(contexts);
    for (0..workers) |w| {
        contexts[w] = .{
            .duel = try initBaseDuel(a, b, allocator, opts.base),
            .base_snapshot = base_snapshot,
            .max_ticks = opts.base.config.max_ticks,
            .next_idx = undefined,
            .individuals = undefined,
            .batches_per_ind = batches_per_ind,
            .evolving_a = true,
            .hof = &hof_b,
            .epoch_seed = 0,
        };
    }
    defer for (0..workers) |w| contexts[w].duel.deinit();

    var threads = try allocator.alloc(std.Thread, workers - 1);
    defer allocator.free(threads);

    const stdout = std.io.getStdOut().writer();
    const total_start = std.time.nanoTimestamp();

    var consecutive_converged: usize = 0;
    var epochs_completed: usize = 0;
    var total_generations: usize = 0;
    var converged = false;

    for (0..opts.epochs) |epoch| {
        if (opts.base.stop_file) |stop_path| {
            if (std.fs.cwd().access(stop_path, .{})) |_| break else |_| {}
        }

        const evolving_a = (epoch % 2 == 0);
        var active_pop = if (evolving_a) &pop_a else &pop_b;
        const opp_hof = if (evolving_a) &hof_b else &hof_a;
        const previous_champ = if (evolving_a) champ_a else champ_b;

        var best_ind: neuro_evolution.Individual = active_pop.individuals[0];

        for (0..gens_per_epoch) |gen| {
            const gen_t0 = std.time.nanoTimestamp();
            var next_idx = std.atomic.Value(usize).init(0);
            const gen_seed = opts.base.config.seed +% (@as(u64, epoch * 1024 + gen + 1) *% 0x9e3779b97f4a7c15);

            for (0..workers) |w| {
                contexts[w].next_idx = &next_idx;
                contexts[w].individuals = active_pop.individuals;
                contexts[w].evolving_a = evolving_a;
                contexts[w].hof = opp_hof;
                contexts[w].epoch_seed = gen_seed;
            }

            for (1..workers) |w| {
                threads[w - 1] = try std.Thread.spawn(.{}, WCtx.run, .{&contexts[w]});
            }
            contexts[0].run();
            for (1..workers) |w| {
                threads[w - 1].join();
            }

            active_pop.sortByFitness();
            best_ind = active_pop.best().*;
            var gen_ticks: u64 = 0;
            for (active_pop.individuals) |ind| gen_ticks += ind.ticks;
            total_generations += 1;

            if (evolving_a) {
                champ_a = best_ind.policy;
            } else {
                champ_b = best_ind.policy;
            }

            const pair_win_rate_a = evaluateJitteredPair(
                a,
                b,
                &base_duel,
                base_snapshot,
                &champ_a,
                &champ_b,
                opts.base.config.max_ticks,
                opts.base.config.seed ^ 0xc4a9 ^ @as(u64, total_generations),
            );
            const gen_sec = @max(1e-6, @as(f64, @floatFromInt(std.time.nanoTimestamp() - gen_t0)) / 1_000_000_000.0);
            const gen_fights_per_sec = @as(f64, @floatFromInt(fights_per_gen)) / gen_sec;
            const gen_ticks_per_sec = @as(f64, @floatFromInt(gen_ticks)) / gen_sec;
            const gen_avg_fight_sec = (@as(f64, @floatFromInt(gen_ticks)) / @as(f64, @floatFromInt(fights_per_gen))) * 0.01;
            const win_rate_a_est = if (evolving_a) best_ind.win_rate else (1.0 - best_ind.win_rate);
            try stdout.print(
                "NEURO_EPOCH epoch={d}/{d} gens={d} side={s} win_rate={d:.4} win_rate_a={d:.4} pair_wr_a={d:.4} pair_fights=112 fitness={d:.4} avg_fight_s={d:.2} fights_sec={d:.0} ticks_sec={d:.0}\n",
                .{
                    epoch + 1,
                    opts.epochs,
                    total_generations,
                    if (evolving_a) "A" else "B",
                    best_ind.win_rate,
                    win_rate_a_est,
                    pair_win_rate_a,
                    best_ind.fitness,
                    gen_avg_fight_sec,
                    gen_fights_per_sec,
                    gen_ticks_per_sec,
                },
            );

            if (gen + 1 < gens_per_epoch) {
                active_pop.evolveNextGeneration(epoch * gens_per_epoch + gen, rng);
            }
        }

        const convergence_seed = opts.base.config.seed ^ 0xc0ffee ^ @as(u64, epoch);
        const previous_archive_score = scoreAgainstArchive(
            a,
            b,
            &base_duel,
            base_snapshot,
            &previous_champ,
            opp_hof,
            evolving_a,
            opts.base.config.max_ticks,
            convergence_seed,
        );
        const candidate_archive_score = scoreAgainstArchive(
            a,
            b,
            &base_duel,
            base_snapshot,
            &best_ind.policy,
            opp_hof,
            evolving_a,
            opts.base.config.max_ticks,
            convergence_seed,
        );
        const delta = @abs(candidate_archive_score - previous_archive_score);

        if (evolving_a) {
            champ_a = best_ind.policy;
            hof_a.add(champ_a);
        } else {
            champ_b = best_ind.policy;
            hof_b.add(champ_b);
        }

        epochs_completed = epoch + 1;

        if (opts.convergence_threshold > 0.0 and epoch >= 4 and delta < opts.convergence_threshold) {
            consecutive_converged += 1;
            if (consecutive_converged >= 2) {
                converged = true;
                break;
            }
        } else {
            consecutive_converged = 0;
        }

        if (epoch + 1 < opts.epochs) {
            active_pop.evolveNextGeneration((epoch + 1) * gens_per_epoch, rng);
        }
    }

    // Select the final representatives by their average score against the
    // opposing archive, rather than keeping whichever policy trained last.
    var selected_a = hof_a.champions[0];
    var selected_b = hof_b.champions[0];
    var selected_score_a = -std.math.inf(f64);
    var selected_score_b = -std.math.inf(f64);
    for (hof_a.champions[0..hof_a.len]) |*candidate| {
        const score = scoreAgainstArchive(
            a,
            b,
            &base_duel,
            base_snapshot,
            candidate,
            &hof_b,
            true,
            opts.base.config.max_ticks,
            opts.base.config.seed ^ 0xa11ce,
        );
        if (score > selected_score_a) {
            selected_score_a = score;
            selected_a = candidate.*;
        }
    }
    for (hof_b.champions[0..hof_b.len]) |*candidate| {
        const score = scoreAgainstArchive(
            a,
            b,
            &base_duel,
            base_snapshot,
            candidate,
            &hof_a,
            false,
            opts.base.config.max_ticks,
            opts.base.config.seed ^ 0xb0b,
        );
        if (score > selected_score_b) {
            selected_score_b = score;
            selected_b = candidate.*;
        }
    }
    champ_a = selected_a;
    champ_b = selected_b;
    const final_pair_win_rate_a = evaluateJitteredPair(
        a,
        b,
        &base_duel,
        base_snapshot,
        &champ_a,
        &champ_b,
        opts.base.config.max_ticks,
        opts.base.config.seed ^ 0xf1a1,
    );

    // Save archive-selected representatives.
    const path_a = try std.fmt.allocPrint(allocator, "{s}_a.nepl", .{opts.output_weights});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, "{s}_b.nepl", .{opts.output_weights});
    defer allocator.free(path_b);
    try champ_a.saveFile(path_a);
    try champ_b.saveFile(path_b);

    // Evaluate head-to-head champion vs champion winrate over 320 matches (20 batches of 16)
    var h2h_wins_a: u64 = 0;
    var h2h_draws: u64 = 0;
    var h2h_matches: u64 = 0;
    for (0..20) |b_idx| {
        const res = neuro_evolution.evaluateBatch16(
            a,
            b,
            &base_duel,
            base_snapshot,
            &champ_a,
            &champ_b,
            true,
            opts.base.config.max_ticks,
            opts.base.config.seed ^ 0x7777_8888 ^ @as(u64, b_idx),
        );
        h2h_wins_a += res.wins;
        h2h_draws += res.draws;
        h2h_matches += res.matches;
    }
    const final_wr_a = (@as(f64, @floatFromInt(h2h_wins_a)) + 0.5 * @as(f64, @floatFromInt(h2h_draws))) / @as(f64, @floatFromInt(h2h_matches));
    const total_sec = @as(f64, @floatFromInt(std.time.nanoTimestamp() - total_start)) / 1_000_000_000.0;

    // Write summary telemetry JSON
    const summary_path = try std.fmt.allocPrint(allocator, "{s}.json", .{opts.output_weights});
    defer allocator.free(summary_path);
    if (std.fs.path.dirname(summary_path)) |dir| try std.fs.cwd().makePath(dir);
    {
        const sf = try std.fs.cwd().createFile(summary_path, .{});
        defer sf.close();
        var bw = std.io.bufferedWriter(sf.writer());
        const w = bw.writer();
        try std.json.stringify(.{
            .epochs_completed = epochs_completed,
            .max_epochs = opts.epochs,
            .generations_completed = total_generations,
            .converged = converged,
            .fights_per_epoch = actual_fights_per_epoch,
            .population_size = pop_size,
            .win_rate_a = final_wr_a,
            .win_rate_b = 1.0 - final_wr_a,
            .archive_score_a = selected_score_a,
            .archive_score_b = selected_score_b,
            .pair_win_rate_a = final_pair_win_rate_a,
            .total_seconds = total_sec,
            .policy_a = path_a,
            .policy_b = path_b,
        }, .{}, w);
        try w.writeAll("\n");
        try bw.flush();
    }

    try stdout.print(
        "NEURO_CONVERGED epochs={d} gens={d} converged={} win_rate_a={d:.4} pair_wr_a={d:.4} archive_score_a={d:.4} archive_score_b={d:.4} seconds={d:.2} policy_a={s} policy_b={s}\n",
        .{ epochs_completed, total_generations, converged, final_wr_a, final_pair_win_rate_a, selected_score_a, selected_score_b, total_sec, path_a, path_b },
    );

    // Generate final champion vs champion replay trajectory
    var replay_opts = opts.base;
    replay_opts.policy_a = path_a;
    replay_opts.policy_b = path_b;
    if (opts.output_replay) |rep| replay_opts.output = rep;
    try mcts_main.run(a, b, replay_opts);
}

// ---------------------------------------------------------------------------
// Bulk evaluation: N fights between two frozen policies (no training).
// ---------------------------------------------------------------------------

fn EvalContext(comptime a: Spec, comptime b: Spec) type {
    return struct {
        const Self = @This();
        duel: sim.Duel(a, b),
        base_snapshot: sim.Snapshot,
        max_ticks: u32,
        next_batch: *std.atomic.Value(usize),
        num_batches: usize,
        policy_a: *const Policy,
        policy_b: *const Policy,
        seed: u64,
        jitter: neuro_evolution.Jitter,
        outcomes: []neuro_evolution.LaneOutcome,

        pub fn run(self: *Self) void {
            while (true) {
                const idx = self.next_batch.fetchAdd(1, .monotonic);
                if (idx >= self.num_batches) break;
                const slot: *[16]neuro_evolution.LaneOutcome = self.outcomes[idx * 16 ..][0..16];
                _ = neuro_evolution.evaluateBatch16Ex(
                    a,
                    b,
                    &self.duel,
                    self.base_snapshot,
                    self.policy_a,
                    self.policy_b,
                    true,
                    self.max_ticks,
                    self.seed +% (@as(u64, idx) +% 1) *% 0x9e3779b97f4a7c15,
                    self.jitter,
                    slot,
                );
            }
        }
    };
}

fn runEvaluate(comptime a: Spec, comptime b: Spec, opts: ArenaOptions) !void {
    const allocator = std.heap.page_allocator;
    const path_a = opts.base.policy_a orelse return error.MissingPolicyA;
    const path_b = opts.base.policy_b orelse return error.MissingPolicyB;
    const policy_a = try Policy.loadFile(path_a);
    const policy_b = try Policy.loadFile(path_b);

    const fights = opts.evaluate;
    const num_batches = (fights + 15) / 16;
    const workers = @max(1, @min(opts.base.config.workers, num_batches));
    const max_ticks = opts.base.config.max_ticks;

    var base_duel = try initBaseDuel(a, b, allocator, opts.base);
    defer base_duel.deinit();
    const base_snapshot = base_duel.snapshot(0);

    const outcomes = try allocator.alloc(neuro_evolution.LaneOutcome, num_batches * 16);
    defer allocator.free(outcomes);

    var next_batch = std.atomic.Value(usize).init(0);
    const ECtx = EvalContext(a, b);
    const contexts = try allocator.alloc(ECtx, workers);
    defer allocator.free(contexts);
    var initialized: usize = 0;
    defer for (contexts[0..initialized]) |*c| c.duel.deinit();
    for (contexts) |*c| {
        c.* = .{
            .duel = try initBaseDuel(a, b, allocator, opts.base),
            .base_snapshot = base_snapshot,
            .max_ticks = max_ticks,
            .next_batch = &next_batch,
            .num_batches = num_batches,
            .policy_a = &policy_a,
            .policy_b = &policy_b,
            .seed = opts.base.config.seed ^ 0xe7a1_0000_0000,
            .jitter = opts.jitter,
            .outcomes = outcomes,
        };
        initialized += 1;
    }

    const t0 = std.time.nanoTimestamp();
    const threads = try allocator.alloc(std.Thread, workers - 1);
    defer allocator.free(threads);
    for (1..workers) |w| threads[w - 1] = try std.Thread.spawn(.{}, ECtx.run, .{&contexts[w]});
    contexts[0].run();
    for (threads) |t| t.join();
    const seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000_000.0;

    // Aggregate exactly `fights` outcomes (the last batch may overshoot).
    const used = outcomes[0..fights];
    var wins_a: u64 = 0;
    var wins_b: u64 = 0;
    var draws: u64 = 0;
    var timeouts: u64 = 0;
    var hp_sum_a_wins: f64 = 0;
    var hp_sum_b_wins: f64 = 0;
    var dur_sum_a_wins: f64 = 0;
    var dur_sum_b_wins: f64 = 0;
    const durations = try allocator.alloc(f32, fights);
    defer allocator.free(durations);
    var dur_sum: f64 = 0;
    for (used, 0..) |o, i| {
        const dur = @as(f32, @floatFromInt(o.finish_tick)) * 0.01;
        durations[i] = dur;
        dur_sum += dur;
        if (o.finish_tick >= max_ticks) timeouts += 1;
        if (o.reward_a > 0) {
            wins_a += 1;
            hp_sum_a_wins += o.hp_ratio_a;
            dur_sum_a_wins += dur;
        } else if (o.reward_a < 0) {
            wins_b += 1;
            hp_sum_b_wins += o.hp_ratio_b;
            dur_sum_b_wins += dur;
        } else draws += 1;
    }
    std.mem.sort(f32, durations, {}, std.sort.asc(f32));

    const n = @as(f64, @floatFromInt(fights));
    const win_rate_a = (@as(f64, @floatFromInt(wins_a)) + 0.5 * @as(f64, @floatFromInt(draws))) / n;
    const ci95 = 1.96 * @sqrt(@max(0.0, win_rate_a * (1.0 - win_rate_a)) / n);
    const safeDiv = struct {
        fn f(num: f64, den: u64) f64 {
            return if (den == 0) 0.0 else num / @as(f64, @floatFromInt(den));
        }
    }.f;
    const summary = .{
        .fights = fights,
        .wins_a = wins_a,
        .wins_b = wins_b,
        .draws = draws,
        .timeouts = timeouts,
        .win_rate_a = win_rate_a,
        .win_rate_b = 1.0 - win_rate_a,
        .ci95 = ci95,
        .avg_fight_s = dur_sum / n,
        .min_fight_s = durations[0],
        .median_fight_s = durations[fights / 2],
        .max_fight_s = durations[fights - 1],
        .avg_fight_s_a_wins = safeDiv(dur_sum_a_wins, wins_a),
        .avg_fight_s_b_wins = safeDiv(dur_sum_b_wins, wins_b),
        .avg_hp_left_a_wins = safeDiv(hp_sum_a_wins, wins_a),
        .avg_hp_left_b_wins = safeDiv(hp_sum_b_wins, wins_b),
        .jitter_start_lag = opts.jitter.start_lag,
        .jitter_pos = opts.jitter.pos,
        .seed = opts.base.config.seed,
        .seconds = seconds,
        .policy_a = path_a,
        .policy_b = path_b,
    };

    const default_eval = try std.fmt.allocPrint(allocator, "{s}_eval.json", .{opts.output_weights});
    defer allocator.free(default_eval);
    const eval_path = opts.output_eval orelse default_eval;
    if (std.fs.path.dirname(eval_path)) |dir| try std.fs.cwd().makePath(dir);
    {
        const f = try std.fs.cwd().createFile(eval_path, .{});
        defer f.close();
        var bw = std.io.bufferedWriter(f.writer());
        try std.json.stringify(summary, .{}, bw.writer());
        try bw.writer().writeAll("\n");
        try bw.flush();
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "NEURO_EVAL fights={d} wins_a={d} wins_b={d} draws={d} timeouts={d} win_rate_a={d:.4} ci95={d:.4} avg_fight_s={d:.2} min_fight_s={d:.2} median_fight_s={d:.2} max_fight_s={d:.2} avg_fight_s_a_wins={d:.2} avg_fight_s_b_wins={d:.2} avg_hp_left_a_wins={d:.4} avg_hp_left_b_wins={d:.4} seconds={d:.3} summary={s}\n",
        .{
            summary.fights,              summary.wins_a,             summary.wins_b,             summary.draws,
            summary.timeouts,            summary.win_rate_a,         summary.ci95,               summary.avg_fight_s,
            summary.min_fight_s,         summary.median_fight_s,     summary.max_fight_s,        summary.avg_fight_s_a_wins,
            summary.avg_fight_s_b_wins,  summary.avg_hp_left_a_wins, summary.avg_hp_left_b_wins, summary.seconds,
            eval_path,
        },
    );
}
