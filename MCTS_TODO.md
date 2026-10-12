# TODO: Optimized offline MCTS fights

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

- [ ] Implement adversarial search for both fighters. A rollout advances the
  complete duel with actions for both sides, and its outcome updates both sides'
  search statistics. Searching A against a fixed B bot alone does not satisfy
  the objective.
- [ ] Use simultaneous-move nodes when both fighters can decide. Select both
  actions from the same pre-action information; neither may inspect the other's
  newly selected action. Audit action application for accidental order advantage.
- [ ] At boundaries where only one fighter can decide, branch only that fighter;
  preserve the other fighter's already committed intent and timers.
- [ ] Prototype simultaneous-move MCTS with regret matching or Exp3. Preserve
  action distributions and sample committed moves when appropriate. Compare
  decoupled UCT as a baseline; do not assume ordinary alternating UCT solves
  simultaneous combat or that naive regret updates inherit convergence proofs.
- [ ] Define a zero-sum terminal reward: A win +1, B win -1, draw 0, with B using
  the opposite reward. Preserve current timeout/draw semantics. If adding a
  cutoff evaluator, document its bias and validate against terminal rollouts.
- [ ] Search at existing reaction/hard-stop boundaries while preserving 100 Hz
  physics. Do not silently change combat timing to make search faster.
- [ ] Enumerate masked legal abilities plus a small movement set, initially
  retreat/hold/advance. Nine abilities times three movements gives at most 27
  candidates per side and 729 joint pairs before masking and deduplication.
  Deduplicate only choices with identical simulation effects.
- [ ] Benchmark deeper movement refinement and progressive widening only after
  the discrete baseline works. Avoid eagerly allocating every joint child.
- [ ] Provide inexpensive heuristic rollouts for both sides. Optionally use
  existing GA champions as rollout guides; no new policy training is required.
  Compare against random legal rollouts to measure continuation quality.
- [ ] Audit randomness and information access. If stochastic mechanics exist,
  sample futures during search without revealing future random outcomes to
  action selection. Keep search RNG separate from committed-fight RNG.

Research starting point: [Convergence of Monte Carlo Tree Search in Simultaneous
Move Games](https://proceedings.neurips.cc/paper_files/paper/2013/hash/1579779b98ce9edb98dd85606f2c119d-Abstract.html).

## State and simulation integration

- [ ] Add an explicit complete duel snapshot/restore interface for all supported
  kits. Include resources, positions, casts, cooldowns, effects, reaction timers,
  movement intents, elapsed time, and stochastic state where applicable. The 24
  policy observations are insufficient to restore combat.
- [ ] Verify snapshot round trips and that restored continuations match the
  original simulation exactly for fixed actions and seeds.
- [ ] Expose a shared simulation path taking externally selected actions, with
  helpers for readiness, legal choices, and advancing to the next decision.
  Reuse combat kernels rather than maintaining separate MCTS combat rules.
- [ ] Support copying/broadcasting snapshots into aligned SIMD worker arenas.
  Benchmark scalar snapshots versus SoA packing before choosing the layout.
- [ ] Refactor recording to accept search-selected actions through the same
  stepping path. Reuse the existing Lua/JSON trajectory and replay browser.

## Extreme optimization and multithreading

Search must preserve the simulator's strengths. A pointer-heavy tree with a
lock per rollout is unlikely to preserve current throughput.

- [ ] Keep implementation native Zig, CPU-only, with no new runtime dependencies.
- [ ] Use persistent configurable workers, initially 1/2/4/8/16, each owning an
  aligned SIMD arena, RNG, scratch buffers, and tree storage. Reuse allocations
  across decisions; no allocator calls in the rollout hot path.
- [ ] Start with independent worker trees and root parallelism to avoid shared
  tree contention. Aggregate root action/joint-action statistics and strategy
  estimates at bounded synchronization points. Specify and validate aggregation;
  independently averaged strategies are not automatically an equilibrium.
- [ ] Batch leaf continuations into 16-lane rollouts. Measure lane utilization,
  early deaths, and divergent decision schedules. Test lane refill/compaction
  only if saved simulation work exceeds packing overhead.
- [ ] Keep tree selection scalar where needed and combat vectorized. Measure
  the batch-size tradeoff: large batches improve SIMD use but delay feedback.
- [ ] Store nodes/edges in bounded contiguous arenas with integer indices and
  compact statistics. Allocate joint children lazily; benchmark cache misses,
  state-copy cost, and bytes per node.
- [ ] Use per-worker counters and padded shared control fields to prevent false
  sharing. Keep replay serialization and rendering out of search workers.
- [ ] Add node/memory caps and defined behavior at capacity, such as continuing
  leaf rollouts without expansion. Never allow unbounded tree growth.
- [ ] Compare root parallelism with a shared-tree implementation only if quality
  or duplicate work warrants it. Shared trees require measured contention,
  reservation/virtual-loss behavior, and race tests.
- [ ] Investigate subtree reuse after committing the actual joint action. Verify
  the child matches the full resulting state; discard incompatible branches.
- [ ] Support fixed rollout budgets for reproducible tests and wall-clock budgets
  for interactive use. Stable per-worker seeds and ordered aggregation should
  reproduce fixed-budget runs at a fixed worker count; changing worker count
  need not produce identical search decisions.
- [ ] Allow cancellation between bounded batches and save the committed replay
  prefix plus metadata. Full search resume is a separate feature requiring all
  relevant combat/RNG/configuration state.

## Product workflow and saved artifacts

- [ ] Add an offline fight command with spec A/B, starting conditions, seed,
  worker count, per-decision rollout/time budget, memory limit, and output path.
- [ ] At each boundary: snapshot state, search both sides, commit their selected
  actions, advance combat, and append actual frames. Repeat until termination.
- [ ] Record spec IDs, simulator version, initial state/seed, search configuration,
  outcome, total compute time, and per-decision visits/strategy estimates.
  Label results as search-generated rather than certified optimal.
- [ ] Save frames so viewing does not require rerunning search. Optionally store
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
- [ ] Validate simultaneous selection with a small matrix game such as
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

1. Complete snapshots, external-action stepping, and equivalence tests.
2. Single-worker simultaneous search with bounded storage and heuristic rollouts.
3. SIMD leaf batching and persistent independent worker trees.
4. Benchmark speed and strategic quality; optimize measured bottlenecks.
5. Offline command, replay recording, metadata, and viewer controls.
6. Evaluate subtree reuse, richer movement, and shared trees if justified.

The first go/no-go checkpoint is actual batched multithreaded search throughput
and decision quality at increasing budgets, before committing to UI work or
assuming the simulator's 500k-duels/sec rate transfers directly to MCTS.
