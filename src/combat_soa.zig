const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");

const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const bool16 = simd.bool16;
const clamp16 = simd.clamp16;
const select16 = simd.select16;
const vAnd16 = simd.vAnd16;
const vOr16 = simd.vOr16;
const VEC_LEN = simd.SimdConfig.VecLen16;
const ALIGNMENT = simd.SimdConfig.Alignment;

/// Structure-of-Arrays (SoA) layout for high-throughput batch combat simulation.
/// All columns are memory-aligned to 64 bytes (AVX-512 / Cache line boundary).
pub const CombatantPool = struct {
    count: usize,
    capacity: usize,
    allocator: mem.Allocator,

    // Primary Vitals
    hp: []align(ALIGNMENT) f32,
    max_hp: []align(ALIGNMENT) f32,
    shield: []align(ALIGNMENT) f32,
    mana: []align(ALIGNMENT) f32,

    // Defensive / Offensive Attributes
    armor: []align(ALIGNMENT) f32,
    attack_power: []align(ALIGNMENT) f32,
    attack_speed: []align(ALIGNMENT) f32, // attacks per second
    attack_timer: []align(ALIGNMENT) f32, // seconds until next auto-attack

    // Status Effects (DOT / Buffs)
    dot_dps: []align(ALIGNMENT) f32,      // damage per second from active DOT
    dot_timer: []align(ALIGNMENT) f32,    // remaining duration of DOT

    // State / Liveness (1 = alive, 0 = dead)
    is_alive: []align(ALIGNMENT) u32,

    pub fn init(allocator: mem.Allocator, capacity: usize) !CombatantPool {
        // Pad capacity to multiple of 16 for clean vector loads/stores without bounds branches
        const padded_cap = (capacity + VEC_LEN - 1) & ~@as(usize, VEC_LEN - 1);

        const hp = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(hp);
        const max_hp = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(max_hp);
        const shield = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(shield);
        const mana = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(mana);

        const armor = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(armor);
        const attack_power = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(attack_power);
        const attack_speed = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(attack_speed);
        const attack_timer = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(attack_timer);

        const dot_dps = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dot_dps);
        const dot_timer = try allocator.alignedAlloc(f32, ALIGNMENT, padded_cap);
        errdefer allocator.free(dot_timer);

        const is_alive = try allocator.alignedAlloc(u32, ALIGNMENT, padded_cap);
        errdefer allocator.free(is_alive);

        @memset(hp, 0.0);
        @memset(max_hp, 0.0);
        @memset(shield, 0.0);
        @memset(mana, 0.0);
        @memset(armor, 0.0);
        @memset(attack_power, 0.0);
        @memset(attack_speed, 1.0);
        @memset(attack_timer, 0.0);
        @memset(dot_dps, 0.0);
        @memset(dot_timer, 0.0);
        @memset(is_alive, 0);

        return CombatantPool{
            .count = 0,
            .capacity = padded_cap,
            .allocator = allocator,
            .hp = hp,
            .max_hp = max_hp,
            .shield = shield,
            .mana = mana,
            .armor = armor,
            .attack_power = attack_power,
            .attack_speed = attack_speed,
            .attack_timer = attack_timer,
            .dot_dps = dot_dps,
            .dot_timer = dot_timer,
            .is_alive = is_alive,
        };
    }

    pub fn deinit(self: *CombatantPool) void {
        self.allocator.free(self.hp);
        self.allocator.free(self.max_hp);
        self.allocator.free(self.shield);
        self.allocator.free(self.mana);
        self.allocator.free(self.armor);
        self.allocator.free(self.attack_power);
        self.allocator.free(self.attack_speed);
        self.allocator.free(self.attack_timer);
        self.allocator.free(self.dot_dps);
        self.allocator.free(self.dot_timer);
        self.allocator.free(self.is_alive);
    }

    /// Reset and seed N combatants with stats
    pub fn seedRandom(self: *CombatantPool, count: usize, seed: u64) void {
        self.count = count;
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        for (0..count) |i| {
            const base_hp = 500.0 + rand.float(f32) * 1500.0;
            self.hp[i] = base_hp;
            self.max_hp[i] = base_hp;
            self.shield[i] = rand.float(f32) * 200.0;
            self.mana[i] = 100.0;
            self.armor[i] = 20.0 + rand.float(f32) * 80.0; // 20 - 100 armor
            self.attack_power[i] = 40.0 + rand.float(f32) * 120.0;
            self.attack_speed[i] = 0.8 + rand.float(f32) * 1.2; // 0.8 - 2.0 attacks/sec
            self.attack_timer[i] = 1.0 / self.attack_speed[i];
            self.dot_dps[i] = if (rand.boolean()) 25.0 + rand.float(f32) * 50.0 else 0.0;
            self.dot_timer[i] = if (self.dot_dps[i] > 0) 5.0 + rand.float(f32) * 5.0 else 0.0;
            self.is_alive[i] = 1;
        }
    }

    /// Super-optimized AVX-512 batch simulation step.
    /// Ticks timers, applies DOT damage through shields and armor mitigation,
    /// and checks liveness branchlessly for 16 combatants per instruction.
    pub fn tickBatch(self: *CombatantPool, dt: f32) usize {
        const v_dt: f32x16 = @splat(dt);
        const v_zeros: f32x16 = @splat(0.0);
        const v_hundred: f32x16 = @splat(100.0);
        const v_ones_u32: u32x16 = @splat(1);
        const v_zeros_u32: u32x16 = @splat(0);

        var alive_count: usize = 0;
        var i: usize = 0;

        while (i < self.count) : (i += VEC_LEN) {
            // 1. Vector loads directly from aligned memory
            var v_hp: f32x16 = self.hp[i..][0..VEC_LEN].*;
            var v_shield: f32x16 = self.shield[i..][0..VEC_LEN].*;
            const v_armor: f32x16 = self.armor[i..][0..VEC_LEN].*;
            const v_dot_dps: f32x16 = self.dot_dps[i..][0..VEC_LEN].*;
            var v_dot_timer: f32x16 = self.dot_timer[i..][0..VEC_LEN].*;
            var v_atk_timer: f32x16 = self.attack_timer[i..][0..VEC_LEN].*;

            // 2. Decrement attack timer and dot timer (clamped at 0)
            v_atk_timer = @max(v_zeros, v_atk_timer - v_dt);
            const active_dot_mask: bool16 = v_dot_timer > v_zeros;
            v_dot_timer = @max(v_zeros, v_dot_timer - v_dt);

            // 3. Calculate incoming raw DOT damage for this tick
            // If dot_timer was > 0, damage = dot_dps * dt, else 0
            const raw_dot_dmg = select16(active_dot_mask, v_dot_dps * v_dt, v_zeros);

            // 4. Branchless shield absorption:
            // shield_absorb = min(shield, raw_damage)
            const shield_absorb = @min(v_shield, raw_dot_dmg);
            v_shield = v_shield - shield_absorb;
            const penetrating_dmg = raw_dot_dmg - shield_absorb;

            // 5. Armor mitigation on penetrating damage:
            // effective_dmg = penetrating * (100 / (100 + max(0, armor)))
            const mitigation_factor = v_hundred / (v_hundred + @max(v_zeros, v_armor));
            const mitigated_dmg = penetrating_dmg * mitigation_factor;

            // 6. Apply damage to HP & branchless death check
            v_hp = @max(v_zeros, v_hp - mitigated_dmg);
            const alive_mask: bool16 = v_hp > v_zeros;
            const v_alive: u32x16 = @select(u32, alive_mask, v_ones_u32, v_zeros_u32);

            // 7. Write back to aligned arrays
            self.hp[i..][0..VEC_LEN].* = v_hp;
            self.shield[i..][0..VEC_LEN].* = v_shield;
            self.dot_timer[i..][0..VEC_LEN].* = v_dot_timer;
            self.attack_timer[i..][0..VEC_LEN].* = v_atk_timer;
            self.is_alive[i..][0..VEC_LEN].* = v_alive;

            // Accumulate alive count
            alive_count += @reduce(.Add, v_alive);
        }

        return alive_count;
    }

    /// Simulate 1v1 PvP duels in parallel across SIMD lanes!
    /// Lane k in Pool A fights Lane k in Pool B.
    /// Runs until all duels are decided or max_ticks reached.
    pub fn simulateDuelsSoA(
        team_a: *CombatantPool,
        team_b: *CombatantPool,
        dt: f32,
        max_ticks: usize,
    ) struct { wins_a: usize, wins_b: usize, draws: usize, total_ticks: usize } {
        const v_dt: f32x16 = @splat(dt);
        const v_zeros: f32x16 = @splat(0.0);
        const v_hundred: f32x16 = @splat(100.0);
        const v_zeros_u32: u32x16 = @splat(0);
        const v_ones_u32: u32x16 = @splat(1);

        const n = @min(team_a.count, team_b.count);
        var wins_a: usize = 0;
        var wins_b: usize = 0;
        var draws: usize = 0;
        var total_sim_ticks: usize = 0;

        var i: usize = 0;
        while (i < n) : (i += VEC_LEN) {
            // Load state for 16 duels
            var hp_a: f32x16 = team_a.hp[i..][0..VEC_LEN].*;
            var hp_b: f32x16 = team_b.hp[i..][0..VEC_LEN].*;
            var shld_a: f32x16 = team_a.shield[i..][0..VEC_LEN].*;
            var shld_b: f32x16 = team_b.shield[i..][0..VEC_LEN].*;
            const arm_a: f32x16 = team_a.armor[i..][0..VEC_LEN].*;
            const arm_b: f32x16 = team_b.armor[i..][0..VEC_LEN].*;
            const ap_a: f32x16 = team_a.attack_power[i..][0..VEC_LEN].*;
            const ap_b: f32x16 = team_b.attack_power[i..][0..VEC_LEN].*;
            const as_a: f32x16 = team_a.attack_speed[i..][0..VEC_LEN].*;
            const as_b: f32x16 = team_b.attack_speed[i..][0..VEC_LEN].*;

            var tmr_a: f32x16 = team_a.attack_timer[i..][0..VEC_LEN].*;
            var tmr_b: f32x16 = team_b.attack_timer[i..][0..VEC_LEN].*;

            const interval_a = @as(f32x16, @splat(1.0)) / as_a;
            const interval_b = @as(f32x16, @splat(1.0)) / as_b;

            const mit_a = v_hundred / (v_hundred + @max(v_zeros, arm_a));
            const mit_b = v_hundred / (v_hundred + @max(v_zeros, arm_b));

            var active_duels: bool16 = vAnd16(hp_a > v_zeros, hp_b > v_zeros);

            var tick: usize = 0;
            while (tick < max_ticks and @reduce(.Or, active_duels)) : (tick += 1) {
                total_sim_ticks += 16;

                // Advance attack timers
                tmr_a = tmr_a - v_dt;
                tmr_b = tmr_b - v_dt;

                // Check who strikes this tick
                const strike_a: bool16 = vAnd16(tmr_a <= v_zeros, active_duels);
                const strike_b: bool16 = vAnd16(tmr_b <= v_zeros, active_duels);

                // Reset timers for those who struck
                tmr_a = select16(strike_a, interval_a, tmr_a);
                tmr_b = select16(strike_b, interval_b, tmr_b);

                // Team A attacks Team B
                const dmg_to_b = select16(strike_a, ap_a, v_zeros);
                const absorb_b = @min(shld_b, dmg_to_b);
                shld_b = shld_b - absorb_b;
                const pen_b = dmg_to_b - absorb_b;
                hp_b = @max(v_zeros, hp_b - pen_b * mit_b);

                // Team B attacks Team A
                const dmg_to_a = select16(strike_b, ap_b, v_zeros);
                const absorb_a = @min(shld_a, dmg_to_a);
                shld_a = shld_a - absorb_a;
                const pen_a = dmg_to_a - absorb_a;
                hp_a = @max(v_zeros, hp_a - pen_a * mit_a);

                // Re-evaluate liveness
                active_duels = vAnd16(hp_a > v_zeros, hp_b > v_zeros);
            }

            // Outcome tally for these 16 duels
            const a_won: bool16 = vAnd16(hp_a > v_zeros, hp_b <= v_zeros);
            const b_won: bool16 = vAnd16(hp_b > v_zeros, hp_a <= v_zeros);
            const both_dead = vAnd16(hp_a <= v_zeros, hp_b <= v_zeros);
            const both_alive = vAnd16(hp_a > v_zeros, hp_b > v_zeros);
            const draw_mask: bool16 = vOr16(both_dead, both_alive);

            const v_a_won: u32x16 = @select(u32, a_won, v_ones_u32, v_zeros_u32);
            const v_b_won: u32x16 = @select(u32, b_won, v_ones_u32, v_zeros_u32);
            const v_draw: u32x16 = @select(u32, draw_mask, v_ones_u32, v_zeros_u32);

            wins_a += @reduce(.Add, v_a_won);
            wins_b += @reduce(.Add, v_b_won);
            draws += @reduce(.Add, v_draw);
        }

        return .{
            .wins_a = wins_a,
            .wins_b = wins_b,
            .draws = draws,
            .total_ticks = total_sim_ticks,
        };
    }
};

test "CombatantPool lifecycle and SIMD tick" {
    var pool = try CombatantPool.init(std.testing.allocator, 32);
    defer pool.deinit();

    pool.seedRandom(32, 12345);
    try std.testing.expectEqual(@as(usize, 32), pool.count);

    const initial_alive = pool.tickBatch(0.016);
    try std.testing.expect(initial_alive > 0);
}
