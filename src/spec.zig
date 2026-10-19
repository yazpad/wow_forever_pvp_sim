const std = @import("std");
const pets = @import("pets.zig");
const action_catalog = @import("action_catalog_generated.zig");
const ActionCount = action_catalog.ActionCount;
pub const AllActionBits: u32 = (@as(u32, 1) << ActionCount) - 1;

pub const Spec = enum(u8) {
    warlock = 0,
    frost_mage = 1,
    priest = 2,

    pub fn parse(name: []const u8) ?Spec {
        inline for (std.meta.fields(Spec)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        if (std.mem.eql(u8, name, "shadow_priest") or std.mem.eql(u8, name, "disc_priest") or std.mem.eql(u8, name, "smite_priest")) return .priest;
        return null;
    }

    pub fn actionNames(self: Spec) [action_catalog.ActionCount][]const u8 {
        return switch (self) {
            .warlock => action_catalog.warlock_names,
            .frost_mage => action_catalog.frost_mage_names,
            .priest => action_catalog.priest_names,
        };
    }
};

/// Current editor race subset; Forever race/class expansion is tracked in TODOs.
/// Missing race is Human.
pub const Race = enum(u32) {
    human,
    gnome,
    orc,
    undead,
    troll,

    pub fn parse(name: []const u8) ?Race {
        inline for (std.meta.fields(Race)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn supports(self: Race, class: Spec) bool {
        _ = self;
        _ = class;
        return true; // All five editor races support all kits in Forever.
    }

    /// Input stats exclude racial bonuses; apply exactly once when loading a spec.
    pub fn applyPassives(self: Race, base: CombatStats) CombatStats {
        var stats = base;
        switch (self) {
            // Forever tuning in Wowhead news 383457; see RACIALS.md.
            .human => stats.spell_crit_chance = @min(1, stats.spell_crit_chance + 0.02),
            .gnome => stats.max_mana *= 1.05,
            .orc => stats.spell_crit_chance = @min(1, stats.spell_crit_chance + 0.01),
            else => {},
        }
        return stats;
    }
};

pub const FrostAction = action_catalog.FrostAction;
pub const PriestAction = action_catalog.PriestAction;

// Deliberately a compact simulator kit, not a particular retail game patch.
pub const Frost = struct {
    pub const LanceMana: f32 = 30;
    pub const LanceDamage: f32 = 100;
    pub const FrozenLanceDamage: f32 = 300;
    pub const NovaMana: f32 = 40;
    pub const NovaRange: f32 = 10;
    pub const NovaDuration: f32 = 4;
    pub const NovaCooldown: f32 = 25;
    pub const PolymorphMana: f32 = 60;
    pub const PolymorphRange: f32 = 30;
    pub const PolymorphCast: f32 = 1.5;
    pub const PolymorphDuration: f32 = 4;
    pub const BoltMana: f32 = 50;
    pub const BoltCast: f32 = 1.8;
    pub const BoltDamage: f32 = 240;
    pub const SlowDuration: f32 = 6;
    pub const SlowMultiplier: f32 = 0.5;
    pub const BlinkMana: f32 = 40;
    pub const BlinkDistance: f32 = 15;
    pub const BlinkCooldown: f32 = 15;
    pub const BarrierMana: f32 = 60;
    pub const BarrierAbsorb: f32 = 400;
    pub const BarrierDuration: f32 = 20;
    pub const BarrierCooldown: f32 = 25;
    pub const CounterspellRange: f32 = 30;
    pub const CounterspellCooldown: f32 = 24;
    pub const LockoutDuration: f32 = 4;
};

/// Forever Priest kit with compact arena resource and defensive values.
pub const Priest = struct {
    // Level-60 class base mana, before Intellect/gear, from the local
    // Forever reference's sim/core/base_stats.go.
    pub const BaseMana: f32 = 1376.0;
    pub const DispelManaFraction: f32 = 0.18;
    pub const DispelMana: f32 = BaseMana * DispelManaFraction;
    // Level-60 damage from mythicsim-forever-engine-go/sim/priest,
    // beta client 1.60.1.69893. SW:P, Mind Blast, Mind Flay and Holy Fire
    // use client mana costs; remaining costs retain the compact arena model.
    pub const SwpMana: f32 = 470.0;
    pub const SwpDuration: f32 = 18.0;
    pub const SwpDps: f32 = 42.0;
    pub const SwpRange: f32 = 30.0;

    pub const DevouringPlagueMana: f32 = 80.0;
    pub const DevouringPlagueCooldown: f32 = 60.0;
    pub const DevouringPlagueDuration: f32 = 24.0;
    pub const DevouringPlagueDps: f32 = 35.0;
    pub const DevouringPlagueHps: f32 = 35.0;
    pub const DevouringPlagueRange: f32 = 30.0;

    pub const PsychicScreamMana: f32 = 50.0;
    pub const PsychicScreamCooldown: f32 = 30.0;
    pub const PsychicScreamDuration: f32 = 4.0;
    pub const PsychicScreamRange: f32 = 8.0;

    pub const MindBlastMana: f32 = 350.0;
    pub const MindBlastCast: f32 = 1.5;
    pub const MindBlastCooldown: f32 = 8.0;
    pub const MindBlastDamage: f32 = (477.0 + 504.0) / 2.0;
    pub const MindBlastRange: f32 = 30.0;

    pub const MindFlayMana: f32 = 205.0;
    pub const MindFlayDuration: f32 = 3.0;
    pub const MindFlayDps: f32 = 130.0;
    pub const MindFlayRange: f32 = 20.0;
    pub const MindFlaySlowMultiplier: f32 = 0.5;

    // Level-60 costs from the local Forever generated spell table:
    // PW:S 10901, Flash Heal 10917, Renew 25315.
    pub const ShieldMana: f32 = 500.0;
    pub const ShieldAbsorb: f32 = 928.0;
    pub const ShieldDuration: f32 = 20.0;
    pub const ShieldCooldown: f32 = 15.0;

    pub const SilenceMana: f32 = 45.0;
    pub const SilenceCooldown: f32 = 45.0;
    pub const SilenceDuration: f32 = 5.0;
    pub const SilenceRange: f32 = 20.0;

    pub const VampiricEmbraceMana: f32 = 20.0;
    pub const VampiricEmbraceCooldown: f32 = 60.0;
    pub const VampiricEmbraceDuration: f32 = 30.0;
    pub const VampiricEmbraceLeechFraction: f32 = 0.20;
    pub const VampiricEmbraceRange: f32 = 30.0;

    pub const ShadowWordDeathMana: f32 = 55.0;
    pub const ShadowWordDeathCooldown: f32 = 15.0;
    pub const ShadowWordDeathDamage: f32 = 458.0;
    pub const ShadowWordDeathBacklashFraction: f32 = 0.10;
    pub const ShieldCoefficient: f32 = 0.10;
    pub const ShadowWordDeathRange: f32 = 30.0;

    pub const FlashHealMana: f32 = 380.0;
    pub const FlashHealCast: f32 = 1.5;
    pub const FlashHealAmount: f32 = 841.0;

    pub const RenewMana: f32 = 410.0;
    pub const RenewDuration: f32 = 15.0;
    pub const RenewHps: f32 = 166.0 / 3.0;

    pub const HolyFireMana: f32 = 255.0;
    pub const HolyFireCast: f32 = 3.5;
    pub const HolyFireInitialDamage: f32 = 208.0;
    pub const HolyFireDuration: f32 = 10.0;
    pub const HolyFireDps: f32 = 7.5;
    pub const HolyFireRange: f32 = 30.0;

    pub const SmiteMana: f32 = 50.0;
    pub const SmiteCast: f32 = 2.5;
    pub const SmiteDamage: f32 = 175.0;
    pub const SmiteRange: f32 = 30.0;

    pub const PenanceMana: f32 = 60.0;
    pub const PenanceDuration: f32 = 2.0;
    pub const PenanceCooldown: f32 = 12.0;
    pub const PenanceDps: f32 = 131.0 * 3.0 / PenanceDuration;
    pub const PenanceRange: f32 = 30.0;

    pub const InnerFocusCooldown: f32 = 180.0;
    pub const InnerFocusCritBonus: f32 = 0.25;

    pub const ShadowWeavingDuration: f32 = 15.0;
    pub const ShadowWeavingMaxStacks: f32 = 5.0;
    pub const ShadowWeavingPerStack: f32 = 0.02;
};

/// Talent point distribution across the class's three talent trees (x/y/z).
/// For Warlock: Affliction / Demonology / Destruction
/// For Mage: Arcane / Fire / Frost
pub const TalentBuild = struct {
    tree1: u8 = 0,
    tree2: u8 = 0,
    tree3: u8 = 0,

    pub fn total(self: TalentBuild) u16 {
        return @as(u16, self.tree1) + @as(u16, self.tree2) + @as(u16, self.tree3);
    }

    /// Formats as "x/y/z"
    pub fn format(self: TalentBuild, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}/{d}/{d}", .{ self.tree1, self.tree2, self.tree3 });
    }

    /// Parses string formatted as "x/y/z" or "x-y-z"
    pub fn parse(str: []const u8) ?TalentBuild {
        var sep: u8 = '/';
        if (std.mem.indexOfScalar(u8, str, '/') == null and std.mem.indexOfScalar(u8, str, '-') != null) {
            sep = '-';
        }
        var iter = std.mem.splitScalar(u8, str, sep);
        const p1 = iter.next() orelse return null;
        const p2 = iter.next() orelse return null;
        const p3 = iter.next() orelse return null;
        if (iter.next() != null) return null;

        const t1 = std.fmt.parseInt(u8, std.mem.trim(u8, p1, " "), 10) catch return null;
        const t2 = std.fmt.parseInt(u8, std.mem.trim(u8, p2, " "), 10) catch return null;
        const t3 = std.fmt.parseInt(u8, std.mem.trim(u8, p3, " "), 10) catch return null;
        return .{ .tree1 = t1, .tree2 = t2, .tree3 = t3 };
    }
};

pub const CombatStats = @import("spell_resolution.zig").Stats;

pub const WarlockTalentRanks = struct {
    suppression: u8 = 0, // 105925
    fel_concentration: u8 = 0, // 105918
    intensity: u8 = 0, // 105882
    pandemic: u8 = 0, // 105917
    malevolence: u8 = 0, // 110876
    ruin: u8 = 0, // 105883
    fire_and_brimstone: u8 = 0, // 105877
    improved_corruption: u8 = 0, // 105924
    malediction: u8 = 0, // 105923
    improved_drains: u8 = 0, // 105920
    improved_bane_of_agony: u8 = 0, // 105919
    siphon_life: u8 = 0, // 105912
    shadow_mastery: u8 = 0, // 105910
    unholy_power: u8 = 0, // 105906
    soul_link: u8 = 0, // 105892
    bane: u8 = 0, // 105888
    molten_skin: u8 = 0, // 105885
    cataclysm: u8 = 0, // 105887
    improved_imp: u8 = 0, // 105908
    improved_sayaad: u8 = 0, // 105901
    improved_felhunter: u8 = 0, // 105894
    shadowburn: u8 = 0, // 105884
    shadow_and_flame: u8 = 0, // 105875
    demonic_sacrifice: u8 = 0, // 105900
    demonic_pact: u8 = 0, // 105890
    agonizing_flames: u8 = 0, // 105879
    aftermath: u8 = 0, // 105886
    conflagrate: u8 = 0, // 105880
    improved_shadow_bolt: u8 = 0, // 105889
    demonic_sacrifice_pet: u8 = 1, // pet enum; 0 means none
    demonic_knowledge: u8 = 0, // 105893 (0..3)
    master_demonologist: u8 = 0, // 105891 (0..5)
    demonic_embrace: u8 = 0, // 105907 (0..5)
    fel_vitality: u8 = 0, // 105903 (0..3)

    pub fn encode(self: WarlockTalentRanks) u128 {
        return @as(u128, (@as(u64, self.improved_corruption) & 0x7) |
            ((@as(u64, self.malediction) & 0x7) << 3) |
            ((@as(u64, self.improved_drains) & 0x3) << 6) |
            ((@as(u64, self.agonizing_flames) & 0x3) << 8) |
            ((@as(u64, self.siphon_life) & 0x1) << 10) |
            ((@as(u64, self.shadow_mastery) & 0x7) << 11) |
            ((@as(u64, self.unholy_power) & 0x7) << 14) |
            ((@as(u64, self.soul_link) & 0x1) << 17) |
            ((@as(u64, self.bane) & 0x7) << 18) |
            ((@as(u64, self.molten_skin) & 0x7) << 21) |
            ((@as(u64, self.cataclysm) & 0x3) << 24) |
            ((@as(u64, self.improved_imp) & 0x3) << 26) |
            ((@as(u64, self.shadowburn) & 0x1) << 28) |
            ((@as(u64, self.shadow_and_flame) & 0x7) << 29) |
            ((@as(u64, self.demonic_sacrifice) & 0x1) << 32) |
            ((@as(u64, (if (self.demonic_sacrifice_pet > 0) self.demonic_sacrifice_pet - 1 else 0)) & 0x3) << 33) |
            ((@as(u64, (if (self.improved_bane_of_agony > 0) @as(u64, 1) else 0)) & 0x1) << 35) |
            ((@as(u64, self.improved_shadow_bolt) & 0x7) << 36) |
            ((@as(u64, self.aftermath) & 0x7) << 39) |
            ((@as(u64, self.conflagrate) & 0x1) << 42) |
            ((@as(u64, self.improved_sayaad) & 0x3) << 43) |
            ((@as(u64, self.improved_felhunter) & 0x3) << 45) |
            ((@as(u64, self.suppression) & 0x7) << 47) |
            ((@as(u64, self.malevolence) & 0x7) << 50) |
            ((@as(u64, self.ruin) & 0x7) << 53) |
            ((@as(u64, self.fire_and_brimstone) & 0x3) << 56) |
            ((@as(u64, self.pandemic) & 0x3) << 58) |
            ((@as(u64, self.fel_concentration) & 0x3) << 60) |
            ((@as(u64, self.intensity) & 0x3) << 62)) |
            ((@as(u128, self.fel_vitality) & 0x3) << 72) |
            ((@as(u128, self.improved_bane_of_agony) & 0x3) << 74) |
            ((@as(u128, self.demonic_embrace) & 0x7) << 76) |
            ((@as(u128, self.demonic_knowledge) & 0x3) << 79) |
            ((@as(u128, self.master_demonologist) & 0x7) << 81);
    }
};

pub const PriestTalentRanks = struct {
    // Low 32-bit word (encoded)
    power_in_light: u8 = 0, // 1309969 (0..5, bits 0..2)
    twin_disciplines: u8 = 0, // 1225132 (0..5, bits 3..5)
    silent_resolve: u8 = 0, // 14523 (0..3, bits 6..7)
    holy_precision: u8 = 0, // 1309957 (0..3, bits 8..9)
    improved_power_word_shield: u8 = 0, // 14748 (0..3, bits 10..11)
    mental_agility: u8 = 0, // 14520 (0..3, bits 12..13)
    inner_focus: u8 = 0, // 14751 (0..1, bit 14)
    soul_warding: u8 = 0, // 402000 (0..1, bit 15)
    penance: u8 = 0, // 402174 (0..1, bit 16)
    twilight_focus: u8 = 0, // 14913 (0..3, bits 17..18)
    improved_renew: u8 = 0, // 14908 (0..3, bits 19..20)
    holy_specialization: u8 = 0, // 14889 (0..5, bits 21..23)
    spell_warding: u8 = 0, // 27900 (0..5, bits 24..26)
    divine_fury: u8 = 0, // 18530 (0..5, bits 27..29)
    searing_light: u8 = 0, // 14909 (0..2, bits 30..31)

    // High 32-bit word (flags, bits 32..63)
    spiritual_healing: u8 = 0, // 14898 (0..3, bits 32..33)
    shadow_focus: u8 = 0, // 15260 (0..5, bits 34..36)
    improved_shadow_word_pain: u8 = 0, // 15275 (0..2, bits 37..38)
    improved_mind_blast: u8 = 0, // 15273 (0..5, bits 39..41)
    improved_psychic_scream: u8 = 0, // 15392 (0..2, bits 42..43)
    mind_flay: u8 = 0, // 15407 (0..1, bit 44)
    improved_mind_flay: u8 = 0, // 1225139 (0..2, bits 45..46)
    vampiric_embrace: u8 = 0, // 15286 (0..1, bit 47)
    shadow_weaving: u8 = 0, // 15257 (0..3, bits 48..49)
    silence: u8 = 0, // 15487 (0..1, bit 50)
    devouring_contagion: u8 = 0, // 1309950 (0..2, bits 51..52)
    early_demise: u8 = 0, // 1310076 (0..2, bits 53..54)
    darkness: u8 = 0, // 15259 (0..5, bits 55..57)
    shadowform: u8 = 0, // 15473 (0..1, bit 58)
    renewed_hope: u8 = 0, // 425280 (0..5, bits 59..61)
    divine_aegis: u8 = 0, // 431622 (0..3, bits 62..63)

    power_infusion: u8 = 0, // 10060, bit 69
    improved_mana_burn: u8 = 0, // 14750, bits 70..71
    blackout: u8 = 0, // 15268, bits 64..66
    shadow_reach: u8 = 0, // 17322, bits 67..68

    pub fn encode(self: PriestTalentRanks) u128 {
        return (@as(u128, self.power_in_light) & 0x7) |
            ((@as(u128, self.twin_disciplines) & 0x7) << 3) |
            ((@as(u128, self.silent_resolve) & 0x3) << 6) |
            ((@as(u128, self.holy_precision) & 0x3) << 8) |
            ((@as(u128, self.improved_power_word_shield) & 0x3) << 10) |
            ((@as(u128, self.mental_agility) & 0x3) << 12) |
            ((@as(u128, self.inner_focus) & 0x1) << 14) |
            ((@as(u128, self.soul_warding) & 0x1) << 15) |
            ((@as(u128, self.penance) & 0x1) << 16) |
            ((@as(u128, self.twilight_focus) & 0x3) << 17) |
            ((@as(u128, self.improved_renew) & 0x3) << 19) |
            ((@as(u128, self.holy_specialization) & 0x7) << 21) |
            ((@as(u128, self.spell_warding) & 0x7) << 24) |
            ((@as(u128, self.divine_fury) & 0x7) << 27) |
            ((@as(u128, self.searing_light) & 0x3) << 30) |
            ((@as(u128, self.spiritual_healing) & 0x3) << 32) |
            ((@as(u128, self.shadow_focus) & 0x7) << 34) |
            ((@as(u128, self.improved_shadow_word_pain) & 0x3) << 37) |
            ((@as(u128, self.improved_mind_blast) & 0x7) << 39) |
            ((@as(u128, self.improved_psychic_scream) & 0x3) << 42) |
            ((@as(u128, self.mind_flay) & 0x1) << 44) |
            ((@as(u128, self.improved_mind_flay) & 0x3) << 45) |
            ((@as(u128, self.vampiric_embrace) & 0x1) << 47) |
            ((@as(u128, self.shadow_weaving) & 0x3) << 48) |
            ((@as(u128, self.silence) & 0x1) << 50) |
            ((@as(u128, self.devouring_contagion) & 0x3) << 51) |
            ((@as(u128, self.early_demise) & 0x3) << 53) |
            ((@as(u128, self.darkness) & 0x7) << 55) |
            ((@as(u128, self.shadowform) & 0x1) << 58) |
            ((@as(u128, self.renewed_hope) & 0x7) << 59) |
            ((@as(u128, self.divine_aegis) & 0x3) << 62) |
            ((@as(u128, self.blackout) & 0x7) << 64) |
            ((@as(u128, self.shadow_reach) & 0x3) << 67) |
            ((@as(u128, self.power_infusion) & 0x1) << 69) |
            ((@as(u128, self.improved_mana_burn) & 0x3) << 70);
    }
};

pub fn pushbackResistance(rank: u8) f32 {
    return switch (rank) {
        1 => 0.23,
        2 => 0.47,
        3 => 0.70,
        else => 0,
    };
}

/// Scalar summary of supported Warlock/Priest effects for spec metadata and reports.
/// The search kernels use the packed rank word to derive SIMD equivalents once
/// per fighter, outside the physics tick loop.
pub const CombatModifiers = struct {
    spell_hit_bonus: f32 = 0,
    shadow_crit_bonus: f32 = 0,
    affliction_crit_multiplier: f32 = 1.5,
    fel_concentration_resist: f32 = 0,
    intensity_resist: f32 = 0,
    destruction_crit_multiplier: f32 = 1.5,
    conflagrate_crit_bonus: f32 = 0,
    searing_pain_crit_bonus: f32 = 0,
    destruction_damage_mult: f32 = 1.0,
    improved_shadow_bolt_mult: f32 = 0,
    agony_damage_mult: f32 = 1.0,
    corruption_damage_mult: f32 = 1.0,
    siphon_life_damage_mult: f32 = 1.0,
    siphon_life_healing_mult: f32 = 1.0,
    shadow_damage_mult: f32 = 1.0,
    fire_damage_mult: f32 = 1.0,
    immolate_initial_damage_mult: f32 = 1.0,
    drain_life_mult: f32 = 1.0,
    damage_taken_mult: f32 = 1.0,
    shadow_bolt_cast_time: f32 = 1.8,
    shadow_bolt_mana_mult: f32 = 1.0,
    pet_damage_mult: f32 = 1.0,
    imp_firebolt_damage_mult: f32 = 1.0,
    soul_link_pct: f32 = 0.0,
    seduction_duration_mult: f32 = 1.0,
    spell_lock_cooldown: f32 = 24.0,
    has_siphon_life: bool = false,

    pub fn default() CombatModifiers {
        return .{};
    }

    /// Build scalar effects for spec metadata and UI summaries.
    pub fn fromWarlockRanks(t: WarlockTalentRanks) CombatModifiers {
        var m = CombatModifiers.default();
        const agon_bonus: f32 = switch (t.agonizing_flames) {
            1 => 0.03,
            2 => 0.07,
            3 => 0.10,
            else => 0.0,
        };
        m.searing_pain_crit_bonus = agon_bonus;
        m.destruction_damage_mult = 1.0 + agon_bonus;
        const shadow = 1.0 + 0.01 * @as(f32, @floatFromInt(t.shadow_mastery));
        const shadow_damage = shadow * (if (t.soul_link > 0) @as(f32, 1.03) else 1.0);
        const periodic = 1.0 + 0.01 * @as(f32, @floatFromInt(t.malediction));
        m.shadow_damage_mult = shadow_damage;
        m.fire_damage_mult = (1.0 + 0.02 * @as(f32, @floatFromInt(t.shadow_and_flame))) * m.destruction_damage_mult;
        m.immolate_initial_damage_mult = m.fire_damage_mult * (1.0 + 0.10 * @as(f32, @floatFromInt(t.aftermath)));
        m.agony_damage_mult = shadow_damage * periodic * (1.0 + 0.05 * @as(f32, @floatFromInt(t.improved_bane_of_agony)));
        m.corruption_damage_mult = shadow_damage * periodic * (1.0 + 0.02 * @as(f32, @floatFromInt(t.improved_corruption)));
        m.siphon_life_damage_mult = shadow_damage * periodic;
        m.siphon_life_healing_mult = m.siphon_life_damage_mult;
        const drain_mult: f32 = switch (t.improved_drains) {
            0 => 1.0,
            1 => 1.07,
            2 => 1.13,
            else => 1.20,
        };
        m.drain_life_mult = shadow_damage * periodic * drain_mult;
        m.damage_taken_mult = 1.0 - 0.02 * @as(f32, @floatFromInt(t.molten_skin));
        m.shadow_bolt_cast_time = @max(0.0, 1.8 - 0.1 * @as(f32, @floatFromInt(t.bane)));
        m.shadow_bolt_mana_mult = switch (t.cataclysm) {
            0 => 1.0,
            1 => 0.97,
            2 => 0.94,
            else => 0.90,
        };
        m.pet_damage_mult = (1.0 + 0.02 * @as(f32, @floatFromInt(t.unholy_power))) * (if (t.soul_link > 0) @as(f32, 1.03) else 1.0);
        m.imp_firebolt_damage_mult = 1.0 + 0.10 * @as(f32, @floatFromInt(t.improved_imp));
        m.soul_link_pct = if (t.soul_link > 0) 0.30 else 0.0;
        m.seduction_duration_mult = 1.0 + 0.10 * @as(f32, @floatFromInt(t.improved_sayaad));
        m.spell_lock_cooldown = 24.0 - 2.0 * @as(f32, @floatFromInt(t.improved_felhunter));
        m.affliction_crit_multiplier = 1.5 + 0.5 * (switch (t.pandemic) {
            @as(u8, 1) => @as(f32, 0.33),
            2 => @as(f32, 0.67),
            3 => @as(f32, 1),
            else => @as(f32, 0),
        });
        m.fel_concentration_resist = pushbackResistance(t.fel_concentration);
        m.intensity_resist = pushbackResistance(t.intensity);
        m.spell_hit_bonus = 0.01 * @as(f32, @floatFromInt(t.suppression));
        m.shadow_crit_bonus = 0.01 * @as(f32, @floatFromInt(t.malevolence));
        m.destruction_crit_multiplier = 1.5 + 0.10 * @as(f32, @floatFromInt(t.ruin));
        m.conflagrate_crit_bonus = switch (t.fire_and_brimstone) {
            1 => 0.08,
            2 => 0.17,
            3 => 0.25,
            else => 0,
        };
        m.improved_shadow_bolt_mult = 0.04 * @as(f32, @floatFromInt(t.improved_shadow_bolt));
        m.has_siphon_life = t.siphon_life > 0;
        return m;
    }

    pub fn fromPriestRanks(t: PriestTalentRanks) CombatModifiers {
        var m = CombatModifiers.default();
        const darkness = 1.0 + 0.02 * @as(f32, @floatFromInt(t.darkness));
        const shadowform = if (t.shadowform > 0) @as(f32, 1.10) else 1.0;
        m.shadow_damage_mult = darkness * shadowform;
        m.affliction_crit_multiplier = if (t.shadowform > 0) 2.0 else 1.5;
        m.spell_hit_bonus = 0.01 * @as(f32, @floatFromInt(t.shadow_focus));
        m.damage_taken_mult = 1.0 - 0.02 * @as(f32, @floatFromInt(t.spell_warding));
        m.fel_concentration_resist = pushbackResistance(t.twilight_focus);
        return m;
    }
};

/// High-level specification configuration
pub const SpecConfig = struct {
    id: []const u8,
    name: []const u8,
    class: Spec,
    talents: TalentBuild,
    action_mask: u32 = AllActionBits,
    warlock_talents: WarlockTalentRanks = .{},
    priest_talents: PriestTalentRanks = .{},
    pet: pets.Kind = .imp,
    sacrifice_pet: pets.Kind = .imp,
    modifiers: CombatModifiers,
    combat_stats: CombatStats = .{},
    race: Race = .human,

    pub fn init(id: []const u8, name: []const u8, class: Spec, talents: TalentBuild) SpecConfig {
        return .{
            .id = id,
            .name = name,
            .class = class,
            .talents = talents,
            .action_mask = if (class == .warlock) AllActionBits & ~((@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Seduction)) | (@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.SpellLock))) else AllActionBits,
            .pet = if (class == .warlock) .imp else .none,
            .sacrifice_pet = if (class == .warlock) .imp else .none,
            .modifiers = CombatModifiers.default(),
        };
    }

    pub fn encodedTalents(self: SpecConfig) u128 {
        return switch (self.class) {
            .warlock => self.warlock_talents.encode(),
            .priest => self.priest_talents.encode(),
            .frost_mage => 0,
        };
    }
};

