//! Complete deterministic combat snapshots and simultaneous external actions.
const std = @import("std");
const combat = @import("combat_spec.zig");
const action_catalog = @import("action_catalog_generated.zig");
const Spec = @import("spec.zig").Spec;
const warlock_talents = @import("warlock_talents.zig");
const fields = std.meta.fields(combat.WarlockArenaPool);
pub const columns = fields.len - 7; // omit the immutable per-spec talent columns
fn snapshotIndex(comptime offset: usize) usize {
    var result: usize = 0;
    inline for (fields[3..], 0..) |field, index| {
        if (index < offset and !std.mem.startsWith(u8, field.name, "talent_ranks_") and !std.mem.startsWith(u8, field.name, "talent_flags_")) result += 1;
    }
    return result;
}
const ActionWrite = enum { unchanged, owner, shared };
// Staged action kernels launch into their own queues; impact telemetry and
// physics-only CC bookkeeping are never changed by an action. Geometry remains
// shared because launch synchronization and Blink can move both positions.
fn actionWrite(comptime name: []const u8) ActionWrite {
    if ((std.mem.startsWith(u8, name, "pet_rng_") or std.mem.startsWith(u8, name, "pet_outcome_"))) return .owner;
    if (std.mem.startsWith(u8, name, "pet_") or std.mem.startsWith(u8, name, "impact_") or std.mem.eql(u8, name, "is_active")) return .unchanged;
    if (std.mem.startsWith(u8, name, "talent_ranks_") or std.mem.startsWith(u8, name, "talent_flags_")) return .unchanged;
    inline for (.{ "fear_timer_", "fear_accum_dmg_", "fear_dr_", "horror_timer_" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return .unchanged;
    }
    inline for (.{ "projectile_", "mana_", "gcd_", "move_intent_", "action6_", "death_coil_cd_", "shadowburn_cd_", "soul_shards_", "conflagrate_", "spell_rng_", "spell_outcome_", "shadow_flame_timer_", "cast_pushback_count_", "channel_elapsed_", "pushback_rng_" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return .owner;
    }
    return .shared;
}
pub const Snapshot = struct {
    words: [columns]u32,
    extras: [10]f32 = @splat(0),
    tick: u32 = 0,
};
fn simdMask(ready: @Vector(16, bool), actions: @Vector(16, u32)) @Vector(16, bool) {
    return @select(bool, ready, actions == @as(@Vector(16, u32), @splat(5)), @as(@Vector(16, bool), @splat(false)));
}
pub const Action = struct { ability: u32 = 0, movement: f32 = 0 };
pub const Choices = struct {
    items: [action_catalog.MaxChoices]Action = @splat(.{}),
    len: u8 = 0,
    pub fn add(self: *Choices, a: Action) void {
        self.items[self.len] = a;
        self.len += 1;
    }
};
pub fn Duel(comptime a: Spec, comptime b: Spec) type {
    return struct {
        const Self = @This();
        const Arena = @import("multi_spec.zig").ArenaPool(a, b);
        arena: Arena,
        scratch: Arena,
        original: Arena,
        warlock_effects_a: warlock_talents.Effects,
        warlock_effects_b: warlock_talents.Effects,
        allowed_actions_a: u32 = std.math.maxInt(u32),
        allowed_actions_b: u32 = std.math.maxInt(u32),
        ticks: [16]u32 = @splat(0),
        pub fn init(allocator: std.mem.Allocator) !Self {
            var arena = try Arena.init(allocator, 16);
            errdefer arena.deinit();
            var scratch = try Arena.init(allocator, 16);
            errdefer scratch.deinit();
            const original = try Arena.init(allocator, 16);
            const empty_effects = warlock_talents.decode(@splat(0), @splat(0));
            var self: Self = .{ .arena = arena, .scratch = scratch, .original = original, .warlock_effects_a = empty_effects, .warlock_effects_b = empty_effects };
            for (0..16) |i| self.arena.resetDuel(i);
            return self;
        }
        /// Player A acts at t=0; B becomes ready at t=10ms. Both timers are
        /// needed because tick boundaries also wake on an expired GCD.
        pub fn staggerOpening(self: *Self) void {
            @memset(self.arena.combat().gcd_b, 0.01);
            @memset(self.arena.combat().react_timer_b, 0.01);
        }
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.scratch.deinit();
            self.original.deinit();
        }
        pub fn setWarlockTalentRanksA(self: *Self, encoded: u64) void {
            inline for (.{ &self.arena, &self.scratch, &self.original }) |pool| {
                const state = pool.combat();
                const low: u32 = @truncate(encoded);
                const high: u32 = @truncate(encoded >> 32);
                @memset(state.talent_ranks_a[0..16], low);
                @memset(state.talent_flags_a[0..16], high);
                @memset(state.soul_link_a[0..16], @intFromBool((encoded & (@as(u64, 1) << 17)) != 0));
            }
            self.warlock_effects_a = warlock_talents.decode(@splat(@truncate(encoded)), @splat(@truncate(encoded >> 32)));
        }
        pub fn setWarlockTalentRanksB(self: *Self, encoded: u64) void {
            inline for (.{ &self.arena, &self.scratch, &self.original }) |pool| {
                const state = pool.combat();
                const low: u32 = @truncate(encoded);
                const high: u32 = @truncate(encoded >> 32);
                @memset(state.talent_ranks_b[0..16], low);
                @memset(state.talent_flags_b[0..16], high);
                @memset(state.soul_link_b[0..16], @intFromBool((encoded & (@as(u64, 1) << 17)) != 0));
            }
            self.warlock_effects_b = warlock_talents.decode(@splat(@truncate(encoded)), @splat(@truncate(encoded >> 32)));
        }
        pub fn setCombatStats(self: *Self, comptime side: bool, stats: @import("spell_resolution.zig").Stats) !void {
            try stats.validate();
            inline for (.{ &self.arena, &self.scratch, &self.original }) |pool| {
                for (0..16) |lane| @import("spell_resolution.zig").setStats(pool.combat(), side, lane, stats);
            }
        }
        pub fn setActionMaskA(self: *Self, mask: u32) void {
            self.allowed_actions_a = mask | reservedActionBits(a);
        }
        pub fn setActionMaskB(self: *Self, mask: u32) void {
            self.allowed_actions_b = mask | reservedActionBits(b);
        }
        fn reservedActionBits(comptime spec: Spec) u32 {
            const idle_id: u5 = if (spec == .warlock) @intCast(@intFromEnum(combat.WarlockAction.IdleOrManeuver)) else @intCast(@intFromEnum(@import("spec.zig").FrostAction.IdleOrManeuver));
            const cancel_id: u5 = if (spec == .warlock) @intCast(@intFromEnum(combat.WarlockAction.CancelCast)) else @intCast(@intFromEnum(@import("spec.zig").FrostAction.CancelCast));
            return (@as(u32, 1) << idle_id) | (@as(u32, 1) << cancel_id);
        }
        fn filterActions(mask: u32, masks: [combat.WarlockAction.COUNT]@Vector(16, bool)) [combat.WarlockAction.COUNT]@Vector(16, bool) {
            var result = masks;
            inline for (0..combat.WarlockAction.COUNT) |id| {
                if ((mask & (@as(u32, 1) << id)) == 0) result[id] = @splat(false);
            }
            return result;
        }
        pub fn getActionMaskA(self: *const Self, lane: usize) [combat.WarlockAction.COUNT]@Vector(16, bool) {
            return filterActions(self.allowed_actions_a, self.arena.getActionMaskA(lane));
        }
        pub fn getActionMaskB(self: *const Self, lane: usize) [combat.WarlockAction.COUNT]@Vector(16, bool) {
            return filterActions(self.allowed_actions_b, self.arena.getActionMaskB(lane));
        }
        pub fn snapshot(self: *Self, lane: usize) Snapshot {
            var s: Snapshot = .{ .words = undefined, .tick = self.ticks[lane] };
            inline for (fields[3..], 0..) |f, j| {
                if (comptime !std.mem.startsWith(u8, f.name, "talent_ranks_") and !std.mem.startsWith(u8, f.name, "talent_flags_")) s.words[snapshotIndex(j)] = @bitCast(@field(self.arena.combat(), f.name)[lane]);
            }
            if (@hasField(Arena, "extras")) inline for (0..10) |j| {
                s.extras[j] = self.arena.extras[j * 16 + lane];
            };
            return s;
        }
        pub fn restore(self: *Self, lane: usize, s: Snapshot) void {
            inline for (fields[3..], 0..) |f, j| {
                if (comptime !std.mem.startsWith(u8, f.name, "talent_ranks_") and !std.mem.startsWith(u8, f.name, "talent_flags_")) @field(self.arena.combat(), f.name)[lane] = @bitCast(s.words[snapshotIndex(j)]);
            }
            if (@hasField(Arena, "extras")) inline for (0..10) |j| {
                self.arena.extras[j * 16 + lane] = s.extras[j];
            };
            self.ticks[lane] = s.tick;
        }
        pub fn ready(self: *Self, comptime side: bool) @Vector(16, bool) {
            const result = if (side) self.arena.needsDecisionA(0) else self.arena.needsDecisionB(0);
            return @select(bool, result, self.arena.combat().is_active[0..16].* != @as(@Vector(16, u32), @splat(0)), @as(@Vector(16, bool), @splat(false)));
        }
        pub fn readyTactical(self: *Self, comptime side: bool) @Vector(16, bool) {
            const result = if (side) self.arena.needsTacticalDecisionA(0) else self.arena.needsTacticalDecisionB(0);
            return @select(bool, result, self.arena.combat().is_active[0..16].* != @as(@Vector(16, u32), @splat(0)), @as(@Vector(16, bool), @splat(false)));
        }
        pub fn choices(self: *Self, comptime side: bool, lane: usize, masks: [combat.WarlockAction.COUNT]@Vector(16, bool)) Choices {
            var c: Choices = .{};
            const state = self.arena.combat();
            const suffix = if (side) "_a" else "_b";
            if (!self.ready(side)[lane]) {
                c.add(.{ .movement = @field(state, "move_intent" ++ suffix)[lane] });
                return c;
            }
            const controlled = @field(state, "fear_timer" ++ suffix)[lane] > 0 or
                @field(state, "horror_timer" ++ suffix)[lane] > 0 or
                @field(state, "seduction_timer" ++ suffix)[lane] > 0;
            // Keep a no-op available under CC so an off-GCD pet command such as
            // Seduction is a choice, rather than the forced action.
            if (controlled) c.add(.{});
            for (0..combat.WarlockAction.COUNT) |id| {
                if (!masks[id][lane]) continue;
                // The action kernels force movement to zero during an existing cast.
                // Action 10 is Cancel Cast which can be used to stop casting.
                const casting = @field(state, "cast_id" ++ suffix)[lane] != 0 and id != 10 and !((if (side) a else b) == .frost_mage and id == 5);
                const actor = if (side) a else b;
                const starts_cast = if (actor == .warlock) action_catalog.warlock_starts_cast[id] else action_catalog.frost_mage_starts_cast[id];
                if (controlled or casting or starts_cast) c.add(.{ .ability = @intCast(id) }) else for ([_]f32{ -1, 0, 1 }) |m| c.add(.{ .ability = @intCast(id), .movement = m });
            }
            if (c.len == 0) c.add(.{}); // Forced no-op while controlled.
            return c;
        }
        pub fn choicesTactical(self: *Self, comptime side: bool, lane: usize, masks: [combat.WarlockAction.COUNT]@Vector(16, bool)) Choices {
            var c: Choices = .{};
            const state = self.arena.combat();
            const suffix = if (side) "_a" else "_b";
            if (!self.readyTactical(side)[lane]) {
                c.add(.{ .movement = @field(state, "move_intent" ++ suffix)[lane] });
                return c;
            }
            const controlled = @field(state, "fear_timer" ++ suffix)[lane] > 0 or
                @field(state, "horror_timer" ++ suffix)[lane] > 0 or
                @field(state, "seduction_timer" ++ suffix)[lane] > 0;
            // Keep a no-op available under CC so an off-GCD pet command such as
            // Seduction is a choice, rather than the forced action.
            if (controlled) c.add(.{});
            for (0..combat.WarlockAction.COUNT) |id| {
                if (!masks[id][lane]) continue;
                const casting = @field(state, "cast_id" ++ suffix)[lane] != 0 and id != 10 and !((if (side) a else b) == .frost_mage and id == 5);
                const actor = if (side) a else b;
                const starts_cast = if (actor == .warlock) action_catalog.warlock_starts_cast[id] else action_catalog.frost_mage_starts_cast[id];
                if (controlled or casting or starts_cast) c.add(.{ .ability = @intCast(id) }) else for ([_]f32{ -1, 0, 1 }) |m| c.add(.{ .ability = @intCast(id), .movement = m });
            }
            if (c.len == 0) c.add(.{});
            return c;
        }
        /// Each action resolves against the same pre-action state. Own resource/cast
        /// changes combine with enemy effects; enemy interruptions win conflicts.
        /// Damage/healing and displacement add; new defenses protect from next tick.
        /// No action is applied for a fighter whose reaction boundary is not ready.
        pub fn apply(self: *Self, aa: [16]Action, bb: [16]Action) void {
            self.applyMasked(aa, bb, self.ready(true), self.ready(false));
        }
        pub fn applyTactical(self: *Self, aa: [16]Action, bb: [16]Action) void {
            self.applyMasked(aa, bb, self.readyTactical(true), self.readyTactical(false));
        }
        pub fn applyMasked(self: *Self, aa: [16]Action, bb: [16]Action, ra: @Vector(16, bool), rb: @Vector(16, bool)) void {
            // A lane-specific split would still run both SIMD action kernels.
            // Bypass staging only when an entire side of the batch is idle.
            const any_a = @reduce(.Or, ra);
            const any_b = @reduce(.Or, rb);
            if (any_a and !any_b) return self.applyOneSided(true, aa, ra);
            if (any_b and !any_a) return self.applyOneSided(false, bb, rb);
            self.applyMaskedStagingBaseline(aa, bb, ra, rb);
        }
        /// Suggestion 1 baseline, without the one-sided dispatch.
        pub fn applyMaskedStagingBaseline(self: *Self, aa: [16]Action, bb: [16]Action, ra: @Vector(16, bool), rb: @Vector(16, bool)) void {
            self.applyMaskedImpl(aa, bb, ra, rb, true);
        }
        // Retain the full merge as a correctness oracle and timing baseline.
        pub fn applyMaskedReference(self: *Self, aa: [16]Action, bb: [16]Action, ra: @Vector(16, bool), rb: @Vector(16, bool)) void {
            self.applyMaskedImpl(aa, bb, ra, rb, false);
        }
        fn applyOneSided(self: *Self, comptime side_a: bool, requested: [16]Action, ready_mask: @Vector(16, bool)) void {
            @setEvalBranchQuota(40000);
            const legal = if (side_a) self.getActionMaskA(0) else self.getActionMaskB(0);
            var actions: @Vector(16, u32) = undefined;
            var movement: @Vector(16, f32) = undefined;
            for (0..16) |lane| {
                actions[lane] = if (requested[lane].ability < combat.WarlockAction.COUNT and legal[requested[lane].ability][lane]) requested[lane].ability else 0;
                movement[lane] = requested[lane].movement;
            }
            // Preserve only possible writes. The other caster's owned columns
            // are untouched. No scratch arena or second action kernel is needed.
            inline for (fields[3..]) |f| {
                if (comptime actionWrite(f.name) == .unchanged or
                    (actionWrite(f.name) == .owner and std.mem.endsWith(u8, f.name, "_a") != side_a)) continue;
                @memcpy(@field(self.original.combat(), f.name), @field(self.arena.combat(), f.name));
            }
            if (@hasField(Arena, "extras")) @memcpy(self.original.extras, self.arena.extras);
            if (side_a) self.arena.stageActionA(0, actions, movement) else self.arena.stageActionB(0, actions, movement);
            inline for (fields[3..]) |f| {
                if (comptime actionWrite(f.name) == .unchanged or
                    (actionWrite(f.name) == .owner and std.mem.endsWith(u8, f.name, "_a") != side_a)) continue;
                const T = std.meta.Child(f.type);
                const V = @Vector(16, T);
                const old: V = @field(self.original.combat(), f.name)[0..16].*;
                var value = @select(T, ready_mask, @as(V, @field(self.arena.combat(), f.name)[0..16].*), old);
                // Match the original delta arithmetic and clamping exactly.
                if (comptime std.mem.startsWith(u8, f.name, "hp_") or std.mem.eql(u8, f.name, "distance")) {
                    const x = if (side_a) value else old;
                    const y = if (side_a) old else value;
                    value = @min(@as(V, @splat(if (std.mem.eql(u8, f.name, "distance")) 35 else 2000)), @max(@as(V, @splat(0)), old + (x - old) + (y - old)));
                }
                @field(self.arena.combat(), f.name)[0..16].* = value;
            }
            if ((if (side_a) a else b) == .frost_mage and @reduce(.Or, simdMask(ready_mask, actions)))
                _ = @import("movement_2d.zig").refresh(self.arena.combat(), 0, true);
            if (@hasField(Arena, "extras")) inline for (0..10) |j| {
                const V = @Vector(16, f32);
                const old: V = self.original.extras[j * 16 ..][0..16].*;
                var value = @select(f32, ready_mask, @as(V, self.arena.extras[j * 16 ..][0..16].*), old);
                if (j % 5 == 2) {
                    const x = if (side_a) value else old;
                    const y = if (side_a) old else value;
                    value = @max(@as(V, @splat(0)), old + (x - old) + (y - old));
                }
                self.arena.extras[j * 16 ..][0..16].* = value;
            };
        }
        fn applyMaskedImpl(self: *Self, aa: [16]Action, bb: [16]Action, ra: @Vector(16, bool), rb: @Vector(16, bool), comptime optimized: bool) void {
            @setEvalBranchQuota(40000);
            const cast_before_a = self.arena.combat().cast_id_a[0..16].*;
            const cast_before_b = self.arena.combat().cast_id_b[0..16].*;
            const legal_a = self.getActionMaskA(0);
            const legal_b = self.getActionMaskB(0);
            var va: @Vector(16, u32) = undefined;
            var vb: @Vector(16, u32) = undefined;
            var ma: @Vector(16, f32) = undefined;
            var mb: @Vector(16, f32) = undefined;
            inline for (fields[3..]) |f| {
                if (!optimized or !std.mem.startsWith(u8, f.name, "impact_"))
                    @memcpy(@field(self.scratch.combat(), f.name), @field(self.arena.combat(), f.name));
                if (!optimized or actionWrite(f.name) != .unchanged)
                    @memcpy(@field(self.original.combat(), f.name), @field(self.arena.combat(), f.name));
            }
            if (@hasField(Arena, "extras")) {
                @memcpy(self.scratch.extras, self.arena.extras);
                @memcpy(self.original.extras, self.arena.extras);
            }
            for (0..16) |i| {
                va[i] = if (aa[i].ability < combat.WarlockAction.COUNT and legal_a[aa[i].ability][i]) aa[i].ability else 0;
                vb[i] = if (bb[i].ability < combat.WarlockAction.COUNT and legal_b[bb[i].ability][i]) bb[i].ability else 0;
                ma[i] = aa[i].movement;
                mb[i] = bb[i].movement;
            }
            self.arena.stageActionA(0, va, ma);
            self.scratch.stageActionB(0, vb, mb);
            inline for (fields[3..]) |f| {
                if (comptime optimized and actionWrite(f.name) == .unchanged) continue;
                const T = std.meta.Child(f.type);
                const V = @Vector(16, T);
                const old: V = @field(self.original.combat(), f.name)[0..16].*;
                const x = @select(T, ra, @as(V, @field(self.arena.combat(), f.name)[0..16].*), old);
                const y = @select(T, rb, @as(V, @field(self.scratch.combat(), f.name)[0..16].*), old);
                const own_a = comptime std.mem.endsWith(u8, f.name, "_a");
                var value = if (comptime optimized and actionWrite(f.name) == .owner)
                    (if (own_a) x else y)
                else if (own_a) @select(T, y != old, y, x) else @select(T, x != old, x, y);
                if (comptime std.mem.startsWith(u8, f.name, "hp_")) value = @min(@as(V, @splat(2000)), @max(@as(V, @splat(0)), old + (x - old) + (y - old)));
                if (comptime std.mem.eql(u8, f.name, "distance")) value = @min(@as(V, @splat(35)), @max(@as(V, @splat(0)), old + (x - old) + (y - old)));
                @field(self.arena.combat(), f.name)[0..16].* = value;
            }
            if ((a == .frost_mage and @reduce(.Or, simdMask(ra, va))) or (b == .frost_mage and @reduce(.Or, simdMask(rb, vb))))
                _ = @import("movement_2d.zig").refresh(self.arena.combat(), 0, true);
            // Interrupt is an event even when its reset timer already equals zero.
            for (0..16) |i| {
                if (b == .warlock and rb[i] and vb[i] == 15 and cast_before_a[i] != 0 and self.scratch.combat().pet_outcome_b[i] == @intFromEnum(@import("spell_resolution.zig").Outcome.hit)) self.arena.combat().react_timer_a[i] = 0;
                if (a == .warlock and ra[i] and va[i] == 15 and cast_before_b[i] != 0 and self.arena.combat().pet_outcome_a[i] == @intFromEnum(@import("spell_resolution.zig").Outcome.hit)) self.arena.combat().react_timer_b[i] = 0;
                if (b == .frost_mage and rb[i] and vb[i] == 7 and cast_before_a[i] != 0 and self.scratch.combat().spell_outcome_b[i] == @intFromEnum(@import("spell_resolution.zig").Outcome.hit)) self.arena.combat().react_timer_a[i] = 0;
                if (a == .frost_mage and ra[i] and va[i] == 7 and cast_before_b[i] != 0 and self.arena.combat().spell_outcome_a[i] == @intFromEnum(@import("spell_resolution.zig").Outcome.hit)) self.arena.combat().react_timer_b[i] = 0;
            }
            if (@hasField(Arena, "extras")) inline for (0..10) |j| {
                const V = @Vector(16, f32);
                const old: V = self.original.extras[j * 16 ..][0..16].*;
                const x = @select(f32, ra, @as(V, self.arena.extras[j * 16 ..][0..16].*), old);
                const y = @select(f32, rb, @as(V, self.scratch.extras[j * 16 ..][0..16].*), old);
                self.arena.extras[j * 16 ..][0..16].* = if (j % 5 == 2) @max(@as(V, @splat(0)), old + (x - old) + (y - old)) else if (j < 5) @select(f32, y != old, y, x) else @select(f32, x != old, x, y);
            };
        }
        pub fn tick(self: *Self, limit: u32) void {
            _ = self.arena.tickPhysics16WithEffects(0.01, 0, &self.warlock_effects_a, &self.warlock_effects_b);
            for (0..16) |i| {
                self.ticks[i] += 1;
                if (self.ticks[i] >= limit) self.arena.combat().is_active[i] = 0;
            }
        }
        pub fn reward(self: *Self, i: usize) f32 {
            const s = self.arena.combat();
            return if (s.hp_a[i] > 0 and s.hp_b[i] <= 0) 1 else if (s.hp_b[i] > 0 and s.hp_a[i] <= 0) -1 else 0;
        }
    };
}
test "one-sided batches match full staging for both actors and every requested action" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |a| inline for (.{ Spec.warlock, Spec.frost_mage }) |b| {
        var fast = try Duel(a, b).init(std.testing.allocator);
        defer fast.deinit();
        var reference = try Duel(a, b).init(std.testing.allocator);
        defer reference.deinit();
        inline for (.{ true, false }) |side_a| for (0..11) |ability| {
            for (0..16) |lane| {
                fast.arena.resetDuel(lane);
                const state = fast.arena.combat();
                state.distance[lane] = @floatFromInt(3 + lane * 2);
                state.cast_id_a[lane] = if (!side_a or lane % 4 == 1) 4 else 0;
                state.cast_id_b[lane] = if (side_a or lane % 4 == 1) 4 else 0;
                state.cast_timer_a[lane] = 0.5;
                state.cast_timer_b[lane] = 0.5;
                state.cast_total_a[lane] = 1.8;
                state.cast_total_b[lane] = 1.8;
                state.move_intent_a[lane] = 1;
                state.move_intent_b[lane] = -1;
                state.react_timer_a[lane] = 0;
                state.react_timer_b[lane] = 0;
                state.projectile_0_spell_a[lane] = 4;
                state.projectile_0_spell_b[lane] = 4;
                state.projectile_0_damage_a[lane] = 240;
                state.projectile_0_damage_b[lane] = 240;
                state.projectile_count_a[lane] = 1;
                state.projectile_count_b[lane] = 1;
                state.impact_bolt_a[lane] = 12;
                state.impact_mask_a[lane] = 1;
                if (lane % 4 == 2) {
                    state.mana_a[lane] = 0;
                    state.mana_b[lane] = 0;
                }
                reference.restore(lane, fast.snapshot(lane));
            }
            var ready_mask: @Vector(16, bool) = undefined;
            var actions: [16]Action = undefined;
            for (0..16) |lane| {
                ready_mask[lane] = lane % 3 != 0;
                actions[lane] = .{ .ability = @intCast(ability), .movement = if (lane % 2 == 0) -1 else 1 };
            }
            const ra = if (side_a) ready_mask else @as(@Vector(16, bool), @splat(false));
            const rb = if (side_a) @as(@Vector(16, bool), @splat(false)) else ready_mask;
            fast.applyMasked(actions, actions, ra, rb);
            reference.applyMaskedReference(actions, actions, ra, rb);
            for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
            for (0..20) |_| {
                fast.tick(6000);
                reference.tick(6000);
                for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
            }
        };
    };
}
test "narrow action staging matches full staging across kits and divergent lanes" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |a| inline for (.{ Spec.warlock, Spec.frost_mage }) |b| {
        var fast = try Duel(a, b).init(std.testing.allocator);
        defer fast.deinit();
        var reference = try Duel(a, b).init(std.testing.allocator);
        defer reference.deinit();
        var rng = std.Random.DefaultPrng.init(947);
        const random = rng.random();
        for (0..1200) |step| {
            // Periodic fresh states exercise instant actions and launches beyond
            // terminal deaths; divergent lanes cover one-sided readiness.
            if (step % 200 == 0) for (0..16) |lane| {
                fast.arena.resetDuel(lane);
                fast.arena.combat().distance[lane] = @floatFromInt(3 + lane * 2);
                fast.arena.combat().gcd_b[lane] = if (lane % 2 == 0) 0.1 else 0;
                reference.restore(lane, fast.snapshot(lane));
            };
            const ra = fast.ready(true);
            const rb = fast.ready(false);
            const masks_a = fast.getActionMaskA(0);
            const masks_b = fast.getActionMaskB(0);
            var aa: [16]Action = undefined;
            var bb: [16]Action = undefined;
            for (0..16) |lane| {
                const ca = fast.choices(true, lane, masks_a);
                const cb = fast.choices(false, lane, masks_b);
                aa[lane] = ca.items[random.uintLessThan(u8, ca.len)];
                bb[lane] = cb.items[random.uintLessThan(u8, cb.len)];
            }
            fast.applyMasked(aa, bb, ra, rb);
            reference.applyMaskedReference(aa, bb, ra, rb);
            for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
            fast.tick(6000);
            reference.tick(6000);
            for (0..16) |lane| try std.testing.expectEqualDeep(reference.snapshot(lane), fast.snapshot(lane));
        }
    };
}
test "complete snapshot restores every lane and both kits exactly" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |a| inline for (.{ Spec.warlock, Spec.frost_mage }) |b| {
        var d = try Duel(a, b).init(std.testing.allocator);
        defer d.deinit();
        const s = d.snapshot(0);
        d.apply(@splat(.{ .ability = 1 }), @splat(.{ .ability = 1 }));
        d.tick(3000);
        const next = d.snapshot(0);
        for (0..16) |i| d.restore(i, s);
        d.apply(@splat(.{ .ability = 1 }), @splat(.{ .ability = 1 }));
        d.tick(3000);
        for (0..16) |i| try std.testing.expectEqualDeep(next, d.snapshot(i));
    };
}
test "simultaneous coil impacts and one-sided readiness" {
    var d = try Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.arena.hp_a[0] = 100;
    d.arena.hp_b[0] = 100;
    d.apply(@splat(.{ .ability = 7 }), @splat(.{ .ability = 7 }));
    try std.testing.expectEqual(d.arena.hp_a[0], d.arena.hp_b[0]);
    try std.testing.expectEqual(@as(f32, 100), d.arena.hp_a[0]);
    for (0..126) |_| d.tick(3000);
    try std.testing.expectEqual(@as(f32, 220), d.arena.hp_a[0]);
    try std.testing.expectEqual(d.arena.hp_a[0], d.arena.hp_b[0]);
    d.arena.react_timer_b[0] = 0.07;
    d.arena.gcd_b[0] = 0.5;
    d.arena.move_intent_b[0] = 1;
    d.apply(@splat(.{}), @splat(.{ .movement = -1 }));
    try std.testing.expectEqual(@as(f32, 0.07), d.arena.react_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 1), d.arena.move_intent_b[0]);
}

