const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");

const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const bool16 = simd.bool16;
const select16 = simd.select16;
const VEC_LEN = simd.SimdConfig.VecLen16;
const ALIGNMENT = simd.SimdConfig.Alignment;

pub const IN_DIM: usize = 24;
pub const HIDDEN_DIM: usize = 24;
pub const ACTION_DIM: usize = 9;
pub const WEIGHTS_COUNT: usize = (HIDDEN_DIM * IN_DIM) + HIDDEN_DIM + (ACTION_DIM * HIDDEN_DIM) + ACTION_DIM + HIDDEN_DIM + 1;

/// Genome representing an individual neural policy.
/// MLP structure: 24 Inputs -> 24 Hidden (ReLU) -> 9 Action Logits + 1 Movement Output.
pub const PolicyGenome = struct {
    // Layer 1
    w1: [HIDDEN_DIM][IN_DIM]f32,
    b1: [HIDDEN_DIM]f32,

    // Layer 2: Action Logits
    w2: [ACTION_DIM][HIDDEN_DIM]f32,
    b2: [ACTION_DIM]f32,

    // Movement Head: outputs continuous move intent [-1.0 (advance), 0.0 (stand), +1.0 (kite)]
    w_move: [HIDDEN_DIM]f32,
    b_move: f32,

    // Performance tracking
    elo: f32 = 1200.0,
    fitness: f32 = 0.0,
    wins: u32 = 0,
    losses: u32 = 0,
    draws: u32 = 0,

    pub fn initRandom(rand: std.Random) PolicyGenome {
        var g: PolicyGenome = undefined;
        g.elo = 1200.0;
        g.fitness = 0.0;
        g.wins = 0;
        g.losses = 0;
        g.draws = 0;

        // Xavier / He initialization
        const scale1 = @sqrt(2.0 / @as(f32, @floatFromInt(IN_DIM)));
        for (0..HIDDEN_DIM) |h| {
            for (0..IN_DIM) |in_idx| {
                g.w1[h][in_idx] = (rand.float(f32) * 2.0 - 1.0) * scale1;
            }
            g.b1[h] = 0.0;
        }

        const scale2 = @sqrt(2.0 / @as(f32, @floatFromInt(HIDDEN_DIM)));
        for (0..ACTION_DIM) |a| {
            for (0..HIDDEN_DIM) |h| {
                g.w2[a][h] = (rand.float(f32) * 2.0 - 1.0) * scale2;
            }
            g.b2[a] = 0.0;
        }

        for (0..HIDDEN_DIM) |h| {
            g.w_move[h] = (rand.float(f32) * 2.0 - 1.0) * scale2;
        }
        g.b_move = 0.0;

        return g;
    }

    /// Mutate genome weights with Gaussian perturbation
    pub fn mutate(self: *PolicyGenome, rand: std.Random, rate: f32, sigma: f32) void {
        for (0..HIDDEN_DIM) |h| {
            for (0..IN_DIM) |in_idx| {
                if (rand.float(f32) < rate) {
                    const noise = (rand.float(f32) + rand.float(f32) + rand.float(f32) - 1.5) * 2.0 * sigma;
                    self.w1[h][in_idx] += noise;
                }
            }
            if (rand.float(f32) < rate) {
                const noise = (rand.float(f32) + rand.float(f32) - 1.0) * sigma;
                self.b1[h] += noise;
            }
        }

        for (0..ACTION_DIM) |a| {
            for (0..HIDDEN_DIM) |h| {
                if (rand.float(f32) < rate) {
                    const noise = (rand.float(f32) + rand.float(f32) + rand.float(f32) - 1.5) * 2.0 * sigma;
                    self.w2[a][h] += noise;
                }
            }
            if (rand.float(f32) < rate) {
                const noise = (rand.float(f32) + rand.float(f32) - 1.0) * sigma;
                self.b2[a] += noise;
            }
        }

        for (0..HIDDEN_DIM) |h| {
            if (rand.float(f32) < rate) {
                const noise = (rand.float(f32) + rand.float(f32) - 1.0) * sigma;
                self.w_move[h] += noise;
            }
        }
        if (rand.float(f32) < rate) {
            self.b_move += (rand.float(f32) + rand.float(f32) - 1.0) * sigma;
        }
    }

    /// Uniform crossover between parent A and parent B
    pub fn crossover(parent_a: *const PolicyGenome, parent_b: *const PolicyGenome, rand: std.Random) PolicyGenome {
        var child: PolicyGenome = undefined;
        child.elo = (parent_a.elo + parent_b.elo) * 0.5;
        child.fitness = 0.0;
        child.wins = 0;
        child.losses = 0;
        child.draws = 0;

        for (0..HIDDEN_DIM) |h| {
            for (0..IN_DIM) |in_idx| {
                child.w1[h][in_idx] = if (rand.boolean()) parent_a.w1[h][in_idx] else parent_b.w1[h][in_idx];
            }
            child.b1[h] = if (rand.boolean()) parent_a.b1[h] else parent_b.b1[h];
        }

        for (0..ACTION_DIM) |a| {
            for (0..HIDDEN_DIM) |h| {
                child.w2[a][h] = if (rand.boolean()) parent_a.w2[a][h] else parent_b.w2[a][h];
            }
            child.b2[a] = if (rand.boolean()) parent_a.b2[a] else parent_b.b2[a];
        }

        for (0..HIDDEN_DIM) |h| {
            child.w_move[h] = if (rand.boolean()) parent_a.w_move[h] else parent_b.w_move[h];
        }
        child.b_move = if (rand.boolean()) parent_a.b_move else parent_b.b_move;

        return child;
    }

    /// Evaluates policy across 16 parallel duels simultaneously in AVX-512 registers!
    /// Returns chosen action indices (u32x16) and continuous movement intents (f32x16 [-1..+1]).
    pub fn forward16(
        self: *const PolicyGenome,
        obs: [IN_DIM]f32x16,
        action_masks: [ACTION_DIM]bool16,
    ) struct { actions: u32x16, move_intents: f32x16 } {
        const v_zeros: f32x16 = @splat(0.0);
        const v_neg_inf: f32x16 = @splat(-1e9);

        // 1. Layer 1: 20 -> 24 with ReLU
        var hidden: [HIDDEN_DIM]f32x16 = undefined;
        inline for (0..HIDDEN_DIM) |h| {
            var acc: f32x16 = @splat(self.b1[h]);
            inline for (0..IN_DIM) |in_idx| {
                acc = acc + obs[in_idx] * @as(f32x16, @splat(self.w1[h][in_idx]));
            }
            hidden[h] = @max(v_zeros, acc);
        }

        // 2. Layer 2: 24 -> 8 Action Logits with branchless Action Masking
        var logits: [ACTION_DIM]f32x16 = undefined;
        inline for (0..ACTION_DIM) |a| {
            var acc: f32x16 = @splat(self.b2[a]);
            inline for (0..HIDDEN_DIM) |h| {
                acc = acc + hidden[h] * @as(f32x16, @splat(self.w2[a][h]));
            }
            // Branchless mask: illegal actions get -1e9
            logits[a] = select16(action_masks[a], acc, v_neg_inf);
        }

        // 3. Movement Head: 24 -> 1 scalar, clamped to [-1.0, 1.0]
        var move_acc: f32x16 = @splat(self.b_move);
        inline for (0..HIDDEN_DIM) |h| {
            move_acc = move_acc + hidden[h] * @as(f32x16, @splat(self.w_move[h]));
        }
        // Branchless clamp between -1.0 (advance) and +1.0 (kite)
        const move_intent = simd.clamp16(move_acc, @splat(-1.0), @splat(1.0));

        // 4. Branchless ArgMax across 8 actions for each lane
        var best_val: f32x16 = logits[0];
        var best_act: u32x16 = @splat(0);

        inline for (1..ACTION_DIM) |a| {
            const is_greater = logits[a] > best_val;
            best_val = select16(is_greater, logits[a], best_val);
            best_act = @select(u32, is_greater, @as(u32x16, @splat(@intCast(a))), best_act);
        }

        return .{
            .actions = best_act,
            .move_intents = move_intent,
        };
    }

    /// Zero-overhead binary export of policy genome (~2.8 KB)
    pub fn saveToFile(self: *const PolicyGenome, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        const writer = file.writer();
        try writer.writeAll(mem.asBytes(self));
    }

    /// Zero-overhead binary ingestion of policy genome
    pub fn loadFromFile(file_path: []const u8) !PolicyGenome {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        if ((try file.stat()).size != @sizeOf(PolicyGenome)) return error.InvalidModelSize;
        var g: PolicyGenome = undefined;
        const reader = file.reader();
        try reader.readNoEof(mem.asBytes(&g));
        return g;
    }
};

test "PolicyGenome forward and mutation" {
    var prng = std.Random.DefaultPrng.init(1337);
    const rand = prng.random();

    var genome = PolicyGenome.initRandom(rand);
    var obs: [IN_DIM]f32x16 = undefined;
    for (0..IN_DIM) |i| {
        obs[i] = @splat(0.5);
    }

    var masks: [ACTION_DIM]bool16 = undefined;
    for (0..ACTION_DIM) |a| {
        masks[a] = @splat(true);
    }

    const out = genome.forward16(obs, masks);
    try std.testing.expect(out.actions[0] < ACTION_DIM);
    try std.testing.expect(out.move_intents[0] >= -1.0 and out.move_intents[0] <= 1.0);

    // Test mutation
    genome.mutate(rand, 0.1, 0.05);
    const out2 = genome.forward16(obs, masks);
    try std.testing.expect(out2.actions[0] < ACTION_DIM);

    // Test save & load
    const tmp_path = "tmp_test_genome.bin";
    try genome.saveToFile(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    const loaded = try PolicyGenome.loadFromFile(tmp_path);
    try std.testing.expectEqual(genome.elo, loaded.elo);
    try std.testing.expectEqual(genome.b_move, loaded.b_move);
}
