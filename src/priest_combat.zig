//! Vectorized SIMD combat kernels for the Forever Priest kit.
//! Reuses existing aligned WarlockArenaPool and extras SoA columns so Snapshot
//! size and MCTS staging speed remain 100% unchanged.
const simd = @import("simd.zig");
const combat_spec = @import("combat_spec.zig");
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Priest = spec_mod.Priest;
const Frost = spec_mod.Frost;
const WarlockConstants = combat_spec.WarlockConstants;
const priest_talents = @import("priest_talents.zig");
const resolution = @import("spell_resolution.zig");
const periodic = @import("periodic.zig");
const projectiles = @import("projectiles.zig");
const racials = @import("racials.zig");
const pushback = @import("pushback.zig");

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

/// Stuns have their own DR category; Horror and Fear remain independent.
pub fn tickStuns(state: anytype, i: usize, dt: f32) void {
    inline for (.{ true, false }) |side| {
        const timer = col(state, "stun_timer", side, i);
        const tier = col(state, "stun_dr_tier", side, i);
        const reset = col(state, "stun_dr_timer", side, i);
        const elapsed = @min(splat(dt), timer.*);
        timer.* = @max(splat(0), timer.* - splat(dt));
        reset.* = @max(splat(0), reset.* - (splat(dt) - elapsed));
        tier.* = select16(reset.* <= splat(0), splat(0), tier.*);
    }
}

pub fn procBlackout(state: anytype, comptime side_a: bool, i: usize, landed: bool16, effects: priest_talents.Effects) void {
    const eligible = vAnd16(landed, vAnd16(effects.blackout_proc_chance > splat(0), vAnd16(col(state, "hp", side_a, i).* > splat(0), col(state, "hp", !side_a, i).* > splat(0))));
    if (!@reduce(.Or, eligible)) return;
    const roll = resolution.rollSpell(state, side_a, i, eligible);
    const tier = col(state, "stun_dr_tier", !side_a, i);
    const duration = splat(3) * getDrMultiplier(tier.*);
    const procced = vAnd16(eligible, vAnd16(roll < effects.blackout_proc_chance, duration > splat(0)));
    const timer = col(state, "stun_timer", !side_a, i);
    timer.* = select16(procced, @max(timer.*, duration), timer.*);
    tier.* = select16(procced, @min(splat(3), tier.* + splat(1)), tier.*);
    const reset = col(state, "stun_dr_timer", !side_a, i);
    reset.* = select16(procced, splat(WarlockConstants.DrResetDuration), reset.*);
    const cast = ucol(state, "cast_id", !side_a, i);
    cast.* = @select(u32, procced, ids(0), cast.*);
    inline for (.{ "cast_timer", "cast_total", "move_intent", "react_timer" }) |name| {
        const value = col(state, name, !side_a, i);
        value.* = select16(procced, splat(0), value.*);
    }
    pushback.reset(state, !side_a, i, procced);
}

fn col(state: anytype, comptime name: []const u8, comptime side_a: bool, i: usize) *align(64) f32x16 {
    return @ptrCast(@alignCast(@field(state, name ++ (if (side_a) "_a" else "_b"))[i..][0..VEC_LEN]));
}

fn ucol(state: anytype, comptime name: []const u8, comptime side_a: bool, i: usize) *align(64) u32x16 {
    return @ptrCast(@alignCast(@field(state, name ++ (if (side_a) "_a" else "_b"))[i..][0..VEC_LEN]));
}

pub fn shadowWeavingMultiplier(state: anytype, comptime side_a: bool, i: usize) f32x16 {
    const tmr = col(state, "shadow_flame_timer", side_a, i).*;
    const stacks = col(state, "soul_shards", side_a, i).*;
    return select16(tmr > splat(0), splat(1.0) + stacks * splat(Priest.ShadowWeavingPerStack), splat(1.0));
}

pub fn procShadowWeaving(state: anytype, comptime side_a: bool, i: usize, mask: bool16, effects: priest_talents.Effects) void {
    const eligible = vAnd16(mask, effects.shadow_weaving_proc_chance > splat(0));
    if (!@reduce(.Or, eligible)) return;
    const roll = resolution.rollSpell(state, side_a, i, eligible);
    const procced = vAnd16(eligible, roll < effects.shadow_weaving_proc_chance);
    if (!@reduce(.Or, procced)) return;
    const tmr = col(state, "shadow_flame_timer", side_a, i);
    const stacks = col(state, "soul_shards", side_a, i);
    const old_stacks = select16(tmr.* > splat(0), stacks.*, splat(0));
    stacks.* = select16(procced, @min(splat(Priest.ShadowWeavingMaxStacks), old_stacks + splat(1.0)), stacks.*);
    tmr.* = select16(procced, splat(Priest.ShadowWeavingDuration), tmr.*);
}

pub fn observations(arena: anytype, comptime side_a: bool, i: usize, base_obs: [24]f32x16) [24]f32x16 {
    var obs = base_obs;
    const state = &arena.state;
    // Own Renew HoT (slot 8) and Inner Focus active (slot 9)
    obs[8] = col(state, "shadow_lockout", side_a, i).* * splat(1.0 / Priest.RenewDuration);
    obs[9] = select16(ucol(state, "soul_link", side_a, i).* != ids(0), splat(1.0), splat(0.0));
    // Target DoTs: SW:P (10), Devouring Plague (11), Vampiric Embrace (12), Holy Fire (13)
    obs[10] = col(state, "agony_timer", !side_a, i).* * splat(1.0 / Priest.SwpDuration);
    obs[11] = col(state, "corruption_timer", !side_a, i).* * splat(1.0 / Priest.DevouringPlagueDuration);
    obs[12] = col(state, "siphon_timer", !side_a, i).* * splat(1.0 / Priest.VampiricEmbraceDuration);
    obs[13] = col(state, "immolate_timer", !side_a, i).* * splat(1.0 / Priest.HolyFireDuration);
    // Lockout on self (14), PW:S cd (15), PW:S absorb (16), Shadow Weaving stacks (17)
    obs[14] = arena.extra(.lockout, side_a, i).* * splat(1.0 / Priest.SilenceDuration);
    obs[15] = col(state, "action6_cd", side_a, i).* * splat(1.0 / Priest.ShieldCooldown);
    obs[16] = arena.extra(.shield, side_a, i).* * splat(1.0 / Priest.ShieldAbsorb);
    obs[17] = select16(col(state, "shadow_flame_timer", side_a, i).* > splat(0), col(state, "soul_shards", side_a, i).* * splat(1.0 / Priest.ShadowWeavingMaxStacks), splat(0));
    // Devouring Plague CD (18), Target Fear DR (19), Mind Blast CD (20), SW:D CD (21), Silence CD (22), Psychic Scream CD (23)
    obs[18] = arena.extra(.blink, side_a, i).* * splat(1.0 / Priest.DevouringPlagueCooldown);
    obs[19] = col(state, "fear_dr_tier", !side_a, i).* * splat(1.0 / 3.0);
    obs[20] = col(state, "death_coil_cd", side_a, i).* * splat(1.0 / Priest.MindBlastCooldown);
    obs[21] = col(state, "shadowburn_cd", side_a, i).* * splat(1.0 / Priest.ShadowWordDeathCooldown);
    obs[22] = col(state, "seduction_cd", side_a, i).* * splat(1.0 / Priest.SilenceCooldown);
    obs[23] = arena.extra(.nova, side_a, i).* * splat(1.0 / Priest.PsychicScreamCooldown);
    return obs;
}

