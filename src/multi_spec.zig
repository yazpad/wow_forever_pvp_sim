const std = @import("std");
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const Spec = @import("spec.zig").Spec;
const Frost = @import("spec.zig").Frost;
const WarlockConstants = combat_spec.WarlockConstants;
const warlock_talents = @import("warlock_talents.zig");
const f32x16 = simd.f32x16;
const u32x16 = simd.u32x16;
const bool16 = simd.bool16;
const select16 = simd.select16;
const vAnd16 = simd.vAnd16;
const vOr16 = simd.vOr16;
const vNot16 = simd.vNot16;
const VEC_LEN = simd.SimdConfig.VecLen16;
const getDrMultiplier = combat_spec.getDrMultiplier;

fn splat(value: f32) f32x16 {
    return @splat(value);
}
fn ids(value: u32) u32x16 {
    return @splat(value);
}

/// Pairing is resolved at compile time. Warlock mirrors use the original type,
/// allocation layout, and combat kernel, without any Mage state or processing.
pub fn ArenaPool(comptime spec_a: Spec, comptime spec_b: Spec) type {
    if (spec_a == .warlock and spec_b == .warlock) return combat_spec.WarlockArenaPool;
    return struct {
        const Self = @This();
        pub const SpecA = spec_a;
        pub const SpecB = spec_b;
        state: combat_spec.WarlockArenaPool,
        // Five aligned columns per side. Shared status slots in state represent
        // root/slow when their source is Mage; their meaning never varies by lane.
        extras: []align(64) f32,
        const Extra = enum(usize) { blink, nova, shield, lockout, root_damage };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            var state = try combat_spec.WarlockArenaPool.init(allocator, capacity);
            errdefer state.deinit();
            const extras = try allocator.alignedAlloc(f32, 64, state.capacity * 10);
            @memset(extras, 0);
            return .{ .state = state, .extras = extras };
        }
        pub fn deinit(self: *Self) void {
            self.state.allocator.free(self.extras);
            self.state.deinit();
        }
        pub fn combat(self: *Self) *combat_spec.WarlockArenaPool {
            return &self.state;
        }
        pub fn resetDuel(self: *Self, i: usize) void {
            self.state.resetDuel(i);
            inline for (0..10) |col| self.extras[col * self.state.capacity + i] = 0;
        }
        fn extra(self: *const Self, comptime kind: Extra, comptime side_a: bool, i: usize) *align(64) f32x16 {
            const col = @intFromEnum(kind) + (if (side_a) @as(usize, 0) else 5);
            return @ptrCast(@alignCast(self.extras[col * self.state.capacity + i ..][0..VEC_LEN]));
        }
        fn column(self: *const Self, comptime name: []const u8, comptime side_a: bool, i: usize) *align(64) f32x16 {
            return @ptrCast(@alignCast(@field(self.state, name ++ (if (side_a) "_a" else "_b"))[i..][0..VEC_LEN]));
        }
        fn castIds(self: *const Self, comptime side_a: bool, i: usize) *align(64) u32x16 {
            return @ptrCast(@alignCast(@field(self.state, "cast_id" ++ (if (side_a) "_a" else "_b"))[i..][0..VEC_LEN]));
        }
        pub fn frostTelemetry(self: *const Self, comptime side_a: bool, i: usize) [5]f32 {
            // Telemetry accepts an individual lane, unlike the aligned SIMD
            // kernels. MCTS evaluates leaves in lanes 0 through 15.
            var result: [5]f32 = undefined;
            inline for (0..5) |j| result[j] = self.extras[((if (side_a) @as(usize, 0) else 5) + j) * self.state.capacity + i];
            return result;
        }
        pub fn needsDecisionA(self: *const Self, i: usize) bool16 {
            return self.state.needsDecisionA(i);
        }
        pub fn needsTacticalDecisionA(self: *const Self, i: usize) bool16 {
            return self.state.needsTacticalDecisionA(i);
        }
        pub fn needsDecisionB(self: *const Self, i: usize) bool16 {
            return self.state.needsDecisionB(i);
        }
        pub fn needsTacticalDecisionB(self: *const Self, i: usize) bool16 {
            return self.state.needsTacticalDecisionB(i);
        }
        pub fn getObservationsA(self: *const Self, i: usize) [24]f32x16 {
            return self.observations(true, i);
        }
        pub fn getObservationsB(self: *const Self, i: usize) [24]f32x16 {
            return self.observations(false, i);
        }
        fn observations(self: *const Self, comptime side_a: bool, i: usize) [24]f32x16 {
            const actor = if (side_a) spec_a else spec_b;
            var obs = if (side_a) self.state.getObservationsA(i) else self.state.getObservationsB(i);
            if (actor == .frost_mage) {
                const opponent = if (side_a) spec_b else spec_a;
                obs[9] = if (opponent == .frost_mage) self.column("corruption_timer", side_a, i).* * splat(1 / Frost.SlowDuration) else splat(0);
                obs[13] = if (opponent == .frost_mage) self.column("agony_timer", side_a, i).* * splat(1 / Frost.NovaDuration) else splat(0);
                obs[19] = self.column("fear_dr_tier", !side_a, i).* * splat(1.0 / 3.0);
                obs[11] = self.column("agony_timer", !side_a, i).* * splat(1 / Frost.NovaDuration);
                obs[12] = self.column("corruption_timer", !side_a, i).* * splat(1 / Frost.SlowDuration);
                obs[14] = self.extra(.lockout, side_a, i).* * splat(1 / Frost.LockoutDuration);
                obs[15] = self.column("action6_cd", side_a, i).* * splat(1 / Frost.BarrierCooldown);
                obs[16] = self.extra(.shield, side_a, i).* * splat(1 / Frost.BarrierAbsorb);
                obs[18] = self.extra(.blink, side_a, i).* * splat(1 / Frost.BlinkCooldown);
                obs[20] = self.column("death_coil_cd", side_a, i).* * splat(1 / Frost.CounterspellCooldown);
                obs[23] = self.extra(.nova, side_a, i).* * splat(1 / Frost.NovaCooldown);
            } else {
                // Warlock kit features retain their old positions. Lockout is
                // visible in the otherwise redundant self-fear feature.
                obs[14] = self.extra(.lockout, side_a, i).* * splat(1 / Frost.LockoutDuration);
            }
            return obs;
        }
        pub fn getActionMaskA(self: *const Self, i: usize) [combat_spec.WarlockAction.COUNT]bool16 {
            return self.masks(true, i);
        }
        pub fn getActionMaskB(self: *const Self, i: usize) [combat_spec.WarlockAction.COUNT]bool16 {
            return self.masks(false, i);
        }
        fn masks(self: *const Self, comptime side_a: bool, i: usize) [combat_spec.WarlockAction.COUNT]bool16 {
            const actor = if (side_a) spec_a else spec_b;
            const alive = vAnd16(self.state.is_active[i..][0..VEC_LEN].* != ids(0), vAnd16(self.column("hp", side_a, i).* > splat(0), self.column("hp", !side_a, i).* > splat(0)));
            const unlocked = self.extra(.lockout, side_a, i).* <= splat(0);
            if (actor == .warlock) {
                var result = if (side_a) self.state.getActionMaskA(i) else self.state.getActionMaskB(i);
                inline for (1..combat_spec.WarlockAction.COUNT) |slot| result[slot] = vAnd16(result[slot], alive);
                inline for (1..combat_spec.WarlockAction.COUNT) |action| {
                    if (action != 6 and action != 10 and action != 15) result[action] = vAnd16(result[action], unlocked);
                }
                return result;
            }
            const mana = self.column("mana", side_a, i).*;
            const free_gcd = self.column("gcd", side_a, i).* <= splat(0);
            const casting = self.castIds(side_a, i).* != ids(0);
            const seduction = if (side_a) self.state.seduction_timer_a[i..][0..VEC_LEN].* else self.state.seduction_timer_b[i..][0..VEC_LEN].*;
            const cc = vOr16(vNot16(alive), vOr16(vOr16(self.column("fear_timer", side_a, i).* > splat(0), self.column("horror_timer", side_a, i).* > splat(0)), seduction > splat(0)));
            const free = vAnd16(vNot16(cc), vNot16(casting));
            const spell = vAnd16(free, vAnd16(free_gcd, unlocked));
            const distance: f32x16 = self.state.distance[i..][0..VEC_LEN].*;
            const room = @import("projectiles.zig").available(&self.state, side_a, i);
            var result: [combat_spec.WarlockAction.COUNT]bool16 = @splat(@as(bool16, @splat(false)));
            result[0] = @splat(true); // Always allow idle, including under CC.
            result[1] = vAnd16(room, vAnd16(spell, mana >= splat(Frost.LanceMana)));
            result[2] = vAnd16(spell, vAnd16(mana >= splat(Frost.NovaMana), vAnd16(distance <= splat(Frost.NovaRange), self.extra(.nova, side_a, i).* <= splat(0))));
            result[3] = vAnd16(spell, vAnd16(mana >= splat(Frost.PolymorphMana), distance <= splat(Frost.PolymorphRange)));
            result[4] = vAnd16(room, vAnd16(spell, mana >= splat(Frost.BoltMana)));
            result[5] = vAnd16(vNot16(cc), vAnd16(mana >= splat(Frost.BlinkMana), self.extra(.blink, side_a, i).* <= splat(0)));
            result[6] = vAnd16(vNot16(cc), vAnd16(unlocked, vAnd16(mana >= splat(Frost.BarrierMana), self.column("action6_cd", side_a, i).* <= splat(0))));
            result[7] = vAnd16(vNot16(cc), vAnd16(distance <= splat(Frost.CounterspellRange), self.column("death_coil_cd", side_a, i).* <= splat(0)));
            result[8] = @splat(false);
            result[9] = @splat(false);
            result[10] = vAnd16(casting, alive);
            return result;
        }
        pub fn applyActionA(self: *Self, i: usize, actions: u32x16, movement: f32x16) void {
            self.apply(true, i, actions, movement, false);
        }
        pub fn applyActionB(self: *Self, i: usize, actions: u32x16, movement: f32x16) void {
            self.apply(false, i, actions, movement, false);
        }

        pub fn stageActionA(self: *Self, i: usize, actions: u32x16, movement: f32x16) void {
            self.apply(true, i, actions, movement, true);
        }
        pub fn stageActionB(self: *Self, i: usize, actions: u32x16, movement: f32x16) void {
            self.apply(false, i, actions, movement, true);
        }
        fn damage(self: *Self, comptime target_a: bool, i: usize, amount: f32x16, comptime staged: bool) void {
            const target = if (target_a) spec_a else spec_b;
            var dmg = amount;
            if (target == .frost_mage) {
                const shield = self.extra(.shield, target_a, i);
                const absorbed = @min(shield.*, dmg);
                shield.* = shield.* - absorbed;
                dmg -= absorbed;
                const dur = self.column("action6_dur", target_a, i);
                dur.* = select16(shield.* <= splat(0), splat(0), dur.*);
            }
            const hp = self.column("hp", target_a, i);
            hp.* = if (staged) hp.* - dmg else @max(splat(0), hp.* - dmg);
            const source = if (target_a) spec_b else spec_a;
            const fear = self.column("fear_timer", target_a, i);
            const accum = self.column("fear_accum_dmg", target_a, i);
            accum.* += dmg;
            fear.* = select16(accum.* >= splat(if (source == .frost_mage) 0.001 else WarlockConstants.FearBreakDmgThreshold), splat(0), fear.*);
            if (source == .frost_mage) {
                const root = self.column("agony_timer", target_a, i);
                const root_dmg = self.extra(.root_damage, target_a, i);
                root_dmg.* += dmg;
                root.* = select16(root_dmg.* >= splat(250), splat(0), root.*);
            }
        }
        fn apply(self: *Self, comptime side_a: bool, i: usize, requested: u32x16, movement: f32x16, comptime staged: bool) void {
            const actor = if (side_a) spec_a else spec_b;
            if (actor == .warlock) {
                const legal = self.masks(side_a, i);
                var actions = ids(0);
                const active = self.state.is_active[i..][0..VEC_LEN].* != ids(0);
                inline for (1..combat_spec.WarlockAction.COUNT) |action| actions = @select(u32, vAnd16(active, vAnd16(requested == ids(action), legal[action])), ids(action), actions);
                const spell_lock = actions == ids(15);
                const target_cast = self.castIds(!side_a, i);
                const interrupted = vAnd16(spell_lock, target_cast.* != ids(0));
                if (staged) {
                    if (side_a) self.state.stageActionA(i, actions, movement) else self.state.stageActionB(i, actions, movement);
                } else {
                    if (side_a) self.state.applyActionA(i, actions, movement) else self.state.applyActionB(i, actions, movement);
                }
                if (side_a) {
                    self.state.seduction_cd_a[i..][0..VEC_LEN].* = select16(spell_lock, splat(WarlockConstants.SpellLockCooldown), self.state.seduction_cd_a[i..][0..VEC_LEN].*);
                } else {
                    self.state.seduction_cd_b[i..][0..VEC_LEN].* = select16(spell_lock, splat(WarlockConstants.SpellLockCooldown), self.state.seduction_cd_b[i..][0..VEC_LEN].*);
                }
                target_cast.* = @select(u32, interrupted, ids(0), target_cast.*);
                self.column("cast_timer", !side_a, i).* = select16(interrupted, splat(0), self.column("cast_timer", !side_a, i).*);
                self.column("cast_total", !side_a, i).* = select16(interrupted, splat(0), self.column("cast_total", !side_a, i).*);
                const lockout = self.extra(.lockout, !side_a, i);
                lockout.* = select16(interrupted, splat(Frost.LockoutDuration), lockout.*);
                self.column("react_timer", !side_a, i).* = select16(interrupted, splat(0), self.column("react_timer", !side_a, i).*);
                return;
            }
            const legal = self.masks(side_a, i);
            const active = self.state.is_active[i..][0..VEC_LEN].* != ids(0);
            var actions = ids(0);
            inline for (1..11) |action| actions = @select(u32, vAnd16(active, vAnd16(requested == ids(action), legal[action])), ids(action), actions);
            const cc = vOr16(vOr16(self.column("fear_timer", side_a, i).* > splat(0), self.column("horror_timer", side_a, i).* > splat(0)), (if (side_a) self.state.seduction_timer_a[i..][0..VEC_LEN].* else self.state.seduction_timer_b[i..][0..VEC_LEN].*) > splat(0));
            const cast = self.castIds(side_a, i);
            const cancel = vOr16(actions == ids(10), actions == ids(5));
            cast.* = @select(u32, cancel, ids(0), cast.*);
            const timer = self.column("cast_timer", side_a, i);
            const total = self.column("cast_total", side_a, i);
            timer.* = select16(cancel, splat(0), timer.*);
            total.* = select16(cancel, splat(0), total.*);
            self.column("move_intent", side_a, i).* = select16(vOr16(cc, cast.* != ids(0)), splat(0), movement);
            self.column("react_timer", side_a, i).* = splat(WarlockConstants.ReactionInterval);
            const mana = self.column("mana", side_a, i);
            const gcd = self.column("gcd", side_a, i);
            inline for (.{ 1, 2, 3, 4, 5, 6 }) |action| {
                const costs = [_]f32{ 0, Frost.LanceMana, Frost.NovaMana, Frost.PolymorphMana, Frost.BoltMana, Frost.BlinkMana, Frost.BarrierMana };
                const used = actions == ids(action);
                mana.* -= select16(used, splat(costs[action]), splat(0));
                if (action <= 4) gcd.* = select16(used, splat(1), gcd.*);
            }
            const lance = actions == ids(1);
            const frozen = self.column("agony_timer", !side_a, i).* > splat(0);
            @import("projectiles.zig").launch(&self.state, side_a, i, 1, select16(frozen, splat(Frost.FrozenLanceDamage), splat(Frost.LanceDamage)), lance);
            const nova = actions == ids(2);
            const dr = self.column("horror_dr_tier", !side_a, i);
            const root = self.column("agony_timer", !side_a, i);
            const duration = splat(Frost.NovaDuration) * getDrMultiplier(dr.*);
            root.* = select16(vAnd16(nova, duration > splat(0)), duration, root.*);
            dr.* = select16(nova, @min(splat(3), dr.* + splat(1)), dr.*);
            const dr_timer = self.column("horror_dr_timer", !side_a, i);
            dr_timer.* = select16(nova, splat(18), dr_timer.*);
            const root_dmg = self.extra(.root_damage, !side_a, i);
            root_dmg.* = select16(nova, splat(0), root_dmg.*);
            const nova_cd = self.extra(.nova, side_a, i);
            nova_cd.* = select16(nova, splat(Frost.NovaCooldown), nova_cd.*);
            inline for (.{ 3, 4 }) |action| {
                const used = actions == ids(action);
                const duration_cast = if (action == 3) Frost.PolymorphCast else Frost.BoltCast;
                cast.* = @select(u32, used, ids(action), cast.*);
                timer.* = select16(used, splat(duration_cast), timer.*);
                total.* = select16(used, splat(duration_cast), total.*);
                const move = self.column("move_intent", side_a, i);
                move.* = select16(used, splat(0), move.*);
            }
            const blink = actions == ids(5);
            @import("movement_2d.zig").blink(&self.state, side_a, i, select16(movement < splat(0), splat(-Frost.BlinkDistance), splat(Frost.BlinkDistance)), blink, staged);
            const blink_cd = self.extra(.blink, side_a, i);
            blink_cd.* = select16(blink, splat(Frost.BlinkCooldown), blink_cd.*);
            // Blink removes roots inflicted by a Mage, without clearing Warlock DOTs.
            if ((if (side_a) spec_b else spec_a) == .frost_mage) {
                const self_root = self.column("agony_timer", side_a, i);
                self_root.* = select16(blink, splat(0), self_root.*);
            }
            const barrier = actions == ids(6);
            const shield = self.extra(.shield, side_a, i);
            shield.* = select16(barrier, splat(Frost.BarrierAbsorb), shield.*);
            const barrier_dur = self.column("action6_dur", side_a, i);
            barrier_dur.* = select16(barrier, splat(Frost.BarrierDuration), barrier_dur.*);
            const barrier_cd = self.column("action6_cd", side_a, i);
            barrier_cd.* = select16(barrier, splat(Frost.BarrierCooldown), barrier_cd.*);
            const cs = actions == ids(7);
            const cs_cd = self.column("death_coil_cd", side_a, i);
            cs_cd.* = select16(cs, splat(Frost.CounterspellCooldown), cs_cd.*);
            const target_cast = self.castIds(!side_a, i);
            const interrupted = vAnd16(cs, target_cast.* != ids(0));
            target_cast.* = @select(u32, interrupted, ids(0), target_cast.*);
            const target_timer = self.column("cast_timer", !side_a, i);
            target_timer.* = select16(interrupted, splat(0), target_timer.*);
            const target_total = self.column("cast_total", !side_a, i);
            target_total.* = select16(interrupted, splat(0), target_total.*);
            const lockout = self.extra(.lockout, !side_a, i);
            lockout.* = select16(interrupted, splat(Frost.LockoutDuration), lockout.*);
            const target_react = self.column("react_timer", !side_a, i);
            target_react.* = select16(interrupted, splat(0), target_react.*);
        }

        pub fn tickPhysics(self: *Self, dt: f32) usize {
            return self.tickPhysicsRange(dt, 0, self.state.capacity);
        }
        pub fn tickPhysics16(self: *Self, dt: f32, i: usize) usize {
            std.debug.assert(i % VEC_LEN == 0 and i + VEC_LEN <= self.state.capacity);
            return self.tickPhysicsRange(dt, i, i + VEC_LEN);
        }
        pub fn tickPhysics16WithEffects(self: *Self, dt: f32, i: usize, effects_a: *const warlock_talents.Effects, effects_b: *const warlock_talents.Effects) usize {
            std.debug.assert(i % VEC_LEN == 0 and i + VEC_LEN <= self.state.capacity);
            return self.tickPhysicsRangeWithEffects(dt, i, i + VEC_LEN, effects_a, effects_b);
        }
        fn tickPhysicsRange(self: *Self, dt: f32, start: usize, end: usize) usize {
            return self.tickPhysicsRangeWithEffects(dt, start, end, null, null);
        }
        fn tickPhysicsRangeWithEffects(self: *Self, dt: f32, start: usize, end: usize, provided_a: ?*const warlock_talents.Effects, provided_b: ?*const warlock_talents.Effects) usize {
            const v_dt: f32x16 = @splat(dt);
            const v_zeros: f32x16 = @splat(0.0);
            const v_zeros_u32: u32x16 = @splat(0);
            const v_ones_u32: u32x16 = @splat(1);
            const v_max_dist: f32x16 = @splat(WarlockConstants.MaxDistance);

            var active_duels_sum: usize = 0;
            var i: usize = start;

            while (i < end) : (i += VEC_LEN) {
                const active_mask: bool16 = self.state.is_active[i..][0..VEC_LEN].* > v_zeros_u32;
                if (!@reduce(.Or, active_mask)) continue;
                var effects_a = if (provided_a) |fx| fx.* else warlock_talents.decode(self.state.talent_ranks_a[i..][0..VEC_LEN].*, self.state.talent_flags_a[i..][0..VEC_LEN].*);
                @import("conflagrate.zig").tickEffects(&self.state, true, i, dt, &effects_a);
                var effects_b = if (provided_b) |fx| fx.* else warlock_talents.decode(self.state.talent_ranks_b[i..][0..VEC_LEN].*, self.state.talent_flags_b[i..][0..VEC_LEN].*);
                @import("conflagrate.zig").tickEffects(&self.state, false, i, dt, &effects_b);

                // Load State
                var dist = self.state.distance[i..][0..VEC_LEN].*;
                var hp_a = self.state.hp_a[i..][0..VEC_LEN].*;
                var hp_b = self.state.hp_b[i..][0..VEC_LEN].*;
                var mana_a = self.state.mana_a[i..][0..VEC_LEN].*;
                var mana_b = self.state.mana_b[i..][0..VEC_LEN].*;
                const PetKind = @import("pets.zig").Kind;
                const sacrifice_a = if (spec_a == .warlock) vAnd16(effects_a.demonic_sacrifice > v_zeros, effects_a.demonic_sacrifice_pet > v_zeros) else @as(bool16, @splat(false));
                const sacrifice_b = if (spec_b == .warlock) vAnd16(effects_b.demonic_sacrifice > v_zeros, effects_b.demonic_sacrifice_pet > v_zeros) else @as(bool16, @splat(false));
                const is_imp_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.imp))));
                const is_succ_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.succubus))));
                const is_vw_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.voidwalker))));
                const is_fh_a = vAnd16(sacrifice_a, effects_a.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.felhunter))));
                const is_imp_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.imp))));
                const is_succ_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.succubus))));
                const is_vw_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.voidwalker))));
                const is_fh_b = vAnd16(sacrifice_b, effects_b.demonic_sacrifice_pet == splat(@floatFromInt(@intFromEnum(PetKind.felhunter))));
                effects_a.shadow_damage *= select16(is_imp_a, splat(1.15), splat(1));
                effects_b.shadow_damage *= select16(is_imp_b, splat(1.15), splat(1));
                const shadow_sac_mult_a = select16(is_imp_a, splat(1.15), splat(1));
                const shadow_sac_mult_b = select16(is_imp_b, splat(1.15), splat(1));
                effects_a.agony_damage *= shadow_sac_mult_a;
                effects_a.corruption_damage *= shadow_sac_mult_a;
                effects_a.drain_life_damage *= shadow_sac_mult_a;
                effects_a.drain_life_healing *= shadow_sac_mult_a;
                effects_a.siphon_life_damage *= shadow_sac_mult_a;
                effects_a.siphon_life_healing *= shadow_sac_mult_a;
                effects_b.agony_damage *= shadow_sac_mult_b;
                effects_b.corruption_damage *= shadow_sac_mult_b;
                effects_b.drain_life_damage *= shadow_sac_mult_b;
                effects_b.drain_life_healing *= shadow_sac_mult_b;
                effects_b.siphon_life_damage *= shadow_sac_mult_b;
                effects_b.siphon_life_healing *= shadow_sac_mult_b;
                effects_a.fire_damage *= select16(is_succ_a, splat(1.15), splat(1));
                effects_b.fire_damage *= select16(is_succ_b, splat(1.15), splat(1));
                var gcd_a = self.state.gcd_a[i..][0..VEC_LEN].*;
                var gcd_b = self.state.gcd_b[i..][0..VEC_LEN].*;
                var r_tmr_a = self.state.react_timer_a[i..][0..VEC_LEN].*;
                var r_tmr_b = self.state.react_timer_b[i..][0..VEC_LEN].*;
                const move_a = self.state.move_intent_a[i..][0..VEC_LEN].*;
                const move_b = self.state.move_intent_b[i..][0..VEC_LEN].*;

                var c_id_a = self.state.cast_id_a[i..][0..VEC_LEN].*;
                var c_tmr_a = self.state.cast_timer_a[i..][0..VEC_LEN].*;
                var c_tot_a = self.state.cast_total_a[i..][0..VEC_LEN].*;

                var c_id_b = self.state.cast_id_b[i..][0..VEC_LEN].*;
                var c_tmr_b = self.state.cast_timer_b[i..][0..VEC_LEN].*;
                var c_tot_b = self.state.cast_total_b[i..][0..VEC_LEN].*;

                var ago_a = self.state.agony_timer_a[i..][0..VEC_LEN].*;
                var immolate_a = self.state.immolate_timer_a[i..][0..VEC_LEN].*;
                var crp_a = self.state.corruption_timer_a[i..][0..VEC_LEN].*;
                var siph_a = self.state.siphon_timer_a[i..][0..VEC_LEN].*;
                var fear_a = self.state.fear_timer_a[i..][0..VEC_LEN].*;
                var seduced_a = self.state.seduced_a[i..][0..VEC_LEN].*;
                var seduction_a = self.state.seduction_timer_a[i..][0..VEC_LEN].*;
                var fear_dmg_a = self.state.fear_accum_dmg_a[i..][0..VEC_LEN].*;
                var horror_a = self.state.horror_timer_a[i..][0..VEC_LEN].*;

                var ago_b = self.state.agony_timer_b[i..][0..VEC_LEN].*;
                var immolate_b = self.state.immolate_timer_b[i..][0..VEC_LEN].*;
                var crp_b = self.state.corruption_timer_b[i..][0..VEC_LEN].*;
                var siph_b = self.state.siphon_timer_b[i..][0..VEC_LEN].*;
                var fear_b = self.state.fear_timer_b[i..][0..VEC_LEN].*;
                var seduced_b = self.state.seduced_b[i..][0..VEC_LEN].*;
                var seduction_b = self.state.seduction_timer_b[i..][0..VEC_LEN].*;
                var fear_dmg_b = self.state.fear_accum_dmg_b[i..][0..VEC_LEN].*;
                var horror_b = self.state.horror_timer_b[i..][0..VEC_LEN].*;

                var un_cd_a = self.state.action6_cd_a[i..][0..VEC_LEN].*;
                var un_dur_a = self.state.action6_dur_a[i..][0..VEC_LEN].*;
                var dc_cd_a = self.state.death_coil_cd_a[i..][0..VEC_LEN].*;
                var seduction_cd_a = self.state.seduction_cd_a[i..][0..VEC_LEN].*;
                var seduction_cast_a = self.state.seduction_cast_a[i..][0..VEC_LEN].*;
                var fear_dr_t_a = self.state.fear_dr_tier_a[i..][0..VEC_LEN].*;
                var fear_dr_tmr_a = self.state.fear_dr_timer_a[i..][0..VEC_LEN].*;
                var seduction_dr_t_a = self.state.seduction_dr_tier_a[i..][0..VEC_LEN].*;
                var seduction_dr_tmr_a = self.state.seduction_dr_timer_a[i..][0..VEC_LEN].*;
                var horror_dr_t_a = self.state.horror_dr_tier_a[i..][0..VEC_LEN].*;
                var horror_dr_tmr_a = self.state.horror_dr_timer_a[i..][0..VEC_LEN].*;

                var un_cd_b = self.state.action6_cd_b[i..][0..VEC_LEN].*;
                var un_dur_b = self.state.action6_dur_b[i..][0..VEC_LEN].*;
                var dc_cd_b = self.state.death_coil_cd_b[i..][0..VEC_LEN].*;
                var seduction_cd_b = self.state.seduction_cd_b[i..][0..VEC_LEN].*;
                var seduction_cast_b = self.state.seduction_cast_b[i..][0..VEC_LEN].*;
                var fear_dr_t_b = self.state.fear_dr_tier_b[i..][0..VEC_LEN].*;
                var fear_dr_tmr_b = self.state.fear_dr_timer_b[i..][0..VEC_LEN].*;
                var seduction_dr_t_b = self.state.seduction_dr_tier_b[i..][0..VEC_LEN].*;
                var seduction_dr_tmr_b = self.state.seduction_dr_timer_b[i..][0..VEC_LEN].*;
                var horror_dr_t_b = self.state.horror_dr_tier_b[i..][0..VEC_LEN].*;
                var horror_dr_tmr_b = self.state.horror_dr_timer_b[i..][0..VEC_LEN].*;

                inline for (.{ true, false }) |side| {
                    inline for (.{ Extra.blink, Extra.nova, Extra.lockout }) |kind| {
                        const timer = self.extra(kind, side, i);
                        timer.* = @max(v_zeros, timer.* - v_dt);
                    }
                }
                // 1. Advance general timers
                gcd_a = @max(v_zeros, gcd_a - v_dt);
                gcd_b = @max(v_zeros, gcd_b - v_dt);
                r_tmr_a = @max(v_zeros, r_tmr_a - v_dt);
                r_tmr_b = @max(v_zeros, r_tmr_b - v_dt);
                un_cd_a = @max(v_zeros, un_cd_a - v_dt);
                un_cd_b = @max(v_zeros, un_cd_b - v_dt);
                un_dur_a = @max(v_zeros, un_dur_a - v_dt);
                un_dur_b = @max(v_zeros, un_dur_b - v_dt);
                dc_cd_a = @max(v_zeros, dc_cd_a - v_dt);
                dc_cd_b = @max(v_zeros, dc_cd_b - v_dt);
                seduction_cd_a = @max(v_zeros, seduction_cd_a - v_dt);
                seduction_cd_b = @max(v_zeros, seduction_cd_b - v_dt);
                const seduction_casting_a = seduction_cast_a > v_zeros;
                const seduction_casting_b = seduction_cast_b > v_zeros;
                seduction_cast_a = @max(v_zeros, seduction_cast_a - v_dt);
                seduction_cast_b = @max(v_zeros, seduction_cast_b - v_dt);
                const seduction_cast_done_a = vAnd16(seduction_casting_a, seduction_cast_a <= v_zeros);
                const seduction_cast_done_b = vAnd16(seduction_casting_b, seduction_cast_b <= v_zeros);
                fear_a = @max(v_zeros, fear_a - v_dt);
                fear_b = @max(v_zeros, fear_b - v_dt);
                seduction_a = @max(v_zeros, seduction_a - v_dt);
                seduction_b = @max(v_zeros, seduction_b - v_dt);
                seduced_a = @select(u32, seduction_a > v_zeros, seduced_a, v_zeros_u32);
                seduced_b = @select(u32, seduction_b > v_zeros, seduced_b, v_zeros_u32);
                immolate_a = @max(v_zeros, immolate_a - v_dt);
                immolate_b = @max(v_zeros, immolate_b - v_dt);
                horror_a = @max(v_zeros, horror_a - v_dt);
                horror_b = @max(v_zeros, horror_b - v_dt);

                // DR Timer progression when CC is inactive
                const fear_dr_ticking_a = vAnd16(fear_a <= v_zeros, fear_dr_t_a > v_zeros);
                fear_dr_tmr_a = select16(fear_dr_ticking_a, @max(v_zeros, fear_dr_tmr_a - v_dt), fear_dr_tmr_a);
                const fear_dr_reset_a = vAnd16(fear_dr_ticking_a, fear_dr_tmr_a <= v_zeros);
                fear_dr_t_a = select16(fear_dr_reset_a, v_zeros, fear_dr_t_a);
                const seduction_dr_ticking_a = vAnd16(seduction_a <= v_zeros, seduction_dr_t_a > v_zeros);
                seduction_dr_tmr_a = select16(seduction_dr_ticking_a, @max(v_zeros, seduction_dr_tmr_a - v_dt), seduction_dr_tmr_a);
                seduction_dr_t_a = select16(vAnd16(seduction_dr_ticking_a, seduction_dr_tmr_a <= v_zeros), v_zeros, seduction_dr_t_a);

                const fear_dr_ticking_b = vAnd16(fear_b <= v_zeros, fear_dr_t_b > v_zeros);
                fear_dr_tmr_b = select16(fear_dr_ticking_b, @max(v_zeros, fear_dr_tmr_b - v_dt), fear_dr_tmr_b);
                const fear_dr_reset_b = vAnd16(fear_dr_ticking_b, fear_dr_tmr_b <= v_zeros);
                fear_dr_t_b = select16(fear_dr_reset_b, v_zeros, fear_dr_t_b);
                const seduction_dr_ticking_b = vAnd16(seduction_b <= v_zeros, seduction_dr_t_b > v_zeros);
                seduction_dr_tmr_b = select16(seduction_dr_ticking_b, @max(v_zeros, seduction_dr_tmr_b - v_dt), seduction_dr_tmr_b);
                seduction_dr_t_b = select16(vAnd16(seduction_dr_ticking_b, seduction_dr_tmr_b <= v_zeros), v_zeros, seduction_dr_t_b);

                const horror_dr_ticking_a = vAnd16((if (spec_b == .frost_mage) ago_a else horror_a) <= v_zeros, horror_dr_t_a > v_zeros);
                horror_dr_tmr_a = select16(horror_dr_ticking_a, @max(v_zeros, horror_dr_tmr_a - v_dt), horror_dr_tmr_a);
                const horror_dr_reset_a = vAnd16(horror_dr_ticking_a, horror_dr_tmr_a <= v_zeros);
                horror_dr_t_a = select16(horror_dr_reset_a, v_zeros, horror_dr_t_a);

                const horror_dr_ticking_b = vAnd16((if (spec_a == .frost_mage) ago_b else horror_b) <= v_zeros, horror_dr_t_b > v_zeros);
                horror_dr_tmr_b = select16(horror_dr_ticking_b, @max(v_zeros, horror_dr_tmr_b - v_dt), horror_dr_tmr_b);
                const horror_dr_reset_b = vAnd16(horror_dr_ticking_b, horror_dr_tmr_b <= v_zeros);
                horror_dr_t_b = select16(horror_dr_reset_b, v_zeros, horror_dr_t_b);

                // Mana passive regen
                const regen: f32x16 = @splat(WarlockConstants.ManaRegenPerSec * dt);
                mana_a = @min(@as(f32x16, @splat(WarlockConstants.MaxMana)), mana_a + regen + @select(f32, is_vw_a, splat(WarlockConstants.MaxMana * 0.02 * dt / 4.0), v_zeros));
                mana_b = @min(@as(f32x16, @splat(WarlockConstants.MaxMana)), mana_b + regen + @select(f32, is_vw_b, splat(WarlockConstants.MaxMana * 0.02 * dt / 4.0), v_zeros));
                hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + @select(f32, is_fh_a, splat(WarlockConstants.MaxHp * 0.03 * dt / 4.0), v_zeros));
                hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + @select(f32, is_fh_b, splat(WarlockConstants.MaxHp * 0.03 * dt / 4.0), v_zeros));

                // 2. Movement & Relative Distance Update
                const speed_a = select16(move_a < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_a > v_zeros, @as(f32x16, @splat(WarlockConstants.BackpedalSpeed)), v_zeros));
                const speed_b = select16(move_b < v_zeros, @as(f32x16, @splat(-WarlockConstants.ForwardSpeed)), select16(move_b > v_zeros, @as(f32x16, @splat(WarlockConstants.BackpedalSpeed)), v_zeros));

                // While feared or horrified, unit runs away involuntarily!
                const fear_cc_a = vOr16(fear_a > v_zeros, horror_a > v_zeros);
                const fear_cc_b = vOr16(fear_b > v_zeros, horror_b > v_zeros);
                const cc_a = vOr16(fear_cc_a, seduction_a > v_zeros);
                const cc_b = vOr16(fear_cc_b, seduction_b > v_zeros);
                const controlled_speed_a = select16(fear_cc_a, @as(f32x16, @splat(if (spec_b == .frost_mage) @as(f32, 2.5) else WarlockConstants.ForwardSpeed)), speed_a);
                const fear_speed_a = if (spec_b == .frost_mage)
                    select16(ago_a > v_zeros, v_zeros, controlled_speed_a * select16(crp_a > v_zeros, splat(Frost.SlowMultiplier), splat(1)))
                else
                    controlled_speed_a;
                const controlled_speed_b = select16(fear_cc_b, @as(f32x16, @splat(if (spec_a == .frost_mage) @as(f32, 2.5) else WarlockConstants.ForwardSpeed)), speed_b);
                const fear_speed_b = if (spec_a == .frost_mage)
                    select16(ago_b > v_zeros, v_zeros, controlled_speed_b * select16(crp_b > v_zeros, splat(Frost.SlowMultiplier), splat(1)))
                else
                    controlled_speed_b;
                const effective_speed_a = select16(seduction_a > v_zeros, v_zeros, fear_speed_a) * @import("conflagrate.zig").speed(&self.state, true, i);
                const effective_speed_b = select16(seduction_b > v_zeros, v_zeros, fear_speed_b) * @import("conflagrate.zig").speed(&self.state, false, i);

                // 3. Movement cast cancel check:
                const a_is_stationary_casting = vAnd16(c_id_a > v_zeros_u32, c_id_a <= @as(u32x16, @splat(5)));
                const a_moved = effective_speed_a != v_zeros;
                const cancel_a = vAnd16(a_is_stationary_casting, vOr16(a_moved, cc_a));
                c_id_a = @select(u32, cancel_a, v_zeros_u32, c_id_a);
                c_tmr_a = select16(cancel_a, v_zeros, c_tmr_a);
                c_tot_a = select16(cancel_a, v_zeros, c_tot_a);

                const b_is_stationary_casting = vAnd16(c_id_b > v_zeros_u32, c_id_b <= @as(u32x16, @splat(5)));
                const b_moved = effective_speed_b != v_zeros;
                const cancel_b = vAnd16(b_is_stationary_casting, vOr16(b_moved, cc_b));
                c_id_b = @select(u32, cancel_b, v_zeros_u32, c_id_b);
                c_tmr_b = select16(cancel_b, v_zeros, c_tmr_b);
                c_tot_b = select16(cancel_b, v_zeros, c_tot_b);

                @import("conflagrate.zig").tickDaze(&self.state, i, dt);
                dist = @import("movement_2d.zig").tick(&self.state, i, dt, effective_speed_a, effective_speed_b, fear_cc_a, fear_cc_b, @max(@as(f32x16, fear_a), @as(f32x16, horror_a)), @max(@as(f32x16, fear_b), @as(f32x16, horror_b)));

                var hits_a = @import("projectiles.zig").tick(&self.state, true, i, dt);
                hits_a.conflagrate = @import("conflagrate.zig").takeDamage(&self.state, true, i);
                var hits_b = @import("projectiles.zig").tick(&self.state, false, i, dt);
                hits_b.conflagrate = @import("conflagrate.zig").takeDamage(&self.state, false, i);

                // 4. Damage Mitigation Factor:
                const mit_a = if (spec_a == .warlock) effects_a.damage_taken else splat(1);
                const mit_b = if (spec_b == .warlock) effects_b.damage_taken else splat(1);

                if (@reduce(.Or, hits_a.coil > v_zeros)) {
                    const coil_hit_a = hits_a.coil > v_zeros;
                    hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + select16(coil_hit_a, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros));
                    const coil_dur_a = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * getDrMultiplier(horror_dr_t_b);
                    horror_b = select16(vAnd16(coil_hit_a, coil_dur_a > v_zeros), coil_dur_a, horror_b);
                    horror_dr_t_b = select16(coil_hit_a, @min(@as(f32x16, @splat(3)), horror_dr_t_b + @as(f32x16, @splat(1))), horror_dr_t_b);
                    horror_dr_tmr_b = select16(coil_hit_a, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_b);
                    const coil_cancel_b = vAnd16(coil_hit_a, coil_dur_a > v_zeros);
                    c_id_b = @select(u32, coil_cancel_b, v_zeros_u32, c_id_b);
                    c_tmr_b = select16(coil_cancel_b, v_zeros, c_tmr_b);
                    c_tot_b = select16(coil_cancel_b, v_zeros, c_tot_b);
                    r_tmr_b = select16(coil_cancel_b, v_zeros, r_tmr_b);
                }
                if (@reduce(.Or, hits_b.coil > v_zeros)) {
                    const coil_hit_b = hits_b.coil > v_zeros;
                    hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + select16(coil_hit_b, @as(f32x16, @splat(WarlockConstants.DeathCoilHeal)), v_zeros));
                    const coil_dur_b = @as(f32x16, @splat(WarlockConstants.DeathCoilDuration)) * getDrMultiplier(horror_dr_t_a);
                    horror_a = select16(vAnd16(coil_hit_b, coil_dur_b > v_zeros), coil_dur_b, horror_a);
                    horror_dr_t_a = select16(coil_hit_b, @min(@as(f32x16, @splat(3)), horror_dr_t_a + @as(f32x16, @splat(1))), horror_dr_t_a);
                    horror_dr_tmr_a = select16(coil_hit_b, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), horror_dr_tmr_a);
                    const coil_cancel_a = vAnd16(coil_hit_b, coil_dur_b > v_zeros);
                    c_id_a = @select(u32, coil_cancel_a, v_zeros_u32, c_id_a);
                    c_tmr_a = select16(coil_cancel_a, v_zeros, c_tmr_a);
                    c_tot_a = select16(coil_cancel_a, v_zeros, c_tot_a);
                    r_tmr_a = select16(coil_cancel_a, v_zeros, r_tmr_a);
                }

                // 5. DOT Ticking:
                const has_ago_a = ago_a > v_zeros;
                ago_a = @max(v_zeros, ago_a - v_dt);
                const dmg_ago_a = if (spec_b == .frost_mage) v_zeros else select16(has_ago_a, @as(f32x16, @splat(WarlockConstants.AgonyDps * dt)) * effects_b.agony_damage * mit_a, v_zeros);

                const has_crp_a = crp_a > v_zeros;
                crp_a = @max(v_zeros, crp_a - v_dt);
                const dmg_crp_a = if (spec_b == .frost_mage) v_zeros else select16(has_crp_a, @as(f32x16, @splat(WarlockConstants.CorruptionDps * dt)) * effects_b.corruption_damage * mit_a, v_zeros);
                const dmg_immolate_a = if (spec_b == .frost_mage) v_zeros else select16(immolate_a > v_zeros, @as(f32x16, @splat(WarlockConstants.ImmolateDps * dt)) * effects_b.periodic_damage * effects_b.fire_damage * mit_a, v_zeros);

                const has_siph_a = siph_a > v_zeros;
                siph_a = @max(v_zeros, siph_a - v_dt);
                const dmg_siph_a = if (spec_b == .frost_mage) v_zeros else select16(has_siph_a, @as(f32x16, @splat(WarlockConstants.SiphonLifeDps * dt)) * effects_b.siphon_life_damage * mit_a, v_zeros);
                const heal_siph_b = if (spec_b == .frost_mage) v_zeros else select16(has_siph_a, @as(f32x16, @splat(WarlockConstants.SiphonLifeHps * dt)) * effects_b.siphon_life_healing, v_zeros);
                hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + heal_siph_b);

                const has_ago_b = ago_b > v_zeros;
                ago_b = @max(v_zeros, ago_b - v_dt);
                const dmg_ago_b = if (spec_a == .frost_mage) v_zeros else select16(has_ago_b, @as(f32x16, @splat(WarlockConstants.AgonyDps * dt)) * effects_a.agony_damage * mit_b, v_zeros);

                const has_crp_b = crp_b > v_zeros;
                crp_b = @max(v_zeros, crp_b - v_dt);
                const dmg_crp_b = if (spec_a == .frost_mage) v_zeros else select16(has_crp_b, @as(f32x16, @splat(WarlockConstants.CorruptionDps * dt)) * effects_a.corruption_damage * mit_b, v_zeros);
                const dmg_immolate_b = if (spec_a == .frost_mage) v_zeros else select16(immolate_b > v_zeros, @as(f32x16, @splat(WarlockConstants.ImmolateDps * dt)) * effects_a.periodic_damage * effects_a.fire_damage * mit_b, v_zeros);

                const has_siph_b = siph_b > v_zeros;
                siph_b = @max(v_zeros, siph_b - v_dt);
                const dmg_siph_b = if (spec_a == .frost_mage) v_zeros else select16(has_siph_b, @as(f32x16, @splat(WarlockConstants.SiphonLifeDps * dt)) * effects_a.siphon_life_damage * mit_b, v_zeros);
                const heal_siph_a = if (spec_a == .frost_mage) v_zeros else select16(has_siph_b, @as(f32x16, @splat(WarlockConstants.SiphonLifeHps * dt)) * effects_a.siphon_life_healing, v_zeros);
                hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + heal_siph_a);

                // 6. Cast Execution & Drain Life Channeling:
                // --- Unit A Cast Progress ---
                const a_casting = c_id_a > v_zeros_u32;
                c_tmr_a = select16(a_casting, c_tmr_a - v_dt, v_zeros);
                const a_cast_finished = vAnd16(a_casting, c_tmr_a <= v_zeros);

                const a_drain_active = if (spec_a == .frost_mage) @as(bool16, @splat(false)) else vAnd16(a_casting, c_id_a == @as(u32x16, @splat(5)));
                const a_drain_dmg = select16(a_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeDps * dt)) * effects_a.drain_life_damage * mit_b, v_zeros);
                const a_drain_heal = select16(a_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeHps * dt)) * effects_a.drain_life_healing, v_zeros);
                hp_a = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_a + a_drain_heal);

                const a_sb_hit = vAnd16(vAnd16(a_cast_finished, dist <= v_max_dist), c_id_a == @as(u32x16, @splat(4)));
                @import("projectiles.zig").launch(&self.state, true, i, 4, @as(f32x16, @splat(if (spec_a == .frost_mage) Frost.BoltDamage else WarlockConstants.ShadowBoltDamage)) * (if (spec_a == .warlock) effects_a.shadow_damage else splat(1)), a_sb_hit);
                const a_sp_hit = if (spec_a == .warlock) vAnd16(a_cast_finished, c_id_a == ids(11)) else @as(bool16, @splat(false));
                @import("projectiles.zig").launch(&self.state, true, i, 11, splat(WarlockConstants.SearingPainDamage) * (if (spec_a == .warlock) effects_a.fire_damage else splat(1)), a_sp_hit);
                const a_inc_hit = if (spec_a == .warlock) vAnd16(a_cast_finished, c_id_a == ids(12)) else @as(bool16, @splat(false));
                const a_inc_bonus = select16(immolate_b > v_zeros, splat(1.25), splat(1.0));
                @import("projectiles.zig").launch(&self.state, true, i, 12, splat(WarlockConstants.IncinerateDamage) * a_inc_bonus * (if (spec_a == .warlock) effects_a.fire_damage else splat(1)), a_inc_hit);
                const a_immolate_hit = if (spec_a == .warlock) vAnd16(a_cast_finished, c_id_a == ids(13)) else @as(bool16, @splat(false));
                @import("projectiles.zig").launch(&self.state, true, i, 13, splat(WarlockConstants.ImmolateInitialDamage) * (if (spec_a == .warlock) effects_a.immolate_initial_damage else splat(1)), a_immolate_hit);
                const a_sb_dmg = (hits_a.bolt + hits_a.lance + hits_a.coil + hits_a.conflagrate) * mit_b;
                if (spec_a == .frost_mage) crp_b = select16(hits_a.bolt > v_zeros, splat(Frost.SlowDuration), crp_b);

                const a_fear_hit = vAnd16(vAnd16(a_cast_finished, dist <= splat(if (spec_a == .frost_mage) Frost.PolymorphRange else WarlockConstants.FearRange)), c_id_a == @as(u32x16, @splat(3)));
                const a_fear_dr_mult = getDrMultiplier(fear_dr_t_b);
                const a_fear_dur = @as(f32x16, @splat(if (spec_a == .frost_mage) Frost.PolymorphDuration else WarlockConstants.FearDuration)) * a_fear_dr_mult;
                fear_b = select16(vAnd16(a_fear_hit, a_fear_dur > v_zeros), a_fear_dur, fear_b);
                const a_cc_applied = vAnd16(a_fear_hit, a_fear_dur > v_zeros);
                c_id_b = @select(u32, a_cc_applied, v_zeros_u32, c_id_b);
                c_tmr_b = select16(a_cc_applied, v_zeros, c_tmr_b);
                c_tot_b = select16(a_cc_applied, v_zeros, c_tot_b);
                r_tmr_b = select16(a_cc_applied, v_zeros, r_tmr_b);
                fear_dr_t_b = select16(a_fear_hit, @min(@as(f32x16, @splat(3.0)), fear_dr_t_b + @as(f32x16, @splat(1.0))), fear_dr_t_b);
                fear_dr_tmr_b = select16(a_fear_hit, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), fear_dr_tmr_b);
                fear_dmg_b = select16(a_fear_hit, v_zeros, fear_dmg_b);

                c_id_a = @select(u32, a_cast_finished, v_zeros_u32, c_id_a);
                c_tmr_a = select16(a_cast_finished, v_zeros, c_tmr_a);
                c_tot_a = select16(a_cast_finished, v_zeros, c_tot_a);
                r_tmr_a = select16(a_cast_finished, v_zeros, r_tmr_a);

                // --- Unit B Cast Progress ---
                const b_casting = c_id_b > v_zeros_u32;
                c_tmr_b = select16(b_casting, c_tmr_b - v_dt, v_zeros);
                const b_cast_finished = vAnd16(b_casting, c_tmr_b <= v_zeros);

                const b_drain_active = if (spec_b == .frost_mage) @as(bool16, @splat(false)) else vAnd16(b_casting, c_id_b == @as(u32x16, @splat(5)));
                const b_drain_dmg = select16(b_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeDps * dt)) * effects_b.drain_life_damage * mit_a, v_zeros);
                const b_drain_heal = select16(b_drain_active, @as(f32x16, @splat(WarlockConstants.DrainLifeHps * dt)) * effects_b.drain_life_healing, v_zeros);
                hp_b = @min(@as(f32x16, @splat(WarlockConstants.MaxHp)), hp_b + b_drain_heal);

                const b_sb_hit = vAnd16(vAnd16(b_cast_finished, dist <= v_max_dist), c_id_b == @as(u32x16, @splat(4)));
                @import("projectiles.zig").launch(&self.state, false, i, 4, @as(f32x16, @splat(if (spec_b == .frost_mage) Frost.BoltDamage else WarlockConstants.ShadowBoltDamage)) * (if (spec_b == .warlock) effects_b.shadow_damage else splat(1)), b_sb_hit);
                const b_sp_hit = if (spec_b == .warlock) vAnd16(b_cast_finished, c_id_b == ids(11)) else @as(bool16, @splat(false));
                @import("projectiles.zig").launch(&self.state, false, i, 11, splat(WarlockConstants.SearingPainDamage) * (if (spec_b == .warlock) effects_b.fire_damage else splat(1)), b_sp_hit);
                const b_inc_hit = if (spec_b == .warlock) vAnd16(b_cast_finished, c_id_b == ids(12)) else @as(bool16, @splat(false));
                const b_inc_bonus = select16(immolate_a > v_zeros, splat(1.25), splat(1.0));
                @import("projectiles.zig").launch(&self.state, false, i, 12, splat(WarlockConstants.IncinerateDamage) * b_inc_bonus * (if (spec_b == .warlock) effects_b.fire_damage else splat(1)), b_inc_hit);
                const b_immolate_hit = if (spec_b == .warlock) vAnd16(b_cast_finished, c_id_b == ids(13)) else @as(bool16, @splat(false));
                @import("projectiles.zig").launch(&self.state, false, i, 13, splat(WarlockConstants.ImmolateInitialDamage) * (if (spec_b == .warlock) effects_b.immolate_initial_damage else splat(1)), b_immolate_hit);
                const b_sb_dmg = (hits_b.bolt + hits_b.lance + hits_b.coil + hits_b.conflagrate) * mit_a;
                if (spec_b == .frost_mage) crp_a = select16(hits_b.bolt > v_zeros, splat(Frost.SlowDuration), crp_a);

                const b_fear_hit = vAnd16(vAnd16(b_cast_finished, dist <= splat(if (spec_b == .frost_mage) Frost.PolymorphRange else WarlockConstants.FearRange)), c_id_b == @as(u32x16, @splat(3)));
                const b_fear_dr_mult = getDrMultiplier(fear_dr_t_a);
                const b_fear_dur = @as(f32x16, @splat(if (spec_b == .frost_mage) Frost.PolymorphDuration else WarlockConstants.FearDuration)) * b_fear_dr_mult;
                fear_a = select16(vAnd16(b_fear_hit, b_fear_dur > v_zeros), b_fear_dur, fear_a);
                const b_cc_applied = vAnd16(b_fear_hit, b_fear_dur > v_zeros);
                c_id_a = @select(u32, b_cc_applied, v_zeros_u32, c_id_a);
                c_tmr_a = select16(b_cc_applied, v_zeros, c_tmr_a);
                c_tot_a = select16(b_cc_applied, v_zeros, c_tot_a);
                r_tmr_a = select16(b_cc_applied, v_zeros, r_tmr_a);
                fear_dr_t_a = select16(b_fear_hit, @min(@as(f32x16, @splat(3.0)), fear_dr_t_a + @as(f32x16, @splat(1.0))), fear_dr_t_a);
                fear_dr_tmr_a = select16(b_fear_hit, @as(f32x16, @splat(WarlockConstants.DrResetDuration)), fear_dr_tmr_a);
                fear_dmg_a = select16(b_fear_hit, v_zeros, fear_dmg_a);

                c_id_b = @select(u32, b_cast_finished, v_zeros_u32, c_id_b);
                c_tmr_b = select16(b_cast_finished, v_zeros, c_tmr_b);
                c_tot_b = select16(b_cast_finished, v_zeros, c_tot_b);
                r_tmr_b = select16(b_cast_finished, v_zeros, r_tmr_b);

                const succubus_kind = @import("pets.zig").Kind.succubus;
                const seduce_hit_a = if (spec_a == .warlock) vAnd16(seduction_cast_done_a, vAnd16(dist <= splat(WarlockConstants.SeductionRange), vAnd16(self.state.pet_kind_a[i..][0..VEC_LEN].* == ids(@intFromEnum(succubus_kind)), self.state.pet_hp_a[i..][0..VEC_LEN].* > v_zeros))) else @as(bool16, @splat(false));
                const seduce_hit_b = if (spec_b == .warlock) vAnd16(seduction_cast_done_b, vAnd16(dist <= splat(WarlockConstants.SeductionRange), vAnd16(self.state.pet_kind_b[i..][0..VEC_LEN].* == ids(@intFromEnum(succubus_kind)), self.state.pet_hp_b[i..][0..VEC_LEN].* > v_zeros))) else @as(bool16, @splat(false));
                const seduce_dur_a = splat(WarlockConstants.SeductionDuration) * getDrMultiplier(seduction_dr_t_b);
                const seduce_dur_b = splat(WarlockConstants.SeductionDuration) * getDrMultiplier(seduction_dr_t_a);
                const seduce_applied_a = vAnd16(seduce_hit_a, seduce_dur_a > v_zeros);
                const seduce_applied_b = vAnd16(seduce_hit_b, seduce_dur_b > v_zeros);
                seduction_b = select16(seduce_applied_a, seduce_dur_a, seduction_b);
                seduction_a = select16(seduce_applied_b, seduce_dur_b, seduction_a);
                seduced_b = @select(u32, seduce_applied_a, v_ones_u32, seduced_b);
                seduced_a = @select(u32, seduce_applied_b, v_ones_u32, seduced_a);
                seduction_dr_t_b = select16(seduce_hit_a, @min(splat(3.0), seduction_dr_t_b + splat(1.0)), seduction_dr_t_b);
                seduction_dr_tmr_b = select16(seduce_hit_a, splat(WarlockConstants.DrResetDuration), seduction_dr_tmr_b);
                seduction_dr_t_a = select16(seduce_hit_b, @min(splat(3.0), seduction_dr_t_a + splat(1.0)), seduction_dr_t_a);
                seduction_dr_tmr_a = select16(seduce_hit_b, splat(WarlockConstants.DrResetDuration), seduction_dr_tmr_a);
                c_id_b = @select(u32, seduce_applied_a, v_zeros_u32, c_id_b);
                c_tmr_b = select16(seduce_applied_a, v_zeros, c_tmr_b);
                c_tot_b = select16(seduce_applied_a, v_zeros, c_tot_b);
                c_id_a = @select(u32, seduce_applied_b, v_zeros_u32, c_id_a);
                c_tmr_a = select16(seduce_applied_b, v_zeros, c_tmr_a);
                c_tot_a = select16(seduce_applied_b, v_zeros, c_tot_a);

                const pet_a = if (spec_a == .warlock) @import("pets.zig").tick(&self.state, true, i, dt, effects_a.imp_firebolt_damage) * effects_a.pet_damage else v_zeros;
                const pet_b = if (spec_b == .warlock) @import("pets.zig").tick(&self.state, false, i, dt, effects_b.imp_firebolt_damage) * effects_b.pet_damage else v_zeros;

                // 7. Apply Damage to HP
                var total_dmg_to_a = dmg_ago_a + dmg_crp_a + dmg_immolate_a + hits_b.immolate * mit_a + dmg_siph_a + b_drain_dmg + b_sb_dmg + pet_b * mit_a;
                var total_dmg_to_b = dmg_ago_b + dmg_crp_b + dmg_immolate_b + hits_a.immolate * mit_b + dmg_siph_b + a_drain_dmg + a_sb_dmg + pet_a * mit_b;
                seduction_a = select16(total_dmg_to_a > v_zeros, v_zeros, seduction_a);
                seduction_b = select16(total_dmg_to_b > v_zeros, v_zeros, seduction_b);
                seduced_a = @select(u32, total_dmg_to_a > v_zeros, v_zeros_u32, seduced_a);
                seduced_b = @select(u32, total_dmg_to_b > v_zeros, v_zeros_u32, seduced_b);
                immolate_a = if (spec_b == .warlock) select16(hits_b.immolate > v_zeros, splat(WarlockConstants.ImmolateDuration), immolate_a) else immolate_a;
                immolate_b = if (spec_a == .warlock) select16(hits_a.immolate > v_zeros, splat(WarlockConstants.ImmolateDuration), immolate_b) else immolate_b;
                const incoming_a = total_dmg_to_a;
                const incoming_b = total_dmg_to_b;

                if (spec_a == .frost_mage) {
                    const shield = self.extra(.shield, true, i);
                    shield.* = select16(un_dur_a > v_zeros, shield.*, v_zeros);
                    const absorbed = @min(shield.*, total_dmg_to_a);
                    shield.* -= absorbed;
                    total_dmg_to_a -= absorbed;
                    un_dur_a = select16(shield.* > v_zeros, un_dur_a, v_zeros);
                }
                const pet_live_a = self.state.pet_hp_a[i..][0..VEC_LEN].* > v_zeros;
                const sl_active_a = if (spec_a == .warlock) vAnd16(pet_live_a, self.state.soul_link_a[i..][0..VEC_LEN].* != v_zeros_u32) else @as(bool16, @splat(false));
                const sl_split_a = select16(sl_active_a, total_dmg_to_a * @as(f32x16, @splat(0.30)), v_zeros);
                const direct_dmg_a = total_dmg_to_a - sl_split_a;
                if (spec_a == .warlock) {
                    self.state.pet_hp_a[i..][0..VEC_LEN].* = @max(v_zeros, self.state.pet_hp_a[i..][0..VEC_LEN].* - sl_split_a);
                }

                @import("projectiles.zig").recordHits(&self.state, false, i, hits_b, mit_a, incoming_a, @min(@as(f32x16, hp_a), total_dmg_to_a));
                @import("pets.zig").recordDamage(&self.state, false, i, pet_b * mit_a, incoming_a, @min(@as(f32x16, hp_a), total_dmg_to_a));
                hp_a = @max(v_zeros, hp_a - direct_dmg_a);
                if (spec_b == .frost_mage) {
                    const root_damage = self.extra(.root_damage, true, i);
                    root_damage.* += total_dmg_to_a;
                    ago_a = select16(root_damage.* >= splat(250), v_zeros, ago_a);
                }
                if (spec_b == .frost_mage) {
                    const shield = self.extra(.shield, false, i);
                    shield.* = select16(un_dur_b > v_zeros, shield.*, v_zeros);
                    const absorbed = @min(shield.*, total_dmg_to_b);
                    shield.* -= absorbed;
                    total_dmg_to_b -= absorbed;
                    un_dur_b = select16(shield.* > v_zeros, un_dur_b, v_zeros);
                }
                const pet_live_b = self.state.pet_hp_b[i..][0..VEC_LEN].* > v_zeros;
                const sl_active_b = if (spec_b == .warlock) vAnd16(pet_live_b, self.state.soul_link_b[i..][0..VEC_LEN].* != v_zeros_u32) else @as(bool16, @splat(false));
                const sl_split_b = select16(sl_active_b, total_dmg_to_b * @as(f32x16, @splat(0.30)), v_zeros);
                const direct_dmg_b = total_dmg_to_b - sl_split_b;
                if (spec_b == .warlock) {
                    self.state.pet_hp_b[i..][0..VEC_LEN].* = @max(v_zeros, self.state.pet_hp_b[i..][0..VEC_LEN].* - sl_split_b);
                }

                @import("projectiles.zig").recordHits(&self.state, true, i, hits_a, mit_b, incoming_b, @min(@as(f32x16, hp_b), total_dmg_to_b));
                @import("pets.zig").recordDamage(&self.state, true, i, pet_a * mit_b, incoming_b, @min(@as(f32x16, hp_b), total_dmg_to_b));
                hp_b = @max(v_zeros, hp_b - direct_dmg_b);
                if (spec_a == .frost_mage) {
                    const root_damage = self.extra(.root_damage, false, i);
                    root_damage.* += total_dmg_to_b;
                    ago_b = select16(root_damage.* >= splat(250), v_zeros, ago_b);
                }

                // Fear damage break threshold check
                fear_dmg_a = fear_dmg_a + total_dmg_to_a;
                fear_a = select16(fear_dmg_a >= @as(f32x16, @splat(if (spec_b == .frost_mage) @as(f32, 0.001) else WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_a);

                fear_dmg_b = fear_dmg_b + total_dmg_to_b;
                fear_b = select16(fear_dmg_b >= @as(f32x16, @splat(if (spec_a == .frost_mage) @as(f32, 0.001) else WarlockConstants.FearBreakDmgThreshold)), v_zeros, fear_b);

                // 8. Duel Liveness & Writeback
                const duel_alive = vAnd16(hp_a > v_zeros, hp_b > v_zeros);
                const v_duel_act: u32x16 = @select(u32, duel_alive, v_ones_u32, v_zeros_u32);

                self.state.distance[i..][0..VEC_LEN].* = dist;
                self.state.hp_a[i..][0..VEC_LEN].* = hp_a;
                self.state.hp_b[i..][0..VEC_LEN].* = hp_b;
                self.state.mana_a[i..][0..VEC_LEN].* = mana_a;
                self.state.mana_b[i..][0..VEC_LEN].* = mana_b;
                self.state.gcd_a[i..][0..VEC_LEN].* = gcd_a;
                self.state.gcd_b[i..][0..VEC_LEN].* = gcd_b;
                self.state.react_timer_a[i..][0..VEC_LEN].* = r_tmr_a;
                self.state.react_timer_b[i..][0..VEC_LEN].* = r_tmr_b;

                self.state.cast_id_a[i..][0..VEC_LEN].* = c_id_a;
                self.state.cast_timer_a[i..][0..VEC_LEN].* = c_tmr_a;
                self.state.cast_total_a[i..][0..VEC_LEN].* = c_tot_a;

                self.state.cast_id_b[i..][0..VEC_LEN].* = c_id_b;
                self.state.cast_timer_b[i..][0..VEC_LEN].* = c_tmr_b;
                self.state.cast_total_b[i..][0..VEC_LEN].* = c_tot_b;

                self.state.agony_timer_a[i..][0..VEC_LEN].* = ago_a;
                self.state.immolate_timer_a[i..][0..VEC_LEN].* = immolate_a;
                self.state.corruption_timer_a[i..][0..VEC_LEN].* = crp_a;
                self.state.siphon_timer_a[i..][0..VEC_LEN].* = siph_a;
                self.state.fear_timer_a[i..][0..VEC_LEN].* = fear_a;
                self.state.seduction_timer_a[i..][0..VEC_LEN].* = seduction_a;
                self.state.seduced_a[i..][0..VEC_LEN].* = seduced_a;
                self.state.fear_accum_dmg_a[i..][0..VEC_LEN].* = fear_dmg_a;
                self.state.horror_timer_a[i..][0..VEC_LEN].* = horror_a;

                self.state.agony_timer_b[i..][0..VEC_LEN].* = ago_b;
                self.state.immolate_timer_b[i..][0..VEC_LEN].* = immolate_b;
                self.state.corruption_timer_b[i..][0..VEC_LEN].* = crp_b;
                self.state.siphon_timer_b[i..][0..VEC_LEN].* = siph_b;
                self.state.fear_timer_b[i..][0..VEC_LEN].* = fear_b;
                self.state.seduction_timer_b[i..][0..VEC_LEN].* = seduction_b;
                self.state.seduced_b[i..][0..VEC_LEN].* = seduced_b;
                self.state.fear_accum_dmg_b[i..][0..VEC_LEN].* = fear_dmg_b;
                self.state.horror_timer_b[i..][0..VEC_LEN].* = horror_b;

                self.state.action6_cd_a[i..][0..VEC_LEN].* = un_cd_a;
                self.state.action6_dur_a[i..][0..VEC_LEN].* = un_dur_a;
                self.state.death_coil_cd_a[i..][0..VEC_LEN].* = dc_cd_a;
                self.state.seduction_cd_a[i..][0..VEC_LEN].* = seduction_cd_a;
                self.state.seduction_cast_a[i..][0..VEC_LEN].* = seduction_cast_a;
                self.state.fear_dr_tier_a[i..][0..VEC_LEN].* = fear_dr_t_a;
                self.state.fear_dr_timer_a[i..][0..VEC_LEN].* = fear_dr_tmr_a;
                self.state.seduction_dr_tier_a[i..][0..VEC_LEN].* = seduction_dr_t_a;
                self.state.seduction_dr_timer_a[i..][0..VEC_LEN].* = seduction_dr_tmr_a;
                self.state.horror_dr_tier_a[i..][0..VEC_LEN].* = horror_dr_t_a;
                self.state.horror_dr_timer_a[i..][0..VEC_LEN].* = horror_dr_tmr_a;

                self.state.action6_cd_b[i..][0..VEC_LEN].* = un_cd_b;
                self.state.action6_dur_b[i..][0..VEC_LEN].* = un_dur_b;
                self.state.death_coil_cd_b[i..][0..VEC_LEN].* = dc_cd_b;
                self.state.seduction_cd_b[i..][0..VEC_LEN].* = seduction_cd_b;
                self.state.seduction_cast_b[i..][0..VEC_LEN].* = seduction_cast_b;
                self.state.fear_dr_tier_b[i..][0..VEC_LEN].* = fear_dr_t_b;
                self.state.fear_dr_timer_b[i..][0..VEC_LEN].* = fear_dr_tmr_b;
                self.state.seduction_dr_tier_b[i..][0..VEC_LEN].* = seduction_dr_t_b;
                self.state.seduction_dr_timer_b[i..][0..VEC_LEN].* = seduction_dr_tmr_b;
                self.state.horror_dr_tier_b[i..][0..VEC_LEN].* = horror_dr_t_b;
                self.state.horror_dr_timer_b[i..][0..VEC_LEN].* = horror_dr_tmr_b;

                self.state.is_active[i..][0..VEC_LEN].* = v_duel_act;

                active_duels_sum += @reduce(.Add, v_duel_act);
            }

            return active_duels_sum;
        }
    };
}

