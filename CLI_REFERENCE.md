# ⚔️ PVP_SIM Quick Reference & CLI Cheat Sheet

## 1. Quick Cheat Sheet

### 🏋️ Training & Evolutionary League
```bash
# Basic training run (10 generations, 64 agents, save champion)
./zig-out/bin/pvp_sim --generations 10 --pop 64 --duels 4 --save-champion champ.bin

# Training with auto-checkpoints every 5 generations & final population export
./zig-out/bin/pvp_sim --generations 20 --pop 64 --checkpoint-interval 5 --save-population pop_gen20.pop

# Train with active Gauntlet Sparring (forces population to counter all 4 archetypes)
./zig-out/bin/pvp_sim --generations 50 --pop 64 --spar-gauntlet --save-champion champ.bin --gauntlet

# Resume training from a saved population checkpoint
./zig-out/bin/pvp_sim --resume pop_gen20.pop --generations 10 --save-population pop_gen30.pop

# Seed a new population around an existing champion with Gaussian noise
./zig-out/bin/pvp_sim --seed-from champ.bin --generations 15 --save-champion champ_v2.bin
```

---

### 🤺 Sparring with External Models
```bash
# Spar against a specific pre-trained opponent during training
./zig-out/bin/pvp_sim --generations 20 --sparring-opponent champ.bin --save-champion new_champ.bin

# Spar against an entire directory of pre-trained .bin models
./zig-out/bin/pvp_sim --generations 20 --sparring-pool ./checkpoints/
```

---

### 🎯 Objective Gauntlet Benchmarks (4 Bot Archetypes)
```bash
# Run 4-bot Gauntlet scorecard against an existing model
./zig-out/bin/pvp_sim --eval-gauntlet champ.bin

# Run Gauntlet checks periodically during training & at conclusion
./zig-out/bin/pvp_sim --generations 25 --gauntlet-interval 5 --gauntlet

# Spar against a single specific bot (aggro | kiter | turret | draintank)
./zig-out/bin/pvp_sim --eval-bot champ.bin kiter
```

---

### 🎮 Head-to-Head & 2D Visualizer Playback
```bash
# Head-to-head evaluation between two models (terminal replay)
./zig-out/bin/pvp_sim --eval champ_v1.bin champ_v2.bin

# Record match to Lua and launch native Love2D 2D visualizer
./zig-out/bin/pvp_sim --eval champ_v1.bin champ_v2.bin --visualize

# Record match against a Gauntlet bot and open visualizer
./zig-out/bin/pvp_sim --eval-bot champ.bin kiter --visualize

# Export match trajectory to Lua or JSON
./zig-out/bin/pvp_sim --eval champ_v1.bin champ_v2.bin --record-match match.lua
```

### 📊 Spec vs Spec Matrix & Batch Match Recording
```bash
# Evaluate round-robin matrix across all trained models in models/
./zig-out/bin/pvp_sim --eval-matrix models/ --matrix-duels 32 --matrix-out spec_matrix.lua

# Batch simulate matrix and auto-record representative 100Hz fights for all matchups
./zig-out/bin/pvp_sim --eval-matrix models/ --matrix-duels 32 --record-all-matches matches/

# Or run the automated script directly
./record_all_matches.sh
```

---

### 🎮 Unified Love2D Monitor with Multi-Tab Navigation
```bash
# Open main visualizer dashboard (defaults to 2D Arena)
love visualizer

# Direct launch into specific tabs
love visualizer --graphs training_metrics.lua   # Training Progress Tab
love visualizer --matrix spec_matrix.lua        # Spec vs Spec Matrix Tab
love visualizer --fights                        # Stored Matches Browser Tab
love visualizer --training                      # Training Controls Tab
```

**Tab Navigation Shortcuts inside Love2D:**
- **`[F1]`**: ⚔️ **Arena Fight Replay** (Playback, Scrubber, Camera Zoom/Pan, Spell VFX, Floating Combat Text)
- **`[F2]`** or **`[G]`**: 📈 **Training Progress** (Elo Dynamics, Action Shift Distribution, Fitness Curves, Gen Scrubber)
- **`[F3]`**: 📂 **Stored Matches Browser** (Browse all fights in `matches/`, press Enter to load into Arena)
- **`[F4]`** or **`[M]`**: 📊 **Spec vs Spec Matrix** (Asymmetric Win % Grid, Deep-Dive Card, press Space/Enter to replay matchup)
- **`[F5]`**: **Training Controls** (Start/Resume, settings, Stop & Save, live status and logs)
- **`[TAB]`**: Cycle through all 5 views (cycles fields while editing training settings)
- **Click tabs**: Click any tab button in the top navigation bar at any time

---

### Training from the app

Build once with `zig build -Doptimize=ReleaseFast`, then run `love visualizer --training`.
Set generations, population, duel batches, and checkpoint interval; optionally provide a
population to resume, a champion to seed, or external sparring paths. Paths are relative
to the project root, or absolute. Each duel batch contains 16 SIMD duels. Resume uses
the checkpoint's population size and runs the requested number of additional generations.
A new run starts from scratch when both resume and seed fields are empty.

Click **Start / Resume**. Each run gets a separate `training_runs/` subfolder containing
`metrics.json`, `trainer.log`, `champion.bin`, `population.pop`, and periodic checkpoints.
**F2** shows live graphs; scrubbing earlier generations preserves your selection during
refreshes. Staying on the newest generation follows incoming data. **Stop & Save**
finishes the current generation and saves the champion and population. Closing the app
requests the same graceful stop and waits for training to finish saving. A successful run
fills the resume field with its saved population automatically.

