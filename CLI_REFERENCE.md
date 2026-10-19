# ⚔️ PVP_SIM Quick Reference & CLI Cheat Sheet

## 1. Quick Cheat Sheet

### 🤖 Spec vs Spec Simultaneous MCTS Engine

New fights give player A a 10 ms opening lead: A can act at time zero, and B becomes ready one physics tick later. Pure Rollout is the default leaf scorer in the CLI, presets, and visualizer: simulations return terminal win/loss/draw outcomes. Use `--evaluator heuristic` to opt into the shorter heuristic evaluation. Cast speeds are unchanged. The opening delay is part of the combat snapshot used by MCTS.
```bash
# Run a fight between Warlock and Frost Mage using MCTS PUCT
./run_fight.sh warlock frost_mage

# Fast preset (1,024 terminal rollouts per decision)
./run_fight.sh warlock frost_mage --fast

# Deep preset (16,384 terminal rollouts per decision)
./run_fight.sh warlock frost_mage --deep

# Generate replay without launching visualizer GUI
./run_fight.sh warlock frost_mage --no-gui --output matches/latest.lua
```

---

### ⚡ Direct `mcts_fight` CLI
```bash
# Direct binary execution with configurable workers and rollout budget
./zig-out/bin/mcts_fight --spec-a warlock --spec-b frost_mage --rollouts 4096 --workers 8 --output matches/latest.lua

# Benchmark MCTS decision throughput (rollouts/sec & ticks/sec)
./zig-out/bin/mcts_fight --spec-a warlock --spec-b frost_mage --rollouts 4096 --workers 8 --benchmark --rounds 5

# Choose autonomous pets, or disable them for a comparison
./zig-out/bin/mcts_fight --spec-a warlock --spec-b warlock --pet-a succubus --pet-b felhunter --output matches/pets.lua
./zig-out/bin/mcts_fight --spec-a warlock --spec-b warlock --pet-a none --pet-b none --benchmark
```

Warlocks default to an Imp; Mages have no pet. `--pet-a` and `--pet-b` accept
`none`, `imp`, `succubus`, `felhunter`, or `voidwalker`. Pets automatically
attack the opposing player and add no MCTS choices. The MVP tracks pet HP,
position, and attack timing, with no mana or pet targeting. Melee pets chase;
the Imp uses a simplified two-second Firebolt cast with immediate damage on
completion. Seduction, interrupts, dispels, sacrifice, pet resummoning, and
Soul Link damage transfer are deferred. Pet stats are simulator tuning values.
The New Fight dialog includes pet selectors, and new replays show pets and HP.

---

### 🎮 2D Visualizer Playback
```bash
# Launch Love2D visualizer to watch saved match
love visualizer matches/latest.lua
```

The visualizer opens in the **Arena workspace (F1)**: select Fighter A or B on the left,
edit Talents, Stats, Pets, or Abilities, and drag either portrait in the arena.
Stat probabilities use 0–1 values; click a value, type its replacement, and press
Enter to apply or Escape to cancel. Abilities automatically lists every supported action available from the current
class, talents, race and active pet. Build changes update the list immediately.
Old saved slot lists migrate to automatic capabilities when opened in the editor;
direct CLI specs retain explicit loadouts unless `automatic_actions` is true.
Fight recordings save action masks for cooldown filtering; older recordings without
capability metadata retain their historical cooldown indicators.
Fight uses the current drafts without saving; Save spec stores a named build.
Completed fights play in the center panel with the existing Arena effects,
telemetry, camera, and timeline controls. Use **Edit positions** to return to the
setup preview or **Playback** to resume the loaded replay. Editing a spec returns
the center to setup automatically. Explicit replay paths open directly in Playback.
Specs and Settings remain visible in both modes; drafts and starting positions
are preserved. Space toggles playback, arrows step, the timeline seeks, the wheel
zooms over playback, and right/middle drag pans. Escape returns to Edit positions.

Arena (F1) is the sole top-level workspace. Fight replays (F2) and Matrix (F4)
expand under Settings, which scrolls independently above the fixed Fight button.
Analysis is hidden for now. F3 and F6 remain workspace shortcuts. The legacy
`--fights` and `--matrix` launch flags open the corresponding Settings section.

