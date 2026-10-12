const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");
const gauntlet_mod = @import("gauntlet.zig");

const Spec = @import("spec.zig").Spec;
const multi_spec = @import("multi_spec.zig");
const spec_policy = @import("spec_policy.zig");
const WarlockConstants = combat_spec.WarlockConstants;
const PolicyGenome = policy_simd.PolicyGenome;
const VEC_LEN = simd.SimdConfig.VecLen16;
const bool16 = simd.bool16;
const u32x16 = simd.u32x16;
const f32x16 = simd.f32x16;

pub const LeagueConfig = struct {
    threads: usize = 1,
    external_spec: ?Spec = null, // Defaults to the training class; HoF/peers always mirror.
    pop_size: usize = 64,
    hall_of_fame_capacity: usize = 16,
    duels_per_agent: usize = 8,
    mutation_rate: f32 = 0.08,
    mutation_sigma: f32 = 0.04,
    elite_ratio: f32 = 0.25,
    max_duel_seconds: f32 = 45.0,
    physics_dt: f32 = 0.010, // 100 Hz physics
    spar_gauntlet: bool = false, // Automatically spar against 4 Gauntlet archetypes during evolution
};

pub const LeagueCheckpointHeader = extern struct {
    magic: [4]u8 = "PLCK".*, // PvP League Checkpoint
    version: u32 = 1,
    generation: u64,
    total_duels: u64,
    pop_size: u32,
    hof_count: u32,
    sparring_count: u32 = 0,
    reserved: [32]u8 = std.mem.zeroes([32]u8),
};

pub const League = LeagueFor(.warlock);
pub const FrostMageLeague = LeagueFor(.frost_mage);

