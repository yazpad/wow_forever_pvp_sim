//! Root-parallel simultaneous-move MCTS; terminal continuations in 16 SIMD lanes.
const std = @import("std");
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;
const WarlockActionCount = @import("combat_spec.zig").WarlockAction.COUNT;
const MaxChoices = @import("action_catalog_generated.zig").MaxChoices;
pub const Algorithm = enum { exp3, uct, puct };
pub const EvaluatorType = enum { rollout, heuristic, learned };
const learned = @import("learned_value.zig");
pub const BoundaryMode = enum { tick, event };
const neuro_policy = @import("neuro_policy.zig");
pub const Config = struct {
    model: ?*const learned.Bundle = null,
    policy_a: ?*const neuro_policy.Policy = null,
    policy_b: ?*const neuro_policy.Policy = null,
    learned_mix: f32 = 0.5,
    rollouts: usize = 1024,
    workers: usize = 1,
    nodes: usize = 4096,
    depth: usize = 128,
    memory_limit: usize = 512 * 1024 * 1024,
    stop_file: ?[]const u8 = null,
    seed: u64 = 1,
    max_ticks: u32 = 6000,
    milliseconds: u64 = 0,
    algorithm: Algorithm = .puct,
    random_rollout: bool = false,
    evaluator: EvaluatorType = .rollout,
    c_puct: f32 = 1.414,
    truncation_ticks: u32 = 30,
    boundary: BoundaryMode = .event,
};
const none = std.math.maxInt(u32);
pub const Bandit = struct {
    weights: [MaxChoices]f32 = @splat(0),
    sums: [MaxChoices]f32 = @splat(0),
    visits: [MaxChoices]u32 = @splat(0),
    priors: [MaxChoices]f32 = @splat(0),
    strategy: [MaxChoices]f64 = @splat(0),
    total: u32 = 0,
    pub fn initPriors(self: *Bandit, n: usize, p: [MaxChoices]f32) void {
        var sum: f32 = 0;
        for (0..n) |i| sum += p[i];
        if (sum > 0) {
            for (0..n) |i| self.priors[i] = p[i] / sum;
        } else {
            const uniform = 1.0 / @as(f32, @floatFromInt(n));
            for (0..n) |i| self.priors[i] = uniform;
        }
    }
    pub fn distribution(self: *const Bandit, n: usize, algo: Algorithm, c_puct: f32) [MaxChoices]f32 {
        var p: [MaxChoices]f32 = @splat(0);
        if (algo == .puct) {
            var best: f32 = -std.math.inf(f32);
            var selected: usize = 0;
            const sqrt_n = @sqrt(@as(f32, @floatFromInt(self.total + 1)));
            for (0..n) |i| {
                const q = if (self.visits[i] == 0) 0 else self.sums[i] / @as(f32, @floatFromInt(self.visits[i]));
                const prior = if (self.priors[i] > 0) self.priors[i] else 1.0 / @as(f32, @floatFromInt(n));
                const u = c_puct * prior * (sqrt_n / @as(f32, @floatFromInt(1 + self.visits[i])));
                const score = q + u;
                if (score > best) {
                    best = score;
                    selected = i;
                }
            }
            p[selected] = 1;
            return p;
        }
        if (algo == .uct) {
            var best: f32 = -std.math.inf(f32);
            var selected: usize = 0;
            for (0..n) |i| {
                const score = if (self.visits[i] == 0) std.math.inf(f32) else self.sums[i] / @as(f32, @floatFromInt(self.visits[i])) + @sqrt(2 * @log(@as(f32, @floatFromInt(self.total + 1))) / @as(f32, @floatFromInt(self.visits[i])));
                if (score > best) {
                    best = score;
                    selected = i;
                }
            }
            p[selected] = 1;
            return p;
        }
        var largest: f32 = -std.math.inf(f32);
        for (0..n) |i| largest = @max(largest, self.weights[i]);
        var sum: f32 = 0;
        for (0..n) |i| {
            p[i] = @exp(self.weights[i] - largest);
            sum += p[i];
        }
        for (0..n) |i| p[i] = 0.9 * p[i] / sum + 0.1 / @as(f32, @floatFromInt(n));
        return p;
    }
    pub fn update(self: *Bandit, n: usize, action: usize, probability: f32, reward: f32, algo: Algorithm) void {
        self.total += 1;
        self.visits[action] += 1;
        self.sums[action] += reward;
        if (algo == .exp3) {
            self.weights[action] += 0.1 / @as(f32, @floatFromInt(n)) * ((reward + 1) * 0.5) / @max(probability, 0.000001);
            // Normalize log weights to avoid long-run growth.
            const shift = self.weights[action];
            if (shift > 100) for (0..n) |i| {
                self.weights[i] -= shift;
            };
        }
    }
};
pub fn sample(p: [MaxChoices]f32, n: usize, random: std.Random) u8 {
    var x = random.float(f32);
    for (0..n) |i| {
        x -= p[i];
        if (x <= 0) return @intCast(i);
    }
    return @intCast(n - 1);
}
const Node = struct {
    bandits: [2]Bandit = .{ .{}, .{} },
    choices: [2]sim.Choices,
    first: u32 = none,
    next: u32 = none,
    joint: u16 = 0,
};
const Visit = struct { node: u32, actions: [2]u8, probabilities: [2]f32 };
pub const Stats = struct {
    rollouts: u64 = 0,
    ticks: u64 = 0,
    vector_ticks: u64 = 0,
    nodes: u64 = 0,
    depth: u32 = 0,
    pub fn add(self: *Stats, other: Stats) void {
        self.rollouts += other.rollouts;
        self.ticks += other.ticks;
        self.vector_ticks += other.vector_ticks;
        self.nodes += other.nodes;
        self.depth = @max(self.depth, other.depth);
    }
};
pub fn Search(comptime a: Spec, comptime b: Spec) type {
    return struct {
        const Self = @This();
        const Duel = sim.Duel(a, b);
        const StateSnapshot = sim.SnapshotFor(a, b);
        const Worker = struct {
            duel: Duel,
            nodes: []Node,
            paths: []Visit,
            used: u32 = 0,
            rng: std.Random.DefaultPrng,
            stats: Stats = .{},
            fn run(w: *Worker, root: StateSnapshot, config: Config, budget: usize, deadline: i128) void {
                w.used = 1;
                w.stats = .{};
                w.duel.restoreAll(root);
                const root_ca = if (config.boundary == .event)
                    w.duel.choicesTactical(true, 0, w.duel.getActionMaskA(0))
                else
                    w.duel.choices(true, 0, w.duel.getActionMaskA(0));
                const root_cb = if (config.boundary == .event)
                    w.duel.choicesTactical(false, 0, w.duel.getActionMaskB(0))
                else
                    w.duel.choices(false, 0, w.duel.getActionMaskB(0));
                w.nodes[0] = .{ .choices = .{ root_ca, root_cb } };
                if (config.algorithm == .puct) {
                    w.nodes[0].bandits[0].initPriors(root_ca.len, computePriors(a, true, &w.duel, 0, root_ca));
                    w.nodes[0].bandits[1].initPriors(root_cb.len, computePriors(b, false, &w.duel, 0, root_cb));
                }
                const random = w.rng.random();
                var batch_idx: usize = 0;
                while (w.stats.rollouts < budget and (deadline == 0 or std.time.nanoTimestamp() < deadline)) : (batch_idx += 1) {
                    if (config.stop_file) |path| {
                        if ((batch_idx & 31) == 0) {
                            if (std.fs.cwd().access(path, .{})) |_| break else |_| {}
                        }
                    }
                    const count = @min(16, budget - w.stats.rollouts);
                    var current: [16]u32 = @splat(0);
                    var pending: [16]u16 = @splat(0);
                    var lens: [16]usize = @splat(0);
                    var leaf: [16]bool = @splat(false);
                    var leaf_ticks: [16]u32 = @splat(0);
                    var leaf_evaluated: [16]bool = @splat(false);
                    var leaf_values: [16]f32 = @splat(0);
                    if (batch_idx > 0) w.duel.restoreAll(root);
                    if (count < 16) {
                        for (count..16) |i| w.duel.arena.combat().is_active[i] = 0;
                    }
                    while (true) {
                        const state = w.duel.arena.combat();
                        var alive: usize = 0;
                        for (0..count) |i| {
                            if (state.is_active[i] != 0) alive += 1;
                        }
                        if (alive == 0) break;
                        const ra = if (config.boundary == .event) w.duel.readyTactical(true) else w.duel.ready(true);
                        const rb = if (config.boundary == .event) w.duel.readyTactical(false) else w.duel.ready(false);
                        if (@reduce(.Or, ra) or @reduce(.Or, rb)) {
                            const masks_a = w.duel.getActionMaskA(0);
                            const masks_b = w.duel.getActionMaskB(0);
                            var aa: [16]sim.Action = @splat(.{});
                            var bb: [16]sim.Action = @splat(.{});
                            for (0..count) |i| {
                                if (state.is_active[i] == 0 or (!ra[i] and !rb[i])) continue;
                                if (leaf[i]) {
                                    if (ra[i]) aa[i] = rolloutFast(a, true, &w.duel, i, masks_a, random, config.random_rollout, config.policy_a);
                                    if (rb[i]) bb[i] = rolloutFast(b, false, &w.duel, i, masks_b, random, config.random_rollout, config.policy_b);
                                    continue;
                                }
                                if (lens[i] > 0) {
                                    const parent = current[i];
                                    var child = w.nodes[parent].first;
                                    while (child != none and w.nodes[child].joint != pending[i]) child = w.nodes[child].next;
                                    if (child == none) {
                                        if (w.used < w.nodes.len) {
                                            const ca = if (config.boundary == .event) w.duel.choicesTactical(true, i, masks_a) else w.duel.choices(true, i, masks_a);
                                            const cb = if (config.boundary == .event) w.duel.choicesTactical(false, i, masks_b) else w.duel.choices(false, i, masks_b);
                                            child = w.used;
                                            w.used += 1;
                                            var new_node: Node = .{ .choices = .{ ca, cb }, .joint = pending[i], .next = w.nodes[parent].first };
                                            if (config.algorithm == .puct) {
                                                new_node.bandits[0].initPriors(ca.len, computePriors(a, true, &w.duel, i, ca));
                                                new_node.bandits[1].initPriors(cb.len, computePriors(b, false, &w.duel, i, cb));
                                            }
                                            w.nodes[child] = new_node;
                                            w.nodes[parent].first = child;
                                        }
                                        leaf[i] = true;
                                        if (config.evaluator != .rollout and config.truncation_ticks == 0) {
                                            leaf_evaluated[i] = true;
                                            leaf_values[i] = evaluateLeaf(a, b, &w.duel, i, config);
                                        }
                                    } else current[i] = child;
                                }
                                if (!leaf[i] and lens[i] < config.depth) {
                                    const node = &w.nodes[current[i]];
                                    const ca = &node.choices[0];
                                    const cb = &node.choices[1];
                                    const pa = node.bandits[0].distribution(ca.len, config.algorithm, config.c_puct);
                                    const pb = node.bandits[1].distribution(cb.len, config.algorithm, config.c_puct);
                                    const ia = sample(pa, ca.len, random);
                                    const ib = sample(pb, cb.len, random);
                                    if (config.algorithm == .exp3) {
                                        for (0..ca.len) |k| node.bandits[0].strategy[k] += pa[k];
                                        for (0..cb.len) |k| node.bandits[1].strategy[k] += pb[k];
                                    } else {
                                        node.bandits[0].strategy[ia] += 1.0;
                                        node.bandits[1].strategy[ib] += 1.0;
                                        // Reserve visits until this batch completes so UCT / PUCT does not
                                        // select the same unvisited action in all sixteen lanes.
                                        node.bandits[0].visits[ia] += 1;
                                        node.bandits[0].total += 1;
                                        node.bandits[1].visits[ib] += 1;
                                        node.bandits[1].total += 1;
                                    }
                                    aa[i] = ca.items[ia];
                                    bb[i] = cb.items[ib];
                                    w.paths[i * config.depth + lens[i]] = .{ .node = current[i], .actions = .{ ia, ib }, .probabilities = .{ pa[ia], pb[ib] } };
                                    lens[i] += 1;
                                    pending[i] = @intCast(ia * MaxChoices + ib);
                                } else {
                                    if (!leaf[i]) leaf[i] = true;
                                    if (ra[i]) aa[i] = rolloutFast(a, true, &w.duel, i, masks_a, random, config.random_rollout, config.policy_a);
                                    if (rb[i]) bb[i] = rolloutFast(b, false, &w.duel, i, masks_b, random, config.random_rollout, config.policy_b);
                                }
                            }
                            w.duel.applyPreMasked(aa, bb, ra, rb, masks_a, masks_b);
                        }
                        w.duel.tick(config.max_ticks);
                        w.stats.ticks += alive;
                        w.stats.vector_ticks += 1;

                        for (0..count) |i| {
                            if (leaf[i] and !leaf_evaluated[i] and config.evaluator != .rollout) {
                                leaf_ticks[i] += 1;
                                if (leaf_ticks[i] >= config.truncation_ticks or state.hp_a[i] <= 0 or state.hp_b[i] <= 0) {
                                    leaf_evaluated[i] = true;
                                    leaf_values[i] = evaluateLeaf(a, b, &w.duel, i, config);
                                    state.is_active[i] = 0;
                                }
                            }
                        }
                    }
                    for (0..count) |i| {
                        const reward = if (leaf_evaluated[i]) leaf_values[i] else w.duel.reward(i);
                        for (w.paths[i * config.depth ..][0..lens[i]]) |v| {
                            const node = &w.nodes[v.node];
                            for (0..2) |s| {
                                if (config.algorithm == .uct or config.algorithm == .puct) {
                                    node.bandits[s].visits[v.actions[s]] -= 1;
                                    node.bandits[s].total -= 1;
                                }
                                node.bandits[s].update(node.choices[s].len, v.actions[s], v.probabilities[s], if (s == 0) reward else -reward, config.algorithm);
                            }
                        }
                        w.stats.depth = @max(w.stats.depth, @as(u32, @intCast(lens[i])));
                    }
                    w.stats.rollouts += count;
                }
                w.stats.nodes = w.used;
            }
        };
        allocator: std.mem.Allocator,
        config: Config,
        workers: []Worker,
        pool: std.Thread.Pool,
        pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
            if (config.evaluator == .learned and config.model == null) return error.MissingLearnedModel;
            if (!std.math.isFinite(config.learned_mix) or config.learned_mix < 0 or config.learned_mix > 1) return error.InvalidLearnedMix;
            if (config.workers == 0 or config.depth == 0 or config.nodes == 0 or config.rollouts == 0 or config.max_ticks == 0) return error.InvalidSearchConfig;
            const node_bytes = try std.math.mul(usize, config.nodes, @sizeOf(Node));
            const path_bytes = try std.math.mul(usize, config.depth, 16 * @sizeOf(Visit));
            const worker_bytes = try std.math.add(usize, try std.math.add(usize, node_bytes, path_bytes), 3 * 16 * (@sizeOf(StateSnapshot) - 4));
            const required = try std.math.mul(usize, worker_bytes, config.workers);
            if (required > config.memory_limit) return error.SearchMemoryLimitExceeded;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .config = config, .workers = try allocator.alloc(Worker, config.workers), .pool = undefined };
            errdefer allocator.free(self.workers);
            var initialized: usize = 0;
            errdefer for (self.workers[0..initialized]) |*w| {
                w.duel.deinit();
                allocator.free(w.nodes);
                allocator.free(w.paths);
            };
            for (self.workers, 0..) |*w, i| {
                var duel = try Duel.init(allocator);
                errdefer duel.deinit();
                const nodes = try allocator.alloc(Node, config.nodes);
                errdefer allocator.free(nodes);
                const paths = try allocator.alloc(Visit, 16 * config.depth);
                w.* = .{ .duel = duel, .nodes = nodes, .paths = paths, .rng = std.Random.DefaultPrng.init(config.seed +% (@as(u64, @intCast(i)) *% 0x9e3779b97f4a7c15)) };
                initialized += 1;
            }
            try self.pool.init(.{ .allocator = allocator, .n_jobs = @intCast(config.workers) });
            return self;
        }
        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            for (self.workers) |*w| {
                w.duel.deinit();
                self.allocator.free(w.nodes);
                self.allocator.free(w.paths);
            }
            self.allocator.free(self.workers);
            self.allocator.destroy(self);
        }
        /// Restart continuation RNGs without reallocating worker trees or threads.
        pub fn reseed(self: *Self, seed: u64) void {
            self.config.seed = seed;
            for (self.workers, 0..) |*worker, i| {
                worker.rng = std.Random.DefaultPrng.init(seed +% (@as(u64, @intCast(i)) *% 0x9e3779b97f4a7c15));
            }
        }
        pub fn setWarriorConfig(self: *Self, comptime side: bool, config: @import("warrior_arena.zig").Config) !void {
            for (self.workers) |*worker| try worker.duel.setWarriorConfig(side, config);
        }
        pub fn setWarlockTalentRanksA(self: *Self, encoded: u128) void {
            for (self.workers) |*worker| worker.duel.setWarlockTalentRanksA(encoded);
        }
        pub fn setWarlockTalentRanksB(self: *Self, encoded: u128) void {
            for (self.workers) |*worker| worker.duel.setWarlockTalentRanksB(encoded);
        }
        pub fn setActionMaskA(self: *Self, mask: u32) void {
            for (self.workers) |*worker| worker.duel.setActionMaskA(mask);
        }
        pub fn setActionMaskB(self: *Self, mask: u32) void {
            for (self.workers) |*worker| worker.duel.setActionMaskB(mask);
        }
        pub const Result = struct { actions: [2]sim.Action, distributions: [2][MaxChoices]f32, choices: [2]sim.Choices, stats: Stats, seconds: f64 };
        pub fn decide(self: *Self, root: StateSnapshot, random: std.Random) Result {
            const start = std.time.nanoTimestamp();
            // No game-theoretic decision exists when both actions are forced.
            // Preserve committed-RNG consumption, but spend no search budget.
            const scout = &self.workers[0].duel;
            scout.restore(0, root);
            const forced_choices = if (self.config.boundary == .event)
                [2]sim.Choices{ scout.choicesTactical(true, 0, scout.getActionMaskA(0)), scout.choicesTactical(false, 0, scout.getActionMaskB(0)) }
            else
                [2]sim.Choices{ scout.choices(true, 0, scout.getActionMaskA(0)), scout.choices(false, 0, scout.getActionMaskB(0)) };
            if (forced_choices[0].len == 1 and forced_choices[1].len == 1) {
                var p: [MaxChoices]f32 = @splat(0);
                p[0] = 1;
                _ = sample(p, 1, random);
                _ = sample(p, 1, random);
                return .{ .actions = .{ forced_choices[0].items[0], forced_choices[1].items[0] }, .distributions = .{ p, p }, .choices = forced_choices, .stats = .{}, .seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) / std.time.ns_per_s };
            }
            const deadline = if (self.config.milliseconds == 0) 0 else start + @as(i128, self.config.milliseconds) * std.time.ns_per_ms;
            var wg: std.Thread.WaitGroup = .{};
            for (self.workers, 0..) |*w, i| {
                const budget = self.config.rollouts / self.workers.len + @intFromBool(i < self.config.rollouts % self.workers.len);
                self.pool.spawnWg(&wg, Worker.run, .{ w, root, self.config, budget, deadline });
            }
            wg.wait();
            var result: Result = .{ .actions = undefined, .distributions = .{ @splat(0), @splat(0) }, .choices = self.workers[0].nodes[0].choices, .stats = .{}, .seconds = 0 };
            // Visit-weighted empirical marginal strategies. No equilibrium claim.
            for (self.workers) |*w| {
                result.stats.add(w.stats);
                for (0..2) |s| for (0..result.choices[s].len) |i| {
                    result.distributions[s][i] += @floatCast(w.nodes[0].bandits[s].strategy[i]);
                };
            }
            for (0..2) |s| {
                var total: f32 = 0;
                for (result.distributions[s]) |p| total += p;
                for (0..result.choices[s].len) |i| result.distributions[s][i] = if (total > 0) result.distributions[s][i] / total else 1 / @as(f32, @floatFromInt(result.choices[s].len));
                // Root decision: commit to argmax of the search distribution for competitive play.
                var best_idx: usize = 0;
                var best_prob: f32 = -1.0;
                for (0..result.choices[s].len) |i| {
                    if (result.distributions[s][i] > best_prob) {
                        best_prob = result.distributions[s][i];
                        best_idx = i;
                    }
                }
                result.actions[s] = result.choices[s].items[best_idx];
            }
            result.seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) / std.time.ns_per_s;
            return result;
        }
        pub fn memoryBytes(self: *Self) usize {
            return self.workers.len * (self.config.nodes * @sizeOf(Node) + 16 * self.config.depth * @sizeOf(Visit) + 3 * 16 * (@sizeOf(StateSnapshot) - 4));
        }
    };
}
pub fn rollout(comptime spec: Spec, comptime side: bool, d: anytype, lane: usize, c: sim.Choices, random: std.Random, random_only: bool) sim.Action {
    _ = c;
    return rolloutFast(spec, side, d, lane, if (side) d.getActionMaskA(0) else d.getActionMaskB(0), random, random_only, null);
}
pub fn rolloutFast(comptime spec: Spec, comptime side: bool, d: anytype, lane: usize, masks: [WarlockActionCount]@Vector(16, bool), random: std.Random, random_only: bool, policy: ?*const neuro_policy.Policy) sim.Action {
    if (policy) |pol| {
        // Evaluate the neuro-evolved policy on this lane.
        // selectActions16 expects comptime spec_a, spec_b.
        const a = @TypeOf(d.*).SpecA;
        const b = @TypeOf(d.*).SpecB;
        var ready_lane: @Vector(16, bool) = @splat(false);
        ready_lane[lane] = true;
        const actions = pol.selectActions16(a, b, d, side, ready_lane, masks, 0.0, random);
        return actions[lane];
    }
    const s = d.arena.combat();
    const own = if (side) "_a" else "_b";
    const enemy = if (side) "_b" else "_a";
    var id: u32 = 0;
    // Deterministic, inexpensive continuation; 5% exploration avoids one fixed script.
    if (random_only or (@field(s, "cast_id" ++ own)[lane] == 0 and random.float(f32) < 0.05)) {
        const c = d.choices(side, lane, masks);
        return c.items[random.uintLessThan(u8, c.len)];
    }
    const hp = @field(s, "hp" ++ own)[lane];
    // Put instant DoTs (Corruption 2, Agony 1, Siphon Life 8) as highest offensive priorities at opening.
    const priorities = switch (spec) {
        .warlock => &[_]u32{ 19, 17, 18, 15, 9, 16, 2, 1, 8, 7, 6, 13, 12, 5, 4, 3 },
        .frost_mage => &[_]u32{ 19, 17, 18, 6, 7, 2, 1, 4, 3, 5 },
        .warrior => &[_]u32{ 2, 1 },
        .priest => &[_]u32{ 25, 19, 20, 17, 18, 16, 22, 7, 6, 3, 21, 23, 9, 2, 8, 1, 12, 11, 24, 15, 4, 13, 5, 14 },
    };
    for (priorities) |candidate| {
        var allowed = true;
        if (spec == .warlock) {
            allowed = switch (candidate) {
                19 => if ((if (side) @TypeOf(d.arena).SpecB else @TypeOf(d.arena).SpecA) == .frost_mage) @field(s, "agony_timer" ++ own)[lane] > 0 or @field(s, "corruption_timer" ++ own)[lane] > 0 else false,
                6 => hp < 800,
                7 => hp < 1600,
                2 => @field(s, "corruption_timer" ++ enemy)[lane] < 1.0,
                1 => @field(s, "agony_timer" ++ enemy)[lane] < 1.0,
                8 => @field(s, "siphon_timer" ++ enemy)[lane] < 1.0,
                9 => @field(s, "hp" ++ enemy)[lane] < 500,
                13 => @field(s, "immolate_timer" ++ enemy)[lane] < 1.0,
                5 => hp < 1400,
                15 => @field(s, "cast_id" ++ enemy)[lane] != 0,
                else => true,
            };
        } else if (spec == .priest) {
            const max_hp = @field(s, "max_health" ++ own)[lane];
            const enemy_hp = @field(s, "hp" ++ enemy)[lane];
            allowed = switch (candidate) {
                19 => if ((if (side) @TypeOf(d.arena).SpecB else @TypeOf(d.arena).SpecA) == .frost_mage) @field(s, "agony_timer" ++ own)[lane] > 0 or @field(s, "corruption_timer" ++ own)[lane] > 0 else false,
                20 => @field(s, "fear_timer" ++ own)[lane] > 0 or @field(s, "seduction_timer" ++ own)[lane] > 0,
                // Burn meaningfully into a caster's remaining pool, without
                // displacing urgent healing or wasting a long cast on scraps.
                24 => hp >= max_hp * 0.55 and enemy_hp > 600 and
                    @field(s, "mana" ++ enemy)[lane] >= 384 and @field(s, "mana" ++ enemy)[lane] <= 1534,
                7 => @field(s, "cast_id" ++ enemy)[lane] != 0,
                6 => @field(s, "action6_dur" ++ own)[lane] <= 0 and hp < max_hp * 0.90,
                3 => s.distance[lane] <= 8.0 and @field(s, "fear_timer" ++ enemy)[lane] <= 0,
                9 => enemy_hp < 600 or hp > 1000,
                2 => @field(s, "corruption_timer" ++ enemy)[lane] < 1.0,
                8 => @field(s, "siphon_timer" ++ enemy)[lane] < 1.0,
                1 => @field(s, "agony_timer" ++ enemy)[lane] < 1.0,
                12 => @field(s, "shadow_lockout" ++ own)[lane] < 1.0 and hp < max_hp * 0.85,
                13 => @field(s, "immolate_timer" ++ enemy)[lane] < 1.0,
                11 => hp < max_hp * 0.55,
                else => true,
            };
        } else if (spec == .warrior) {
            allowed = switch (candidate) {
                1 => d.arena.warrior.floats(side, .rage, 0).*[lane] >= 30,
                2 => d.arena.warrior.floats(side, .hamstring, 0).*[lane] < 1,
                else => true,
            };
        } else allowed = switch (candidate) {
            19 => if ((if (side) @TypeOf(d.arena).SpecB else @TypeOf(d.arena).SpecA) == .frost_mage) @field(s, "agony_timer" ++ own)[lane] > 0 or @field(s, "corruption_timer" ++ own)[lane] > 0 else false,
            7 => @field(s, "cast_id" ++ enemy)[lane] != 0,
            2 => s.distance[lane] < 10,
            1 => @field(s, "agony_timer" ++ enemy)[lane] > 0,
            5 => hp < 800,
            else => true,
        };
        if (!allowed) continue;
        if (masks[candidate][lane]) id = candidate;
        if (id != 0) break;
    }
    const dist = s.distance[lane];
    const mv: f32 = if (spec == .warrior) (if (dist > 3.5) @as(f32, -1) else 0) else if (dist > 25.0) -1.0 else if (dist < 15.0) 1.0 else 0.0;
    return .{ .ability = id, .movement = mv };
}