fn rankInTree(trees: std.json.ObjectMap, tree_name: []const u8, talent_id: []const u8) u8 {
    const tree_value = trees.get(tree_name) orelse return 0;
    const rank_value = tree_value.object.get(talent_id) orelse return 0;
    return switch (rank_value) {
        .integer => |rank| if (rank > 0 and rank <= 255) @intCast(rank) else 0,
        else => 0,
    };
}

/// Build capabilities are independent of current mana, cooldowns and crowd control.
pub fn filterActionCapabilities(class: Spec, configured: u32, warlock: WarlockTalentRanks, priest: PriestTalentRanks, race: Race, pet: pets.Kind) u32 {
    var mask = configured & AllActionBits;
    inline for (0..ActionCount) |id| {
        const name = switch (class) {
            .warlock => action_catalog.warlock_names[id],
            .priest => action_catalog.priest_names[id],
            .frost_mage => action_catalog.frost_mage_names[id],
        };
        if (std.mem.eql(u8, name, "None")) mask &= ~(@as(u32, 1) << id);
        const rank: u8 = switch (class) {
            .warlock => switch (action_catalog.warlock_talent_gate_ids[id]) {
                105912 => warlock.siphon_life,
                105884 => warlock.shadowburn,
                105880 => warlock.conflagrate,
                else => 1,
            },
            .priest => switch (action_catalog.priest_talent_gate_ids[id]) {
                15407 => priest.mind_flay,
                15487 => priest.silence,
                15286 => priest.vampiric_embrace,
                402174 => priest.penance,
                14751 => priest.inner_focus,
                10060 => priest.power_infusion,
                else => 1,
            },
            .frost_mage => 1,
        };
        if (rank == 0) mask &= ~(@as(u32, 1) << id);
    }
    inline for (.{ Race.orc, Race.troll, Race.gnome, Race.undead }, 17..) |required_race, id| {
        if (race != required_race) mask &= ~(@as(u32, 1) << id);
    }
    if (class == .warlock) {
        if (pet != .succubus) mask &= ~(@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Seduction));
        if (pet != .felhunter) mask &= ~(@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.SpellLock));
    }
    return mask;
}