pub fn LeagueFor(comptime class: Spec) type {
    return struct {
        const Self = @This();
        const WarlockArenaPool = multi_spec.ArenaPool(class, class);
        const other_class: Spec = if (class == .warlock) .frost_mage else .warlock;
        const CrossArena = multi_spec.ArenaPool(class, other_class);

        allocator: mem.Allocator,
        config: LeagueConfig,
        prng: std.Random.DefaultPrng,

        population: []PolicyGenome,
        hall_of_fame: std.ArrayList(PolicyGenome),
        sparring_partners: std.ArrayList(PolicyGenome),
        arena_pool: WarlockArenaPool,

        workers: ?*WorkerPool = null,
        cross_arena: ?*CrossArena = null,

        generation: usize = 0,
        total_duels_simulated: usize = 0,
        generation_metrics: ?@import("training_logger.zig").GenerationMetrics = null,
        generation_wins: usize = 0,
        generation_losses: usize = 0,
        generation_draws: usize = 0,
        // Duration bins: [0,5), [5,10), [10,20), [20,30), [30,infinity) seconds.
        generation_match_duration_bins: [5]usize = [_]usize{0} ** 5,
        generation_match_seconds: f64 = 0,

        pub fn init(allocator: mem.Allocator, config: LeagueConfig, seed: u64) !Self {
            if (config.threads == 0 or config.pop_size < 2) return error.InvalidLeagueConfig;
            var prng = std.Random.DefaultPrng.init(seed);
            const rand = prng.random();

            const population = try allocator.alloc(PolicyGenome, config.pop_size);
            errdefer allocator.free(population);

            for (population) |*g| {
                g.* = PolicyGenome.initRandom(rand);
            }

            var hof = std.ArrayList(PolicyGenome).init(allocator);
            errdefer hof.deinit();

            // Initialize seed champion in Hall of Fame
            try hof.append(population[0]);

            var sparring = std.ArrayList(PolicyGenome).init(allocator);
            errdefer sparring.deinit();

            // Arena pool sized to 64 duels minimum for batching
            const pool_cap = @max(config.pop_size, 64);
            var arena = try WarlockArenaPool.init(allocator, pool_cap);
            errdefer arena.deinit();

            const cross: ?*CrossArena = if (needsCross(config)) try createCross(allocator) else null;
            errdefer if (cross) |arena_cross| destroyCross(allocator, arena_cross);
            const workers = if (config.threads > 1) try WorkerPool.init(allocator, config) else null;

            return Self{
                .workers = workers,
                .cross_arena = cross,
                .allocator = allocator,
                .config = config,
                .prng = prng,
                .population = population,
                .hall_of_fame = hof,
                .sparring_partners = sparring,
                .arena_pool = arena,
                .generation = 0,
                .total_duels_simulated = 0,
            };
        }

        /// Initializes a new league by seeding the entire population around a pre-trained champion.
        /// Champion is placed in index 0 and HoF; all other genomes are initialized with Gaussian perturbations.
        pub fn seedFromChampion(
            allocator: mem.Allocator,
            config: LeagueConfig,
            champion: *const PolicyGenome,
            seed: u64,
            sigma: f32,
        ) !Self {
            var league = try Self.init(allocator, config, seed);
            errdefer league.deinit();

            const rand = league.prng.random();
            league.population[0] = champion.*;

            for (league.population[1..]) |*g| {
                g.* = champion.*;
                g.mutate(rand, 0.40, sigma);
                g.elo = champion.elo;
                g.fitness = 0.0;
                g.wins = 0;
                g.losses = 0;
                g.draws = 0;
            }

            league.hall_of_fame.clearRetainingCapacity();
            try league.hall_of_fame.append(champion.*);

            return league;
        }

        pub fn deinit(self: *Self) void {
            if (self.cross_arena) |arena_cross| destroyCross(self.allocator, arena_cross);
            if (self.workers) |workers| workers.deinit();
            self.arena_pool.deinit();
            self.sparring_partners.deinit();
            self.hall_of_fame.deinit();
            self.allocator.free(self.population);
        }

        pub fn addSparringPartner(self: *Self, partner: PolicyGenome) !void {
            try self.sparring_partners.append(partner);
        }

        pub fn loadSparringFile(self: *Self, file_path: []const u8) !void {
            const partner = try spec_policy.loadFor(self.config.external_spec orelse class, file_path);
            try self.addSparringPartner(partner);
        }

        pub fn loadSparringPoolFromDir(self: *Self, dir_path: []const u8) !usize {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
                return err;
            };
            defer dir.close();

            var iterator = dir.iterate();
            var count: usize = 0;

            while (try iterator.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".bin")) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                    defer self.allocator.free(full_path);

                    const partner = try spec_policy.loadFor(self.config.external_spec orelse class, full_path);
                    try self.addSparringPartner(partner);
                    count += 1;
                }
            }

            return count;
        }

        /// Save full population and league checkpoint state to binary file (.pop)
        pub fn saveCheckpoint(self: *const Self, file_path: []const u8) !void {
            const file = try std.fs.cwd().createFile(file_path, .{});
            defer file.close();
            var buf_writer = std.io.bufferedWriter(file.writer());
            const writer = buf_writer.writer();

            const header = LeagueCheckpointHeader{
                .generation = @intCast(self.generation),
                .total_duels = @intCast(self.total_duels_simulated),
                .pop_size = @intCast(self.population.len),
                .hof_count = @intCast(self.hall_of_fame.items.len),
                .sparring_count = @intCast(self.sparring_partners.items.len),
                .reserved = checkpointTags(self.config),
            };

            try writer.writeAll(mem.asBytes(&header));

            // Write Population genomes
            for (self.population) |*g| {
                try writer.writeAll(mem.asBytes(g));
            }

            // Write Hall of Fame genomes
            for (self.hall_of_fame.items) |*g| {
                try writer.writeAll(mem.asBytes(g));
            }

            // Write Sparring Partner genomes
            for (self.sparring_partners.items) |*g| {
                try writer.writeAll(mem.asBytes(g));
            }

            try buf_writer.flush();
        }

        /// Restore full population and league checkpoint state from binary file (.pop)
        pub fn loadCheckpoint(allocator: mem.Allocator, file_path: []const u8, config: LeagueConfig) !Self {
            const file = try std.fs.cwd().openFile(file_path, .{});
            defer file.close();
            const reader = file.reader();

            var header: LeagueCheckpointHeader = undefined;
            try reader.readNoEof(mem.asBytes(&header));

            if (!mem.eql(u8, &header.magic, "PLCK")) {
                return error.InvalidCheckpointMagic;
            }
            if (header.version != 1) {
                return error.UnsupportedCheckpointVersion;
            }

            if (header.reserved[0] != @intFromEnum(class)) return error.CheckpointSpecMismatch;
            if (header.reserved[1] != @intFromEnum(config.external_spec orelse class)) return error.CheckpointOpponentSpecMismatch;
            var eff_config = config;
            eff_config.pop_size = header.pop_size;

            var league = try Self.init(allocator, eff_config, 42);
            errdefer league.deinit();

            league.generation = @intCast(header.generation);
            league.total_duels_simulated = @intCast(header.total_duels);

            // Read population
            for (league.population) |*g| {
                try reader.readNoEof(mem.asBytes(g));
            }

            // Read HoF
            league.hall_of_fame.clearRetainingCapacity();
            for (0..header.hof_count) |_| {
                var g: PolicyGenome = undefined;
                try reader.readNoEof(mem.asBytes(&g));
                try league.hall_of_fame.append(g);
            }

            // Read Sparring Partners
            league.sparring_partners.clearRetainingCapacity();
            for (0..header.sparring_count) |_| {
                var g: PolicyGenome = undefined;
                try reader.readNoEof(mem.asBytes(&g));
                try league.sparring_partners.append(g);
            }

            return league;
        }

        /// Simulate a batch of 16 duels where Team A uses policy `p_a` and Team B uses policy `p_b`.
        /// Runs with the dual-clock model (100 Hz physics, 100ms reaction with hard stops).
        pub fn simulateDuelBatch16(self: *Self, p_a: *PolicyGenome, p_b: *PolicyGenome, offset: usize) void {
            const result = runBatch(&self.arena_pool, self.config, p_a, p_b, offset);
            self.applyBatch(p_a, p_b, result);
        }

        fn runBatch(arena: anytype, config: LeagueConfig, p_a: *const PolicyGenome, p_b: *const PolicyGenome, offset: usize) BatchResult {
            // Reset the 16 lanes in arena pool
            for (0..VEC_LEN) |lane| {
                arena.resetDuel(offset + lane);
            }

            const dt = config.physics_dt;
            const max_ticks: usize = @intFromFloat(config.max_duel_seconds / dt);
            var elapsed_ticks: usize = 0;
            var lane_ticks: [VEC_LEN]usize = [_]usize{max_ticks} ** VEC_LEN;

            while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
                // Check if active
                const act_mask = arena.combat().is_active[offset..][0..VEC_LEN].* > @as(u32x16, @splat(0));
                if (!@reduce(.Or, act_mask)) break;

                // 1. Cognitive Decision for Team A (if 100ms reaction expired or hard stop triggered)
                const dec_a = arena.needsDecisionA(offset);
                if (@reduce(.Or, dec_a)) {
                    const obs_a = arena.getObservationsA(offset);
                    const masks_a = arena.getActionMaskA(offset);
                    const out_a = p_a.forward16(obs_a, masks_a);
                    arena.applyActionA(offset, out_a.actions, out_a.move_intents);
                }

                // 2. Cognitive Decision for Team B
                const dec_b = arena.needsDecisionB(offset);
                if (@reduce(.Or, dec_b)) {
                    const obs_b = arena.getObservationsB(offset);
                    const masks_b = arena.getActionMaskB(offset);
                    const out_b = p_b.forward16(obs_b, masks_b);
                    arena.applyActionB(offset, out_b.actions, out_b.move_intents);
                }

                // 3. Step Physics (100 Hz / 10ms)
                _ = arena.tickPhysics16(dt, offset);
                for (0..VEC_LEN) |lane| {
                    if (act_mask[lane] and arena.combat().is_active[offset + lane] == 0) {
                        lane_ticks[lane] = elapsed_ticks + 1;
                    }
                }
            }

            return .{ .hp_a = arena.combat().hp_a[offset..][0..VEC_LEN].*, .hp_b = arena.combat().hp_b[offset..][0..VEC_LEN].*, .lane_ticks = lane_ticks };
        }

        fn applyBatch(self: *Self, p_a: *PolicyGenome, p_b: *PolicyGenome, result: BatchResult) void {
            self.total_duels_simulated += VEC_LEN;

            // Tally outcomes for the 16 duels and update fitness/Elo
            for (0..VEC_LEN) |lane| {
                const hp_a = result.hp_a[lane];
                const hp_b = result.hp_b[lane];
                if (hp_a > 0 and hp_b <= 0) {
                    self.generation_wins += 1;
                } else if (hp_b > 0 and hp_a <= 0) {
                    self.generation_losses += 1;
                } else {
                    self.generation_draws += 1;
                }
                const match_time = @as(f32, @floatFromInt(result.lane_ticks[lane])) * self.config.physics_dt;
                self.generation_match_seconds += match_time;
                const bin: usize = if (match_time < 5) 0 else if (match_time < 10) 1 else if (match_time < 20) 2 else if (match_time < 30) 3 else 4;
                self.generation_match_duration_bins[bin] += 1;

                var score_a: f32 = 0.0;
                var score_b: f32 = 0.0;

                if (hp_a > 0.0 and hp_b <= 0.0) {
                    // A won
                    p_a.wins += 1;
                    p_b.losses += 1;
                    score_a = 1.0;
                    score_b = 0.0;
                    p_a.fitness += 100.0 + (hp_a / WarlockConstants.MaxHp) * 50.0 - match_time * 0.02;
                    p_b.fitness -= 100.0;
                } else if (hp_b > 0.0 and hp_a <= 0.0) {
                    // B won
                    p_b.wins += 1;
                    p_a.losses += 1;
                    score_a = 0.0;
                    score_b = 1.0;
                    p_b.fitness += 100.0 + (hp_b / WarlockConstants.MaxHp) * 50.0 - match_time * 0.02;
                    p_a.fitness -= 100.0;
                } else {
                    // Draw
                    p_a.draws += 1;
                    p_b.draws += 1;
                    score_a = 0.5;
                    score_b = 0.5;
                    p_a.fitness += ((hp_a - hp_b) / WarlockConstants.MaxHp) * 30.0;
                    p_b.fitness += ((hp_b - hp_a) / WarlockConstants.MaxHp) * 30.0;
                }

                // Update Elo
                const expected_a = 1.0 / (1.0 + std.math.pow(f32, 10.0, (p_b.elo - p_a.elo) / 400.0));
                const expected_b = 1.0 - expected_a;
                const k_factor: f32 = 16.0;
                p_a.elo += k_factor * (score_a - expected_a);
                p_b.elo += k_factor * (score_b - expected_b);
            }
        }

        /// Simulate a batch of 16 duels where Team A uses policy `p_a` and Team B is a fixed Gauntlet Bot
        pub fn simulateDuelBatch16VsBot(self: *Self, p_a: *PolicyGenome, bot: gauntlet_mod.GauntletBot, offset: usize) void {
            const result = if (class == .frost_mage) runBatchVsBot(self.cross_arena.?, self.config, p_a, bot, 0) else runBatchVsBot(&self.arena_pool, self.config, p_a, bot, offset);
            self.applyBatchVsBot(p_a, bot, result);
        }

        fn runBatchVsBot(arena: anytype, config: LeagueConfig, p_a: *const PolicyGenome, bot: gauntlet_mod.GauntletBot, offset: usize) BatchResult {
            for (0..VEC_LEN) |lane| {
                arena.resetDuel(offset + lane);
            }

            const dt = config.physics_dt;
            const max_ticks: usize = @intFromFloat(config.max_duel_seconds / dt);
            var elapsed_ticks: usize = 0;
            var lane_ticks: [VEC_LEN]usize = [_]usize{max_ticks} ** VEC_LEN;

            while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
                const act_mask = arena.combat().is_active[offset..][0..VEC_LEN].* > @as(u32x16, @splat(0));
                if (!@reduce(.Or, act_mask)) break;

                const dec_a = arena.needsDecisionA(offset);
                if (@reduce(.Or, dec_a)) {
                    const obs_a = arena.getObservationsA(offset);
                    const masks_a = arena.getActionMaskA(offset);
                    const out_a = p_a.forward16(obs_a, masks_a);
                    arena.applyActionA(offset, out_a.actions, out_a.move_intents);
                }

                const dec_b = arena.needsDecisionB(offset);
                if (@reduce(.Or, dec_b)) {
                    const obs_b = arena.getObservationsB(offset);
                    const masks_b = arena.getActionMaskB(offset);
                    const out_b = bot.forward16(obs_b, masks_b);
                    arena.applyActionB(offset, out_b.actions, out_b.move_intents);
                }

                _ = arena.tickPhysics16(dt, offset);
                for (0..VEC_LEN) |lane| {
                    if (act_mask[lane] and arena.combat().is_active[offset + lane] == 0) {
                        lane_ticks[lane] = elapsed_ticks + 1;
                    }
                }
            }

            return .{ .hp_a = arena.combat().hp_a[offset..][0..VEC_LEN].*, .hp_b = arena.combat().hp_b[offset..][0..VEC_LEN].*, .lane_ticks = lane_ticks };
        }

        fn applyBatchVsBot(self: *Self, p_a: *PolicyGenome, bot: gauntlet_mod.GauntletBot, result: BatchResult) void {
            self.total_duels_simulated += VEC_LEN;

            for (0..VEC_LEN) |lane| {
                const hp_a = result.hp_a[lane];
                const hp_b = result.hp_b[lane];
                if (hp_a > 0 and hp_b <= 0) {
                    self.generation_wins += 1;
                } else if (hp_b > 0 and hp_a <= 0) {
                    self.generation_losses += 1;
                } else {
                    self.generation_draws += 1;
                }
                const match_time = @as(f32, @floatFromInt(result.lane_ticks[lane])) * self.config.physics_dt;
                self.generation_match_seconds += match_time;
                const bin: usize = if (match_time < 5) 0 else if (match_time < 10) 1 else if (match_time < 20) 2 else if (match_time < 30) 3 else 4;
                self.generation_match_duration_bins[bin] += 1;

                var score_a: f32 = 0.0;
                if (hp_a > 0.0 and hp_b <= 0.0) {
                    p_a.wins += 1;
                    score_a = 1.0;
                    p_a.fitness += 100.0 + (hp_a / WarlockConstants.MaxHp) * 50.0 - match_time * 0.02;
                } else if (hp_b > 0.0 and hp_a <= 0.0) {
                    p_a.losses += 1;
                    score_a = 0.0;
                    p_a.fitness -= 100.0;
                } else {
                    p_a.draws += 1;
                    score_a = 0.5;
                    p_a.fitness += ((hp_a - hp_b) / WarlockConstants.MaxHp) * 30.0;
                }

                const bot_elo = bot.kind.getBaselineElo();
                const expected_a = 1.0 / (1.0 + std.math.pow(f32, 10.0, (bot_elo - p_a.elo) / 400.0));
                p_a.elo += 16.0 * (score_a - expected_a);
            }
        }

        /// Run one complete generation tournament across the entire population + Hall of Fame + Sparring pool.
        pub fn stepGeneration(self: *Self) void {
            const rand = self.prng.random();

            self.generation_wins = 0;
            self.generation_losses = 0;
            self.generation_draws = 0;
            self.generation_match_duration_bins = [_]usize{0} ** 5;
            self.generation_match_seconds = 0;
            const duels_before = self.total_duels_simulated;

            // 1. Reset generational fitness & records
            for (self.population) |*g| {
                g.fitness = 0.0;
                g.wins = 0;
                g.losses = 0;
                g.draws = 0;
            }

            // 2. Schedule pairings across the population + Hall of Fame + External Sparring Partners
            // Each agent plays `duels_per_agent` batches of 16 duels
            const has_sparring = self.sparring_partners.items.len > 0;
            const has_hof = self.hall_of_fame.items.len > 0;

            if (self.workers) |pool| {
                var job_idx: usize = 0;
                for (0..self.config.pop_size) |i| {
                    for (0..self.config.duels_per_agent) |_| {
                        const roll = rand.float(f32);

                        if (self.config.spar_gauntlet and roll < 0.30) {
                            // 30% chance to spar against a random Gauntlet bot archetype (Aggro, Kiter, Turret, DrainTank)
                            const bot_kind: gauntlet_mod.GauntletBotKind = @enumFromInt(rand.intRangeLessThan(u32, 0, 4));
                            const bot = gauntlet_mod.GauntletBot.init(bot_kind);
                            pool.jobs[job_idx] = .{ .a = &self.population[i], .opponent = .{ .bot = bot } };
                        } else if (has_sparring and roll < 0.50) {
                            // Spar against an external pre-trained champion partner
                            const sp_idx = rand.intRangeLessThan(usize, 0, self.sparring_partners.items.len);
                            pool.jobs[job_idx] = .{ .a = &self.population[i], .opponent = .{ .external = &self.sparring_partners.items[sp_idx] } };
                        } else if (has_hof and roll < 0.70) {
                            // Duel a historical Hall of Fame champion
                            const hof_idx = rand.intRangeLessThan(usize, 0, self.hall_of_fame.items.len);
                            pool.jobs[job_idx] = .{ .a = &self.population[i], .opponent = .{ .frozen = &self.hall_of_fame.items[hof_idx] } };
                        } else {
                            // Duel an active peer
                            var opp_idx = rand.intRangeLessThan(usize, 0, self.config.pop_size);
                            while (opp_idx == i) {
                                opp_idx = rand.intRangeLessThan(usize, 0, self.config.pop_size);
                            }
                            pool.jobs[job_idx] = .{ .a = &self.population[i], .opponent = .{ .peer = &self.population[opp_idx] } };
                        }
                        job_idx += 1;
                    }
                }

                pool.run();
                for (pool.jobs, pool.results) |job, result| {
                    switch (job.opponent) {
                        .bot => |bot| self.applyBatchVsBot(job.a, bot, result),
                        .peer => |peer| self.applyBatch(job.a, peer, result),
                        .external, .frozen => |frozen| {
                            var opponent = frozen.*;
                            self.applyBatch(job.a, &opponent, result);
                        },
                    }
                }
            } else {
                for (0..self.config.pop_size) |i| {
                    for (0..self.config.duels_per_agent) |_| {
                        const roll = rand.float(f32);

                        if (self.config.spar_gauntlet and roll < 0.30) {
                            // 30% chance to spar against a random Gauntlet bot archetype (Aggro, Kiter, Turret, DrainTank)
                            const bot_kind: gauntlet_mod.GauntletBotKind = @enumFromInt(rand.intRangeLessThan(u32, 0, 4));
                            const bot = gauntlet_mod.GauntletBot.init(bot_kind);
                            self.simulateDuelBatch16VsBot(&self.population[i], bot, 0);
                        } else if (has_sparring and roll < 0.50) {
                            // Spar against an external pre-trained champion partner
                            const sp_idx = rand.intRangeLessThan(usize, 0, self.sparring_partners.items.len);
                            var sp_opp = self.sparring_partners.items[sp_idx];
                            self.applyBatch(&self.population[i], &sp_opp, self.runExternal(&self.population[i], &sp_opp));
                        } else if (has_hof and roll < 0.70) {
                            // Duel a historical Hall of Fame champion
                            const hof_idx = rand.intRangeLessThan(usize, 0, self.hall_of_fame.items.len);
                            var hof_opp = self.hall_of_fame.items[hof_idx];
                            self.simulateDuelBatch16(&self.population[i], &hof_opp, 0);
                        } else {
                            // Duel an active peer
                            var opp_idx = rand.intRangeLessThan(usize, 0, self.config.pop_size);
                            while (opp_idx == i) {
                                opp_idx = rand.intRangeLessThan(usize, 0, self.config.pop_size);
                            }
                            self.simulateDuelBatch16(&self.population[i], &self.population[opp_idx], 0);
                        }
                    }
                }
            }

            // 3. Sort population descending by fitness
            std.mem.sort(PolicyGenome, self.population, {}, struct {
                fn lessThan(_: void, a: PolicyGenome, b: PolicyGenome) bool {
                    return a.fitness > b.fitness;
                }
            }.lessThan);

            // 4. Archive current best to Hall of Fame every 10 generations
            if (self.generation % 10 == 0) {
                if (self.hall_of_fame.items.len >= self.config.hall_of_fame_capacity) {
                    _ = self.hall_of_fame.orderedRemove(0); // evict oldest
                }
                self.hall_of_fame.append(self.population[0]) catch {};
            }

            self.generation_metrics = self.populationMetrics();
            self.generation_metrics.?.generation = self.generation + 1;
            self.generation_metrics.?.total_duels = self.total_duels_simulated - duels_before;

            // 5. Breeding / Evolutionary Selection
            const num_elites = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.config.pop_size)) * self.config.elite_ratio)));

            // Elite preservation: indices 0..num_elites are kept
            var next_idx = num_elites;
            while (next_idx < self.config.pop_size) : (next_idx += 1) {
                // Tournament selection among elites
                const p1_idx = rand.intRangeLessThan(usize, 0, num_elites);
                const p2_idx = rand.intRangeLessThan(usize, 0, num_elites);

                var child = PolicyGenome.crossover(&self.population[p1_idx], &self.population[p2_idx], rand);
                child.mutate(rand, self.config.mutation_rate, self.config.mutation_sigma);
                self.population[next_idx] = child;
            }

            self.generation += 1;
        }

        pub fn getBest(self: *const Self) *const PolicyGenome {
            return &self.population[0];
        }

        fn populationMetrics(self: *Self) @import("training_logger.zig").GenerationMetrics {
            var metrics = @import("training_logger.zig").GenerationMetrics{
                .generation = self.generation,
                .duration_ms = 0,
                .elo_min = 99999.0,
                .elo_mean = 0.0,
                .elo_median = 0.0,
                .elo_max = -99999.0,
                .fitness_best = self.population[0].fitness,
                .fitness_mean = 0.0,
                .wins = self.generation_wins,
                .losses = self.generation_losses,
                .draws = self.generation_draws,
                .total_duels = 0,
                .match_duration_bins = self.generation_match_duration_bins,
            };

            var elo_sum: f32 = 0.0;
            var fit_sum: f32 = 0.0;
            for (self.population) |g| {
                if (g.elo < metrics.elo_min) metrics.elo_min = g.elo;
                if (g.elo > metrics.elo_max) metrics.elo_max = g.elo;
                elo_sum += g.elo;
                fit_sum += g.fitness;
            }
            const pop_f = @as(f32, @floatFromInt(self.population.len));
            const matches = metrics.wins + metrics.losses + metrics.draws;
            metrics.match_duration_mean_seconds = if (matches > 0) self.generation_match_seconds / @as(f64, @floatFromInt(matches)) else 0;
            metrics.elo_mean = elo_sum / pop_f;
            metrics.fitness_mean = fit_sum / pop_f;

            const elos = self.allocator.alloc(f32, self.population.len) catch @panic("out of memory collecting Elo statistics");
            defer self.allocator.free(elos);
            var variance: f32 = 0;
            for (self.population, 0..) |g, i| {
                elos[i] = g.elo;
                variance += (g.elo - metrics.elo_mean) * (g.elo - metrics.elo_mean);
            }
            metrics.elo_stddev = @sqrt(variance / pop_f);
            std.mem.sort(f32, elos, {}, std.sort.asc(f32));
            const mid = elos.len / 2;
            metrics.elo_median = if (elos.len % 2 == 0) (elos[mid - 1] + elos[mid]) / 2 else elos[mid];
            return metrics;
        }

        /// Sample action frequency distribution and population stats across the current generation
        pub fn collectGenerationMetrics(
            self: *Self,
            gen_ms: f64,
            total_duels_in_gen: usize,
        ) @import("training_logger.zig").GenerationMetrics {
            const logger = @import("training_logger.zig");
            var metrics = self.generation_metrics orelse self.populationMetrics();
            metrics.duration_ms = gen_ms;
            metrics.total_duels = total_duels_in_gen;

            // Profile the top champion's action selection across a test simulation to measure emergent strategy
            self.arena_pool.resetDuel(0);
            const best = &self.population[0];
            const dt = self.config.physics_dt;
            const max_ticks: usize = @intFromFloat(20.0 / dt);
            var t: usize = 0;
            while (t < max_ticks) : (t += 1) {
                const dec_a = self.arena_pool.needsDecisionA(0);
                if (dec_a[0]) {
                    const obs_a = self.arena_pool.getObservationsA(0);
                    const masks_a = self.arena_pool.getActionMaskA(0);
                    const out_a = best.forward16(obs_a, masks_a);
                    const act = out_a.actions[0];
                    if (act < logger.ACTION_COUNT) {
                        metrics.action_counts[act] += 1;
                    }
                    const m_intent = out_a.move_intents[0];
                    if (m_intent < 0) {
                        metrics.move_advance_count += 1;
                    } else if (m_intent > 0) {
                        metrics.move_kite_count += 1;
                    } else {
                        metrics.move_stand_count += 1;
                    }
                    self.arena_pool.applyActionA(0, out_a.actions, out_a.move_intents);
                }
                _ = self.arena_pool.tickPhysics(dt);
                if (self.arena_pool.combat().hp_a[0] <= 0.0 or self.arena_pool.combat().hp_b[0] <= 0.0) break;
            }

            return metrics;
        }

        /// Replay a single duel visually with ASCII play-by-play output
        pub fn replayDuelVisual(
            self: *Self,
            p_a: *const PolicyGenome,
            p_b: *const PolicyGenome,
            writer: anytype,
        ) !void {
            self.arena_pool.resetDuel(0);
            const dt = self.config.physics_dt;
            const max_ticks: usize = @intFromFloat(self.config.max_duel_seconds / dt);
            var elapsed_ticks: usize = 0;

            try writer.print("\n=== ⚔️ DUEL VISUALIZATION: CHAMPION A vs CHAMPION B ===\n", .{});
            try writer.print("Starting distance: 25.0m | Dual-Clock 100Hz Physics / 10Hz Reaction\n\n", .{});

            var last_print_s: f32 = -1.0;
            var act_a_id: u32 = 0;
            var act_b_id: u32 = 0;

            while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
                const hp_a = self.arena_pool.combat().hp_a[0];
                const hp_b = self.arena_pool.combat().hp_b[0];
                if (hp_a <= 0.0 or hp_b <= 0.0) break;

                const time_s = @as(f32, @floatFromInt(elapsed_ticks)) * dt;

                // Decision A
                const dec_a = self.arena_pool.needsDecisionA(0);
                if (dec_a[0]) {
                    const obs_a = self.arena_pool.getObservationsA(0);
                    const masks_a = self.arena_pool.getActionMaskA(0);
                    const out_a = p_a.forward16(obs_a, masks_a);
                    act_a_id = out_a.actions[0];
                    self.arena_pool.applyActionA(0, out_a.actions, out_a.move_intents);
                }

                // Decision B
                const dec_b = self.arena_pool.needsDecisionB(0);
                if (dec_b[0]) {
                    const obs_b = self.arena_pool.getObservationsB(0);
                    const masks_b = self.arena_pool.getActionMaskB(0);
                    const out_b = p_b.forward16(obs_b, masks_b);
                    act_b_id = out_b.actions[0];
                    self.arena_pool.applyActionB(0, out_b.actions, out_b.move_intents);
                }

                _ = self.arena_pool.tickPhysics(dt);

                // Print snapshot every 1.5 seconds of sim time
                if (time_s - last_print_s >= 1.5) {
                    last_print_s = time_s;
                    const dist = self.arena_pool.combat().distance[0];
                    const cid_a = self.arena_pool.combat().cast_id_a[0];
                    const cid_b = self.arena_pool.combat().cast_id_b[0];

                    try writer.print("T={d:4.1}s | Dist: {d:4.1}m | [A] HP: {d:4.0}/2000 MP: {d:3.0} Act: {s} Cast: {d} | [B] HP: {d:4.0}/2000 MP: {d:3.0} Act: {s} Cast: {d}\n", .{
                        time_s,
                        dist,
                        self.arena_pool.combat().hp_a[0],
                        self.arena_pool.combat().mana_a[0],
                        class.actionNames()[act_a_id],
                        cid_a,
                        self.arena_pool.combat().hp_b[0],
                        self.arena_pool.combat().mana_b[0],
                        class.actionNames()[act_b_id],
                        cid_b,
                    });
                }
            }

            const final_time = @as(f32, @floatFromInt(elapsed_ticks)) * dt;
            try writer.print("\nDuel concluded at T={d:0.2}s!\n", .{final_time});
            if (self.arena_pool.combat().hp_a[0] > 0.0 and self.arena_pool.combat().hp_b[0] <= 0.0) {
                try writer.print("🏆 VICTOR: Unit A! (Surviving HP: {d:0.0}/2000)\n\n", .{self.arena_pool.combat().hp_a[0]});
            } else if (self.arena_pool.combat().hp_b[0] > 0.0 and self.arena_pool.combat().hp_a[0] <= 0.0) {
                try writer.print("🏆 VICTOR: Unit B! (Surviving HP: {d:0.0}/2000)\n\n", .{self.arena_pool.combat().hp_b[0]});
            } else {
                try writer.print("⚖️ DRAW! (Both alive or both dead)\n\n", .{});
            }
        }
        fn createCross(allocator: mem.Allocator) !*CrossArena {
            const arena = try allocator.create(CrossArena);
            errdefer allocator.destroy(arena);
            arena.* = try CrossArena.init(allocator, VEC_LEN);
            return arena;
        }
        fn destroyCross(allocator: mem.Allocator, arena: *CrossArena) void {
            arena.deinit();
            allocator.destroy(arena);
        }
        fn needsCross(config: LeagueConfig) bool {
            return (config.external_spec orelse class) != class or (class == .frost_mage and config.spar_gauntlet);
        }
        fn checkpointTags(config: LeagueConfig) [32]u8 {
            var tags = std.mem.zeroes([32]u8);
            tags[0] = @intFromEnum(class);
            tags[1] = @intFromEnum(config.external_spec orelse class);
            return tags;
        }
        fn runExternal(self: *Self, a: *const PolicyGenome, b: *const PolicyGenome) BatchResult {
            if ((self.config.external_spec orelse class) == class) return runBatch(&self.arena_pool, self.config, a, b, 0);
            return runBatch(self.cross_arena.?, self.config, a, b, 0);
        }

        const WorkerPool = struct {
            allocator: mem.Allocator,
            config: LeagueConfig,
            workers: []Worker,
            jobs: []MatchJob,
            results: []BatchResult,
            mutex: std.Thread.Mutex = .{},
            ready: std.Thread.Condition = .{},
            done: std.Thread.Condition = .{},
            epoch: usize = 0,
            pending: usize = 0,
            stopping: bool = false,
            next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

            const Worker = struct {
                arena: WarlockArenaPool,
                cross_arena: ?*CrossArena = null,
                thread: ?std.Thread = null,
            };

            fn init(allocator: mem.Allocator, config: LeagueConfig) !*WorkerPool {
                const pool = try allocator.create(WorkerPool);
                errdefer allocator.destroy(pool);
                const count = try std.math.mul(usize, config.pop_size, config.duels_per_agent);
                const jobs = try allocator.alloc(MatchJob, count);
                errdefer allocator.free(jobs);
                const results = try allocator.alloc(BatchResult, count);
                errdefer allocator.free(results);
                const workers = try allocator.alloc(Worker, @min(config.threads, @max(count, 1)));
                errdefer allocator.free(workers);
                pool.* = .{ .allocator = allocator, .config = config, .workers = workers, .jobs = jobs, .results = results };
                var initialized: usize = 0;
                errdefer {
                    pool.mutex.lock();
                    pool.stopping = true;
                    pool.ready.broadcast();
                    pool.mutex.unlock();
                    for (workers[0..initialized]) |*worker| {
                        if (worker.thread) |thread| thread.join();
                        if (worker.cross_arena) |cross| destroyCross(pool.allocator, cross);
                        worker.arena.deinit();
                    }
                }
                for (workers) |*worker| {
                    worker.* = .{ .arena = try WarlockArenaPool.init(allocator, VEC_LEN) };
                    initialized += 1;
                    if (needsCross(config)) worker.cross_arena = try createCross(allocator);
                    worker.thread = try std.Thread.spawn(.{}, work, .{ pool, worker });
                }
                return pool;
            }

            fn deinit(pool: *WorkerPool) void {
                pool.mutex.lock();
                pool.stopping = true;
                pool.ready.broadcast();
                pool.mutex.unlock();
                for (pool.workers) |*worker| {
                    worker.thread.?.join();
                    if (worker.cross_arena) |cross| destroyCross(pool.allocator, cross);
                    worker.arena.deinit();
                }
                const allocator = pool.allocator;
                allocator.free(pool.workers);
                allocator.free(pool.results);
                allocator.free(pool.jobs);
                allocator.destroy(pool);
            }

            fn run(pool: *WorkerPool) void {
                pool.mutex.lock();
                defer pool.mutex.unlock();
                pool.next.store(0, .monotonic);
                pool.pending = pool.workers.len;
                pool.epoch += 1;
                pool.ready.broadcast();
                while (pool.pending != 0) pool.done.wait(&pool.mutex);
            }

            fn work(pool: *WorkerPool, worker: *Worker) void {
                var epoch: usize = 0;
                pool.mutex.lock();
                defer pool.mutex.unlock();
                while (true) {
                    while (!pool.stopping and epoch == pool.epoch) pool.ready.wait(&pool.mutex);
                    if (pool.stopping) return;
                    epoch = pool.epoch;
                    pool.mutex.unlock();
                    while (true) {
                        const index = pool.next.fetchAdd(1, .monotonic);
                        if (index >= pool.jobs.len) break;
                        const job = pool.jobs[index];
                        pool.results[index] = switch (job.opponent) {
                            .bot => |bot| if (class == .frost_mage) Self.runBatchVsBot(worker.cross_arena.?, pool.config, job.a, bot, 0) else Self.runBatchVsBot(&worker.arena, pool.config, job.a, bot, 0),
                            .external => |opponent| if ((pool.config.external_spec orelse class) == class) Self.runBatch(&worker.arena, pool.config, job.a, opponent, 0) else Self.runBatch(worker.cross_arena.?, pool.config, job.a, opponent, 0),
                            .peer => |peer| Self.runBatch(&worker.arena, pool.config, job.a, peer, 0),
                            .frozen => |frozen| Self.runBatch(&worker.arena, pool.config, job.a, frozen, 0),
                        };
                    }
                    pool.mutex.lock();
                    pool.pending -= 1;
                    if (pool.pending == 0) pool.done.signal();
                }
            }
        };
    };
}

