# Beating bare MCTS with learned evaluation

## Objective and decision

The target is the current MCTS implementation, not any legacy genetic champion.
Build a fresh training pipeline; do not reuse historical neuroevolution weights,
model formats, or the old self-play script. Keep combat physics, simultaneous
resolution, legal actions, and tactical decision boundaries identical.

Start with **one value model per class**: Warlock and Mage (currently only the
Frost Mage kit exists). A class model covers its supported builds and all opponents;
it is not a model per talent spec or per matchup. Compare this against one shared
model trained on the exact same trajectories. Do not choose by intuition alone.

For the first pilot, restrict both alternatives to untalented, petless base kits. The production fight CLI defaults Warlocks to an Imp;
this pilot does not cover that default pet configuration. Current
features do not encode talent ranks or action availability, so these models must
not be used to claim competence on custom builds. Later add explicit build features,
cast identity, legal-action masks, pet identity, DR state, and projectile geometry.

## Why a class model can work

Every input is expressed as own fighter / opponent, never implicitly A / B.
Each class model sees both class identities and both combat states. It can learn,
for example, that a Mage's shield changes a Warlock's winning chances. Sharing a
network is optional: the shared model gets those same class indicators; the class
version routes the own-fighter view to the matching class network.

The pilot network is 58 inputs -> 16 ReLU units -> one tanh value, 961 parameters.
Two class models have 1,922 parameters versus 961 for the shared model. This is a
practical architecture comparison, not an equal-total-parameter experiment. A
follow-up shared 58 -> 32 -> 1 network has 1,921 parameters, almost matching the
two class models; compare that before attributing gains to specialization rather
than capacity. Native
JSON bundles reserve two network slots even for shared mode. Both configurations
make two forward passes per leaf:

    learned_value_for_A = (model_A(own_A, enemy_B) - model_B(own_B, enemy_A)) / 2

This produces one zero-sum value even when the two predictions disagree. Death
and combat timeout override learned values. An adjustable mixture with the existing
heuristic limits disruption during the first experiment. A model trained solely
on win/loss/draw should not be described as a calibrated win probability.

## Freeze the control

The initial control is bare PUCT with event boundaries, heuristic evaluation,
30 physics ticks of leaf continuation, one worker, 1,024 nodes, depth 128, a
60-second combat timeout, and a fixed rollout budget. The production default
node cap is 4,096; this pilot uses 1,024 for both controllers. The experiment must
state this difference. Also evaluate terminal-rollout MCTS separately: it is a
stronger/different control, not interchangeable with the default heuristic.

Record the source fingerprint, executable SHA-256, complete command lines, model
hashes, seeds, training splits, and machine information. Models reject a different
simulator/search fingerprint. Do not silently resume after changing mechanics.
Default production fights continue to use the existing evaluator.

## First implementation

- `src/learned_value.zig`: fresh compact native value inference and feature schema.
- `src/mcts.zig`: optional learned evaluator; existing priors remain unchanged.
- `src/learning_arena.zig`: MCTS self-play data and controller-versus-controller
  arena. Each controller searches from the same pre-action snapshot and commits
  only its own side. Neither sees the opponent's selected action.
- `scripts/value_learning.py`: NumPy Adam training, shared/class checkpoints,
  whole-fight validation splits, and paired evaluation summaries.

When policy priors are added, each class's action head should follow the generated
class action catalog and mask the actual legal ability/movement combinations.
Equal numeric action IDs across classes do not imply equal spells. A shared
alternative can use a shared trunk with class-specific action heads; that is a
third architecture to test later, not what this first shared-value pilot measures.

The initial experiment is **value learning only**, not a completed AlphaZero or
PPO implementation. It learns outcomes of the teacher policy; that need not make
it a better search evaluator. Keep negative results and investigate them.

## Simulator and pipeline checks

Before accepting results, run the existing simulator tests, including snapshot
restoration and simultaneous resolution. Add checks for perspective reversal,
terminal reward signs, finite inference, Python/native prediction parity, and
zero-mixture root-distribution equivalence to bare search. Verify identical controllers produce
identical trajectories when exchanging controller labels. Fit a tiny synthetic
outcome dataset as a pipeline sanity check. None of these checks certify all
combat mechanics; inspect failed or suspicious fights before scaling training.

## Training and progression

1. Generate base-kit self-play with MCTS across all four ordered class matchups,
   varied distance and HP, and fixed full-fight outcomes (+1 / 0 / -1).
2. Split by whole fight, stratified by matchup. Do not randomly split adjacent
   frames. Weight each game's trajectory equally so longer fights do not dominate.
3. Train both architectures on the same games, select epochs by validation loss.
   Include a zero-output network control: multiplying the heuristic by a smaller
   factor changes PUCT exploration even without learning. Separate that effect
   from the information in trained predictions.
4. Use a separate tuning scenario range to choose heuristic mixture and budgets.
5. Freeze that choice and evaluate on untouched scenarios. If results inform a
   change, those scenarios become tuning data and a new test set is required.
6. If value-only search improves, add masked policy priors trained on root search
   distributions. Compare value-only, policy-only, both, and network-alone.