fn actionMaskFromRoot(root: std.json.ObjectMap, class: Spec) !u32 {
    const names = class.actionNames();
    var mask = AllActionBits;
    const automatic = if (root.get("automatic_actions")) |v| v == .bool and v.bool else false;
    if (if (automatic) null else root.get("action_loadout") orelse root.get("action_slots")) |actions_value| {
        if (actions_value != .array) return error.InvalidActionLoadout;
        mask = 0;
        for (actions_value.array.items) |value| {
            if (value != .string) continue;
            for (names, 0..) |name, id| {
                if (std.mem.eql(u8, value.string, name)) mask |= @as(u32, 1) << @intCast(id);
            }
        }
        // These controls are reserved by the editor and stay available regardless
        // of which spell slots the user selected.
        const idle_id: usize = switch (class) {
            .warlock => @intFromEnum(action_catalog.WarlockAction.IdleOrManeuver),
            .frost_mage => @intFromEnum(action_catalog.FrostAction.IdleOrManeuver),
            .priest => @intFromEnum(action_catalog.PriestAction.IdleOrManeuver),
        };
        const cancel_id: usize = switch (class) {
            .warlock => @intFromEnum(action_catalog.WarlockAction.CancelCast),
            .frost_mage => @intFromEnum(action_catalog.FrostAction.CancelCast),
            .priest => @intFromEnum(action_catalog.PriestAction.CancelCast),
        };
        mask |= @as(u32, 1) << @intCast(idle_id);
        mask |= @as(u32, 1) << @intCast(cancel_id);
    }

    if (class == .warlock) {
        if (root.get("trees")) |tree_value| {
            if (tree_value == .object) {
                var ranks_buf: [16]u8 = undefined;
                inline for (0..ActionCount) |id| {
                    const talent_id = action_catalog.warlock_talent_gate_ids[id];
                    const tree_name = action_catalog.warlock_talent_gate_trees[id];
                    if (talent_id == 0) continue;
                    const key = try std.fmt.bufPrint(&ranks_buf, "{d}", .{talent_id});
                    if (rankInTree(tree_value.object, tree_name, key) == 0) mask &= ~(@as(u32, 1) << id);
                }
            }
        } else {
            // Without saved talent ranks, talent-gated abilities cannot be
            // proven available.
            inline for (0..ActionCount) |id| {
                if (action_catalog.warlock_talent_gate_ids[id] != 0) mask &= ~(@as(u32, 1) << id);
            }
        }
    } else if (class == .priest) {
        if (root.get("trees")) |tree_value| {
            if (tree_value == .object) {
                var ranks_buf: [16]u8 = undefined;
                inline for (0..ActionCount) |id| {
                    const talent_id = action_catalog.priest_talent_gate_ids[id];
                    const tree_name = action_catalog.priest_talent_gate_trees[id];
                    if (talent_id == 0) continue;
                    const key = try std.fmt.bufPrint(&ranks_buf, "{d}", .{talent_id});
                    var r = rankInTree(tree_value.object, tree_name, key);
                    if (r == 0 and talent_id == 402174) r = rankInTree(tree_value.object, tree_name, "1316995");
                    if (r == 0) mask &= ~(@as(u32, 1) << id);
                }
            }
        } else {
            inline for (0..ActionCount) |id| {
                if (action_catalog.priest_talent_gate_ids[id] != 0) mask &= ~(@as(u32, 1) << id);
            }
        }
    }
    return mask & AllActionBits;
}