test "League initialization and one generation step" {
    var league = try League.init(std.testing.allocator, .{
        .pop_size = 16,
        .hall_of_fame_capacity = 4,
        .duels_per_agent = 1,
        .max_duel_seconds = 5.0,
    }, 42);
    defer league.deinit();

    try std.testing.expectEqual(@as(usize, 0), league.generation);
    league.stepGeneration();
    try std.testing.expectEqual(@as(usize, 1), league.generation);
    try std.testing.expect(league.total_duels_simulated > 0);
}

test "League checkpoint save and load roundtrip" {
    const allocator = std.testing.allocator;
    var league = try League.init(allocator, .{
        .pop_size = 16,
        .hall_of_fame_capacity = 4,
        .duels_per_agent = 1,
        .max_duel_seconds = 5.0,
    }, 99);
    defer league.deinit();

    league.stepGeneration();
    league.stepGeneration();

    const tmp_ckpt = "tmp_test_checkpoint.pop";
    try league.saveCheckpoint(tmp_ckpt);
    defer std.fs.cwd().deleteFile(tmp_ckpt) catch {};

    var loaded_league = try League.loadCheckpoint(allocator, tmp_ckpt, .{});
    defer loaded_league.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded_league.generation);
    try std.testing.expectEqual(league.population.len, loaded_league.population.len);
    try std.testing.expectEqual(league.getBest().elo, loaded_league.getBest().elo);
    try std.testing.expectEqual(league.total_duels_simulated, loaded_league.total_duels_simulated);
}