fn frostAction(value: @import("spec.zig").FrostAction) u32x16 {
    return ids(@intFromEnum(value));
}

test "Warlock mirrors retain the original arena type and layout" {
    try std.testing.expect(ArenaPool(.warlock, .warlock) == combat_spec.WarlockArenaPool);
}

test "Frost Nova roots movement without preventing casts; Ice Lance shatters and breaks root" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 32);
    defer arena.deinit();
    const state = arena.combat();
    for (0..32) |lane| arena.resetDuel(lane);
    @memset(state.distance, 8);
    @memset(state.move_intent_b, -1);
    arena.applyActionA(0, frostAction(.FrostNova), splat(0));
    try std.testing.expectEqual(@as(f32, 4), state.agony_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 1), state.horror_dr_tier_b[0]);
    try std.testing.expect(arena.getActionMaskB(0)[4][0]);
    _ = arena.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(f32, 8), state.distance[0]);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 0), state.agony_timer_b[16]);
    @memset(state.gcd_a, 0);
    arena.applyActionA(0, frostAction(.IceLance), splat(0));
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    _ = arena.tickPhysics16(0.21, 0);
    try std.testing.expectEqual(@as(f32, 1700), state.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 0), state.agony_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[16]);
}

test "Frostbolt applies slow; Blink removes roots and clamps distance" {
    var arena = try ArenaPool(.frost_mage, .frost_mage).init(std.testing.allocator, 16);
    defer arena.deinit();
    const state = arena.combat();
    arena.applyActionA(0, frostAction(.Frostbolt), splat(0));
    _ = arena.tickPhysics16(1.8, 0);
    try std.testing.expectEqual(@as(f32, 2000), state.hp_b[0]);
    _ = arena.tickPhysics16(1, 0);
    try std.testing.expectEqual(@as(f32, 1760), state.hp_b[0]);
    try std.testing.expectEqual(Frost.SlowDuration, state.corruption_timer_b[0]);
    @memset(state.move_intent_b, -1);
    const distance = state.distance[0];
    _ = arena.tickPhysics16(0.1, 0);
    try std.testing.expectApproxEqAbs(distance - 0.35, state.distance[0], 0.001);
    @memset(state.agony_timer_a, 4);
    arena.applyActionA(0, frostAction(.Blink), splat(1));
    try std.testing.expectEqual(@as(f32, 35), state.distance[0]);
    try std.testing.expectEqual(@as(f32, 0), state.agony_timer_a[0]);
    try std.testing.expect(!arena.getActionMaskA(0)[5][0]);
    try std.testing.expectEqual(Frost.BlinkCooldown, arena.frostTelemetry(true, 0)[0]);
}