7. Iterate self-play against a league of bare MCTS, historical candidates, and
   specialist exploiters. Run multiple independent training seeds.

More data may be necessary: hundreds of correlated states from one deterministic
fight are not hundreds of independent strategy examples. Training against only
oneself is insufficient evidence of robustness.

## Validation and performance

For every scenario run the candidate as A and as B, preserving character states
and the A-opening stagger. Bootstrap complete scenario pairs, not frames or
individual sides. Report wins, draws, losses, score (win=1, draw=0.5), 95% paired
confidence interval, and results per ordered class matchup.

The target is >=55% score against frozen bare MCTS, with the lower 95% interval
above 50%, no major matchup collapse, and replication across at least three
training runs. A small pilot finding is not a promotion certificate. Later test
unseen builds and reachable midfight starts; seed-only base-kit tests are limited.

Measure fixed-rollout strength first to isolate search changes, then compare at
equal per-decision wall-clock limits. Record mean decision latency, tail latency,
complete-fight search time, actual rollout counts, model storage and training cost.
Equal rollouts are **not** equal compute. Deadline runs are nondeterministic and
can overrun by a SIMD batch. Compare both architectures at similar quality as well
as similar compute. The class architecture selects one network per perspective;
it does not inherently double per-leaf inference relative to the shared model.

An exploiter finding a counterstrategy demonstrates a weakness. Failing to find
one does not prove equilibrium or near-optimal play.

## Reproduction

Requires Zig 0.14 and Python with NumPy. Use one BLAS thread for small-network
training. Experiment artifacts are intentionally separate from legacy runs.

```sh
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe
mkdir -p evaluation_runs/value_pilot
zig-out/bin/learning_arena --generate --games 96 --seed 1000 \
  --baseline-rollouts 256 --output evaluation_runs/value_pilot/data.jsonl
OPENBLAS_NUM_THREADS=1 python3 scripts/value_learning.py train \
  --data evaluation_runs/value_pilot/data.jsonl \
  --output evaluation_runs/value_pilot/models --seed 17
zig-out/bin/learning_arena --games 32 --seed 20000 --rollouts 256 \
  --baseline-rollouts 256 --mix 0.5 \
  --model evaluation_runs/value_pilot/models/class.json \
  --output evaluation_runs/value_pilot/class.jsonl
# Repeat the preceding command with shared.json and a different output path.
python3 scripts/value_learning.py summarize \
  evaluation_runs/value_pilot/class.jsonl evaluation_runs/value_pilot/shared.jsonl
```

For equal-time tests add `--ms N` and raise both rollout ceilings sufficiently.
For terminal-baseline controls add `--terminal-baseline` (candidate remains learned).
The arena intentionally has a smaller CLI than the replay generator. It records
trajectory features for training and action hashes for evaluation, not viewer
replays. Replays and arbitrary-build evaluation are follow-up integration work.

Measured results and limitations are recorded in `benchmarks/learning/RESULTS.md`.

Additional measurement commands:

```sh
OPENBLAS_NUM_THREADS=1 python3 scripts/value_learning.py verify \
  evaluation_runs/value_pilot/models/class.json \
  evaluation_runs/value_pilot/models/shared.json --output evaluation_runs/value_pilot
python3 scripts/run_value_arena.py --output evaluation_runs/value_pilot/test \
  --games 32 --seed 30000 --mix 0.5
# Equal-time comparison: a high ceiling and 5 ms per decision for each controller.
python3 scripts/run_value_arena.py --output evaluation_runs/value_pilot/time \
  --games 16 --seed 40000 --mix 0.5 --ms 5 \
  --rollouts 100000 --baseline-rollouts 100000
# Full-health starts preserve the same varying distances.
python3 scripts/run_value_arena.py --output evaluation_runs/value_pilot/full_health \
  --games 16 --seed 50000 --mix 0.5 --full-health
```

The comparison runner executes architectures sequentially to avoid interference
between its own benchmark processes and records binary/model hashes and commands.
Other host activity and different visited states can still affect timings. Use
`learning_arena --microbench --model MODEL --output FILE` for isolated native
inference on an identical synthetic input stream; this excludes feature extraction
and search and is not a prediction of complete-fight runtime.

To check the default Warlock pet and production search budget without retraining:

```sh
python3 scripts/run_value_arena.py --output evaluation_runs/value_pilot/default_control \
  --games 8 --seed 60000 --mix 0.5 --full-health --default-pets \
  --nodes 4096 --rollouts 1024 --baseline-rollouts 1024
```

That is a transfer check, not an in-distribution guarantee: the first training
set contains no pets. A model's unused pet feature weights may be arbitrary.
Varying starting distances still differs from one fixed default 25 m opening.
A confident production claim needs pet-inclusive training and a larger suite.

Training also writes `zero.json` for the value-scale ablation. Reproduce it with:

```sh
python3 scripts/run_value_arena.py --output evaluation_runs/value_pilot/zero_control \
  --games 32 --seed 30000 --mix 0.5 --modes zero
```

This uses the primary held-out scenarios deliberately: it measures the effect of
replacing learned predictions with zero while holding starting states fixed.
