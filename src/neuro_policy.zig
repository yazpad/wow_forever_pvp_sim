//! Compact SIMD Neural Policy Network for PvP Neuroevolution.
//! Evaluates 16 combat lanes simultaneously using `@Vector(16, f32)`.
//! Learned logits refine soft tactical priors; legal actions remain overridable.
const std = @import("std");
const simd = @import("simd.zig");
const sim = @import("search_sim.zig");
const combat = @import("combat_spec.zig");
const action_catalog = @import("action_catalog_generated.zig");
const Spec = @import("spec.zig").Spec;

const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const bool16 = simd.bool16;
const select16 = simd.select16;

pub const NumFeatures: usize = 44;
pub const NumHidden: usize = 24;
pub const NumAbilities: usize = action_catalog.ActionCount;
pub const NumMovements: usize = 3; // -1, 0, +1
pub const NumOutputs: usize = NumAbilities + NumMovements;
pub const ParamCount: usize = NumHidden * NumFeatures + NumHidden + NumOutputs * NumHidden + NumOutputs;

pub const Magic: [4]u8 = "NEPL".*;
pub const Version: u32 = 4;

pub const Policy = struct {
    params: [ParamCount]f32 = @splat(0),

    pub fn initZero() Policy {
        return .{};
    }

    pub fn initRandom(rng: std.Random, scale: f32) Policy {
        var p: Policy = .{};
        const w1_scale = scale / @sqrt(@as(f32, @floatFromInt(NumFeatures)));
        const w2_scale = scale / @sqrt(@as(f32, @floatFromInt(NumHidden)));

        var idx: usize = 0;
        for (0..NumHidden * NumFeatures) |_| {
            p.params[idx] = rng.floatNorm(f32) * w1_scale;
            idx += 1;
        }
        for (0..NumHidden) |_| {
            p.params[idx] = 0;
            idx += 1;
        }
        for (0..NumOutputs * NumHidden) |_| {
            p.params[idx] = rng.floatNorm(f32) * w2_scale;
            idx += 1;
        }
        for (0..NumOutputs) |_| {
            p.params[idx] = 0;
            idx += 1;
        }
        return p;
    }

    pub fn saveFile(self: *const Policy, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();
        try w.writeAll(&Magic);
        try w.writeInt(u32, Version, .little);
        try w.writeInt(u32, @intCast(ParamCount), .little);
        try w.writeAll(std.mem.sliceAsBytes(&self.params));
        try bw.flush();
    }

    pub fn loadFile(path: []const u8) !Policy {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var magic: [4]u8 = undefined;
        if (try file.readAll(&magic) != 4 or !std.mem.eql(u8, &magic, &Magic)) return error.InvalidPolicyFile;
        var ver_buf: [4]u8 = undefined;
        if (try file.readAll(&ver_buf) != 4) return error.InvalidPolicyFile;
        const ver = std.mem.readInt(u32, &ver_buf, .little);
        if (ver != Version and ver != 2 and ver != 3) return error.UnsupportedPolicyVersion;
        var cnt_buf: [4]u8 = undefined;
        if (try file.readAll(&cnt_buf) != 4) return error.InvalidPolicyFile;
        const cnt = std.mem.readInt(u32, &cnt_buf, .little);
        var p: Policy = .{};
        // The item action was appended at 26, before the three movement
        // outputs. Preserve old ability/movement rows rather than shifting a
        // learned movement logit into the new item action.
        inline for (.{ 2, 3, Version }, .{ 36, 41, NumFeatures }) |legacy_version, old_features| {
            const old_outputs = 26 + NumMovements;
            const old_count = NumHidden * old_features + NumHidden + old_outputs * NumHidden + old_outputs;
            if (ver == legacy_version and cnt == old_count) {
                var old: [old_count]f32 = undefined;
                const bytes = std.mem.sliceAsBytes(&old);
                if (try file.readAll(bytes) != bytes.len) return error.UnexpectedEof;
                for (0..NumHidden) |h| @memcpy(p.params[h * NumFeatures ..][0..old_features], old[h * old_features ..][0..old_features]);
                const old_b1 = NumHidden * old_features;
                const new_b1 = NumHidden * NumFeatures;
                @memcpy(p.params[new_b1..][0..NumHidden], old[old_b1..][0..NumHidden]);
                const old_w2 = old_b1 + NumHidden;
                const new_w2 = new_b1 + NumHidden;
                const old_b2 = old_w2 + old_outputs * NumHidden;
                const new_b2 = new_w2 + NumOutputs * NumHidden;
                for (0..old_outputs) |row| {
                    const destination = if (row >= 26) row + 1 else row;
                    @memcpy(p.params[new_w2 + destination * NumHidden ..][0..NumHidden], old[old_w2 + row * NumHidden ..][0..NumHidden]);
                    p.params[new_b2 + destination] = old[old_b2 + row];
                }
                return p;
            }
        }
        inline for (.{ 2, 3 }, .{ 36, 41 }) |legacy_version, old_features| {
            if (ver == legacy_version) {
                // Preserve every old input weight and the complete output layer.
                // Extra observations start with zero influence on legacy policies.
                const old_count = NumHidden * old_features + NumHidden + NumOutputs * NumHidden + NumOutputs;
                if (cnt != old_count) return error.PolicyDimensionMismatch;
                var old: [old_count]f32 = undefined;
                const old_bytes = std.mem.sliceAsBytes(&old);
                if (try file.readAll(old_bytes) != old_bytes.len) return error.UnexpectedEof;
                for (0..NumHidden) |h| {
                    @memcpy(p.params[h * NumFeatures ..][0..old_features], old[h * old_features ..][0..old_features]);
                }
                @memcpy(p.params[NumHidden * NumFeatures ..], old[NumHidden * old_features ..]);
                return p;
            }
        }
        if (cnt != ParamCount) return error.PolicyDimensionMismatch;
        const bytes = std.mem.sliceAsBytes(&p.params);
        if (try file.readAll(bytes) != bytes.len) return error.UnexpectedEof;
        return p;
    }

    /// 16-lane SIMD batch forward pass: Input(44) -> Linear -> ReLU(24) -> Linear -> Output(30)
    pub fn forward16(self: *const Policy, features: *const [NumFeatures]f32x16, out: *[NumOutputs]f32x16) void {
        const v_zero: f32x16 = @splat(0.0);
        const w1_offset: usize = 0;
        const b1_offset: usize = NumHidden * NumFeatures;
        const w2_offset: usize = b1_offset + NumHidden;
        const b2_offset: usize = w2_offset + NumOutputs * NumHidden;

        var hidden: [NumHidden]f32x16 = undefined;
        for (0..NumHidden) |h| {
            var acc: f32x16 = @splat(self.params[b1_offset + h]);
            const row = w1_offset + h * NumFeatures;
            for (0..NumFeatures) |f| {
                const w: f32x16 = @splat(self.params[row + f]);
                acc = @mulAdd(f32x16, w, features[f], acc);
            }
            hidden[h] = @max(v_zero, acc);
        }

        for (0..NumOutputs) |o| {
            var acc: f32x16 = @splat(self.params[b2_offset + o]);
            const row = w2_offset + o * NumHidden;
            for (0..NumHidden) |h| {
                const w: f32x16 = @splat(self.params[row + h]);
                acc = @mulAdd(f32x16, w, hidden[h], acc);
            }
            out[o] = acc;
        }
    }

    /// Extracts normalized combat features across all 16 SIMD lanes for `side_a`.
    pub fn extractFeatures(
        comptime a: Spec,
        comptime b: Spec,
        duel: *const sim.Duel(a, b),
        comptime side_a: bool,
        feats: *[NumFeatures]f32x16,
    ) void {
        feats.* = @splat(@splat(0));
        const base = if (side_a) duel.arena.getObservationsA(0) else duel.arena.getObservationsB(0);
        inline for (0..24) |idx| {
            feats[idx] = base[idx];
        }

        const state: *const combat.WarlockArenaPool = if (a == .warlock and b == .warlock) &duel.arena else &duel.arena.state;
        const self_suf = if (side_a) "_a" else "_b";
        const enemy_suf = if (side_a) "_b" else "_a";

        const v_zero: f32x16 = @splat(0.0);
        const v_one: f32x16 = @splat(1.0);

        const max_hp_self = @max(@as(f32x16, @splat(1.0)), @as(f32x16, @field(state, "max_health" ++ self_suf)[0..16].*));
        const max_mana_self = @max(@as(f32x16, @splat(1.0)), @as(f32x16, @field(state, "max_mana" ++ self_suf)[0..16].*));
        const max_hp_enemy = @max(@as(f32x16, @splat(1.0)), @as(f32x16, @field(state, "max_health" ++ enemy_suf)[0..16].*));
        const max_mana_enemy = @max(@as(f32x16, @splat(1.0)), @as(f32x16, @field(state, "max_mana" ++ enemy_suf)[0..16].*));

        const hp_self: f32x16 = @field(state, "hp" ++ self_suf)[0..16].*;
        const mana_self: f32x16 = @field(state, "mana" ++ self_suf)[0..16].*;
        const hp_enemy: f32x16 = @field(state, "hp" ++ enemy_suf)[0..16].*;
        const mana_enemy: f32x16 = @field(state, "mana" ++ enemy_suf)[0..16].*;

        feats[0] = hp_self / max_hp_self;
        if ((if (side_a) a else b) != .warrior) feats[1] = mana_self / max_mana_self;
        feats[2] = hp_enemy / max_hp_enemy;
        feats[3] = mana_enemy / max_mana_enemy;
        if ((if (side_a) b else a) == .warrior) {
            const enemy_cfg = duel.arena.warrior.configs[@TypeOf(duel.arena.warrior).slot(!side_a)];
            const cap = 100 + 10 * @as(f32, @floatFromInt(enemy_cfg.build.ranks[@intFromEnum(@import("warrior_talents.zig").Talent.boundlessRage)]));
            feats[3] = duel.arena.warrior.floats(!side_a, .rage, 0).* / @as(f32x16, @splat(cap));
        }
        if ((if (side_a) a else b) != .warrior) feats[19] = feats[0] - feats[2];

        feats[24] = @as(f32x16, @field(state, "siphon_timer" ++ enemy_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 30.0));
        feats[25] = @as(f32x16, @field(state, "immolate_timer" ++ enemy_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 15.0));
        feats[26] = @as(f32x16, @field(state, "siphon_timer" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 30.0));
        feats[27] = @as(f32x16, @field(state, "immolate_timer" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 15.0));
        feats[28] = @as(f32x16, @field(state, "agony_timer" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 18.0));
        feats[29] = @as(f32x16, @field(state, "corruption_timer" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 15.0));
        feats[30] = @as(f32x16, @field(state, "shadowburn_cd" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 15.0));
        feats[31] = @as(f32x16, @field(state, "conflagrate_cd" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 10.0));
        feats[32] = @as(f32x16, @field(state, "seduction_cd" ++ self_suf)[0..16].*) * @as(f32x16, @splat(1.0 / 24.0));
        const hdr: f32x16 = @field(state, "horror_dr_tier" ++ enemy_suf)[0..16].*;
        const sdr: f32x16 = @field(state, "stun_dr_tier" ++ enemy_suf)[0..16].*;
        feats[33] = @max(hdr, sdr) * @as(f32x16, @splat(1.0 / 3.0));
        const proj_self: f32x16 = @field(state, "projectile_count" ++ self_suf)[0..16].*;
        const proj_enemy: f32x16 = @field(state, "projectile_count" ++ enemy_suf)[0..16].*;
        feats[34] = (proj_self - proj_enemy) * @as(f32x16, @splat(0.25));
        const pet_hp: f32x16 = @field(state, "pet_hp" ++ self_suf)[0..16].*;
        feats[35] = select16(pet_hp > v_zero, @min(v_one, pet_hp * @as(f32x16, @splat(1.0 / 1000.0))), v_zero);
        if ((if (side_a) a else b) == .warrior) {
            // Warrior uses class-specific slots; caster feature semantics stay unchanged.
            const columns = .{ .off_swing, .rend, .execute_cd, .pummel_cd, .berserker_rage_cd, .bloodrage_cd, .bloodrage_timer };
            inline for (columns, 0..) |column, j| {
                feats[24 + j] = duel.arena.warrior.floats(side_a, column, 0).* / @as(f32x16, @splat(30));
            }
            const cfg = duel.arena.warrior.configs[@TypeOf(duel.arena.warrior).slot(side_a)];
            const fury_columns = .{ .bloodthirst_cd, .whirlwind_cd, .death_wish_cd, .death_wish, .bloodthirst_speed };
            const scales = .{ 6.0, 10.0, 180.0, 30.0, 10.0 };
            inline for (fury_columns, scales, 0..) |column, scale, j| {
                feats[36 + j] = duel.arena.warrior.floats(side_a, column, 0).* / @as(f32x16, @splat(scale));
            }
            feats[41] = duel.arena.warrior.floats(side_a, .enrage, 0).* / @as(f32x16, @splat(12));
            feats[42] = duel.arena.warrior.floats(side_a, .flurry_stacks, 0).* / @as(f32x16, @splat(3));
            feats[43] = duel.arena.warrior.floats(side_a, .flurry_icd, 0).* / @as(f32x16, @splat(0.5));
            feats[31] = @splat(cfg.main_hand.speed / 10);
            feats[32] = @splat(cfg.attack_power / 10000);
            feats[35] = @splat(if (cfg.off_hand != null) 1 else 0);
        }
    }

    /// Residual guidance for a useful starting policy. All preferences are finite:
    /// learned logits can override them without changing simulator legality.
    fn tacticalPrior(
        comptime a: Spec,
        comptime b: Spec,
        duel: *const sim.Duel(a, b),
        comptime side_a: bool,
        lane: usize,
        ability: usize,
    ) f32 {
        const actor = if (side_a) a else b;
        const opp = if (side_a) b else a;
        const s: *const combat.WarlockArenaPool = if (a == .warlock and b == .warlock) &duel.arena else &duel.arena.state;
        const own = if (side_a) "_a" else "_b";
        const enemy = if (side_a) "_b" else "_a";

        const hp = @field(s, "hp" ++ own)[lane];
        const max_hp = @max(1.0, @field(s, "max_health" ++ own)[lane]);
        const hp_pct = hp / max_hp;
        const enemy_hp = @field(s, "hp" ++ enemy)[lane];
        const enemy_max_hp = @max(1.0, @field(s, "max_health" ++ enemy)[lane]);
        const enemy_hp_pct = enemy_hp / enemy_max_hp;
        const enemy_casting = @field(s, "cast_id" ++ enemy)[lane] != 0;
        const dist = s.distance[lane];

        if (actor == .warrior) {
            const warrior = &duel.arena.warrior;
            const rage = warrior.floats(side_a, .rage, 0).*[lane];
            const stance = warrior.floats(side_a, .stance, 0).*[lane];
            const cfg = warrior.configs[@TypeOf(duel.arena.warrior).slot(side_a)];
            const fury = cfg.build.ranks[@intFromEnum(@import("warrior_talents.zig").Talent.bloodthirst)] > 0;
            return switch (ability) {
                0 => if (dist <= 5 and @field(s, "gcd" ++ own)[lane] <= 0 and rage >= 10) -1.0 else 0.0,
                1 => if (dist > 5 or rage < 45) -2.0 else 0.7, // Save rage for specials.
                2 => if (warrior.floats(side_a, .hamstring, 0).*[lane] > 2.5) -2.0 else 2.6,
                3, 4 => 3.0, // Charge / Intercept, when legal.
                5 => 2.5, // Mortal Strike.
                6 => if (warrior.floats(side_a, .rend, 0).*[lane] > 2.5) -2.0 else 1.0,
                7 => 2.5, // Overpower.
                8 => 3.0, // Execute.
                9 => if (enemy_casting) @as(f32, 3.0) else -2.5,
                10 => -2.0, // Cancel queued strike remains available.
                11 => if (@field(s, "fear_timer" ++ own)[lane] > 0 or @field(s, "seduction_timer" ++ own)[lane] > 0 or @field(s, "horror_timer" ++ own)[lane] > 0) @as(f32, 3.0) else 0.3,
                12 => if (rage < 50) @as(f32, 1.8) else -1.0, // Bloodrage.
                13 => if (dist >= 8 and dist <= 25 and warrior.floats(side_a, .charge_cd, 0).*[lane] <= 0) @as(f32, 1.6) else if (!fury and stance != 1) @as(f32, 0.5) else -1.8,
                14 => -1.8, // Defensive Stance is an optional learned choice.
                15 => if (fury or (dist >= 8 and dist <= 25 and warrior.floats(side_a, .intercept_cd, 0).*[lane] <= 0 and rage >= 10)) @as(f32, 1.4) else -1.8,
                16 => 2.6, // Bloodthirst.
                17, 18 => 1.8,
                19, 20 => if (@field(s, "fear_timer" ++ own)[lane] > 0 or @field(s, "seduction_timer" ++ own)[lane] > 0) @as(f32, 3.0) else -2.5,
                23 => 2.2, // Whirlwind.
                24 => if (dist <= 8) @as(f32, 2.4) else 0.2, // Death Wish.
                else => 0.0,
            };
        }

        // Check if enemy has an off-GCD interrupt ready to juke
        const enemy_can_interrupt = switch (opp) {
            .warrior => dist <= 5 and duel.arena.warrior.floats(!side_a, .pummel_cd, 0).*[lane] <= 0 and duel.arena.warrior.floats(!side_a, .rage, 0).*[lane] >= 10 and duel.arena.warrior.floats(!side_a, .stance, 0).*[lane] == 4,
            .frost_mage => @field(s, "death_coil_cd" ++ enemy)[lane] <= 0.0 and dist <= 30.0,
            .priest => @field(s, "seduction_cd" ++ enemy)[lane] <= 0.0 and dist <= 30.0,
            .warlock => @field(s, "pet_kind" ++ enemy)[lane] == @intFromEnum(@import("pets.zig").Kind.felhunter) and
                @field(s, "pet_hp" ++ enemy)[lane] > 0.0 and
                @field(s, "seduction_cd" ++ enemy)[lane] <= 0.0 and dist <= 30.0,
        };

        if (ability == 10) {
            // CancelCast: prefer juking when enemy has an interrupt available
            // and our cast is partially underway (so we bait the interrupt).
            if (!enemy_can_interrupt) return -2.5;
            const c_tmr = @field(s, "cast_timer" ++ own)[lane];
            const c_tot = @max(0.01, @field(s, "cast_total" ++ own)[lane]);
            const elapsed_frac = (c_tot - c_tmr) / c_tot;
            if (elapsed_frac < 0.25 or elapsed_frac > 0.85) return -2.5;
            return -1.2; // Juke is possible when neural network boosts it
        }

        if (ability == 0) {
            // Idle/Maneuver: penalize when GCD is ready so fighters cast instead of idling
            return if (@field(s, "gcd" ++ own)[lane] <= 0.0 and @field(s, "cast_id" ++ own)[lane] == 0) -1.8 else 0.0;
        }

        // Racial 19: Escape Artist
        if (ability == 19) {
            const rooted_or_slowed = (opp == .frost_mage) and (@field(s, "agony_timer" ++ own)[lane] > 0.5 or @field(s, "corruption_timer" ++ own)[lane] > 0.5);
            return if (rooted_or_slowed) 2.5 else -2.5;
        }
        // Racial 20: Will of the Forsaken
        if (ability == 20) {
            const feared_or_seduced = @field(s, "fear_timer" ++ own)[lane] > 0.5 or @field(s, "seduction_timer" ++ own)[lane] > 0.5;
            return if (feared_or_seduced) 3.0 else -2.5;
        }
        // Racials 17 (Blood Fury), 18 (Berserking)
        if (ability == 17 or ability == 18) {
            return 1.8;
        }

        if (actor == .warlock) {
            return switch (ability) {
                1 => if (@field(s, "agony_timer" ++ enemy)[lane] > 2.5) -2.5 else 1.7,
                2 => if (@field(s, "corruption_timer" ++ enemy)[lane] > 2.5) -2.5 else 1.9,
                8 => if (@field(s, "siphon_timer" ++ enemy)[lane] > 3.0) -2.5 else 2.0,
                13 => if (@field(s, "immolate_timer" ++ enemy)[lane] > 2.5) -2.5 else 1.7,
                7 => if (hp_pct < 0.45) @as(f32, 2.8) else if (hp_pct < 0.80 or enemy_casting) @as(f32, 2.0) else @as(f32, 0.8),
                6 => if (hp_pct < 0.50) @as(f32, 2.6) else if (hp_pct < 0.75) @as(f32, 0.8) else -2.5,
                9 => if (enemy_hp_pct < 0.30) @as(f32, 2.8) else @as(f32, 1.2),
                16 => 2.2, // Conflagrate
                15 => if (enemy_casting) @as(f32, 3.0) else -2.5, // Spell Lock
                14 => if (@field(s, "seduction_timer" ++ enemy)[lane] <= 0.0 and @field(s, "seduction_dr_tier" ++ enemy)[lane] < 3.0) @as(f32, 1.6) else -2.5,
                3 => if (@field(s, "fear_timer" ++ enemy)[lane] <= 0.5 and @field(s, "fear_dr_tier" ++ enemy)[lane] < 3.0) @as(f32, 1.1) else -2.0,
                5 => if (hp_pct < 0.75) @as(f32, 1.2) else @as(f32, 0.3), // Drain Life
                4, 11, 12 => 1.0, // Shadow Bolt / Searing Pain / Incinerate
                else => 0.0,
            };
        } else if (actor == .priest) {
            return switch (ability) {
                1 => if (@field(s, "agony_timer" ++ enemy)[lane] > 2.5) -2.5 else 1.8, // SW:P
                2 => if (@field(s, "corruption_timer" ++ enemy)[lane] > 2.5) -2.5 else 2.1, // Devouring Plague
                8 => if (@field(s, "siphon_timer" ++ enemy)[lane] > 3.0) -2.5 else 1.6, // Vampiric Embrace
                13 => if (@field(s, "immolate_timer" ++ enemy)[lane] > 2.0) -2.5 else 1.5, // Holy Fire
                6 => if (@field(s, "action6_dur" ++ own)[lane] <= 0.0 and hp_pct < 0.92) @as(f32, 2.2) else -2.5, // PW:S
                7 => if (enemy_casting) @as(f32, 3.0) else @as(f32, 0.8), // Silence
                3 => if (dist <= 8.0 and @field(s, "fear_timer" ++ enemy)[lane] <= 0.0 and @field(s, "fear_dr_tier" ++ enemy)[lane] < 3.0) @as(f32, 2.4) else -2.5, // Psychic Scream
                9 => if (enemy_hp_pct < 0.30) @as(f32, 2.8) else if (hp_pct > 0.50) @as(f32, 1.5) else -0.5, // SW:D
                4 => 1.5, // Mind Blast
                5 => 1.0, // Mind Flay
                11 => if (hp_pct < 0.55) @as(f32, 2.2) else if (hp_pct < 0.80) @as(f32, 0.5) else -2.5, // Flash Heal
                12 => if (@field(s, "shadow_lockout" ++ own)[lane] < 1.5 and hp_pct < 0.85) @as(f32, 1.6) else -2.5, // Renew
                14 => 0.8, // Smite
                15 => 2.0, // Penance
                16 => 2.2, // Inner Focus
                21 => 2.6, // Power Infusion
                22 => 2.2, // Dispel Self
                23 => 1.9, // Dispel Enemy
                24 => if (hp_pct >= 0.55 and @field(s, "mana" ++ enemy)[lane] >= 350.0) @as(f32, 1.3) else -1.0, // Mana Burn
                else => 0.0,
            };
        } else {
            // Frost Mage
            const enemy_frozen = @field(s, "agony_timer" ++ enemy)[lane] > 0.0;
            return switch (ability) {
                7 => if (enemy_casting) @as(f32, 3.0) else -2.5, // Counterspell
                6 => if (hp_pct < 0.90) @as(f32, 2.2) else @as(f32, 1.0), // Ice Barrier
                5 => if (dist < 10.0 or hp_pct < 0.50 or @field(s, "stun_timer" ++ own)[lane] > 0.0) @as(f32, 2.0) else -1.0, // Blink
                2 => if (dist <= 10.0 and !enemy_frozen) @as(f32, 2.2) else -2.5, // Frost Nova
                1 => if (enemy_frozen) @as(f32, 2.4) else @as(f32, 0.9), // Ice Lance
                3 => if (@field(s, "fear_timer" ++ enemy)[lane] <= 0.5 and @field(s, "fear_dr_tier" ++ enemy)[lane] < 2.0 and hp_pct < enemy_hp_pct) @as(f32, 1.2) else -1.2, // Polymorph
                4 => 1.4, // Frostbolt
                else => 0.0,
            };
        }
    }

    /// Selects legal actions for all 16 lanes in `duel` for `side_a`.
    /// Combines learned logits with finite tactical guidance and exploration noise.
    /// Only the simulator masks exclude abilities; evolution can override preferences.
    pub fn selectActions16(
        self: *const Policy,
        comptime a: Spec,
        comptime b: Spec,
        duel: *sim.Duel(a, b),
        comptime side_a: bool,
        ready_mask: bool16,
        legal_masks: [combat.WarlockAction.COUNT]bool16,
        temperature: f32,
        rng: std.Random,
    ) [16]sim.Action {
        var feats: [NumFeatures]f32x16 = undefined;
        extractFeatures(a, b, duel, side_a, &feats);
        var logits: [NumOutputs]f32x16 = undefined;
        self.forward16(&feats, &logits);

        const state: *const combat.WarlockArenaPool = if (a == .warlock and b == .warlock) &duel.arena else &duel.arena.state;
        const suffix = if (side_a) "_a" else "_b";
        const actor = if (side_a) a else b;
        const starts_cast_table = switch (actor) {
            .warlock => action_catalog.warlock_starts_cast,
            .frost_mage => action_catalog.frost_mage_starts_cast,
            .priest => action_catalog.priest_starts_cast,
            .warrior => action_catalog.warrior_starts_cast,
        };

        var result: [16]sim.Action = @splat(.{});
        for (0..16) |lane| {
            if (!ready_mask[lane]) continue;

            const controlled = @field(state, "fear_timer" ++ suffix)[lane] > 0 or
                @field(state, "horror_timer" ++ suffix)[lane] > 0 or
                @field(state, "seduction_timer" ++ suffix)[lane] > 0 or
                @field(state, "stun_timer" ++ suffix)[lane] > 0;
            const cast_id = @field(state, "cast_id" ++ suffix)[lane];
            const dist = state.distance[lane];
            // Soft positioning guidance; all movement options remain available.
            var s_m0 = logits[NumAbilities + 0][lane] + (if (actor == .warrior) (if (dist > 3) @as(f32, 0.8) else 0) else (if (dist > 26) @as(f32, 0.35) else 0));
            var s_m1 = logits[NumAbilities + 1][lane] + (if (actor == .warrior and dist <= 3) @as(f32, 0.35) else 0);
            var s_m2 = logits[NumAbilities + 2][lane] + (if (actor != .warrior and dist < 15) @as(f32, 0.35) else 0);
            if (temperature > 0.0) {
                s_m0 += (rng.float(f32) - 0.5) * temperature;
                s_m1 += (rng.float(f32) - 0.5) * temperature;
                s_m2 += (rng.float(f32) - 0.5) * temperature;
            }
            var best_move: f32 = 0.0;
            var best_move_score: f32 = s_m1;
            if (s_m0 > best_move_score) {
                best_move_score = s_m0;
                best_move = -1.0;
            }
            if (s_m2 > best_move_score) {
                best_move_score = s_m2;
                best_move = 1.0;
            }

            var best_score: f32 = -std.math.inf(f32);
            var best_act: sim.Action = .{ .ability = 0, .movement = if (controlled or cast_id != 0) 0.0 else best_move };

            if (controlled) {
                best_score = logits[0][lane] + s_m1;
                if (temperature > 0.0) best_score += (rng.float(f32) - 0.5) * temperature;
                best_act = .{ .ability = 0, .movement = 0.0 };
            }

            for (0..NumAbilities) |id| {
                if (!legal_masks[id][lane]) continue;
                const casting = cast_id != 0 and id != 10 and !(actor == .frost_mage and id == 5);
                const stationary = controlled or casting or starts_cast_table[id];
                var ab_score = logits[id][lane] + tacticalPrior(a, b, duel, side_a, lane, id);
                if (temperature > 0.0) ab_score += (rng.float(f32) - 0.5) * temperature;

                const total_score = ab_score + (if (stationary) s_m1 else best_move_score);
                if (total_score > best_score) {
                    best_score = total_score;
                    best_act = .{
                        .ability = @intCast(id),
                        .movement = if (stationary) 0.0 else best_move,
                    };
                }
            }
            result[lane] = best_act;
        }
        return result;
    }

    /// Selects a single legal action for lane 0 (used in mcts_main replay generation).
    pub fn selectActionSingle(
        self: *const Policy,
        comptime a: Spec,
        comptime b: Spec,
        duel: *sim.Duel(a, b),
        comptime side_a: bool,
    ) sim.Action {
        const masks = if (side_a) duel.getActionMaskA(0) else duel.getActionMaskB(0);
        var dummy_prng = std.Random.DefaultPrng.init(0);
        const actions = self.selectActions16(a, b, duel, side_a, @splat(true), masks, 0.0, dummy_prng.random());
        return actions[0];
    }
};

