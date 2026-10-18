const std = @import("std");
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Priest = spec_mod.Priest;
const PriestAction = spec_mod.PriestAction;
const PriestTalentRanks = spec_mod.PriestTalentRanks;
const priest_talents = @import("priest_talents.zig");
const multi_spec = @import("multi_spec.zig");
const search_sim = @import("search_sim.zig");
const mcts = @import("mcts.zig");
const simd = @import("simd.zig");

fn splat(v: f32) simd.f32x16 {
    return @splat(v);
}

fn act(a: PriestAction) simd.u32x16 {
    return @splat(@intFromEnum(a));
}

test "Shadow Reach loads both ranks and extends targeted Shadow spells on either side" {
    const loaded = try spec_mod.loadSpecFile(std.testing.allocator, "specs/shadow_priest.json");
    defer std.testing.allocator.free(loaded.name);
    defer std.testing.allocator.free(loaded.id);
    try std.testing.expectEqual(@as(u8, 5), loaded.priest_talents.blackout);
    try std.testing.expectEqual(@as(u8, 2), loaded.priest_talents.shadow_reach);
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        const ranks = PriestTalentRanks{ .shadow_reach = 2, .mind_flay = 1, .improved_mind_flay = 2, .silence = 1, .vampiric_embrace = 1 };
        if (side) d.setPriestTalentRanksA(ranks.encode()) else d.setPriestTalentRanksB(ranks.encode());
        const s = d.arena.combat();
        s.distance[0] = 35;
        const masks = if (side) d.getActionMaskA(0) else d.getActionMaskB(0);
        inline for (.{ 1, 2, 4, 5, 8, 9 }) |id| try std.testing.expect(masks[id][0]);
        try std.testing.expect(!masks[3][0]); // Scream's radius is unchanged.
        s.distance[0] = 24;
        try std.testing.expect((if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[7][0]);
        s.distance[0] = 24.1;
        try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[7][0]);
        s.distance[0] = 35;
        if (side) d.apply(@splat(.{ .ability = 4 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 4 }));
        for (0..152) |_| _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expect(@field(s, if (side) "death_coil_cd_a" else "death_coil_cd_b")[0] > 0);
        const snapshot = d.snapshot(0);
        d.restore(7, snapshot);
        try std.testing.expectEqual(@field(s, if (side) "talent_extra_a" else "talent_extra_b")[0], @field(s, if (side) "talent_extra_a" else "talent_extra_b")[7]);
    }
    try std.testing.expectError(error.InvalidTalentRank, spec_mod.validatePriestRanks(.{ .blackout = 6 }));
    try std.testing.expectError(error.InvalidTalentRank, spec_mod.validatePriestRanks(.{ .shadow_reach = 3 }));
}

test "Blackout stuns stop casts and movement with independent diminishing returns and snapshot restore" {
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        const s = d.arena.combat();
        const own = if (side) "_a" else "_b";
        const target = if (side) "_b" else "_a";
        const ranks = (PriestTalentRanks{ .blackout = 5 }).encode();
        var fx = priest_talents.decode(@splat(@truncate(ranks)), @splat(@truncate(ranks >> 32)), @splat(@truncate(ranks >> 64)));
        try std.testing.expectApproxEqAbs(@as(f32, 0.10), fx.blackout_proc_chance[0], 0.00001);
        // Fixed successful proc rolls exercise DR independently of chance.
        fx.blackout_proc_chance = @splat(1);
        inline for (.{ @as(f32, 3), @as(f32, 1.5), @as(f32, 0.75), @as(f32, 0) }) |duration| {
            @field(s, "stun_timer" ++ target)[0] = 0;
            @field(s, "cast_id" ++ target)[0] = 4;
            @field(s, "cast_timer" ++ target)[0] = 1;
            @field(s, "move_intent" ++ target)[0] = -1;
            @import("priest_combat.zig").procBlackout(s, side, 0, @splat(true), fx);
            try std.testing.expectEqual(duration, @field(s, "stun_timer" ++ target)[0]);
            if (duration > 0) {
                try std.testing.expectEqual(@as(u32, 0), @field(s, "cast_id" ++ target)[0]);
                try std.testing.expect(!(if (side) d.getActionMaskB(0) else d.getActionMaskA(0))[1][0]);
                const snap = d.snapshot(0);
                d.restore(7, snap);
                try std.testing.expectEqual(duration, @field(s, "stun_timer" ++ target)[7]);
                try std.testing.expectEqual(@as(f32, 0), @field(s, "horror_dr_tier" ++ target)[0]);
                try std.testing.expectEqual(@as(f32, 0), @field(s, "fear_dr_tier" ++ target)[0]);
                const x = @field(s, "pos_x" ++ target)[0];
                _ = d.arena.tickPhysics16(0.01, 0);
                try std.testing.expectEqual(x, @field(s, "pos_x" ++ target)[0]);
            }
        }
        @import("priest_combat.zig").tickStuns(s, 0, 18);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "stun_dr_tier" ++ target)[0]);
        // Integration: SW:D resolves its damage, then the queued Shadow hit can proc.
        if (side) d.setPriestTalentRanksA(ranks) else d.setPriestTalentRanksB(ranks);
        @field(s, "cast_id" ++ target)[0] = 0;
        @field(s, "spell_rng" ++ own)[0] = 1; // First xorshift roll < 0.1.
        @field(s, "conflagrate_pending" ++ own)[0] = 100;
        _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expect(@field(s, "stun_timer" ++ target)[0] > 0);
    }
}

