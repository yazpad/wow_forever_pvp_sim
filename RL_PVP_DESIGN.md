# ⚔️ Vectorized RL PvP Simulator: Architecture & League Play Specification

## 1. Project Mission & Constraints
* **Primary Objective:** Build an ultra-optimized, zero-dependency, SIMD-accelerated (AVX-512 / AVX2) PvP combat simulator in pure **Zig 0.14** for reinforcement learning tournaments.
* **Environment Constraints:**
  * **Zero Python / Zero External Dependencies:** 100% native Zig standard library.
  * **CPU Only:** Pure x86_64 vector extensions (`@Vector(16, f32)`, FMA, `@select`).
  * **No Line of Sight (LOS):** 1D continuous distance ($0\text{m} \le d \le 35\text{m}$), eliminating raycasting overhead.
  * **Dual-Clock Reaction Model:** 100 Hz ($10\text{ms}$) physics/combat tick + 10 Hz ($100\text{ms}$) cognitive reaction intervals with hard stops on GCD / cast completions (zero action leaks).
  * **Extensible Specs:** Start with **Warlock** (affliction/destruction flavor), designed with generic SoA channels so additional classes (Mage, Rogue, Warrior) can be added seamlessly.
  * **Learning Paradigm:** **Vectorized Neuroevolution & League Play** (AVX-512 batched MLP forward passes, round-robin batch tournaments, Hall of Fame anti-cycling).

---

## 2. Combat Mechanics: Warlock Specification

### 2.1 Vitals & Attributes
* **HP:** Max $2000.0$
* **Mana:** Max $1000.0$, passive regeneration $+15.0\text{/s}$
* **Movement Speed:** Running forward $7.0\text{ m/s}$, Backpedaling / Kiting $4.5\text{ m/s}$
* **Arena Distance:** $0.0\text{m}$ to $35.0\text{m}$ (starts at $25.0\text{m}$)
* **Global Cooldown (GCD):** $1.0\text{s}$

### 2.2 Action Palette (9 Discrete Actions)
| Action ID | Name | Cast Type | Cast Time | Base Dmg/Heal | Range | Resource | Movement Rule | Special Effect |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| **0** | **Maneuver / Idle** | None | 0s | - | - | 0 | Move $\pm$ | Choose direction (Advance, Kite, or Stand) without casting |
| **1** | **Agony** | Instant | 0s | 30 dps | 35m | 30 Mana | **Castable while moving** | Applies 18s stacking DOT |
| **2** | **Corruption** | Instant | 0s | 50 dps | 35m | 40 Mana | **Castable while moving** | Applies 14s continuous DOT |
| **3** | **Fear** | Hard Cast | 1.5s | 0 | 20m | 60 Mana | **Stationary only** | Crowd Control: Interrupts target & incapacitates for up to 4s |
| **4** | **Shadow Bolt** | Hard Cast | 1.8s | 240 dmg | 35m | 50 Mana | **Stationary only** | Heavy direct damage nuker |
| **5** | **Drain Life** | Channel | 3.0s | 70 dps / +60 hps | 25m | 70 Mana | **Stationary only** | Channeled life siphon (deals dmg and heals self) |
| **6** | **Unending Resolve** | Instant | 0s | - | Self | 0 | **Castable while moving** | 45s CD: 40% damage reduction for 6s |
| **7** | **Death Coil** | Instant | 0s | 180 dmg / 300 heal | 30m | 50 Mana | **Castable while moving** | 45s CD: 3s Horror with separate DR |
| **8** | **Cancel Cast** | Instant | 0s | - | Self | 0 | Anywhere | **Cancels active cast** (crucial for fake-casting and baiting) |

### 2.3 Hard Stops & Reaction Time Dynamics
1. **100ms Reaction Timer (`t_react`):** Agent evaluates the policy network every 100ms instead of every 10ms (10x policy evaluation speedup).
2. **Hard Stop Interrupt:** If:
   * GCD expires (`gcd <= 0.0`), OR
   * Cast completes (`cast_timer <= 0.0`), OR
   * Agent is Feared / CC'd,
   $\to$ The reaction timer is immediately forced to $0.0$, granting the agent instant opportunity to choose its next action without dead-time leakage.
