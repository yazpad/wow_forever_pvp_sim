# Learned MCTS pilot — 2026-10-15

Fresh value networks improve some measured fights against bare MCTS. Class-specific models passed the initial fixed-rollout score threshold in one training run, but the complete promotion gate is not met. Equal-time results favor the shared model in this small sample. Keep the normal fight generator unchanged.

## What ran

- New 58 → 16 ReLU → 1 tanh networks and native inference; no legacy neuroevolution code or checkpoints.
- One shared network versus two class networks (Warlock and the currently implemented Frost Mage kit). Both alternatives see both fighters from the acting player’s perspective.
- Learned values mixed 50/50 with the existing heuristic; existing PUCT priors and combat mechanics unchanged. This is an initial value-learning experiment, not a completed RL or AlphaZero loop.
- Teacher: 96 petless, untalented MCTS self-play fights; 12,382 decision states / 24,764 perspective rows. Whole-fight split: 76 training fights and 20 validation fights. One training seed, 17.
- CPU: AMD Ryzen 9 9950X; Zig 0.14.0 ReleaseFast; NumPy 2.5.1, one BLAS thread. One MCTS worker with 16 simulation lanes. Architectures ran sequentially; host affinity and frequency were not pinned.
- Bare control: event-boundary PUCT, heuristic evaluation with 30-tick continuation, depth 128, 60-second timeout. The 256-rollout pilot uses 1,024 nodes for both controllers; the default-budget pet check uses 4,096 nodes.
- Initial distances vary from 5 to 34 m. Primary starts vary each fighter’s HP from 800 to 2,000; full-health checks use 2,000 each. Both controller assignments run for every scenario, retaining A’s opening stagger.

## Fight quality

Every row compares the named architecture with bare MCTS. Score is win=1, draw=0.5; intervals bootstrap complete scenario pairs. Different suites use different scenario ranges, so budget changes and scenario changes are not isolated from each other.

| Suite | Model | Fights | Score | Paired 95% interval |
|---|---|---:|---:|---:|
| Held-out, 256 rollouts | class | 64 | 62.5% | 56.2–70.3% |
| Held-out, 256 rollouts | shared | 64 | 56.2% | 48.4–64.1% |
| Full HP, 256 rollouts, no pets | class | 32 | 68.8% | 56.2–81.2% |
| Full HP, 256 rollouts, no pets | shared | 32 | 59.4% | 50.0–68.8% |
| Equal 5 ms ceilings, no pets | class | 32 | 50.0% | 40.6–59.4% |
| Equal 5 ms ceilings, no pets | shared | 32 | 62.5% | 53.1–75.0% |
| Full HP, normal pets, 1,024 rollouts | class | 16 | 56.2% | 37.5–75.0% |
| Full HP, normal pets, 1,024 rollouts | shared | 16 | 68.8% | 56.2–87.5% |

The primary class result is 40 wins and 24 losses; shared is 36 wins and 28 losses. Neither had draws. The paired class-minus-shared difference is 6.25 percentage points, with a 95% interval of -1.56 to 14.06 points: this does not establish architecture superiority.

Primary scores by ordered character matchup:

| Matchup | Class model | Shared model |
|---|---:|---:|
| frost_mage/frost_mage | 81.2% | 43.8% |
| frost_mage/warlock | 50.0% | 50.0% |
| warlock/frost_mage | 50.0% | 50.0% |
| warlock/warlock | 68.8% | 81.2% |

The measured gains are concentrated in mirrors. Cross-class controller-swapped scores remain 50%, so these results do not establish improved cross-class strategy.

## Value-scale control

A zero-output network with the same 50/50 mixture scored 53.1% (43.8–62.5%) on the primary scenarios. This scales down heuristic Q values and changes PUCT exploration even without learning. Trained class models scored 9.38 percentage points higher, but the paired interval is -1.56 to 20.31 points. The direction is encouraging; attribution to learned information alone remains inconclusive.

## Runtime and storage