test "Priest shield scales with Holy spell power before talents on either side" {
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        try d.setCombatStats(side, .{ .shadow_power = 400 });
        const ranks = (PriestTalentRanks{ .improved_power_word_shield = 3, .twin_disciplines = 5 }).encode();
        if (side) d.setPriestTalentRanksA(ranks) else d.setPriestTalentRanksB(ranks);
        if (side) d.apply(@splat(.{ .ability = 6 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 6 }));
        try std.testing.expectApproxEqAbs((Priest.ShieldAbsorb + 400 * 0.10) * 1.20 * 1.05, d.arena.extra(.shield, side, 0)[0], 0.001);
    }
}

test "SW:D backlash costs max health through shields but not on miss or killing blow" {
    inline for (.{ true, false }) |side| {
        inline for (.{ @as(u8, 0), @as(u8, 1), @as(u8, 2) }) |outcome| {
            const kill = outcome == 1;
            const miss = outcome == 2;
            var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
            defer d.deinit();
            try d.setCombatStats(side, .{ .max_health = 3000 });
            const s = d.arena.combat();
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @field(s, "hp" ++ own)[0] = 2500;
            if (miss) @field(s, "spell_hit_chance" ++ own)[0] = 0;
            @field(s, "hp" ++ target)[0] = if (kill) 1 else 2000;
            @field(s, "action6_dur" ++ own)[0] = 20;
            d.arena.extra(.shield, side, 0)[0] = 1000;
            if (side) d.apply(@splat(.{ .ability = 9 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 9 }));
            _ = d.arena.tickPhysics16(0.01, 0);
            try std.testing.expectEqual(@as(f32, if (kill or miss) 2500 else 2200), @field(s, "hp" ++ own)[0]);
            try std.testing.expectEqual(@as(f32, 1000), d.arena.extra(.shield, side, 0)[0]);
        }
    }
}

test "canonical priest specs and json files load and validate" {
    const sp = spec_mod.findCanonicalSpec("shadow_priest").?;
    try std.testing.expectEqual(Spec.priest, sp.class);
    try spec_mod.validatePriestRanks(sp.priest_talents);

    const dp = spec_mod.findCanonicalSpec("disc_priest").?;
    try std.testing.expectEqual(Spec.priest, dp.class);
    try spec_mod.validatePriestRanks(dp.priest_talents);

    const smp = spec_mod.findCanonicalSpec("smite_priest").?;
    try std.testing.expectEqual(Spec.priest, smp.class);
    try spec_mod.validatePriestRanks(smp.priest_talents);

    const loaded_sp = try spec_mod.loadSpecFile(std.testing.allocator, "specs/shadow_priest.json");
    defer std.testing.allocator.free(loaded_sp.name);
    defer std.testing.allocator.free(loaded_sp.id);
    try std.testing.expectEqual(Spec.priest, loaded_sp.class);
    try std.testing.expectEqual(@as(u8, 1), loaded_sp.priest_talents.shadowform);
    try std.testing.expectEqual(@as(u8, 4), loaded_sp.priest_talents.darkness);

    const loaded_dp = try spec_mod.loadSpecFile(std.testing.allocator, "specs/disc_priest.json");
    defer std.testing.allocator.free(loaded_dp.name);
    defer std.testing.allocator.free(loaded_dp.id);
    try std.testing.expectEqual(Spec.priest, loaded_dp.class);
    try std.testing.expectEqual(@as(u8, 1), loaded_dp.priest_talents.penance);
    try std.testing.expectEqual(@as(u8, 1), loaded_dp.priest_talents.soul_warding);
}