test "simultaneous swaps preserve mirror states, including overlapping instant effects" {
    @setEvalBranchQuota(40000);
    inline for (.{ Spec.warlock, Spec.frost_mage }) |spec| {
        var x = try Duel(spec, spec).init(std.testing.allocator);
        defer x.deinit();
        var y = try Duel(spec, spec).init(std.testing.allocator);
        defer y.deinit();
        // Random streams belong to fighters and must swap with their state.
        @memcpy(y.arena.combat().spell_rng_a, x.arena.combat().spell_rng_b);
        @memcpy(y.arena.combat().spell_rng_b, x.arena.combat().spell_rng_a);
        @memcpy(y.arena.combat().pet_rng_a, x.arena.combat().pet_rng_b);
        @memcpy(y.arena.combat().pet_rng_b, x.arena.combat().pet_rng_a);
        @memcpy(y.arena.combat().pushback_rng_a, x.arena.combat().pushback_rng_b);
        @memcpy(y.arena.combat().pushback_rng_b, x.arena.combat().pushback_rng_a);
        var rng = std.Random.DefaultPrng.init(104);
        const random = rng.random();
        for (0..1200) |_| {
            const ca = x.choices(true, 0, x.getActionMaskA(0));
            const cb = x.choices(false, 0, x.getActionMaskB(0));
            const aa = ca.items[random.uintLessThan(u8, ca.len)];
            const bb = cb.items[random.uintLessThan(u8, cb.len)];
            x.apply(@splat(aa), @splat(bb));
            y.apply(@splat(bb), @splat(aa));
            x.tick(6000);
            y.tick(6000);
            inline for (fields[3..]) |f| {
                if (comptime std.mem.endsWith(u8, f.name, "_a")) {
                    const other = f.name[0 .. f.name.len - 1] ++ "b";
                    if (comptime std.mem.startsWith(u8, f.name, "pos_") or (std.mem.startsWith(u8, f.name, "projectile_") and (std.mem.endsWith(u8, f.name, "_x_a") or std.mem.endsWith(u8, f.name, "_y_a")))) {
                        try std.testing.expectApproxEqAbs(@field(x.arena.combat(), f.name)[0], -@field(y.arena.combat(), other)[0], 0.0001);
                    } else {
                        try std.testing.expectEqual(@field(x.arena.combat(), f.name)[0], @field(y.arena.combat(), other)[0]);
                    }
                }
            }
            try std.testing.expectEqual(x.arena.combat().distance[0], y.arena.combat().distance[0]);
        }
    }
}
test "external actions obey masks and terminal reward semantics" {
    var d = try Duel(.warlock, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.arena.mana_a[0] = 0;
    d.apply(@splat(.{ .ability = 7 }), @splat(.{}));
    try std.testing.expectEqual(@as(f32, 2000), d.arena.hp_b[0]);
    d.arena.hp_b[0] = 0;
    try std.testing.expectEqual(@as(f32, 1), d.reward(0));
    d.arena.hp_a[0] = 0;
    try std.testing.expectEqual(@as(f32, 0), d.reward(0));
    d.arena.hp_b[0] = 100;
    try std.testing.expectEqual(@as(f32, -1), d.reward(0));
    d.arena.hp_a[0] = 100;
    d.tick(1);
    try std.testing.expectEqual(@as(f32, 0), d.reward(0));
}

test "simultaneous counterspell preserves a hard-stop timer reset" {
    var d = try Duel(.warlock, .frost_mage).init(std.testing.allocator);
    defer d.deinit();
    const s = d.arena.combat();
    s.cast_id_a[0] = 4;
    s.cast_timer_a[0] = 0.5;
    s.cast_total_a[0] = 1.8;
    s.gcd_a[0] = 0.5;
    d.apply(@splat(.{}), @splat(.{ .ability = 7 }));
    try std.testing.expectEqual(@as(u32, 0), s.cast_id_a[0]);
    try std.testing.expectEqual(@as(f32, 0), s.react_timer_a[0]);
}

test "10ms opening lead staggers casts and prevents mirrored control trades" {
    inline for (.{ Spec.warlock, Spec.frost_mage }) |kit| {
        inline for (.{ false, true }) |tactical| {
            var d = try Duel(kit, kit).init(std.testing.allocator);
            defer d.deinit();
            d.staggerOpening();
            const state = d.arena.combat();
            @memset(state.distance, 15);
            @memset(state.pos_x_a, -7.5);
            @memset(state.pos_x_b, 7.5);
            try std.testing.expect(d.ready(true)[0] and d.readyTactical(true)[0]);
            try std.testing.expect(!d.ready(false)[0] and !d.readyTactical(false)[0]);
            const cast = @as(Action, .{ .ability = 3 });
            if (tactical) d.applyTactical(@splat(cast), @splat(cast)) else d.apply(@splat(cast), @splat(cast));
            try std.testing.expectEqual(@as(u32, 3), state.cast_id_a[0]);
            try std.testing.expectEqual(@as(u32, 0), state.cast_id_b[0]);
            d.tick(1000);
            try std.testing.expect(d.ready(false)[0] and d.readyTactical(false)[0]);
            if (tactical) d.applyTactical(@splat(.{}), @splat(cast)) else d.apply(@splat(.{}), @splat(cast));
            try std.testing.expectEqual(@as(u32, 3), state.cast_id_b[0]);
            try std.testing.expectApproxEqAbs(@as(f32, 0.01), state.cast_timer_b[0] - state.cast_timer_a[0], 0.000001);
            for (0..200) |_| {
                if (state.fear_timer_b[0] > 0) break;
                d.tick(1000);
            }
            try std.testing.expect(state.fear_timer_b[0] > 0);
            try std.testing.expectEqual(@as(f32, 0), state.fear_timer_a[0]);
            d.tick(1000);
            try std.testing.expectEqual(@as(u32, 0), state.cast_id_b[0]);
            try std.testing.expectEqual(@as(f32, 0), state.fear_timer_a[0]);
        }
    }
}

test "midflight snapshots reproduce projectile impacts exactly" {
    var d = try Duel(.frost_mage, .warlock).init(std.testing.allocator);
    defer d.deinit();
    d.apply(@splat(.{ .ability = 1 }), @splat(.{ .ability = 7 }));
    for (0..10) |_| d.tick(3000);
    const flight = d.snapshot(0);
    try std.testing.expect(d.arena.combat().projectile_0_spell_a[0] > 0);
    try std.testing.expect(d.arena.combat().projectile_0_spell_b[0] > 0);
    for (0..150) |_| d.tick(3000);
    const impact = d.snapshot(0);
    for (0..16) |lane| d.restore(lane, flight);
    for (0..150) |_| d.tick(3000);
    try std.testing.expectEqualDeep(impact, d.snapshot(0));
}
