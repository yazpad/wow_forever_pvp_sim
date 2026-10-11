const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");
const match_recorder = @import("match_recorder.zig");

const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const bool16 = simd.bool16;
const select16 = simd.select16;
const VEC_LEN = simd.SimdConfig.VecLen16;

const WarlockAction = combat_spec.WarlockAction;
const WarlockConstants = combat_spec.WarlockConstants;
const WarlockArenaPool = combat_spec.WarlockArenaPool;
const PolicyGenome = policy_simd.PolicyGenome;
const MatchTrajectory = match_recorder.MatchTrajectory;
const RecordedFrame = match_recorder.RecordedFrame;

pub const GauntletBotKind = enum(u32) {
    AggroRusher = 0,
    FearKiter = 1,
    TurretCaster = 2,
    DrainTank = 3,

    pub const COUNT: usize = 4;

    pub fn getName(self: GauntletBotKind) []const u8 {
        return switch (self) {
            .AggroRusher => "Aggro Rusher Bot",
            .FearKiter => "Fear-Kite Specialist",
            .TurretCaster => "Turret Caster Bot",
            .DrainTank => "Drain-Tank Turtle",
        };
    }

    pub fn getIcon(self: GauntletBotKind) []const u8 {
        return switch (self) {
            .AggroRusher => "🗡️",
            .FearKiter => "🏃",
            .TurretCaster => "🏰",
            .DrainTank => "🛡️",
        };
    }

    pub fn getDescription(self: GauntletBotKind) []const u8 {
        return switch (self) {
            .AggroRusher => "Hyper-aggressive gap closer, instant DOT spammer, drains on low HP",
            .FearKiter => "Kites to 18-22m, prioritizes Fear crowd control, punishes while feared",
            .TurretCaster => "Stationary artillery, keeps DOTs rolling, casts heavy Shadow Bolts",
            .DrainTank => "Activates defensive early, relentlessly channels Drain Life to sustain",
        };
    }

    pub fn getBaselineElo(self: GauntletBotKind) f32 {
        return switch (self) {
            .AggroRusher => 1250.0,
            .FearKiter => 1450.0,
            .TurretCaster => 1350.0,
            .DrainTank => 1400.0,
        };
    }

    pub fn parse(str: []const u8) ?GauntletBotKind {
        if (std.ascii.eqlIgnoreCase(str, "aggro") or std.ascii.eqlIgnoreCase(str, "aggro_rusher") or std.ascii.eqlIgnoreCase(str, "rusher")) {
            return .AggroRusher;
        } else if (std.ascii.eqlIgnoreCase(str, "kiter") or std.ascii.eqlIgnoreCase(str, "fear_kiter") or std.ascii.eqlIgnoreCase(str, "fear")) {
            return .FearKiter;
        } else if (std.ascii.eqlIgnoreCase(str, "turret") or std.ascii.eqlIgnoreCase(str, "turret_caster") or std.ascii.eqlIgnoreCase(str, "caster")) {
            return .TurretCaster;
        } else if (std.ascii.eqlIgnoreCase(str, "draintank") or std.ascii.eqlIgnoreCase(str, "drain_tank") or std.ascii.eqlIgnoreCase(str, "tank")) {
            return .DrainTank;
        }
        return null;
    }
};