test "shadow priest kit: SW:P, Devouring Plague, Vampiric Embrace, Mind Blast, Mind Flay, SW:D backlash, Silence, Scream" {
    var duel = try search_sim.Duel(.priest, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    var sp_ranks = spec_mod.findCanonicalSpec("shadow_priest").?.priest_talents;
    sp_ranks.blackout = 0; // Keep this scripted spell sequence free of random stuns.
    duel.setPriestTalentRanksA(sp_ranks.encode());

    const state = duel.arena.combat();
    @memset(state.distance, 6.0);
    @memset(state.pos_x_a, -3.0);
    @memset(state.pos_x_b, 3.0);
    @memset(state.spell_hit_chance_a, 1.0);
    @memset(state.spell_crit_chance_a, 0.0);

    // 1. Shadowform blocks Flash Heal (11), Renew (12), Penance (15), but allows SW:P (1), Holy Fire (13), Smite (14)
    const masks0 = duel.getActionMaskA(0);
    try std.testing.expect(masks0[@intFromEnum(PriestAction.ShadowWordPain)][0]);
    try std.testing.expect(masks0[@intFromEnum(PriestAction.HolyFire)][0]);
    try std.testing.expect(masks0[@intFromEnum(PriestAction.Smite)][0]);
    try std.testing.expect(!masks0[@intFromEnum(PriestAction.FlashHeal)][0]);
    try std.testing.expect(!masks0[@intFromEnum(PriestAction.Renew)][0]);
    try std.testing.expect(!masks0[@intFromEnum(PriestAction.Penance)][0]);

    // 2. Apply SW:P (2/2 Imp SW:P -> 24s duration)
    duel.arena.applyActionA(0, act(.ShadowWordPain), splat(0));
    try std.testing.expectEqual(@as(f32, 24.0), state.agony_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 1.0), state.soul_shards_a[0]); // 1 Shadow Weaving stack

    // 3. Clear GCD and apply Vampiric Embrace (action 8)
    @memset(state.gcd_a, 0);
    duel.arena.applyActionA(0, act(.VampiricEmbrace), splat(0));
    try std.testing.expectEqual(@as(f32, 30.0), state.siphon_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 60.0), state.seduction_cast_a[0]);

    // 4. Clear GCD and apply Devouring Plague (action 2)
    @memset(state.gcd_a, 0);
    duel.arena.applyActionA(0, act(.DevouringPlague), splat(0));
    try std.testing.expectEqual(@as(f32, 24.0), state.corruption_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 60.0), duel.arena.extra(.blink, true, 0)[0]);

    // 5. Damage Priest to 1200 HP, then cast Shadow Word: Death (action 9) -> damages target, costs 10% maximum health, and heals Priest via Vampiric Embrace!
    @memset(state.gcd_a, 0);
    state.hp_a[0] = 1200.0;
    const hp_b_before = state.hp_b[0];
    duel.arena.applyActionA(0, act(.ShadowWordDeath), splat(0));
    try std.testing.expect(state.conflagrate_pending_a[0] > 0);
    _ = duel.arena.tickPhysics16(0.01, 0);
    const dmg_dealt = hp_b_before - state.hp_b[0];
    try std.testing.expect(dmg_dealt > 200.0);
    // The health cost is independent of spell damage and VE healing.
    try std.testing.expectApproxEqAbs(1200.0 + dmg_dealt * 0.20 - state.max_health_a[0] * 0.10, state.hp_a[0], 1.0);

    // 6. Silence (action 7, off-GCD) interrupts target cast and locks out for 5s
    state.cast_id_b[0] = 4;
    state.cast_timer_b[0] = 1.0;
    state.cast_total_b[0] = 2.0;
    duel.arena.applyActionA(0, act(.Silence), splat(0));
    try std.testing.expectEqual(@as(u32, 0), state.cast_id_b[0]);
    try std.testing.expectEqual(@as(f32, 5.0), duel.arena.extra(.lockout, false, 0)[0]);

    // 7. Psychic Scream (action 3) fears target within 8m and sets 26s cooldown (2/2 Imp Psychic Scream)
    @memset(state.gcd_a, 0);
    duel.arena.applyActionA(0, act(.PsychicScream), splat(0));
    try std.testing.expectEqual(@as(f32, Priest.PsychicScreamDuration), state.fear_timer_b[0]);
    try std.testing.expectEqual(@as(f32, 26.0), duel.arena.extra(.nova, true, 0)[0]);
}