test "Counterspell interrupts casts and locks spells without immobilizing the target" {
    inline for (.{ true, false }) |mage_on_a| {
        var arena = try ArenaPool(if (mage_on_a) .frost_mage else .warlock, if (mage_on_a) .warlock else .frost_mage).init(std.testing.allocator, 16);
        defer arena.deinit();
        if (mage_on_a) arena.applyActionB(0, ids(4), splat(0)) else arena.applyActionA(0, ids(4), splat(0));
        if (mage_on_a) arena.applyActionA(0, frostAction(.Counterspell), splat(0)) else arena.applyActionB(0, frostAction(.Counterspell), splat(0));
        try std.testing.expectEqual(@as(u32x16, @splat(0)), arena.castIds(!mage_on_a, 0).*);
        const masks = if (mage_on_a) arena.getActionMaskB(0) else arena.getActionMaskA(0);
        try std.testing.expect(!masks[4][0]);
        try std.testing.expect(masks[0][0]);
        try std.testing.expectEqual(Frost.LockoutDuration, arena.frostTelemetry(!mage_on_a, 0)[3]);
        _ = arena.tickPhysics16(4, 0);
        try std.testing.expectEqual(@as(f32, 0), arena.frostTelemetry(!mage_on_a, 0)[3]);
    }
}

