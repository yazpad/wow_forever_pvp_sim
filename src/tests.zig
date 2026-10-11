const std = @import("std");

test {
    _ = @import("simd.zig");
    _ = @import("combat_soa.zig");
    _ = @import("combat_spec.zig");
    _ = @import("policy_simd.zig");
    _ = @import("league.zig");
    _ = @import("benchmark_test.zig");
    _ = @import("match_recorder.zig");
    _ = @import("gauntlet.zig");
    _ = @import("training_logger.zig");
    _ = @import("spec_matrix.zig");
}
