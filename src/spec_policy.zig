const std = @import("std");
const PolicyGenome = @import("policy_simd.zig").PolicyGenome;
const Spec = @import("spec.zig").Spec;

pub const Model = struct { spec: Spec, genome: PolicyGenome };

// Legacy raw checkpoints remain Warlock. New Mage models carry a versioned tag;
// no model metadata is read in a simulation/inference loop.
pub fn save(genome: *const PolicyGenome, spec: Spec, path: []const u8) !void {
    if (spec == .warlock) return genome.saveToFile(path);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(&.{ 'P', 'S', 'I', 'M', 1, @intFromEnum(spec), 0, 0 });
    try file.writeAll(std.mem.asBytes(genome));
}

pub fn load(path: []const u8) !Model {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    var spec: Spec = .warlock;
    if (size == @sizeOf(PolicyGenome) + 8) {
        var header: [8]u8 = undefined;
        try file.reader().readNoEof(&header);
        if (!std.mem.eql(u8, header[0..4], "PSIM") or header[4] != 1 or header[6] != 0 or header[7] != 0) return error.InvalidModelHeader;
        spec = std.meta.intToEnum(Spec, header[5]) catch return error.InvalidModelSpec;
    } else if (size != @sizeOf(PolicyGenome)) return error.InvalidModelSize;
    var genome: PolicyGenome = undefined;
    try file.reader().readNoEof(std.mem.asBytes(&genome));
    return .{ .spec = spec, .genome = genome };
}

pub fn loadFor(spec: Spec, path: []const u8) !PolicyGenome {
    const model = try load(path);
    if (model.spec != spec) return error.ModelSpecMismatch;
    return model.genome;
}

test "legacy and tagged policies round-trip and reject wrong classes and malformed sizes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "model.bin" });
    defer allocator.free(path);
    var prng = std.Random.DefaultPrng.init(81);
    const genome = PolicyGenome.initRandom(prng.random());
    try save(&genome, .warlock, path);
    try std.testing.expectEqualDeep(genome, try loadFor(.warlock, path));
    try std.testing.expectError(error.ModelSpecMismatch, loadFor(.frost_mage, path));
    try save(&genome, .frost_mage, path);
    try std.testing.expectEqualDeep(genome, try loadFor(.frost_mage, path));
    try std.testing.expectError(error.ModelSpecMismatch, loadFor(.warlock, path));
    try std.testing.expectError(error.InvalidModelSize, PolicyGenome.loadFromFile(path));
    const file = try tmp.dir.createFile("model.bin", .{});
    try file.writeAll("PSIM");
    file.close();
    try std.testing.expectError(error.InvalidModelSize, load(path));
}