3. **Movement Violation:** If an agent attempts to move while casting a stationary spell (`Fear`, `Shadow Bolt`, `Drain Life`), the cast is aborted unless `Cancel Cast` is explicitly chosen or movement is idle.

---

## 3. Vectorized State (SoA) & Observation Layout

All data arrays are aligned to **64-byte boundaries** (`align(64)`), matching 512-bit ZMM registers (16 parallel duels per SIMD vector lane).

### 3.1 Observation Vector (24 Observation Features per Agent)
Packaged branchlessly across 16 parallel duels:
1. `self_hp_norm`: $\text{hp} / \text{max\_hp}$
2. `self_mana_norm`: $\text{mana} / \text{max\_mana}$
3. `target_hp_norm`: $\text{hp}_{\text{tgt}} / \text{max\_hp}_{\text{tgt}}$
4. `target_mana_norm`: $\text{mana}_{\text{tgt}} / \text{max\_mana}_{\text{tgt}}$
5. `distance_norm`: $d / 35.0$
6. `self_gcd_norm`: $\text{gcd} / 1.0$
7. `self_is_casting`: $1.0$ if casting, else $0.0$
8. `self_cast_progress`: remaining / duration
9. `target_is_casting`: $1.0$ if target casting, else $0.0$
10. `target_cast_spell_id`: normalized spell ID
11. `target_cast_progress`: remaining / duration
12. `target_agony_timer_norm`: $\text{agony\_timer} / 18.0$
13. `target_corruption_timer_norm`: $\text{corruption\_timer} / 14.0$
14. `target_is_feared`: $1.0$ if target in fear, else $0.0$
15. `self_is_feared`: $1.0$ if self in fear, else $0.0$
16. `self_defensive_cd_norm`: $\text{cd} / 45.0$
17. `self_defensive_active`: $1.0$ if Unending Resolve active, else $0.0$
18. `target_defensive_active`: $1.0$ if enemy defensive active, else $0.0$
19. `movement_direction`: $-1.0$ (advancing), $0.0$ (stationary), $+1.0$ (kiting)
20. `relative_advantage`: $(\text{self\_hp} - \text{target\_hp}) / \text{max\_hp}$
21. `self_death_coil_cd_norm`: Death Coil cooldown / 45s
22. `self_is_cc`: feared or horrified
23. `target_is_cc`: feared or horrified
24. `target_fear_dr_tier_norm`: fear DR tier / 3

---

## 4. Vectorized Policy Architecture (Pure SIMD MLP)
* **Architecture:** $24 \to 24 \to 9$ feed-forward network.
  * Layer 1: $24$ inputs $\times 24$ hidden + $24$ biases $\to$ ReLU activation (`@max(0, x)`).
  * Layer 2: $24$ hidden $\times 9$ actions + $9$ biases $\to$ Logits.
  * Separate movement head: 24 hidden weights plus bias select movement intent.
* **Vector Execution:** Weights are stored per genome; for 16 duels in a SIMD lane, observations are vector registers (`f32x16`), and unrolled broadcast FMAs evaluate all 16 duels simultaneously.
* **Action Masking:** Branchless invalidation (sets logits of illegal actions to $-10^9$):
  * Out of mana $\to$ mask spell
  * Out of range $\to$ mask spell
  * On GCD $\to$ mask instant/hard spells (leave Maneuver and Cancel Cast legal)
  * Currently CC'd/Feared $\to$ mask all except Cancel/Idle
  * Not casting $\to$ mask Cancel Cast

---

## 5. League Play & Evolutionary Tournament Structure

```
                  ┌────────────────────────────────────────┐
                  │          Active Population             │
                  │   (e.g., 64 Genomes, Elo-Rated)        │
                  └──────────────────┬─────────────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
┌──────────────────────────────────────┐     ┌──────────────────────────────────┐
│         Sampled League Matchmaking      │     │       Hall of Fame Pool          │
│   (16 parallel duels per batch)     │ <───│ (Historical frozen checkpoints   │
│         Timing depends on CPU/load       │     │  to prevent cyclic forgetting)   │
└──────────────────┬───────────────────┘     └──────────────────────────────────┘
                   ▼
┌──────────────────────────────────────┐
│       Fitness & Elo Scoring          │
│  Fitness = Win% + NetHP% - TimePen   │
└──────────────────┬───────────────────┘
                   ▼
┌──────────────────────────────────────┐
│  Rank Selection, Mutation & Crossover│
│   (Top 25% elite survive, Gaussian   │
│      perturbation on weights)        │
└──────────────────────────────────────┘
```

