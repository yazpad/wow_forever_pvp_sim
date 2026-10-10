const std = @import("std");
const mem = std.mem;

pub const PointSample = struct {
    x: f32, y: f32, z: f32,
    sdf: f32,
    r: f32, g: f32, b: f32,
    roughness: f32, metallic: f32,
};

pub const ModelEntry = struct {
    file: std.fs.File,
    samples: []const PointSample,
    label: []f32,
    moving_indices: []u32, // Indices of points with non-zero displacement
};

pub const MultiDataLoader = struct {
    models: []ModelEntry,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, pcb_dir_path: []const u8, latents_path: []const u8) !MultiDataLoader {
        var dir = try std.fs.cwd().openDir(pcb_dir_path, .{ .iterate = true });
        defer dir.close();

        // Load latents JSON
        const latents_file = try std.fs.cwd().readFileAlloc(allocator, latents_path, 10 * 1024 * 1024);
        defer allocator.free(latents_file);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, latents_file, .{});
        defer parsed.deinit();
        const root = parsed.value.object;

        var models_list = std.ArrayList(ModelEntry).init(allocator);

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pcb")) {
                const name_no_ext = entry.name[0 .. entry.name.len - 4];
                if (root.get(name_no_ext)) |latent_val| {
                    const file = try dir.openFile(entry.name, .{});
                    const stat = try file.stat();
                    const ptr = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
                    
                    const latent_arr = latent_val.array;
                    const label = try allocator.alloc(f32, latent_arr.items.len);
                    for (latent_arr.items, 0..) |v, i| label[i] = @as(f32, @floatCast(v.float));

                    const samples = mem.bytesAsSlice(PointSample, ptr);
                    
                    // --- PRE-INDEX MOVING POINTS ---
                    var moving = std.ArrayList(u32).init(allocator);
                    for (samples, 0..) |s, i| {
                        // Check if r, g, or b (displacement) is non-zero
                        if (@abs(s.r) > 0.0001 or @abs(s.g) > 0.0001 or @abs(s.b) > 0.0001) {
                            try moving.append(@as(u32, @intCast(i)));
                        }
                    }

                    try models_list.append(.{
                        .file = file,
                        .samples = samples,
                        .label = label,
                        .moving_indices = try moving.toOwnedSlice(),
                    });
                }
            }
        }

        std.debug.print("MultiDataLoader: Loaded {d} models from {s}\n", .{models_list.items.len, pcb_dir_path});
        return MultiDataLoader{ .models = try models_list.toOwnedSlice(), .allocator = allocator };
    }

    pub fn deinit(self: *MultiDataLoader) void {
        for (self.models) |m| {
            std.posix.munmap(@alignCast(mem.sliceAsBytes(m.samples)));
            m.file.close();
            self.allocator.free(m.label);
            self.allocator.free(m.moving_indices);
        }
        self.allocator.free(self.models);
    }

    pub fn getBatch(self: MultiDataLoader, batch_size: usize, in_dim: usize, out_dim: usize, prng: *std.Random.DefaultPrng, inputs: []f32, targets: []f32) void {
        const rand = prng.random();
        const latent_dim = if (in_dim > 2) in_dim - 2 else 0;

        for (0..batch_size) |b| {
            // Pick a random model
            const m = self.models[rand.uintLessThan(usize, self.models.len)];
            
            // --- IMPORTANCE SAMPLING ---
            // 50% chance to pick from "moving" points, 50% from global pool
            var s: PointSample = undefined;
            if (m.moving_indices.len > 0 and rand.boolean()) {
                const idx = m.moving_indices[rand.uintLessThan(usize, m.moving_indices.len)];
                s = m.samples[idx];
            } else {
                s = m.samples[rand.uintLessThan(usize, m.samples.len)];
            }
            
            // --- SYMMETRY MIRRORING ---
            const mirror = rand.boolean();
            const u = if (mirror) 1.0 - s.x else s.x;
            const dx = if (mirror) -s.r else s.r;

            // Input: [U, V, Latents...]
            inputs[b * in_dim + 0] = u;
            inputs[b * in_dim + 1] = s.y;
            for (0..latent_dim) |i| {
                inputs[b * in_dim + 2 + i] = m.label[i];
            }
            
            // Output: [dX, dY, dZ]
            targets[b * out_dim + 0] = dx;
            targets[b * out_dim + 1] = s.g;
            targets[b * out_dim + 2] = s.b;
        }
    }
};

// Original DataLoader still needs implementation for SDF/Single tasks
pub const DataLoader = struct {
    file: std.fs.File,
    samples: []const PointSample,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, path: []const u8) !DataLoader {
        const file = try std.fs.cwd().openFile(path, .{});
        const stat = try file.stat();
        const ptr = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
        return DataLoader{
            .file = file,
            .samples = mem.bytesAsSlice(PointSample, ptr),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DataLoader) void {
        std.posix.munmap(@alignCast(mem.sliceAsBytes(self.samples)));
        self.file.close();
    }

    pub fn getBatch(self: DataLoader, batch_size: usize, in_dim: usize, out_dim: usize, prng: *std.Random.DefaultPrng, inputs: []f32, targets: []f32) void {
        const rand = prng.random();
        for (0..batch_size) |i| {
            const s = self.samples[rand.uintLessThan(usize, self.samples.len)];
            if (in_dim == 3) {
                inputs[i * 3 + 0] = s.x;
                inputs[i * 3 + 1] = s.y;
                inputs[i * 3 + 2] = s.z;
            } else {
                inputs[i * 2 + 0] = s.x;
                inputs[i * 2 + 1] = s.y;
            }

            if (out_dim == 3) {
                targets[i * 3 + 0] = s.r;
                targets[i * 3 + 1] = s.g;
                targets[i * 3 + 2] = s.b;
            } else {
                targets[i * out_dim + 0] = s.sdf;
            }
        }
    }
};
