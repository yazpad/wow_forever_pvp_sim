# ⚔️ PVP_SIM Quick Reference & CLI Cheat Sheet

## 1. Quick Cheat Sheet

### 🤖 Spec vs Spec Simultaneous MCTS Engine

New fights give player A a 10 ms opening lead: A can act at time zero, and B becomes ready one physics tick later. Cast speeds are unchanged. The opening delay is part of the combat snapshot used by MCTS.
```bash
# Run a fight between Warlock and Frost Mage using MCTS PUCT
./run_fight.sh warlock frost_mage

# Fast preset (~0.3s compute, 1,024 rollouts per decision)
./run_fight.sh warlock frost_mage --fast

# Deep preset (~5.0s compute, 16,384 rollouts per decision)
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