1. **Fitness Function:**
   * Win: `100 + 50 * remaining_hp / max_hp - 0.02 * match_seconds`; loss: `-100`; draw: `30 * (self_hp - enemy_hp) / max_hp`. Match duration is measured per lane.
2. **Anti-Cycling (Hall of Fame):**
   * Every 10 generations, the reigning champion is frozen and archived.
   * Historical opponents participate in sampled league matchmaking alongside active peers and optional external/bot opponents.
3. **Multi-Class Expansion Path:**
   * Current SoA buffers are Warlock-specific. A general status-effect layout and spec registration are planned for Mage, Warrior, and Rogue.

---

## 6. Actionable Roadmap & Priority TODOs

### TODO 1: Benchmark & Vectorization Regression Test ✅ [IMPLEMENTED]
* **Objective:** Ensure modifications never silently de-vectorize SIMD loops or degrade throughput.
* **Implemented:** ReleaseFast throughput floors for ticks, raw duels, and neural league play, plus compile-time checks of all SoA slice alignments and 16-lane vector types. Other optimization modes use lower smoke-test floors. Timing depends on host CPU and load; run the release suite on the benchmark host.
* **Requirements:**
  * Add a dedicated automated test suite (`zig build test -Doptimize=ReleaseFast`) asserting hard throughput floors:
    * Batch Combat Ticking: $\ge 1.0 \times 10^9$ ticks/sec.
    * Monte-Carlo Raw Duels: $\ge 1.0 \times 10^6$ duels/sec.
    * Full RL Neuroevolution Duels: $\ge 20,000$ duels/sec with neural forward passes and action masking.
  * Static compile-time checks (`@typeInfo`) ensuring all SoA arrays are 64-byte aligned and processed via `@Vector(16, f32)`.

### TODO 2: Multi-Spec League Architecture & Asymmetric Spec-vs-Spec Specialization [OPEN]
* **Objective:** Expand beyond Warlock into a full multi-spec PvP meta (Mage, Warrior, Rogue) with a two-stage specialization training curriculum.
* **Current state:** The model matrix compares Warlock policies sharing the same kit; filenames such as “destro” and “soul link” do not enable distinct spec mechanics. Multi-class registration and the two-stage training curriculum remain unimplemented.
* **Two-Stage Spec Training Pipeline:**
  1. **Phase 1: Base Class Foundation Training:**
     * Train a general foundation model per class (e.g., base Warlock, base Mage, base Warrior, base Rogue) on core kit mechanics, resource management, distance control, and generic dueling.
  2. **Phase 2: Asymmetric Spec-vs-Spec Specialization Tuning:**
     * Branch from base models into specialized spec-vs-spec matchup policies (e.g. *Affliction Warlock tuned specifically vs. Arms Warrior*, *Frost Mage tuned vs. Subtlety Rogue*).
     * The final deployed models do not use the raw base model; instead, specialized heads/policies handle distinct matchup dynamics (e.g., kiting gap-closers vs. counter-spell fake casting).
     * Provide inspection tooling to compare spec vs. spec performance, isolate weak matchup segments, and improve targeted abilities/heuristics.
* **Requirements:**
  * Unified spec registration in `MultiSpecArenaPool` (parameter tables for Frostbolt, Nova, Blink, Mortal Strike, Charge, Pummel, Shadowstep, Kick, Cheap Shot, etc.).
  * Cross-Spec Matchmaking Matrix with intra-spec and cross-spec Elo tracking.
  * Specialized matchmaking schedules pairing candidate spec agents against frozen sparring pools of opponent specs.

