const std = @import("std");
const Stats = @import("spell_resolution.zig").Stats;
const catalog_json = @import("gear_catalog_generated.zig").json;

pub const slots = [_][]const u8{ "head", "neck", "shoulder", "back", "chest", "wrist", "hands", "waist", "legs", "feet", "ring1", "ring2", "trinket1", "trinket2", "main_hand", "off_hand", "wand" };
const Item = struct {
    id: u32,
    slot: []const u8,
    class: ?[]const u8 = null,
    unique: bool = false,
    all_classes: bool = false,
    unique_group: ?[]const u8 = null,
    two_hand: bool = false,
    stats: std.json.Value,
    weapon: ?@import("warrior_arena.zig").Weapon = null,
    off_hand_eligible: bool = false,
    shield_block: ?f32 = null,
};
const Catalog = struct { items: []Item };

const Loaded = struct {
    parsed: std.json.Parsed(Catalog),
    equipped: [slots.len]?Item,
    totals: std.StringHashMap(f32),
    fn deinit(self: *Loaded) void {
        self.totals.deinit();
        self.parsed.deinit();
    }
};

fn readLoadout(allocator: std.mem.Allocator, value: std.json.Value, class: []const u8) !Loaded {
    if (value != .object) return error.InvalidEquipment;
    const parsed = try std.json.parseFromSlice(Catalog, allocator, catalog_json, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    var equipped = [_]?Item{null} ** slots.len;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const index = for (slots, 0..) |slot, i| {
            if (std.mem.eql(u8, slot, entry.key_ptr.*)) break i;
        } else return error.UnknownEquipmentSlot;
        const id_value = entry.value_ptr.*;
        if (id_value != .integer or id_value.integer < 0 or id_value.integer > std.math.maxInt(u32)) return error.InvalidItemId;
        if (id_value.integer == 0) continue;
        const item = for (parsed.value.items) |candidate| {
            if (candidate.id == id_value.integer) break candidate;
        } else return error.UnknownItemId;
        const slot = slots[index];
        const kind = if (std.mem.endsWith(u8, slot, "1") or std.mem.endsWith(u8, slot, "2")) slot[0 .. slot.len - 1] else slot;
        if (!std.mem.eql(u8, kind, item.slot) and !(std.mem.eql(u8, slot, "off_hand") and item.off_hand_eligible)) return error.InvalidItemSlot;
        if (std.mem.eql(u8, class, "warrior") and item.class == null and !item.all_classes) return error.InvalidItemClass;
        if (item.class) |restriction| {
            if (!std.mem.eql(u8, restriction, class)) return error.InvalidItemClass;
        }
        equipped[index] = item;
    }
    for (equipped, 0..) |maybe_item, i| {
        const item = maybe_item orelse continue;
        if (item.unique_group) |group| {
            for (equipped[0..i]) |previous| {
                if (previous) |other| if (other.unique_group) |other_group| {
                    if (std.mem.eql(u8, group, other_group)) return error.DuplicateItemEffect;
                };
            }
        }
        if (item.unique) {
            for (equipped[0..i]) |previous| {
                if (previous != null and previous.?.id == item.id) return error.DuplicateUniqueItem;
            }
        }
    }
    if (equipped[14] != null and equipped[14].?.two_hand and equipped[15] != null) return error.TwoHandOffHandConflict;
    var totals = std.StringHashMap(f32).init(allocator);
    errdefer totals.deinit();
    for (equipped) |maybe_item| {
        const item = maybe_item orelse continue;
        var stats = item.stats.object.iterator();
        while (stats.next()) |entry| {
            const number: f32 = switch (entry.value_ptr.*) {
                .integer => |n| @floatFromInt(n),
                .float => |n| @floatCast(n),
                else => return error.InvalidCatalogStat,
            };
            const result = try totals.getOrPut(entry.key_ptr.*);
            if (!result.found_existing) result.value_ptr.* = 0;
            result.value_ptr.* += number;
        }
    }
    return .{ .parsed = parsed, .equipped = equipped, .totals = totals };
}

/// Validate even legacy exports whose explicit resolved stats take precedence.
pub fn resolve(allocator: std.mem.Allocator, value: std.json.Value, class: []const u8, base: Stats) !Stats {
    return resolveWithReference(allocator, value, class, base, null);
}