test "discipline priest kit: PW:S Soul Warding, Inner Focus, Holy Fire + Penance Power in Light, Flash Heal Divine Aegis, Renew" {
    var duel = try search_sim.Duel(.priest, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    var dp_ranks = spec_mod.findCanonicalSpec("disc_priest").?.priest_talents;
    dp_ranks.divine_aegis = 3; // Exercise this optional talent explicitly.
    duel.setPriestTalentRanksA(dp_ranks.encode());

    const state = duel.arena.combat();
    @memset(state.distance, 15.0);
    @memset(state.pos_x_a, -7.5);
    @memset(state.pos_x_b, 7.5);
    @memset(state.spell_hit_chance_a, 1.0);

    // 1. Power Word: Shield with Improved PW:S (+20%), Twin Disciplines (+5%), and Soul Warding (11s CD)
    duel.arena.applyActionA(0, act(.PowerWordShield), splat(0));
    try std.testing.expectApproxEqAbs(Priest.ShieldAbsorb * 1.20 * 1.05, duel.arena.extra(.shield, true, 0)[0], 0.5);
    try std.testing.expectEqual(@as(f32, 11.0), state.action6_cd_a[0]);

    // 2. Inner Focus (off-GCD) makes next spell cost 0 mana and adds +25% crit
    @memset(state.gcd_a, 0);
    state.hp_a[0] = 1000.0;
    state.spell_crit_chance_a[0] = 0.80; // with +25% Inner Focus -> 100% crit
    const mana_before = state.mana_a[0];
    duel.arena.applyActionA(0, act(.InnerFocus), splat(0));
    try std.testing.expectEqual(@as(u32, 1), state.soul_link_a[0]);
    try std.testing.expectEqual(@as(f32, 180.0), state.fire_lockout_a[0]);

    // Cast Flash Heal (1.5s cast) -> 0 mana spent, crits, and triggers Divine Aegis (15% of heal added to shield)
    duel.arena.applyActionA(0, act(.FlashHeal), splat(0));
    try std.testing.expectEqual(mana_before, state.mana_a[0]);
    const shield_before = duel.arena.extra(.shield, true, 0)[0];
    for (0..160) |_| _ = duel.arena.tickPhysics16(0.01, 0);
    try std.testing.expectEqual(@as(u32, 0), state.soul_link_a[0]); // Inner Focus consumed
    try std.testing.expect(state.hp_a[0] > 1500.0);
    try std.testing.expect(duel.arena.extra(.shield, true, 0)[0] > shield_before); // Divine Aegis added shield

    // 3. Renew applies 15s HoT in shadow_lockout_a and ticks every 3s
    @memset(state.gcd_a, 0);
    state.hp_a[0] = 1200.0;
    duel.arena.applyActionA(0, act(.Renew), splat(0));
    try std.testing.expectEqual(@as(f32, 15.0), state.shadow_lockout_a[0]);
    for (0..310) |_| _ = duel.arena.tickPhysics16(0.01, 0);
    try std.testing.expect(state.hp_a[0] > 1250.0);

    // 4. Holy Fire + Penance with Power in Light (+15% damage while Holy Fire DoT is active)
    @memset(state.gcd_a, 0);
    @memset(state.spell_crit_chance_a, 0.0);
    dp_ranks.holy_specialization = 0; // Deterministic noncritical channel damage.
    duel.setPriestTalentRanksA(dp_ranks.encode());
    state.immolate_timer_b[0] = 10.0; // Holy Fire DoT active on target B
    const hp_b_before = state.hp_b[0];
    duel.arena.applyActionA(0, act(.Penance), splat(0));
    try std.testing.expectEqual(@as(u32, 15), state.cast_id_a[0]);
    for (0..210) |_| _ = duel.arena.tickPhysics16(0.01, 0);
    const penance_dmg = hp_b_before - state.hp_b[0];
    // Three Penance bolts, plus the Holy Fire tick at 2s. Searing Light is 5%
    // and Power in Light is 10% in the current Forever talent data.
    try std.testing.expectApproxEqAbs(Priest.PenanceDps * Priest.PenanceDuration * 1.05 * 1.10 + Priest.HolyFireDps * 2.0 * 1.05, penance_dmg, 2.0);
}

test "narrow action staging matches full staging for priest matchups" {
    inline for (.{ Spec.warlock, Spec.frost_mage, Spec.priest }) |other| {
        var fast = try search_sim.Duel(.priest, other).init(std.testing.allocator);
        defer fast.deinit();
        var reference = try search_sim.Duel(.priest, other).init(std.testing.allocator);
        defer reference.deinit();
        const sp_ranks = spec_mod.findCanonicalSpec("shadow_priest").?.priest_talents;
        const dp_ranks = spec_mod.findCanonicalSpec("disc_priest").?.priest_talents;
        fast.setPriestTalentRanksA(sp_ranks.encode());
        reference.setPriestTalentRanksA(sp_ranks.encode());
        if (other == .priest) {
            fast.setPriestTalentRanksB(dp_ranks.encode());
            reference.setPriestTalentRanksB(dp_ranks.encode());
        }
        var rng = std.Random.DefaultPrng.init(1337);
        const random = rng.random();
        for (0..400) |step| {
            if (step % 100 == 0) for (0..16) |lane| {
                fast.arena.resetDuel(lane);
                // Talent columns are immutable configuration, excluded from snapshots.
                // resetDuel clears them, so reapply the same build to both engines.
                fast.setPriestTalentRanksA(sp_ranks.encode());
                reference.setPriestTalentRanksA(sp_ranks.encode());
                if (other == .priest) {
                    fast.setPriestTalentRanksB(dp_ranks.encode());
                    reference.setPriestTalentRanksB(dp_ranks.encode());
                }
                fast.arena.combat().distance[lane] = @floatFromInt(3 + lane * 2);
                fast.arena.combat().gcd_b[lane] = if (lane % 2 == 0) 0.1 else 0;
                reference.restore(lane, fast.snapshot(lane));
            };
            const ra = fast.ready(true);
            const rb = fast.ready(false);
            const masks_a = fast.getActionMaskA(0);
            const masks_b = fast.getActionMaskB(0);
            var aa: [16]search_sim.Action = undefined;
            var bb: [16]search_sim.Action = undefined;
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
    }
}

test "mcts search runs cleanly on priest vs warlock" {
    var duel = try search_sim.Duel(.priest, .warlock).init(std.testing.allocator);
    defer duel.deinit();
    duel.setPriestTalentRanksA(spec_mod.findCanonicalSpec("shadow_priest").?.priest_talents.encode());
    duel.setWarlockTalentRanksB(spec_mod.findCanonicalSpec("affliction_warlock").?.warlock_talents.encode());

    var engine = try mcts.Search(.priest, .warlock).init(std.testing.allocator, .{
        .rollouts = 64,
        .workers = 1,
        .depth = 12,
        .truncation_ticks = 30,
    });
    defer engine.deinit();
    var rng = std.Random.DefaultPrng.init(42);
    const res = engine.decide(duel.snapshot(0), rng.random());
    try std.testing.expect(res.choices[0].len > 1);
    try std.testing.expect(res.choices[1].len > 1);
}

test "priest level 60 damage and channel spell power scale on both sides" {
    inline for (.{ true, false }) |side| {
        inline for (.{ PriestAction.MindBlast, PriestAction.MindFlay, PriestAction.ShadowWordDeath, PriestAction.Penance }) |ability| {
            var duel = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
            defer duel.deinit();
            const ranks = if (ability == .Penance)
                PriestTalentRanks{ .penance = 1 }
            else
                PriestTalentRanks{ .mind_flay = 1, .improved_mind_flay = 2, .darkness = 5, .shadowform = 1, .twin_disciplines = 5 };
            if (side) duel.setPriestTalentRanksA(ranks.encode()) else duel.setPriestTalentRanksB(ranks.encode());
            const state = duel.arena.combat();
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @memset(state.distance, 6);
            @memset(state.pos_x_a, -3);
            @memset(state.pos_x_b, 3);
            @memset(state.hp_a, 10000);
            @memset(state.hp_b, 10000);
            @memset(state.max_health_a, 10000);
            @memset(state.max_health_b, 10000);
            @memset(@field(state, "spell_hit_chance" ++ own), 1);
            @memset(@field(state, "spell_crit_chance" ++ own), 0);
            @field(state, "shadow_power" ++ own)[1] = 400;
            @field(state, "shadow_power" ++ own)[2] = 400;
            @field(state, "spell_crit_chance" ++ own)[2] = 1;
            if (side) duel.arena.applyActionA(0, act(ability), splat(0)) else duel.arena.applyActionB(0, act(ability), splat(0));
            for (0..330) |_| _ = duel.arena.tickPhysics16(0.01, 0);
            for (0..3) |lane| {
                const power: f32 = if (lane == 0) 0 else 400;
                // Independent reference amounts, not derived from the constants under test.
                const base: f32 = switch (ability) {
                    .MindBlast => 490.5 + power * 0.429,
                    .MindFlay => 3 * (130 + power * 0.167) * 1.20,
                    .ShadowWordDeath => (458 + power * 0.429) * 1.05,
                    .Penance => 3 * (131 + power * 0.285),
                    else => unreachable,
                };
                const damage_mult: f32 = if (ability == .Penance) 1 else 1.10 * 1.10;
                const crit_mult: f32 = if (lane != 2) 1 else if (ability == .Penance) 1.5 else 2;
                try std.testing.expectApproxEqAbs(base * damage_mult * crit_mult, 10000 - @field(state, "hp" ++ target)[lane], 0.1);
            }
        }
    }
}

test "Penance bolts land at opening, one second, two seconds; cancellation removes remaining bolts" {
    inline for (.{ true, false }) |side| {
        var duel = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer duel.deinit();
        const state = duel.arena.combat();
        const suffix = if (side) "_a" else "_b";
        const target = if (side) "_b" else "_a";
        if (side) duel.setPriestTalentRanksA((PriestTalentRanks{ .penance = 1 }).encode()) else duel.setPriestTalentRanksB((PriestTalentRanks{ .penance = 1 }).encode());
        @memset(@field(state, "spell_hit_chance" ++ suffix), 1);
        @memset(@field(state, "spell_crit_chance" ++ suffix), 0);
        @memset(@field(state, "hp" ++ target), 2000);
        if (side) duel.arena.applyActionA(0, act(.Penance), splat(0)) else duel.arena.applyActionB(0, act(.Penance), splat(0));
        _ = duel.arena.tickPhysics16(0.01, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1869), @field(state, "hp" ++ target)[0], 0.01);
        for (0..98) |_| _ = duel.arena.tickPhysics16(0.01, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1869), @field(state, "hp" ++ target)[0], 0.01);
        _ = duel.arena.tickPhysics16(0.01, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1738), @field(state, "hp" ++ target)[0], 0.01);
        // Cancel just lane zero; lane one completes the channel.
        @field(state, "cast_id" ++ suffix)[0] = 0;
        @field(state, "cast_timer" ++ suffix)[0] = 0;
        for (0..100) |_| _ = duel.arena.tickPhysics16(0.01, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1738), @field(state, "hp" ++ target)[0], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1607), @field(state, "hp" ++ target)[1], 0.01);
    }
}

