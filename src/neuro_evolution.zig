//! Evolutionary Population, Training Operators, Hall of Fame, and Batch Evaluation.
const std = @import("std");
const neuro_policy = @import("neuro_policy.zig");
const Policy = neuro_policy.Policy;
const ParamCount = neuro_policy.ParamCount;
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;

pub const MaxHallOfFame: usize = 32;

pub const Individual = struct {
    policy: Policy = .{},
    fitness: f64 = 0.0,
    win_rate: f64 = 0.0,
    wins: u64 = 0,
    losses: u64 = 0,
    draws: u64 = 0,
    ticks: u64 = 0,
    matches: u64 = 0,

    pub fn resetStats(self: *Individual) void {
        self.fitness = 0.0;
        self.win_rate = 0.0;
        self.wins = 0;
        self.losses = 0;
        self.draws = 0;
        self.ticks = 0;
        self.matches = 0;
    }
};

pub const HallOfFame = struct {
    champions: [MaxHallOfFame]Policy,
    len: usize = 0,

    pub fn init() HallOfFame {
        return .{ .champions = undefined, .len = 0 };
    }

    pub fn add(self: *HallOfFame, champion: Policy, rng: std.Random) void {
        if (self.len < MaxHallOfFame) {
            self.champions[self.len] = champion;
            self.len += 1;
        } else {
            const idx = rng.uintLessThan(usize, MaxHallOfFame);
            self.champions[idx] = champion;
        }
    }

    pub fn sampleOpponent(self: *const HallOfFame, current_champion: *const Policy, rng: std.Random) *const Policy {
        if (self.len == 0 or rng.float(f32) < 0.70) {
            return current_champion;
        }
        const idx = rng.uintLessThan(usize, self.len);
        return &self.champions[idx];
    }
};

pub const Population = struct {
    allocator: std.mem.Allocator,
    individuals: []Individual,
    scratch: []Policy,
    elite_count: usize,
    sigma_init: f32 = 0.16,
    sigma_decay: f32 = 0.985,

    pub fn init(allocator: std.mem.Allocator, size: usize, seed: u64) !Population {
        const pop_size = @max(4, size);
        const individuals = try allocator.alloc(Individual, pop_size);
        errdefer allocator.free(individuals);
        const scratch = try allocator.alloc(Policy, pop_size);
        errdefer allocator.free(scratch);

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        for (individuals, 0..) |*ind, i| {
            ind.* = .{
                // Keep index 0 at zero weights (pure tactical prior baseline) and initialize
                // others with small perturbations around the tactical prior.
                .policy = if (i == 0) Policy.initZero() else Policy.initRandom(rng, 0.25),
            };
        }

        const elite = @max(2, pop_size / 8);
        return .{
            .allocator = allocator,
            .individuals = individuals,
            .scratch = scratch,
            .elite_count = elite,
        };
    }

    pub fn deinit(self: *Population) void {
        self.allocator.free(self.individuals);
        self.allocator.free(self.scratch);
    }

    pub fn resetStats(self: *Population) void {
        for (self.individuals) |*ind| ind.resetStats();
    }

    /// Sorts individuals in descending order of fitness.
    pub fn sortByFitness(self: *Population) void {
        std.sort.insertion(Individual, self.individuals, {}, struct {
            fn lessThan(_: void, a: Individual, b: Individual) bool {
                return a.fitness > b.fitness;
            }
        }.lessThan);
    }

    pub fn best(self: *const Population) *const Individual {
        return &self.individuals[0];
    }

    /// Creates the next generation:
    /// 1. Preserves top `elite_count` unmutated.
    /// 2. Generates antithetic (+/-) sparse perturbations around the top elites.
    /// 3. Generates uniform crossover + sparse mutation offspring from the top parent pool.
    pub fn evolveNextGeneration(self: *Population, generation: usize, rng: std.Random) void {
        self.sortByFitness();
        const n = self.individuals.len;
        const elite = @min(self.elite_count, n);
        const parent_pool = @max(elite, n / 4);
        const sigma = @max(0.02, self.sigma_init * std.math.pow(f32, self.sigma_decay, @as(f32, @floatFromInt(generation))));

        for (0..elite) |i| {
            self.scratch[i] = self.individuals[i].policy;
        }

        var idx: usize = elite;
        // Antithetic mirrored pairs (+/- perturbation) around top elites for directional gradient climb
        const antithetic_end = @min(n, elite + (n - elite) / 2);
        while (idx + 1 < antithetic_end) : (idx += 2) {
            const p_idx = ((idx - elite) / 2) % elite;
            const base = self.individuals[p_idx].policy;
            var pos = base;
            var neg = base;
            for (0..ParamCount) |w_idx| {
                if (rng.float(f32) < 0.25) {
                    const delta = rng.floatNorm(f32) * sigma;
                    pos.params[w_idx] = std.math.clamp(base.params[w_idx] + delta, -4.0, 4.0);
                    neg.params[w_idx] = std.math.clamp(base.params[w_idx] - delta, -4.0, 4.0);
                }
            }
            self.scratch[idx] = pos;
            self.scratch[idx + 1] = neg;
        }

        // Remaining slots: tournament selection + uniform crossover + sparse Gaussian mutation
        while (idx < n) : (idx += 1) {
            var p1 = rng.uintLessThan(usize, parent_pool);
            for (0..2) |_| {
                const cand = rng.uintLessThan(usize, parent_pool);
                if (cand < p1) p1 = cand;
            }
            var p2 = rng.uintLessThan(usize, parent_pool);
            for (0..2) |_| {
                const cand = rng.uintLessThan(usize, parent_pool);
                if (cand < p2) p2 = cand;
            }
            var child = self.individuals[p1].policy;
            if (p1 != p2 and rng.float(f32) < 0.5) {
                const other = &self.individuals[p2].policy;
                for (0..ParamCount) |w_idx| {
                    if (rng.boolean()) child.params[w_idx] = other.params[w_idx];
                }
            }
            mutatePolicy(&child, sigma, rng);
            self.scratch[idx] = child;
        }

        for (0..n) |i| {
            self.individuals[i].policy = self.scratch[i];
            self.individuals[i].resetStats();
        }
    }
};