test "Ice Barrier absorbs direct and periodic Warlock damage with no extra mitigation" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    arena.applyActionA(0, frostAction(.IceBarrier), splat(0));
    arena.applyActionB(0, ids(7), splat(0));
    try std.testing.expectEqual(Frost.BarrierAbsorb, arena.frostTelemetry(true, 0)[2]);
    _ = arena.tickPhysics16(1.25, 0);
    try std.testing.expectEqual(@as(f32, 2000), arena.state.hp_a[0]);
    try std.testing.expectEqual(@as(f32, 220), arena.frostTelemetry(true, 0)[2]);
    @memset(arena.state.gcd_b, 0);
    @memset(arena.state.horror_timer_a, 0);
    arena.applyActionB(0, ids(1), splat(0));
    _ = arena.tickPhysics16(1, 0);
    try std.testing.expectEqual(@as(f32, 2000), arena.state.hp_a[0]);
    try std.testing.expectEqual(@as(f32, 190), arena.frostTelemetry(true, 0)[2]);
    _ = arena.tickPhysics16(10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1890), arena.state.hp_a[0], 0.001);
    try std.testing.expectEqual(@as(f32, 0), arena.frostTelemetry(true, 0)[2]);
    try std.testing.expectEqual(@as(f32, 0), arena.state.action6_dur_a[0]);
}

