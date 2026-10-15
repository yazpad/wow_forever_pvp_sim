# Geometry and homing experiments — 2026-10-14

Suggestion 3 was measured against the suggestion 2 baseline. Neither candidate
showed a material end-to-end gain, so neither is enabled in production. The
production geometry math, projectile speeds, homing updates, and impact timing
remain unchanged. Cached target loads remain available as an explicit test and
benchmark candidate, with a compile-time selection and no runtime switch.

## Candidates

1. Exact horizontal fast paths: replace `sqrt(dx*dx)` with `abs(dx)` when every
   lane has zero vertical displacement, with bounds to avoid tiny/overflowing
   inputs. Replace heading divisions with signs only when stored distance exactly
   equals horizontal separation. All other cases retain the original 2D math.
   This passed trajectory/state and randomized length comparisons, but exploratory
   end-to-end gains were only about 0.4–1.0%. The branches were removed.
2. Cached homing targets: load the target's X/Y vectors once before advancing a
   caster's four slots. The original implementation loads them inside each live
   slot. Geometry cannot change during this loop, so this is bit-exact. The
   generated homing functions shrank by 87 bytes each, but measured throughput
   did not improve materially. Production still uses the original load placement.

No approximate square roots, reciprocal math, or delayed homing were introduced.

## Final target-cache comparison

AMD Ryzen 9 9950X, native Zig 0.14.0 ReleaseFast, one worker, seed 1, 512 rollouts
per search, 60 searches per run. Five repetitions per binary/workload, alternating
binary order. The final end-to-end comparison ran after builds, tests, and kernel
timings had finished. Results are median rollouts/sec.

| Workload | Suggestion 2 baseline | Cache candidate | Difference |
| --- | ---: | ---: | ---: |
| Default PUCT / heuristic / event boundary | 12,441.4 | 12,394.8 | -0.4% |
| Terminal evaluator / event boundary | 11,957.3 | 11,996.7 | +0.3% |
| Suffix at tick 300 / heuristic / tick boundary | 5,782.6 | 5,810.6 | +0.5% |

Rollout counts, node counts, maximum depth, and lane utilization match in every
pair. These sub-percent differences are too small and inconsistent across cases
to claim a useful improvement. The first default baseline run was slower than
the rest; medians reduce the effect of that outlier. Raw runs:
[geometry_optimization.json](geometry_optimization.json).

## Isolated kernel timing

Five samples per case, 64,000 SIMD calls per implementation per sample. Each
homing call advances both casters' queues. Horizontal and 2D fixtures have three
projectiles per caster; sparse fixtures have one, with some lanes inactive.
Snapshots are restored outside timing. Explicit function boundaries keep the
measured mutations observable; complete outputs are checked against the original.

| Homing workload | Median speedup from caching |
| --- | ---: |
| Horizontal | 1.0041x |
| Two dimensional | 0.9986x |
| Sparse | 1.0065x |

Movement is deliberately unchanged in this benchmark and acts as a timing
control; its medians were within 0.4% of parity. Raw samples:
[geometry_microbenchmark.json](geometry_microbenchmark.json).

Exploratory horizontal-path results are retained in
[geometry_collinear_experiment.json](geometry_collinear_experiment.json) and
[geometry_collinear_microbenchmark.json](geometry_collinear_microbenchmark.json).
Part of the exploratory suffix measurement overlapped kernel timing, so those
exploratory results are not acceptance evidence. The final comparison above was
serialized. Hardware profiling counters remain unavailable on this host; all
measurements here use wall-clock timers.

## Validation and reproduction

`zig build test -Doptimize=ReleaseSafe` passes. The retained trajectory test
compares all snapshot words after 2,000 movement/homing steps, covering horizontal
and 2D movement, CC wander, edited starting distances, sparse/inactive lanes,
queue launches, impacts, and arena limits. Existing projectile speed, midflight
snapshot, action equivalence, and deterministic search tests also pass.

```sh
zig build test -Doptimize=ReleaseSafe
zig run src/geometry_benchmark.zig -O ReleaseFast
```

To reproduce the end-to-end candidate, first save the default ReleaseFast binary
as the baseline. Temporarily change `projectiles.tick` to call `tickImpl` with
`true`, build/save the candidate, and restore it to `false`. Then compare binaries:

```sh
python3 scripts/profile_staging.py /tmp/mcts_before_geometry /tmp/mcts_geometry_cached_targets \
  --repeats 5 --output benchmarks/mcts/geometry_optimization.json
```

The current working executable is rebuilt with the candidate disabled. No gain
from these experiments is added to the improvements measured for suggestions 1
and 2. Action-mask work is the next independent experiment.
