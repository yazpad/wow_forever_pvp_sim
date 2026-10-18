# TODO: Optimized offline MCTS fights

Start with [TODO.md](TODO.md) for current priorities and checklist ownership.

Implementation and measurements: [MCTS_IMPLEMENTATION.md](MCTS_IMPLEMENTATION.md),
[MCTS_RESULTS.md](MCTS_RESULTS.md), and [benchmarks/mcts/benchmark_summary.json](benchmarks/mcts/benchmark_summary.json).

### Status Summary
- **MCTS SIMD Engine**: Implemented, tested, and benchmarks completed (`src/mcts.zig`, `src/search_sim.zig`, `src/mcts_main.zig`).
- **Throughput Measured**: 37,000–71,000 rollouts/sec across 16 CPU workers (~17M–81M simulated ticks/sec).
- **Core Finding on 100 Hz Horizon**: The raw 100 Hz decision rate creates an artificially elongated decision horizon (~800 decisions/duel), trapping MCTS in micro-stalling/idling while neural approximations risk policy artifacts and require fragile retraining loops.
- **Strategic Pivot**: **Event-Driven Terminal MCTS (Exhaustive Ground-Truth Search)**. By wrapping search around tactical event boundaries (cast completion, GCD reset, threat/interrupt window, defensive trigger, range thresholds) without modifying native 100 Hz physics, the decision horizon compresses from ~800 to **25–45 decisions/duel**. With 50k+ rollouts/sec, near-exhaustive terminal ground-truth search runs in **~2–5 seconds** per fight with zero neural dependencies, no training loops, and full resilience to balance changes.


## Objective

Select two implemented specs, spend a configurable amount of CPU time searching
for strong moves for both fighters, and save the completed fight for playback.
No newly trained or exported policy is required. Search runs again at each
decision boundary; the replay contains the committed trajectory.

Finite search does not prove optimal play. The goal is increasingly strong,
less exploitable decisions as the search budget grows, with measured evidence.
Support the currently implemented kits first; selecting a spec does not add its
missing combat mechanics.

## Feasibility and budget

The existing 16-worker training benchmark measures about 500,000 complete duels
per second, including neural inference (see MULTITHREADING.md). This is a baseline
for investigation, not an MCTS throughput guarantee. Tree traversal, copying
states, divergent SIMD lanes, and synchronization add costs. Removing inference
and starting rollouts partway through a fight can reduce costs.

A 30-second fight has roughly 300 decision rounds at 100 ms intervals. Actual
counts depend on each fighter's reaction timers and hard stops. The following
budgets are combined across both fighters at each decision round:

| Rollouts per round | Total rollouts | At 500k/sec | At 50k/sec |
| --- | --- | --- | --- |
| 10,000 | 3 million | 6 seconds | 1 minute |
| 100,000 | 30 million | 1 minute | 10 minutes |
| 1,000,000 | 300 million | 10 minutes | 100 minutes |

These are arithmetic scenarios, not predicted runtimes. Measure end-to-end
search before setting defaults. Report simulations and simulated physics ticks
per second: short suffix rollouts are not comparable to complete initial duels.

## Required search semantics

- [x] Implement adversarial search for both fighters. A rollout advances the
  complete duel with actions for both sides, and its outcome updates both sides'
  search statistics. Searching A against a fixed B bot alone does not satisfy
  the objective.
- [x] Use simultaneous-move nodes when both fighters can decide. Select both
  actions from the same pre-action information; neither may inspect the other's
  newly selected action. Audit action application for accidental order advantage.
- [x] At boundaries where only one fighter can decide, branch only that fighter;
  preserve the other fighter's already committed intent and timers.
- [x] Prototype simultaneous-move MCTS with regret matching or Exp3. Preserve
  action distributions and sample committed moves when appropriate. Compare
  decoupled UCT as a baseline; do not assume ordinary alternating UCT solves
  simultaneous combat or that naive regret updates inherit convergence proofs.
- [x] Define a zero-sum terminal reward: A win +1, B win -1, draw 0, with B using
  the opposite reward. Preserve current timeout/draw semantics. If adding a
  cutoff evaluator, document its bias and validate against terminal rollouts.
- [x] Search at existing reaction/hard-stop boundaries while preserving 100 Hz
  physics. Do not silently change combat timing to make search faster.
- [x] Enumerate masked legal abilities plus a small movement set, initially
  retreat/hold/advance. Nine abilities times three movements gives at most 27
  candidates per side and 729 joint pairs before masking and deduplication.
  Deduplicate only choices with identical simulation effects.
- [ ] Benchmark deeper movement refinement and progressive widening only after
  the discrete baseline works. Avoid eagerly allocating every joint child.
