//! Validated Forever talent configuration. Not yet wired into selectable kits.
const std = @import("std");
const simd = @import("simd.zig");
pub const data = @import("warrior_data_generated.zig");
pub const Talent = data.Talent;
pub const Packed = [4]u32;
pub const Error = error{ InvalidRank, TooManyPoints, MissingTierPoints, MissingPrerequisite };

pub const Build = struct {
    ranks: [data.definitions.len]u8 = @splat(0),

    pub fn set(self: *Build, talent: Talent, value: u8) Error!void {
        const index = @intFromEnum(talent);
        if (value > data.definitions[index].max_rank) return error.InvalidRank;
        self.ranks[index] = value;
    }

    pub fn validate(self: Build) Error!void {
        var total: u16 = 0;
        for (data.definitions, self.ranks) |definition, value| {
            if (value > definition.max_rank) return error.InvalidRank;
            total += value;
        }
        if (total > 51) return error.TooManyPoints;
        for (data.definitions, self.ranks) |definition, value| {
            if (value == 0) continue;
            var below: u16 = 0;
            for (data.definitions, self.ranks) |other, rank_value| {
                if (other.tree == definition.tree and other.row < definition.row) below += rank_value;
            }
            if (below < @as(u16, definition.row) * 5) return error.MissingTierPoints;
            if (definition.prerequisite) |parent| {
                const index = @intFromEnum(parent);
                if (self.ranks[index] < data.definitions[index].max_rank) return error.MissingPrerequisite;
            }
        }
    }

    pub fn pack(self: Build) Error!Packed {
        try self.validate();
        var words: Packed = @splat(0);
        for (data.definitions, self.ranks) |definition, value| {
            words[definition.word] |= @as(u32, value) << definition.shift;
        }
        return words;
    }
};

pub fn rank(words: Packed, talent: Talent) u8 {
    const definition = data.definitions[@intFromEnum(talent)];
    const mask = (@as(u32, 1) << definition.bits) - 1;
    return @intCast((words[definition.word] >> definition.shift) & mask);
}

pub fn rankVector(words: [4]simd.u32x16, comptime talent: Talent) simd.f32x16 {
    const definition = data.definitions[@intFromEnum(talent)];
    const mask: simd.u32x16 = @splat((@as(u32, 1) << definition.bits) - 1);
    const shifts: @Vector(16, u5) = @splat(definition.shift);
    return @floatFromInt((words[definition.word] >> shifts) & mask);
}

/// Only effects consumed by the initial rage/stance foundation. Other ranks are
/// preserved, but are not advertised as implemented combat effects.
pub const ResourceEffects = struct {
    max_rage: simd.f32x16,
    retained_rage: simd.f32x16,
    offhand_rage_multiplier: simd.f32x16,
};

pub fn resources(words: [4]simd.u32x16) ResourceEffects {
    const V = simd.f32x16;
    return .{
        .max_rage = @as(V, @splat(100)) + rankVector(words, .boundlessRage) * @as(V, @splat(10)),
        .retained_rage = @as(V, @splat(10)) + rankVector(words, .improvedTacticalMastery) * @as(V, @splat(3)),
        .offhand_rage_multiplier = @as(V, @splat(1)) + rankVector(words, .dualWieldSpecialization) * @as(V, @splat(0.2)),
    };
}
