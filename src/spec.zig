const std = @import("std");
const action_catalog = @import("action_catalog_generated.zig");
const ActionCount = action_catalog.ActionCount;
const AllActionBits: u32 = (@as(u32, 1) << ActionCount) - 1;

pub const Spec = enum(u8) {
    warlock = 0,
    frost_mage = 1,

    pub fn parse(name: []const u8) ?Spec {
        inline for (std.meta.fields(Spec)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn actionNames(self: Spec) [action_catalog.ActionCount][]const u8 {
        return switch (self) {
            .warlock => action_catalog.warlock_names,
            .frost_mage => action_catalog.frost_mage_names,
        };
    }
};

pub const FrostAction = action_catalog.FrostAction;

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

pub const WarlockTalentRanks = struct {
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
    shadowburn: u8 = 0, // 105884
    shadow_and_flame: u8 = 0, // 105875

    pub fn encode(self: WarlockTalentRanks) u32 {
        return (@as(u32, self.improved_corruption) & 0x7) |
            ((@as(u32, self.malediction) & 0x7) << 3) |
            ((@as(u32, self.improved_drains) & 0x3) << 6) |
            ((@as(u32, self.improved_bane_of_agony) & 0x3) << 8) |
            ((@as(u32, self.siphon_life) & 0x1) << 10) |
            ((@as(u32, self.shadow_mastery) & 0x7) << 11) |
            ((@as(u32, self.unholy_power) & 0x7) << 14) |
            ((@as(u32, self.soul_link) & 0x1) << 17) |
            ((@as(u32, self.bane) & 0x7) << 18) |
            ((@as(u32, self.molten_skin) & 0x7) << 21) |
            ((@as(u32, self.cataclysm) & 0x3) << 24) |
            ((@as(u32, self.improved_imp) & 0x3) << 26) |
            ((@as(u32, self.shadowburn) & 0x1) << 28) |
            ((@as(u32, self.shadow_and_flame) & 0x7) << 29);
    }
};

/// Scalar summary of supported Warlock effects for spec metadata and reports.
/// The search kernels use the packed rank word to derive SIMD equivalents once
/// per fighter, outside the physics tick loop.
pub const CombatModifiers = struct {
    agony_damage_mult: f32 = 1.0,
    corruption_damage_mult: f32 = 1.0,
    siphon_life_damage_mult: f32 = 1.0,
    siphon_life_healing_mult: f32 = 1.0,
    shadow_damage_mult: f32 = 1.0,
    drain_life_mult: f32 = 1.0,
    damage_taken_mult: f32 = 1.0,
    shadow_bolt_cast_time: f32 = 1.8,
    shadow_bolt_mana_mult: f32 = 1.0,
    pet_damage_mult: f32 = 1.0,
    imp_firebolt_damage_mult: f32 = 1.0,
    soul_link_pct: f32 = 0.0,
    has_siphon_life: bool = false,

    pub fn default() CombatModifiers {
        return .{};
    }

    /// Build scalar effects for spec metadata and UI summaries.
    pub fn fromWarlockRanks(t: WarlockTalentRanks) CombatModifiers {
        var m = CombatModifiers.default();
        const shadow = 1.0 + 0.01 * @as(f32, @floatFromInt(t.shadow_mastery));
        const shadow_damage = shadow * (if (t.soul_link > 0) @as(f32, 1.03) else 1.0);
        const periodic = 1.0 + 0.01 * @as(f32, @floatFromInt(t.malediction));
        m.shadow_damage_mult = shadow_damage;
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
        m.has_siphon_life = t.siphon_life > 0;
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
    modifiers: CombatModifiers,

    pub fn init(id: []const u8, name: []const u8, class: Spec, talents: TalentBuild) SpecConfig {
        return .{
            .id = id,
            .name = name,
            .class = class,
            .talents = talents,
            .action_mask = AllActionBits,
            .modifiers = CombatModifiers.default(),
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

fn actionMaskFromRoot(root: std.json.ObjectMap, class: Spec) !u32 {
    const names = if (class == .warlock) action_catalog.warlock_names else action_catalog.frost_mage_names;
    var mask = AllActionBits;
    if (root.get("action_loadout") orelse root.get("action_slots")) |actions_value| {
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
        const idle_id: usize = if (class == .warlock) @intFromEnum(action_catalog.WarlockAction.IdleOrManeuver) else @intFromEnum(action_catalog.FrostAction.IdleOrManeuver);
        const cancel_id: usize = if (class == .warlock) @intFromEnum(action_catalog.WarlockAction.CancelCast) else @intFromEnum(action_catalog.FrostAction.CancelCast);
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
    }
    return mask & AllActionBits;
}

fn warlockRanksFromTrees(trees: std.json.ObjectMap) WarlockTalentRanks {
    return .{
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
        .shadowburn = rankInTree(trees, "Destruction", "105884"),
        .shadow_and_flame = rankInTree(trees, "Destruction", "105875"),
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
    if (ranks.improved_corruption > 5 or ranks.malediction > 5 or ranks.improved_drains > 3 or
        ranks.improved_bane_of_agony > 2 or ranks.siphon_life > 1 or ranks.shadow_mastery > 5 or
        ranks.unholy_power > 5 or ranks.soul_link > 1 or ranks.bane > 5 or ranks.improved_imp > 3 or
        ranks.molten_skin > 5 or ranks.cataclysm > 3 or ranks.shadowburn > 1 or ranks.shadow_and_flame > 5) return error.InvalidTalentRank;
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
};

pub fn findCanonicalSpec(id: []const u8) ?SpecConfig {
    for (CANONICAL_SPECS) |s| {
        if (std.mem.eql(u8, s.id, id)) {
            var result = s;
            if (std.mem.eql(u8, s.id, "soul_link_warlock")) {
                result.warlock_talents.soul_link = 1;
                result.modifiers = CombatModifiers.fromWarlockRanks(result.warlock_talents);
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
    const action_mask = try actionMaskFromRoot(root, class);

    var talents = TalentBuild{};
    var warlock_talents = WarlockTalentRanks{};
    var modifiers = CombatModifiers.default();
    if (root.get("trees")) |tree_value| {
        if (tree_value != .object) return error.InvalidTalentTrees;
        const trees = tree_value.object;
        talents = .{
            .tree1 = try sumTreeRanks(trees, if (class == .warlock) "Affliction" else "Arcane"),
            .tree2 = try sumTreeRanks(trees, if (class == .warlock) "Demonology" else "Fire"),
            .tree3 = try sumTreeRanks(trees, if (class == .warlock) "Destruction" else "Frost"),
        };
        if (talents.total() > 51) return error.InvalidTalentBuild;
        if (root.get("talents_summary")) |summary| {
            const stated = TalentBuild.parse(summary.string) orelse return error.InvalidTalentSummary;
            if (!std.meta.eql(stated, talents)) return error.TalentSummaryMismatch;
        }
        if (class == .warlock) {
            warlock_talents = warlockRanksFromTrees(trees);
            try validateWarlockRanks(warlock_talents);
            modifiers = CombatModifiers.fromWarlockRanks(warlock_talents);
        }
    } else if (root.get("talents_summary")) |ts| {
        // Legacy summary-only specs retain their point totals but do not gain
        // talent effects that cannot be proven from the saved rank data.
        if (TalentBuild.parse(ts.string)) |tb| talents = tb;
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
        .modifiers = modifiers,
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
