# Neuroevolution Policy Engine & Alternating Self-Play (TODO)

## Overview & Goal
Replace or complement hand-coded heuristic MCTS rollouts with an optimal, learned combat policy evolved via high-throughput alternating self-play (Fictitious Play / PSRO). 

Given the simulator's throughput (~40,000 fights/sec on 8 threads, ~4.1B ticks/sec), an epoch of 100,000 matches completes in ~2.5 seconds. The engine alternates between:
1. Freezing **Spec B**, evolving a population of **Spec A** policies to counter it.
2. Freezing **Spec A**, evolving a population of **Spec B** policies to counter it.
3. Repeating while tracking response improvements against each side's archive mixture. This is a practical stability signal, not a formal Nash-equilibrium test.

A **Hall of Fame** (mixture of past frozen champions) is maintained for both sides during evaluation to prevent cyclical rock-paper-scissors amnesia (e.g. nuke -> bait -> turtle -> nuke).

---

## 1. Compact SIMD Neural Policy Network (`src/neuro_policy.zig`)
- [x] **Architecture Design**:
  - Keep weights compact (~1,500 – 3,000 parameters) to optimize evolutionary efficiency (`ParamCount = 1,588`: 36 inputs $\to$ 24 ReLU hidden units $\to$ 28 outputs).
  - Learned ability and movement logits refine finite tactical priors for every class, providing a useful starting policy while remaining overridable.
  - Use Zig `@Vector(16, f32)` SIMD operations for 16-lane simultaneous batch forward passes (`Policy.forward16`).
- [x] **Combat State Feature Extraction**:
  - Distance between fighters, relative positions.
  - Self & Enemy: HP percentage, Mana percentage (normalized against actual `max_health` and `max_mana`).
  - Active cast ID and remaining cast time / enemy cast state (for interrupt/juke timing).
  - Cooldown timers for key defensive/offensive abilities.
  - CC states and diminishing returns (Stun, Fear, Silence, Lockout, Horror).
  - Active auras and DoT timers (Agony, Corruption, Immolate, Siphon Life, Shields).
  - Projectiles currently in flight and active pet HP ratio.
- [x] **Action Selection & Legal Masking**:
  - Apply legal ability mask (cooldowns, out of range, out of mana, silence/lockout).
  - Legal cast cancellation, early DoT refreshes, idling, stance changes and movement remain available regardless of tactical context. Casting and crowd control still enforce physical movement restrictions.
  - Temperature-based exploration noise during training; strict argmax during champion replay generation (`selectActions16`, `selectActionSingle`).

---

## 2. Evolutionary Population & Training Operators (`src/neuro_evolution.zig`)
- [x] **Population Data Structures**:
  - `Population`: Array of candidate parameter vectors ($N \approx 64 - 128$ individuals).
  - Elite preservation (top $K$ elite policies copied forward unmutated).
- [x] **Mutation, Crossover & Antithetic Sampling**:
  - Antithetic mirrored pairs ($\pm \epsilon$ around the elite champion) for variance-reduced directional gradient steps.
  - 3-way tournament selection + uniform crossover + sparse Gaussian weight perturbation (20–25% of weights mutated per offspring, avoiding 1,500-D random-walk dilution).
- [x] **Fitness Function**:
  - Win (+1.0) / Loss (-1.0) / Draw (0.0).
  - Secondary margin-of-victory signal (normalized net HP, Mana, and speed-of-victory bonus) to break ties and reward decisive kills.
- [x] **Hall of Fame & Anti-Cycling**:
  - Maintain an archive of frozen champions from previous epochs (`HallOfFame`).
  - Fitness evaluation samples uniformly from a rolling archive of distinct frozen opponents for the other side.
  - Final saved policies are selected by average fitness against the opposing archive, so the last side to evolve does not automatically supply the displayed champion.

---

