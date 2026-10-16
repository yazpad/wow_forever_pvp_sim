# Offline simultaneous MCTS

The executable generates **one committed fight**, searching again at each existing
decision boundary. It requires no training or exported policy. Both fighters are
adversaries inside each search, even when evaluating the committed fight against
a fixed bot. Results are search-generated, **not certified near-optimal**.

## Build and run

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/mcts_fight --spec-a warlock --spec-b frost_mage \
  --workers 16 --rollouts 10000 --output matches/mcts_warlock_vs_frost_mage.lua
```

The budget counts complete joint simulations, combined across workers; it is not
multiplied by two players. The executable supports `--help`. Important options:

- `--evaluator rollout|heuristic`: defaults to terminal win/loss/draw (`rollout`);
  `heuristic` explicitly enables intermediate leaf scoring.
- `--algorithm exp3|uct|puct` (default `puct`): independent adversarial bandits at simultaneous nodes.
- `--rollouts N`: fixed per-boundary budget; `--ms N` adds a wall-clock deadline.
  To use primarily a time budget, set a large rollout ceiling too. The deadline
  is checked between batches; one batch of 16 terminal simulations may overrun it.
- `--workers N`: persistent worker pool and independent trees. Fixed budgets and
  fixed worker counts reproduce actions/strategies; deadlines are nondeterministic.
- `--nodes N`: maximum nodes **per worker**, default 4096. At capacity, selection
  continues on existing edges and missing edges use terminal continuations.
- `--depth N`: maximum tree decisions in a path, default 128; thereafter use a
  terminal rollout. This limits storage, not the simulated fight horizon.
- `--memory-mb N`: maximum estimated arena/tree/path storage across all workers,
  default 512 MiB; oversized configurations fail before allocating worker arenas.
  This is not an operating-system RSS limit (thread stacks/allocator add overhead).
- `--seconds N`: combat timeout, default 60 seconds, with 100 Hz physics.
- `--seed N`, `--distance N`, `--hp-a N`, `--hp-b N`: starting conditions.
- `--random-rollout`: uniform legal action/movement continuations instead of the
  inexpensive spell-priority heuristic with occasional random actions.
- `--opponent heuristic|random|champion`, `--search-side a|b`: evaluation opponent.
  `--champion PATH` defaults to `champ_balanced.bin`; incompatible class tags are rejected.
- `--stop-file PATH`: creating this file cancels between bounded rollout batches.
  The main loop saves the committed replay prefix and marks metadata cancelled.
  Remove the file before starting another run. This is not a search-resume format.

The output is a Lua replay plus `<output>.json` and `<output>.search.json`.
Metadata records full initial combat state, configuration, seed, version of the
stepping contract, committed actions, root distributions, statistics, and outcome.
The existing replay browser finds Lua files in `matches`; use its **All** filter
if the filename does not match its class/spec naming filters. Playback uses saved
frames and never reruns search. CLI progress is printed every 25 decisions.
There are no new viewer generation/cancel controls in this implementation.

## Simulation contract

`search_sim.zig` captures every SoA combat column, ten Mage-specific columns, and
elapsed ticks. Snapshots can be restored into any of sixteen aligned lanes.
Combat currently has no stochastic mechanics; worker search RNG and committed
move RNG are separate. Each tree edge therefore identifies a deterministic state.
No observation-vector reconstruction or future-randomness access is involved.

Both players select masked actions from the same pre-action state. Single-sided
readiness preserves the other's committed movement and reaction timer. The new
staging methods run the existing action kernels separately against that state,
then combine their effects. Damage/healing and displacement add **before** final
clamping. Enemy effects win conflicting own-state writes; interrupts reset the
reaction timer even if its old value was already zero. New defenses affect later
physics, not the other simultaneous instant action. Existing shields and damage
reduction are considered when staging incoming damage. This explicitly defines
same-tick resolution instead of granting A or B a fixed application-order advantage.
Legacy training/recording entry points retain their original sequential behavior.

The existing readiness rule treats a zero GCD as ready even when the reaction
timer is positive. This can cause a decision every 10 ms. It is deliberately
preserved, so a 15-second fight can have around 900 decisions, not 150.

The action set is retreat/hold/advance crossed with legal abilities. Movement is
deduplicated when an existing/new cast or control effect forces it to zero.
Inactive/non-ready fighters have one no-op/preserved-intent choice. Terminal
rewards are A win +1, B win -1, both alive at timeout or both dead 0. There is no
health-based cutoff evaluator or shaping reward.

Replay positions are reconstructed from simulator distance and movement because
absolute world positions are not part of the combat model. Events and damage/heal
summaries use frame HP deltas, so simultaneous healing and damage can cancel in
those summaries. The recorded health/resource/cast/status frames are authoritative.

## Search and limitations

Each worker owns a bounded contiguous node arena, three aligned combat arenas,
path buffers and RNG. Joint edges are allocated lazily as linked integer indices.
There are no allocations inside the rollout loop. UCT reserves local visits
until a batch completes to spread unvisited actions across lanes. Sixteen simulations advance
in a SIMD batch; inactive lanes remain unused until that batch completes.
The implementation uses neither lane refill nor subtree reuse.

Each node maintains separate Exp3 bandits with opposite terminal rewards, or
separate UCT statistics. Exp3 uses log weights, importance-weighted sampled gains,
and a 0.1 exploration mixture. Backpropagation updates both players from every
joint outcome. Root commitment samples visit-weighted average marginal strategies
from workers in stable order. This aggregation is an empirical strategy, not a
proof of equilibrium. Batched feedback and independent trees are further reasons
not to transfer a convergence theorem directly to this implementation. See the
[simultaneous-move MCTS paper](https://proceedings.neurips.cc/paper_files/paper/2013/hash/1579779b98ce9edb98dd85606f2c119d-Abstract.html).

Worker count is a quality/speed tradeoff: 128 total simulations over eight workers
is just one batch per tree, so the committed root strategies have no feedback from
an earlier batch. Increasing workers while holding a tiny total budget fixed can
produce very fast but effectively untrained root choices. Large worker counts
need sufficiently large per-worker budgets.

The current root strategies are averaged including exploration. Repeatedly
sampling a low-confidence distribution at fine time boundaries can waste spells,
refresh effects early, or cancel useful casts. Terminal rollouts also become
uninformative when most continuations already lose or time out. Strong tactical
results alone do not establish strong long-horizon play.

## Validation and reproducible measurements

```sh
zig build test -Doptimize=ReleaseSafe
python3 scripts/benchmark_mcts.py --suite speed
python3 scripts/benchmark_mcts.py --suite quality --workers 8 \
  --rollouts 128 1024 --seeds 1 2 3 4
zig-out/bin/mcts_fight --benchmark --workers 16 --rollouts 100000 --rounds 2
zig-out/bin/mcts_fight --benchmark --workers 16 --rollouts 1000000
```

Tests cover both-kit snapshot restoration, side-swapped simultaneous resolution,
legal masks, single-sided readiness, simultaneous lethal damage/healing,
interrupt hard stops, terminal rewards, deterministic parallel budgets, bounded
nodes, memory rejection, cancellation, rock-paper-scissors mixing, and learning
an immediate terminal winning action. Existing simulator tests also remain in
the suite. Thread lifecycle is exercised by creating/searching/destroying pools;
a dedicated thread race sanitizer has not been run.

`--benchmark` repeatedly searches a fixed state. `--start-ticks N` obtains a suffix
state using heuristic play first. Reports include terminal rollouts/sec, actual
active-lane physics ticks/sec, SIMD lane utilization, node counts, maximum tree
depth, search wall time and estimated allocated working storage. Node counts are
summed over repetitions/workers. Complete initial-state and suffix rates must not
be conflated. The training benchmark's neural-inference throughput is not used
as an MCTS estimate. See `MCTS_RESULTS.md` for measured results and the viability
assessment.