test "priest recording separates periodic damage and effective healing" {
    var duel = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
    defer duel.deinit();
    var ticks: [2]@import("priest_recording.zig").Tick = .{ .{}, .{} };
    duel.arena.priest_recording = &ticks;
    const state = duel.arena.combat();
    @memset(state.spell_hit_chance_a, 1);
    @memset(state.spell_hit_chance_b, 1);
    @memset(state.spell_crit_chance_a, 0);
    @memset(state.spell_crit_chance_b, 0);
    state.hp_a[0] = 1990;
    state.shadow_lockout_a[0] = 12.01; // Renew is about to tick, with only 10 HP missing.
    state.agony_timer_a[0] = 15.01; // Opposing SW:P lands on the same tick.
    _ = duel.arena.tickPhysics16(0.01, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 10), ticks[0].healing[12], 0.01);
    try std.testing.expect(ticks[1].damage[1] > 0);
    try std.testing.expect(state.hp_a[0] < 1990); // Net HP loss must not hide the heal.
    try std.testing.expectEqual(@as(f32, 0), ticks[0].healing[11]);
}

test "Power Infusion loads from Discipline preset and buffs damage/healing with cooldown snapshot parity" {
    const loaded = try spec_mod.loadSpecFile(std.testing.allocator, "specs/disc_priest.json");
    defer std.testing.allocator.free(loaded.name);
    defer std.testing.allocator.free(loaded.id);
    try std.testing.expectEqual(@as(u8, 1), loaded.priest_talents.power_infusion);
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        const s = d.arena.combat();
        const own = if (side) "_a" else "_b";
        try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[21][0]);
        const ranks = PriestTalentRanks{ .power_infusion = 1 };
        if (side) d.setPriestTalentRanksA(ranks.encode()) else d.setPriestTalentRanksB(ranks.encode());
        const mana_before = @field(s, "mana" ++ own)[0];
        // Off-GCD, but cannot be activated during another cast.
        @field(s, "gcd" ++ own)[0] = 1;
        try std.testing.expect((if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[21][0]);
        if (side) d.arena.applyActionA(0, act(.PowerInfusion), splat(0)) else d.arena.applyActionB(0, act(.PowerInfusion), splat(0));
        try std.testing.expectEqual(mana_before - 200, @field(s, "mana" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 15), @field(s, "priest_pi_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 180), @field(s, "priest_pi_cd" ++ own)[0]);
        const fx = @import("priest_combat.zig").dynamicEffects(s, side, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), fx.shadow_damage_mult[0], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), fx.holy_damage_mult[0], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), fx.healing_mult[0], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), fx.renew_healing_mult[0], 0.0001);
        // Absorption isn't healing: PI doesn't increase Shield.
        try std.testing.expectEqual(@as(f32, 1), fx.shield_absorb_mult[0]);
        const saved = d.snapshot(0);
        d.restore(7, saved);
        try std.testing.expectEqual(@as(f32, 15), @field(s, "priest_pi_timer" ++ own)[7]);
        for (0..1501) |_| _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "priest_pi_timer" ++ own)[0]);
        try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[21][0]);
    }
}

