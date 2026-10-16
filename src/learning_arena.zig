//! Reproducible base-kit value-learning experiment; JSONL results and trajectories.
const std = @import("std");
const sim = @import("search_sim.zig");
const mcts = @import("mcts.zig");
const value = @import("learned_value.zig");
const Spec = @import("spec.zig").Spec;
const identity = @import("simulator_identity_generated.zig");
const Options = struct {
    games: usize = 32,
    seed: u64 = 1000,
    rollouts: usize = 128,
    baseline_rollouts: usize = 128,
    milliseconds: u64 = 0,
    mix: f32 = 0.5,
    output: []const u8 = "/tmp/learning.jsonl",
    model: ?[]const u8 = null,
    generate: bool = false,
    probe: bool = false,
    full_health: bool = false,
    microbench: bool = false,
    default_pets: bool = false,
    nodes: usize = 1024,
    baseline_rollout: bool = false,
};
const Sample = struct { x: [2][value.Inputs]f32, heuristic: f32 };
pub fn main() !void {
    var o: Options = .{};
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--default-pets")) {
            o.default_pets = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--full-health")) {
            o.full_health = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--microbench")) {
            o.microbench = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--probe")) {
            o.probe = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--generate")) {
            o.generate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--terminal-baseline")) {
            o.baseline_rollout = true;
            continue;
        }
        const v = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--nodes")) o.nodes = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, arg, "--games")) o.games = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, arg, "--seed")) o.seed = try std.fmt.parseInt(u64, v, 10) else if (std.mem.eql(u8, arg, "--rollouts")) o.rollouts = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, arg, "--baseline-rollouts")) o.baseline_rollouts = try std.fmt.parseInt(usize, v, 10) else if (std.mem.eql(u8, arg, "--ms")) o.milliseconds = try std.fmt.parseInt(u64, v, 10) else if (std.mem.eql(u8, arg, "--mix")) o.mix = try std.fmt.parseFloat(f32, v) else if (std.mem.eql(u8, arg, "--output")) o.output = v else if (std.mem.eql(u8, arg, "--model")) o.model = v else return error.UnknownOption;
    }
    if ((!o.generate or o.probe or o.microbench) and o.model == null) return error.ModelRequired;
    if (o.generate and o.model != null) return error.LearnedSelfPlayNotImplemented;
    if (o.probe and o.microbench) return error.ConflictingModes;
    var parsed: ?std.json.Parsed(value.Bundle) = null;
    defer if (parsed) |p| p.deinit();
    if (o.model) |path| {
        const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024);
        defer std.heap.page_allocator.free(data);
        parsed = try std.json.parseFromSlice(value.Bundle, std.heap.page_allocator, data, .{ .allocate = .alloc_always });
        if (parsed.?.value.schema != 1 or !std.mem.eql(u8, parsed.?.value.fingerprint, identity.fingerprint)) return error.ModelSimulatorMismatch;
        for (parsed.?.value.networks) |n| {
            for (n.w) |row| for (row) |v| {
                if (!std.math.isFinite(v)) return error.InvalidWeights;
            };
            for (n.bias) |v| {
                if (!std.math.isFinite(v)) return error.InvalidWeights;
            }
            for (n.out) |v| {
                if (!std.math.isFinite(v)) return error.InvalidWeights;
            }
            if (!std.math.isFinite(n.out_bias)) return error.InvalidWeights;
        }
    }
    const file = try std.fs.cwd().createFile(o.output, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    const writer = buffered.writer();
    if (o.microbench) {
        const model = &parsed.?.value;
        var x: [value.Inputs]f32 = @splat(0.25);
        var opponent_x: [value.Inputs]f32 = @splat(0.5);
        var checksum: f64 = 0;
        const started = std.time.nanoTimestamp();
        const iterations = 200000;
        for (0..iterations) |i| {
            x[4] = @as(f32, @floatFromInt(i % 101)) / 100;
            opponent_x[24] = 1 - x[4];
            checksum += model.predict(.warlock, x);
            checksum += model.predict(.frost_mage, opponent_x);
        }
        const seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started)) / 1e9;
        try std.json.stringify(.{ .mode = @tagName(model.mode), .predictions = iterations * 2, .seconds = seconds, .checksum = checksum }, .{}, writer);
        try writer.writeByte('\n');
        try buffered.flush();
        return;
    }
    if (o.probe) {
        const model = &parsed.?.value;
        for (0..64) |i| {
            var x: [value.Inputs]f32 = undefined;
            for (&x, 0..) |*v, j| v.* = @as(f32, @floatFromInt((i * 17 + j * 13) % 101)) / 50 - 1;
            try std.json.stringify(.{ .x = x, .predictions = [2]f32{ model.networks[0].predict(x), model.networks[1].predict(x) } }, .{}, writer);
            try writer.writeByte('\n');
        }
        try buffered.flush();
        return;
    }
    for (0..o.games) |game| {
        const seed = o.seed + game;
        // Every seed has a fixed matchup and randomized initial conditions.
        switch (seed % 4) {
            0 => try play(.warlock, .warlock, o, seed, if (parsed) |*p| &p.value else null, writer),
            1 => try play(.warlock, .frost_mage, o, seed, if (parsed) |*p| &p.value else null, writer),
            2 => try play(.frost_mage, .warlock, o, seed, if (parsed) |*p| &p.value else null, writer),
            else => try play(.frost_mage, .frost_mage, o, seed, if (parsed) |*p| &p.value else null, writer),
        }
        try buffered.flush();
        std.debug.print("completed {d}/{d}\n", .{ game + 1, o.games });
    }
}
fn play(comptime a: Spec, comptime b: Spec, o: Options, seed: u64, model: ?*const value.Bundle, writer: anytype) !void {
    const alloc = std.heap.page_allocator;
    var setup_rng = std.Random.DefaultPrng.init(seed);
    const setup = setup_rng.random();
    const distance = setup.float(f32) * 29 + 5;
    const sampled_hp_a = 800 + setup.float(f32) * 1200;
    const sampled_hp_b = 800 + setup.float(f32) * 1200;
    const hp_a: f32 = if (o.full_health) 2000 else sampled_hp_a;
    const hp_b: f32 = if (o.full_health) 2000 else sampled_hp_b;
    const limit = 6000;
    const baseline_config: mcts.Config = .{ .rollouts = o.baseline_rollouts, .workers = 1, .nodes = o.nodes, .depth = 128, .max_ticks = limit, .seed = seed, .evaluator = if (o.baseline_rollout) .rollout else .heuristic, .milliseconds = o.milliseconds };
    var candidate_config = baseline_config;
    candidate_config.rollouts = o.rollouts;
    candidate_config.model = model;
    candidate_config.learned_mix = o.mix;
    candidate_config.evaluator = if (model != null) .learned else baseline_config.evaluator;
    for (0..if (o.generate) @as(usize, 1) else 2) |swap| {
        var d = try sim.Duel(a, b).init(alloc);
        defer d.deinit();
        d.staggerOpening();
        const s = d.arena.combat();
        s.distance[0] = distance;
        s.pos_x_a[0] = -distance / 2;
        s.pos_x_b[0] = distance / 2;
        s.hp_a[0] = hp_a;
        s.hp_b[0] = hp_b;
        if (o.default_pets) {
            const pets = @import("pets.zig");
            pets.set(s, true, 0, if (a == .warlock) .imp else .none);
            pets.set(s, false, 0, if (b == .warlock) .imp else .none);
        }
        const base = try mcts.Search(a, b).init(alloc, baseline_config);
        defer base.deinit();
        const candidate = if (o.generate) base else try mcts.Search(a, b).init(alloc, candidate_config);
        defer if (!o.generate) candidate.deinit();
        var rb = std.Random.DefaultPrng.init(seed ^ 0xabc);
        var rc = std.Random.DefaultPrng.init(seed ^ 0xabc);
        var samples = std.ArrayList(Sample).init(alloc);
        defer samples.deinit();
        var base_seconds: f64 = 0;
        var candidate_seconds: f64 = 0;
        var base_calls: usize = 0;
        var candidate_calls: usize = 0;
        var base_rollouts: u64 = 0;
        var candidate_rollouts: u64 = 0;
        var latencies = std.ArrayList(f64).init(alloc);
        defer latencies.deinit();
        const started = std.time.nanoTimestamp();
        var action_hash = std.hash.Wyhash.init(0);
        while (s.is_active[0] != 0) {
            const ra = d.readyTactical(true);
            const rbb = d.readyTactical(false);
            if (ra[0] or rbb[0]) {
                const root = d.snapshot(0);
                if (o.generate) try samples.append(.{ .x = .{ value.features(a, b, true, &d, 0, limit), value.features(a, b, false, &d, 0, limit) }, .heuristic = mcts.evaluateHeuristic(a, b, &d, 0) });
                // Each search models both players but commits only its own side.
                // No controller observes the other's selected action.
                var aa: sim.Action = .{};
                var bb: sim.Action = .{};
                if (o.generate or (if (swap == 0) rbb[0] else ra[0])) {
                    const decision = base.decide(root, rb.random());
                    base_seconds += decision.seconds;
                    base_calls += 1;
                    base_rollouts += decision.stats.rollouts;
                    if (o.generate) {
                        aa = decision.actions[0];
                        bb = decision.actions[1];
                    } else if (swap == 0) bb = decision.actions[1] else aa = decision.actions[0];
                }
                if (!o.generate and (if (swap == 0) ra[0] else rbb[0])) {
                    const decision = candidate.decide(root, rc.random());
                    candidate_seconds += decision.seconds;
                    candidate_calls += 1;
                    candidate_rollouts += decision.stats.rollouts;
                    try latencies.append(decision.seconds);
                    if (swap == 0) aa = decision.actions[0] else bb = decision.actions[1];
                }
                action_hash.update(std.mem.asBytes(&aa.ability));
                action_hash.update(std.mem.asBytes(&aa.movement));
                action_hash.update(std.mem.asBytes(&bb.ability));
                action_hash.update(std.mem.asBytes(&bb.movement));
                d.applyMasked(@splat(aa), @splat(bb), ra, rbb);
            }
            d.tick(limit);
        }
        std.mem.sort(f64, latencies.items, {}, std.sort.asc(f64));
        const record = .{
            .fingerprint = identity.fingerprint,
            .seed = seed,
            .configuration = .{ .algorithm = "puct", .boundary = "event", .workers = 1, .nodes = o.nodes, .depth = 128, .max_ticks = limit, .truncation_ticks = 30, .baseline_rollouts = o.baseline_rollouts, .candidate_rollouts = o.rollouts, .milliseconds = o.milliseconds, .mix = o.mix, .baseline_evaluator = @tagName(baseline_config.evaluator), .candidate_evaluator = @tagName(candidate_config.evaluator), .full_health = o.full_health, .default_pets = o.default_pets, .model_mode = if (model) |v| @tagName(v.mode) else "none" },
            .class_a = @tagName(a),
            .class_b = @tagName(b),
            .candidate_side = if (swap == 0) "a" else "b",
            .distance = distance,
            .initial_hp_a = hp_a,
            .initial_hp_b = hp_b,
            .reward_a = d.reward(0),
            .score = (1 + (if (swap == 0) d.reward(0) else -d.reward(0))) / 2,
            .ticks = d.ticks[0],
            .hp_a = s.hp_a[0],
            .hp_b = s.hp_b[0],
            .action_hash = action_hash.final(),
            .base_seconds = base_seconds,
            .candidate_seconds = candidate_seconds,
            .base_calls = base_calls,
            .candidate_calls = candidate_calls,
            .base_rollouts = base_rollouts,
            .candidate_rollouts = candidate_rollouts,
            .candidate_p95_seconds = if (latencies.items.len > 0) latencies.items[@min(latencies.items.len - 1, latencies.items.len * 95 / 100)] else 0,
            .wall_seconds = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started)) / 1e9,
            .samples = samples.items,
        };
        try std.json.stringify(record, .{}, writer);
        try writer.writeByte('\n');
    }
}