### TODO 3: Zero-Overhead Deployment & 2D PvP Fight Visualizer (Evaluation) ✅ [COMPLETE]
* **Objective:** Visually inspect and evaluate PvP matches in a full 2D representation without degrading headless training throughput.
* **Delivered Implementation:**
  * **Zero-Overhead Policy Export & Evaluation (`src/policy_simd.zig` & `src/main.zig`):**
    * Save/load `.bin` binary checkpoints (~3.4 KB binary memory dump).
    * CLI flag: `--eval <modelA.bin> <modelB.bin>` enables head-to-head evaluation without training overhead.
  * **Headless Training Decoupling:** Training remains 100% decoupled in pure SIMD batch loops (>47,000 duels/s with NN inference, >4.0 Billion ticks/s).
  * **Match Recorder Mode (`src/match_recorder.zig`):**
    * High-fidelity 100 Hz evaluation recorder capturing continuous coordinates, velocities, casts, interrupts, debuffs, buffs, cooldowns, diminishing returns (DRs), heals, and combat events.
    * CLI flag: `--record-match <file.lua|file.json>` directly records either champion tournaments or `--eval` matches.
  * **2D PvP Fight Player (Native LÖVE / Love2D Visualizer):**
    * Native Love2D 2D combat visualizer in `visualizer/` (`love visualizer [last_match.lua|last_match.json]`).
    * Automated launch with CLI flag `--visualize`.
    * High-performance native Lua table ingestion (`exportLua`) loading full 30s duels in < 1ms with zero parsing overhead.
    * Top-down 2D arena layout with stone paving, yard markings (-15m, 0m, +15m), and range lines (20m Fear, 30m Death Coil).
    * Smooth camera controls: mouse wheel zoom (45% - 300%), middle/right click drag pan, `+`/`-` zoom keys, and `0` reset.
    * Floating overhead unit plates: health/mana bars with exact values, dynamic cast bars with spell names & countdowns.
    * Aura & debuff badges: Agony, Corruption, Fear, Horror, and Unending Resolve shield dome.
    * Real-time cooldown indicators: Death Coil CD and Unending Resolve CD tracking.
    * Diminishing returns (DR) badges: Fear and Horror DR tiers (100% / 50% / 25% / IMMUNE) with 18.0s reset countdowns.
    * Spell animations: Death Coil green skull missile with siphon healing return, in-flight Shadow Bolt projectile with trail and impact sparks, wavy animated Drain Life life-siphon beam, Fear terror ring, Horror skull aura, and Unending Resolve shield bubble.
    * Floating Combat Text (FCT) with popups for direct hits, dots, siphon heals, interrupts, and CC alerts.
    * Full playback control: Scrubber bar, Spacebar pause/play, Left/Right arrow tick stepping (10ms), speed toggles `[1-5]` (0.25x - 4x), hot-reload `[R]`, and live combat telemetry.

### TODO 4: Training Graphs & Evolution Progress Tracking (In Love2D & CLI)
* **Objective:** Visualize training metrics, fitness convergence, action distribution shift, and spec matchup performance directly in Love2D and CLI logs.
* **Implemented:** `--metrics <file.json>` exports generation telemetry as JSON, including action counts, movement counts, and gauntlet snapshots. The Love2D graphs viewer loads both Lua and JSON metrics. Tournament statistics are captured before breeding, including correctly sorted median Elo, population standard deviation, initiating-agent W/L/D totals, mean match duration, and five duration bins. Lua and JSON export the same fields, and the graphs summary displays the new telemetry. Action and movement counts remain a champion diagnostic against an idle target, rather than full tournament counts.
* **Remaining:** Add full tournament action/movement sampling, win/loss/draw and match-time charts.
* **Target UI / telemetry scope:**
  * **Metric Logging (`src/training_logger.zig`):** Record per-generation telemetry:
    * Elo ratings (Min, Mean, Median, Max, Standard Deviation).
    * Fitness ratings (Best, Mean).
    * Generation win/loss/draw ratios & match duration distribution.
    * Action selection frequency distribution (% Agony, % Corruption, % Fear, % ShadowBolt, % DrainLife, % UnendingResolve, % DeathCoil, % CancelCast, % Advance vs Kite).
    * Gauntlet objective win rates and Elo benchmarks per interval.
    * Export format: Lua table (`training_metrics.lua`) and JSON (`training_metrics.json`) for zero-overhead Love2D visualizer loading.
  * **Love2D Training Graphs View (`visualizer/`):**
    * Multi-panel interactive telemetry viewer toggled via `[G]` key in Love2D visualizer (or launched via `--visualize-graphs`).
    * **Panel 1: Rating & Convergence Curves:** Min/Mean/Max Elo over generations with Gauntlet benchmark overlay curve.
    * **Panel 2: Strategy & Action Shift Stacked Chart / Heatmap:** Evolution of action probabilities over generations showing emergent playstyles (e.g. discovering Fear CC setup or fake-casting).
    * **Panel 3: Fitness & Win Ratio Distribution:** Generational win/loss/draw bars and match time trends.
    * Interactive generation scrubber with tooltips showing generation stats on hover.