fn warlockRanksFromTrees(trees: std.json.ObjectMap) WarlockTalentRanks {
    return .{
        .suppression = rankInTree(trees, "Affliction", "105925"),
        .fel_concentration = rankInTree(trees, "Affliction", "105918"),
        .intensity = rankInTree(trees, "Destruction", "105882"),
        .pandemic = rankInTree(trees, "Affliction", "105917"),
        .malevolence = rankInTree(trees, "Affliction", "110876"),
        .ruin = rankInTree(trees, "Destruction", "105883"),
        .fire_and_brimstone = rankInTree(trees, "Destruction", "105877"),
        .improved_corruption = rankInTree(trees, "Affliction", "105924"),
        .malediction = rankInTree(trees, "Affliction", "105923"),
        .improved_drains = rankInTree(trees, "Affliction", "105920"),
        .improved_bane_of_agony = rankInTree(trees, "Affliction", "105919"),
        .siphon_life = rankInTree(trees, "Affliction", "105912"),
        .shadow_mastery = rankInTree(trees, "Affliction", "105910"),
        .unholy_power = rankInTree(trees, "Demonology", "105906"),
        .soul_link = rankInTree(trees, "Demonology", "105892"),
        .bane = rankInTree(trees, "Destruction", "105888"),
        .molten_skin = rankInTree(trees, "Destruction", "105885"),
        .cataclysm = rankInTree(trees, "Destruction", "105887"),
        .improved_imp = rankInTree(trees, "Demonology", "105908"),
        .improved_sayaad = rankInTree(trees, "Demonology", "105901"),
        .improved_felhunter = rankInTree(trees, "Demonology", "105894"),
        .shadowburn = rankInTree(trees, "Destruction", "105884"),
        .shadow_and_flame = rankInTree(trees, "Destruction", "105875"),
        .demonic_sacrifice = rankInTree(trees, "Demonology", "105900"),
        .demonic_pact = rankInTree(trees, "Demonology", "105890"),
        .agonizing_flames = rankInTree(trees, "Destruction", "105879"),
        .aftermath = rankInTree(trees, "Destruction", "105886"),
        .conflagrate = rankInTree(trees, "Destruction", "105880"),
        .improved_shadow_bolt = rankInTree(trees, "Destruction", "105889"),
        .demonic_knowledge = rankInTree(trees, "Demonology", "105893"),
        .master_demonologist = rankInTree(trees, "Demonology", "105891"),
        .demonic_embrace = rankInTree(trees, "Demonology", "105907"),
        .fel_vitality = rankInTree(trees, "Demonology", "105903"),
    };
}

