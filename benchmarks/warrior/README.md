# Warrior arena integration — 2026-10-21

The initial melee arena pass preserves caster-only snapshot size (956 bytes),
action count (26), and maximum search-choice capacity (63). Its optional Warrior
storage has zero size in the legacy mixed-class arena; Warlock mirrors still
use the original arena type. Warrior snapshots append 72 bytes per Warrior:
1,028 bytes for Warrior versus a caster; 1,100 for a Warrior mirror. The three
16-lane staging arenas add 3,456 bytes of dynamic column storage per Warrior per
search worker, plus immutable configuration and allocation metadata. Search
nodes do not acquire Warrior snapshots or additional action entries.

## Caster performance comparison

Built a baseline binary before the arena integration, saved it in `/tmp`, then
built the updated benchmark with the same Zig 0.14.0 ReleaseFast configuration.
After all compilation finished, ran three alternating before/after rounds on
CPU 7. Each binary produces five samples per matchup per round, for 15 samples
per binary/matchup. Raw samples, binary hashes and medians are in
[caster_integration.json](caster_integration.json).

| Caster matchup | Tick ns before → after | Median change | Snapshot + restore ns before → after | Median change |
| --- | --- | --- | --- | --- |
| Warlock / Warlock | 685.07 → 680.43 | −0.68% | 15,028.78 → 15,264.65 | +1.57% |
| Priest / Warlock | 700.84 → 703.96 | +0.45% | 15,150.76 → 15,228.17 | +0.51% |
| Frost Mage / Priest | 647.70 → 650.32 | +0.40% | 15,163.43 → 15,241.75 | +0.52% |

The complete compiled `.text` sections of the two benchmark binaries are
byte-identical. Their shared SHA-256 is:

```text
42ab720a8a49adff478e9cc070bb56cb484a8668a640ec4bdef1fd7a762ea45d
```

For these instantiated workloads, Warrior integration introduces no machine
instructions. The timing differences are consistent with run-to-run noise;
the small positive copy medians do not indicate extra snapshot bytes or work.
This supports expecting no added combat/snapshot-copy cost for caster-only
matches. It is not a measurement of complete MCTS throughput, every combat
scenario, other compiler targets, or the new Warrior matchup's cost.

The physics workload deliberately measures steady casting (initial cast time
1.5s, reset every 1.28s), without projectile impacts. The independent snapshot
workload captures a lane and broadcasts it to all 16 lanes. Checksums and layout
invariants match before/after. The benchmark does not claim whole-fight parity
from a single performance fixture; the combat regression suite covers behavior.

Reproduction for a future change:

```sh
zig build build-class-perf -Doptimize=ReleaseFast
cp zig-out/bin/class_perf /tmp/class-perf-before
# Make the change, then rebuild:
zig build build-class-perf -Doptimize=ReleaseFast
taskset -c 7 python3 scripts/benchmark_class_integration.py \
  --before /tmp/class-perf-before --after zig-out/bin/class_perf \
  --rounds 3 --output /tmp/class-perf-comparison.json
```

The original baseline binary is ephemeral. Preserve it before making the next
change if another before/after comparison is needed. The checked-in JSON
retains the observations and binary hashes for this run.

## Functional validation and staged scope

- `zig build test -Doptimize=ReleaseSafe --summary all`: **175/175 passed**.
- `zig build -Doptimize=ReleaseFast -j2 --summary all`: all five standard
  executables built successfully.
- Warrior talent, automatic-action, Priest utility and racial Lua checks passed.
- Generated Warrior data integrity and Zig formatting checks passed.
- `zig build warrior-demo -Doptimize=ReleaseSafe`: deterministic headless
  Warrior-versus-Priest fixture completed; [fixture.json](fixture.json) records
  its seed and final output. It exercises chasing, Heroic Strike queueing,
  Hamstring, stance changes and caster interactions. It is not a visualizer
  replay, an optimal-policy claim or a class balance comparison.

The arena uses explicit weapon/AP/hit/crit inputs and the existing compact
combined avoidance and armor model. Separate PvP attack-table rules, proc and
per-hit replay attribution, exact pushback ordering for simultaneous hand hits,
incoming-damage rage, swing haste, continuous Charge/Intercept travel, Mortal
Strike dispels, the rest of Arms, gear,
racial integration and item gear remain work items. A later preset/visualizer
pass now supports starter presets, CLI fight generation, playback and
saved counterfactual analysis. Warrior neural training remains disabled.

## Preset/visualizer follow-up

178/178 ReleaseSafe tests pass. The real UI workflow is exercised with:

```sh
SDL_VIDEODRIVER=offscreen love visualizer --test-warrior
```

It captures [setup](warrior_setup.png), [talents](warrior_talents.png) and
[replay](warrior_replay.png), using real fonts, icons, event handlers and the
background fight worker. `lua visualizer/test_warrior_ui.lua` checks preset
round trips, weapon validation, talent support labels and both-side resource
telemetry. Caster recording frames retain their 496-byte layout and 124 output
columns; only Warrior matchups use 544-byte frames and append columns 125–136.
The cast-only snapshot/choice-size guarantees above are unchanged.