test "Polymorph incapacitates and cancels casts, breaks on damage, and obeys DR and range" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    arena.applyActionB(0, ids(4), splat(0));
    arena.applyActionA(0, frostAction(.Polymorph), splat(0));
    _ = arena.tickPhysics16(1.5, 0);
    try std.testing.expectEqual(@as(f32, 4), arena.state.fear_timer_b[0]);
    try std.testing.expectEqual(@as(u32, 0), arena.state.cast_id_b[0]);
    @memset(arena.state.gcd_a, 0);
    arena.applyActionA(0, frostAction(.IceLance), splat(0));
    try std.testing.expect(arena.state.fear_timer_b[0] > 0);
    _ = arena.tickPhysics16(0.9, 0);
    try std.testing.expectEqual(@as(f32, 0), arena.state.fear_timer_b[0]);
    arena.applyActionA(0, frostAction(.Polymorph), splat(0)); // GCD blocks this action.
    try std.testing.expectEqual(@as(u32, 0), arena.state.cast_id_a[0]);
    @memset(arena.state.gcd_a, 0);
    arena.applyActionA(0, frostAction(.Polymorph), splat(0));
    _ = arena.tickPhysics16(1.5, 0);
    try std.testing.expectEqual(@as(f32, 2), arena.state.fear_timer_b[0]);
    @memset(arena.state.distance, 35);
    @memset(arena.state.gcd_a, 0);
    try std.testing.expect(!arena.getActionMaskA(0)[3][0]);
}

