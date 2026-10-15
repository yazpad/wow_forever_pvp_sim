# Action-mask experiments — 2026-10-14

Suggestion 4 was tested in two stages against the suggestion 2 baseline
(the geometry candidates from suggestion 3 remain disabled).

1. Move mask construction and action selection inside a batch readiness check.
   Physics still advances every 10 ms, but ticks without a decision do not enter
   this block. This removes the per-lane `has_decision` bookkeeping.
2. Pass pre-action masks through action staging and mixed-spec kernels, avoiding
   their repeated legality calculations. Also reuse the existing masks when
   entering a fallback rollout instead of reconstructing them in `rollout`.

The full second prototype was correct but only 0.8–1.9% faster end-to-end. This
does not justify adding cached-mask APIs across simulation and combat kernels.
Those API changes were removed. The final code retains only the readiness scope
and the two fallback `rolloutFast` calls using existing masks. The application
and combat kernel interfaces are unchanged.

## Measurements

AMD Ryzen 9 9950X, Zig 0.14.0 native ReleaseFast, one worker, seed 1, 512 rollouts
per search, 60 searches per run. Three repetitions per binary/workload, alternating
binary order. Builds, tests, and equivalence checks completed before timing runs;
no other benchmark ran concurrently. Results use median rollouts/sec.

Gating-only differences were -0.2% default, +0.3% terminal, and +0.5% suffix.
Raw runs: [masks_gating.json](masks_gating.json).

| Full reuse prototype | Baseline | Candidate | Difference |
| --- | ---: | ---: | ---: |
| Default PUCT / heuristic / event boundary | 12,308.4 | 12,471.9 | +1.3% |
| Terminal evaluator / event boundary | 11,887.0 | 11,986.4 | +0.8% |
| Suffix at tick 300 / heuristic / tick boundary | 5,797.3 | 5,908.0 | +1.9% |

Raw prototype runs: [masks_optimization.json](masks_optimization.json).
The rejected complete prototype is retained as
[masks_reuse_experiment.patch](masks_reuse_experiment.patch), relative to the
pre-experiment source. It is not applied to the final implementation.

| Final lightweight code | Baseline | Final | Difference |
| --- | ---: | ---: | ---: |
| Default PUCT / heuristic / event boundary | 12,218.9 | 12,255.4 | +0.3% |
| Terminal evaluator / event boundary | 11,875.1 | 11,873.9 | approximately 0% |
| Suffix at tick 300 / heuristic / tick boundary | 5,819.4 | 5,808.8 | -0.2% |

Final lightweight measurements are recorded in [masks_final.json](masks_final.json).
These experiments do not demonstrate a substantial additional throughput gain.
Some first baseline runs were slower than subsequent runs; medians limit their
effect. Absolute rates should not be compared across sessions. Hardware profiling
counters remain unavailable; these are wall-clock comparisons.

## Correctness

ReleaseSafe tests pass. While the full reuse prototype was active, the one-sided
and divergent-lane oracle tests also exercised supplied masks against the original
full staging implementation. After removing that prototype, the existing oracle
tests and simulator/search tests pass with the final interfaces.

Both the prototype and final implementation matched the baseline across 16
six-second recorded fights. Cases cover all four matchups, event/tick boundaries,
heuristic and random continuations, PUCT/Exp3, one/two workers, and depth 2 to force
fallback rollouts. Comparison excludes only compute time and the output filename;
it checks replay frames/events, initial state, root choices and distributions,
committed actions, exact tick/node statistics, and outcome. The final comparison
contains 2,510 matching decision records.

Artifacts:

- [masks_candidate_equivalence.json](masks_candidate_equivalence.json)
- [masks_final_equivalence.json](masks_final_equivalence.json), including normalized
  search/replay hashes for each case

Readiness does not eliminate the unready side's rollout RNG calls. Even discarded
actions can consume random numbers; preserving these calls keeps the subsequent
search trajectory unchanged. Masks are reused only before combat state changes.

## Reproduction

Save the baseline executable before changing `mcts.zig`, then build the candidate:

```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/mcts_fight /tmp/mcts_before_masks
# Apply the final lightweight changes, then:
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe
python3 scripts/verify_mcts_equivalence.py /tmp/mcts_before_masks zig-out/bin/mcts_fight
python3 scripts/profile_staging.py /tmp/mcts_before_masks zig-out/bin/mcts_fight \
  --output benchmarks/mcts/masks_final.json
```

Saved experiment binaries for this session are `/tmp/mcts_masks_gated` and
`/tmp/mcts_masks_reused`. The final executable contains neither the cross-kernel
mask APIs nor the rejected geometry fast paths.

## Re-evaluation

Stop this optimization pass here. Suggestions 1 and 2 delivered the material
improvements; suggestions 3 and 4 show diminishing returns on these workloads.
Do not proceed to lane refill without evidence that idle SIMD capacity dominates
the actual production workload. The historical pre-projectile throughput gap is
not a matched-workload target and does not justify more complexity by itself.