test "League seed from champion" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1234);
    const champ = PolicyGenome.initRandom(prng.random());

    var seeded = try League.seedFromChampion(allocator, .{ .pop_size = 16 }, &champ, 5678, 0.05);
    defer seeded.deinit();

    try std.testing.expectEqual(champ.elo, seeded.population[0].elo);
    try std.testing.expectEqual(champ.b_move, seeded.population[0].b_move);
    try std.testing.expectEqual(@as(usize, 16), seeded.population.len);
}

test "Generation statistics use sorted Elo and survive breeding" {
    var league = try League.init(std.testing.allocator, .{ .pop_size = 4, .duels_per_agent = 1, .max_duel_seconds = 1 }, 42);
    defer league.deinit();
    const elos = [_]f32{ 400, 100, 300, 200 };
    for (league.population, elos) |*g, elo| g.elo = elo;
    const stats = league.populationMetrics();
    try std.testing.expectEqual(@as(f32, 250), stats.elo_median);
    try std.testing.expectApproxEqAbs(@as(f32, 111.8034), stats.elo_stddev, 0.001);
    // Odd populations use the single middle rating.
    const full = league.population;
    league.population = full[0..3];
    const odd = league.populationMetrics();
    league.population = full;
    try std.testing.expectEqual(@as(f32, 300), odd.elo_median);
    league.stepGeneration();
    const before = league.generation_metrics.?;
    for (league.population) |*g| g.elo = 9999;
    const after = league.collectGenerationMetrics(12, before.total_duels);
    try std.testing.expectEqual(before.elo_mean, after.elo_mean);
    try std.testing.expectEqual(after.total_duels, after.wins + after.losses + after.draws);
    var duration_count: usize = 0;
    for (after.match_duration_bins) |n| duration_count += n;
    try std.testing.expectEqual(after.total_duels, duration_count);
    try std.testing.expect(after.match_duration_mean_seconds > 0 and after.match_duration_mean_seconds <= 1.001);
}

