# One-sided action optimization — 2026-10-14

Suggestion 2 only, compared with the already optimized action staging from
suggestion 1. The baseline executable was saved before this change.

`applyMasked` now checks whether either side has no ready SIMD lanes. When only
one side is ready, it runs that side's action kernel directly in the combat
arena. It preserves possible writes in the original arena and restores lanes
that are not ready. The opponent's owned fields need no copying or restoration.
Both-sided batches retain the existing simultaneous staging path.

This eliminates the scratch copy, the second action kernel, the unused side's
outer legality calculation, and conflict merging for one-sided batches. Combat
column copies decrease from 149 to 46 per such call. Mage extras retain a saved
original copy. HP, distance, and shield delta arithmetic/clamping match the full
merge, including non-ready lanes. Blink still refreshes geometry, and interrupts
still reset the target's reaction timer.

A one-sided decision in an individual lane does not activate this path if the
opposite side can act in another lane; both SIMD kernels are still needed there.
Projectile speed, physics ticks, readiness rules, and search policy are unchanged.

## Matched end-to-end measurement

AMD Ryzen 9 9950X, native Zig 0.14.0 ReleaseFast, one worker, seed 1,
512 rollouts per search, 60 searches per run, three repetitions per binary and
workload, alternating binary order. Results are median rollouts/sec.

| Workload | Suggestion 1 baseline | With suggestion 2 | Incremental gain |
| --- | ---: | ---: | ---: |
| Default PUCT / heuristic / event boundary | 9,840.2 | 12,388.0 | 25.9% |
| Terminal evaluator / event boundary | 9,609.3 | 12,068.9 | 25.6% |
| Suffix at tick 300 / heuristic / tick boundary | 5,345.2 | 5,865.3 | 9.7% |

The benchmark script verifies equal rollout counts, nodes, maximum depths, and
lane utilization in every before/after pair. Raw runs and commands are in
[one_sided_optimization.json](one_sided_optimization.json).

Use these paired measurements to assess the incremental gain; absolute rates
vary between measurement sessions. Scaling across worker counts has not been
measured. Hardware profiling counters remain unavailable on this host; these
are controlled wall-clock measurements.

## Validation

`zig build test -Doptimize=ReleaseSafe` passes. A targeted test compares the fast
path against the original full simultaneous merge for all four matchups, both
acting sides, all nine actions and an invalid action, partially ready batches,
cast cancellation, Blink, interrupts, zero-mana lanes, geometry synchronization,
impact telemetry, and missiles already in flight. Complete snapshots match after
the action and after each of 20 physics ticks. The earlier divergent-lane oracle
test and existing simulation/search tests also pass.

The isolated staging benchmark now compares the suggestion 1 baseline against
one-sided dispatch. It times natural fixture readiness, A-only, B-only, and
both-sided readiness masks, restoring snapshots outside timing. The latter three
use synthetic masks with some lanes not ready. It checks complete output equality
against the original full merge. Each sample contains 128,000 SIMD calls per
implementation per matchup/scenario. Raw samples:
[one_sided_microbenchmark.json](one_sided_microbenchmark.json).

Median speedups across three samples:

| Matchup | A-only | B-only | Both-sided |
| --- | ---: | ---: | ---: |
| Warlock / Warlock | 1.8619x | 1.8872x | 1.0028x |
| Warlock / Frost Mage | 1.9666x | 1.7261x | 1.0023x |
| Frost Mage / Frost Mage | 1.7693x | 1.8338x | 1.0000x |

Both-sided calls remain within 0.3% of baseline, with no measured slowdown.
Natural-fixture speedups are 1.0626x, 1.1655x, and 1.0001x respectively; these
fixtures do not represent the readiness distribution of a full MCTS search.

## Reproduction

Save the suggestion 1 executable before applying this change:

```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/mcts_fight /tmp/mcts_before_one_sided
# Apply suggestion 2 changes, then:
zig build -Doptimize=ReleaseFast
python3 scripts/profile_staging.py /tmp/mcts_before_one_sided zig-out/bin/mcts_fight \
  --output benchmarks/mcts/one_sided_optimization.json
zig build test -Doptimize=ReleaseSafe
zig run src/staging_benchmark.zig -O ReleaseFast
```

Pass `-- --staging-only` to the isolated benchmark to compare the original full
merge with suggestion 1, excluding one-sided dispatch.