// Rank-two Dispel Magic removes at most two eligible auras. Fixed priority keeps
// snapshots deterministic; curses, diseases, stuns and cooldowns are untouched.
fn dispelSelf(arena: anytype, comptime side: bool, i: usize, used: bool16, comptime opponent: Spec) void {
    var remaining = select16(used, splat(2), splat(0));
    if (opponent == .warlock) {
        inline for (.{ "fear_timer", "seduction_timer", "corruption_timer", "immolate_timer", "siphon_timer" }) |name| removeAura(col(&arena.state, name, side, i), &remaining);
    } else if (opponent == .frost_mage) {
        inline for (.{ "fear_timer", "agony_timer", "corruption_timer" }) |name| removeAura(col(&arena.state, name, side, i), &remaining);
    } else {
        inline for (.{ "fear_timer", "agony_timer", "immolate_timer", "siphon_timer" }) |name| removeAura(col(&arena.state, name, side, i), &remaining);
    }
}
fn removeAura(timer: *align(64) f32x16, remaining: *f32x16) void {
    const removed = vAnd16(remaining.* > splat(0), timer.* > splat(0));
    timer.* = select16(removed, splat(0), timer.*);
    remaining.* -= select16(removed, splat(1), splat(0));
}
fn selfDispellable(state: anytype, comptime side: bool, i: usize, comptime opponent: Spec) bool16 {
    var present = col(state, "fear_timer", side, i).* > splat(0);
    if (opponent == .warlock) {
        inline for (.{ "seduction_timer", "corruption_timer", "immolate_timer", "siphon_timer" }) |name| present = vOr16(present, col(state, name, side, i).* > splat(0));
    } else if (opponent == .frost_mage) {
        inline for (.{ "agony_timer", "corruption_timer" }) |name| present = vOr16(present, col(state, name, side, i).* > splat(0));
    } else {
        inline for (.{ "agony_timer", "immolate_timer", "siphon_timer" }) |name| present = vOr16(present, col(state, name, side, i).* > splat(0));
    }
    return present;
}
fn enemyDispellable(arena: anytype, comptime side: bool, i: usize, comptime opponent: Spec) bool16 {
    if (opponent == .warlock) return @splat(false);
    var present = arena.extra(.shield, !side, i).* > splat(0);
    if (opponent == .priest) {
        inline for (.{ "priest_pi_timer", "shadow_lockout" }) |name| present = vOr16(present, col(&arena.state, name, !side, i).* > splat(0));
        present = vOr16(present, ucol(&arena.state, "soul_link", !side, i).* != ids(0));
    }
    return present;
}
pub fn powerInfusionMultiplier(state: anytype, comptime side: bool, i: usize) f32x16 {
    return select16(col(state, "priest_pi_timer", side, i).* > splat(0), splat(1.2), splat(1));
}
pub fn dynamicEffects(state: anytype, comptime side: bool, i: usize) priest_talents.Effects {
    var fx = priest_talents.decode(ucol(state, "talent_ranks", side, i).*, ucol(state, "talent_flags", side, i).*, ucol(state, "talent_extra", side, i).*);
    const mult = powerInfusionMultiplier(state, side, i);
    fx.shadow_damage_mult *= mult;
    fx.holy_damage_mult *= mult;
    fx.healing_mult *= mult;
    fx.renew_healing_mult *= mult;
    return fx;
}