pub fn evaluateLeaf(comptime a: Spec, comptime b: Spec, d: anytype, lane: usize, config: Config) f32 {
    const heuristic = evaluateHeuristic(a, b, d, lane);
    if (config.evaluator != .learned) return heuristic;
    const state = d.arena.combat();
    if (state.hp_a[lane] <= 0 or state.hp_b[lane] <= 0) return d.reward(lane);
    if (d.ticks[lane] >= config.max_ticks) return 0;
    const model = config.model.?;
    const va = model.predict(a, learned.features(a, b, true, d, lane, config.max_ticks));
    const vb = model.predict(b, learned.features(a, b, false, d, lane, config.max_ticks));
    return (1 - config.learned_mix) * heuristic + config.learned_mix * (va - vb) * 0.5;
}

pub fn evaluateHeuristic(comptime spec_a: Spec, comptime spec_b: Spec, d: anytype, lane: usize) f32 {
    const s = d.arena.combat();
    const hp_a = s.hp_a[lane];
    const hp_b = s.hp_b[lane];
    if (hp_a <= 0 and hp_b <= 0) return 0;
    if (hp_a <= 0) return -1;
    if (hp_b <= 0) return 1;

    // Delta HP normalized to [-1, 1]
    const health_scale = @max(s.max_health_a[lane], s.max_health_b[lane]);
    const delta_hp = (hp_a - hp_b) / health_scale;

    // A short heuristic horizon must still value missiles already in flight.
    // Discount the estimate: mitigation and shielding can change before impact.
    const pending_a = @import("projectiles.zig").pendingEffects(s, true, lane);
    const pending_b = @import("projectiles.zig").pendingEffects(s, false, lane);
    const shield_a = if (spec_a == .frost_mage or spec_a == .priest) d.arena.frostTelemetry(true, lane)[2] else 0;
    const shield_b = if (spec_b == .frost_mage or spec_b == .priest) d.arena.frostTelemetry(false, lane)[2] else 0;
    const mit_a: f32 = 1;
    const mit_b: f32 = 1;
    const future_damage_a = @min(hp_b, @max(0, pending_a.damage * mit_b - shield_b));
    const future_damage_b = @min(hp_a, @max(0, pending_b.damage * mit_a - shield_a));
    const future_heal_a = @min(s.max_health_a[lane] - hp_a, pending_a.healing);
    const future_heal_b = @min(s.max_health_b[lane] - hp_b, pending_b.healing);
    const flight_score = (future_damage_a - future_damage_b + future_heal_a - future_heal_b) / health_scale * 0.65 * 0.75;

    // DoT differential
    var dot_score: f32 = 0;
    if (spec_a == .warlock) {
        dot_score += (s.agony_timer_b[lane] / 18.0) * 0.10;
        dot_score += (s.corruption_timer_b[lane] / 14.0) * 0.10;
        dot_score += (s.siphon_timer_b[lane] / 30.0) * 0.18;
        dot_score += (s.immolate_timer_b[lane] / 15.0) * 0.12;
    } else if (spec_a == .priest) {
        dot_score += (s.agony_timer_b[lane] / 18.0) * 0.12;
        dot_score += (s.corruption_timer_b[lane] / 24.0) * 0.18;
        dot_score += (s.siphon_timer_b[lane] / 30.0) * 0.10;
        dot_score += (s.immolate_timer_b[lane] / 10.0) * 0.08;
        dot_score += (s.shadow_lockout_a[lane] / 15.0) * 0.10;
    }
    if (spec_b == .warlock) {
        dot_score -= (s.agony_timer_a[lane] / 18.0) * 0.10;
        dot_score -= (s.corruption_timer_a[lane] / 14.0) * 0.10;
        dot_score -= (s.siphon_timer_a[lane] / 30.0) * 0.18;
        dot_score -= (s.immolate_timer_a[lane] / 15.0) * 0.12;
    } else if (spec_b == .priest) {
        dot_score -= (s.agony_timer_a[lane] / 18.0) * 0.12;
        dot_score -= (s.corruption_timer_a[lane] / 24.0) * 0.18;
        dot_score -= (s.siphon_timer_a[lane] / 30.0) * 0.10;
        dot_score -= (s.immolate_timer_a[lane] / 10.0) * 0.08;
        dot_score -= (s.shadow_lockout_b[lane] / 15.0) * 0.10;
    }

    // CC differential
    var cc_score: f32 = 0;
    if (s.fear_timer_b[lane] > 0 or s.horror_timer_b[lane] > 0) cc_score += 0.2;
    if (s.fear_timer_a[lane] > 0 or s.horror_timer_a[lane] > 0) cc_score -= 0.2;

    const cd_score: f32 = 0;

    // Distance / kite score
    var kite_score: f32 = 0;
    const dist = s.distance[lane];
    if (spec_a == .warrior and dist <= 5) kite_score += 0.05;
    if (spec_b == .warrior and dist <= 5) kite_score -= 0.05;
    if (spec_a == .frost_mage or spec_a == .warlock or spec_a == .priest) {
        // Caster prefers safe range (15m - 28m)
        if (dist >= 15.0 and dist <= 28.0) kite_score += 0.05;
        if (dist < 10.0) kite_score -= 0.05;
    }

    const total = delta_hp * 0.65 + flight_score + dot_score + cc_score + cd_score + kite_score;
    return std.math.clamp(total, -1.0, 1.0);
}