### TODO 5: Resuming Training & External Model Sparring (Benchmarking) ✅ [COMPLETE]
* **Objective:** Support resuming long-running training runs across sessions, training against external pre-trained opponent models, and objective benchmarking via baseline bot gauntlet.
* **Delivered Implementation:**
  * **Full Population & League State Checkpointing (`src/league.zig`):**
    * Binary checkpoint format (`.pop`) preserving generation counter, total duels, full population genome array, Hall of Fame pool, and sparring partner genomes.
    * CLI flag: `--save-population <path.pop>` exports complete league state at the end of training.
    * CLI flag: `--checkpoint-interval <N>` automatically snapshots `checkpoint_gen_<N>.pop` every $N$ generations.
    * CLI flag: `--resume <path.pop>` seamlessly restores evolutionary state, continuing training across sessions without losing generational history.
    * CLI flag: `--seed-from <champ.bin>` seeds an entire new population initialized around an existing pre-trained champion with Gaussian diversity perturbations ($\sigma_{\text{init}} = 0.05$).
  * **External Sparring Partners & Pool Ingestion (`src/league.zig` & `src/main.zig`):**
    * CLI flag: `--sparring-opponent <path.bin>` ingests a single pre-trained model into the training schedule as a fixed sparring partner.
    * CLI flag: `--sparring-pool <dir>` bulk-ingests an entire directory of `.bin` models into the matchmaking schedule.
    * Evolving agents are dynamically matched against external sparring partners (25% sparring rate), preventing local league groupthink and meta overfitting.
  * **Objective Benchmark Gauntlet (`src/gauntlet.zig`):**
    * A frozen suite of 4 distinct rule-based PvP bot archetypes:
      1. **🗡️ Aggro Rusher Bot:** Constant gap-closer (-1.0 m/s), aggressive instant DOT spammer, defensive shield on low HP, opportunistic Drain Life execution.
      2. **🏃 Fear-Kite Specialist:** Range manager maintaining 18-22m sweet spot, prioritizes Fear CC on cooldown, interrupts enemy casts, punishes feared targets with heavy Shadow Bolts and Drain Life.
      3. **🏰 Turret Caster Bot:** Immovable turret (0.0 m/s), maintains 100% DOT uptime, fires high-DPS Shadow Bolt artillery, casts Fear at close range (<10m).
      4. **🛡️ Drain-Tank Turtle:** Early defensive mitigation, continuous life siphon sustain via Drain Life, space control against aggressive rushers.
    * **Objective Scorecard & Estimated Elo:** Computes win rates, records (W/L/D), average duration, and average remaining HP across all archetypes to calculate an absolute, objective skill rating.
    * CLI flag: `--gauntlet` runs the 4-bot gauntlet benchmark against the tournament champion at the end of training.
    * CLI flag: `--gauntlet-interval <N>` evaluates the reigning champion against the gauntlet during training runs to track objective skill growth over generations.
    * CLI flag: `--eval-gauntlet <model.bin>` evaluates an existing model directly against the gauntlet suite and outputs a formatted ASCII diagnostic scorecard.
    * CLI flag: `--eval-bot <model.bin> <aggro|kiter|turret|draintank>` benchmarks a model against a specific bot with optional 100 Hz match recording and 2D Love2D visualizer playback (`--visualize`).