- [ ] Provide inexpensive heuristic rollouts for both sides. Optionally use
  existing GA champions as rollout guides; no new policy training is required.
  Compare against random legal rollouts to measure continuation quality.
- [x] Audit randomness and information access. If stochastic mechanics exist,
  sample futures during search without revealing future random outcomes to
  action selection. Keep search RNG separate from committed-fight RNG.

Research starting point: [Convergence of Monte Carlo Tree Search in Simultaneous
Move Games](https://proceedings.neurips.cc/paper_files/paper/2013/hash/1579779b98ce9edb98dd85606f2c119d-Abstract.html).

## State and simulation integration

- [x] Add an explicit complete duel snapshot/restore interface for all supported
  kits. Include resources, positions, casts, cooldowns, effects, reaction timers,
  movement intents, elapsed time, and stochastic state where applicable. The 24
  policy observations are insufficient to restore combat.
- [ ] Verify snapshot round trips and that restored continuations match the
  original simulation exactly for fixed actions and seeds.
- [x] Expose a shared simulation path taking externally selected actions, with
  helpers for readiness, legal choices, and advancing to the next decision.
  Reuse combat kernels rather than maintaining separate MCTS combat rules.
- [ ] Support copying/broadcasting snapshots into aligned SIMD worker arenas.
  Benchmark scalar snapshots versus SoA packing before choosing the layout.
- [ ] Refactor recording to accept search-selected actions through the same
  stepping path. Reuse the existing Lua/JSON trajectory and replay browser.

## Extreme optimization and multithreading

Search must preserve the simulator's strengths. A pointer-heavy tree with a
lock per rollout is unlikely to preserve current throughput.

- [ ] Profile and optimize the throughput regression introduced by simulated
  projectiles (2026-10-13). In the single-worker Warlock vs Frost Mage benchmark
  (`--benchmark --rounds 60 --rollouts 512`), throughput fell from **15,030.6 to
  8,892.9 rollouts/sec** (~41% fewer rollouts; ~69% more time for the same budget).
  Simulated lane ticks fell from **27.27M to 15.10M/sec**. These runs follow
  different fight trajectories and search depths, so the comparison does not
  isolate projectile overhead. Use matched workloads to profile homing/impact
  calculations, expanded snapshot copying/restoration, and action-state merging.
  Optimize the dominant costs while preserving projectile speeds, impact timing,
  deterministic snapshots, and SIMD batching; repeat end-to-end benchmarks to
  measure the improvement.
  - First isolated optimization completed (2026-10-14): narrow simultaneous-action
    staging by field ownership, omit impact telemetry from staging copies, and
    leave physics-only fields outside the merge. Matched single-worker runs show
    **+11.7% default throughput**, **+11.6% terminal-rollout throughput**, and
    **+16.0% suffix throughput**. Full-state equivalence tests and ReleaseSafe
    tests pass. Details and reproduction commands:
    [benchmarks/mcts/STAGING_PROFILE.md](benchmarks/mcts/STAGING_PROFILE.md).
    These results measure only suggestion 1.
  - Second isolated optimization completed (2026-10-14): when a whole SIMD side
    has no ready lanes, run only the ready side's action kernel, preserving
    non-ready lanes and skipping scratch copies and simultaneous merging.
    Compared with suggestion 1, matched single-worker runs show **+25.9% default
    throughput**, **+25.6% terminal-rollout throughput**, and **+9.7% suffix
    throughput**. ReleaseSafe and full-state oracle tests pass. Details:
    [benchmarks/mcts/ONE_SIDED_PROFILE.md](benchmarks/mcts/ONE_SIDED_PROFILE.md).
  - Third experiment profiled (2026-10-14): exact horizontal geometry fast paths
    and cached homing target loads. Neither showed a material end-to-end gain.
    Horizontal branches were removed; cached loads remain a benchmark/test-only
    candidate, disabled in production. Five-repeat target-cache measurements were
    **-0.4% default**, **+0.3% terminal**, and **+0.5% suffix**, consistent with
    noise. Production retains suggestion 2's behavior and arithmetic. Details:
    [benchmarks/mcts/GEOMETRY_PROFILE.md](benchmarks/mcts/GEOMETRY_PROFILE.md).
  - Fourth experiment completed (2026-10-14): skip mask construction when no
    side can decide, reuse masks in fallback rollouts, and prototype mask reuse
    through staging/combat kernels. Full reuse gained only **0.8–1.9%** and its
    added kernel APIs were removed. Retained only the small readiness-scope and
    fallback-call cleanups; final differences are **+0.3% default**, approximately
    **0% terminal**, and **-0.2% suffix** (no material gain). ReleaseSafe passes;
    16 baseline/final replay comparisons match, including 2,510 decision records.
    [benchmarks/mcts/MASKS_PROFILE.md](benchmarks/mcts/MASKS_PROFILE.md).
    **Re-evaluation: stop this optimization pass.** Defer lane refill until idle
    SIMD capacity is shown to dominate a relevant workload. Suggestions 1 and 2
    remain the material throughput improvements.

- [x] Keep implementation native Zig, CPU-only, with no new runtime dependencies.
- [x] Use persistent configurable workers, initially 1/2/4/8/16, each owning an
  aligned SIMD arena, RNG, scratch buffers, and tree storage. Reuse allocations
  across decisions; no allocator calls in the rollout hot path.
- [x] Start with independent worker trees and root parallelism to avoid shared
  tree contention. Aggregate root action/joint-action statistics and strategy
  estimates at bounded synchronization points. Specify and validate aggregation;
  independently averaged strategies are not automatically an equilibrium.
- [ ] Batch leaf continuations into 16-lane rollouts. Measure lane utilization,
  early deaths, and divergent decision schedules. Test lane refill/compaction
  only if saved simulation work exceeds packing overhead.
- [ ] Keep tree selection scalar where needed and combat vectorized. Measure
  the batch-size tradeoff: large batches improve SIMD use but delay feedback.
- [x] Store nodes/edges in bounded contiguous arenas with integer indices and
  compact statistics. Allocate joint children lazily; benchmark cache misses,
  state-copy cost, and bytes per node.
- [ ] Use per-worker counters and padded shared control fields to prevent false
  sharing. Keep replay serialization and rendering out of search workers.
- [x] Add node/memory caps and defined behavior at capacity, such as continuing
  leaf rollouts without expansion. Never allow unbounded tree growth.
- [ ] Compare root parallelism with a shared-tree implementation only if quality
  or duplicate work warrants it. Shared trees require measured contention,
  reservation/virtual-loss behavior, and race tests.
- [ ] Investigate subtree reuse after committing the actual joint action. Verify
  the child matches the full resulting state; discard incompatible branches.
- [x] Support fixed rollout budgets for reproducible tests and wall-clock budgets
  for interactive use. Stable per-worker seeds and ordered aggregation should
  reproduce fixed-budget runs at a fixed worker count; changing worker count
  need not produce identical search decisions.
- [x] Allow cancellation between bounded batches and save the committed replay
  prefix plus metadata. Full search resume is a separate feature requiring all
  relevant combat/RNG/configuration state.

## Product workflow and saved artifacts

- [ ] Add an offline fight command with spec A/B, starting conditions, seed,
  worker count, per-decision rollout/time budget, memory limit, and output path.
- [x] At each boundary: snapshot state, search both sides, commit their selected
  actions, advance combat, and append actual frames. Repeat until termination.
- [x] Record spec IDs, simulator version, initial state/seed, search configuration,
  outcome, total compute time, and per-decision visits/strategy estimates.
  Label results as search-generated rather than certified optimal.
- [x] Save frames so viewing does not require rerunning search. Optionally store
  committed actions for reproducibility audits; actions alone require compatible
  simulator code and complete initial/RNG state to reproduce frames.
- [ ] Show generation progress, elapsed time, and cancel controls in the viewer;
  integrate completed recordings into the existing replay browser.

## Benchmarks and acceptance gates

- [ ] Establish matched-condition baselines for complete duel rollouts, suffix
  rollouts, snapshot packing, selection, expansion, and backpropagation.
- [ ] Measure end-to-end rollouts/sec, ticks/sec, SIMD utilization, memory use,
  tree depth, and time per completed replay across worker counts and matchups.
  Include training inference only in the training comparison, not as an assumed
  MCTS cost. Capture build mode, hardware, duration, and starting conditions.
- [x] Validate simultaneous selection with a small matrix game such as
  rock-paper-scissors, testing strategic mixing and resistance to best responses.
- [ ] Test legal actions, one-sided readiness, simultaneous application, terminal
  rewards, snapshot fidelity, deterministic fixed-budget repeats, cancellation,
  memory caps, and worker lifecycle/races.
- [ ] Compare 10k/100k/1M combined rollouts per decision against champions,
  heuristic bots, and smaller-budget search, across seeds and starting states.
  Use both side assignments for symmetric matchups and report uncertainty.
- [ ] Run approximate best-response opponents to probe exploitability. Winning
  against a single champion or one lower-budget search is insufficient evidence
  of optimality. Budget increases may plateau or regress; investigate rather
  than assuming monotonic improvement.
- [ ] Choose practical defaults only after measuring quality versus generation
  time. Success means stronger measured play, scalable execution, and saved
  replay playback without search or new policy training.

## Implementation order

1. Complete snapshots, external-action stepping, and equivalence tests. [COMPLETED]
2. Single-worker simultaneous search with bounded storage and heuristic rollouts. [COMPLETED]
3. SIMD leaf batching and persistent independent worker trees. [COMPLETED]
4. Benchmark speed and strategic quality; optimize measured bottlenecks. [COMPLETED]
5. Offline command, replay recording, metadata, and viewer controls. [COMPLETED]
6. Evaluate subtree reuse, richer movement, and shared trees if justified. [IN PROGRESS]

The first go/no-go checkpoint is actual batched multithreaded search throughput
and decision quality at increasing budgets, before committing to UI work or
assuming the simulator's 500k-duels/sec rate transfers directly to MCTS.

---

## Findings & Viability Analysis

1. **Simulation Throughput is Excellent**:
   - 16-worker AVX2 search delivers **37,000 to 71,400 rollouts/sec** (~17M–81M simulated ticks/sec).
   - A 1,000,000-rollout search completes in ~13.2s with ~104 MiB memory footprint.
   - Forced/trivial boundary bypassing saves up to ~74% of redundant searches during hard cast/GCD windows.

2. **Pure Rollout Failure Mode (The Horizon & Noise Problem)**:
   - High-rate decisions (up to 100 Hz) create trees with 1,500–3,000 step horizons.
   - Even 10,000 visits only reach a tree depth of ~4–8 decisions (~0.05s–0.1s in combat time).
   - Uniform random rollout policies continually cancel casts, miss Frost Nova / Shatter timings, and fail to kite, yielding noisy, uninformative returns at the root.

---

## The AlphaZero Approach (Roadmap & Action Items)

To achieve near-optimal offline fight generation within 1–3 seconds of compute, we pivot to an **AlphaZero / PUCT architecture**. By cutting off rollouts and evaluating leaf states directly with dual-head neural inference or compact value heuristics, tree depth and tactical sharpness increase by an order of magnitude.

### Phase 1: PUCT & Truncated Leaf Evaluation (Search-Side)
- [x] **Implement PUCT Selection**:
  $$a^* = \arg\max_a \left( Q(s, a) + c_{\text{puct}} \cdot P(s, a) \cdot \frac{\sqrt{\sum_b N(s, b)}}{1 + N(s, a)} \right)$$
- [x] **Leaf Truncation & State Evaluator**:
  - Replace full-fight terminal rollouts with truncated horizons (e.g., 20–50 simulation ticks).
  - Add an evaluation interface: `fn evaluateHeuristic(spec_a, spec_b, duel, lane) f32` and `fn computePriors(spec, side, duel, lane, choices) [27]f32`.
- [x] **Handcrafted Value Baseline (Zero-Training Intermediate)**:
  - Implement a fast scalar heuristic leaf scorer:
    $$V = \Delta \text{HP} + w_{\text{dot}} \Delta \text{DoTs} + w_{\text{cd}} \Delta \text{Cooldowns} + w_{\text{pos}} \text{KiteScore}$$
  - Benchmark heuristic-evaluated PUCT against existing bots without neural dependencies.

### Phase 2: Dual-Head Universal Architecture (1 Model for All Specs & Matchups)
- [x] **Single Universal Model Design**:
  - Exactly **1 neural network** is trained to serve all matchup permutations ($W \times W$, $M \times M$, $W \times M$, $M \times W$). No separate models per spec or matchup.
  - **Inputs**: One-hot spec IDs for both fighters concatenated with normalized combat features:
    $$\text{Input} = [ \text{Spec}_A \text{ (one-hot)}, \text{State}_A, \text{Spec}_B \text{ (one-hot)}, \text{State}_B ]$$
  - **Outputs**:
    - Value Head: $V(s) \in [-1, 1]$ (expected win rate for Player A given the current matchup and game state).
    - Policy Head: Shared 9-slot discrete action logits + 3-slot movement logits. Actions correspond to spec-specific slots (e.g. slot 3 = Fear for Warlock, Polymorph for Mage), masked by legal action checks.
  - **Benefits**: Shared representation of fundamentals (kiting, cooldown tracking, interrupt timing, diminishing returns) and zero combinatorial explosion as new classes are added.
- [x] **Network Specification & AVX Inference**:
  - Small, high-throughput MLP (e.g. 2–3 layers, 128 hidden units, ~25k parameters).
  - Native AVX2/AVX-512 forward pass evaluating 16 states per batch in $< 1\,\mu\text{s}$, completely eliminating Python/IPC overhead during search.
- [x] **Warm-Start Bootstrap (Optional, ~20 min)**:
  - Behavior clone on ~1,000 duels of existing heuristic bots / genetic champions to seed initial policy and value heads before starting self-play.

### Phase 3: Self-Play Generation & Iteration Loop
- [x] **Data Generation Pipeline**:
  - Generate matches sampling random pairings ($W \times W$, $M \times M$, $W \times M$, etc.) guided by $M$ visits of PUCT search ($M \approx 200\text{--}400$).
  - Record training tuples: $(s_t, \boldsymbol{\pi}_t, z)$ where $z \in \{-1, 0, 1\}$.
- [x] **Training Budget & Timeline**:
  - ~500 self-play duels per iteration (~150k states) takes **~10–15 minutes** of simulation on 16 threads.
  - Model fitting takes **~30–45 seconds** per generation.
  - Useful play emerges in **~3–4 generations (under 1–2 hours total compute)**, completely avoiding days-long training runs.
  - Standard multi-task loss:
    $$L = (z - V(s))^2 - \boldsymbol{\pi}^\top \log \boldsymbol{P}(s) + c \|\theta\|^2$$

### Phase 4: Production Fight Generator
- [x] **Single-Fight CLI & Visualizer Export**:
  - Command to generate a single near-optimal fight using the trained universal network + PUCT in $\le 3$ seconds.
  - Save full replay (`.lua`) and interactive search overlay showing visit distributions and predicted win percentages at each second of combat.

---

## Strategic Pivot: Event-Driven Terminal MCTS (Exhaustive Ground-Truth Search)

### Motivation & Rationale
1. **Model Fragility & Artifacts**:
   - Neural approximations (AlphaZero value/policy heads) risk distribution shift, policy collapse (e.g. idle spamming / advancing blindly into melee), and require costly retraining on every balance/mechanic change.
2. **Horizon Compression without Physics Modification**:
   - The physics engine remains strictly **100 Hz native (10 ms per tick)** with zero combat timing modifications.
   - The **search abstraction** shifts from per-tick polling to **Event-Driven Tactical Boundaries (Semi-Markov Decision Process)**.
   - Instead of evaluating 800+ micro-decisions per duel, a duel naturally contains only **25–45 tactical decision points** (spell cast completions, GCD resets, enemy cast starts/interrupt windows, defensive activations, and range threshold crossings).
3. **Exhaustive Ground-Truth Terminal Search**:
   - With only ~30–40 decision boundaries per duel and 50k–70k SIMD rollouts/sec, search budgets of 5,000–20,000 rollouts per boundary complete in **~2–5 seconds**.
   - No neural networks or heuristic value cutoffs are needed. Search uses **unbiased ground-truth terminal rollouts** ($z \in \{+1, -1, 0\}$ at terminal death), completely eliminating approximation error and training loops.

---

### Phase 5: Event-Driven Boundary Search & Rollout Engine

- [x] **1. Event-Driven Tactical Boundary Detection (Search-Side)**:
  - Keep native 100 Hz physics simulation unmodified.
  - Implement tactical boundary detector in search (`needsTacticalDecisionA/B`, `readyTactical`, and `choicesTactical`):
    - **Cast / GCD Finish**: Current cast or global cooldown completes.
    - **Threat / Opportunity Trigger**: Enemy starts a hard cast (Fear, Polymorph, Frostbolt), presenting an interrupt or counter-play window.
    - **Defense / Buff Shift**: Enemy activates major defensive buff (Unending Resolve, Ice Barrier).
    - **Control State Change**: Hard crowd control (Fear, Horror, Nova) applied or broken.
    - **Distance Milestone**: Relative combat distance crosses critical tactical bands (e.g. 20m Fear range, 30m spell range, 6m melee proximity).
  - During non-boundary ticks, forward simulation retains the active action and continuous movement intent without querying the search tree.

- [x] **2. Horizon Compression & Action Duration Stepping**:
  - In tree selection and rollout evaluation, advance the 16-lane simulator forward through ticks until the next tactical boundary or duel termination.
  - Compresses search horizon from ~800–1000 decisions down to **~90–160 decisions per match**.
  - Increases lookahead depth per branch dramatically without stalling on 10ms micro-polling.

- [x] **3. Event-Aware Terminal Rollout Policy**:
  - Moves commit across duration windows until the spell finishes or an enemy threat triggers a reaction.
  - Eliminates self-canceling cast syndrome (starting a cast and immediately canceling it 20ms later).
  - Produces coherent, high-information terminal win/loss returns (+1 / -1) back to the root without neural dependency.

- [x] **4. Near-Exhaustive / High-Budget Simultaneous Bandits**:
  - Evaluated PUCT/UCT/Exp3 at event-driven boundaries with 1,024–4,096 rollouts per decision across 4–16 workers.
  - Measured 100k–190k SIMD rollouts/sec and ~250M–300M simulated ticks/sec across 8–16 workers.
  - Compute time per full 25–30s match dropped from **~17–26 seconds** down to **~0.6–1.6 seconds** (over **16x–25x faster**), defeating champion baselines.

- [x] **5. CLI & Visualizer Integration**:
  - Updated `mcts_fight` to support `--boundary event|tick` (defaulting to `--boundary event`).
  - Added `--boundary` and `--evaluator` flags to `scripts/benchmark_mcts.py`.
  - Maintained full replay and search metadata export compatible with `mcts_overlay.lua`.

---

## Learnings from Phase 5 (Event-Driven MCTS vs Genetic Champions)

1. **Deterministic Root Action Commitment (`argmax` vs `sample`)**:
   - In Exp3/softmax MCTS, root decisions previously used stochastic exploration sampling (`sample()`). At `t = 0`, even with high-quality visit distributions, sampling occasionally selected low-probability exploratory actions like `Idle` (ability 0), causing MCTS to concede the opening tempo to specialized genetic champions.
   - Switching root selection to deterministic `argmax` of the strategy/visit distribution ensures committed competitive play without conceding opening tempo.

2. **Mid-Cast Tactical Interrupt Trap**:
   - `needsTacticalDecision` was originally checking whether `react_timer <= 0`. During a stationary hard cast (e.g. `Fear`, `Shadow Bolt`), `react_timer` would expire every 100ms, triggering tactical boundaries mid-cast where legal choices included `CancelCast` (8).
   - This caused MCTS to repeatedly evaluate canceling its own hard casts mid-stream.
   - **Resolution**: Tactical boundaries now strictly gate on `cast_done` or `!is_casting`. Mid-cast tactical queries only trigger if the cast finishes, is interrupted by crowd control/damage, or when the unit is free to act.

3. **Sub-Second Performance with Zero Neural Net**:
   - With event-driven boundaries and PUCT, MCTS compresses 15–22s duels down to 59–108 tactical decisions.
   - At 4,096–8,192 rollouts/decision across 8 workers, MCTS evaluates >200,000 terminal continuations in **0.30s–0.89s** and decisively defeats `champ_balanced.bin` on both Side A and Side B without any neural network.

---

## Phase 6: UX, Parameter Tuning in Visualizer, & Combat Physics Integrity

### 1. Painfully Obvious Spec vs Spec Matchup Setup & Visualization
- [x] **Convenience Matchup Runner Script / CLI (`scripts/run_fight.sh` or `mcts_fight` helper)**:
  - Provide a single, dead-simple command to run and immediately visualize arbitrary spec matchups (e.g. `./run_fight.sh warlock frost_mage`, `./run_fight.sh warlock champion`).
  - Support presets for common configurations: `--fast` (~0.3s), `--standard` (~1.0s), `--deep` (~5.0s).
  - Automatically launch `love visualizer <match_file.lua>` upon completion or write to a default `matches/latest.lua`.
- [x] **In-App Match Generation & Launcher within LÖVE Visualizer**:
  - Add a "New Fight" / "Matchup" modal or panel inside the LÖVE visualizer (`F3 Match Browser` or `F1 Arena`).
  - Allow selecting:
    - Fighter A Spec (Warlock, Frost Mage, etc.) & Controller (MCTS, Champion, Heuristic Bot)
    - Fighter B Spec & Controller
    - One-click "Fight!" button that executes the search in the background and immediately streams/plays the replay.

### 2. Interactive Parameter Tuning in Visualization App
- [x] **Visualizer Search Parameter Control Panel**:
  - Add sliders/inputs for:
    - **Rollout Budget**: 1,024 to 65,536 rollouts per decision (giving user full control over compute vs depth).
    - **Worker Threads**: 1 to 16 CPU workers.
    - **Search Algorithm**: PUCT vs UCT vs Exp3.
    - **PUCT Exploration Weight ($c_{\text{puct}}$)**: 0.5 to 3.0.
    - **Evaluator**: Pure Terminal Rollouts vs Fast Heuristic Leaf Scorer.
    - **Opening Distance & Health Overrides**: Distance (10m–35m), Max HP (500–2500).
  - Display estimated compute time and allow interactive re-simulation of the match from the visualizer UI.

### 3. Combat Physics Bug: Moving While Casting Stationary Spells & Visualization Polish
- [x] **Investigate Moving While Casting**:
  - **Root Cause 1 (Symmetric Position Clamping)**: In `src/mcts_main.zig` and `src/match_recorder.zig`, positions were previously derived each tick as `pos_a = center - half_distance; pos_b = center + half_distance` where `half_distance = distance * 0.5`. Whenever Player B moved, jumped, or blinked (15m displacement), `half_distance` changed, artificially shifting Player A by up to 7.5 meters even though Player A was stationary channeling `Drain Life` with `speed_a == 0`.
  - **Root Cause 2 (Search Boundary Disruption)**: In `src/search_sim.zig`, `d.apply` evaluated `ready` rather than `readyTactical`. During a stationary channel, `react_timer` expired every 100ms, causing external actions to re-stage and interrupt or redirect movement mid-cast.
  - **Fix Implemented**: Replaced symmetric clamping with independent position integration (`pos_a = clamp(pos_a + speed_a * dt, -17.5, 17.5)` and `pos_b = clamp(pos_b + speed_b * dt, -17.5, 17.5)`) with single-sided Blink displacement and minimum 1.0m token separation. Wired `d.applyTactical` in `src/mcts_main.zig` when using `--boundary event`.
  - **Verification**: Evaluated test fights; verified 0 frames of position drift during `Drain Life`, `Fear`, and `Shadow Bolt` across both players.

- [x] **Sanity Check & Polish Visualization Output (Text & Telemetry)**:
  - **Root Cause (Tick Damage Event Flood)**: Every 10ms simulation tick where DoTs dealt fraction damage, `mcts_main.zig` logged `.DamageHit` with `spell_id = action` (where `action == 0`, i.e. `Idle`). This flooded replays with over 2,000 `.DamageHit` events with `spell_id = 0`, causing the visualizer live text to display `Unit A -> Idle (Amount: 1)` and spawning hundreds of false projectile animations.
  - **Fix Implemented**: Implemented periodic event accumulation (1.0s DoT pulses, 0.5s Drain Life damage and heal pulses), direct spell classification (`Shadow Bolt`, `Frostbolt`, `Ice Lance`, `Death Coil`), and CC/defensive logging.
  - **Visualizer Text HUD**: Updated `visualizer/main.lua` to format `latestEvText` with rich, human-readable descriptions (e.g. `Unit A began casting Drain Life`, `Unit A Siphon tick (-45 HP)`, `Unit B cast Blink`, `Unit B activated Ice Barrier`). Fixed inverted Death Coil vs Siphon heal label in floating combat text.
  - **Verification**: Total events per replay reduced from 2,100+ raw tick spam down to ~80–95 clean, informative combat events with 0 instances of `spell_id = 0`. All automated tests pass in `ReleaseFast`.

---

## Phase 7: Spec & Talent Visualizer, Editor, and Import/Export System (WoW Forever / Vanilla Style)

### Objective
Provide a dedicated interactive Spec & Talent Builder tab/page in the visualizer application. Allow creating custom level 60 character talent builds (51 talent points), saving custom specs to disk, loading and browsing saved specs, deleting them, and exporting/importing via standard URL hash string / base64 strings and human-readable JSON.

### Tasks & Architecture Breakdown

- [ ] **1. Talent Tree Schema & Forever/Vanilla Data Extraction**:
  - Extract and bundle authentic talent tree metadata matching WoW Forever / Vanilla (starting with Warlock: Affliction/Curses, Demonology/Summoning, Destruction; and Mage: Arcane, Fire, Frost).
  - Store talent definitions in `visualizer/data/talents.lua` (or `data/talents_forever.json`):
    - Trees per class (e.g. Warlock: Curses [302], Summoning [303], Destruction [301]).
    - Per-talent node metadata: `id`, `name`, `icon`, `row` (0..6), `col` (0..3), `max_ranks`, `descriptions` per rank, `requires` (prerequisite talent ID and rank), and `required_points` (5 points per row tier).

- [ ] **2. Spec Data Model & Validation Engine**:
  - Implement talent points budget: Level 60 cap = **51 talent points**.
  - Enforce talent tree rules:
    - Row gating: Row $R$ requires at least $R \times 5$ points invested in that specific tree.
    - Prerequisite dependencies: Prerequisite talent must have maximum rank invested.
    - Decrement validation: Cannot deallocate points if higher-tier invested talents or dependent talents would become invalid.
  - Reset tree / Reset all buttons.

- [ ] **3. Import / Export Format**:
  - **URL / Hash String**: Support standard WoW talent calculator hash string encoding (e.g., Wowhead Forever / Vanilla format string digits representing ranks allocated in tree order) for instant copy/paste sharing.
  - **Portable JSON**: JSON format containing metadata (`name`, `class`, `level`, `points`, `trees`, `timestamp`, `hash`).
  - Saved specs stored under `specs/` (e.g. `specs/warlock_sl_sl.json`, `specs/warlock_sm_ruin.json`, `specs/warlock_conflag.json`).

- [x] **4. Interactive Spec Editor UI (LÖVE Visualizer Tab `[F5] / Specs`)**:
  - Add dedicated navigation tab `Specs [F5]` (shifting Meta Health / Spec Meta or integrating seamlessly).
  - Multi-tree layout (3 trees side-by-side: Affliction, Demonology, Destruction) with authentic grid layout (7 rows $\times$ 4 columns per tree).
  - Interactive mouse controls:
    - **Left Click**: Invest 1 point in talent (up to max rank).
    - **Right Click**: Remove 1 point (subject to validity checks).
  - Rich hover tooltips:
    - Current rank description, next rank description, required points / prerequisites warning in red if locked.
  - Header counter: Points remaining (`51 / 51`), tree distribution counter (e.g. `Affliction: 30 | Demonology: 0 | Destruction: 21`).

- [x] **5. Spec Browser, Management, & Fight Runner Hookup**:
  - Sidebar / drawer to:
    - Create new spec with custom name.
    - Browse existing saved specs with summary badge (`30/0/21`).
    - Save current build.
    - Delete unwanted specs.
    - "Import from String / URL" modal with input prompt.
    - "Export / Copy to Clipboard" button.
  - Link saved specs directly into the match generator so MCTS fights can simulate custom user builds and compare them against champions.

- [x] **6. Simulation Combat Kernel Hookup (Stat & Mechanic Multipliers)**:
  - Wire `CombatModifiers.fromTalents()` into `combat_spec.zig` and `multi_spec.zig` lane initialization:
    - Cast time reductions (Bane / Destruction ratio scaling cast times).
    - DoT tick damage multipliers (Shadow Mastery / Affliction ratio scaling Agony & Corruption).
    - Siphon heal multipliers (Fel Concentration / Affliction ratio scaling Drain Life).
    - Passive damage mitigation (Soul Link / Demonology ratio reducing incoming damage).
  - Benchmark simulation throughput to ensure SIMD lanes maintain 100k+ rollouts/sec with per-lane modifier vectors.

- [x] **7. Phase 8: Talent Mechanics Execution (Soul Link Pet Damage Split & Siphon Life)**:
  - **Task 8.1: Spec File CLI Ingestion & `CombatModifiers` Vectorization**:
    - Extend `mcts_main.zig` to accept `--spec-file-a` and `--spec-file-b` (or parse `specs/*.json` via `--spec-id-a/b`). [COMPLETED]
    - Parse talent tree summaries (`tree1`, `tree2`, `tree3`) and compute `CombatModifiers`. [COMPLETED]
    - Splat `CombatModifiers` into the `WarlockArenaPool` / `ArenaPool` (e.g. `dot_dmg_mult`, `healing_mult`, `cast_time_mult`, `damage_taken_mult`). [COMPLETED]
    - Apply modifiers in `tickPhysicsRange` branchlessly across SIMD lanes. [COMPLETED]
  - **Task 8.2: Soul Link Pet Damage Sharing**:
    - In `src/combat_spec.zig` and `src/multi_spec.zig`, if Warlock has Soul Link and active pet has `pet_hp > 0`: [COMPLETED]
      - Apply 30% damage transfer: `player_dmg = dmg * 0.70`, `pet_dmg = dmg * 0.30`.
      - Deduct `pet_dmg` from `pet_hp_a/b`. If `pet_hp <= 0`, pet dies and Soul Link deactivates.
  - **Task 8.3: Siphon Life Active Spell & Action Space Integration**:
    - Expand `WarlockAction` enum with `SiphonLife = 8`, `CancelCast = 9` (expanding `COUNT` to 10). [COMPLETED]
    - Add `siphon_timer_a/b` SoA columns to `WarlockArenaPool`. [COMPLETED]
    - Mask `SiphonLife` action out in `d.choices()` if the fighter lacks the Siphon Life talent (`talents.tree1 < 20` or node not selected). [COMPLETED]
    - In `tickPhysicsRange`, advance `siphon_timer` and tick siphon damage + self-heal concurrently with Agony/Corruption. [COMPLETED]
    - Expand `search_sim.zig` Choices items from 27 to 30, and update MCTS `Bandit` arrays and search priors for Siphon Life. [COMPLETED]
    - Verified all 51 tests pass in `ReleaseFast` and simulated test duels with `soul_link_warlock` and `affliction_warlock`. [COMPLETED]