pub fn resolveWithReference(allocator: std.mem.Allocator, value: std.json.Value, class: []const u8, base: Stats, reference: ?@import("reference_stats.zig").Baseline) !Stats {
    var loadout = try readLoadout(allocator, value, class);
    defer loadout.deinit();
    const totals = loadout.totals;
    var stats = base;
    const stamina = totals.get("stamina") orelse 0;
    const intellect = totals.get("intellect") orelse 0;
    const armor = totals.get("armor") orelse 0;
    const power = totals.get("spell_power") orelse 0;
    stats.stamina += stamina;
    stats.max_health += stamina * 10;
    stats.max_mana += intellect * 15;
    stats.spell_hit_chance = @min(0.99, 0.96 + (totals.get("spell_hit") orelse 0) / 100);
    const intellect_per_crit: f32 = if (std.mem.eql(u8, class, "warlock")) 60.6 else 59.5;
    const intellect_crit = if (reference) |model| intellect * model.crit_per_intellect else intellect / intellect_per_crit / 100;
    stats.spell_crit_chance = @min(1, base.spell_crit_chance + (totals.get("spell_crit") orelse 0) / 100 + intellect_crit);
    stats.armor_damage_reduction = 1 - (1 - base.armor_damage_reduction) * (1 - armor / (armor + 5500));
    if (reference) |model| stats.armor_damage_reduction = (model.armor + armor) / (model.armor + armor + 5500);
    inline for (.{ "shadow", "fire", "frost" }) |school| {
        @field(stats, school ++ "_power") += power + (totals.get(school ++ "_power") orelse 0);
    }
    inline for (.{ "shadow", "fire", "frost", "arcane" }) |school| {
        @field(stats, school ++ "_resistance") += totals.get(school ++ "_resistance") orelse 0;
    }
    try stats.validate();
    return stats;
}

pub fn warriorBaseStats() Stats {
    return .{ .max_health = 4000, .max_mana = 1 };
}

pub const WarriorResolved = struct {
    stats: Stats,
    config: @import("warrior_arena.zig").Config,
};

pub fn resolveWarrior(allocator: std.mem.Allocator, value: std.json.Value, base: Stats, base_config: @import("warrior_arena.zig").Config) !WarriorResolved {
    var loadout = try readLoadout(allocator, value, "warrior");
    defer loadout.deinit();
    const main = loadout.equipped[14] orelse {
        var only_active = true;
        for (loadout.equipped, 0..) |item, slot| if (item != null and slot != 12 and slot != 13) {
            only_active = false;
        };
        const id = try @import("item_actions.zig").fromGear(value);
        if (!only_active or id == 0) return error.MissingWarriorMainHand;
        var stats = base;
        stats.max_mana = 1;
        try stats.validate();
        try base_config.validate();
        return .{ .stats = stats, .config = base_config };
    };
    const weapon = main.weapon orelse return error.InvalidWarriorWeaponItem;
    var config = base_config;
    config.main_hand = weapon;
    config.off_hand = null;
    config.shield = false;
    var block_value: f32 = 0;
    if (loadout.equipped[15]) |off| {
        if (off.weapon) |off_weapon| {
            if (!off.off_hand_eligible or off_weapon.two_handed) return error.InvalidWarriorWeaponItem;
            config.off_hand = off_weapon;
        } else if (off.shield_block) |shield_block| {
            config.shield = true;
            block_value = shield_block;
        } else return error.InvalidWarriorWeaponItem;
    }
    const totals = loadout.totals;
    const strength = totals.get("strength") orelse 0;
    const agility = totals.get("agility") orelse 0;
    const stamina = totals.get("stamina") orelse 0;
    const hit = (totals.get("melee_hit") orelse 0) / 100;
    config.attack_power += 2 * strength + (totals.get("attack_power") orelse 0);
    config.crit = @min(1, base_config.crit + agility * 0.0005 + (totals.get("melee_crit") orelse 0) / 100);
    config.white_hit = @min(1, @max(0, base_config.white_hit - @as(f32, if (config.off_hand != null) 0.19 else 0) + hit));
    config.special_hit = @min(1, base_config.special_hit + hit);
    var stats = base;
    stats.stamina += stamina;
    stats.max_health += 10 * stamina;
    stats.max_mana = 1;
    const armor = (totals.get("armor") orelse 0) + 2 * agility;
    if (base.armor_damage_reduction < 1) {
        const base_armor = 5500 * base.armor_damage_reduction / (1 - base.armor_damage_reduction);
        stats.armor_damage_reduction = (base_armor + armor) / (base_armor + armor + 5500);
    }
    stats.melee_dodge_chance += stats.melee_avoidance_chance + agility * 0.0005;
    stats.melee_avoidance_chance = 0;
    stats.melee_block_chance = if (config.shield) @max(0.05, base.melee_block_chance) else 0;
    stats.melee_block_value = if (config.shield) base.melee_block_value + block_value + @max(0, strength * 0.05 - 1) else 0;
    inline for (.{ "shadow", "fire", "frost", "arcane" }) |school| {
        @field(stats, school ++ "_resistance") += totals.get(school ++ "_resistance") orelse 0;
    }
    try stats.validate();
    try config.validate();
    return .{ .stats = stats, .config = config };
}
