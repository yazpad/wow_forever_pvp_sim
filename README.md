# ⚔️ PvP Sim: Ultra-Fast Vectorized Combat Simulation Engine

A high-performance, SIMD-accelerated battle simulation engine written in **Zig 0.14**. 

Built for extreme throughput (hundreds of millions to billions of entity ticks per second), designed for Monte-Carlo battle simulations, auto-battlers, matchmaking balance calculations, and real-time game logic.

Current priorities and detailed checklists: [Project TODO](TODO.md).

The visualizer supports per-slot Vanilla pre-raid gear for Warlock and Frost Mage, with resolved combat stats. See [Gear setup and data sources](GEAR.md).

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

See [CLI_REFERENCE.md](CLI_REFERENCE.md) for training, resume, sparring, recording, and Love2D playback commands, and [RL_PVP_DESIGN.md](RL_PVP_DESIGN.md) for roadmap status. The engine supports Warlock and Frost Mage with 24 observations, 24 hidden units, 11 Warlock action IDs (including idle and cancel-cast), and a separate movement head. See [Frost Mage mechanics, commands, and performance checks](FROST_MAGE.md). Models named after other Warlock specs currently share this kit.

Run the performance regression floors on the benchmark host:

```bash
zig build test -Doptimize=ReleaseFast
```

Generation metrics describe the evaluated population before breeding. `wins`, `losses`, and `draws` count each scheduled duel once from its initiating agent's perspective, including external and historical opponents. `elo_stddev` is the population standard deviation. `match_duration_bins` counts durations in `[0,5)`, `[5,10)`, `[10,20)`, `[20,30)`, and `[30,infinity)` seconds. Action and movement counts profile the champion against an idle target. New exports identify this interpretation with `outcome_scope = "initiating_agent"`; older metrics retain their original champion-only W/L/D interpretation and are labeled as legacy in the viewer.

Source, documentation, scripts, and visualizer assets belong in version control. Generated models (`*.bin`), population checkpoints (`*.pop`), match recordings, matrices, and training metrics are ignored and can be regenerated with the CLI. The headless engine needs Zig only; graphical playback additionally needs Love2D.

Start training from the desktop app with `love visualizer --training` after building. The Training Controls tab (F5) launches the native trainer, supports resume and graceful stop/save, and feeds live graphs (F2). Training defaults to one CPU thread with 16-wide SIMD; `--threads N` enables persistent workers across CPU cores. See [CLI_REFERENCE.md](CLI_REFERENCE.md) for settings and run artifacts.

F5 opens the training pipeline dashboard. Warlock and Frost Mage are the two supported simulator kits. Train each base kit with self-play, then train Warlock vs Frost Mage and Frost Mage vs Warlock using the base champions as seeds and external sparring opponents. **Run remaining pipeline** runs these stages sequentially; **Stop & save** pauses the current stage and cancels the remaining queue. Individual stages can be continued from their saved population. Use **Settings / manual training** to set generations, population, duel batches, checkpoints, and CPU threads before launching the pipeline.

Pipeline runs record their stage and completion state beside their artifacts in `training_runs`, so the dashboard restores saved progress on restart. Completed means the requested generations finished; it does not certify model quality. Older runs are counted by kit but have unknown pipeline stages and are not automatically promoted to completed stages. Other classes and distinct Warlock specs still require simulator implementation. Matchup training retains league self-play alongside external sparring.

Successful individual or manual training runs, and the end of the full pipeline, automatically evaluate saved champions and record replays. **Evaluate + replays** on F5 also runs this step independently. Evaluation snapshots models from `models/`, saved pipeline stages, and the latest legacy champion per kit when no base stage exists, without moving source checkpoints. It writes `spec_matrix.lua` and recordings in `matches/`, then refreshes F4 and F3. Evaluation snapshots and logs live in `evaluation_runs/`. F3 shows class icons from replay metadata; use arrows or Page Up/Page Down to browse all recordings.

Training supports `--threads N` and the Love2D **CPU training threads** setting (default: 1). See [multithreading performance and design](MULTITHREADING.md).

## 2D duel movement

Combat state stores aligned `pos_x_a`, `pos_y_a`, `pos_x_b`, and `pos_y_b` arrays and derives opponent distance from those positions. Movement remains advance, hold, or retreat along the current opponent axis; agents cannot choose to strafe. Fear makes targets wander at 7 m/s, and Polymorph makes them wander at 2.5 m/s. Directions change in 0.75-second timer buckets, including lateral and forward/back movement, with normalized diagonal speed. Roots and slows still apply.

Movement uses the existing 16-wide SIMD batches. Forced paths are deterministic from combat timers, so MCTS snapshots reproduce them without additional random state. Blink moves along the opponent axis. The existing 0–35 m separation constraint remains; this change does not add walls, obstacles, or pathfinding.

Replay columns 3/4 retain the X positions; appended columns 49/50 store A/B Y positions after the Frost telemetry. Older recordings default to Y=0 in playback. New recordings use actual combat positions for characters, beams, projectiles, and combat text.

## Projectile travel

Shadow Bolt and Frostbolt travel at 30 m/s, Ice Lance at 40 m/s, and Death Coil at 20 m/s. These are simulator tuning values, defined in `src/projectiles.zig`, rather than values tied to a game patch. A stationary target 30 m away takes approximately 1 second for a bolt to reach, after the cast completes. Travel and impact are quantized to the 10 ms physics tick.

Missiles home toward the target's current 2D position, including after Blink. Damage, Frostbolt slow, Death Coil healing/Horror/interrupts, shield absorption, and damage-based control breaks occur on impact. Ice Lance's frozen damage bonus is selected at launch. Fear and Polymorph remain direct effects on cast completion; DOT applications and Drain Life remain direct/channeled effects.

Each caster has four fixed projectile slots in aligned SoA arrays, with no per-shot heap allocation. Empty queues skip flight math. Queues and positions are included in MCTS snapshots. New replay columns 51–82 store four `spell, damage, x, y` slots per side; playback uses these recorded positions and emits impact effects at the recorded arrival time. Older replays keep their legacy cosmetic projectile effects.

## Learned MCTS experiment

See [the fresh value-learning strategy](LEARNED_MCTS_STRATEGY.md) for class-specific versus shared models, the frozen bare-MCTS control, validation gates, and reproducible commands. Measured pilot outcomes are recorded in [learning results](benchmarks/learning/RESULTS.md). The experimental arena is separate from normal fight generation.
