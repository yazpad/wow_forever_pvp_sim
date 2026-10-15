# Autonomous pet MVP

Implemented one fixed pet slot per warlock, independent automatic basic attacks,
HP, 2D position, and an attack/cast timer. No pet mana, commands, or selectable
targets. Every attack targets the opposing player. Pet HP is persistent and zero
HP disables the pet, but no attack currently damages pets. Player death ends the
duel, regardless of surviving pets. Library arenas reset to no pets; the fight
CLI defaults warlocks to an Imp and rejects pets on Mages.

The Imp casts a simplified Firebolt (60 damage, 2 seconds, 30m range); leaving
range cancels the cast and it chases back into range. Damage applies immediately
at cast completion; it does not use player missile capacity. Succubus, Felhunter,
and Voidwalker chase at 7m/s and melee within 3m for 50/40/30 damage every two
seconds. HP is 500/700/900/1200 respectively. These are MVP simulator tuning
values. Utility spells, pet CC, mana, resummoning, and actual Soul Link damage
transfer remain deferred. Owner CC does not stop its pet from acting.

Pet damage shares existing mitigation, shield absorption, fear damage-break
accounting, and simultaneous player damage resolution. Replay event 16 records
pet damage separately; spell ID is pet kind (1 Imp, 2 Succubus, 3 Felhunter,
4 Voidwalker). Replay columns 83–92 (Lua indexing) append kind/HP/x/y/timer per
side after missiles, preserving all existing columns and older replay playback.
The fight dialog exposes pet selection; the arena shows pet positions and HP.

MCTS retains the same 27-choice limit and decision boundaries. Pet state is
included in snapshot/restore but excluded from action staging copies/merges.
There are 12 additional four-byte columns (including damage telemetry), raising
snapshot size from 396 to 444 bytes. Three 16-lane arenas add 2,304 bytes per
worker; tree node and path sizes are unchanged.

## Integrated measurements

AMD Ryzen 9 9950X; ReleaseFast; one worker; warlock mirror opening; 10,000
rollouts per sample, seeds 1/2/3; heuristic evaluator; event boundaries. Execution
order reverses on alternate samples. Medians from `pet_mvp_results.json`:

| Configuration | Rollouts/s | Million lane ticks/s |
|---|---:|---:|
| Previous executable, no pets | 12,438 | 23.88 |
| New executable, pets disabled | 11,708 | 22.34 |
| Two Imps | 13,317 | 20.68 |
| Two Succubi | 12,809 | 21.09 |
| Two Felhunters | 12,376 | 20.63 |
| Two Voidwalkers | 12,055 | 20.62 |

Within the new build, pets reduce lane-tick throughput by about 6–8% and increase
rollout throughput by 3–14%. Combat and search paths differ, so these are not
isolated kernel overheads. Pets can shorten continuations. The new disabled
build also measured roughly 6% lower rollout throughput than the previous
executable in this small sample. No claim of zero overhead or equal search
quality follows from these results. Reported search memory is 7,721,600 bytes
versus 7,719,296 previously. Results are specific to this opening and evaluator.

Reproduce with:

```sh
zig build -Doptimize=ReleaseFast
python3 scripts/benchmark_pets.py
# Optional comparison to a retained pre-pet executable:
python3 scripts/benchmark_pets.py --before /path/to/previous/mcts_fight
```

## Validation

* ReleaseSafe: 50 tests pass, including pet lifecycles, range, cast timing,
  divergent SIMD lanes, owner death, mitigation, shields, overkill, simultaneous
  death, snapshot replay, staging equivalence, and MCTS with pets.
* Eight pet-disabled replay/search comparisons match the prior executable across
  all class pairings and both decision boundary modes; appended pet columns are
  excluded from the old-format frame comparison (`pet_disabled_equivalence.json`).
* Three end-to-end pet pairings produce valid 92-column Lua and JSON replays and
  separate positive pet damage events (`pet_smoke_results.json`). Invalid pet
  names and assigning a pet to a Mage are rejected.
* Lua syntax checks pass for the modified visualizer files. GUI appearance has
  not been visually verified.
* Debug tests also pass (50/50) with `zig build test -Dcpu=baseline`. Native-CPU
  Debug testing encountered Zig 0.14's LLVM error, "Cannot emit physreg copy
  instruction". ReleaseSafe exposed an existing unrelated scalar-lane
  alignment error in Mage telemetry; that access and its regression test are
  fixed as part of this change.

Example replay: `matches/pet_mvp.lua` (Succubus versus Imp).