pub fn computePriors(comptime spec: Spec, comptime side: bool, d: anytype, lane: usize, choices: sim.Choices) [MaxChoices]f32 {
    var p: [MaxChoices]f32 = @splat(0);
    if (choices.len == 0) return p;
    const s = d.arena.combat();
    const own = if (side) "_a" else "_b";
    const enemy = if (side) "_b" else "_a";
    const hp = @field(s, "hp" ++ own)[lane];
    const enemy_casting = @field(s, "cast_id" ++ enemy)[lane] != 0;
    const dist = s.distance[lane];

    for (0..choices.len) |i| {
        const action = choices.items[i];
        var weight: f32 = 1.0; // base weight for legal action

        if (spec == .warlock) {
            switch (action.ability) {
                0 => { // Idle / Maneuver
                    weight = 0.2;
                },
                7 => { // Death Coil
                    if (hp < 800) weight += 12.0 else if (hp < 1600 or enemy_casting) weight += 6.0 else weight += 2.0;
                },
                6 => { // Healthstone
                    if (hp < 800) weight += 10.0 else weight = 0.2;
                },
                2 => { // Corruption
                    if (@field(s, "corruption_timer" ++ enemy)[lane] < 1.0) weight += 6.0;
                },
                1 => { // Agony
                    if (@field(s, "agony_timer" ++ enemy)[lane] < 1.0) weight += 5.5;
                },
                8 => { // Siphon Life
                    if (@field(s, "siphon_timer" ++ enemy)[lane] < 1.0) weight += 7.0;
                },
                3 => { // Fear
                    if (dist <= 20.0 and @field(s, "fear_timer" ++ enemy)[lane] <= 0) weight += 2.5;
                },
                5 => { // Drain Life
                    if (hp < 1500 and dist <= 25.0) weight += 2.0;
                },
                4 => { // Shadow Bolt
                    if (dist <= 30.0) weight += 1.5;
                },
                9 => { // Shadowburn
                    if (@field(s, "hp" ++ enemy)[lane] < 500) weight += 10.0 else weight = 0.2;
                },
                10 => { // Cancel Cast
                    weight = 0.05;
                },
                11 => { // Searing Pain
                    if (dist <= 20.0) weight += 1.5;
                },
                12 => { // Incinerate
                    if (dist <= 30.0) weight += 1.5;
                },
                13 => { // Immolate
                    if (@field(s, "immolate_timer" ++ enemy)[lane] < 1.0) weight += 5.0;
                },
                16 => { // Conflagrate
                    weight += 5.0;
                },
                15 => { // Spell Lock
                    if (enemy_casting) weight += 8.0 else weight = 0.2;
                },
                else => {},
            }
        } else if (spec == .priest) {
            const max_hp = @field(s, "max_health" ++ own)[lane];
            const enemy_hp = @field(s, "hp" ++ enemy)[lane];
            switch (action.ability) {
                0 => { // Idle / Maneuver
                    weight = 0.2;
                },
                7 => { // Silence
                    if (enemy_casting) weight += 9.0 else weight += 2.0;
                },
                6 => { // Power Word: Shield
                    if (@field(s, "action6_dur" ++ own)[lane] <= 0) weight += 6.0 else weight = 0.2;
                },
                3 => { // Psychic Scream
                    if (dist <= 8.0 and @field(s, "fear_timer" ++ enemy)[lane] <= 0) weight += 7.0 else weight = 0.1;
                },
                2 => { // Devouring Plague
                    if (@field(s, "corruption_timer" ++ enemy)[lane] < 1.0) weight += 7.5;
                },
                1 => { // Shadow Word: Pain
                    if (@field(s, "agony_timer" ++ enemy)[lane] < 1.0) weight += 6.0;
                },
                8 => { // Vampiric Embrace
                    if (@field(s, "siphon_timer" ++ enemy)[lane] < 1.0) weight += 5.0;
                },
                9 => { // Shadow Word: Death
                    if (enemy_hp < 500) weight += 10.0 else if (hp > 1000) weight += 4.5 else weight = 0.3;
                },
                4 => { // Mind Blast
                    if (dist <= 30.0) weight += 4.0;
                },
                5 => { // Mind Flay
                    if (dist <= 24.0) weight += 2.5;
                },
                11 => { // Flash Heal
                    if (hp < max_hp * 0.55) weight += 7.0 else weight = 0.3;
                },
                12 => { // Renew
                    if (@field(s, "shadow_lockout" ++ own)[lane] < 1.0 and hp < max_hp * 0.85) weight += 4.5 else weight = 0.3;
                },
                13 => { // Holy Fire
                    if (@field(s, "immolate_timer" ++ enemy)[lane] < 1.0) weight += 4.5 else weight += 1.5;
                },
                14 => { // Smite
                    weight += 2.0;
                },
                15 => { // Penance
                    weight += 6.5;
                },
                16 => { // Inner Focus
                    weight += 8.0;
                },
                21 => { // Power Infusion: strongest before committing damage/heals.
                    weight += 12.0;
                },
                22 => { // Defensive Dispel Magic (only offered with an eligible aura).
                    weight += 7.0;
                },
                23 => { // Offensive Dispel Magic (only offered with an eligible buff).
                    weight += 6.0;
                },
                24 => { // Mana Burn: prefer pressure on an already depleted caster.
                    const enemy_mana = @field(s, "mana" ++ enemy)[lane];
                    weight += if (enemy_mana < 1000) @as(f32, 4.0) else @as(f32, 1.5);
                },
                10 => { // Cancel Cast
                    weight = 0.05;
                },
                else => {},
            }
        } else if (spec == .warrior) {
            const rage = d.arena.warrior.floats(side, .rage, 0).*[lane];
            weight = switch (action.ability) {
                1 => if (rage >= 40) 4 else 0.2,
                2 => if (d.arena.warrior.floats(side, .hamstring, 0).*[lane] < 1) 6 else 0.2,
                13, 14, 15 => 0.1,
                10 => 0.1,
                else => 1,
            };
        } else {
            // Frost Mage
            switch (action.ability) {
                7 => { // Counterspell
                    if (enemy_casting) weight += 8.0 else weight = 0.2;
                },
                6 => { // Ice Barrier
                    if (hp < 1800) weight += 4.0;
                },
                5 => { // Blink
                    if (dist < 10.0 or hp < 1000) weight += 3.5;
                },
                2 => { // Frost Nova
                    if (dist <= 10.0) weight += 4.0;
                },
                1 => { // Ice Lance
                    const enemy_frozen = @field(s, "agony_timer" ++ enemy)[lane] > 0;
                    if (enemy_frozen) weight += 5.0 else weight += 1.5;
                },
                3 => { // Polymorph
                    if (dist <= 30.0) weight += 2.0;
                },
                4 => { // Frostbolt
                    weight += 1.5;
                },
                10 => { // Cancel Cast
                    weight = 0.1;
                },
                else => {},
            }
        }

        // Movement preference
        if (spec == .warrior) {
            if (action.movement == -1 and dist > 3.5) weight *= 2;
            if (action.movement == 0 and dist <= 3.5) weight *= 1.5;
        } else {
            if (action.movement == 1 and dist < 15.0) weight *= 1.3; // Kite away when close
            if (action.movement == -1 and dist > 26.0) weight *= 1.3; // Advance when far
        }

        p[i] = weight;
    }

    var sum: f32 = 0;
    for (0..choices.len) |i| sum += p[i];
    if (sum > 0) {
        for (0..choices.len) |i| p[i] /= sum;
    } else {
        const u = 1.0 / @as(f32, @floatFromInt(choices.len));
        for (0..choices.len) |i| p[i] = u;
    }
    return p;
}
test "Exp3 mixes rock paper scissors and resists a pure best response" {
    var rng = std.Random.DefaultPrng.init(9);
    const random = rng.random();
    var x: Bandit = .{};
    var y: Bandit = .{};
    for (0..100000) |_| {
        const p = x.distribution(3, .exp3, 1.414);
        const q = y.distribution(3, .exp3, 1.414);
        const i = sample(p, 3, random);
        const j = sample(q, 3, random);
        const r: f32 = if (i == j) 0 else if ((@as(u32, i) + 1) % 3 == j) -1 else 1;
        for (0..3) |k| {
            x.strategy[k] += p[k];
            y.strategy[k] += q[k];
        }
        x.update(3, i, p[i], r, .exp3);
        y.update(3, j, q[j], -r, .exp3);
    }
    for (0..3) |i| {
        try std.testing.expect(@abs(x.strategy[i] / 100000 - 1.0 / 3.0) < 0.06);
        try std.testing.expect(@abs(y.strategy[i] / 100000 - 1.0 / 3.0) < 0.06);
    }
}
test "bounded trees and fixed-budget workers reproduce strategies" {
    const config: Config = .{ .rollouts = 32, .workers = 2, .nodes = 2, .max_ticks = 25 };
    var d = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    const x = try Search(.warlock, .frost_mage).init(std.testing.allocator, config);
    defer x.deinit();
    const y = try Search(.warlock, .frost_mage).init(std.testing.allocator, config);
    defer y.deinit();
    var rx = std.Random.DefaultPrng.init(1);
    var ry = std.Random.DefaultPrng.init(1);
    const p = x.decide(d.snapshot(0), rx.random());
    const q = y.decide(d.snapshot(0), ry.random());
    try std.testing.expectEqualDeep(p.distributions, q.distributions);
    try std.testing.expectEqual(@as(u64, 32), p.stats.rollouts);
    try std.testing.expect(p.stats.nodes <= 4);
}