fn priestRanksFromTrees(trees: std.json.ObjectMap) PriestTalentRanks {
    const penance_rank = blk: {
        const r = rankInTree(trees, "Discipline", "402174");
        if (r > 0) break :blk r;
        break :blk rankInTree(trees, "Discipline", "1316995");
    };
    return .{
        .power_infusion = rankInTree(trees, "Discipline", "10060"),
        .improved_mana_burn = rankInTree(trees, "Discipline", "14750"),
        .power_in_light = rankInTree(trees, "Discipline", "1309969"),
        .twin_disciplines = rankInTree(trees, "Discipline", "1225132"),
        .silent_resolve = rankInTree(trees, "Discipline", "14523"),
        .holy_precision = rankInTree(trees, "Discipline", "1309957"),
        .improved_power_word_shield = rankInTree(trees, "Discipline", "14748"),
        .mental_agility = rankInTree(trees, "Discipline", "14520"),
        .inner_focus = rankInTree(trees, "Discipline", "14751"),
        .soul_warding = rankInTree(trees, "Discipline", "402000"),
        .penance = penance_rank,
        .twilight_focus = rankInTree(trees, "Holy", "14913"),
        .improved_renew = rankInTree(trees, "Holy", "14908"),
        .holy_specialization = rankInTree(trees, "Holy", "14889"),
        .spell_warding = rankInTree(trees, "Holy", "27900"),
        .divine_fury = rankInTree(trees, "Holy", "18530"),
        .searing_light = rankInTree(trees, "Holy", "14909"),
        .spiritual_healing = rankInTree(trees, "Holy", "14898"),
        .shadow_focus = rankInTree(trees, "Shadow Magic", "15260"),
        .blackout = rankInTree(trees, "Shadow Magic", "15268"),
        .shadow_reach = rankInTree(trees, "Shadow Magic", "17322"),
        .improved_shadow_word_pain = rankInTree(trees, "Shadow Magic", "15275"),
        .improved_mind_blast = rankInTree(trees, "Shadow Magic", "15273"),
        .improved_psychic_scream = rankInTree(trees, "Shadow Magic", "15392"),
        .mind_flay = rankInTree(trees, "Shadow Magic", "15407"),
        .improved_mind_flay = rankInTree(trees, "Shadow Magic", "1225139"),
        .vampiric_embrace = rankInTree(trees, "Shadow Magic", "15286"),
        .shadow_weaving = rankInTree(trees, "Shadow Magic", "15257"),
        .silence = rankInTree(trees, "Shadow Magic", "15487"),
        .devouring_contagion = rankInTree(trees, "Shadow Magic", "1309950"),
        .early_demise = rankInTree(trees, "Shadow Magic", "1310076"),
        .darkness = rankInTree(trees, "Shadow Magic", "15259"),
        .shadowform = rankInTree(trees, "Shadow Magic", "15473"),
        .renewed_hope = rankInTree(trees, "Discipline", "425280"),
        .divine_aegis = rankInTree(trees, "Discipline", "431622"),
    };
}

fn sumTreeRanks(trees: std.json.ObjectMap, tree_name: []const u8) !u8 {
    const tree_value = trees.get(tree_name) orelse return error.MissingTalentTree;
    var total: u16 = 0;
    var iter = tree_value.object.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .integer => |rank| {
                if (rank < 0 or rank > 5) return error.InvalidTalentRank;
                total += @intCast(rank);
            },
            else => return error.InvalidTalentRank,
        }
    }
    if (total > 255) return error.InvalidTalentBuild;
    return @intCast(total);
}

