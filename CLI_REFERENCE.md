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