pub fn masks(arena: anytype, comptime side_a: bool, i: usize) [combat_spec.WarlockAction.COUNT]bool16 {
    const state = &arena.state;
    const alive = vAnd16(state.is_active[i..][0..VEC_LEN].* != ids(0), vAnd16(col(state, "hp", side_a, i).* > splat(0), col(state, "hp", !side_a, i).* > splat(0)));
    const unlocked = arena.extra(.lockout, side_a, i).* <= splat(0);
    const mana = col(state, "mana", side_a, i).*;
    const free_gcd = col(state, "gcd", side_a, i).* <= splat(0);
    const casting = ucol(state, "cast_id", side_a, i).* != ids(0);
    const seduction = @max(col(state, "seduction_timer", side_a, i).*, col(state, "stun_timer", side_a, i).*);
    const cc = vOr16(vNot16(alive), vOr16(vOr16(col(state, "fear_timer", side_a, i).* > splat(0), col(state, "horror_timer", side_a, i).* > splat(0)), seduction > splat(0)));
    const free = vAnd16(vNot16(cc), vNot16(casting));
    const spell = vAnd16(free, vAnd16(free_gcd, unlocked));
    const distance: f32x16 = state.distance[i..][0..VEC_LEN].*;
    const room = projectiles.available(state, side_a, i);

    const encoded = ucol(state, "talent_ranks", side_a, i).*;
    const flags = ucol(state, "talent_flags", side_a, i).*;
    const effects = dynamicEffects(state, side_a, i);
    const inner_focus_active = ucol(state, "soul_link", side_a, i).* != ids(0);
    const cost_mult = select16(inner_focus_active, splat(0), splat(1));
    const shadow_inst_mult = cost_mult * effects.instant_mana_mult * effects.shadow_mana_mult;
    const shadow_cast_mult = cost_mult * effects.shadow_mana_mult;
    const holy_inst_mult = cost_mult * effects.instant_mana_mult;
    const can_holy_heal = vNot16(effects.has_shadowform);

    var result: [combat_spec.WarlockAction.COUNT]bool16 = @splat(@as(bool16, @splat(false)));
    result[0] = @splat(true);
    // 1: Shadow Word: Pain
    result[1] = vAnd16(spell, vAnd16(distance <= (splat(Priest.SwpRange) * effects.shadow_range_mult), mana >= splat(Priest.SwpMana) * shadow_inst_mult));
    // 2: Devouring Plague
    result[2] = vAnd16(spell, vAnd16(distance <= (splat(Priest.DevouringPlagueRange) * effects.shadow_range_mult), vAnd16(arena.extra(.blink, side_a, i).* <= splat(0), mana >= splat(Priest.DevouringPlagueMana) * cost_mult * effects.devouring_plague_mana_mult)));
    // 3: Psychic Scream
    result[3] = vAnd16(spell, vAnd16(distance <= splat(Priest.PsychicScreamRange), vAnd16(arena.extra(.nova, side_a, i).* <= splat(0), mana >= splat(Priest.PsychicScreamMana) * shadow_inst_mult)));
    // 4: Mind Blast
    result[4] = vAnd16(room, vAnd16(spell, vAnd16(distance <= (splat(Priest.MindBlastRange) * effects.shadow_range_mult), vAnd16(col(state, "death_coil_cd", side_a, i).* <= splat(0), mana >= splat(Priest.MindBlastMana) * shadow_cast_mult))));
    // 5: Mind Flay (talent-gated)
    result[5] = vAnd16(priest_talents.mindFlayUnlocked(flags), vAnd16(spell, vAnd16(distance <= effects.mind_flay_range * effects.shadow_range_mult, mana >= splat(Priest.MindFlayMana) * shadow_cast_mult)));
    // 6: Power Word: Shield
    result[6] = vAnd16(spell, vAnd16(col(state, "action6_cd", side_a, i).* <= splat(0), mana >= splat(Priest.ShieldMana) * cost_mult * effects.shield_mana_mult));
    // 7: Silence (talent-gated, off-GCD interrupt/silence!)
    result[7] = vAnd16(priest_talents.silenceUnlocked(flags), vAnd16(vNot16(cc), vAnd16(unlocked, vAnd16(distance <= (splat(Priest.SilenceRange) * effects.shadow_range_mult), vAnd16(col(state, "seduction_cd", side_a, i).* <= splat(0), mana >= splat(Priest.SilenceMana) * shadow_inst_mult)))));
    // 8: Vampiric Embrace (talent-gated)
    result[8] = vAnd16(priest_talents.vampiricEmbraceUnlocked(flags), vAnd16(spell, vAnd16(distance <= (splat(Priest.VampiricEmbraceRange) * effects.shadow_range_mult), vAnd16(col(state, "seduction_cast", side_a, i).* <= splat(0), mana >= splat(Priest.VampiricEmbraceMana) * shadow_inst_mult))));
    // 9: Shadow Word: Death
    result[9] = vAnd16(spell, vAnd16(distance <= (splat(Priest.ShadowWordDeathRange) * effects.shadow_range_mult), vAnd16(col(state, "shadowburn_cd", side_a, i).* <= splat(0), mana >= splat(Priest.ShadowWordDeathMana) * shadow_inst_mult)));
    // 10: Cancel Cast
    result[10] = vAnd16(casting, alive);
    // 11: Flash Heal (blocked in Shadowform)
    result[11] = vAnd16(can_holy_heal, vAnd16(spell, mana >= splat(Priest.FlashHealMana) * cost_mult));
    // 12: Renew (blocked in Shadowform)
    result[12] = vAnd16(can_holy_heal, vAnd16(spell, mana >= splat(Priest.RenewMana) * holy_inst_mult));
    // 13: Holy Fire (allowed in Shadowform per Forever talents.go!)
    result[13] = vAnd16(room, vAnd16(spell, vAnd16(distance <= splat(Priest.HolyFireRange), mana >= splat(Priest.HolyFireMana) * holy_inst_mult)));
    // 14: Smite (allowed in Shadowform per Forever talents.go!)
    result[14] = vAnd16(room, vAnd16(spell, vAnd16(distance <= splat(Priest.SmiteRange), mana >= splat(Priest.SmiteMana) * holy_inst_mult)));
    // 15: Penance (talent-gated, blocked in Shadowform)
    result[15] = vAnd16(priest_talents.penanceUnlocked(encoded), vAnd16(can_holy_heal, vAnd16(spell, vAnd16(distance <= splat(Priest.PenanceRange), vAnd16(col(state, "conflagrate_cd", side_a, i).* <= splat(0), mana >= splat(Priest.PenanceMana) * cost_mult)))));
    // 16: Inner Focus (talent-gated, off-GCD)
    result[16] = vAnd16(priest_talents.innerFocusUnlocked(encoded), vAnd16(free, vAnd16(col(state, "fire_lockout", side_a, i).* <= splat(0), vNot16(inner_focus_active))));

    const Arena = @TypeOf(arena.*);
    const opponent = if (side_a) Arena.SpecB else Arena.SpecA;
    const extra = ucol(state, "talent_extra", side_a, i).*;
    result[21] = vAnd16(free, vAnd16(unlocked, vAnd16((extra & ids(1 << 5)) != ids(0), vAnd16(col(state, "priest_pi_cd", side_a, i).* <= splat(0), mana >= splat(200) * cost_mult))));
    result[22] = vAnd16(spell, vAnd16(mana >= splat(180) * holy_inst_mult, selfDispellable(state, side_a, i, opponent)));
    result[23] = vAnd16(spell, vAnd16(distance <= splat(30), vAnd16(mana >= splat(180) * holy_inst_mult, enemyDispellable(arena, side_a, i, opponent))));
    result[24] = vAnd16(spell, vAnd16(distance <= splat(30) * effects.shadow_range_mult, vAnd16(mana >= splat(270) * shadow_cast_mult, col(state, "mana", !side_a, i).* > splat(0))));
    racials.fillMasks(state, side_a, i, &result);
    return result;
}

