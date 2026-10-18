const std = @import("std");
const mcts = @import("mcts.zig");
const sim = @import("search_sim.zig");
const Spec = @import("spec.zig").Spec;
const WarlockTalentRanks = @import("spec.zig").WarlockTalentRanks;
const PriestTalentRanks = @import("spec.zig").PriestTalentRanks;
const pets = @import("pets.zig");
const recorder = @import("match_recorder.zig");
const Frost = @import("spec.zig").Frost;

fn interruptedSchool(comptime caster: Spec, cast_id: u32) u32 {
    if (caster == .warlock) return switch (cast_id) {
        3, 4, 5, 24 => 1, // Shadow
        11, 12, 13 => 2, // Fire
        else => 0,
    };
    if (caster == .priest) return switch (cast_id) {
        4, 5, 24 => 1, // Shadow
        11, 13, 14, 15 => 5, // Holy
        else => 0,
    };
    return switch (cast_id) {
        3 => 4, // Arcane
        4 => 3, // Frost
        else => 0,
    };
}
const default_shadow_priest_talents: PriestTalentRanks = .{
    .blackout = 5,
    .shadow_reach = 2,
    .twin_disciplines = 5,
    .silent_resolve = 3,
    .improved_power_word_shield = 3,
    .inner_focus = 1,
    .mental_agility = 2,
    .improved_shadow_word_pain = 2,
    .shadow_focus = 5,
    .improved_psychic_scream = 2,
    .improved_mind_blast = 5,
    .mind_flay = 1,
    .shadow_weaving = 3,
    .silence = 1,
    .vampiric_embrace = 1,
    .improved_mind_flay = 2,
    .devouring_contagion = 2,
    .early_demise = 1,
    .darkness = 4,
    .shadowform = 1,
};
const Options = struct {
    config: mcts.Config = .{
        .evaluator = .rollout,
        .algorithm = .puct,
        .boundary = .event,
    },
    a: Spec = .warlock,
    b: Spec = .frost_mage,
    pet_a: ?pets.Kind = null,
    pet_b: ?pets.Kind = null,
    name_a: ?[]const u8 = null,
    name_b: ?[]const u8 = null,
    spec_id_a: ?[]const u8 = null,
    spec_id_b: ?[]const u8 = null,
    race_a: @import("spec.zig").Race = .human,
    race_b: @import("spec.zig").Race = .human,
    combat_stats_a: @import("spell_resolution.zig").Stats = .{},
    combat_stats_b: @import("spell_resolution.zig").Stats = .{},
    warlock_talents_a: WarlockTalentRanks = .{},
    warlock_talents_b: WarlockTalentRanks = .{},
    priest_talents_a: PriestTalentRanks = default_shadow_priest_talents,
    priest_talents_b: PriestTalentRanks = default_shadow_priest_talents,
    action_mask_a: u32 = std.math.maxInt(u32),
    action_mask_b: u32 = std.math.maxInt(u32),
    output: []const u8 = "matches/mcts.lua",
    benchmark: bool = false,
    rounds: usize = 1,
    start_ticks: u32 = 0,
    distance: f32 = 25,
    x_a: ?f32 = null,
    y_a: ?f32 = null,
    x_b: ?f32 = null,
    y_b: ?f32 = null,
    hp_a: f32 = 2000,
    hp_b: f32 = 2000,
    stop_file: ?[]const u8 = null,
};
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var o: Options = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--benchmark")) {
            o.benchmark = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--random-rollout")) {
            o.config.random_rollout = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll("mcts_fight [--spec-a warlock|frost_mage|priest] [--spec-b ...] [--pet-a none|imp|succubus|felhunter|voidwalker] [--pet-b ...] [--rollouts 1024] [--workers 1] [--nodes 4096] [--depth 128] [--memory-mb 512] [--seed 1] [--seconds 60] [--ms 0] [--algorithm exp3|uct|puct] [--evaluator heuristic|rollout] [--boundary event|tick] [--c-puct 1.414] [--truncation-ticks 30] [--random-rollout] [--output matches/mcts.lua] [--benchmark --rounds 1 --start-ticks 0] [--distance 25] [--x-a X --y-a Y --x-b X --y-b Y] [--hp-a 2000] [--hp-b 2000] [--stop-file PATH]\nAdversarial simultaneous MCTS search on both ends. Default evaluator: rollout (terminal win/loss/draw). Fixed rollout budget is combined across workers and both players. --ms adds a per-decision deadline. Creates Lua replay, JSON replay, and search metadata. Warlocks default to an autonomous Imp; Mages and Priests have no pet. MVP pets use basic attacks only and cannot be targeted.\n");
            return;
        }
        const value = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--x-a")) {
            o.x_a = try std.fmt.parseFloat(f32, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--y-a")) {
            o.y_a = try std.fmt.parseFloat(f32, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--x-b")) {
            o.x_b = try std.fmt.parseFloat(f32, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--y-b")) {
            o.y_b = try std.fmt.parseFloat(f32, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--pet-a")) o.pet_a = pets.Kind.parse(value) orelse return error.UnknownPet else if (std.mem.eql(u8, arg, "--pet-b")) o.pet_b = pets.Kind.parse(value) orelse return error.UnknownPet else if (std.mem.eql(u8, arg, "--spec-a")) o.a = Spec.parse(value) orelse return error.UnknownSpec else if (std.mem.eql(u8, arg, "--spec-b")) o.b = Spec.parse(value) orelse return error.UnknownSpec else if (std.mem.eql(u8, arg, "--name-a")) o.name_a = value else if (std.mem.eql(u8, arg, "--name-b")) o.name_b = value else if (std.mem.eql(u8, arg, "--spec-id-a")) o.spec_id_a = value else if (std.mem.eql(u8, arg, "--spec-id-b")) o.spec_id_b = value else if (std.mem.eql(u8, arg, "--rollouts")) o.config.rollouts = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--workers")) o.config.workers = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--memory-mb"))
            o.config.memory_limit = try std.math.mul(usize, try std.fmt.parseInt(usize, value, 10), 1024 * 1024)
        else if (std.mem.eql(u8, arg, "--depth"))
            o.config.depth = try std.fmt.parseInt(usize, value, 10)
        else if (std.mem.eql(u8, arg, "--nodes")) o.config.nodes = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--seed")) o.config.seed = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--seconds")) {
            const seconds = try std.fmt.parseFloat(f32, value);
            if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > 600) return error.InvalidDuration;
            o.config.max_ticks = @intFromFloat(seconds * 100);
        } else if (std.mem.eql(u8, arg, "--ms")) o.config.milliseconds = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--algorithm")) o.config.algorithm = std.meta.stringToEnum(mcts.Algorithm, value) orelse return error.UnknownAlgorithm else if (std.mem.eql(u8, arg, "--evaluator")) o.config.evaluator = std.meta.stringToEnum(mcts.EvaluatorType, value) orelse return error.UnknownEvaluator else if (std.mem.eql(u8, arg, "--boundary")) o.config.boundary = std.meta.stringToEnum(mcts.BoundaryMode, value) orelse return error.UnknownBoundary else if (std.mem.eql(u8, arg, "--c-puct")) o.config.c_puct = try std.fmt.parseFloat(f32, value) else if (std.mem.eql(u8, arg, "--truncation-ticks")) o.config.truncation_ticks = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, arg, "--output")) o.output = value else if (std.mem.eql(u8, arg, "--rounds")) o.rounds = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--start-ticks")) o.start_ticks = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, arg, "--distance")) o.distance = try std.fmt.parseFloat(f32, value) else if (std.mem.eql(u8, arg, "--hp-a")) o.hp_a = try std.fmt.parseFloat(f32, value) else if (std.mem.eql(u8, arg, "--hp-b")) o.hp_b = try std.fmt.parseFloat(f32, value) else if (std.mem.eql(u8, arg, "--stop-file")) o.stop_file = value else return error.UnknownOption;
    }
    if (!std.math.isFinite(o.distance) or o.distance < 0 or o.distance > 35 or !std.math.isFinite(o.hp_a) or !std.math.isFinite(o.hp_b) or o.hp_a <= 0 or o.hp_b <= 0 or o.hp_a > 100000 or o.hp_b > 100000 or o.rounds == 0 or o.start_ticks >= o.config.max_ticks) return error.InvalidStartingConditions;

    if (o.x_a != null or o.y_a != null or o.x_b != null or o.y_b != null) {
        if (o.x_a == null or o.y_a == null or o.x_b == null or o.y_b == null) return error.IncompleteStartingPositions;
        for ([_]f32{ o.x_a.?, o.y_a.?, o.x_b.?, o.y_b.? }) |v| {
            if (!std.math.isFinite(v) or @abs(v) > 17.5) return error.InvalidStartingPositions;
        }
        const dx = o.x_b.? - o.x_a.?;
        const dy = o.y_b.? - o.y_a.?;
        o.distance = @sqrt(dx * dx + dy * dy);
        if (o.distance > 35) return error.InvalidStartingPositions;
    }

    // Resolve spec IDs if provided
    const spec_mod = @import("spec.zig");
    if (o.spec_id_a) |id_a| {
        if (spec_mod.resolveSpec(std.heap.page_allocator, id_a)) |cfg_a| {
            o.a = cfg_a.class;
            o.combat_stats_a = cfg_a.combat_stats;
            o.race_a = cfg_a.race;
            o.warlock_talents_a = cfg_a.warlock_talents;
            o.priest_talents_a = cfg_a.priest_talents;
            o.action_mask_a = cfg_a.action_mask;
            if (o.pet_a == null) o.pet_a = cfg_a.pet;
            if (o.name_a == null) o.name_a = cfg_a.name;
        } else return error.UnknownSpecId;
    }
    if (o.spec_id_b) |id_b| {
        if (spec_mod.resolveSpec(std.heap.page_allocator, id_b)) |cfg_b| {
            o.b = cfg_b.class;
            o.combat_stats_b = cfg_b.combat_stats;
            o.race_b = cfg_b.race;
            o.warlock_talents_b = cfg_b.warlock_talents;
            o.priest_talents_b = cfg_b.priest_talents;
            o.action_mask_b = cfg_b.action_mask;
            if (o.pet_b == null) o.pet_b = cfg_b.pet;
            if (o.name_b == null) o.name_b = cfg_b.name;
        } else return error.UnknownSpecId;
    }

    // Persist resolved defaults in search metadata so saved runs are explicit.
    o.pet_a = o.pet_a orelse (if (o.a == .warlock) pets.Kind.imp else pets.Kind.none);
    o.pet_b = o.pet_b orelse (if (o.b == .warlock) pets.Kind.imp else pets.Kind.none);
    if ((o.a != .warlock and o.pet_a.? != .none) or (o.b != .warlock and o.pet_b.? != .none)) return error.PetRequiresWarlock;
    // Resummoning the sacrificed demon cancels the effect even with Demonic Pact.
    if (o.warlock_talents_a.demonic_sacrifice > 0 and o.warlock_talents_a.demonic_pact > 0 and @as(u8, @intCast(@intFromEnum(o.pet_a.?))) == o.warlock_talents_a.demonic_sacrifice_pet) o.warlock_talents_a.demonic_sacrifice = 0;
    if (o.warlock_talents_b.demonic_sacrifice > 0 and o.warlock_talents_b.demonic_pact > 0 and @as(u8, @intCast(@intFromEnum(o.pet_b.?))) == o.warlock_talents_b.demonic_sacrifice_pet) o.warlock_talents_b.demonic_sacrifice = 0;
    o.config.stop_file = o.stop_file;
    switch (o.a) {
        inline else => |spec_a| switch (o.b) {
            inline else => |spec_b| try run(spec_a, spec_b, o),
        },
    }
}
fn run(comptime a: Spec, comptime b: Spec, o: Options) !void {
    const allocator = std.heap.page_allocator;
    var d = try sim.Duel(a, b).init(allocator);
    defer d.deinit();
    d.staggerOpening();
    const state = d.arena.combat();
    state.distance[0] = o.distance;
    state.pos_x_a[0] = o.x_a orelse (-o.distance * 0.5);
    state.pos_y_a[0] = o.y_a orelse 0;
    state.pos_x_b[0] = o.x_b orelse (o.distance * 0.5);
    state.pos_y_b[0] = o.y_b orelse 0;
    state.spell_rng_a[0] = @as(u32, @truncate(o.config.seed)) ^ 0x6d2b79f5;
    state.spell_rng_b[0] = @as(u32, @truncate(o.config.seed >> 32)) ^ @as(u32, @truncate(o.config.seed)) ^ 0xa341316c;
    state.pushback_rng_a[0] = state.spell_rng_a[0] ^ 0xc2b2ae35;
    state.pushback_rng_b[0] = state.spell_rng_b[0] ^ 0x27d4eb2f;
    state.pet_rng_a[0] = state.spell_rng_a[0] ^ 0x9e3779b9;
    state.pet_rng_b[0] = state.spell_rng_b[0] ^ 0x85ebca6b;
    state.hp_a[0] = o.hp_a;
    state.hp_b[0] = o.hp_b;
    const active_pet_a = if (a == .warlock and o.warlock_talents_a.demonic_sacrifice > 0 and o.warlock_talents_a.demonic_sacrifice_pet != 0 and o.warlock_talents_a.demonic_pact == 0) pets.Kind.none else o.pet_a.?;
    const active_pet_b = if (b == .warlock and o.warlock_talents_b.demonic_sacrifice > 0 and o.warlock_talents_b.demonic_sacrifice_pet != 0 and o.warlock_talents_b.demonic_pact == 0) pets.Kind.none else o.pet_b.?;
    pets.set(state, true, 0, active_pet_a);
    pets.set(state, false, 0, active_pet_b);
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
    d.setRace(true, o.race_a);
    d.setRace(false, o.race_b);
    try d.setCombatStats(true, o.combat_stats_a);
    try d.setCombatStats(false, o.combat_stats_b);
    state.mana_a[0] = o.combat_stats_a.max_mana;
    state.mana_b[0] = o.combat_stats_b.max_mana;
    state.hp_a[0] = @min(state.hp_a[0], o.combat_stats_a.max_health);
    state.hp_b[0] = @min(state.hp_b[0], o.combat_stats_b.max_health);
    d.setActionMaskA(o.action_mask_a);
    d.setActionMaskB(o.action_mask_b);
    var rng = std.Random.DefaultPrng.init(o.config.seed ^ 0xbadc0ffee);
    const random = rng.random();

    const search = try mcts.Search(a, b).init(allocator, o.config);
    defer search.deinit();
    search.setWarlockTalentRanksA(encoded_a);
    search.setWarlockTalentRanksB(encoded_b);
    search.setActionMaskA(o.action_mask_a);
    search.setActionMaskB(o.action_mask_b);
    for (0..o.start_ticks) |_| {
        const aa = mcts.rollout(a, true, &d, 0, d.choices(true, 0, d.getActionMaskA(0)), random, false);
        const bb = mcts.rollout(b, false, &d, 0, d.choices(false, 0, d.getActionMaskB(0)), random, false);
        d.apply(@splat(aa), @splat(bb));
        d.tick(o.config.max_ticks);
    }
    const stdout = std.io.getStdOut().writer();
    if (o.benchmark) {
        if (state.is_active[0] == 0) return error.TerminalBenchmarkState;
        var stats: mcts.Stats = .{};
        var seconds: f64 = 0;
        for (0..o.rounds) |_| {
            const r = search.decide(d.snapshot(0), random);
            stats.add(r.stats);
            seconds += r.seconds;
        }
        try stdout.print("{{\"spec_a\":\"{s}\",\"spec_b\":\"{s}\",\"pet_a\":\"{s}\",\"pet_b\":\"{s}\",\"workers\":{d},\"rollouts\":{d},\"seconds\":{d:.6},\"rollouts_per_second\":{d:.1},\"ticks_per_second\":{d:.1},\"lane_utilization\":{d:.4},\"nodes\":{d},\"max_depth\":{d},\"memory_bytes\":{d}}}\n", .{ @tagName(a), @tagName(b), @tagName(@as(pets.Kind, @enumFromInt(state.pet_kind_a[0]))), @tagName(@as(pets.Kind, @enumFromInt(state.pet_kind_b[0]))), o.config.workers, stats.rollouts, seconds, @as(f64, @floatFromInt(stats.rollouts)) / seconds, @as(f64, @floatFromInt(stats.ticks)) / seconds, @as(f64, @floatFromInt(stats.ticks)) / @as(f64, @floatFromInt(stats.vector_ticks * 16)), stats.nodes, stats.depth, search.memoryBytes() });
        return;
    }
    if (std.fs.path.dirname(o.output)) |dir| try std.fs.cwd().makePath(dir);
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}.search.json", .{o.output});
    defer allocator.free(metadata_path);
    const metadata = try std.fs.cwd().createFile(metadata_path, .{});
    defer metadata.close();
    var buffered = std.io.bufferedWriter(metadata.writer());
    const writer = buffered.writer();
    try writer.writeAll("{\"label\":\"search-generated; not certified optimal\",\"simulator_version\":\"mcts-simultaneous-v2-pets\",\"options\":");
    try std.json.stringify(o, .{}, writer);
    try writer.writeAll(",\"simulator_fingerprint\":");
    try std.json.stringify(@import("simulator_identity_generated.zig").fingerprint, .{}, writer);
    try writer.writeAll(",\"initial_state\":");
    try std.json.stringify(d.snapshot(0), .{}, writer);
    try writer.writeAll(",\"decisions\":[\n");
    const display_a = o.name_a orelse switch (a) {
        .warlock => "Warlock",
        .frost_mage => "Frost Mage",
        .priest => "Priest",
    };
    const display_b = o.name_b orelse switch (b) {
        .warlock => "Warlock",
        .frost_mage => "Frost Mage",
        .priest => "Priest",
    };
    var traj = try recorder.MatchTrajectory.init(allocator, display_a, display_b, 0, 0);
    defer traj.deinit();
    traj.max_health_a = o.combat_stats_a.max_health;
    traj.max_health_b = o.combat_stats_b.max_health;
    traj.max_mana_a = o.combat_stats_a.max_mana;
    traj.max_mana_b = o.combat_stats_b.max_mana;
    traj.spec_a = a;
    traj.race_a = o.race_a;
    traj.spec_b = b;
    traj.race_b = o.race_b;
    traj.warlock_talents_a = o.warlock_talents_a;
    traj.warlock_talents_b = o.warlock_talents_b;
    var priest_ticks: [2]@import("priest_recording.zig").Tick = .{ .{}, .{} };
    if (a == .priest or b == .priest) d.arena.priest_recording = &priest_ticks;
    var totals: mcts.Stats = .{};
    var elapsed: f64 = 0;
    var rounds: usize = 0;
    var cancelled = false;
    var old_fear_a: f32 = state.fear_timer_a[0];
    var old_fear_b: f32 = state.fear_timer_b[0];
    var old_horror_a: f32 = state.horror_timer_a[0];
    var old_horror_b: f32 = state.horror_timer_b[0];
    var old_root_a: f32 = state.agony_timer_a[0];
    var old_root_b: f32 = state.agony_timer_b[0];

    var accum_dot_to_a: f32 = 0.0;
    var accum_dot_to_b: f32 = 0.0;
    var last_dot_time_a: f32 = 0.0;
    var last_dot_time_b: f32 = 0.0;

    var accum_drain_dmg_to_a: f32 = 0.0;
    var accum_drain_dmg_to_b: f32 = 0.0;
    var accum_drain_heal_a: f32 = 0.0;
    var accum_drain_heal_b: f32 = 0.0;
    var last_drain_time_a: f32 = 0.0;
    var last_drain_time_b: f32 = 0.0;
    var accum_siphon_heal_a: f32 = 0.0;
    var accum_siphon_heal_b: f32 = 0.0;
    var last_siphon_time_a: f32 = 0.0;
    var last_siphon_time_b: f32 = 0.0;

    while (state.is_active[0] != 0) {
        const old_a = state.hp_a[0];
        const old_b = state.hp_b[0];
        const old_cast_a = state.cast_id_a[0];
        const old_cast_b = state.cast_id_b[0];
        const old_siphon_a = state.siphon_timer_a[0];
        const old_siphon_b = state.siphon_timer_b[0];
        var action_a: u32 = 0;
        var action_b: u32 = 0;
        var act_a_triggered = false;
        var act_b_triggered = false;
        const ready_a = if (o.config.boundary == .event) d.readyTactical(true)[0] else d.ready(true)[0];
        const ready_b = if (o.config.boundary == .event) d.readyTactical(false)[0] else d.ready(false)[0];
        if (ready_a or ready_b) {
            if (o.stop_file) |path| {
                if (std.fs.cwd().access(path, .{})) |_| {
                    cancelled = true;
                    break;
                } else |_| {}
            }
            const r = search.decide(d.snapshot(0), random);
            if (o.stop_file) |path| {
                if (std.fs.cwd().access(path, .{})) |_| {
                    elapsed += r.seconds;
                    totals.add(r.stats);
                    cancelled = true;
                    break;
                } else |_| {}
            }
            const actions = r.actions;
            if (rounds > 0) try writer.writeAll(",\n");
            try std.json.stringify(.{ .tick = d.ticks[0], .state = d.snapshot(0), .actions = actions, .choices = r.choices, .strategies = r.distributions, .stats = r.stats, .seconds = r.seconds }, .{}, writer);
            totals.add(r.stats);
            elapsed += r.seconds;
            rounds += 1;
            action_a = if (ready_a) actions[0].ability else 0;
            action_b = if (ready_b) actions[1].ability else 0;
            act_a_triggered = ready_a;
            act_b_triggered = ready_b;
            if (o.config.boundary == .event) {
                d.applyTactical(@splat(actions[0]), @splat(actions[1]));
            } else {
                d.apply(@splat(actions[0]), @splat(actions[1]));
            }
            if (rounds % 25 == 0) std.debug.print("MCTS: fight {d:.2}s, decisions {d}, compute {d:.2}s\n", .{ @as(f32, @floatFromInt(d.ticks[0])) * 0.01, rounds, elapsed });
        }
        const pre_cast_a = state.cast_id_a[0];
        const pre_cast_b = state.cast_id_b[0];
        const old_stun_a = state.stun_timer_a[0];
        const old_stun_b = state.stun_timer_b[0];
        const pre_rem_a = state.cast_timer_a[0];
        const pre_rem_b = state.cast_timer_b[0];

        const old_x_a = state.pos_x_a[0];
        const old_x_b = state.pos_x_b[0];
        priest_ticks = .{ .{}, .{} };
        d.tick(o.config.max_ticks);
        const speed_a = (state.pos_x_a[0] - old_x_a) / 0.01;
        const speed_b = (state.pos_x_b[0] - old_x_b) / 0.01;
        const time_s = @as(f32, @floatFromInt(d.ticks[0])) * 0.01;
        const post_cast_a = state.cast_id_a[0];
        const post_cast_b = state.cast_id_b[0];
        const post_hp_a = state.hp_a[0];
        const post_hp_b = state.hp_b[0];

        const flight_after = @import("projectiles.zig").telemetry(state, 0);
        const coil_arrived_a = state.impact_mask_a[0] & 4 != 0;
        const coil_arrived_b = state.impact_mask_b[0] & 4 != 0;
        const impact_a = state.impact_bolt_a[0] + state.impact_lance_a[0] + state.impact_coil_a[0] + state.impact_pet_a[0] + state.impact_conflagrate_a[0];
        const impact_b = state.impact_bolt_b[0] + state.impact_lance_b[0] + state.impact_coil_b[0] + state.impact_pet_b[0] + state.impact_conflagrate_b[0];
        traj.total_dmg_a += impact_a;
        traj.total_dmg_b += impact_b;
        inline for (.{ true, false }) |side_a| {
            const suffix = if (side_a) "_a" else "_b";
            const side_spec = if (side_a) a else b;
            const conflag_amount = @field(state, "impact_conflagrate" ++ suffix)[0];
            if (conflag_amount > 0) try traj.events.append(.{ .time_s = time_s, .source = if (side_a) 0 else 1, .target = if (side_a) 1 else 0, .kind = .DamageHit, .spell_id = if (side_spec == .priest) 9 else 16, .amount = conflag_amount });
            const pet_amount = @field(state, "impact_pet" ++ suffix)[0];
            if (pet_amount > 0) try traj.events.append(.{ .time_s = time_s, .source = if (side_a) 0 else 1, .target = if (side_a) 1 else 0, .kind = .PetAttack, .spell_id = @field(state, "pet_kind" ++ suffix)[0], .amount = pet_amount });
            inline for (.{ "bolt", "lance", "coil" }, .{ 4, 1, 7 }, .{ 1, 2, 4 }) |kind, spell, bit| {
                if (@field(state, "impact_mask" ++ suffix)[0] & bit != 0)
                    try traj.events.append(.{ .time_s = time_s, .source = if (side_a) 0 else 1, .target = if (side_a) 1 else 0, .kind = .ProjectileImpact, .spell_id = spell, .amount = 0 });
                const amount = @field(state, "impact_" ++ kind ++ suffix)[0];
                if (amount > 0) try traj.events.append(.{ .time_s = time_s, .source = if (side_a) 0 else 1, .target = if (side_a) 1 else 0, .kind = .DamageHit, .spell_id = spell, .amount = amount });
            }
        }

        inline for (.{ true, false }) |target_a| {
            const timer = if (target_a) state.stun_timer_a[0] else state.stun_timer_b[0];
            const old_timer = if (target_a) old_stun_a else old_stun_b;
            if (timer > old_timer) try traj.events.append(.{ .time_s = time_s, .source = if (target_a) 1 else 0, .target = if (target_a) 0 else 1, .kind = .StunApplied, .spell_id = 15269, .amount = timer });
        }

        // 1. ActionUsed / Blink / Counterspell events
        if (act_a_triggered and action_a != 0) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = if ((action_a >= 17 and action_a <= 20) or (a == .priest and (action_a == 6 or action_a == 11 or action_a == 12 or action_a == 16 or action_a == 21 or action_a == 22))) 0 else 1, .kind = .ActionUsed, .spell_id = action_a, .amount = 0 });
            if (a == .frost_mage and action_a == 5)
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Blink, .spell_id = 5, .amount = 0 });
            if ((a == .frost_mage or a == .priest) and action_a == 7)
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .Counterspell, .spell_id = 7, .amount = 0 });
            if (a == .warlock and action_a == 15 and old_cast_b != 0)
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .SpellLock, .spell_id = interruptedSchool(b, old_cast_b), .amount = Frost.LockoutDuration });
        }
        if (act_b_triggered and action_b != 0) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = if ((action_b >= 17 and action_b <= 20) or (b == .priest and (action_b == 6 or action_b == 11 or action_b == 12 or action_b == 16 or action_b == 21 or action_b == 22))) 1 else 0, .kind = .ActionUsed, .spell_id = action_b, .amount = 0 });
            if (b == .frost_mage and action_b == 5)
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Blink, .spell_id = 5, .amount = 0 });
            if ((b == .frost_mage or b == .priest) and action_b == 7)
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .Counterspell, .spell_id = 7, .amount = 0 });
            if (b == .warlock and action_b == 15 and old_cast_a != 0)
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .SpellLock, .spell_id = interruptedSchool(a, old_cast_a), .amount = Frost.LockoutDuration });
        }

        // 2. Cast start
        if (old_cast_a == 0 and pre_cast_a != 0) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = if (a == .priest and pre_cast_a == 11) 0 else 1, .kind = .CastStart, .spell_id = pre_cast_a, .amount = state.cast_total_a[0] });
        }
        if (old_cast_b == 0 and pre_cast_b != 0) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = if (b == .priest and pre_cast_b == 11) 1 else 0, .kind = .CastStart, .spell_id = pre_cast_b, .amount = state.cast_total_b[0] });
        }

        // 3. Cast completion or interruption
        if (pre_cast_a != 0 and post_cast_a == 0) {
            if (pre_rem_a <= 0.015) {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = if (a == .priest and pre_cast_a == 11) 0 else 1, .kind = .CastComplete, .spell_id = pre_cast_a, .amount = 0 });
            } else {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = if (a == .priest and pre_cast_a == 11) 0 else 1, .kind = .CastInterrupt, .spell_id = pre_cast_a, .amount = 0 });
            }
        }
        if (pre_cast_b != 0 and post_cast_b == 0) {
            if (pre_rem_b <= 0.015) {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = if (b == .priest and pre_cast_b == 11) 1 else 0, .kind = .CastComplete, .spell_id = pre_cast_b, .amount = 0 });
            } else {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = if (b == .priest and pre_cast_b == 11) 1 else 0, .kind = .CastInterrupt, .spell_id = pre_cast_b, .amount = 0 });
            }
        }

        // 5. Crowd control
        if (state.fear_timer_b[0] > old_fear_b) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .FearApplied, .spell_id = 3, .amount = state.fear_timer_b[0] });
        }
        if (state.fear_timer_a[0] > old_fear_a) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .FearApplied, .spell_id = 3, .amount = state.fear_timer_a[0] });
        }
        old_fear_a = state.fear_timer_a[0];
        old_fear_b = state.fear_timer_b[0];

        if (state.horror_timer_b[0] > old_horror_b) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .HorrorApplied, .spell_id = 7, .amount = state.horror_timer_b[0] });
        }
        if (state.horror_timer_a[0] > old_horror_a) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .HorrorApplied, .spell_id = 7, .amount = state.horror_timer_a[0] });
        }
        old_horror_a = state.horror_timer_a[0];
        old_horror_b = state.horror_timer_b[0];

        if (a == .frost_mage and state.agony_timer_b[0] > old_root_b) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .RootApplied, .spell_id = 2, .amount = state.agony_timer_b[0] });
        }
        if (b == .frost_mage and state.agony_timer_a[0] > old_root_a) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .RootApplied, .spell_id = 2, .amount = state.agony_timer_a[0] });
        }
        old_root_a = state.agony_timer_a[0];
        old_root_b = state.agony_timer_b[0];

        inline for (.{ a, b }, 0..) |side_spec, side| {
            if (side_spec == .priest) {
                if (priest_ticks[side].backlash > 0) try traj.events.append(.{ .time_s = time_s, .source = side, .target = side, .kind = .DamageHit, .spell_id = 9, .amount = priest_ticks[side].backlash });
                for (priest_ticks[side].damage, 0..) |amount, spell| {
                    if (amount > 0) {
                        try traj.events.append(.{ .time_s = time_s, .source = side, .target = 1 - side, .kind = if (spell == 24) .DamageHit else .DamageDot, .spell_id = @intCast(spell), .amount = amount });
                        if (side == 0) traj.total_dmg_a += amount else traj.total_dmg_b += amount;
                    }
                }
                for (priest_ticks[side].healing, 0..) |amount, spell| {
                    if (amount > 0) {
                        try traj.events.append(.{ .time_s = time_s, .source = side, .target = side, .kind = .Heal, .spell_id = @intCast(spell), .amount = amount });
                        if (side == 0) traj.total_heal_a += amount else traj.total_heal_b += amount;
                    }
                }
            }
        }

        // 6. Damage dealt by A to B
        const dmg_to_b = @max(0, old_b - post_hp_b - impact_a + @reduce(.Add, @as(@Vector(@import("action_catalog_generated.zig").ActionCount, f32), priest_ticks[1].healing)) - priest_ticks[1].backlash);
        if (a != .priest and dmg_to_b > 0) {
            traj.total_dmg_a += dmg_to_b;
            if (pre_cast_a == 5) {
                accum_drain_dmg_to_b += dmg_to_b;
                if (time_s - last_drain_time_a >= 0.50 and accum_drain_dmg_to_b > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .DamageDot, .spell_id = 5, .amount = accum_drain_dmg_to_b });
                    accum_drain_dmg_to_b = 0;
                    last_drain_time_a = time_s;
                }
            } else {
                accum_dot_to_b += dmg_to_b;
                if (time_s - last_dot_time_b >= 1.0 and accum_dot_to_b > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .DamageDot, .spell_id = 1, .amount = accum_dot_to_b });
                    accum_dot_to_b = 0;
                    last_dot_time_b = time_s;
                }
            }
        }
        if (pre_cast_a == 5 and post_cast_a == 0 and accum_drain_dmg_to_b > 1.0) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 1, .kind = .DamageDot, .spell_id = 5, .amount = accum_drain_dmg_to_b });
            accum_drain_dmg_to_b = 0;
        }

        // 7. Damage dealt by B to A
        const dmg_to_a = @max(0, old_a - post_hp_a - impact_b + @reduce(.Add, @as(@Vector(@import("action_catalog_generated.zig").ActionCount, f32), priest_ticks[0].healing)) - priest_ticks[0].backlash);
        if (b != .priest and dmg_to_a > 0) {
            traj.total_dmg_b += dmg_to_a;
            if (pre_cast_b == 5) {
                accum_drain_dmg_to_a += dmg_to_a;
                if (time_s - last_drain_time_b >= 0.50 and accum_drain_dmg_to_a > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .DamageDot, .spell_id = 5, .amount = accum_drain_dmg_to_a });
                    accum_drain_dmg_to_a = 0;
                    last_drain_time_b = time_s;
                }
            } else {
                accum_dot_to_a += dmg_to_a;
                if (time_s - last_dot_time_a >= 1.0 and accum_dot_to_a > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .DamageDot, .spell_id = 1, .amount = accum_dot_to_a });
                    accum_dot_to_a = 0;
                    last_dot_time_a = time_s;
                }
            }
        }
        if (pre_cast_b == 5 and post_cast_b == 0 and accum_drain_dmg_to_a > 1.0) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 0, .kind = .DamageDot, .spell_id = 5, .amount = accum_drain_dmg_to_a });
            accum_drain_dmg_to_a = 0;
        }

        // 8. Healing received by A
        const heal_a = if (coil_arrived_a) @min(@as(f32, 300), state.max_health_a[0] - old_a) else @max(0, post_hp_a - old_a);
        if (a != .priest and heal_a > 0) {
            traj.total_heal_a += heal_a;
            if (a == .warlock and coil_arrived_a) {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 7, .amount = heal_a });
            } else if (action_a == 6) {
                try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 6, .amount = heal_a });
            } else if (a == .warlock and old_siphon_b > 0 and old_cast_a != 5) {
                accum_siphon_heal_a += heal_a;
                if (time_s - last_siphon_time_a >= 0.50 and accum_siphon_heal_a > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 8, .amount = accum_siphon_heal_a });
                    accum_siphon_heal_a = 0;
                    last_siphon_time_a = time_s;
                }
            } else if (pre_cast_a == 5) {
                accum_drain_heal_a += heal_a;
                if (time_s - last_drain_time_a >= 0.50 and accum_drain_heal_a > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 5, .amount = accum_drain_heal_a });
                    accum_drain_heal_a = 0;
                }
            }
        }
        if (pre_cast_a == 5 and post_cast_a == 0 and accum_drain_heal_a > 1.0) {
            try traj.events.append(.{ .time_s = time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 5, .amount = accum_drain_heal_a });
            accum_drain_heal_a = 0;
        }

        // 9. Healing received by B
        const heal_b = if (coil_arrived_b) @min(@as(f32, 300), state.max_health_b[0] - old_b) else @max(0, post_hp_b - old_b);
        if (b != .priest and heal_b > 0) {
            traj.total_heal_b += heal_b;
            if (b == .warlock and coil_arrived_b) {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 7, .amount = heal_b });
            } else if (action_b == 6) {
                try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 6, .amount = heal_b });
            } else if (b == .warlock and old_siphon_a > 0 and old_cast_b != 5) {
                accum_siphon_heal_b += heal_b;
                if (time_s - last_siphon_time_b >= 0.50 and accum_siphon_heal_b > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 8, .amount = accum_siphon_heal_b });
                    accum_siphon_heal_b = 0;
                    last_siphon_time_b = time_s;
                }
            } else if (pre_cast_b == 5) {
                accum_drain_heal_b += heal_b;
                if (time_s - last_drain_time_b >= 0.50 and accum_drain_heal_b > 1.0) {
                    try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 5, .amount = accum_drain_heal_b });
                    accum_drain_heal_b = 0;
                }
            }
        }
        if (pre_cast_b == 5 and post_cast_b == 0 and accum_drain_heal_b > 1.0) {
            try traj.events.append(.{ .time_s = time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 5, .amount = accum_drain_heal_b });
            accum_drain_heal_b = 0;
        }
        const fa = if (a == .warlock and b == .warlock) [_]f32{0} ** 5 else d.arena.frostTelemetry(true, 0);
        const fb = if (a == .warlock and b == .warlock) [_]f32{0} ** 5 else d.arena.frostTelemetry(false, 0);
        const pa = recorder.priestAuraTelemetry(state, a, true);
        const pb = recorder.priestAuraTelemetry(state, b, false);
        try traj.frames.append(.{
            .priest_auras = .{ pa[0], pb[0], pa[1], pb[1], pa[2], pb[2], pa[3], pb[3], pa[4], pb[4] },
            .projectiles = flight_after,
            .pets = pets.telemetry(state, 0),
            .siphon_a = state.siphon_timer_a[0],
            .siphon_b = state.siphon_timer_b[0],
            .immolate_a = state.immolate_timer_a[0],
            .immolate_b = state.immolate_timer_b[0],
            .seduced_a = @floatFromInt(state.seduced_a[0]),
            .seduced_b = @floatFromInt(state.seduced_b[0]),
            .seduction_cd_a = state.seduction_cd_a[0],
            .seduction_cd_b = state.seduction_cd_b[0],
            .priest_pi_timer_a = state.priest_pi_timer_a[0],
            .priest_pi_timer_b = state.priest_pi_timer_b[0],
            .priest_pi_cd_a = state.priest_pi_cd_a[0],
            .priest_pi_cd_b = state.priest_pi_cd_b[0],
            .stun_a = state.stun_timer_a[0],
            .stun_b = state.stun_timer_b[0],
            .seduction_a = state.seduction_timer_a[0],
            .seduction_b = state.seduction_timer_b[0],
            .seduction_cast_a = state.seduction_cast_a[0],
            .seduction_cast_b = state.seduction_cast_b[0],
            .isb_timer_a = state.isb_timer_a[0],
            .isb_timer_b = state.isb_timer_b[0],
            .isb_charges_a = state.isb_charges_a[0],
            .isb_charges_b = state.isb_charges_b[0],
            .frost = .{ fa[0], fb[0], fa[1], fb[1], fa[2], fb[2], fa[3], fb[3] },
            .time_s = time_s,
            .dist = state.distance[0],
            .pos_a = state.pos_x_a[0],
            .pos_y_a = state.pos_y_a[0],
            .pos_b = state.pos_x_b[0],
            .pos_y_b = state.pos_y_b[0],
            .hp_a = state.hp_a[0],
            .hp_b = state.hp_b[0],
            .mana_a = state.mana_a[0],
            .mana_b = state.mana_b[0],
            .speed_a = speed_a,
            .speed_b = speed_b,
            .cast_id_a = state.cast_id_a[0],
            .cast_id_b = state.cast_id_b[0],
            .cast_timer_a = state.cast_timer_a[0],
            .cast_timer_b = state.cast_timer_b[0],
            .cast_total_a = state.cast_total_a[0],
            .cast_total_b = state.cast_total_b[0],
            .agony_a = state.agony_timer_a[0],
            .agony_b = state.agony_timer_b[0],
            .corruption_a = state.corruption_timer_a[0],
            .corruption_b = state.corruption_timer_b[0],
            .fear_a = state.fear_timer_a[0],
            .fear_b = state.fear_timer_b[0],
            .horror_a = state.horror_timer_a[0],
            .horror_b = state.horror_timer_b[0],
            .action6_dur_a = state.action6_dur_a[0],
            .action6_dur_b = state.action6_dur_b[0],
            .action6_cd_a = state.action6_cd_a[0],
            .action6_cd_b = state.action6_cd_b[0],
            .death_coil_cd_a = state.death_coil_cd_a[0],
            .death_coil_cd_b = state.death_coil_cd_b[0],
            .fear_dr_a = state.fear_dr_tier_a[0],
            .fear_dr_b = state.fear_dr_tier_b[0],
            .fear_dr_timer_a = state.fear_dr_timer_a[0],
            .fear_dr_timer_b = state.fear_dr_timer_b[0],
            .horror_dr_a = state.horror_dr_tier_a[0],
            .horror_dr_b = state.horror_dr_tier_b[0],
            .horror_dr_timer_a = state.horror_dr_timer_a[0],
            .horror_dr_timer_b = state.horror_dr_timer_b[0],
            .action_a = action_a,
            .action_b = action_b,
        });
    }
    const end_time_s = @as(f32, @floatFromInt(d.ticks[0])) * 0.01;
    if (accum_dot_to_b > 1.0) {
        try traj.events.append(.{ .time_s = end_time_s, .source = 0, .target = 1, .kind = .DamageDot, .spell_id = 1, .amount = accum_dot_to_b });
    }
    if (accum_dot_to_a > 1.0) {
        try traj.events.append(.{ .time_s = end_time_s, .source = 1, .target = 0, .kind = .DamageDot, .spell_id = 1, .amount = accum_dot_to_a });
    }
    if (accum_siphon_heal_a > 1.0) {
        try traj.events.append(.{ .time_s = end_time_s, .source = 0, .target = 0, .kind = .Heal, .spell_id = 8, .amount = accum_siphon_heal_a });
    }
    if (accum_siphon_heal_b > 1.0) {
        try traj.events.append(.{ .time_s = end_time_s, .source = 1, .target = 1, .kind = .Heal, .spell_id = 8, .amount = accum_siphon_heal_b });
    }
    traj.total_time_s = end_time_s;
    traj.victor = if (d.reward(0) > 0) 0 else if (d.reward(0) < 0) 1 else 2;
    try traj.exportLua(o.output);
    const json_path = try std.fmt.allocPrint(allocator, "{s}.json", .{o.output});
    defer allocator.free(json_path);
    try traj.exportJson(json_path);
    try writer.writeAll("],\"summary\":");
    try std.json.stringify(.{ .victor = traj.victor, .fight_seconds = traj.total_time_s, .compute_seconds = elapsed, .decisions = rounds, .cancelled = cancelled, .stats = totals }, .{}, writer);
    try writer.writeAll("}\n");
    try buffered.flush();

    try stdout.print("Saved {s}: victor={d}, fight={d:.2}s, decisions={d}, compute={d:.3}s, rollouts={d}\n", .{ o.output, traj.victor, traj.total_time_s, rounds, elapsed, totals.rollouts });
}
