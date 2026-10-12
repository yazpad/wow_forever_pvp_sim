const std = @import("std");

pub const Spec = enum(u8) {
    warlock = 0,
    frost_mage = 1,

    pub fn parse(name: []const u8) ?Spec {
        inline for (std.meta.fields(Spec)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn actionNames(self: Spec) [9][]const u8 {
        return switch (self) {
            .warlock => .{ "Idle/Maneuver", "Agony", "Corruption", "Fear", "Shadow Bolt", "Drain Life", "Unending Resolve", "Death Coil", "Cancel Cast" },
            .frost_mage => .{ "Idle/Maneuver", "Ice Lance", "Frost Nova", "Polymorph", "Frostbolt", "Blink", "Ice Barrier", "Counterspell", "Cancel Cast" },
        };
    }
};

pub const FrostAction = enum(u32) {
    IdleOrManeuver = 0,
    IceLance = 1,
    FrostNova = 2,
    Polymorph = 3,
    Frostbolt = 4,
    Blink = 5,
    IceBarrier = 6,
    Counterspell = 7,
    CancelCast = 8,
};

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

/// Combat stat multipliers derived from a talent build.
/// Kept branchless and computed at init/compile time so simulation loops never branch.
pub const CombatModifiers = struct {
    // Damage scaling
    dot_dmg_mult: f32 = 1.0,
    direct_dmg_mult: f32 = 1.0,
    // Cast time scaling
    cast_time_mult: f32 = 1.0,
    // Cooldown scaling
    cooldown_mult: f32 = 1.0,
    // Defensives & EHP
    damage_taken_mult: f32 = 1.0,
    shield_absorb_mult: f32 = 1.0,
    healing_mult: f32 = 1.0,
    // Speed
    move_speed_mult: f32 = 1.0,

    pub fn default() CombatModifiers {
        return .{};
    }

    /// Compute modifiers from class and talent build x/y/z
    pub fn fromTalents(class: Spec, talents: TalentBuild) CombatModifiers {
        var m = CombatModifiers.default();
        switch (class) {
            .warlock => {
                // Tree 1: Affliction (e.g. up to +25% dot damage, +20% siphon heal)
                const aff_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree1)) / 30.0);
                m.dot_dmg_mult += 0.25 * aff_ratio;
                m.healing_mult += 0.20 * aff_ratio;

                // Tree 2: Demonology / Soul Link (e.g. up to 20% passive damage reduction)
                const demo_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree2)) / 30.0);
                m.damage_taken_mult -= 0.20 * demo_ratio;

                // Tree 3: Destruction (e.g. up to +30% direct spell damage, -15% cast time)
                const destro_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree3)) / 30.0);
                m.direct_dmg_mult += 0.30 * destro_ratio;
                m.cast_time_mult -= 0.15 * destro_ratio;
            },
            .frost_mage => {
                // Tree 1: Arcane (Presence of Mind / cooldown reductions & mana efficiency)
                const arc_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree1)) / 30.0);
                m.cooldown_mult -= 0.15 * arc_ratio;

                // Tree 2: Fire (Burst damage scaling)
                const fire_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree2)) / 30.0);
                m.direct_dmg_mult += 0.25 * fire_ratio;

                // Tree 3: Frost (Shield absorption, control & shattered burst)
                const frost_ratio = @min(1.0, @as(f32, @floatFromInt(talents.tree3)) / 30.0);
                m.shield_absorb_mult += 0.30 * frost_ratio;
                m.dot_dmg_mult += 0.15 * frost_ratio; // Chilled / control mastery
                m.damage_taken_mult -= 0.10 * frost_ratio;
            },
        }
        return m;
    }
};

/// High-level specification configuration
pub const SpecConfig = struct {
    id: []const u8,
    name: []const u8,
    class: Spec,
    talents: TalentBuild,
    modifiers: CombatModifiers,

    pub fn init(id: []const u8, name: []const u8, class: Spec, talents: TalentBuild) SpecConfig {
        return .{
            .id = id,
            .name = name,
            .class = class,
            .talents = talents,
            .modifiers = CombatModifiers.fromTalents(class, talents),
        };
    }
};

/// Standard canonical specs with explicit talent builds x/y/z
pub const CANONICAL_SPECS = [_]SpecConfig{
    // Warlocks
    SpecConfig.init("affliction_warlock", "Affliction Warlock", .warlock, .{ .tree1 = 30, .tree2 = 0, .tree3 = 21 }),
    SpecConfig.init("soul_link_warlock", "Soul Link Warlock", .warlock, .{ .tree1 = 20, .tree2 = 31, .tree3 = 0 }),
    SpecConfig.init("destro_warlock", "Destruction Warlock", .warlock, .{ .tree1 = 0, .tree2 = 17, .tree3 = 34 }),

    // Mages
    SpecConfig.init("deep_frost_mage", "Deep Frost Mage", .frost_mage, .{ .tree1 = 17, .tree2 = 0, .tree3 = 34 }),
    SpecConfig.init("elemental_mage", "Elemental Mage", .frost_mage, .{ .tree1 = 0, .tree2 = 28, .tree3 = 23 }),
};

pub fn findCanonicalSpec(id: []const u8) ?SpecConfig {
    for (CANONICAL_SPECS) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
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
    const aff = CombatModifiers.fromTalents(.warlock, .{ .tree1 = 30, .tree2 = 0, .tree3 = 0 });
    try std.testing.expect(aff.dot_dmg_mult > 1.20);
    try std.testing.expect(aff.healing_mult > 1.15);

    const sl = CombatModifiers.fromTalents(.warlock, .{ .tree1 = 0, .tree2 = 30, .tree3 = 0 });
    try std.testing.expect(sl.damage_taken_mult < 0.85);

    const frost = CombatModifiers.fromTalents(.frost_mage, .{ .tree1 = 0, .tree2 = 0, .tree3 = 30 });
    try std.testing.expect(frost.shield_absorb_mult > 1.25);
}

