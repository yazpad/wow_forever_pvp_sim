# Action staging optimization — 2026-10-14

Suggestion 1 only: reduce copying and merging in `search_sim.Duel.applyMasked`.
No changes to projectile speeds, movement, readiness, search policy, or physics.

Action fields are classified as unchanged, owned by their caster, or shared.
Impact telemetry is excluded from staging copies. Physics-only fields need no
original-state copy or merge. Owned fields use the owner's staged value directly;
shared fields retain the existing simultaneous resolution. Snapshot capture and
restore still include every column. The original merge is retained as a test and
microbenchmark reference, with no runtime switch in production.

Across the 88 combat columns, staging copies decrease from 176 to 149 columns,
merging decreases from 88 to 69 columns, and only 23 columns need conflict merging.
The ten Mage extra columns retain their previous copying and merging behavior.

## End-to-end measurement

AMD Ryzen 9 9950X, native Zig 0.14.0 ReleaseFast, one worker, seed 1,
512 rollouts per search, 60 repeated searches per run. Three runs per binary
per workload, alternating binary order. Results are median rollouts/sec.

| Workload | Before | After | Throughput gain |
| --- | ---: | ---: | ---: |
| Default PUCT / heuristic / event boundary | 8,543.9 | 9,541.6 | 11.7% |
| Terminal evaluator / event boundary | 8,374.3 | 9,344.1 | 11.6% |
| Suffix at tick 300 / heuristic / tick boundary | 4,459.7 | 5,172.9 | 16.0% |

Within each matched pair, rollout counts, node counts, maximum depth, and lane
utilization are identical. The suffix uses tick boundaries because the event
boundary at tick 300 has forced actions and bypasses search. These cases preserve
the existing CLI defaults; terminal evaluation still uses PUCT selection.

Raw runs: [staging_optimization.json](staging_optimization.json).
Hardware `perf` counters are unavailable on this host (`perf_event_paranoid=4`),
including outside the sandbox. These are wall-clock measurements, not a sampled
CPU profile. Single-worker gains do not establish scaling across worker counts.

## Correctness and isolated timing

`zig build test -Doptimize=ReleaseSafe` passes. A new oracle test compares every
snapshot word and Mage extra after each action and physics tick, over 1,200 ticks,
16 divergent lanes, and all four spec pairings. Existing impact timing, midflight
snapshot, simultaneous action, and deterministic search tests also pass.

The isolated benchmark prepares 32 states per pairing and restores snapshots
outside timing. It alternates the old and new staging order for 4,000 repetitions
(128,000 SIMD staging calls per implementation per pairing). It verifies full
output state equality against the reference. Three samples per pairing are saved
in [staging_microbenchmark.json](staging_microbenchmark.json).

Median isolated staging speedups are 1.2934x for Warlock mirrors, 1.2459x for
Warlock vs Frost Mage, and 1.2343x for Frost Mage mirrors (23–29% more calls/sec).

## Reproduction

Save the executable before applying the optimization, then build the candidate:

```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/mcts_fight /tmp/mcts_before_staging
# Apply suggestion 1 changes, then:
zig build -Doptimize=ReleaseFast
python3 scripts/profile_staging.py /tmp/mcts_before_staging zig-out/bin/mcts_fight
zig build test -Doptimize=ReleaseSafe
zig run src/staging_benchmark.zig -O ReleaseFast -- --staging-only
```

Future action mechanics that modify physics-only fields or the opponent's owned
fields must update the classification. Keep the full-state oracle tests when
changing action kernels.
