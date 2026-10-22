//! Optional lane-zero telemetry. It is never part of combat snapshots.
pub const Tick = struct {
    damage: [@import("action_catalog_generated.zig").ActionCount]f32 = @splat(0),
};