test "cancellation stops at a batch boundary without committing actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("stop", .{});
    file.close();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "stop");
    defer std.testing.allocator.free(path);
    const config: Config = .{ .rollouts = 1000, .workers = 2, .nodes = 8, .max_ticks = 100, .stop_file = path };
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    const search = try Search(.warlock, .warlock).init(std.testing.allocator, config);
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    const before = d.snapshot(0);
    const result = search.decide(before, rng.random());
    try std.testing.expectEqual(@as(u64, 0), result.stats.rollouts);
    try std.testing.expectEqualDeep(before, d.snapshot(0));
}

test "memory budget rejects excessive trees before allocation" {
    try std.testing.expectError(error.SearchMemoryLimitExceeded, Search(.warlock, .warlock).init(std.testing.allocator, .{ .memory_limit = 1 }));
}

test "search concentrates on a terminal winning move as budget grows" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    // A close-range Coil can still land within the ten-tick search horizon.
    @memset(d.arena.distance, 1);
    @memset(d.arena.pos_x_a, -0.5);
    @memset(d.arena.pos_x_b, 0.5);
    d.arena.hp_b[0] = 100;
    d.arena.mana_b[0] = 0;
    d.arena.action6_cd_b[0] = 45;
    d.arena.action6_cd_a[0] = 45;
    const search = try Search(.warlock, .warlock).init(std.testing.allocator, .{ .rollouts = 8192, .nodes = 128, .depth = 8, .max_ticks = 10 });
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    const result = search.decide(d.snapshot(0), rng.random());
    var winning: f32 = 0;
    for (result.choices[0].items[0..result.choices[0].len], 0..) |action, i| if (action.ability == 7) {
        winning += result.distributions[0][i];
    };
    try std.testing.expect(winning > 0.6);
}