pub const GauntletBot = struct {
    kind: GauntletBotKind,

    pub fn init(kind: GauntletBotKind) GauntletBot {
        return .{ .kind = kind };
    }

    /// Evaluates 16 lanes in parallel according to the bot's heuristic rules.
    /// Uses the 24-element normalized observation layout from combat_spec.zig.
    pub fn forward16(
        self: GauntletBot,
        obs: [24]f32x16,
        masks: [WarlockAction.COUNT]bool16,
    ) struct { actions: u32x16, move_intents: f32x16 } {
        var actions: u32x16 = @splat(@intFromEnum(WarlockAction.IdleOrManeuver));
        var move_intents: f32x16 = @splat(0.0);

        const act_idle: u32 = @intFromEnum(WarlockAction.IdleOrManeuver);
        const act_agony: u32 = @intFromEnum(WarlockAction.Agony);
        const act_corr: u32 = @intFromEnum(WarlockAction.Corruption);
        const act_fear: u32 = @intFromEnum(WarlockAction.Fear);
        const act_bolt: u32 = @intFromEnum(WarlockAction.ShadowBolt);
        const act_drain: u32 = @intFromEnum(WarlockAction.DrainLife);
        const act_def: u32 = @intFromEnum(WarlockAction.UnendingResolve);
        const act_dc: u32 = @intFromEnum(WarlockAction.DeathCoil);

        for (0..VEC_LEN) |lane| {
            const my_hp = obs[0][lane];
            const opp_hp = obs[2][lane];
            const dist_m = obs[4][lane] * WarlockConstants.MaxDistance;
            const agony_pct = obs[11][lane];
            const corr_pct = obs[12][lane];
            const opp_feared = obs[13][lane] > 0.5;
            const opp_casting = obs[8][lane] > 0.5;

            const mask_agony = masks[act_agony][lane];
            const mask_corr = masks[act_corr][lane];
            const mask_fear = masks[act_fear][lane];
            const mask_bolt = masks[act_bolt][lane];
            const mask_drain = masks[act_drain][lane];
            const mask_def = masks[act_def][lane];
            const mask_dc = masks[act_dc][lane];

            var chosen_act: u32 = act_idle;
            var chosen_move: f32 = 0.0;

            switch (self.kind) {
                .AggroRusher => {
                    // Movement: Always aggressively close distance
                    chosen_move = -1.0;

                    // Priority 1: Defensive if HP < 65%
                    if (my_hp < 0.65 and mask_def) {
                        chosen_act = act_def;
                    }
                    // Priority 2: Death Coil if injured (< 60% HP) or to interrupt enemy casting
                    else if ((my_hp < 0.60 or opp_casting) and mask_dc and dist_m <= WarlockConstants.DeathCoilRange) {
                        chosen_act = act_dc;
                    }
                    // Priority 3: Apply Agony if missing or expiring (< 20%)
                    else if (agony_pct < 0.20 and mask_agony) {
                        chosen_act = act_agony;
                    }
                    // Priority 4: Apply Corruption if missing or expiring (< 20%)
                    else if (corr_pct < 0.20 and mask_corr) {
                        chosen_act = act_corr;
                    }
                    // Priority 5: If target < 35% HP or self < 50% HP, Drain Life to finish/sustain
                    else if ((opp_hp < 0.35 or my_hp < 0.50) and mask_drain and dist_m <= WarlockConstants.DrainLifeRange) {
                        chosen_act = act_drain;
                    }
                    // Priority 6: Cast Shadow Bolt if target Feared or at range
                    else if (mask_bolt) {
                        chosen_act = act_bolt;
                    }
                    // Priority 7: Drain Life
                    else if (mask_drain and dist_m <= WarlockConstants.DrainLifeRange) {
                        chosen_act = act_drain;
                    }
                },

                .FearKiter => {
                    // Movement: Maintain 18m - 22m sweet spot
                    if (dist_m < 18.0) {
                        chosen_move = 1.0; // Kite away
                    } else if (dist_m > 22.0) {
                        chosen_move = -1.0; // Advance into range
                    } else {
                        chosen_move = 0.0; // Perfect range
                    }

                    // Priority 1: Defensive if HP < 45%
                    if (my_hp < 0.45 and mask_def) {
                        chosen_act = act_def;
                    }
                    // Priority 2: Death Coil if pressured / close or enemy casting
                    else if ((dist_m < 15.0 or opp_casting or my_hp < 0.50) and mask_dc and dist_m <= WarlockConstants.DeathCoilRange) {
                        chosen_act = act_dc;
                    }
                    // Priority 3: If target is not feared and within Fear range, cast Fear!
                    else if (!opp_feared and dist_m <= WarlockConstants.FearRange and mask_fear) {
                        chosen_act = act_fear;
                    }
                    // Priority 4: If target is casting a spell and we can fear them, interrupt with Fear!
                    else if (opp_casting and dist_m <= WarlockConstants.FearRange and mask_fear) {
                        chosen_act = act_fear;
                    }
                    // Priority 5: Apply Agony
                    else if (agony_pct < 0.25 and mask_agony) {
                        chosen_act = act_agony;
                    }
                    // Priority 6: Apply Corruption
                    else if (corr_pct < 0.25 and mask_corr) {
                        chosen_act = act_corr;
                    }
                    // Priority 7: While target is feared, punish with Shadow Bolt
                    else if (opp_feared and mask_bolt) {
                        chosen_act = act_bolt;
                    }
                    // Priority 8: Drain Life if self injured
                    else if (my_hp < 0.80 and mask_drain and dist_m <= WarlockConstants.DrainLifeRange) {
                        chosen_act = act_drain;
                    }
                    // Priority 9: Shadow Bolt
                    else if (mask_bolt) {
                        chosen_act = act_bolt;
                    }
                },

                .TurretCaster => {
                    // Movement: Immovable turret
                    chosen_move = 0.0;

                    // Priority 1: Defensive if HP < 60%
                    if (my_hp < 0.60 and mask_def) {
                        chosen_act = act_def;
                    }
                    // Priority 2: Death Coil peel if enemy gets close or casting
                    else if ((dist_m < 15.0 or opp_casting) and mask_dc and dist_m <= WarlockConstants.DeathCoilRange) {
                        chosen_act = act_dc;
                    }
                    // Priority 3: Keep Agony on target
                    else if (agony_pct < 0.20 and mask_agony) {
                        chosen_act = act_agony;
                    }
                    // Priority 4: Keep Corruption on target
                    else if (corr_pct < 0.20 and mask_corr) {
                        chosen_act = act_corr;
                    }
                    // Priority 5: Cast Fear if enemy gets too close (< 10m)
                    else if (dist_m < 10.0 and !opp_feared and mask_fear) {
                        chosen_act = act_fear;
                    }
                    // Priority 6: Heavy Shadow Bolt artillery
                    else if (mask_bolt) {
                        chosen_act = act_bolt;
                    }
                    // Priority 7: Drain Life
                    else if (mask_drain and dist_m <= WarlockConstants.DrainLifeRange) {
                        chosen_act = act_drain;
                    }
                },

                .DrainTank => {
                    // Movement: Keep at 10m - 20m
                    if (dist_m < 10.0) {
                        chosen_move = 1.0; // Back up slightly
                    } else if (dist_m > 22.0) {
                        chosen_move = -1.0; // Get in drain range
                    } else {
                        chosen_move = 0.0;
                    }

                    // Priority 1: Pop Defensive early (HP < 85%) for sustained mitigation
                    if (my_hp < 0.85 and mask_def) {
                        chosen_act = act_def;
                    }
                    // Priority 2: Death Coil when dropping under 70% HP
                    else if (my_hp < 0.70 and mask_dc and dist_m <= WarlockConstants.DeathCoilRange) {
                        chosen_act = act_dc;
                    }
                    // Priority 3: Apply Agony
                    else if (agony_pct < 0.20 and mask_agony) {
                        chosen_act = act_agony;
                    }
                    // Priority 4: Apply Corruption
                    else if (corr_pct < 0.20 and mask_corr) {
                        chosen_act = act_corr;
                    }
                    // Priority 5: Relentless Drain Life channel
                    else if (mask_drain and dist_m <= WarlockConstants.DrainLifeRange) {
                        chosen_act = act_drain;
                    }
                    // Priority 6: Fear if enemy in close range
                    else if (dist_m < 12.0 and !opp_feared and mask_fear) {
                        chosen_act = act_fear;
                    }
                    // Priority 7: Shadow Bolt
                    else if (mask_bolt) {
                        chosen_act = act_bolt;
                    }
                },
            }

            actions[lane] = chosen_act;
            move_intents[lane] = chosen_move;
        }

        return .{
            .actions = actions,
            .move_intents = move_intents,
        };
    }
};