fn validateWarlockRanks(ranks: WarlockTalentRanks) !void {
    if (ranks.fel_concentration > 3 or ranks.intensity > 3 or ranks.pandemic > 3 or ranks.suppression > 5 or ranks.malevolence > 5 or ranks.ruin > 5 or ranks.fire_and_brimstone > 3 or
        ranks.improved_corruption > 5 or ranks.malediction > 5 or ranks.improved_drains > 3 or
        ranks.improved_bane_of_agony > 2 or ranks.siphon_life > 1 or ranks.shadow_mastery > 5 or
        ranks.improved_sayaad > 3 or ranks.improved_felhunter > 3 or
        ranks.unholy_power > 5 or ranks.soul_link > 1 or ranks.bane > 5 or ranks.improved_imp > 3 or
        ranks.molten_skin > 5 or ranks.cataclysm > 3 or ranks.shadowburn > 1 or ranks.shadow_and_flame > 5 or
        ranks.agonizing_flames > 3 or ranks.conflagrate > 1 or ranks.aftermath > 5 or ranks.demonic_sacrifice > 1 or ranks.demonic_pact > 1 or ranks.demonic_sacrifice_pet > 4 or ranks.improved_shadow_bolt > 5 or ranks.fel_vitality > 3 or ranks.demonic_embrace > 5 or ranks.demonic_knowledge > 3 or ranks.master_demonologist > 5) return error.InvalidTalentRank;
}

pub fn validatePriestRanks(ranks: PriestTalentRanks) !void {
    if (ranks.power_in_light > 5 or ranks.twin_disciplines > 5 or ranks.silent_resolve > 3 or ranks.holy_precision > 3 or
        ranks.improved_power_word_shield > 3 or ranks.mental_agility > 3 or ranks.inner_focus > 1 or ranks.soul_warding > 1 or
        ranks.penance > 1 or ranks.twilight_focus > 3 or ranks.improved_renew > 3 or ranks.holy_specialization > 5 or
        ranks.spell_warding > 5 or ranks.divine_fury > 5 or ranks.searing_light > 2 or ranks.spiritual_healing > 3 or
        ranks.shadow_focus > 5 or ranks.improved_shadow_word_pain > 2 or ranks.improved_mind_blast > 5 or
        ranks.improved_psychic_scream > 2 or ranks.mind_flay > 1 or ranks.improved_mind_flay > 2 or
        ranks.vampiric_embrace > 1 or ranks.shadow_weaving > 3 or ranks.silence > 1 or
        ranks.devouring_contagion > 2 or ranks.early_demise > 2 or ranks.darkness > 5 or ranks.shadowform > 1 or
        ranks.power_infusion > 1 or ranks.improved_mana_burn > 2 or ranks.renewed_hope > 5 or ranks.divine_aegis > 3 or ranks.blackout > 5 or ranks.shadow_reach > 2) return error.InvalidTalentRank;
}

/// Standard canonical specs with explicit talent builds x/y/z
pub const CANONICAL_SPECS = [_]SpecConfig{
    // Warlocks
    SpecConfig.init("affliction_warlock", "Affliction Warlock", .warlock, .{ .tree1 = 30, .tree2 = 0, .tree3 = 21 }),
    SpecConfig.init("soul_link_warlock", "Soul Link Warlock", .warlock, .{ .tree1 = 20, .tree2 = 31, .tree3 = 0 }),
    SpecConfig.init("destro_warlock", "Destruction Warlock", .warlock, .{ .tree1 = 0, .tree2 = 17, .tree3 = 34 }),

    // Mages
    SpecConfig.init("deep_frost_mage", "Deep Frost Mage", .frost_mage, .{ .tree1 = 17, .tree2 = 0, .tree3 = 34 }),
    SpecConfig.init("elemental_mage", "Elemental Mage", .frost_mage, .{ .tree1 = 0, .tree2 = 28, .tree3 = 23 }),

    // Priests
    SpecConfig.init("shadow_priest", "Shadow Priest", .priest, .{ .tree1 = 14, .tree2 = 0, .tree3 = 37 }),
    SpecConfig.init("disc_priest", "Discipline Priest", .priest, .{ .tree1 = 31, .tree2 = 20, .tree3 = 0 }),
    SpecConfig.init("smite_priest", "Smite Priest", .priest, .{ .tree1 = 31, .tree2 = 20, .tree3 = 0 }),
};

pub fn findCanonicalSpec(id: []const u8) ?SpecConfig {
    if (std.mem.eql(u8, id, "priest")) return findCanonicalSpec("shadow_priest");
    for (CANONICAL_SPECS) |s| {
        if (std.mem.eql(u8, s.id, id)) {
            var result = s;
            if (std.mem.eql(u8, s.id, "soul_link_warlock")) {
                result.warlock_talents.soul_link = 1;
                result.modifiers = CombatModifiers.fromWarlockRanks(result.warlock_talents);
            } else if (std.mem.eql(u8, s.id, "shadow_priest")) {
                result.priest_talents = .{
                    .twin_disciplines = 5,
                    .silent_resolve = 3,
                    .improved_power_word_shield = 3,
                    .mental_agility = 2,
                    .inner_focus = 1,
                    .shadow_focus = 5,
                    .blackout = 5,
                    .shadow_reach = 2,
                    .improved_shadow_word_pain = 2,
                    .improved_mind_blast = 5,
                    .improved_psychic_scream = 2,
                    .mind_flay = 1,
                    .improved_mind_flay = 2,
                    .vampiric_embrace = 1,
                    .shadow_weaving = 3,
                    .silence = 1,
                    .devouring_contagion = 2,
                    .early_demise = 1,
                    .darkness = 4,
                    .shadowform = 1,
                };
                result.action_mask &= ~(@as(u32, 1) << @intFromEnum(action_catalog.PriestAction.Penance));
                result.modifiers = CombatModifiers.fromPriestRanks(result.priest_talents);
            } else if (std.mem.eql(u8, s.id, "disc_priest") or std.mem.eql(u8, s.id, "smite_priest")) {
                result.priest_talents = .{
                    .power_in_light = 5,
                    .twin_disciplines = 5,
                    .silent_resolve = 3,
                    .holy_precision = 3,
                    .improved_power_word_shield = 3,
                    .mental_agility = 3,
                    .inner_focus = 1,
                    .soul_warding = 1,
                    .penance = 1,
                    .power_infusion = 1,
                    .renewed_hope = 5,
                    .twilight_focus = 3,
                    .improved_renew = 2,
                    .holy_specialization = 5,
                    .spell_warding = 3,
                    .divine_fury = 5,
                    .searing_light = 2,
                };
                result.action_mask &= ~((@as(u32, 1) << @intFromEnum(action_catalog.PriestAction.MindFlay)) |
                    (@as(u32, 1) << @intFromEnum(action_catalog.PriestAction.Silence)) |
                    (@as(u32, 1) << @intFromEnum(action_catalog.PriestAction.VampiricEmbrace)));
                result.modifiers = CombatModifiers.fromPriestRanks(result.priest_talents);
            }
            return result;
        }
    }
    return null;
}