test "UCT batch reservations are removed exactly once" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    const search = try Search(.warlock, .warlock).init(std.testing.allocator, .{ .algorithm = .uct, .evaluator = .rollout, .workers = 2, .rollouts = 64, .nodes = 2, .depth = 4, .max_ticks = 10 });
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    _ = search.decide(d.snapshot(0), rng.random());
    for (search.workers) |w| for (w.nodes[0].bandits) |bandit| {
        var visits: u32 = 0;
        for (bandit.visits) |n| visits += n;
        try std.testing.expectEqual(@as(u32, 32), visits);
        try std.testing.expectEqual(@as(u32, 32), bandit.total);
    };
}

test "PUCT with heuristic leaf evaluation finds high-value defensive actions" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.arena.hp_a[0] = 500;
    d.arena.hp_b[0] = 1800;
    d.arena.combat().cast_id_b[0] = 4; // B is casting Shadow Bolt
    d.arena.combat().cast_timer_b[0] = 1.0;
    d.arena.combat().cast_total_b[0] = 1.8;
    const search = try Search(.warlock, .warlock).init(std.testing.allocator, .{ .algorithm = .puct, .evaluator = .heuristic, .truncation_ticks = 20, .workers = 2, .rollouts = 256, .nodes = 64, .depth = 8, .max_ticks = 30 });
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    const result = search.decide(d.snapshot(0), rng.random());
    try std.testing.expect(result.stats.rollouts == 256);
    // Unit A should heavily prioritize Death Coil (7) or Healthstone (6)
    var defensive_weight: f32 = 0;
    for (result.choices[0].items[0..result.choices[0].len], 0..) |act, i| {
        if (act.ability == 7 or act.ability == 6) defensive_weight += result.distributions[0][i];
    }
    try std.testing.expect(defensive_weight > 0.4);
}

test "forced choices need no simulations and preserve combat state" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.arena.horror_timer_a[0] = 3;
    d.arena.horror_timer_b[0] = 3;
    const search = try Search(.warlock, .warlock).init(std.testing.allocator, .{ .rollouts = 100000, .nodes = 2, .depth = 2, .max_ticks = 20 });
    defer search.deinit();
    var rng = std.Random.DefaultPrng.init(1);
    const before = d.snapshot(0);
    const result = search.decide(before, rng.random());
    try std.testing.expectEqual(@as(u64, 0), result.stats.rollouts);
    try std.testing.expectEqual(@as(u8, 1), result.choices[0].len);
    try std.testing.expectEqual(@as(u8, 1), result.choices[1].len);
    try std.testing.expectEqualDeep(before, d.snapshot(0));
}

test "heuristic values in-flight missiles before they deal damage" {
    var d = try sim.Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    const before = evaluateHeuristic(.warlock, .warlock, &d, 0);
    @import("projectiles.zig").launch(d.arena.combat(), true, 0, 4, @splat(240), @splat(true));
    try std.testing.expectEqual(@as(f32, 2000), d.arena.hp_b[0]);
    try std.testing.expect(evaluateHeuristic(.warlock, .warlock, &d, 0) > before);
}
