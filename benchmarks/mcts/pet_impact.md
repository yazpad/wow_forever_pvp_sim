# Pet performance investigation

Historical investigation before implementation. The autonomous basic-attack MVP
is now implemented; see `pet_mvp_results.json` for integrated measurements and
`CLI_REFERENCE.md` for behavior and limitations. The synthetic probe below is
retained only as the original inconclusive experiment.

Measured 2026-10-14 on AMD Ryzen 9 9950X, Zig ReleaseFast.

Pets are not implemented in the combat engine. Consequently there is no valid
end-to-end pet slowdown measurement yet. Imp, succubus, felhunter, and voidwalker
will have different costs depending on mechanics and player control.

## Existing baseline

Commands:

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/mcts_fight --benchmark --rounds 3 --rollouts 10000 --workers 1 --spec-a warlock --spec-b warlock --evaluator heuristic
```

Result: 30,000 rollouts in 2.657133 seconds; 11,290.4 rollouts/s;
21,112,603.1 lane ticks/s; 80.34% lane utilization; 7,719,296 reported
search-memory bytes; maximum depth 9. This is one opening-position benchmark,
not an average over fights. It uses heuristic evaluation and event boundaries.
The memory figure is the engine's accounting, not process RSS.

## Where costs enter

* `combat_spec.zig`: 88 SoA columns per duel, 16 independent duels per SIMD
  batch, 10 ms physics steps. Add a pet slot per owner as additional columns;
  pets need not consume SIMD lanes or halve parallel duel count.
* `search_sim.zig`: current snapshot is 396 bytes. Snapshot/restore copies
  combat columns, with three arena buffers per worker. Additional columns also
  enter action staging unless write classification explicitly excludes them.
  Pet effects on the opponent require deliberate merge rules.
* `mcts.zig`: nodes contain two bandits and action choices, not full combat
  snapshots. Pet state alone does not enlarge every tree node. Expanding
  choices does enlarge nodes, paths, distributions, and selection work.

Illustrative state budgets for TWO pets (one per side):

| State per pet | Added bytes per snapshot | Snapshot growth | Added payload in three 16-lane arena buffers per worker |
|---|---:|---:|---:|
| 7 four-byte columns | 56 | 14.1% | 2,688 bytes |
| 16 four-byte columns | 128 | 32.3% | 6,144 bytes |

These are byte calculations, not runtime predictions. The seven-column example
is only HP, mana, attack timer, x/y, CC timer, and cooldown. Full targetable pets
need more state: cast/target information, debuffs, DR, projectiles, and orders.
Column allocation metadata and allocator overhead are excluded.

## Search is the larger design risk

Current choices are capped at 27 per side: nine abilities times three movement
options, with restrictions often reducing the actual number. Joint actions are
sampled using separate bandits and sparse child links, not exhaustively evaluated.

| Control model | Maximum choices per side | Possible action pairs |
|---|---:|---:|
| Current / automatic pets | 27 | 729 |
| Three independent pet commands combined with every player action | 81 | 6,561 |

The second model has nine times as many possible pairs, NOT a demonstrated 9x
runtime slowdown. Fixed rollout budgets instead risk poorer coverage; recovering
decision quality may require more rollouts. Arrays, joint-action encoding, and
the hardcoded factor 27 require changes before this model is supported.
Allowing attacks on enemy pets further expands relevant target choices.

Autonomous attacks should not wake the search at every pet swing or firebolt.
Pet death, important cast starts, and control effects may warrant tactical
boundaries. Their effect on decision frequency must be measured separately.

## Mechanics to budget

* Imp: autonomous cast scheduling, range, resources, and missile travel/collision.
* Succubus: chasing/melee plus Seduction cast/channel, interruption, damage
  breaks, and the appropriate control/DR interactions. The prototype below
  includes only chasing/melee, not Seduction.
* Felhunter: movement/melee plus interrupt/dispel target selection and cooldowns.
* Voidwalker: movement/melee plus defensive commands and pet death/sacrifice.
* All targetable pets: damage routing, status effects, and targeting. Current
  Demonology/Soul Link talents merely scale player damage taken in `spec.zig`;
  actual owner-to-pet damage transfer and pet survival are additional work.

## Exploratory microbenchmark and its limits

```sh
zig run src/pet_cost_benchmark.zig -O ReleaseFast
```

This standalone experiment adds two vectorized pet kernels after existing
warlock physics. Each kernel updates resources/timers and range-gated damage;
the succubus variant also computes 2D pursuit. Six samples of 300,000 batch ticks
per variant rotate execution order. Player HP/activity are refreshed to keep
the physics workload alive. No gameplay code was changed.

The final run produced these ns per 16-duel tick samples:

| Variant | Samples |
|---|---|
| Baseline | 360.959, 356.860, 357.843, 355.813, 361.772, 354.992 |
| Imp prototype | 322.149, 325.305, 320.140, 320.422, 322.746, 320.644 |
| Succubus pursuit prototype | 314.194, 314.941, 312.818, 315.185, 311.582, 314.191 |

The negative incremental costs make this experiment unsuitable for forecasting
pet slowdown. Shared physics and measurement functions did not remove the
anomaly; its cause is unresolved. These numbers do not establish that pets are
free or faster. The fixture is mostly idle combat, omits MCTS, staging,
snapshots, missiles, real pet CC, targetability, and mixed pet/no-pet lanes.

## Recommended implementation and decisive measurement

Start with optional fixed pet slots, SIMD across duels, autonomous basic attacks,
and explicit commands for major abilities. Keep pet decisions separate from the
Cartesian product of every player action where possible. Classify action writes
so physics-only pet state does not unnecessarily enter staging merges. Ensure
all pet state participates in deterministic snapshots and restores.

Then compare pet-disabled, one-pet, and two-pet variants over matched saved
combat positions and seeds. Include imp projectile traffic, succubus control,
pet focus/death, and heterogeneous SIMD lanes. Measure physics, staging,
snapshot/restore, end-to-end rollouts/s, decision count per simulated second,
memory, and search quality at equal wall-clock budgets. Report both fixed-tick
throughput (isolates compute) and full-fight cost (includes changed fight length).
Until this integrated comparison exists, a percentage slowdown would be speculation.