Mean time per committed search call, including forced-choice bypasses. Calls and visited states differ between controllers; these are observed workloads, not an isolated causal estimate of inference overhead. Deadline ceilings can overrun by a SIMD batch.

| Suite | Model | Bare mean decision | Learned mean decision | Learned median fight p95 |
|---|---|---|---|
| 256 rollouts | class | 8.99 ms | 8.98 ms | 17.83 ms |
| 256 rollouts | shared | 9.04 ms | 9.49 ms | 19.40 ms |
| Full HP, 256 | class | 11.33 ms | 12.84 ms | 22.29 ms |
| Full HP, 256 | shared | 11.54 ms | 12.40 ms | 22.37 ms |
| 5 ms ceiling | class | 4.13 ms | 3.98 ms | 5.87 ms |
| 5 ms ceiling | shared | 4.41 ms | 4.10 ms | 5.81 ms |
| Normal pets, 1,024 | class | 45.97 ms | 51.54 ms | 78.03 ms |
| Normal pets, 1,024 | shared | 41.89 ms | 49.25 ms | 82.84 ms |

Isolated native inference uses two distinct synthetic perspective inputs per loop, five alternating repetitions, and excludes feature extraction and search:

| Model | Median per prediction | Logical trainable parameters | Checkpoint JSON |
|---|---:|---:|---:|
| class | 0.413 µs | 1,922 | 42,181 bytes |
| shared | 0.213 µs | 961 | 41,660 bytes |

Both variants make two predictions per evaluated leaf. The current bundle format reserves two network slots even in shared mode, so its allocated weight storage is approximately 7.5 KiB for either variant. The shared model has fewer independently trained parameters, not half the allocated storage in this implementation. Synthetic timings need not predict real fight overhead.

Teacher search took 111.1 seconds; recorded teacher fight wall time totaled 111.4 seconds. A repeat fit reproduced both checkpoint hashes exactly and took 0.47 seconds for shared and 0.47 seconds for both class networks combined, excluding interpreter startup. This is small-scale bootstrapping, not the cost of reaching robust production strength.

## Checks and limits

- All 71 ReleaseSafe tests passed, including perspective extraction, snapshot restoration, terminal reward signs, model presence, and zero-mixture root-distribution equivalence.
- Native/Python inference errors were below 0.000002. A 64-example synthetic fit reached MSE below 0.0005. Mismatched simulator fingerprints were rejected.
- No independent training-seed replication yet. Small per-matchup samples and several exploratory comparisons limit statistical claims.
- Class models have twice the logical parameter count. A capacity-matched 32-hidden-unit shared model is still untested.
- Pets were absent from training. The normal-pet check is transfer to unseen pet feature values, not evidence of pet-aware training. It also raises the search budget, so it does not isolate pet effects.
- No custom talent builds, reachable midfight test starts, terminal-rollout control, multiple-worker quality comparison, or trained exploiters yet.
- Current features omit cast identity, detailed build/action availability, and projectile geometry. Add these before broadening training.
- Deadline results are nondeterministic. Repeat them before choosing a deployment latency budget.

## Next decision

Keep both architectures through the next stage. Class-specific models offer a modular starting point, while the equal-time and normal-pet results keep the shared model competitive. Neither architecture has earned an unconditional production recommendation. Expand state features and pet-inclusive training, compare against an equally sized shared model, and repeat across three training seeds. Then add policy priors only if the value-only gains survive these controls.

## Artifacts and reproduction

- [Strategy and commands](../../LEARNED_MCTS_STRATEGY.md).
- [Persistent metrics, configuration, hashes, and command manifests](pilot_summary.json).
- Local raw trajectories, per-fight outcomes/timings, frozen models, and integrity results: `evaluation_runs/value_pilot/` (generated and ignored by Git).
- Arena: `zig-out/bin/learning_arena`; trainer: `scripts/value_learning.py`; sequential comparisons: `scripts/run_value_arena.py`.