test "Dispel Magic removes two eligible harmful auras and preserves curses and diseases" {
    inline for (.{ true, false }) |side| {
        const A: Spec = if (side) .priest else .warlock;
        const B: Spec = if (side) .warlock else .priest;
        var d = try search_sim.Duel(A, B).init(std.testing.allocator);
        defer d.deinit();
        const s = d.arena.combat();
        const own = if (side) "_a" else "_b";
        @field(s, "agony_timer" ++ own)[0] = 18; // Curse, never magic.
        @field(s, "corruption_timer" ++ own)[0] = 14;
        @field(s, "immolate_timer" ++ own)[0] = 15;
        @field(s, "siphon_timer" ++ own)[0] = 30;
        if (side) d.arena.applyActionA(0, act(.DispelSelf), splat(0)) else d.arena.applyActionB(0, act(.DispelSelf), splat(0));
        try std.testing.expectEqual(@as(f32, 18), @field(s, "agony_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "corruption_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "immolate_timer" ++ own)[0]);
        try std.testing.expectEqual(@as(f32, 30), @field(s, "siphon_timer" ++ own)[0]);
    }
    var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
    defer d.deinit();
    const s = d.arena.combat();
    s.corruption_timer_a[0] = 24; // Devouring Plague is a disease.
    try std.testing.expect(!d.getActionMaskA(0)[22][0]);
    s.agony_timer_a[0] = 18; // SW:P is magic.
    d.arena.applyActionA(0, act(.DispelSelf), splat(0));
    try std.testing.expectEqual(@as(f32, 0), s.agony_timer_a[0]);
    try std.testing.expectEqual(@as(f32, 24), s.corruption_timer_a[0]);
}