test "neuro_policy forward pass and action selection" {
    var prng = std.Random.DefaultPrng.init(42);
    const policy = Policy.initRandom(prng.random(), 0.5);
    var duel = try sim.Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer duel.deinit();
    duel.staggerOpening();

    const act_a = policy.selectActionSingle(.warlock, .frost_mage, &duel, true);
    try std.testing.expect(act_a.ability < NumAbilities);
    const masks = duel.getActionMaskA(0);
    try std.testing.expect(masks[act_a.ability][0]);
    try std.testing.expect(act_a.movement == -1.0 or act_a.movement == 0.0 or act_a.movement == 1.0);
}

test "26 action policies retain ability and movement rows when adding the item action" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ path, "old.nepl" });
    defer std.testing.allocator.free(file_path);
    const old_outputs = 29;
    const old_count = NumHidden * NumFeatures + NumHidden + old_outputs * NumHidden + old_outputs;
    var old: [old_count]f32 = undefined;
    for (&old, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    const file = try tmp.dir.createFile("old.nepl", .{});
    try file.writeAll(&Magic);
    try file.writer().writeInt(u32, Version, .little);
    try file.writer().writeInt(u32, old_count, .little);
    try file.writeAll(std.mem.sliceAsBytes(&old));
    file.close();
    const policy = try Policy.loadFile(file_path);
    const w2 = NumHidden * NumFeatures + NumHidden;
    const old_b2 = w2 + old_outputs * NumHidden;
    const new_b2 = w2 + NumOutputs * NumHidden;
    try std.testing.expectEqualSlices(f32, old[0..w2], policy.params[0..w2]);
    for (0..old_outputs) |row| {
        const target = if (row >= 26) row + 1 else row;
        try std.testing.expectEqualSlices(f32, old[w2 + row * NumHidden ..][0..NumHidden], policy.params[w2 + target * NumHidden ..][0..NumHidden]);
        try std.testing.expectEqual(old[old_b2 + row], policy.params[new_b2 + target]);
    }
    for (policy.params[w2 + 26 * NumHidden ..][0..NumHidden]) |value| try std.testing.expectEqual(@as(f32, 0), value);
    try std.testing.expectEqual(@as(f32, 0), policy.params[new_b2 + 26]);
}