For explicit starting positions in the CLI:

```bash
zig-out/bin/mcts_fight --x-a -8 --y-a 4 --x-b 10 --y-b -2 --output matches/positioned.lua
```

Supply all four coordinates, each between -17.5 and 17.5 meters, with at most
35 meters between fighters. Explicit coordinates determine starting distance.
Without coordinates, `--distance` retains its centered horizontal setup. Pets
spawn beside their owner; coordinates are recorded in search metadata.


---

## 2. Key Architecture Details

- **Adversarial Simultaneous Search**: Both fighter actions are selected using tree search (PUCT) at tactical event boundaries (cast completions, GCD resets, defensive triggers, CC changes).
- **Zero Neural / Genetic Bloat**: Pure native Zig SIMD rollouts and tactical heuristics. No external models, training loops, or heuristic bots.

### Fight analysis

Open **Analysis [F5]** for the loaded fight. Select a decision and player, then
choose **Evaluate move** (Enter). Select 8, 16, or 32 starting seeds per move
and 2x, 4x, or 8x the original search rollout budget. The default is 8 seeds,
2x the saved rollout budget (at least 4,096 per decision), and two background
workers. Analysis can take a long time; progress and cancellation are available.

Analysis imports the same combat simulator and MCTS implementation as fight
generation. Every legal action/movement alternative starts from the same
saved state. The opponent's recorded action is held fixed at the initial
branch; **both players use production MCTS for every later decision**, through
the original fight time limit. The original algorithm, evaluator, reaction
boundaries, talents, loadouts, pets and combat state are preserved. Analysis
increases the simulation budget, removes per-decision wall-clock deadlines,
and preserves or increases aggregate tree capacity while using fewer workers.
Search RNGs restart from matched starting seeds for each alternative.

Results show wins, losses, draws, unfinished runs, mean final HP margin, and
a paired score difference against the played move. The report includes the
actual continuation search settings, source fingerprint, and search counts.
These estimates are not a proof of optimal play. Unfinished runs count as
0.5 for the displayed score and are listed separately.

New recordings include a fingerprint of the shared simulator/search source
and Zig version. A fingerprint mismatch rejects analysis rather than silently
using changed mechanics. Legacy recordings have no fingerprint and are clearly
labeled unverified. Exact decision snapshots are used when available; compatible
older files can be reconstructed from their initial state and committed moves.
Saved talent ranks are used directly; edited spec files cannot change analysis.

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fight_analysis --input matches/mcts_custom.lua.search.json \
  --decision 51 --side 1 --samples 8 --budget-multiplier 2 --workers 2 \
  --seed 947 --output /tmp/analysis.json
```

CLI decision indices start at zero; player A is side 0 and B is side 1.
`--rollouts N` overrides the multiplier with an explicit per-decision budget.
The analyzer writes progress beside its output as `.progress.json`. The
visualizer runs it in a separate process and snapshots the input file, so
playback and new fight generation can continue independently.


### Combat probabilities, resistance, and periodic timing

Saved specs loaded with `--spec-id-a` / `--spec-id-b` may include `combat_stats`.
The spec editor's **Combat stats...** dialog edits and saves the same fields.

```json
"combat_stats": {
  "level": 60,
  "spell_hit_chance": 0.96,
  "spell_crit_chance": 0.05,
  "shadow_resist_chance": 0.0,
  "fire_resist_chance": 0.0,
  "frost_resist_chance": 0.0,
  "arcane_resist_chance": 0.0,
  "spell_penetration": 0,
  "shadow_resistance": 0,
  "fire_resistance": 0,
  "frost_resistance": 0,
  "arcane_resistance": 0,
  "pet_hit_chance": 0.95,
  "pet_crit_chance": 0.05,
  "melee_avoidance_chance": 0,
  "armor_damage_reduction": 0
}
```

Hit, crit, full-resist chances, melee avoidance, and armor reduction are fractions
in [0, 1]. School resistance and penetration are raw points in [0, 10000]; level
is an integer in [1, 100]. Unsupported fields (including combat rating inputs),
non-finite values, and out-of-range values are rejected by the simulator.

The **Level 60 example** preset uses the probabilities above. These are editable
simulation assumptions, not verified Forever naked-character or gear-derived
stats. Base/gear probabilities are separate from talent bonuses. Omitted fields
preserve the legacy compact baseline: level 60, 100% owner/pet hit, zero base
crit, resistance, penetration, avoidance, and armor reduction.

`combat_stats.stamina` records total stamina before talents (0–10000; default 0).
`max_health` is health before talents and already includes that stamina's health;
entering stamina does not add it a second time. Gear adds its stamina to this
field and 10 HP per point to maximum health. Demonic Embrace adds another
`stamina × 0.03 × rank × 10` HP (ranks 0–5). This uses the existing compact
10-HP-per-stamina model without integer stat rounding. Legacy specs without
stamina retain their health; the editor recovers gear stamina for old gear saves.
Base/racial stamina is supplied explicitly; verified naked-character baselines
remain pending. Fight previews and replay maximum health include the bonus.
CLI fights start at full resolved health unless `--hp-a` / `--hp-b` is supplied.

Owner direct damage, DoT applications, channel starts, crowd control, and
interrupts now resolve hit/full resist. A failed action still spends mana, GCD,
cooldown, and reagents; failed refreshes leave the old effect and its tick phase
intact. Crowd control and interrupts use binary (all-or-nothing) resistance and
failed effects do not advance diminishing returns. Death Coil is noncritical
and binary. Direct missiles resolve at launch and retain their damage payload.
Conflagrate keeps its existing consumption/preservation rules.

The compact resistance model defines:

```
effective = max(0, target_school_resistance - caster_penetration)
          + 5 * max(0, target_level - caster_level)