test "Offensive Dispel Magic purges Shield and Power Infusion without resetting cooldowns on either side" {
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        const s = d.arena.combat();
        const enemy = if (side) "_b" else "_a";
        @field(s, if (side) "spell_hit_chance_a" else "spell_hit_chance_b")[0] = 1;
        d.arena.extra(.shield, !side, 0)[0] = 500;
        @field(s, "action6_dur" ++ enemy)[0] = 20;
        @field(s, "action6_cd" ++ enemy)[0] = 11;
        @field(s, "priest_pi_timer" ++ enemy)[0] = 15;
        @field(s, "priest_pi_cd" ++ enemy)[0] = 180;
        @field(s, "shadow_lockout" ++ enemy)[0] = 15;
        if (side) d.apply(@splat(.{ .ability = 23 }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = 23 }));
        try std.testing.expectEqual(@as(f32, 0), d.arena.extra(.shield, !side, 0)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "action6_dur" ++ enemy)[0]);
        try std.testing.expectEqual(@as(f32, 0), @field(s, "priest_pi_timer" ++ enemy)[0]);
        try std.testing.expectEqual(@as(f32, 11), @field(s, "action6_cd" ++ enemy)[0]);
        try std.testing.expectEqual(@as(f32, 180), @field(s, "priest_pi_cd" ++ enemy)[0]);
        try std.testing.expectEqual(@as(f32, 15), @field(s, "shadow_lockout" ++ enemy)[0]);
    }
}

test "Mana Burn drains only available mana on completion and shields absorb damage but not mana loss" {
    inline for (.{ true, false }) |side| {
        var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
        defer d.deinit();
        const s = d.arena.combat();
        const own = if (side) "_a" else "_b";
        const enemy = if (side) "_b" else "_a";
        const ranks = PriestTalentRanks{ .improved_mana_burn = 2 };
        if (side) d.setPriestTalentRanksA(ranks.encode()) else d.setPriestTalentRanksB(ranks.encode());
        @field(s, "spell_hit_chance" ++ own)[0] = 1;
        @field(s, "mana" ++ enemy)[0] = 200;
        d.arena.extra(.shield, !side, 0)[0] = 1000;
        @field(s, "action6_dur" ++ enemy)[0] = 20;
        const hp_before = @field(s, "hp" ++ enemy)[0];
        if (side) d.arena.applyActionA(0, act(.ManaBurn), splat(0)) else d.arena.applyActionB(0, act(.ManaBurn), splat(0));
        try std.testing.expectEqual(@as(f32, 2), @field(s, "cast_timer" ++ own)[0]);
        for (0..190) |_| _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expect(@field(s, "mana" ++ enemy)[0] > 200);
        for (0..12) |_| _ = d.arena.tickPhysics16(0.01, 0);
        try std.testing.expect(@field(s, "mana" ++ enemy)[0] < 2);
        try std.testing.expectEqual(hp_before, @field(s, "hp" ++ enemy)[0]);
        try std.testing.expect(d.arena.extra(.shield, !side, 0)[0] < 900);
    }
    try std.testing.expectError(error.InvalidTalentRank, spec_mod.validatePriestRanks(.{ .power_infusion = 2 }));
    try std.testing.expectError(error.InvalidTalentRank, spec_mod.validatePriestRanks(.{ .improved_mana_burn = 3 }));
}

test "Mana Burn cancellation miss and range failure never drain mana" {
    inline for (.{ true, false }) |side| {
        inline for (.{ "cancel", "miss", "range" }) |failure| {
            var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
            defer d.deinit();
            const s = d.arena.combat();
            const own = if (side) "_a" else "_b";
            const enemy = if (side) "_b" else "_a";
            @field(s, "mana" ++ enemy)[0] = 1000;
            @field(s, "spell_hit_chance" ++ own)[0] = if (comptime std.mem.eql(u8, failure, "miss")) 0 else 1;
            if (side) d.arena.applyActionA(0, act(.ManaBurn), splat(0)) else d.arena.applyActionB(0, act(.ManaBurn), splat(0));
            if (comptime std.mem.eql(u8, failure, "cancel")) {
                if (side) d.arena.applyActionA(0, act(.CancelCast), splat(0)) else d.arena.applyActionB(0, act(.CancelCast), splat(0));
            }
            if (comptime std.mem.eql(u8, failure, "range")) {
                @memset(s.distance, 35);
                @memset(s.pos_x_a, -17.5);
                @memset(s.pos_x_b, 17.5);
            }
            for (0..305) |_| _ = d.arena.tickPhysics16(0.01, 0);
            try std.testing.expect(@field(s, "mana" ++ enemy)[0] >= 1000);
        }
    }
}

test "Priest replay aura telemetry separates sides and excludes reused Warlock storage" {
    const recorder = @import("match_recorder.zig");
    var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
    defer d.deinit();
    d.setPriestTalentRanksA((PriestTalentRanks{ .shadowform = 1 }).encode());
    const s = d.arena.combat();
    s.shadow_lockout_a[0] = 9;
    s.soul_link_a[0] = 1;
    s.shadow_flame_timer_a[0] = 13;
    s.soul_shards_a[0] = 5;
    s.shadow_lockout_b[0] = 4;
    try std.testing.expectEqualSlices(f32, &.{ 9, 1, 1, 13, 5 }, &recorder.priestAuraTelemetry(s, .priest, true));
    try std.testing.expectEqualSlices(f32, &.{ 4, 0, 0, 0, 0 }, &recorder.priestAuraTelemetry(s, .priest, false));
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0 }, &recorder.priestAuraTelemetry(s, .warlock, true));
}

