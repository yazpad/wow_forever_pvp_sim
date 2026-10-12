const std = @import("std");
const simd = @import("simd.zig");
const combat_soa = @import("combat_soa.zig");
const combat_spec = @import("combat_spec.zig");
const policy_simd = @import("policy_simd.zig");
const league_mod = @import("league.zig");
const match_recorder = @import("match_recorder.zig");
const gauntlet_mod = @import("gauntlet.zig");
const training_logger = @import("training_logger.zig");
const spec_matrix_mod = @import("spec_matrix.zig");
const spec_status_mod = @import("spec_status.zig");

const CombatantPool = combat_soa.CombatantPool;
const MatchRecorder = match_recorder.MatchRecorder;
const GauntletRunner = gauntlet_mod.GauntletRunner;
const GauntletBotKind = gauntlet_mod.GauntletBotKind;
const TrainingLogger = training_logger.TrainingLogger;
const SpecMatrixEvaluator = spec_matrix_mod.SpecMatrixEvaluator;
const Spec = @import("spec.zig").Spec;
const spec_policy = @import("spec_policy.zig");

fn exportAndMaybeVisualize(
    allocator: std.mem.Allocator,
    traj: *const match_recorder.MatchTrajectory,
    out_path_opt: ?[]const u8,
    launch_vis: bool,
    stdout: anytype,
) !void {
    const default_lua_path: []const u8 = "last_match.lua";
    const effective_path: ?[]const u8 = out_path_opt orelse (if (launch_vis) default_lua_path else null);
    if (effective_path) |out_path| {
        if (std.mem.endsWith(u8, out_path, ".json")) {
            try traj.exportJson(out_path);
            try stdout.print("  -> Saved match trajectory JSON to '{s}'\n", .{out_path});
        } else {
            // Default to high-performance Lua for Love2D
            try traj.exportLua(out_path);
            try stdout.print("  -> Saved match trajectory Lua to '{s}'\n", .{out_path});
        }
    }

    if (launch_vis) {
        const file_to_open = out_path_opt orelse "last_match.lua";
        if (!std.mem.endsWith(u8, file_to_open, ".lua")) {
            try traj.exportLua("last_match.lua");
        }
        try stdout.print("  -> Launching native Love2D 2D arena visualizer...\n\n", .{});
        var child = std.process.Child.init(&[_][]const u8{ "love", "visualizer", file_to_open }, allocator);
        _ = child.spawn() catch |err| {
            try stdout.print("  [Note] Could not launch love automatically: {}\n", .{err});
            try stdout.print("  Run manually with: love visualizer {s}\n\n", .{file_to_open});
            return;
        };
        _ = child.wait() catch {};
    }
}

pub fn main() !void {
    var args = std.process.args();
    var class: Spec = .warlock;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--class")) class = Spec.parse(args.next() orelse return error.MissingClass) orelse return error.UnknownClass;
    }
    switch (class) {
        .warlock => try runMain(.warlock),
        .frost_mage => try runMain(.frost_mage),
    }
}