pub fn mutatePolicy(policy: *Policy, sigma: f32, rng: std.Random) void {
    for (&policy.params) |*w| {
        if (rng.float(f32) < 0.20) {
            w.* = std.math.clamp(w.* + rng.floatNorm(f32) * sigma, -4.0, 4.0);
        }
    }
}

pub const BatchResult = struct {
    fitness_sum: f64 = 0.0,
    wins: u64 = 0,
    losses: u64 = 0,
    draws: u64 = 0,
    ticks: u64 = 0,
    matches: u64 = 0,
};

/// Per-fight randomization of initial conditions (never touches stats).
pub const Jitter = struct {
    /// Max extra opening delay (seconds) added independently to each side's GCD / reaction timer.
    start_lag: f32 = 0.0,
    /// Max offset (yards) added independently to each fighter's x/y start position (pets follow).
    pos: f32 = 0.0,
};

/// Raw outcome of a single fight lane, used by bulk evaluation.
pub const LaneOutcome = struct {
    /// +1 = A won, -1 = B won, 0 = draw/timeout.
    reward_a: f32 = 0.0,
    finish_tick: u32 = 0,
    hp_ratio_a: f32 = 0.0,
    hp_ratio_b: f32 = 0.0,
};

fn applyJitter(state: anytype, jitter: Jitter, rng: std.Random) void {
    if (jitter.start_lag <= 0.0 and jitter.pos <= 0.0) return;
    for (0..16) |lane| {
        if (jitter.start_lag > 0.0) {
            const lag_a = rng.float(f32) * jitter.start_lag;
            const lag_b = rng.float(f32) * jitter.start_lag;
            state.gcd_a[lane] += lag_a;
            state.react_timer_a[lane] += lag_a;
            state.gcd_b[lane] += lag_b;
            state.react_timer_b[lane] += lag_b;
        }
        if (jitter.pos > 0.0) {
            const dxa = (rng.float(f32) * 2.0 - 1.0) * jitter.pos;
            const dya = (rng.float(f32) * 2.0 - 1.0) * jitter.pos;
            const dxb = (rng.float(f32) * 2.0 - 1.0) * jitter.pos;
            const dyb = (rng.float(f32) * 2.0 - 1.0) * jitter.pos;
            state.pos_x_a[lane] += dxa;
            state.pos_y_a[lane] += dya;
            state.pos_x_b[lane] += dxb;
            state.pos_y_b[lane] += dyb;
            state.pet_x_a[lane] += dxa;
            state.pet_y_a[lane] += dya;
            state.pet_x_b[lane] += dxb;
            state.pet_y_b[lane] += dyb;
            const dx = state.pos_x_b[lane] - state.pos_x_a[lane];
            const dy = state.pos_y_b[lane] - state.pos_y_a[lane];
            state.distance[lane] = @sqrt(dx * dx + dy * dy);
        }
    }
}

/// Evaluates 16 simultaneous fights in `duel` between `policy_a` and `policy_b`.
/// Returns stats from the perspective of `perspective_a` (true = Side A, false = Side B).
pub fn evaluateBatch16(
    comptime a: Spec,
    comptime b: Spec,
    duel: *sim.Duel(a, b),
    base_snapshot: sim.Snapshot,
    policy_a: *const Policy,
    policy_b: *const Policy,
    perspective_a: bool,
    max_ticks: u32,
    seed: u64,
) BatchResult {
    return evaluateBatch16Ex(a, b, duel, base_snapshot, policy_a, policy_b, perspective_a, max_ticks, seed, .{}, null);
}