/// Loads a spec by path, resolving name, class, and talent summary (e.g. "20/31/0").
pub fn loadSpecFile(allocator: std.mem.Allocator, path: []const u8) !SpecConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const class_str = if (root.get("class")) |v| v.string else "warlock";
    const class = Spec.parse(class_str) orelse .warlock;
    const race = if (root.get("race")) |value| blk: {
        if (value != .string) return error.InvalidRace;
        break :blk Race.parse(value.string) orelse return error.UnknownRace;
    } else Race.human;
    if (!race.supports(class)) return error.InvalidRaceClass;
    const pet_value = if (root.get("pet")) |value| blk: {
        if (value != .string) return error.InvalidPet;
        break :blk pets.Kind.parse(value.string) orelse return error.UnknownPet;
    } else null;
    const sacrifice_pet_value = if (root.get("sacrifice_pet")) |value| blk: {
        if (value != .string) return error.InvalidPet;
        break :blk pets.Kind.parse(value.string) orelse return error.UnknownPet;
    } else null;
    var action_mask = try actionMaskFromRoot(root, class);
    const combat_stats = if (root.get("combat_stats")) |value| blk: {
        const stats = try std.json.parseFromValue(CombatStats, allocator, value, .{});
        defer stats.deinit();
        try stats.value.validate();
        break :blk stats.value;
    } else CombatStats{};

    var talents = TalentBuild{};
    var warlock_talents = WarlockTalentRanks{};
    var priest_talents = PriestTalentRanks{};
    var modifiers = CombatModifiers.default();
    if (root.get("trees")) |tree_value| {
        if (tree_value != .object) return error.InvalidTalentTrees;
        const trees = tree_value.object;
        talents = switch (class) {
            .warlock => .{
                .tree1 = try sumTreeRanks(trees, "Affliction"),
                .tree2 = try sumTreeRanks(trees, "Demonology"),
                .tree3 = try sumTreeRanks(trees, "Destruction"),
            },
            .frost_mage => .{
                .tree1 = try sumTreeRanks(trees, "Arcane"),
                .tree2 = try sumTreeRanks(trees, "Fire"),
                .tree3 = try sumTreeRanks(trees, "Frost"),
            },
            .priest => .{
                .tree1 = try sumTreeRanks(trees, "Discipline"),
                .tree2 = try sumTreeRanks(trees, "Holy"),
                .tree3 = try sumTreeRanks(trees, "Shadow Magic"),
            },
        };
        if (talents.total() > 51) return error.InvalidTalentBuild;
        if (root.get("talents_summary")) |summary| {
            const stated = TalentBuild.parse(summary.string) orelse return error.InvalidTalentSummary;
            if (!std.meta.eql(stated, talents)) return error.TalentSummaryMismatch;
        }
        if (class == .warlock) {
            warlock_talents = warlockRanksFromTrees(trees);
            warlock_talents.demonic_sacrifice_pet = @intCast(@intFromEnum(sacrifice_pet_value orelse .imp));
            try validateWarlockRanks(warlock_talents);
            modifiers = CombatModifiers.fromWarlockRanks(warlock_talents);
        } else if (class == .priest) {
            priest_talents = priestRanksFromTrees(trees);
            try validatePriestRanks(priest_talents);
            modifiers = CombatModifiers.fromPriestRanks(priest_talents);
        }
    } else if (root.get("talents_summary")) |ts| {
        // Legacy summary-only specs retain their point totals but do not gain
        // talent effects that cannot be proven from the saved rank data.
        if (TalentBuild.parse(ts.string)) |tb| talents = tb;
    }

    const pet = pet_value orelse if (class == .warlock and warlock_talents.demonic_sacrifice > 0 and (sacrifice_pet_value == null or sacrifice_pet_value.? != .none)) pets.Kind.none else if (class == .warlock) pets.Kind.imp else pets.Kind.none;
    const sacrifice_pet = sacrifice_pet_value orelse if (class == .warlock) pets.Kind.imp else pets.Kind.none;
    if (class == .warlock and pet != .succubus) action_mask &= ~(@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Seduction));
    if (class == .warlock and pet != .felhunter) action_mask &= ~(@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.SpellLock));

    inline for (.{ Race.orc, Race.troll, Race.gnome, Race.undead }, 17..) |required_race, id| {
        if (race != required_race) action_mask &= ~(@as(u32, 1) << id);
    }

    const name = if (root.get("name")) |n| try allocator.dupe(u8, n.string) else try allocator.dupe(u8, path);
    const id = try allocator.dupe(u8, std.fs.path.stem(path));

    return .{
        .id = id,
        .name = name,
        .class = class,
        .talents = talents,
        .action_mask = action_mask,
        .warlock_talents = warlock_talents,
        .priest_talents = priest_talents,
        .pet = pet,
        .sacrifice_pet = sacrifice_pet,
        .modifiers = modifiers,
        .combat_stats = race.applyPassives(combat_stats),
        .race = race,
    };
}

/// Resolves a spec configuration from a canonical ID, path, or filename.
pub fn resolveSpec(allocator: std.mem.Allocator, id_or_path: []const u8) ?SpecConfig {
    if (findCanonicalSpec(id_or_path)) |c| return c;
    // Check if it's a direct file path
    if (loadSpecFile(allocator, id_or_path)) |cfg| return cfg else |_| {}
    // Check inside specs/ directory
    var buf: [256]u8 = undefined;
    const spec_path = std.fmt.bufPrint(&buf, "specs/{s}.json", .{id_or_path}) catch return null;
    if (loadSpecFile(allocator, spec_path)) |cfg| return cfg else |_| {}
    return null;
}

test "TalentBuild parse and format" {
    const build = TalentBuild.parse("30/0/21") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 30), build.tree1);
    try std.testing.expectEqual(@as(u8, 0), build.tree2);
    try std.testing.expectEqual(@as(u8, 21), build.tree3);
    try std.testing.expectEqual(@as(u16, 51), build.total());

    const dash_build = TalentBuild.parse("17-0-34") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 17), dash_build.tree1);
    try std.testing.expectEqual(@as(u8, 34), dash_build.tree3);
}

test "CombatModifiers calculations" {
    const aff = CombatModifiers.fromWarlockRanks(.{ .malediction = 5, .improved_bane_of_agony = 2, .siphon_life = 1 });
    try std.testing.expect(aff.agony_damage_mult > 1.15);
    try std.testing.expect(aff.has_siphon_life);

    const sl = CombatModifiers.fromWarlockRanks(.{ .soul_link = 1 });
    try std.testing.expectEqual(@as(f32, 0.30), sl.soul_link_pct);
    try std.testing.expectEqual(@as(f32, 1.03), sl.shadow_damage_mult);
}

test "loadSpecFile and resolveSpec" {
    const sl = resolveSpec(std.testing.allocator, "soul_link__affliction");
    try std.testing.expect(sl != null);
    if (sl) |cfg| {
        defer std.testing.allocator.free(cfg.name);
        defer std.testing.allocator.free(cfg.id);
        try std.testing.expectEqual(Spec.warlock, cfg.class);
        try std.testing.expectEqual(@as(u8, 24), cfg.talents.tree1);
        try std.testing.expectEqual(@as(u8, 27), cfg.talents.tree2);
        try std.testing.expectEqual(@as(u8, 0), cfg.talents.tree3);
        try std.testing.expectEqual(@as(f32, 0.30), cfg.modifiers.soul_link_pct);
        try std.testing.expectEqual(@as(u8, 1), cfg.warlock_talents.soul_link);
    }
}

test "Aftermath parses from the Destruction tree and rejects excess ranks" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"Destruction":{"105886":5}}
    , .{});
    defer parsed.deinit();
    const ranks = warlockRanksFromTrees(parsed.value.object);
    try std.testing.expectEqual(@as(u8, 5), ranks.aftermath);
    try validateWarlockRanks(ranks);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .aftermath = 6 }));
}

test "Conflagrate talent and saved action loadout round trip into runtime gates" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"action_loadout":["Immolate","Conflagrate"],"trees":{"Destruction":{"105880":1}}}
    , .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const ranks = warlockRanksFromTrees(root.get("trees").?.object);
    try std.testing.expectEqual(@as(u8, 1), ranks.conflagrate);
    try validateWarlockRanks(ranks);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .conflagrate = 2 }));
    const mask = try actionMaskFromRoot(root, .warlock);
    try std.testing.expect(mask & (@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Conflagrate)) != 0);
    try std.testing.expect(mask & (@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Immolate)) != 0);
}

test "pet utility talents parse and reject excess ranks" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"Demonology":{"105901":3,"105894":2}}
    , .{});
    defer parsed.deinit();
    const ranks = warlockRanksFromTrees(parsed.value.object);
    try std.testing.expectEqual(@as(u8, 3), ranks.improved_sayaad);
    try std.testing.expectEqual(@as(u8, 2), ranks.improved_felhunter);
    try validateWarlockRanks(ranks);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .improved_sayaad = 4 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .improved_felhunter = 4 }));
}