pub fn apply(arena: anytype, comptime side_a: bool, i: usize, requested: u32x16, movement: f32x16, comptime staged: bool, comptime opponent: Spec) void {
    const state = &arena.state;
    const active = state.is_active[i..][0..VEC_LEN].* != ids(0);
    var actions = ids(0);
    if (staged) {
        actions = @select(u32, active, requested, ids(0));
    } else {
        const legal = masks(arena, side_a, i);
        inline for (1..combat_spec.WarlockAction.COUNT) |action| {
            actions = @select(u32, vAnd16(active, vAnd16(requested == ids(action), legal[action])), ids(action), actions);
        }
    }

    const effects = dynamicEffects(state, side_a, i);
    const target_cc_mult = if (opponent == .priest)
        priest_talents.decode(ucol(state, "talent_ranks", !side_a, i).*, ucol(state, "talent_flags", !side_a, i).*, ucol(state, "talent_extra", !side_a, i).*).cc_duration_mult
    else
        splat(1.0);

    const cc = vOr16(vOr16(col(state, "fear_timer", side_a, i).* > splat(0), col(state, "horror_timer", side_a, i).* > splat(0)), @max(col(state, "seduction_timer", side_a, i).*, col(state, "stun_timer", side_a, i).*) > splat(0));
    const cast = ucol(state, "cast_id", side_a, i);
    const timer = col(state, "cast_timer", side_a, i);
    const total = col(state, "cast_total", side_a, i);

    const cancel = actions == ids(10);
    const starts_cast_or_channel = vOr16(vOr16(actions == ids(4), actions == ids(5)), vOr16(vOr16(actions == ids(11), actions == ids(13)), vOr16(actions == ids(14), actions == ids(15))));
    pushback.reset(state, side_a, i, vOr16(cancel, vOr16(starts_cast_or_channel, actions == ids(24))));
    cast.* = @select(u32, cancel, ids(0), cast.*);
    timer.* = select16(cancel, splat(0), timer.*);
    total.* = select16(cancel, splat(0), total.*);

    col(state, "move_intent", side_a, i).* = select16(vOr16(cc, cast.* != ids(0)), splat(0), movement);
    col(state, "react_timer", side_a, i).* = splat(WarlockConstants.ReactionInterval);

    const mana = col(state, "mana", side_a, i);
    const gcd = col(state, "gcd", side_a, i);
    const inner_focus_flag = ucol(state, "soul_link", side_a, i);
    const inner_focus_cd = col(state, "fire_lockout", side_a, i);

    // 16: Inner Focus (off-GCD)
    const is_inner_focus = actions == ids(16);
    inner_focus_flag.* = @select(u32, is_inner_focus, ids(1), inner_focus_flag.*);
    inner_focus_cd.* = select16(is_inner_focus, splat(Priest.InnerFocusCooldown), inner_focus_cd.*);

    const if_active = inner_focus_flag.* != ids(0);
    const cost_mult = select16(if_active, splat(0.0), splat(1.0));
    const shadow_inst_mult = cost_mult * effects.instant_mana_mult * effects.shadow_mana_mult;
    const shadow_cast_mult = cost_mult * effects.shadow_mana_mult;
    const holy_inst_mult = cost_mult * effects.instant_mana_mult;
    const gcd_dur = @max(splat(1.0), splat(1.0) / racials.hasteMultiplier(state, side_a, i));

    // 1: Shadow Word: Pain
    const is_swp = actions == ids(1);
    mana.* = select16(is_swp, mana.* - splat(Priest.SwpMana) * shadow_inst_mult, mana.*);
    gcd.* = select16(is_swp, gcd_dur, gcd.*);
    const swp_landed = periodic.application(state, side_a, i, is_swp, effects.shadow_hit_bonus, .shadow);
    col(state, "agony_timer", !side_a, i).* = select16(swp_landed, effects.swp_duration, col(state, "agony_timer", !side_a, i).*);
    procShadowWeaving(state, side_a, i, swp_landed, effects);

    // 2: Devouring Plague
    const is_dp = actions == ids(2);
    mana.* = select16(is_dp, mana.* - splat(Priest.DevouringPlagueMana) * cost_mult * effects.devouring_plague_mana_mult, mana.*);
    gcd.* = select16(is_dp, gcd_dur, gcd.*);
    arena.extra(.blink, side_a, i).* = select16(is_dp, splat(Priest.DevouringPlagueCooldown), arena.extra(.blink, side_a, i).*);
    const dp_landed = periodic.application(state, side_a, i, is_dp, effects.shadow_hit_bonus, .shadow);
    col(state, "corruption_timer", !side_a, i).* = select16(dp_landed, splat(Priest.DevouringPlagueDuration), col(state, "corruption_timer", !side_a, i).*);
    procShadowWeaving(state, side_a, i, dp_landed, effects);

    // 3: Psychic Scream (Instant AoE Fear)
    const is_scream = actions == ids(3);
    mana.* = select16(is_scream, mana.* - splat(Priest.PsychicScreamMana) * shadow_inst_mult, mana.*);
    gcd.* = select16(is_scream, gcd_dur, gcd.*);
    arena.extra(.nova, side_a, i).* = select16(is_scream, effects.psychic_scream_cooldown, arena.extra(.nova, side_a, i).*);
    const scream_hit = periodic.control(state, side_a, i, vAnd16(is_scream, racials.canImpair(state, !side_a, i)), effects.shadow_hit_bonus, .shadow, false);
    const fear_dr = col(state, "fear_dr_tier", !side_a, i);
    const scream_dur = splat(Priest.PsychicScreamDuration) * getDrMultiplier(fear_dr.*) * target_cc_mult;
    const scream_applied = vAnd16(scream_hit, scream_dur > splat(0));
    col(state, "fear_timer", !side_a, i).* = select16(scream_applied, scream_dur, col(state, "fear_timer", !side_a, i).*);
    col(state, "fear_accum_dmg", !side_a, i).* = select16(scream_hit, splat(0), col(state, "fear_accum_dmg", !side_a, i).*);
    fear_dr.* = select16(scream_hit, @min(splat(3.0), fear_dr.* + splat(1.0)), fear_dr.*);
    col(state, "fear_dr_timer", !side_a, i).* = select16(scream_hit, splat(WarlockConstants.DrResetDuration), col(state, "fear_dr_timer", !side_a, i).*);
    ucol(state, "cast_id", !side_a, i).* = @select(u32, scream_applied, ids(0), ucol(state, "cast_id", !side_a, i).*);
    col(state, "cast_timer", !side_a, i).* = select16(scream_applied, splat(0), col(state, "cast_timer", !side_a, i).*);
    col(state, "cast_total", !side_a, i).* = select16(scream_applied, splat(0), col(state, "cast_total", !side_a, i).*);
    col(state, "react_timer", !side_a, i).* = select16(scream_applied, splat(0), col(state, "react_timer", !side_a, i).*);

    // 4: Mind Blast (1.5s cast)
    const is_mb = actions == ids(4);
    mana.* = select16(is_mb, mana.* - splat(Priest.MindBlastMana) * shadow_cast_mult, mana.*);
    gcd.* = select16(is_mb, gcd_dur, gcd.*);
    cast.* = @select(u32, is_mb, ids(4), cast.*);
    timer.* = select16(is_mb, splat(Priest.MindBlastCast), timer.*);
    total.* = select16(is_mb, splat(Priest.MindBlastCast), total.*);
    col(state, "move_intent", side_a, i).* = select16(is_mb, splat(0), col(state, "move_intent", side_a, i).*);

    // 5: Mind Flay (3.0s channel)
    const is_mf = actions == ids(5);
    mana.* = select16(is_mf, mana.* - splat(Priest.MindFlayMana) * shadow_cast_mult, mana.*);
    gcd.* = select16(is_mf, gcd_dur, gcd.*);
    const mf_landed = periodic.application(state, side_a, i, is_mf, effects.shadow_hit_bonus, .shadow);
    cast.* = @select(u32, mf_landed, ids(5), cast.*);
    timer.* = select16(mf_landed, splat(Priest.MindFlayDuration), timer.*);
    total.* = select16(mf_landed, splat(Priest.MindFlayDuration), total.*);
    col(state, "move_intent", side_a, i).* = select16(is_mf, splat(0), col(state, "move_intent", side_a, i).*);
    procShadowWeaving(state, side_a, i, mf_landed, effects);

    // 6: Power Word: Shield
    const is_pws = actions == ids(6);
    mana.* = select16(is_pws, mana.* - splat(Priest.ShieldMana) * cost_mult * effects.shield_mana_mult, mana.*);
    gcd.* = select16(is_pws, gcd_dur, gcd.*);
    arena.extra(.shield, side_a, i).* = select16(is_pws, (splat(Priest.ShieldAbsorb) + resolution.spellPower(state, side_a, i, .holy) * splat(Priest.ShieldCoefficient)) * effects.shield_absorb_mult, arena.extra(.shield, side_a, i).*);
    col(state, "action6_dur", side_a, i).* = select16(is_pws, splat(Priest.ShieldDuration), col(state, "action6_dur", side_a, i).*);
    col(state, "action6_cd", side_a, i).* = select16(is_pws, effects.shield_cooldown, col(state, "action6_cd", side_a, i).*);

    // 7: Silence (off-GCD interrupt + 5s spell lockout)
    const is_silence = actions == ids(7);
    mana.* = select16(is_silence, mana.* - splat(Priest.SilenceMana) * shadow_inst_mult, mana.*);
    col(state, "seduction_cd", side_a, i).* = select16(is_silence, splat(Priest.SilenceCooldown), col(state, "seduction_cd", side_a, i).*);
    const silenced = periodic.control(state, side_a, i, is_silence, effects.shadow_hit_bonus, .shadow, false);
    ucol(state, "cast_id", !side_a, i).* = @select(u32, silenced, ids(0), ucol(state, "cast_id", !side_a, i).*);
    col(state, "cast_timer", !side_a, i).* = select16(silenced, splat(0), col(state, "cast_timer", !side_a, i).*);
    col(state, "cast_total", !side_a, i).* = select16(silenced, splat(0), col(state, "cast_total", !side_a, i).*);
    arena.extra(.lockout, !side_a, i).* = select16(silenced, splat(Priest.SilenceDuration) * target_cc_mult, arena.extra(.lockout, !side_a, i).*);
    col(state, "react_timer", !side_a, i).* = select16(silenced, splat(0), col(state, "react_timer", !side_a, i).*);

    // 8: Vampiric Embrace
    const is_ve = actions == ids(8);
    mana.* = select16(is_ve, mana.* - splat(Priest.VampiricEmbraceMana) * shadow_inst_mult, mana.*);
    gcd.* = select16(is_ve, gcd_dur, gcd.*);
    col(state, "seduction_cast", side_a, i).* = select16(is_ve, splat(Priest.VampiricEmbraceCooldown), col(state, "seduction_cast", side_a, i).*);
    const ve_landed = periodic.application(state, side_a, i, is_ve, effects.shadow_hit_bonus, .shadow);
    col(state, "siphon_timer", !side_a, i).* = select16(ve_landed, splat(Priest.VampiricEmbraceDuration), col(state, "siphon_timer", !side_a, i).*);
    procShadowWeaving(state, side_a, i, ve_landed, effects);

    // 9: Shadow Word: Death (Instant direct Shadow nuke + Early Demise execute crit)
    const is_swd = actions == ids(9);
    mana.* = select16(is_swd, mana.* - splat(Priest.ShadowWordDeathMana) * shadow_inst_mult, mana.*);
    gcd.* = select16(is_swd, gcd_dur, gcd.*);
    col(state, "shadowburn_cd", side_a, i).* = select16(is_swd, splat(Priest.ShadowWordDeathCooldown), col(state, "shadowburn_cd", side_a, i).*);
    if (@reduce(.Or, is_swd)) {
        const target_hp = col(state, "hp", !side_a, i).*;
        const target_max_hp = col(state, "max_health", !side_a, i).*;
        const in_execute = target_hp <= target_max_hp * splat(0.20);
        const crit_bonus = select16(in_execute, effects.early_demise_crit_bonus, splat(0.0)) + select16(if_active, splat(Priest.InnerFocusCritBonus), splat(0.0));
        const sw_mult = shadowWeavingMultiplier(state, side_a, i);
        const raw_swd = (splat(Priest.ShadowWordDeathDamage) + resolution.spellPower(state, side_a, i, .shadow) * splat(0.429)) * effects.shadow_damage_mult * effects.instant_damage_mult * sw_mult;
        const resolved = resolution.resolve(state, side_a, i, raw_swd, is_swd, .{
            .school = .shadow,
            .hit_bonus = effects.shadow_hit_bonus,
            .crit_bonus = crit_bonus,
            .crit_multiplier = effects.shadow_crit_multiplier,
        });
        col(state, "conflagrate_pending", side_a, i).* += select16(is_swd, resolved.damage, splat(0));
        procShadowWeaving(state, side_a, i, resolved.landed, effects);
    }

    // 11: Flash Heal (1.5s cast)
    const is_fh = actions == ids(11);
    mana.* = select16(is_fh, mana.* - splat(Priest.FlashHealMana) * cost_mult, mana.*);
    gcd.* = select16(is_fh, gcd_dur, gcd.*);
    cast.* = @select(u32, is_fh, ids(11), cast.*);
    timer.* = select16(is_fh, splat(Priest.FlashHealCast), timer.*);
    total.* = select16(is_fh, splat(Priest.FlashHealCast), total.*);
    col(state, "move_intent", side_a, i).* = select16(is_fh, splat(0), col(state, "move_intent", side_a, i).*);

    // 12: Renew (Instant HoT)
    const is_renew = actions == ids(12);
    mana.* = select16(is_renew, mana.* - splat(Priest.RenewMana) * holy_inst_mult, mana.*);
    gcd.* = select16(is_renew, gcd_dur, gcd.*);
    col(state, "shadow_lockout", side_a, i).* = select16(is_renew, splat(Priest.RenewDuration), col(state, "shadow_lockout", side_a, i).*);

    // 13: Holy Fire (3.5s - Divine Fury cast)
    const is_hf = actions == ids(13);
    mana.* = select16(is_hf, mana.* - splat(Priest.HolyFireMana) * holy_inst_mult, mana.*);
    gcd.* = select16(is_hf, gcd_dur, gcd.*);
    cast.* = @select(u32, is_hf, ids(13), cast.*);
    timer.* = select16(is_hf, effects.holy_fire_cast_time, timer.*);
    total.* = select16(is_hf, effects.holy_fire_cast_time, total.*);
    col(state, "move_intent", side_a, i).* = select16(is_hf, splat(0), col(state, "move_intent", side_a, i).*);

    // 14: Smite (2.5s - Divine Fury cast)
    const is_smite = actions == ids(14);
    mana.* = select16(is_smite, mana.* - splat(Priest.SmiteMana) * holy_inst_mult, mana.*);
    gcd.* = select16(is_smite, gcd_dur, gcd.*);
    cast.* = @select(u32, is_smite, ids(14), cast.*);
    timer.* = select16(is_smite, effects.smite_cast_time, timer.*);
    total.* = select16(is_smite, effects.smite_cast_time, total.*);
    col(state, "move_intent", side_a, i).* = select16(is_smite, splat(0), col(state, "move_intent", side_a, i).*);

    // 15: Penance (2.0s channel, 12s CD)
    const is_penance = actions == ids(15);
    mana.* = select16(is_penance, mana.* - splat(Priest.PenanceMana) * cost_mult, mana.*);
    gcd.* = select16(is_penance, gcd_dur, gcd.*);
    col(state, "conflagrate_cd", side_a, i).* = select16(is_penance, splat(Priest.PenanceCooldown), col(state, "conflagrate_cd", side_a, i).*);
    const penance_landed = periodic.application(state, side_a, i, is_penance, effects.holy_hit_bonus, .holy);
    cast.* = @select(u32, penance_landed, ids(15), cast.*);
    timer.* = select16(penance_landed, splat(Priest.PenanceDuration), timer.*);
    total.* = select16(penance_landed, splat(Priest.PenanceDuration), total.*);
    col(state, "move_intent", side_a, i).* = select16(is_penance, splat(0), col(state, "move_intent", side_a, i).*);

    const is_pi = actions == ids(21);
    mana.* = select16(is_pi, mana.* - splat(200) * cost_mult, mana.*);
    col(state, "priest_pi_cd", side_a, i).* = select16(is_pi, splat(180), col(state, "priest_pi_cd", side_a, i).*);
    col(state, "priest_pi_timer", side_a, i).* = select16(is_pi, splat(15), col(state, "priest_pi_timer", side_a, i).*);
    const is_dispel = vOr16(actions == ids(22), actions == ids(23));
    mana.* = select16(is_dispel, mana.* - splat(180) * holy_inst_mult, mana.*);
    gcd.* = select16(is_dispel, splat(1.5), gcd.*);
    dispelSelf(arena, side_a, i, actions == ids(22), opponent);
    const purge = periodic.application(state, side_a, i, actions == ids(23), effects.holy_hit_bonus, .holy);
    if (opponent != .warlock) {
        var remaining = select16(purge, splat(2), splat(0));
        const shield = arena.extra(.shield, !side_a, i);
        const removed = vAnd16(remaining > splat(0), shield.* > splat(0));
        shield.* = select16(removed, splat(0), shield.*);
        col(state, "action6_dur", !side_a, i).* = select16(removed, splat(0), col(state, "action6_dur", !side_a, i).*);
        remaining -= select16(removed, splat(1), splat(0));
        if (opponent == .priest) {
            removeAura(col(state, "priest_pi_timer", !side_a, i), &remaining);
            removeAura(col(state, "shadow_lockout", !side_a, i), &remaining);
            const flag = ucol(state, "soul_link", !side_a, i);
            flag.* = @select(u32, remaining > splat(0), ids(0), flag.*);
        }
    }
    const is_burn = actions == ids(24);
    const burn_rank = (ucol(state, "talent_extra", side_a, i).* >> @as(@Vector(16, u5), @splat(6))) & ids(3);
    const burn_cast = splat(3) - @as(f32x16, @floatFromInt(burn_rank)) * splat(0.5);
    mana.* = select16(is_burn, mana.* - splat(270) * shadow_cast_mult, mana.*);
    gcd.* = select16(is_burn, splat(1.5), gcd.*);
    cast.* = @select(u32, is_burn, ids(24), cast.*);
    timer.* = select16(is_burn, burn_cast, timer.*);
    total.* = select16(is_burn, burn_cast, total.*);
    col(state, "move_intent", side_a, i).* = select16(is_burn, splat(0), col(state, "move_intent", side_a, i).*);

    // Consume Inner Focus on instant spells (cast-time spells consume Inner Focus upon cast completion)
    const old_instant_consumed_if = vOr16(vOr16(is_swp, is_dp), vOr16(vOr16(is_scream, is_pws), vOr16(is_ve, vOr16(is_swd, vOr16(is_renew, is_penance)))));
    const instant_consumed_if = vOr16(old_instant_consumed_if, vOr16(is_pi, is_dispel));
    inner_focus_flag.* = @select(u32, instant_consumed_if, ids(0), inner_focus_flag.*);

    racials.apply(state, side_a, i, actions, opponent);
}

