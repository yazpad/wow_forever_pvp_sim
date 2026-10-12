# Frost Mage

`--class frost_mage` selects a real second combat kit. The default remains
Warlock. This is a small simulator ruleset, independent of retail game patches.
Both classes have 2,000 HP, 1,000 mana, 15 mana/sec regeneration, 7 m/sec advance,
4.5 m/sec kite, a 1-second GCD, and the same 24 → 24 → 9 network and movement head.

| ID | Action | Simulator behavior |
| --- | --- | --- |
| 0 | Idle / Maneuver | Move or stand; stationary casts hold movement |
| 1 | Ice Lance | Instant, 35 m, 30 mana, 100 damage; 300 against a rooted target |
| 2 | Frost Nova | Instant, 10 m, 40 mana, 25 sec cooldown; 4 sec root, separate root DR |
| 3 | Polymorph | 1.5 sec stationary cast, 30 m, 60 mana; 4 sec incapacitate, breaks on HP damage |
| 4 | Frostbolt | 1.8 sec stationary cast, 35 m, 50 mana; 240 damage and 50% slow for 6 sec |
| 5 | Blink | Off GCD, 40 mana, 15 sec cooldown; 15 m toward target if advancing, away otherwise; removes roots and cancels own cast |
| 6 | Ice Barrier | Off GCD and usable while casting, 60 mana, 25 sec cooldown; absorbs 400 damage for up to 20 sec |
| 7 | Counterspell | Off GCD and usable while casting, 30 m, 24 sec cooldown; interrupts an active cast and locks spell actions for 4 sec |
| 8 | Cancel Cast | Cancels an active cast |

Nova roots prevent movement but allow casting; accumulated HP damage of 250
breaks a root. Ice Lance checks the root before its damage breaks it. Polymorph
stops movement and interrupts casting. Root and incapacitate DR have full, half,
quarter, and immune tiers, resetting after 18 sec outside that control effect.
Counterspell on an idle target still consumes its cooldown but applies no lockout.
The simulator uses one spell lockout, rather than separate magic schools.
It blocks the offensive kit and Ice Barrier. Blink, Counterspell, and Warlock
Unending Resolve remain usable during lockout. Blink is blocked by
Fear, Horror, and Polymorph. Polymorph does not regenerate the target's HP.

## Train and evaluate

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/pvp_sim --class frost_mage --train-only --threads 4 \
  --generations 100 --save-champion frost.bin --save-population frost.pop \
  --metrics frost_metrics.json
zig-out/bin/pvp_sim --class frost_mage --train-only --resume frost.pop \
  --generations 100 --save-champion frost.bin --save-population frost.pop
zig-out/bin/pvp_sim --eval frost.bin champ.bin --record-match frost_vs_warlock.lua
love visualizer frost_vs_warlock.lua
zig-out/bin/pvp_sim --class frost_mage --eval-gauntlet frost.bin
```

Evaluation and the model matrix infer each class from its model tag. Legacy raw
`.bin` files are Warlocks; Mage files add an 8-byte versioned `PSIM` header.
Class mismatches fail explicitly. Population checkpoints store the training class
and external opponent class in previously reserved bytes; legacy Warlock
checkpoints remain valid. Use `--class frost_mage` when resuming a Mage population.
The desktop Training Controls tab includes class and external opponent class fields.
Metrics export the correct action names; replays carry class metadata and append
Blink/Nova cooldowns, absorption, and lockout to the legacy frame columns.

For a matchup specialization, seed a new Mage population from its foundation and
train against frozen Warlocks:

```sh
zig-out/bin/pvp_sim --class frost_mage --train-only --seed-from frost.bin \
  --opponent-class warlock --sparring-opponent champ.bin --generations 100 \
  --save-champion frost_vs_warlock.bin
```

Peers and historical champions always use the training class. External sparring
uses the declared opponent class; a sparring directory must contain models of
that class. The same flow also trains Warlocks against frozen Mages. Gauntlet bots
retain their Warlock kits. `--eval-matrix` supports directories containing both
classes, including both directions of each matchup and their bot rows.
Automatic specialist routing and separate cross-class Elo ratings remain roadmap
work; a single training league still reports aggregate Elo.

## Performance design and checks

`ArenaPool(.warlock, .warlock)` returns the original `WarlockArenaPool` type.
Warlock mirrors allocate no Mage combat columns and execute the existing kernel.
Mage pairings are compiled separately. Matchmaking selects a pairing before the
simulation loop; class identifiers, virtual calls, and effect registries never
enter the tick or inference loops. Each SIMD batch contains one class pairing.
Workers retain private arenas and main-thread ordered scoring.

Mage pairings reuse the aligned Warlock state storage. A target's Agony/Corruption
slots represent root/slow if its opponent is Mage; those slots retain DOT meaning
if its opponent is Warlock. This is fixed at compile time, with no per-lane tags.
Ten extra aligned float columns hold Blink/Nova cooldowns, shield absorption,
lockout, and root damage accumulation, adding 640 bytes per 16-duel Mage arena.
Cross-class training allocates a separate 16-duel arena only when needed.

Mage observations preserve the original indices except: 9 = self slow timer,
11/12 = target root/slow timers, 13 = self root timer, 14 = self lockout,
15 = Barrier cooldown, 16 = absorption, 18 = Blink cooldown,
19 = target incapacitate DR, 20 = Counterspell cooldown, 23 = Nova cooldown.
Warlock policies in Mage matchups expose lockout at index 14; Warlock mirrors
retain every original feature. No network dimension or weight layout changes.

```sh
zig build test -Doptimize=ReleaseFast
zig build bench-classes -Doptimize=ReleaseFast
```

The suite covers spell semantics, class-tagged models, checkpoint validation,
recorded-versus-headless combat, mixed-class matrices, aligned storage, and exact
seeded serial/parallel evolution with external Warlocks, bots, and resumed state.
Mage training has the same 20,000 neural duels/sec ReleaseFast floor as Warlock.
The class benchmark reports fixed tick and inference costs separately from actual
CLI league throughput, since class mechanics change duel length. Timed tick setup
is identical across pairings; its rates are not the simple raw-SoA billion-tick
benchmark.

On the Ryzen 9 9950X, five alternating before/after runs per worker count of the
existing Warlock CLI workload (30 generations, 64 agents, 4 duel batches, no
metrics file) produced these medians:

| Threads | Before, duels/sec | After, duels/sec | Change |
| --- | ---: | ---: | ---: |
| 1 | 48,106.5 | 48,268.1 | +0.34% |
| 4 | 179,102.7 | 181,136.0 | +1.14% |

Serial before/after ranges were 47,929–48,668 and 47,919–48,576. Four-worker
ranges were 178,596–182,474 and 179,065–181,693. The ranges overlap; these small
median increases establish no measured slowdown, rather than a reliable speedup.
A 100-generation seeded Warlock champion from the final binary remained
byte-for-byte identical to the pre-change binary. ReleaseFast and ReleaseSafe
suites and desktop training/resume integration passed. Throughput floors alone
do not establish absence of a regression; retain repeated comparisons when
changing these kernels.
