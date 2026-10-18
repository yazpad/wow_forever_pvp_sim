//! Transient spell attribution for the recorded lane, excluded from snapshots.
pub const Tick = struct {
    backlash: f32 = 0,
    damage: [@import("action_catalog_generated.zig").ActionCount]f32 = @splat(0),
    healing: [@import("action_catalog_generated.zig").ActionCount]f32 = @splat(0),
};