test "combat resolution talents parse from the right trees and validate ranks" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"Affliction":{"105925":5,"110876":4,"105918":3},"Destruction":{"105883":3,"105877":2,"105882":2,"105889":5,"105879":3}}
    , .{});
    defer parsed.deinit();
    const ranks = warlockRanksFromTrees(parsed.value.object);
    try std.testing.expectEqual(@as(u8, 5), ranks.suppression);
    try std.testing.expectEqual(@as(u8, 3), ranks.fel_concentration);
    try std.testing.expectEqual(@as(u8, 2), ranks.intensity);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .fel_concentration = 4 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .intensity = 4 }));
    try std.testing.expectEqual(@as(u8, 4), ranks.malevolence);
    try std.testing.expectEqual(@as(u8, 3), ranks.ruin);
    try std.testing.expectEqual(@as(u8, 2), ranks.fire_and_brimstone);
    try std.testing.expectEqual(@as(u8, 5), ranks.improved_shadow_bolt);
    try std.testing.expectEqual(@as(u8, 3), ranks.agonizing_flames);
    try validateWarlockRanks(ranks);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .suppression = 6 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .malevolence = 6 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .ruin = 6 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .fire_and_brimstone = 4 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .improved_shadow_bolt = 6 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .agonizing_flames = 4 }));
}

test "spec files load optional combat probabilities and reject invalid stats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const valid =
        \\{"class":"warlock","combat_stats":{"spell_hit_chance":0.96,"spell_crit_chance":0.05,"fire_resist_chance":0.1}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "stats.json", .data = valid });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "stats.json");
    defer std.testing.allocator.free(path);
    const cfg = try loadSpecFile(std.testing.allocator, path);
    defer std.testing.allocator.free(cfg.id);
    defer std.testing.allocator.free(cfg.name);
    try std.testing.expectEqual(@as(f32, 0.96), cfg.combat_stats.spell_hit_chance);
    try std.testing.expectApproxEqAbs(@as(f32, 0.07), cfg.combat_stats.spell_crit_chance, 0.000001);
    try std.testing.expectEqual(@as(f32, 0.1), cfg.combat_stats.fire_resist_chance);
    try std.testing.expectEqual(@as(f32, 0), cfg.combat_stats.shadow_resist_chance);
    const invalid =
        \\{"combat_stats":{"spell_hit_chance":-0.01}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "stats.json", .data = invalid });
    try std.testing.expectError(error.InvalidCombatStats, loadSpecFile(std.testing.allocator, path));
}

test "Forever racial spec loading validates identity and applies crit passives once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "race.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "race.json");
    defer std.testing.allocator.free(path);
    const cases = [_]struct { json: []const u8, race: Race, arcane: f32, shadow: f32, crit: f32 = 0 }{
        .{ .json = "{}", .race = .human, .arcane = 0, .shadow = 0, .crit = 0.02 },
        .{ .json = "{\"race\":\"gnome\",\"combat_stats\":{\"arcane_resistance\":20}}", .race = .gnome, .arcane = 20, .shadow = 0 },
        .{ .json = "{\"class\":\"frost_mage\",\"race\":\"undead\",\"combat_stats\":{\"shadow_resistance\":15}}", .race = .undead, .arcane = 0, .shadow = 15 },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 1050), Race.gnome.applyPassives(.{}).max_mana, 0.001);
    try std.testing.expect(Race.orc.supports(.frost_mage));
    try std.testing.expect(Race.troll.supports(.warlock));
    try std.testing.expectApproxEqAbs(@as(f32, 0.21), Race.orc.applyPassives(.{ .spell_crit_chance = 0.20 }).spell_crit_chance, 0.000001);
    try std.testing.expectEqual(@as(f32, 1), Race.human.applyPassives(.{ .spell_crit_chance = 1 }).spell_crit_chance);
    for (cases) |case| {
        try tmp.dir.writeFile(.{ .sub_path = "race.json", .data = case.json });
        const cfg = try loadSpecFile(std.testing.allocator, path);
        defer std.testing.allocator.free(cfg.id);
        defer std.testing.allocator.free(cfg.name);
        try std.testing.expectEqual(case.race, cfg.race);
        try std.testing.expectEqual(case.arcane, cfg.combat_stats.arcane_resistance);
        try std.testing.expectEqual(case.shadow, cfg.combat_stats.shadow_resistance);
        try std.testing.expectApproxEqAbs(case.crit, cfg.combat_stats.spell_crit_chance, 0.000001);
    }
    const invalid = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"race\":3}", .err = error.InvalidRace },
        .{ .json = "{\"race\":\"elf\"}", .err = error.UnknownRace },
    };
    for (invalid) |case| {
        try tmp.dir.writeFile(.{ .sub_path = "race.json", .data = case.json });
        try std.testing.expectError(case.err, loadSpecFile(std.testing.allocator, path));
    }
}

test "Demonic Embrace parses stamina and validates ranks" {
    const json =
        \\{"class":"warlock","combat_stats":{"max_health":3000,"stamina":200},"trees":{"Affliction":{},"Demonology":{"105907":5,"105893":3,"105891":5},"Destruction":{}}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "embrace.json", .data = json });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "embrace.json");
    defer std.testing.allocator.free(path);
    const cfg = try loadSpecFile(std.testing.allocator, path);
    defer std.testing.allocator.free(cfg.id);
    defer std.testing.allocator.free(cfg.name);
    try std.testing.expectEqual(@as(u8, 5), cfg.warlock_talents.demonic_embrace);
    try std.testing.expectEqual(@as(u8, 3), cfg.warlock_talents.demonic_knowledge);
    try std.testing.expectEqual(@as(u8, 5), cfg.warlock_talents.master_demonologist);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .demonic_knowledge = 4 }));
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .master_demonologist = 6 }));
    try std.testing.expectEqual(@as(f32, 200), cfg.combat_stats.stamina);
    try std.testing.expectEqual(@as(f32, 3000), cfg.combat_stats.max_health);
    try std.testing.expectError(error.InvalidTalentRank, validateWarlockRanks(.{ .demonic_embrace = 6 }));
    try std.testing.expectError(error.InvalidCombatStats, (CombatStats{ .stamina = -1 }).validate());
    try std.testing.expectError(error.InvalidCombatStats, (CombatStats{ .stamina = 10001 }).validate());
}

test "automatic capabilities include baselines and talent unlocks despite legacy slots" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"automatic_actions":true,"action_slots":["Idle/Maneuver","Cancel Cast"],"trees":{"Destruction":{"105880":1}}}
    , .{});
    defer parsed.deinit();
    const mask = try actionMaskFromRoot(parsed.value.object, .warlock);
    inline for (.{ action_catalog.WarlockAction.Fear, action_catalog.WarlockAction.Immolate, action_catalog.WarlockAction.Conflagrate, action_catalog.WarlockAction.CancelCast }) |action| {
        try std.testing.expect(mask & (@as(u32, 1) << @intFromEnum(action)) != 0);
    }
    try std.testing.expect(mask & (@as(u32, 1) << @intFromEnum(action_catalog.WarlockAction.Shadowburn)) == 0);
}

test "recorded capabilities exclude unsupported cooldowns for canonical builds" {
    const shadow = findCanonicalSpec("shadow_priest").?;
    const shadow_mask = filterActionCapabilities(shadow.class, shadow.action_mask, shadow.warlock_talents, shadow.priest_talents, shadow.race, shadow.pet);
    const pi = @as(u32, 1) << @intFromEnum(action_catalog.PriestAction.PowerInfusion);
    try std.testing.expect(shadow_mask & pi == 0);
    const disc = findCanonicalSpec("disc_priest").?;
    const disc_mask = filterActionCapabilities(disc.class, disc.action_mask, disc.warlock_talents, disc.priest_talents, disc.race, disc.pet);
    try std.testing.expect(disc_mask & pi != 0);
}