const BatchResult = struct {
    hp_a: [VEC_LEN]f32,
    hp_b: [VEC_LEN]f32,
    lane_ticks: [VEC_LEN]usize,
};
const MatchJob = struct {
    a: *PolicyGenome,
    opponent: union(enum) {
        peer: *PolicyGenome,
        frozen: *const PolicyGenome,
        external: *const PolicyGenome,
        bot: gauntlet_mod.GauntletBot,
    },
};

// Heap ownership keeps worker addresses stable when League is returned by value.
// No allocations, locks, or shared writes occur inside a duel's physics loop.

test "Persistent workers preserve exact seeded evolution and telemetry for every opponent pool" {
    for ([_]bool{ false, true }) |bots| {
        const config = LeagueConfig{ .pop_size = 8, .duels_per_agent = 4, .max_duel_seconds = 8, .spar_gauntlet = bots };
        var serial = try League.init(std.testing.allocator, config, 789);
        defer serial.deinit();
        for ([_]usize{ 2, 4, 16 }) |threads| {
            var cfg = config;
            cfg.threads = threads;
            var parallel = try League.init(std.testing.allocator, cfg, 789);
            defer parallel.deinit();
            // Restart serial for each worker count, including HoF archive at gen 10.
            var reference = try League.init(std.testing.allocator, config, 789);
            defer reference.deinit();
            try reference.addSparringPartner(serial.population[2]);
            try parallel.addSparringPartner(serial.population[2]);
            for (0..12) |_| {
                reference.stepGeneration();
                parallel.stepGeneration();
                try std.testing.expectEqualDeep(reference.population, parallel.population);
                try std.testing.expectEqualDeep(reference.hall_of_fame.items, parallel.hall_of_fame.items);
                try std.testing.expectEqualDeep(reference.sparring_partners.items, parallel.sparring_partners.items);
                try std.testing.expectEqualDeep(reference.prng, parallel.prng);
                try std.testing.expectEqual(reference.total_duels_simulated, parallel.total_duels_simulated);
                const a = reference.collectGenerationMetrics(0, reference.generation_metrics.?.total_duels);
                const b = parallel.collectGenerationMetrics(0, parallel.generation_metrics.?.total_duels);
                try std.testing.expectEqualDeep(a, b);
            }
        }
    }
}