fn runMain(comptime class: Spec) !void {
    const ClassLeague = league_mod.LeagueFor(class);
    const ClassGauntlet = gauntlet_mod.GauntletFor(class);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Default Configuration
    var train_only = false;
    var external_spec: ?Spec = null;
    var live_metrics = false;
    var stop_file: ?[]const u8 = null;
    var num_generations: usize = 10;
    var threads: usize = 1;
    var pop_size: usize = 64;
    var duels_per_agent: usize = 4;
    var render_best: bool = false;
    var save_champion_path: ?[]const u8 = null;
    var save_population_path: ?[]const u8 = null;
    var resume_checkpoint_path: ?[]const u8 = null;
    var seed_from_path: ?[]const u8 = null;
    var checkpoint_interval: ?usize = null;
    var gauntlet_interval: ?usize = null;
    var run_gauntlet_end: bool = false;
    var spar_gauntlet: bool = false;

    var sparring_opponent_path: ?[]const u8 = null;
    var sparring_pool_dir: ?[]const u8 = null;

    var metrics_path: ?[]const u8 = "training_metrics.lua";
    var launch_visualizer: bool = false;
    var visualize_graphs: bool = false;
    var record_match_path: ?[]const u8 = null;
    var eval_model_a: ?[]const u8 = null;
    var eval_model_b: ?[]const u8 = null;
    var eval_gauntlet_path: ?[]const u8 = null;
    var eval_bot_model_path: ?[]const u8 = null;
    var eval_bot_target_name: ?[]const u8 = null;

    var eval_matrix_dir: ?[]const u8 = null;
    var matrix_out_path: []const u8 = "spec_matrix.lua";
    var matrix_duels: usize = 32;
    var record_all_matches_dir: ?[]const u8 = null;

    var check_spec_status: bool = false;
    var spec_status_dir: []const u8 = "models";
    var spec_status_out: ?[]const u8 = null;

    // Parse CLI arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // Skip executable path

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--class")) {
            _ = args.next() orelse return error.MissingClass;
        } else if (std.mem.eql(u8, arg, "--opponent-class")) {
            external_spec = Spec.parse(args.next() orelse return error.MissingOpponentClass) orelse return error.UnknownClass;
        } else if (std.mem.eql(u8, arg, "--train-only")) {
            train_only = true;
        } else if (std.mem.eql(u8, arg, "--live-metrics")) {
            live_metrics = true;
        } else if (std.mem.eql(u8, arg, "--stop-file")) {
            stop_file = args.next() orelse return error.MissingStopFile;
        } else if (std.mem.eql(u8, arg, "--generations")) {
            if (args.next()) |val| {
                num_generations = std.fmt.parseInt(usize, val, 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--threads")) {
            threads = try std.fmt.parseInt(usize, args.next() orelse return error.MissingThreadCount, 10);
            if (threads == 0) return error.InvalidThreadCount;
        } else if (std.mem.eql(u8, arg, "--pop")) {
            if (args.next()) |val| {
                pop_size = std.fmt.parseInt(usize, val, 10) catch 64;
            }
        } else if (std.mem.eql(u8, arg, "--duels")) {
            if (args.next()) |val| {
                duels_per_agent = std.fmt.parseInt(usize, val, 10) catch 4;
            }
        } else if (std.mem.eql(u8, arg, "--render-best")) {
            render_best = true;
        } else if (std.mem.eql(u8, arg, "--save-champion")) {
            if (args.next()) |val| {
                save_champion_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--save-population")) {
            if (args.next()) |val| {
                save_population_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--resume")) {
            if (args.next()) |val| {
                resume_checkpoint_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--seed-from")) {
            if (args.next()) |val| {
                seed_from_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--checkpoint-interval")) {
            if (args.next()) |val| {
                checkpoint_interval = std.fmt.parseInt(usize, val, 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--gauntlet")) {
            run_gauntlet_end = true;
        } else if (std.mem.eql(u8, arg, "--gauntlet-interval")) {
            if (args.next()) |val| {
                gauntlet_interval = std.fmt.parseInt(usize, val, 10) catch 5;
            }
        } else if (std.mem.eql(u8, arg, "--spar-gauntlet")) {
            spar_gauntlet = true;
        } else if (std.mem.eql(u8, arg, "--sparring-opponent")) {
            if (args.next()) |val| {
                sparring_opponent_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--sparring-pool")) {
            if (args.next()) |val| {
                sparring_pool_dir = val;
            }
        } else if (std.mem.eql(u8, arg, "--record-match")) {
            if (args.next()) |val| {
                record_match_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--visualize")) {
            launch_visualizer = true;
        } else if (std.mem.eql(u8, arg, "--eval")) {
            if (args.next()) |val_a| {
                eval_model_a = val_a;
                if (args.next()) |val_b| {
                    eval_model_b = val_b;
                }
            }
        } else if (std.mem.eql(u8, arg, "--eval-gauntlet")) {
            if (args.next()) |val| {
                eval_gauntlet_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--eval-bot")) {
            if (args.next()) |val_model| {
                eval_bot_model_path = val_model;
                if (args.next()) |val_bot| {
                    eval_bot_target_name = val_bot;
                }
            }
        } else if (std.mem.eql(u8, arg, "--spec-status")) {
            check_spec_status = true;
            if (args.next()) |val| {
                if (!std.mem.startsWith(u8, val, "--")) {
                    spec_status_dir = val;
                }
            }
        } else if (std.mem.eql(u8, arg, "--spec-status-out")) {
            if (args.next()) |val| {
                spec_status_out = val;
            }
        } else if (std.mem.eql(u8, arg, "--eval-matrix")) {
            if (args.next()) |val| {
                eval_matrix_dir = val;
            }
        } else if (std.mem.eql(u8, arg, "--matrix-out")) {
            if (args.next()) |val| {
                matrix_out_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--matrix-duels")) {
            if (args.next()) |val| {
                matrix_duels = std.fmt.parseInt(usize, val, 10) catch 32;
            }
        } else if (std.mem.eql(u8, arg, "--record-all-matches")) {
            if (args.next()) |val| {
                record_all_matches_dir = val;
            }
        } else if (std.mem.eql(u8, arg, "--metrics")) {
            if (args.next()) |val| {
                metrics_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--no-metrics")) {
            metrics_path = null;
        } else if (std.mem.eql(u8, arg, "--visualize-graphs")) {
            visualize_graphs = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print(
                \\Usage: pvp_sim [OPTIONS]
                \\
                \\Training & Evolution:
                \\  --class <warlock|frost_mage>    Training class (default: warlock)
                \\  --opponent-class <class>       Class of external sparring models (default: same class)
                \\  --train-only                  Skip throughput benchmarks before training
                \\  --live-metrics                Publish atomic metrics snapshots during training
                \\  --stop-file <path>            Stop between generations when this file exists
                \\  --generations <N>             Number of league evolution generations (default: 10)
                \\  --pop <N>                     Population size in genomes (default: 64)
                \\  --threads <N>                 Training workers (default: 1)
                \\  --duels <N>                   Duels per agent per generation (default: 4)
                \\  --save-champion <path.bin>    Export champion neural weights (.bin)
                \\  --save-population <path.pop>  Export full population checkpoint (.pop)
                \\  --resume <path.pop>           Resume training from full population checkpoint
                \\  --seed-from <champ.bin>       Seed initial population around champion with Gaussian noise
                \\  --checkpoint-interval <N>     Auto-save population checkpoint every N generations
                \\
                \\Objective Benchmarks & Sparring:
                \\  --gauntlet                    Run 4-bot objective Gauntlet benchmark after training
                \\  --gauntlet-interval <N>       Run Gauntlet benchmark every N generations
                \\  --sparring-opponent <mod.bin> Load external pre-trained model into sparring pool
                \\  --sparring-pool <dir>         Load directory of pre-trained models into sparring pool
                \\  --eval-gauntlet <model.bin>   Evaluate model directly against objective Gauntlet suite
                \\  --eval-bot <mod.bin> <bot>    Evaluate model vs specific bot (aggro|kiter|turret|draintank)
                \\
                \\Spec vs Spec Matrix & Match Recording:
                \\  --eval-matrix <models_dir>    Run full round-robin cross-spec matrix across all models in dir
                \\  --matrix-out <file.lua>       Output matrix Lua file (default: spec_matrix.lua)
                \\  --matrix-duels <N>            Duels per pairwise matchup (default: 32)
                \\  --record-all-matches <dir>    Auto-record representative 100Hz fight trajectories to dir
                \\
                \\Evaluation & Visualization:
                \\  --metrics <file.lua|json>     Export training telemetry graphs data (default: training_metrics.lua)
                \\  --no-metrics                  Disable metrics recording
                \\  --visualize-graphs            Launch Love2D directly in training graph & progress view
                \\  --render-best                 Visually replay champion vs runner-up in terminal
                \\  --eval <modA.bin> <modB.bin>  Evaluate two pre-trained .bin models head-to-head
                \\  --record-match <path>         Record match trajectory (.lua or .json for Love2D)
                \\  --visualize                   Launch native 2D Love2D arena visualizer
                \\  --help, -h                    Show this help message
                \\
            , .{});
            return;
        }
    }

    if (pop_size < 2 or duels_per_agent == 0 or checkpoint_interval == 0 or gauntlet_interval == 0)
        return error.InvalidTrainingConfiguration;

    try stdout.print("\n======================================================\n", .{});
    try stdout.print("         ⚔️  PVP_SIM: HIGH-PERFORMANCE SIMD ENGINE       \n", .{});
    try stdout.print("======================================================\n\n", .{});

    // ---------------------------------------------------------
    // Mode A: Direct Gauntlet Evaluation (--eval-gauntlet)
    // ---------------------------------------------------------
    if (eval_gauntlet_path) |path| {
        try stdout.print("[Objective Gauntlet] Benchmarking '{s}' against 4 baseline bot archetypes...\n", .{path});
        const model = try spec_policy.loadFor(class, path);

        var runner = try ClassGauntlet.init(allocator);
        defer runner.deinit();

        const report = runner.evaluateChampion(&model, 64, 45.0, 0.010);
        try ClassGauntlet.printReport(&report, stdout);

        if (record_match_path != null or launch_visualizer) {
            try stdout.print("Recording representative match vs Fear-Kite Specialist...\n", .{});
            var traj = try ClassGauntlet.recordDuelVsBot(allocator, &model, .FearKiter, path, 45.0, 0.010);
            defer traj.deinit();
            try exportAndMaybeVisualize(allocator, &traj, record_match_path, launch_visualizer, stdout);
        }
        return;
    }

    // ---------------------------------------------------------
    // Mode B: Direct Single Bot Evaluation (--eval-bot)
    // ---------------------------------------------------------
    if (eval_bot_model_path) |path| {
        const bot_name_str = eval_bot_target_name orelse "kiter";
        const bot_kind = GauntletBotKind.parse(bot_name_str) orelse .FearKiter;

        try stdout.print("[Bot Sparring] Pitting '{s}' against {s} {s}...\n", .{
            path,
            bot_kind.getIcon(),
            bot_kind.getName(),
        });
        const model = try spec_policy.loadFor(class, path);

        var runner = try ClassGauntlet.init(allocator);
        defer runner.deinit();

        var traj = try ClassGauntlet.recordDuelVsBot(allocator, &model, bot_kind, path, 45.0, 0.010);
        defer traj.deinit();

        try stdout.print("  -> Match Duration: {d:0.2}s | Victor: {s}\n\n", .{
            traj.total_time_s,
            if (traj.victor == 0) "Champion" else if (traj.victor == 1) bot_kind.getName() else "Draw",
        });

        try exportAndMaybeVisualize(allocator, &traj, record_match_path, launch_visualizer, stdout);
        return;
    }

    // ---------------------------------------------------------
    // Mode C: Head-to-Head Evaluation Mode (--eval)
    // ---------------------------------------------------------
    if (eval_model_a) |path_a| {
        if (eval_model_b) |path_b| {
            try stdout.print("[Evaluation Mode] Pitting two pre-trained models head-to-head...\n", .{});
            const model_a = try spec_policy.load(path_a);
            const model_b = try spec_policy.load(path_b);
            try stdout.print("  -> {s} vs {s}\n", .{ @tagName(model_a.spec), @tagName(model_b.spec) });
            if (model_a.spec == .warlock and model_b.spec == .warlock) {
                var league = try league_mod.League.init(allocator, .{ .pop_size = 16 }, 1);
                defer league.deinit();
                try league.replayDuelVisual(&model_a.genome, &model_b.genome, stdout);
            }
            var traj = switch (model_a.spec) {
                .warlock => switch (model_b.spec) {
                    .warlock => try MatchRecorder.recordDuel(allocator, &model_a.genome, &model_b.genome, path_a, path_b, 45, 0.01),
                    .frost_mage => try MatchRecorder.recordPair(.warlock, .frost_mage, allocator, &model_a.genome, &model_b.genome, model_b.genome.elo, path_a, path_b, 45, 0.01),
                },
                .frost_mage => switch (model_b.spec) {
                    .warlock => try MatchRecorder.recordPair(.frost_mage, .warlock, allocator, &model_a.genome, &model_b.genome, model_b.genome.elo, path_a, path_b, 45, 0.01),
                    .frost_mage => try MatchRecorder.recordPair(.frost_mage, .frost_mage, allocator, &model_a.genome, &model_b.genome, model_b.genome.elo, path_a, path_b, 45, 0.01),
                },
            };
            defer traj.deinit();
            try stdout.print("  -> Match Duration: {d:.2}s | Victor: {s}\n", .{ traj.total_time_s, if (traj.victor == 0) "A" else if (traj.victor == 1) "B" else "Draw" });
            try exportAndMaybeVisualize(allocator, &traj, record_match_path, launch_visualizer, stdout);

            return;
        }
    }

    // ---------------------------------------------------------
    // Mode D: Round-Robin Spec vs Spec Matrix (--eval-matrix)
    // ---------------------------------------------------------
    if (eval_matrix_dir) |dir_path| {
        try stdout.print("[Spec Matrix Evaluation] Discovering and benchmarking all trained models in '{s}'...\n", .{dir_path});
        var evaluator = SpecMatrixEvaluator.init(allocator);
        defer evaluator.deinit();

        const count = try evaluator.loadModelsFromDir(dir_path);
        try stdout.print("  -> Found {d} trained models for round-robin evaluation.\n", .{count});

        if (count == 0) {
            try stdout.print("  [Warning] No valid .bin models found in '{s}'!\n", .{dir_path});
            return;
        }

        if (record_all_matches_dir) |m_dir| {
            try stdout.print("  -> Auto-recording high-fidelity 100Hz fight trajectories to '{s}'...\n", .{m_dir});
            std.fs.cwd().makePath(m_dir) catch {};
        }

        try stdout.print("  -> Simulating {d} duels per matchup (AVX-512 vector lanes)...\n", .{matrix_duels});
        const start_m_ns = std.time.nanoTimestamp();
        try evaluator.evaluateAll(matrix_duels, record_all_matches_dir);
        const end_m_ns = std.time.nanoTimestamp();
        const matrix_dur_s = @as(f64, @floatFromInt(end_m_ns - start_m_ns)) / 1e9;

        try stdout.print("  -> Matrix evaluation completed in: {d:0.3} seconds\n", .{matrix_dur_s});
        try evaluator.exportLua(matrix_out_path);
        try stdout.print("  -> Saved spec matchup matrix Lua to '{s}'\n\n", .{matrix_out_path});

        // Print formatted ASCII preview table to terminal
        try stdout.print("=== SPEC VS SPEC WIN PERCENTAGE MATRIX (TRAINED MODELS) ===\n", .{});
        try stdout.print("{s:<28}", .{"Model \\ Opponent"});
        for (evaluator.models.items) |opp| {
            try stdout.print(" | {s:<6}", .{opp.file_name[0..@min(opp.file_name.len, 6)]});
        }
        try stdout.print(" | Aggro  | Kiter  | Turret | Turtle |\n", .{});
        for (0..80) |_| try stdout.print("-", .{});
        try stdout.print("\n", .{});

        for (evaluator.models.items, 0..) |row_mod, i| {
            const clean_name = row_mod.display_name[0..@min(row_mod.display_name.len, 27)];
            try stdout.print("{s:<28}", .{clean_name});
            for (evaluator.models.items, 0..) |_, j| {
                if (i == j) {
                    try stdout.print(" |   --- ", .{});
                } else {
                    const wr = evaluator.matrix.items[i].items[j].winRateA() * 100.0;
                    try stdout.print(" | {d:5.1}%", .{wr});
                }
            }
            // Bots
            for (0..GauntletBotKind.COUNT) |b| {
                const b_wr = evaluator.bot_matrix.items[i][b].winRateA() * 100.0;
                try stdout.print(" | {d:5.1}%", .{b_wr});
            }
            try stdout.print(" |\n", .{});
        }
        try stdout.print("\n", .{});

        if (launch_visualizer) {
            try stdout.print("Launching native Love2D with spec matrix dashboard...\n\n", .{});
            var child = std.process.Child.init(&[_][]const u8{ "love", "visualizer", "--matrix", matrix_out_path }, allocator);
            _ = child.spawn() catch |err| {
                try stdout.print("  [Note] Could not launch love automatically: {}\n", .{err});
                try stdout.print("  Run manually with: love visualizer --matrix {s}\n\n", .{matrix_out_path});
                return;
            };
            _ = child.wait() catch {};
        }

        return;
    }

    // ---------------------------------------------------------
    // Mode D: Spec & Pairwise Health Status Check (--spec-status)
    // ---------------------------------------------------------
    if (check_spec_status) {
        var monitor = spec_status_mod.SpecHealthMonitor.init(allocator);
        defer monitor.deinit();

        try stdout.print("[Spec Monitor] Scanning models from '{s}' and 'training_runs'...\n", .{spec_status_dir});
        try monitor.scanModels(spec_status_dir);
        try monitor.scanModels("training_runs");

        const health = try monitor.analyze();
        try monitor.renderReport(health, stdout);

        if (spec_status_out) |out_path| {
            try monitor.exportLua(health, out_path);
            try stdout.print("  -> Exported spec health status to '{s}'\n\n", .{out_path});
        }
        return;
    }

    // ---------------------------------------------------------
    // Benchmark 1: Mass Unit Status / Damage Ticking (AVX-512)
    // ---------------------------------------------------------
    if (!train_only) {
        const num_units = 100_000;
        try stdout.print("[Benchmark 1] Initializing {d} combatants in SoA layout...\n", .{num_units});

        var pool = try CombatantPool.init(allocator, num_units);
        defer pool.deinit();
        pool.seedRandom(num_units, 42);

        const num_ticks = 1_000;
        const dt: f32 = 0.016; // 60 FPS tick (16ms)
        try stdout.print("Simulating {d} ticks (dt = {d:0.3}s) for {d} units...\n", .{ num_ticks, dt, num_units });

        const start_tick_ns = std.time.nanoTimestamp();
        var last_alive: usize = 0;
        for (0..num_ticks) |_| {
            last_alive = pool.tickBatch(dt);
        }
        const end_tick_ns = std.time.nanoTimestamp();
        const tick_duration_s = @as(f64, @floatFromInt(end_tick_ns - start_tick_ns)) / 1e9;
        const total_evaluations = @as(f64, @floatFromInt(num_units * num_ticks));
        const evaluations_per_sec = total_evaluations / tick_duration_s;

        try stdout.print("  -> Completed in:      {d:0.3} seconds\n", .{tick_duration_s});
        try stdout.print("  -> Combatant Ticks:   {d:0.2} Million / sec\n", .{evaluations_per_sec / 1e6});
        try stdout.print("  -> Per-Batch Tick:    {d:0.3} ms\n", .{(tick_duration_s / @as(f64, @floatFromInt(num_ticks))) * 1000.0});
        try stdout.print("  -> Units Surviving:   {d} / {d}\n\n", .{ last_alive, num_units });

        // ---------------------------------------------------------
        // Benchmark 2: Monte-Carlo Parallel 1v1 Duels
        // ---------------------------------------------------------
        const num_duels = 64_000;
        try stdout.print("[Benchmark 2] Simulating {d} simultaneous 1v1 Duels...\n", .{num_duels});

        var team_a = try CombatantPool.init(allocator, num_duels);
        defer team_a.deinit();
        team_a.seedRandom(num_duels, 101);

        var team_b = try CombatantPool.init(allocator, num_duels);
        defer team_b.deinit();
        team_b.seedRandom(num_duels, 202);

        const start_duel_ns = std.time.nanoTimestamp();
        const duel_results = CombatantPool.simulateDuelsSoA(&team_a, &team_b, 0.05, 500);
        const end_duel_ns = std.time.nanoTimestamp();

        const duel_duration_s = @as(f64, @floatFromInt(end_duel_ns - start_duel_ns)) / 1e9;
        const duels_per_sec = @as(f64, @floatFromInt(num_duels)) / duel_duration_s;

        try stdout.print("  -> Completed in:      {d:0.3} seconds\n", .{duel_duration_s});
        try stdout.print("  -> Duel Throughput:   {d:0.1} Duels / sec\n", .{duels_per_sec});
        try stdout.print("  -> Total Sim Ticks:   {d:0.2} Million ticks\n", .{@as(f64, @floatFromInt(duel_results.total_ticks)) / 1e6});
        try stdout.print("  -> Results:           Team A wins: {d} | Team B wins: {d} | Draws: {d}\n\n", .{
            duel_results.wins_a,
            duel_results.wins_b,
            duel_results.draws,
        });
    }

    // ---------------------------------------------------------
    // Benchmark 3: Vectorized Warlock RL Tournament (League Play)
    // ---------------------------------------------------------
    try stdout.print("[Benchmark 3] Running Vectorized RL {s} League Play (Neuroevolution)...\n", .{@tagName(class)});

    var league: ClassLeague = undefined;
    const league_cfg = league_mod.LeagueConfig{
        .threads = threads,
        .external_spec = external_spec,
        .pop_size = pop_size,
        .hall_of_fame_capacity = 16,
        .duels_per_agent = duels_per_agent,
        .max_duel_seconds = 30.0,
        .physics_dt = 0.010, // 100 Hz physics, 100ms reactions
        .spar_gauntlet = spar_gauntlet,
    };

    if (resume_checkpoint_path) |ckpt_path| {
        try stdout.print("  -> Resuming population state from checkpoint '{s}'...\n", .{ckpt_path});
        league = try ClassLeague.loadCheckpoint(allocator, ckpt_path, league_cfg);
    } else if (seed_from_path) |seed_path| {
        try stdout.print("  -> Seeding new population around champion '{s}' (Gaussian sigma = 0.05)...\n", .{seed_path});
        const champ = try spec_policy.loadFor(class, seed_path);
        league = try ClassLeague.seedFromChampion(allocator, league_cfg, &champ, 42, 0.05);
    } else {
        league = try ClassLeague.init(allocator, league_cfg, 42);
    }
    defer league.deinit();

    // Ingest Sparring Partners
    if (sparring_opponent_path) |opp_path| {
        try stdout.print("  -> Ingesting external sparring partner from '{s}'...\n", .{opp_path});
        try league.loadSparringFile(opp_path);
    }
    if (sparring_pool_dir) |pool_dir| {
        try stdout.print("  -> Ingesting sparring pool from directory '{s}'...\n", .{pool_dir});
        const loaded = try league.loadSparringPoolFromDir(pool_dir);
        try stdout.print("  -> Loaded {d} external sparring partners into matchmaking.\n", .{loaded});
    }

    var gauntlet_runner: ?ClassGauntlet = null;
    if (gauntlet_interval != null or run_gauntlet_end) {
        gauntlet_runner = try ClassGauntlet.init(allocator);
    }
    defer if (gauntlet_runner) |*gr| gr.deinit();

    var logger = TrainingLogger.init(allocator);
    defer logger.deinit();
    logger.spec = class;

    const start_gen = league.generation;
    const target_gen = start_gen + num_generations;
    try stdout.print("Simulating generations {d} -> {d} for {d} agents (100Hz dual-clock, HoF: {d}, Sparring: {d})...\n\n", .{
        start_gen + 1,
        target_gen,
        league.population.len,
        league.hall_of_fame.items.len,
        league.sparring_partners.items.len,
    });

    const start_league_ns = std.time.nanoTimestamp();
    var current_gen: usize = start_gen;
    var duels_before_gen: usize = league.total_duels_simulated;

    var last_metrics_ns = start_league_ns;
    if (live_metrics) {
        if (metrics_path) |path| try logger.exportAtomic(path);
    }
    while (current_gen < target_gen) : (current_gen += 1) {
        if (stop_file) |path| {
            if (std.fs.cwd().access(path, .{})) |_| {
                try stdout.print("Stop requested; saving at generation {d}.\n", .{league.generation});
                break;
            } else |err| {
                if (err != error.FileNotFound) return err;
            }
        }
        const gen_start = std.time.nanoTimestamp();
        league.stepGeneration();
        const gen_end = std.time.nanoTimestamp();
        const gen_ms = @as(f64, @floatFromInt(gen_end - gen_start)) / 1e6;
        const best = league.getBest();

        const duels_in_gen = league.total_duels_simulated - duels_before_gen;
        duels_before_gen = league.total_duels_simulated;

        var m = league.collectGenerationMetrics(gen_ms, duels_in_gen);

        try stdout.print("  Gen {d:2} | Time: {d:6.1} ms | Best Elo: {d:6.1} | Best Fitness: {d:6.1} | Record: {d}W/{d}L/{d}D\n", .{
            league.generation,
            gen_ms,
            best.elo,
            best.fitness,
            best.wins,
            best.losses,
            best.draws,
        });

        // Periodic checkpoint
        if (checkpoint_interval) |ckpt_int| {
            if (league.generation % ckpt_int == 0) {
                var ckpt_buf: [128]u8 = undefined;
                const auto_path = try std.fmt.bufPrint(&ckpt_buf, "checkpoint_gen_{d}.pop", .{league.generation});
                try league.saveCheckpoint(auto_path);
                try stdout.print("    💾 [Checkpoint] Saved population snapshot to '{s}'\n", .{auto_path});
            }
        }

        // Periodic gauntlet evaluation
        if (gauntlet_interval) |g_int| {
            if (league.generation % g_int == 0 and gauntlet_runner != null) {
                const rep = gauntlet_runner.?.evaluateChampion(best, 16, 30.0, 0.010);
                m.has_gauntlet = true;
                m.gauntlet_win_rate = rep.overall_win_rate;
                m.gauntlet_objective_elo = rep.objective_elo;
                try stdout.print("    🎯 [Gauntlet Check] Win Rate: {d:0.1}% | Objective Elo: {d:0.0}\n", .{
                    rep.overall_win_rate * 100.0,
                    rep.objective_elo,
                });
            }
        }

        try logger.record(m);
        const now_ns = std.time.nanoTimestamp();
        if (live_metrics and now_ns - last_metrics_ns >= 250 * std.time.ns_per_ms) {
            if (metrics_path) |path| try logger.exportAtomic(path);
            last_metrics_ns = now_ns;
        }
    }
    const end_league_ns = std.time.nanoTimestamp();

    const total_league_s = @as(f64, @floatFromInt(end_league_ns - start_league_ns)) / 1e9;
    const duels_per_sec_league = @as(f64, @floatFromInt(league.total_duels_simulated)) / total_league_s;

    try stdout.print("\n  -> Completed {d} Gens in: {d:0.3} seconds\n", .{ league.generation - start_gen, total_league_s });
    try stdout.print("  -> Total Duels Fought:   {d}\n", .{league.total_duels_simulated});
    try stdout.print("  -> RL Duel Throughput:   {d:0.1} Duels / sec (with NN policy inference!)\n\n", .{duels_per_sec_league});

    // Export training metrics
    if (metrics_path) |m_path| {
        try logger.exportAtomic(m_path);
        try stdout.print("Saved training progress telemetry to '{s}' ({d} generations)\n\n", .{ m_path, logger.history.items.len });
    }

    // Optional: Save champion
    if (save_champion_path) |path| {
        try spec_policy.save(league.getBest(), class, path);
        try stdout.print("Saved champion weights to '{s}' ({d} bytes)\n\n", .{ path, @sizeOf(policy_simd.PolicyGenome) + (if (class == .frost_mage) @as(usize, 8) else 0) });
    }

    // Optional: Save full population checkpoint
    if (save_population_path) |path| {
        try league.saveCheckpoint(path);
        try stdout.print("Saved full population checkpoint to '{s}'\n\n", .{path});
    }

    // Optional: Final Gauntlet Report
    if (run_gauntlet_end and gauntlet_runner != null) {
        try stdout.print("[Objective Gauntlet Evaluation] Running final scorecard against baseline bots...\n", .{});
        const rep = gauntlet_runner.?.evaluateChampion(league.getBest(), 64, 45.0, 0.010);
        try ClassGauntlet.printReport(&rep, stdout);
    }

    // Optional: Launch Love2D Visualizer directly in training graph mode
    if (visualize_graphs) {
        const file_to_open = metrics_path orelse "training_metrics.lua";
        try stdout.print("  -> Launching native Love2D training progress graphs view...\n\n", .{});
        var child = std.process.Child.init(&[_][]const u8{ "love", "visualizer", "--graphs", file_to_open }, allocator);
        _ = child.spawn() catch |err| {
            try stdout.print("  [Note] Could not launch love automatically: {}\n", .{err});
            try stdout.print("  Run manually with: love visualizer --graphs {s}\n\n", .{file_to_open});
        };
        _ = child.wait() catch {};
    }

    // Optional: Visually replay match
    if (render_best) {
        const best = league.getBest();
        const runner_up = &league.population[@min(1, league.population.len - 1)];
        try league.replayDuelVisual(best, runner_up, stdout);
    }

    // Optional: Record champion match and/or launch Love2D visualizer
    if (record_match_path != null or launch_visualizer) {
        const best = league.getBest();
        const runner_up = &league.population[@min(1, league.population.len - 1)];
        try stdout.print("Recording high-fidelity 100Hz champion duel...\n", .{});
        var traj = try MatchRecorder.recordPair(class, class, allocator, best, runner_up, runner_up.elo, "Tournament Champion", "Runner-Up", 45.0, 0.010);
        defer traj.deinit();

        try exportAndMaybeVisualize(allocator, &traj, record_match_path, launch_visualizer, stdout);
    }

    try stdout.print("Vectorized SIMD simulation & RL League verified successfully.\n", .{});
}