The controls currently support Linux/macOS desktop shells. Training runs in a separate
native process, launched by a LÖVE worker thread. Set **CPU training threads** or pass
`--threads N` to distribute 16-wide SIMD duel batches across persistent CPU workers.
The default is 1, which runs directly without worker scheduling overhead. Workers have
private aligned arenas; results are applied in the original order before metrics,
breeding, checkpoints, or graceful stop/save. Fixed-seed results match across thread counts.
Use 4–8 workers to leave CPU capacity for the desktop; larger counts have diminishing returns.
See [multithreading benchmarks](MULTITHREADING.md) for measured performance and memory costs.

For headless use, `--train-only` skips the two throughput benchmarks, `--live-metrics`
publishes atomic snapshots at generation boundaries at most once every 250 ms plus a
final snapshot, and `--stop-file <path>` stops when that file exists before the next
generation. Supply `--save-champion` and `--save-population` to save on graceful stop;
the stop file is left in place, so remove it or choose a new path before another CLI run.

Run the headless LÖVE integration check from the project root with
`love visualizer/training_test`. It creates isolated runs in `training_runs/` and verifies
live updates, stop/save, resume, immediate stopping, and trainer failures.

## 2. CLI Options Overview

| Flag | Parameter | Description |
|---|---|---|
| `--train-only` | *(none)* | Skip throughput benchmarks before training |
| `--live-metrics` | *(none)* | Publish atomic telemetry snapshots during training |
| `--stop-file` | `<path>` | Stop between generations when this file exists; final exports still run |
| `--generations` | `<N>` | Number of evolution generations to run (default: 10) |
| `--pop` | `<N>` | Population size in genomes (default: 64) |
| `--duels` | `<N>` | Duels per agent per generation (default: 4) |
| `--save-champion` | `<path.bin>` | Export best neural genome to binary file (~3.4 KB) |
| `--save-population` | `<path.pop>` | Export full league state & population checkpoint |
| `--resume` | `<path.pop>` | Resume evolutionary training from `.pop` checkpoint |
| `--seed-from` | `<path.bin>` | Initialize population perturbed around champion ($\sigma=0.05$) |
| `--checkpoint-interval` | `<N>` | Auto-save `checkpoint_gen_<N>.pop` every N generations |
| `--sparring-opponent` | `<path.bin>` | Add single external model to training matchmaking pool |
| `--sparring-pool` | `<dir>` | Ingest all `.bin` models from directory into matchmaking |
| `--gauntlet` | *(none)* | Run 4-bot objective benchmark scorecard after training |
| `--gauntlet-interval` | `<N>` | Evaluate champion against gauntlet every N generations |
| `--eval-gauntlet` | `<path.bin>` | Immediate gauntlet evaluation of a saved model |
| `--eval-bot` | `<path.bin> <bot>` | Evaluate model vs bot (`aggro`, `kiter`, `turret`, `draintank`) |
| `--eval-matrix` | `<dir>` | Discover and run full round-robin cross-spec matrix across all `.bin` models |
| `--matrix-out` | `<path.lua>` | Destination file for spec matrix table (default: `spec_matrix.lua`) |
| `--matrix-duels` | `<N>` | Number of duels per pairwise matrix matchup (default: 32) |
| `--spec-status` | `[dir]` | Inspect health of all canonical talent specs, trained bases, and pairwise models (default: `models`) |
| `--spec-status-out` | `<path.lua>` | Export spec & pairwise health status report as Lua table for visualizer |
| `--record-all-matches` | `<dir>` | Auto-record representative 100Hz fight trajectories to directory |
| `--metrics` | `<file.lua\|file.json>` | Export training telemetry as Lua or JSON; both load in the graphs viewer (default: `training_metrics.lua`) |
| `--no-metrics` | *(none)* | Disable metrics recording |
| `--visualize-graphs` | *(none)* | Launch Love2D directly in training graph & progress view |
| `--eval` | `<A.bin> <B.bin>` | Head-to-head evaluation of two trained models |
| `--render-best` | *(none)* | Print ASCII play-by-play between champion & runner-up |
| `--record-match` | `<path>` | Save trajectory (`.lua` or `.json`) |
| `--visualize` | *(none)* | Launch native Love2D 2D Arena visualizer |

---

## 3. Bot Archetypes in the Gauntlet

| Bot Icon & Name | Key Strategy | Weakness |
|---|---|---|
| **🗡️ Aggro Rusher** | Closes distance aggressively (`-1.0 m/s`), spams instant DoTs, executes with Drain Life. | Vulnerable to kite & hard CC. |
| **🏃 Fear-Kite Specialist** | Maintains 18–22m range, spams Fear CC, punishes with Shadow Bolt & Drain Life. | Pressured by high close-range burst. |
| **🏰 Turret Caster** | Stationary turret (`0.0 m/s`), 100% DoT uptime, heavy direct Shadow Bolt artillery. | Lacks mobility; vulnerable to range-stepping. |
| **🛡️ Drain-Tank Turtle** | Pops Unending Resolve shield early, relentless continuous Drain Life self-sustain. | Low burst damage output. |

## Frost Mage and cross-class sparring

Use `--class frost_mage` for training, resume, seeding, and bot evaluation. The
default is `warlock`. `--opponent-class warlock` selects the kit of external
sparring models while peers and historical champions remain Mages. Model
evaluation (`--eval`) and matrices infer classes from model headers. Legacy
raw models remain Warlocks. See [Frost Mage commands and mechanics](FROST_MAGE.md).