test "Worker checkpoints resume equivalently across thread counts" {
    const config = LeagueConfig{ .pop_size = 8, .duels_per_agent = 2, .max_duel_seconds = 3, .threads = 4, .spar_gauntlet = true };
    var original = try League.init(std.testing.allocator, config, 321);
    defer original.deinit();
    try original.addSparringPartner(original.population[1]);
    original.stepGeneration();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fs.path.join(std.testing.allocator, &.{ path, "state.pop" });
    defer std.testing.allocator.free(checkpoint);
    try original.saveCheckpoint(checkpoint);
    var serial_config = config;
    serial_config.threads = 1;
    var serial = try League.loadCheckpoint(std.testing.allocator, checkpoint, serial_config);
    defer serial.deinit();
    var parallel = try League.loadCheckpoint(std.testing.allocator, checkpoint, config);
    defer parallel.deinit();
    for (0..3) |_| {
        serial.stepGeneration();
        parallel.stepGeneration();
        try std.testing.expectEqualDeep(serial.population, parallel.population);
        try std.testing.expectEqualDeep(serial.generation_metrics, parallel.generation_metrics);
    }
}

test "Frost training preserves seeded evolution and telemetry across workers with Warlock sparring and bots" {
    const config = LeagueConfig{ .pop_size = 8, .duels_per_agent = 4, .max_duel_seconds = 4, .external_spec = .warlock, .spar_gauntlet = true };
    var serial = try FrostMageLeague.init(std.testing.allocator, config, 234);
    defer serial.deinit();
    var parallel_config = config;
    parallel_config.threads = 4;
    var parallel = try FrostMageLeague.init(std.testing.allocator, parallel_config, 234);
    defer parallel.deinit();
    try serial.addSparringPartner(serial.population[2]);
    try parallel.addSparringPartner(serial.population[2]);
    for (0..12) |_| {
        serial.stepGeneration();
        parallel.stepGeneration();
        try std.testing.expectEqualDeep(serial.population, parallel.population);
        try std.testing.expectEqualDeep(serial.hall_of_fame.items, parallel.hall_of_fame.items);
        try std.testing.expectEqualDeep(serial.sparring_partners.items, parallel.sparring_partners.items);
        try std.testing.expectEqualDeep(serial.prng, parallel.prng);
        const a = serial.collectGenerationMetrics(0, serial.generation_metrics.?.total_duels);
        const b = parallel.collectGenerationMetrics(0, parallel.generation_metrics.?.total_duels);
        try std.testing.expectEqualDeep(a, b);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "frost.pop" });
    defer std.testing.allocator.free(path);
    try serial.saveCheckpoint(path);
    try std.testing.expectError(error.CheckpointSpecMismatch, League.loadCheckpoint(std.testing.allocator, path, config));
    try std.testing.expectError(error.CheckpointOpponentSpecMismatch, FrostMageLeague.loadCheckpoint(std.testing.allocator, path, .{}));
    var resumed_serial = try FrostMageLeague.loadCheckpoint(std.testing.allocator, path, config);
    defer resumed_serial.deinit();
    var resumed_parallel = try FrostMageLeague.loadCheckpoint(std.testing.allocator, path, parallel_config);
    defer resumed_parallel.deinit();
    for (0..3) |_| {
        resumed_serial.stepGeneration();
        resumed_parallel.stepGeneration();
        try std.testing.expectEqualDeep(resumed_serial.population, resumed_parallel.population);
        try std.testing.expectEqualDeep(resumed_serial.generation_metrics, resumed_parallel.generation_metrics);
    }
}