## 3. High-Throughput Alternating Training Runner (`src/neuro_arena.zig`)
- [x] Build a dedicated training binary `neuro_arena` (added to `build.zig`).
- [x] Multi-generation epochs: Runs multiple rapid generations per epoch (2 SIMD batches = 32 fights per individual per generation, yielding ~25–50 generations per 50k–100k fight epoch) so selection and mutation compound rapidly.
- [x] CLI flags:
  - `--spec-a <spec>`, `--spec-b <spec>` (plus all spec/gear/talent/position flags shared with `mcts_fight`)
  - `--fights-per-epoch <N>` (default: 100,000)
  - `--epochs <N>` (default: 10)
  - `--population-size <N>` (default: 128)
  - `--workers <N>` (default: auto-detected cores)
  - `--convergence-threshold <float>` (stop early when a new champion's average archive score improves by less than the threshold on consecutive side updates)
  - `--output-replay <path>` (writes trajectory `.lua` and `.json` of converged champion vs champion fight)
  - `--output-weights <path>` (saves binary `.nepl` model weights and `.json` summary telemetry)
- [x] Real-time stdout telemetry: `NEURO_EPOCH` and `NEURO_CONVERGED` lines with epoch number, total generations (`gens`), active evolving side, average fight duration, win rates, ticks/sec, and throughput.
- [x] `mcts_fight` integration: `--policy-a` and `--policy-b` flags allow driving either or both fighters with evolved `.nepl` policies.

---

## 4. Visualizer Integration (`visualizer/`)
- [x] **Settings Panel League Play Section**:
  - Added collapsible `League Play (Neuroevolution)` section in `visualizer/workspace.lua` below MCTS settings.
  - Displays dropdowns for:
    - Fights per epoch (`10k`, `50k`, `100k`, `250k`)
    - Max Epochs (`4`, `6`, `10`, `20`)
    - Population size (`32`, `64`, `128`)
    - Live convergence status & progress bar
- [x] **Evolve & Fight Action Button**:
  - Added **`Evolve & Fight`** button in the League Play section.
  - Asynchronously launches `neuro_arena` in a background thread (`match_generator.startLeaguePlay`) and streams live `NEURO_EPOCH` progress updates.
  - Upon completion/convergence, automatically loads and launches playback of the champion vs champion fight in the Arena viewport.
- [x] **Policy Inspector / Telemetry**:
  - Displays policy generation stats (epoch progress, win rate, throughput in fights/s).
  - Added **`Champ A vs MCTS B`** and **`MCTS A vs Champ B`** buttons after evolution completes to pit the evolved champion policies directly against the MCTS engine.

## Graph and evaluation semantics (2026-10-22)

The graph works for all supported classes, including Warrior. **Train A** is
Fighter A's score against the sampled opponent archive (complemented when B is
training); **Pair A** is the current champions' score over 112 fights. Both count
wins as one and draws as one half. The archive and current champions are different
opponents, so these curves can disagree and alternate sharply between epochs.
The final graph point reports the archive-selected saved pair without inventing
a new training sample. Hover the graph for this explanation.

Champion pair and batch evaluation use strict argmax, the configured opening and
position jitter, and a common seed schedule. Training retains 0.05 action noise.
For the same seed, presets, saved policies, duration, jitter and 112 fights, final
Pair A and batch A score should agree. Other sample sizes or seeds can differ.

Validation: ReleaseFast build and Lua graph syntax/telemetry checks passed,
including zero values, pair-only updates and final selection. Two short Warrior
training runs (Warrior on A and B; one and two workers; zero and nonzero jitter)
saved/reloaded champions and reproduced the final Pair A score exactly in
112-fight batch evaluation: 0.41964285714285715 and 0.7276785714285714.
Artifacts were written under `/tmp/warrior-graph`, leaving saved user champions
untouched. These short 15-second fixtures validate telemetry agreement, not
class balance or training convergence.

### Restored neural baseline guidance

League training plays candidate neural policies against archived neural champions;
it does not call scripted MCTS rollouts. Neural policies again add tactical and
positioning priors to learned logits, including Warrior rage, stance, gap closer,
Hamstring and Fury special guidance. These are runtime residual scores, not saved
initial weights. Former tactical exclusions are finite penalties (-2.5), so every
simulator-legal action remains available for evolution to discover.

Champion playback and explicitly configured neural MCTS rollouts use the same
selector. Ordinary MCTS is unchanged. Existing NEPL weights remain compatible;
resume training with the restored guidance. Fitness still includes health/resource
margin and time shaping. Training quality has not been benchmarked for this change.