mean_resisted = min(0.75, 0.75 * effective / (5 * caster_level))
```

Damage uses a random choice between adjacent 25% resist buckets preserving that
mean; binary effects combine the mean with the explicitly configured full-resist
probability. Penetration cannot remove the level contribution. This distribution
is a simulator approximation, not an authentic Forever resistance table. Level
only affects this resistance calculation; base hit remains an explicit input.
DoT/channel applications use the configured hit/full-resist probabilities once;
landed ticks do not reroll hit/full resist, but do roll partial resistance.

Periodic timing preserves the existing compact-kit durations and base DPS:

| Effect | Duration | Tick interval | Full-duration ticks |
| --- | --- | --- | --- |
| Agony | 18s | 2s | 9 |
| Corruption | 14s | 2s | 7 |
| Immolate | 15s | 3s | 5 |
| Siphon Life | 30s | 3s | 10 |
| Drain Life | 3s | 1s | 3 |

First ticks occur after one complete interval; expiry includes the final tick.
Successful refreshes restart duration and phase. Cancellation, consumption, or
interruption discards unfinished ticks. Corruption's two-second cadence preserves
this simulator's existing 14-second compact spell; these are not level-60 rank
tuning claims. Timers are quantized to 10 microseconds to prevent countdown drift.
Snapshots include DoT timers, natural channel elapsed time, and RNG, with no external scheduler state. Coarse
steps can resolve several separately rolled ticks, but the full combat engine's
movement, interrupts, and cross-effect ordering still use physics-step boundaries.

Eligible ticks crit once per tick (base 1.5x). Malevolence affects Shadow ticks;
Pandemic increases the Affliction critical bonus by 33%/67%/100% at ranks 1/2/3.
Immolate uses Ruin rather than Pandemic. Drain/Siphon healing uses the same crit
and partial-resist multiplier as damage, applied to the kit's existing base HPS;
healing is capped at maximum HP. This preserves the existing healing model,
which does not scale healing down for target shields, Soul Link, or overkill.

Pets use separate hit/crit stats, outcomes, and snapshotted RNG streams; owner-only
Suppression, Malevolence, and Ruin do not apply. Imp Firebolt uses Fire spell
resolution (1.5x crit). Simplified melee pets use hit, defender avoidance, 2x crit,
and defender armor reduction; they do not use spell resistance. Full melee attack
tables, authentic pet stats, and pet Firebolt travel remain separate work.

Fight seeds initialize owner and pet RNG streams. Search continuations restore
those streams from snapshots. Visual replays still do not label individual
crit/miss/full/partial-resist outcomes, and crit-triggered debuffs such as Improved
Shadow Bolt remain separate talent work.


### Cast pushback and resistance

Direct missile impacts (including Immolate's initial hit), Conflagrate, and
autonomous pet attacks can cause pushback. **Periodic DoT/channel ticks never
cause pushback**, including Agony, Corruption, Immolate ticks, Siphon Life, and
Drain Life. Misses, full resists, and fully absorbed direct hits do not qualify.

This simulator uses the Classic-reference sequence: each non-resisted hit pushes
back by 1.0s, 0.8s, 0.6s, 0.4s, then 0.2s for every subsequent hit on that cast.
Normal casts add that amount to remaining time, capped at the original cast
length. For example, a hit 0.1s into a cast can only rewind those 0.1s. There is
no immunity threshold near cast completion, and no automatic immunity after
five hits. Channels subtract the same sequence from remaining duration, capped
at zero. This follows [VMaNGOS's Classic delay sequence](https://github.com/vmangos/core/blob/development/src/game/Spells/Spell.h#L369)
and [cast/channel handling](https://github.com/vmangos/core/blob/development/src/game/Spells/Spell.cpp#L6893),
not the later-expansion two-hit/0.5s rule. Exact Forever overrides are unverified.

The checked-in talent descriptions supply resistance probabilities:

| Talent | Rank 1 | Rank 2 | Rank 3 | Currently eligible casts |
| --- | --- | --- | --- | --- |
| Fel Concentration | 23% | 47% | 70% | Drain Life |
| Intensity | 23% | 47% | 70% | Shadow Bolt, Searing Pain, Incinerate, Immolate |

A resistance roll prevents the whole pushback and does not advance its sequence.
Fear receives neither talent's protection. Resistance is not protection against
an explicit interrupt or crowd control. Future supported drain/Destruction
spells must opt into the applicable talent when implemented.

Channels track natural elapsed time separately from their shortened expiry.
Pushback removes future tail time; it neither grants immediate ticks nor shifts
later ticks earlier. If it ends a channel before the next tick, that tick is lost.
New casts reset their pushback counter and channel phase. Both fields and a
separate per-fighter resistance RNG are preserved in snapshots; fight seeds
initialize the resistance stream.

At a physics boundary, direct impacts resolve before cast completion. Each
projectile slot, then Conflagrate, then the autonomous pet gets its own pushback
check. For shield eligibility, these direct events consume the available shield
before periodic damage; a simultaneous periodic tick cannot make a fully
absorbed direct hit trigger pushback. Existing aggregate HP/shield accounting
remains unchanged. Pet casting pushback is outside the current owner-targeted
combat model.

### Visualizer workspace checks

```bash
lua visualizer/test_workspace.lua
luajit visualizer/test_workspace.lua
# Real GUI events, worker thread and simulator; writes replay/screenshots under /tmp.
zig build -Doptimize=ReleaseFast
SDL_VIDEODRIVER=offscreen ALSOFT_DRIVERS=null love visualizer/tests/repeat_fight
```

The Love2D check runs two fights from unsaved edits, verifies replay metadata,
returns to setup, changes the pet/loadout/position, and runs again. It also checks
resizing and dropdown bounds/dismissal at 960x540, 1280x720 and 2560x1080.
Omit `SDL_VIDEODRIVER=offscreen` to watch the check in a window.

### Pet-dependent Warlock talents

The checked-in Forever Demonic Knowledge (105893) grants spell damage equal to
33%/67%/100% of owner level, rather than scaling from pet stamina/intellect. It
applies while the owner and a summoned demon are alive. Owner school spell power
and pet Firebolt gain the bonus; pet melee does not. Firebolt uses the compact
2/3.5 spell-power coefficient, with Improved Imp and existing pet damage bonuses.
Master Demonologist (105891) grants 2% per rank: Imp Fire damage, Succubus Shadow
damage, Voidwalker physical damage reduction, or Felhunter magic damage
reduction. Effects depend on the active pet, independently of the sacrificed pet
when Demonic Pact allows both. Death removes these bonuses from subsequent
casts/ticks. Missiles retain damage calculated at launch. Search caches retain
only static talents; live pet bonuses are recomputed after snapshot restore.
Pet-targeted attacks and pet Shadow damage spells are not modeled yet. Soul Link
transfers damage after owner mitigation without applying mitigation twice.
