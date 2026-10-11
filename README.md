# ⚔️ PvP Sim: Ultra-Fast Vectorized Combat Simulation Engine

A high-performance, SIMD-accelerated battle simulation engine written in **Zig 0.14**. 

Built for extreme throughput (hundreds of millions to billions of entity ticks per second), designed for Monte-Carlo battle simulations, auto-battlers, matchmaking balance calculations, and real-time game logic.

---

## 🚀 Performance Highlights

Benchmarked on AMD Zen (AVX-512 enabled):

* **Combatant Ticks:** **~5.0 Billion ticks / sec** (100,000 units simulated for 1,000 frames in ~20 ms).
* **Monte-Carlo Duels:** **~5.0 Million complete 1v1 duels / sec** (64,000 parallel duels simulated to death in ~13 ms).
* **Per-Batch Tick:** **0.020 ms** per 100,000 units.

---

## 🏛️ Core Architectural Pillars for Super Optimization

### 1. Structure-of-Arrays (SoA) vs Array-of-Structures (AoS)
Instead of standard OOP / AoS:
```zig
// ❌ Cache-unfriendly AoS (poor cache locality, strided SIMD loads)
struct Combatant {
    hp: f32, max_hp: f32, shield: f32, mana: f32, armor: f32, ...
};
```
We store entities as column arrays:
```zig
// ✅ High-throughput SoA (sequential streaming, 100% cache-line utilization)
pub const CombatantPool = struct {
    hp: []align(64) f32,
    shield: []align(64) f32,
    armor: []align(64) f32,
    attack_power: []align(64) f32,
    ...
};
```

### 2. Strict 64-Byte Hardware Alignment
Every buffer is allocated with 64-byte alignment:
* Perfectly aligns with x86 cache lines (64 bytes).
* Enables unaligned-penalty-free 512-bit AVX-512 ZMM register loads (`@Vector(16, f32)`).
* Avoids split-cache-line access penalties.

### 3. Pure Branchless Computation (`@select` / SIMD Masks)
Branch mispredictions inside tight combat loops destroy instruction pipeline throughput. All conditional logic is transformed into vectorized arithmetic:
* **Shield absorption:** `absorb = @min(shield, incoming_damage)`
* **Death check:** `alive_mask = hp > 0.0`
* **Damage application:** `@select(f32, alive_mask, hp - damage, 0.0)`
* **Logical operations:** `vAnd16(a, b)`, `vOr16(a, b)` using `@select(bool, ...)` to emit single hardware mask instructions (`kandw`, `korw`).

---

## 📁 Repository Structure

```
~/pvp_sim/
├── build.zig                  # Native Zig 0.14 build file (-OReleaseFast)
├── README.md                  # This reference and architecture guide
└── src/
    ├── main.zig               # Benchmarks, training, evaluation, recording CLI
    ├── combat_spec.zig        # Warlock arena and dual-clock combat
    ├── policy_simd.zig        # 24 → 24 → 9 policy plus movement head
    ├── league.zig             # Evolution, checkpoints, historical/external sparring
    ├── training_logger.zig    # Lua/JSON generation telemetry
    ├── gauntlet.zig           # Four fixed benchmark bot archetypes
    ├── spec_matrix.zig        # Saved-model matchup matrix
    ├── match_recorder.zig     # 100 Hz fight recording
    ├── tests.zig              # Functional and throughput test entry point
    ├── simd.zig               # Vector types (f32x16, f32x8), branchless helpers, FMA
    ├── combat_soa.zig         # CombatantPool SoA data layout and SIMD duel engine
    └── reference/             # Migrated reference implementations from Moontide
        ├── moontide_simd.zig  # Foundational SIMD array ops, neuromorphic leak, 4x4 matrix mul
        ├── kan_spline.zig     # Branchless piecewise polynomial evaluation (replacing Cox-de Boor)
        ├── kan_layer.zig      # 512-bit ZMM register streaming, 2-pass FMA accumulation
        └── kan_dataloader.zig # Zero-copy memory-mapped (mmap) binary ingestion
```

---

## 📚 Migrated Reference Files

The following files from the Moontide engine are preserved in `src/reference/` as blueprints for specific optimization techniques:

1. **`src/reference/moontide_simd.zig`**:
   * Demonstrates 8-wide (256-bit AVX) and 16-wide (512-bit AVX-512) basic vector operations (`add`, `sub`, `mul`, `madd`).
   * Vectorized 4x4 matrix multiplication using `@Vector(4, f32)` splats and broadcast FMAs.
2. **`src/reference/kan_spline.zig`**:
   * Demonstrates how to eliminate heavy recursive algorithms by expanding analytical polynomial formulas into branchless piecewise functions (`basisAll`, `basisAllSimd`).
3. **`src/reference/kan_layer.zig`**:
   * Two-pass pattern: pre-evaluating math into stack buffers followed by pure, uninterrupted FMA register accumulation without cache thrashing.
4. **`src/reference/kan_dataloader.zig`**:
   * High-speed `std.posix.mmap` with `mem.bytesAsSlice` for zero-copy streaming of huge datasets directly into memory without serialization overhead.

---

## 🛠️ Building & Running

### Run the Benchmark (Fast Release)
```bash
zig build run -Doptimize=ReleaseFast
```

### Run Tests
```bash
zig build test
```

## Training and evaluation

See [CLI_REFERENCE.md](CLI_REFERENCE.md) for training, resume, sparring, recording, and Love2D playback commands, and [RL_PVP_DESIGN.md](RL_PVP_DESIGN.md) for roadmap status. The current engine supports Warlock combat with 24 observations, 24 hidden units, 9 actions, and a separate movement head. Models named after other Warlock specs currently share this kit.

Run the performance regression floors on the benchmark host:

```bash
zig build test -Doptimize=ReleaseFast
```

Generation metrics describe the evaluated population before breeding. `wins`, `losses`, and `draws` count each scheduled duel once from its initiating agent's perspective, including external and historical opponents. `elo_stddev` is the population standard deviation. `match_duration_bins` counts durations in `[0,5)`, `[5,10)`, `[10,20)`, `[20,30)`, and `[30,infinity)` seconds. Action and movement counts profile the champion against an idle target. New exports identify this interpretation with `outcome_scope = "initiating_agent"`; older metrics retain their original champion-only W/L/D interpretation and are labeled as legacy in the viewer.

Source, documentation, scripts, and visualizer assets belong in version control. Generated models (`*.bin`), population checkpoints (`*.pop`), match recordings, matrices, and training metrics are ignored and can be regenerated with the CLI. The headless engine needs Zig only; graphical playback additionally needs Love2D.