test "Holy Fire matches Forever rank eight cast cost impact and five noncritical ticks" {
    inline for (.{ true, false }) |side| {
        inline for (.{ @as(u8, 0), @as(u8, 5) }) |fury| {
            var duel = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
            defer duel.deinit();
            const ranks = PriestTalentRanks{ .divine_fury = fury };
            if (side) duel.setPriestTalentRanksA(ranks.encode()) else duel.setPriestTalentRanksB(ranks.encode());
            const state = duel.arena.combat();
            const own = if (side) "_a" else "_b";
            const target = if (side) "_b" else "_a";
            @memset(state.distance, 6);
            @memset(state.pos_x_a, -3);
            @memset(state.pos_x_b, 3);
            @memset(@field(state, "hp" ++ target), 10000);
            @memset(@field(state, "max_health" ++ target), 10000);
            @memset(@field(state, "shadow_power" ++ own), 0);
            @memset(@field(state, "spell_hit_chance" ++ own), 1);
            @memset(@field(state, "spell_crit_chance" ++ own), 0);
            @field(state, "shadow_power" ++ own)[1] = 400;
            @field(state, "shadow_power" ++ own)[2] = 400;
            @field(state, "spell_crit_chance" ++ own)[2] = 1;
            const mana_before = @field(state, "mana" ++ own)[0];
            if (side) duel.arena.applyActionA(0, act(.HolyFire), splat(0)) else duel.arena.applyActionB(0, act(.HolyFire), splat(0));
            const cast_time: f32 = if (fury == 0) 3.5 else 3.0;
            try std.testing.expectApproxEqAbs(cast_time, @field(state, "cast_timer" ++ own)[0], 0.0001);
            try std.testing.expectApproxEqAbs(mana_before - 255, @field(state, "mana" ++ own)[0], 0.0001);
            // No damage or debuff before the cast completes.
            for (0..290) |_| _ = duel.arena.tickPhysics16(0.01, 0);
            try std.testing.expectEqual(@as(f32, 10000), @field(state, "hp" ++ target)[0]);
            try std.testing.expectEqual(@as(f32, 0), @field(state, "immolate_timer" ++ target)[0]);
            // Cast, projectile travel, and the full ten-second periodic duration.
            for (0..1200) |_| _ = duel.arena.tickPhysics16(0.01, 0);
            for (0..3) |lane| {
                const power: f32 = if (lane == 0) 0 else 400;
                const crit: f32 = if (lane == 2) 1.5 else 1;
                const expected = (208 + 0.75 * power) * crit + 5 * (15 + 0.05 * power);
                try std.testing.expectApproxEqAbs(expected, 10000 - @field(state, "hp" ++ target)[lane], 0.1);
                try std.testing.expectEqual(@as(f32, 0), @field(state, "immolate_timer" ++ target)[lane]);
            }
        }
    }
}

test "Priest audited Shadow mana costs gate and spend correctly on both sides" {
    inline for (.{ true, false }) |side| {
        inline for (.{ .{ @as(u8, 1), @as(f32, 470) }, .{ @as(u8, 4), @as(f32, 350) }, .{ @as(u8, 5), @as(f32, 205) } }) |spell| {
            inline for (0..3) |mode| {
                var d = try search_sim.Duel(.priest, .priest).init(std.testing.allocator);
                defer d.deinit();
                const ranks = PriestTalentRanks{ .mind_flay = 1, .shadowform = if (mode == 1) 1 else 0, .mental_agility = 3 };
                if (side) d.setPriestTalentRanksA(ranks.encode()) else d.setPriestTalentRanksB(ranks.encode());
                const s = d.arena.combat();
                const own = if (side) "_a" else "_b";
                s.distance[0] = 10;
                const cost = spell[1] * (if (spell[0] == 1) @as(f32, 0.90) else 1) * (if (mode == 1) @as(f32, 0.5) else 1);
                @field(s, "mana" ++ own)[0] = cost - 0.01;
                try std.testing.expect(!(if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[spell[0]][0]);
                @field(s, "mana" ++ own)[0] = cost;
                if (mode == 2) {
                    @field(s, "soul_link" ++ own)[0] = 1;
                    @field(s, "mana" ++ own)[0] = 0;
                }
                try std.testing.expect((if (side) d.getActionMaskA(0) else d.getActionMaskB(0))[spell[0]][0]);
                if (side) d.apply(@splat(.{ .ability = spell[0] }), @splat(.{})) else d.apply(@splat(.{}), @splat(.{ .ability = spell[0] }));
                try std.testing.expectApproxEqAbs(@as(f32, 0), @field(s, "mana" ++ own)[0], 0.0001);
                // Cast-time spells retain Inner Focus until completion.
                if (mode == 2 and spell[0] == 1) try std.testing.expectEqual(@as(u32, 0), @field(s, "soul_link" ++ own)[0]);
            }
        }
    }
}