pub fn tickCooldowns(state: anytype, comptime side_a: bool, i: usize, dt: f32) void {
    const v_dt = splat(dt);
    const v_zeros = splat(0.0);
    inline for (.{ "shadowburn_cd", "conflagrate_cd", "fire_lockout", "shadow_flame_timer", "priest_pi_cd", "priest_pi_timer" }) |name| {
        const timer = col(state, name, side_a, i);
        if (@reduce(.Or, timer.* > v_zeros)) {
            timer.* = @max(v_zeros, timer.* - v_dt);
        }
    }
    const sw_tmr = col(state, "shadow_flame_timer", side_a, i).*;
    const sw_stacks = col(state, "soul_shards", side_a, i);
    sw_stacks.* = select16(sw_tmr > v_zeros, sw_stacks.*, v_zeros);
}

pub fn tickPeriodics(
    arena: anytype,
    comptime caster_side_a: bool,
    i: usize,
    dt: f32,
    effects: priest_talents.Effects,
    target_mit: f32x16,
    swp_timer: anytype,
    dp_timer: anytype,
    hf_timer: anytype,
    renew_timer: anytype,
    caster_hp: anytype,
) struct { dmg_swp: f32x16, dmg_dp: f32x16, dmg_hf: f32x16 } {
    const state = &arena.state;
    const v_zeros = splat(0.0);
    const v_true: bool16 = @splat(true);
    const sw_mult = shadowWeavingMultiplier(state, caster_side_a, i);
    const sp_shadow = resolution.spellPower(state, caster_side_a, i, .shadow);
    const sp_holy = resolution.spellPower(state, caster_side_a, i, .holy);

    // 1. Shadow Word: Pain (3s interval, can crit in Forever!)
    const tick_swp = periodic.advance(
        state,
        caster_side_a,
        i,
        swp_timer,
        dt,
        effects.swp_duration,
        3.0,
        (splat(Priest.SwpDps) + sp_shadow * splat(0.06666667)) * effects.shadow_damage_mult * effects.instant_damage_mult * sw_mult,
        v_zeros,
        v_true,
        .{ .school = .shadow, .crit_multiplier = effects.shadow_crit_multiplier, .can_crit = true },
    );

    // 2. Devouring Plague (3s interval, does NOT crit in Forever, leeches 100%)
    const dp_dps = (splat(Priest.DevouringPlagueDps) + sp_shadow * splat(0.033333335)) * effects.shadow_damage_mult * effects.instant_damage_mult * sw_mult;
    const tick_dp = periodic.advance(
        state,
        caster_side_a,
        i,
        dp_timer,
        dt,
        splat(Priest.DevouringPlagueDuration),
        3.0,
        dp_dps,
        dp_dps * effects.healing_mult,
        v_true,
        .{ .school = .shadow, .can_crit = false },
    );

    // 3. Holy Fire DoT (2s interval, 10s duration)
    const tick_hf = periodic.advance(
        state,
        caster_side_a,
        i,
        hf_timer,
        dt,
        splat(Priest.HolyFireDuration),
        2.0,
        (splat(Priest.HolyFireDps) + sp_holy * splat(0.025)) * effects.holy_damage_mult,
        v_zeros,
        v_true,
        .{ .school = .holy, .can_crit = false },
    );

    // 4. Self Renew HoT (stored in caster's shadow_lockout, 3s interval, 15s duration)
    const tick_renew = periodic.advance(
        state,
        caster_side_a,
        i,
        renew_timer,
        dt,
        splat(Priest.RenewDuration),
        3.0,
        v_zeros,
        (splat(Priest.RenewHps) + sp_holy * splat(0.06666667)) * effects.renew_healing_mult,
        v_true,
        .{ .school = .holy, .can_crit = false, .partial = false },
    );

    const max_hp = col(state, "max_health", caster_side_a, i).*;
    const before_dp = caster_hp.*;
    caster_hp.* = @min(max_hp, @as(f32x16, caster_hp.*) + tick_dp.healing);
    if (i == 0) if (arena.priest_recording) |record| {
        record[if (caster_side_a) 0 else 1].healing[2] += caster_hp.*[0] - before_dp[0];
    };
    const before_renew = caster_hp.*;
    caster_hp.* = @min(max_hp, @as(f32x16, caster_hp.*) + tick_renew.healing);
    if (i == 0) if (arena.priest_recording) |record| {
        record[if (caster_side_a) 0 else 1].healing[12] += caster_hp.*[0] - before_renew[0];
    };

    return .{
        .dmg_swp = tick_swp.damage * target_mit,
        .dmg_dp = tick_dp.damage * target_mit,
        .dmg_hf = tick_hf.damage * target_mit,
    };
}