test "Barrier absorbs full incoming hits even when remaining HP is below the hit" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    @memset(arena.state.hp_a, 40);
    arena.applyActionA(0, frostAction(.IceBarrier), splat(0));
    arena.applyActionB(0, ids(7), splat(0));
    _ = arena.tickPhysics16(1.25, 0);
    try std.testing.expectEqual(@as(f32, 40), arena.state.hp_a[0]);
    try std.testing.expectEqual(@as(f32, 220), arena.frostTelemetry(true, 0)[2]);
}

test "A dead target cannot cast or heal itself after a projectile kills it" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    @memset(arena.state.hp_b, 50);
    arena.applyActionA(0, frostAction(.IceLance), splat(0));
    try std.testing.expect(arena.getActionMaskB(0)[7][0]);
    _ = arena.tickPhysics16(0.7, 0);
    try std.testing.expect(!arena.getActionMaskB(0)[7][0]);
    arena.applyActionB(0, ids(7), splat(0));
    try std.testing.expectEqual(@as(f32, 0), arena.state.hp_b[0]);
    _ = arena.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(u32, 0), arena.state.is_active[0]);
}

test "2D advance follows opponent heading without voluntary strafe" {
    var arena = try ArenaPool(.warlock, .frost_mage).init(std.testing.allocator, 16);
    defer arena.deinit();
    const state = arena.combat();
    @memset(state.pos_x_a, 0);
    @memset(state.pos_y_a, 0);
    @memset(state.pos_x_b, 15);
    @memset(state.pos_y_b, 20);
    @memset(state.move_intent_a, -1);
    _ = arena.tickPhysics16(0.1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), state.pos_x_a[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.56), state.pos_y_a[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 24.3), state.distance[0], 0.0001);
}