/// Same as `evaluateBatch16`, with optional initial-condition jitter and per-lane outcome output.
pub fn evaluateBatch16Ex(
    comptime a: Spec,
    comptime b: Spec,
    duel: *sim.Duel(a, b),
    base_snapshot: sim.Snapshot,
    policy_a: *const Policy,
    policy_b: *const Policy,
    perspective_a: bool,
    max_ticks: u32,
    seed: u64,
    jitter: Jitter,
    lanes_out: ?*[16]LaneOutcome,
) BatchResult {
    duel.restoreAll(base_snapshot);
    const state = duel.arena.combat();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    applyJitter(state, jitter, rng);

    for (0..16) |lane| {
        const s1 = rng.int(u32) | 1;
        const s2 = rng.int(u32) | 1;
        state.spell_rng_a[lane] = s1;
        state.spell_rng_b[lane] = s2;
        state.pushback_rng_a[lane] = s1 ^ 0xc2b2ae35;
        state.pushback_rng_b[lane] = s2 ^ 0x27d4eb2f;
        state.pet_rng_a[lane] = s1 ^ 0x9e3779b9;
        state.pet_rng_b[lane] = s2 ^ 0x85ebca6b;
        state.conflagrate_rng_a[lane] = s1 ^ 0x1b873593;
        state.conflagrate_rng_b[lane] = s2 ^ 0xcc9e2d51;
    }

    var total_ticks: u64 = 0;
    var finish_tick: [16]u32 = @splat(max_ticks);
    var current_tick: u32 = 0;

    while (true) {
        const active_vec: @Vector(16, u32) = state.is_active[0..16].*;
        const active_count = @reduce(.Add, active_vec);
        if (active_count == 0) break;

        const ra = duel.readyTactical(true);
        const rb = duel.readyTactical(false);
        if (@reduce(.Or, ra) or @reduce(.Or, rb)) {
            const masks_a = duel.getActionMaskA(0);
            const masks_b = duel.getActionMaskB(0);
            // Low exploration noise during evaluation so policies execute crisp sequences
            const aa = if (@reduce(.Or, ra))
                policy_a.selectActions16(a, b, duel, true, ra, masks_a, 0.05, rng)
            else
                @as([16]sim.Action, @splat(.{}));
            const bb = if (@reduce(.Or, rb))
                policy_b.selectActions16(a, b, duel, false, rb, masks_b, 0.05, rng)
            else
                @as([16]sim.Action, @splat(.{}));
            duel.applyPreMasked(aa, bb, ra, rb, masks_a, masks_b);
        }

        duel.tick(max_ticks);
        current_tick += 1;
        total_ticks += active_count;
        for (0..16) |lane| {
            if (state.is_active[lane] == 0 and finish_tick[lane] == max_ticks) {
                finish_tick[lane] = current_tick;
            }
        }
    }

    var res: BatchResult = .{ .ticks = total_ticks, .matches = 16 };
    for (0..16) |lane| {
        const rw_a = duel.reward(lane);
        const rw = if (perspective_a) rw_a else -rw_a;
        if (rw > 0) {
            res.wins += 1;
        } else if (rw < 0) {
            res.losses += 1;
        } else {
            res.draws += 1;
        }

        const hp_ratio_a = @max(0.0, state.hp_a[lane]) / @max(1.0, state.max_health_a[lane]);
        const hp_ratio_b = @max(0.0, state.hp_b[lane]) / @max(1.0, state.max_health_b[lane]);
        const mana_ratio_a = @max(0.0, state.mana_a[lane]) / @max(1.0, state.max_mana_a[lane]);
        const mana_ratio_b = @max(0.0, state.mana_b[lane]) / @max(1.0, state.max_mana_b[lane]);
        if (lanes_out) |out| out[lane] = .{
            .reward_a = rw_a,
            .finish_tick = finish_tick[lane],
            .hp_ratio_a = hp_ratio_a,
            .hp_ratio_b = hp_ratio_b,
        };

        // Reward winning decisively (remaining HP/mana + faster kills when winning, surviving longer when losing)
        const time_bonus = (1.0 - @as(f32, @floatFromInt(finish_tick[lane])) / @as(f32, @floatFromInt(@max(1, max_ticks)))) * 0.15;
        const speed_term = if (rw > 0) time_bonus else if (rw < 0) -time_bonus else 0.0;
        const margin_a = 0.25 * (hp_ratio_a - hp_ratio_b) + 0.05 * (mana_ratio_a - mana_ratio_b);
        const margin = (if (perspective_a) margin_a else -margin_a) + speed_term;
        res.fitness_sum += @as(f64, rw + margin);
    }
    return res;
}

test "neuro_evolution population and batch evaluation" {
    var pop = try Population.init(std.testing.allocator, 8, 123);
    defer pop.deinit();

    var duel = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer duel.deinit();
    duel.staggerOpening();
    const snap = duel.snapshot(0);

    const opp = Policy.initZero();
    const res = evaluateBatch16(.warlock, .frost_mage, &duel, snap, &pop.individuals[0].policy, &opp, true, 1000, 999);
    try std.testing.expectEqual(@as(u64, 16), res.matches);
    try std.testing.expectEqual(@as(u64, 16), res.wins + res.losses + res.draws);
}
