const std = @import("std");

test {
    _ = @import("pets_test.zig");
    _ = @import("conflagrate_test.zig");
    _ = @import("fight_analysis.zig");
    _ = @import("geometry_test.zig");
    _ = @import("mcts.zig");
    _ = @import("simd.zig");
    _ = @import("multi_spec.zig");
    _ = @import("combat_soa.zig");
    _ = @import("combat_spec.zig");
    _ = @import("match_recorder.zig");
    _ = @import("search_sim.zig");
}
