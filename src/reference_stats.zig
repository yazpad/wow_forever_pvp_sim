//! Provisional, opt-in level-60 reference baseline; see STAT_PROFILES.md.
const std = @import("std");
const Stats = @import("spell_resolution.zig").Stats;
pub const profile_name = "level60_reference_v1";
const Attributes = struct {
    health: f32 = 0,
    mana: f32 = 0,
    stamina: f32 = 0,
    intellect: f32 = 0,
    agility: f32 = 0,
    base_spell_crit_percent: f32 = 0,
    spell_crit_percent_per_intellect: f32 = 0,
};
const Data = struct {
    classes: struct { warlock: Attributes, frost_mage: Attributes, priest: Attributes },
    race_offsets: struct { human: Attributes, gnome: Attributes, orc: Attributes, undead: Attributes, troll: Attributes },
    resource_offsets: struct { health: f32, mana: f32 },
};
pub const Baseline = struct {
    stats: Stats,
    armor: f32,
    crit_per_intellect: f32,
};

pub fn load(allocator: std.mem.Allocator, class: []const u8, race: []const u8) !Baseline {
    const data = try std.json.parseFromSlice(Data, allocator, @import("stat_reference_generated.zig").json, .{ .ignore_unknown_fields = true });
    defer data.deinit();
    const base = inline for (std.meta.fields(@TypeOf(data.value.classes))) |field| {
        if (std.mem.eql(u8, class, field.name)) break @field(data.value.classes, field.name);
    } else return error.UnsupportedStatProfileClass;
    const offset = inline for (std.meta.fields(@TypeOf(data.value.race_offsets))) |field| {
        if (std.mem.eql(u8, race, field.name)) break @field(data.value.race_offsets, field.name);
    } else return error.UnsupportedStatProfileRace;
    const stamina = base.stamina + offset.stamina;
    const intellect = base.intellect + offset.intellect;
    const armor = 2 * (base.agility + offset.agility);
    const coefficient = base.spell_crit_percent_per_intellect / 100;
    return .{
        .stats = .{
            .stamina = stamina,
            .max_health = base.health + 10 * stamina + data.value.resource_offsets.health,
            .max_mana = base.mana + 15 * intellect + data.value.resource_offsets.mana,
            .spell_hit_chance = 0.96,
            .spell_crit_chance = base.base_spell_crit_percent / 100 + intellect * coefficient,
            .armor_damage_reduction = armor / (armor + 5500),
        },
        .armor = armor,
        .crit_per_intellect = coefficient,
    };
}