pub fn tickCasts(
    arena: anytype,
    comptime caster_side_a: bool,
    i: usize,
    dt: f32,
    dist: f32x16,
    effects: priest_talents.Effects,
    target_mit: f32x16,
    cast_id: anytype,
    cast_timer: anytype,
    cast_total: anytype,
    react_timer: anytype,
    mb_cd: anytype,
    shield_dur: anytype,
    caster_hp: anytype,
    target_hf_timer: f32x16,
    target_mana: *f32x16,
) struct { shadow_dmg: f32x16, holy_dmg: f32x16, burn_dmg: f32x16 } {
    const state = &arena.state;
    const v_zeros = splat(0.0);
    const casting = cast_id.* > ids(0);
    const cast_clock = cast_timer.*;
    const step = racials.castStep(state, caster_side_a, i, dt);
    cast_timer.* = select16(casting, periodic.remaining(cast_timer.*, step), v_zeros);
    const cast_finished = vAnd16(casting, cast_timer.* <= v_zeros);

    const sw_mult = shadowWeavingMultiplier(state, caster_side_a, i);
    const sp_shadow = resolution.spellPower(state, caster_side_a, i, .shadow);
    const sp_holy = resolution.spellPower(state, caster_side_a, i, .holy);
    const inner_focus_flag = ucol(state, "soul_link", caster_side_a, i);
    const if_active = inner_focus_flag.* != ids(0);
    const pil_mult = select16(target_hf_timer > v_zeros, effects.power_in_light_mult, splat(1.0));

    // 1. Mind Flay Channel (cast_id == 5, 3s duration, 1s tick interval)
    const mf_active = vAnd16(casting, cast_id.* == ids(5));
    const mf_tick = periodic.channel(
        state,
        caster_side_a,
        i,
        cast_clock,
        step,
        Priest.MindFlayDuration,
        1.0,
        (splat(Priest.MindFlayDps) + sp_shadow * splat(0.167)) * effects.shadow_damage_mult * effects.mind_flay_damage_mult * sw_mult,
        v_zeros,
        mf_active,
        .{ .school = .shadow, .crit_multiplier = effects.shadow_crit_multiplier, .can_crit = true },
    );

    // 2. Penance Channel (cast_id == 15, 2s duration, 1s tick interval)
    const penance_active = vAnd16(casting, cast_id.* == ids(15));
    const penance_start = vAnd16(penance_active, col(state, "channel_elapsed", caster_side_a, i).* == v_zeros);
    const penance_tick = periodic.channel(
        state,
        caster_side_a,
        i,
        cast_clock,
        step,
        Priest.PenanceDuration,
        1.0,
        // One bolt at channel start, then one at each full second.
        (splat(131.0) + sp_holy * splat(0.285)) * effects.holy_damage_mult * pil_mult,
        v_zeros,
        penance_active,
        .{ .school = .holy, .crit_bonus = effects.holy_crit_bonus, .crit_multiplier = splat(1.5), .can_crit = true },
    );

    const opening_bolt = resolution.periodic(state, caster_side_a, i, splat(1), penance_start, .{ .school = .holy, .crit_bonus = effects.holy_crit_bonus, .crit_multiplier = splat(1.5), .can_crit = true });
    const penance_damage = penance_tick.damage + opening_bolt.damage * (splat(131.0) + sp_holy * splat(0.285)) * effects.holy_damage_mult * pil_mult;

    // 3. Mind Blast completion (cast_id == 4)
    const mb_hit = vAnd16(vAnd16(cast_finished, dist <= (splat(Priest.MindBlastRange) * effects.shadow_range_mult)), cast_id.* == ids(4));
    mb_cd.* = select16(mb_hit, effects.mind_blast_cooldown, mb_cd.*);
    projectiles.launchClass(
        state,
        caster_side_a,
        i,
        4,
        (splat(Priest.MindBlastDamage) + sp_shadow * splat(0.429)) * effects.shadow_damage_mult * sw_mult,
        mb_hit,
        Spec.priest,
    );
    procShadowWeaving(state, caster_side_a, i, mb_hit, effects);

    // 4. Flash Heal completion (cast_id == 11)
    const fh_done = vAnd16(cast_finished, cast_id.* == ids(11));
    if (@reduce(.Or, fh_done)) {
        const shield_val = arena.extra(.shield, caster_side_a, i);
        const shielded = shield_val.* > v_zeros;
        const crit_bonus = effects.holy_crit_bonus + select16(shielded, effects.renewed_hope_crit_bonus, v_zeros) + select16(if_active, splat(Priest.InnerFocusCritBonus), v_zeros);
        const base_heal = (splat(Priest.FlashHealAmount) + sp_holy * splat(0.429)) * effects.healing_mult;
        const resolved = resolution.resolve(state, caster_side_a, i, base_heal, fh_done, .{
            .school = .holy,
            .hit_bonus = splat(1.0),
            .crit_bonus = crit_bonus,
            .crit_multiplier = splat(1.5),
            .partial = false,
        });
        const max_hp = col(state, "max_health", caster_side_a, i).*;
        const before_heal = caster_hp.*;
        caster_hp.* = @min(max_hp, @as(f32x16, caster_hp.*) + select16(fh_done, resolved.damage, v_zeros));
        if (i == 0) if (arena.priest_recording) |record| {
            record[if (caster_side_a) 0 else 1].healing[11] += caster_hp.*[0] - before_heal[0];
        };
        // Divine Aegis: critical heals create a protective shield for 5%/10%/15% of the amount healed
        const is_crit = ucol(state, "spell_outcome", caster_side_a, i).* == ids(@intFromEnum(resolution.Outcome.crit));
        const aegis = select16(vAnd16(fh_done, is_crit), resolved.damage * effects.divine_aegis_mult, v_zeros);
        shield_val.* += aegis;
        shield_dur.* = select16(aegis > v_zeros, @max(@as(f32x16, shield_dur.*), splat(12.0)), shield_dur.*);
    }

    // 5. Holy Fire completion (cast_id == 13)
    const hf_hit = vAnd16(vAnd16(cast_finished, dist <= splat(Priest.HolyFireRange)), cast_id.* == ids(13));
    projectiles.launchClass(
        state,
        caster_side_a,
        i,
        13,
        (splat(Priest.HolyFireInitialDamage) + sp_holy * splat(0.75)) * effects.holy_damage_mult,
        hf_hit,
        Spec.priest,
    );

    // 6. Smite completion (cast_id == 14)
    const smite_hit = vAnd16(vAnd16(cast_finished, dist <= splat(Priest.SmiteRange)), cast_id.* == ids(14));
    projectiles.launchClass(
        state,
        caster_side_a,
        i,
        14,
        (splat(Priest.SmiteDamage) + sp_holy * splat(0.714)) * effects.holy_damage_mult * pil_mult,
        smite_hit,
        Spec.priest,
    );

    const burn_done = vAnd16(cast_finished, vAnd16(cast_id.* == ids(24), dist <= splat(30) * effects.shadow_range_mult));
    const burn_hit = periodic.application(state, caster_side_a, i, burn_done, effects.shadow_hit_bonus, .shadow);
    const burned = select16(burn_hit, @min(@as(f32x16, target_mana.*), splat(767)), v_zeros);
    target_mana.* = @as(f32x16, target_mana.*) - burned;
    // Resource loss bypasses absorption; the damage enters normal mitigation/shields.
    const burn_damage = burned * splat(0.5) * effects.shadow_damage_mult * sw_mult * target_mit;
    procShadowWeaving(state, caster_side_a, i, burn_hit, effects);

    // Consume Inner Focus when a cast-time spell finishes
    inner_focus_flag.* = @select(u32, cast_finished, ids(0), inner_focus_flag.*);

    cast_id.* = @select(u32, cast_finished, ids(0), cast_id.*);
    cast_timer.* = select16(cast_finished, v_zeros, cast_timer.*);
    cast_total.* = select16(cast_finished, v_zeros, cast_total.*);
    react_timer.* = select16(cast_finished, v_zeros, react_timer.*);

    return .{
        .shadow_dmg = mf_tick.damage * target_mit + burn_damage,
        .burn_dmg = burn_damage,
        .holy_dmg = penance_damage * target_mit,
    };
}