test "Fear and Polymorph wander in both axes with normalized speed" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |source| {
        var arena = try ArenaPool(source, .warlock).init(std.testing.allocator, 16);
        defer arena.deinit();
        const state = arena.combat();
        @memset(state.fear_timer_b, 6);
        var positive_x = false;
        var negative_x = false;
        var positive_y = false;
        var negative_y = false;
        for (0..500) |_| {
            const old_distance = state.distance[0];
            const x = state.pos_x_b[0];
            const y = state.pos_y_b[0];
            _ = arena.tickPhysics16(0.01, 0);
            const dx = state.pos_x_b[0] - x;
            const dy = state.pos_y_b[0] - y;
            positive_x = positive_x or dx > 0.0001;
            negative_x = negative_x or dx < -0.0001;
            positive_y = positive_y or dy > 0.0001;
            negative_y = negative_y or dy < -0.0001;
            const speed: f32 = if (source == .warlock) 7 else 2.5;
            if (old_distance > 1.1 and old_distance < 34.9 and state.distance[0] > 1.1 and state.distance[0] < 34.9)
                try std.testing.expectApproxEqAbs(speed * 0.01, @sqrt(dx * dx + dy * dy), 0.0001);
            const gx = state.pos_x_b[0] - state.pos_x_a[0];
            const gy = state.pos_y_b[0] - state.pos_y_a[0];
            try std.testing.expectApproxEqAbs(state.distance[0], @sqrt(gx * gx + gy * gy), 0.0001);
        }
        try std.testing.expect(positive_x and negative_x and positive_y and negative_y);
    }
}

test "Blink moves the casting mage along the 2D opponent axis" {
    var arena = try ArenaPool(.frost_mage, .warlock).init(std.testing.allocator, 16);
    defer arena.deinit();
    const state = arena.combat();
    @memset(state.pos_x_a, 0);
    @memset(state.pos_y_a, 0);
    @memset(state.pos_x_b, 15);
    @memset(state.pos_y_b, 20);
    arena.applyActionA(0, frostAction(.Blink), splat(-1));
    try std.testing.expectApproxEqAbs(@as(f32, 9), state.pos_x_a[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 12), state.pos_y_a[0], 0.0001);
    try std.testing.expectEqual(@as(f32, 15), state.pos_x_b[0]);
    try std.testing.expectEqual(@as(f32, 20), state.pos_y_b[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 10), state.distance[0], 0.0001);
}