pub const BotBenchmarkResult = struct {
    bot_kind: GauntletBotKind,
    duels_fought: u32,
    wins: u32,
    losses: u32,
    draws: u32,
    win_rate: f32,
    avg_duration_s: f32,
    avg_surviving_hp: f32,
};

pub const GauntletReport = struct {
    champion_elo: f32,
    total_duels: u32,
    total_wins: u32,
    total_losses: u32,
    total_draws: u32,
    overall_win_rate: f32,
    objective_elo: f32,
    bot_results: [GauntletBotKind.COUNT]BotBenchmarkResult,
};

pub const GauntletRunner = struct {
    allocator: mem.Allocator,
    arena_pool: WarlockArenaPool,

    pub fn init(allocator: mem.Allocator) !GauntletRunner {
        var arena = try WarlockArenaPool.init(allocator, 64);
        errdefer arena.deinit();

        return GauntletRunner{
            .allocator = allocator,
            .arena_pool = arena,
        };
    }

    pub fn deinit(self: *GauntletRunner) void {
        self.arena_pool.deinit();
    }

    /// Evaluates a candidate PolicyGenome against all 4 Gauntlet Bots.
    /// Runs multiple 16-duel batches per bot archetype with SIMD throughput.
    pub fn evaluateChampion(
        self: *GauntletRunner,
        champion: *const PolicyGenome,
        duels_per_bot: usize,
        max_duel_seconds: f32,
        physics_dt: f32,
    ) GauntletReport {
        const batch_size = VEC_LEN;
        const num_batches = @max(1, (duels_per_bot + batch_size - 1) / batch_size);
        const actual_duels_per_bot = num_batches * batch_size;

        var report = GauntletReport{
            .champion_elo = champion.elo,
            .total_duels = 0,
            .total_wins = 0,
            .total_losses = 0,
            .total_draws = 0,
            .overall_win_rate = 0.0,
            .objective_elo = 1200.0,
            .bot_results = undefined,
        };

        var weighted_elo_sum: f32 = 0.0;
        var total_weight: f32 = 0.0;

        inline for (0..GauntletBotKind.COUNT) |b_idx| {
            const kind: GauntletBotKind = @enumFromInt(b_idx);
            const bot = GauntletBot.init(kind);

            var bot_wins: u32 = 0;
            var bot_losses: u32 = 0;
            var bot_draws: u32 = 0;
            var bot_time_sum: f32 = 0.0;
            var bot_hp_sum: f32 = 0.0;

            for (0..num_batches) |_| {
                // Reset 16 lanes
                for (0..batch_size) |lane| {
                    self.arena_pool.resetDuel(lane);
                }

                const max_ticks: usize = @intFromFloat(max_duel_seconds / physics_dt);
                var elapsed_ticks: usize = 0;

                while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
                    const act_mask = self.arena_pool.is_active[0..batch_size].* > @as(u32x16, @splat(0));
                    if (!@reduce(.Or, act_mask)) break;

                    // 1. Champion Decision (Team A)
                    const dec_a = self.arena_pool.needsDecisionA(0);
                    if (@reduce(.Or, dec_a)) {
                        const obs_a = self.arena_pool.getObservationsA(0);
                        const masks_a = self.arena_pool.getActionMaskA(0);
                        const out_a = champion.forward16(obs_a, masks_a);
                        self.arena_pool.applyActionA(0, out_a.actions, out_a.move_intents);
                    }

                    // 2. Gauntlet Bot Decision (Team B)
                    const dec_b = self.arena_pool.needsDecisionB(0);
                    if (@reduce(.Or, dec_b)) {
                        const obs_b = self.arena_pool.getObservationsB(0);
                        const masks_b = self.arena_pool.getActionMaskB(0);
                        const out_b = bot.forward16(obs_b, masks_b);
                        self.arena_pool.applyActionB(0, out_b.actions, out_b.move_intents);
                    }

                    // 3. Step Physics (100 Hz)
                    _ = self.arena_pool.tickPhysics(physics_dt);
                }

                // Tally batch
                const match_time = @as(f32, @floatFromInt(elapsed_ticks)) * physics_dt;
                for (0..batch_size) |lane| {
                    const hp_a = self.arena_pool.hp_a[lane];
                    const hp_b = self.arena_pool.hp_b[lane];

                    bot_time_sum += match_time;
                    bot_hp_sum += @max(0.0, hp_a);

                    if (hp_a > 0.0 and hp_b <= 0.0) {
                        bot_wins += 1;
                    } else if (hp_b > 0.0 and hp_a <= 0.0) {
                        bot_losses += 1;
                    } else {
                        bot_draws += 1;
                    }
                }
            }

            const total_b = @as(f32, @floatFromInt(actual_duels_per_bot));
            const win_rate = @as(f32, @floatFromInt(bot_wins)) / total_b;

            report.bot_results[b_idx] = .{
                .bot_kind = kind,
                .duels_fought = @intCast(actual_duels_per_bot),
                .wins = bot_wins,
                .losses = bot_losses,
                .draws = bot_draws,
                .win_rate = win_rate,
                .avg_duration_s = bot_time_sum / total_b,
                .avg_surviving_hp = bot_hp_sum / total_b,
            };

            report.total_duels += @intCast(actual_duels_per_bot);
            report.total_wins += bot_wins;
            report.total_losses += bot_losses;
            report.total_draws += bot_draws;

            // Objective Elo Calculation based on baseline opponent ratings:
            // Score = wins + 0.5 * draws
            const score = @as(f32, @floatFromInt(bot_wins)) + 0.5 * @as(f32, @floatFromInt(bot_draws));
            const score_ratio = @min(0.99, @max(0.01, score / total_b));
            // Logit-based Elo estimate vs this bot: Elo_opp - 400 * log10((1 - S) / S)
            const elo_delta = -400.0 * @log10((1.0 - score_ratio) / score_ratio);
            const est_elo = kind.getBaselineElo() + elo_delta;

            weighted_elo_sum += est_elo;
            total_weight += 1.0;
        }

        report.overall_win_rate = @as(f32, @floatFromInt(report.total_wins)) / @as(f32, @floatFromInt(report.total_duels));
        report.objective_elo = weighted_elo_sum / total_weight;

        return report;
    }

    /// Record a high-fidelity 100 Hz duel between a PolicyGenome and a specific Gauntlet Bot
    pub fn recordDuelVsBot(
        allocator: mem.Allocator,
        p_a: *const PolicyGenome,
        bot_kind: GauntletBotKind,
        name_a: []const u8,
        max_seconds: f32,
        dt: f32,
    ) !MatchTrajectory {
        var arena = try WarlockArenaPool.init(allocator, 16);
        defer arena.deinit();

        arena.resetDuel(0);
        const bot = GauntletBot.init(bot_kind);

        var traj = try MatchTrajectory.init(allocator, name_a, bot_kind.getName(), p_a.elo, bot_kind.getBaselineElo());
        errdefer traj.deinit();

        const max_ticks: usize = @intFromFloat(max_seconds / dt);
        var elapsed_ticks: usize = 0;

        var pos_a: f32 = -12.5;
        var pos_b: f32 = 12.5;

        var last_act_a: u32 = 0;
        var last_act_b: u32 = 0;

        var prev_hp_a = arena.hp_a[0];
        var prev_hp_b = arena.hp_b[0];
        var prev_cid_a: u32 = arena.cast_id_a[0];
        var prev_cid_b: u32 = arena.cast_id_b[0];
        var prev_ctmr_a: f32 = arena.cast_timer_a[0];
        var prev_ctmr_b: f32 = arena.cast_timer_b[0];
        var prev_fear_a = arena.fear_timer_a[0];
        var prev_fear_b = arena.fear_timer_b[0];
        var prev_un_a = arena.unending_dur_a[0];
        var prev_un_b = arena.unending_dur_b[0];

        while (elapsed_ticks < max_ticks) : (elapsed_ticks += 1) {
            const cur_hp_a = arena.hp_a[0];
            const cur_hp_b = arena.hp_b[0];
            if (cur_hp_a <= 0.0 or cur_hp_b <= 0.0) break;

            const time_s = @as(f32, @floatFromInt(elapsed_ticks)) * dt;

            // Decision A (Champion)
            const dec_a = arena.needsDecisionA(0);
            if (dec_a[0]) {
                const obs_a = arena.getObservationsA(0);
                const masks_a = arena.getActionMaskA(0);
                const out_a = p_a.forward16(obs_a, masks_a);
                last_act_a = out_a.actions[0];
                arena.applyActionA(0, out_a.actions, out_a.move_intents);

                if (last_act_a != 0) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 0,
                        .target = 1,
                        .kind = .ActionUsed,
                        .spell_id = last_act_a,
                        .amount = 0.0,
                    });
                }
            }

            // Decision B (Gauntlet Bot)
            const dec_b = arena.needsDecisionB(0);
            if (dec_b[0]) {
                const obs_b = arena.getObservationsB(0);
                const masks_b = arena.getActionMaskB(0);
                const out_b = bot.forward16(obs_b, masks_b);
                last_act_b = out_b.actions[0];
                arena.applyActionB(0, out_b.actions, out_b.move_intents);

                if (last_act_b != 0) {
                    try traj.events.append(.{
                        .time_s = time_s,
                        .source = 1,
                        .target = 0,
                        .kind = .ActionUsed,
                        .spell_id = last_act_b,
                        .amount = 0.0,
                    });
                }
            }

            _ = arena.tickPhysics(dt);

            // Update Positions
            const mv_a = arena.move_intent_a[0];
            const mv_b = arena.move_intent_b[0];
            const is_cast_a = arena.cast_id_a[0] > 0;
            const is_cast_b = arena.cast_id_b[0] > 0;
            const is_feared_a = arena.fear_timer_a[0] > 0.0;
            const is_feared_b = arena.fear_timer_b[0] > 0.0;

            var spd_a: f32 = 0.0;
            if (!is_cast_a and !is_feared_a) {
                if (mv_a < 0.0) spd_a = WarlockConstants.ForwardSpeed else if (mv_a > 0.0) spd_a = -WarlockConstants.BackpedalSpeed;
            } else if (is_feared_a) {
                spd_a = -WarlockConstants.ForwardSpeed;
            }

            var spd_b: f32 = 0.0;
            if (!is_cast_b and !is_feared_b) {
                if (mv_b < 0.0) spd_b = -WarlockConstants.ForwardSpeed else if (mv_b > 0.0) spd_b = WarlockConstants.BackpedalSpeed;
            } else if (is_feared_b) {
                spd_b = WarlockConstants.ForwardSpeed;
            }

            pos_a = @min(pos_b - WarlockConstants.MinDistance, @max(-30.0, pos_a + spd_a * dt));
            pos_b = @max(pos_a + WarlockConstants.MinDistance, @min(30.0, pos_b + spd_b * dt));

            // Record events
            if (arena.unending_dur_a[0] > 0.0 and prev_un_a == 0.0) {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .DefensiveActivated, .spell_id = 6, .amount = 0.0 });
            }
            if (arena.unending_dur_b[0] > 0.0 and prev_un_b == 0.0) {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .DefensiveActivated, .spell_id = 6, .amount = 0.0 });
            }
            if (arena.fear_timer_b[0] > 0.0 and prev_fear_b == 0.0) {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .FearApplied, .spell_id = 3, .amount = 0.0 });
            }
            if (arena.fear_timer_a[0] > 0.0 and prev_fear_a == 0.0) {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .FearApplied, .spell_id = 3, .amount = 0.0 });
            }

            // Damage delta detection
            if (arena.hp_b[0] < prev_hp_b) {
                const dmg = prev_hp_b - arena.hp_b[0];
                traj.total_dmg_a += dmg;
                if (dmg > 50.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .DamageHit, .spell_id = 4, .amount = dmg });
                }
            }
            if (arena.hp_a[0] < prev_hp_a) {
                const dmg = prev_hp_a - arena.hp_a[0];
                traj.total_dmg_b += dmg;
                if (dmg > 50.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .DamageHit, .spell_id = 4, .amount = dmg });
                }
            }

            prev_hp_a = arena.hp_a[0];
            prev_hp_b = arena.hp_b[0];
            prev_cid_a = arena.cast_id_a[0];
            prev_cid_b = arena.cast_id_b[0];
            prev_ctmr_a = arena.cast_timer_a[0];
            prev_ctmr_b = arena.cast_timer_b[0];
            prev_fear_a = arena.fear_timer_a[0];
            prev_fear_b = arena.fear_timer_b[0];
            prev_un_a = arena.unending_dur_a[0];
            prev_un_b = arena.unending_dur_b[0];

            try traj.frames.append(.{
                .time_s = time_s,
                .dist = arena.distance[0],
                .pos_a = pos_a,
                .pos_b = pos_b,
                .hp_a = arena.hp_a[0],
                .hp_b = arena.hp_b[0],
                .mana_a = arena.mana_a[0],
                .mana_b = arena.mana_b[0],
                .speed_a = spd_a,
                .speed_b = spd_b,
                .cast_id_a = arena.cast_id_a[0],
                .cast_id_b = arena.cast_id_b[0],
                .cast_timer_a = arena.cast_timer_a[0],
                .cast_timer_b = arena.cast_timer_b[0],
                .cast_total_a = arena.cast_total_a[0],
                .cast_total_b = arena.cast_total_b[0],
                .agony_a = arena.agony_timer_a[0],
                .agony_b = arena.agony_timer_b[0],
                .corruption_a = arena.corruption_timer_a[0],
                .corruption_b = arena.corruption_timer_b[0],
                .fear_a = arena.fear_timer_a[0],
                .fear_b = arena.fear_timer_b[0],
                .horror_a = arena.horror_timer_a[0],
                .horror_b = arena.horror_timer_b[0],
                .unending_dur_a = arena.unending_dur_a[0],
                .unending_dur_b = arena.unending_dur_b[0],
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
                .action_a = last_act_a,
                .action_b = last_act_b,
            });
        }

        traj.total_time_s = @as(f32, @floatFromInt(elapsed_ticks)) * dt;
        if (arena.hp_a[0] > 0.0 and arena.hp_b[0] <= 0.0) {
            traj.victor = 0;
        } else if (arena.hp_b[0] > 0.0 and arena.hp_a[0] <= 0.0) {
            traj.victor = 1;
        } else {
            traj.victor = 2;
        }

        return traj;
    }

    /// Print formatted objective gauntlet scorecard
    pub fn printReport(report: *const GauntletReport, writer: anytype) !void {
        try writer.print("\n╔══════════════════════════════════════════════════════════════════════════════╗\n", .{});
        try writer.print("║                   ⚔️  OBJECTIVE GAUNTLET BENCHMARK REPORT                    ║\n", .{});
        try writer.print("╠══════════════════════════╦══════════════╦════════════════╦═══════════════════╣\n", .{});
        try writer.print("║ Opponent Bot             ║ Win Rate     ║ Record (W/L/D) ║ Avg Surviving HP  ║\n", .{});
        try writer.print("╠══════════════════════════╬══════════════╬════════════════╬═══════════════════╣\n", .{});

        for (report.bot_results) |res| {
            try writer.print("║ {s} {s: <20} ║   {d:5.1}%     ║ {d:3}W/{d:3}L/{d:3}D  ║   {d:4.0}/2000 HP   ║\n", .{
                res.bot_kind.getIcon(),
                res.bot_kind.getName(),
                res.win_rate * 100.0,
                res.wins,
                res.losses,
                res.draws,
                res.avg_surviving_hp,
            });
        }

        try writer.print("╠══════════════════════════╬══════════════╬════════════════╬═══════════════════╣\n", .{});
        try writer.print("║ 🏆 OVERALL PERFORMANCE   ║   {d:5.1}%     ║ {d:3}W/{d:3}L/{d:3}D  ║ Objective Elo: {d:4.0}║\n", .{
            report.overall_win_rate * 100.0,
            report.total_wins,
            report.total_losses,
            report.total_draws,
            report.objective_elo,
        });
        try writer.print("╚══════════════════════════╩══════════════╩════════════════╩═══════════════════╝\n\n", .{});
    }
};

test "GauntletBot decision forward16" {
    inline for (0..GauntletBotKind.COUNT) |b_idx| {
        const kind: GauntletBotKind = @enumFromInt(b_idx);
        const bot = GauntletBot.init(kind);

        var obs: [policy_simd.IN_DIM]f32x16 = undefined;
        for (0..policy_simd.IN_DIM) |i| {
            obs[i] = @splat(0.5);
        }
        var masks: [WarlockAction.COUNT]bool16 = undefined;
        for (0..WarlockAction.COUNT) |a| {
            masks[a] = @splat(true);
        }

        const out = bot.forward16(obs, masks);
        try std.testing.expect(out.actions[0] < WarlockAction.COUNT);
        try std.testing.expect(out.move_intents[0] >= -1.0 and out.move_intents[0] <= 1.0);
    }
}

test "GauntletRunner evaluation throughput" {
    var prng = std.Random.DefaultPrng.init(42);
    const champion = PolicyGenome.initRandom(prng.random());

    var runner = try GauntletRunner.init(std.testing.allocator);
    defer runner.deinit();

    const report = runner.evaluateChampion(&champion, 16, 5.0, 0.010);
    try std.testing.expectEqual(@as(u32, 64), report.total_duels);
    try std.testing.expect(report.overall_win_rate >= 0.0 and report.overall_win_rate <= 1.0);
    try std.testing.expect(report.objective_elo > 500.0 and report.objective_elo < 3000.0);
}
