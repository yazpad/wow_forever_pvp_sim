# Forever Warrior: setup and playback

Run `love visualizer`, choose **Warrior** from either class selector, then load
**Warrior — Two-Hand Starter** or **Warrior — Dual-Wield Starter** from the preset
selector. Open **Gear** to edit weapon damage/speed, attack power, hit/crit,
starting rage and stance. Scroll that panel to reach the remaining fields.
Hit, crit, armor reduction and avoidance use fractions: `0.95` means 95%.

Warrior evolution is not implemented yet, so Warrior presets can be edited
and existing replay files viewed, but cannot use the Evolve/Train workflow yet.
The red replay bar shows rage; the action row shows stance and swing timing.
Melee hits have separate main-hand/off-hand combat-log names and hit effects.

The presets use explicit illustrative stats, not a verified item set. The
supported kit is auto-attacks, Heroic Strike, Hamstring, Rend, Charge, Intercept
and the three stances. Charge and Intercept use the audited 8–25 yard range;
Charge is available in Battle Stance (and Defensive Stance with Vanguard), while
Intercept requires Berserker Stance and 10 rage. Gap closers move directly to
melee range in this arena model. Intercept uses the audited rank-three 65 damage
value. Mortal Strike uses rank-four weapon damage plus 160, costs 30 Rage, and
applies a 50% healing reduction for 10 seconds. Charge and Intercept stuns share
the arena's diminishing-return category.
Rend applies the rank-seven, seven-tick bleed over 21 seconds and uses Improved
Rend's 12%, 23% and 35% damage bonuses. Overpower is available for five seconds
after the target dodges a Warrior melee attack. Separate target dodge, parry and
block chances are configurable in combat stats; block value reduces blocked
hits, and legacy melee avoidance is treated as dodge. Improved Overpower adds
25% or 50% critical chance. Both starters invest three points in
Improved Heroic Strike. All 53 Forever talents are editable, with hover text
showing active, partial or planned support. The remaining abilities and talents,
item gear and Warrior neural training are still pending. Training/champion-policy
controls are disabled for Warrior until that integration is complete.

Generate a short replay directly:

```sh
zig build build-mcts -Doptimize=ReleaseFast
zig-out/bin/mcts_fight --spec-id-a specs/warrior_two_hand.json \
  --spec-id-b specs/disc_priest.json --distance 3 --seconds 8 \
  --rollouts 128 --workers 2 --evaluator heuristic \
  --output matches/warrior_vs_priest.lua
love visualizer matches/warrior_vs_priest.lua
```

Preset JSON stores weapon/resource settings under `warrior`, and talent ranks
under `trees`. Fight snapshots freeze both, including unsaved editor changes.
Lua/JSON replay rows append rage, stance, main swing, queued Heroic Strike,
outgoing Hamstring duration and shared stance cooldown, interleaved A/B, in
columns 125–136. Saved search metadata retains the extended state for analysis.

See [implementation checklist](WARRIOR_TODO.md) and
[performance/validation evidence](benchmarks/warrior/README.md).

Warrior can now use **Evolve/Train**, champion Quick Fight, Polished fight,
and batch evaluation. Training installs both editor drafts, including weapons
and talents, in every worker. Warrior policies use NEPL v4 with 44 inputs, including Fury cooldown/buff
observations. NEPL v2/v3 models load by copying their weights and zeroing the new
input connections; caster observations retain their meanings. Keep champion files paired with the presets used to train them.
Configuration identity is managed by the existing workflow, not embedded in NEPL.

The broader neuroevolution validation and performance gates in WARRIOR_TODO.md
remain open until short training, replay and batch evaluation runs are completed.

The **Warrior — Fury Kit Starter** preset (`specs/warrior_fury.json`) unlocks
Bloodthirst and Death Wish and includes Raging Blows for Whirlwind's off-hand
attack. It spends 31 talent points and retains the dual-wield starter stats.
Cruelty adds melee critical chance to the configured crit value. Several filler
talents are still unimplemented; the talent editor labels them accordingly.

Bloodthirst uses rank-four damage (35% attack power + 48) and grants 10% movement
speed for ten seconds on a landed hit. Blood Craze healing remains pending.
Whirlwind currently attacks only the opposing fighter. Death Wish increases
physical damage by 20%, incoming damage by 5%, and grants Fear immunity for
30 seconds. Horror, Seduction and Polymorph remain separate control effects.

Replay columns 137–146 append interleaved A/B Bloodthirst, Whirlwind and Death
Wish cooldowns, Death Wish duration and Bloodthirst movement aura duration.
Older recordings omit those columns and show no additional active buffs.
Retrain Warrior champions to learn the new abilities and updated stance priors.

Charge and Intercept cooldown indicators use replay columns 147–152: interleaved
A/B Charge remaining, Intercept remaining and talent-adjusted Intercept total.
Intercept is 30 seconds baseline, reduced by five seconds per Improved Intercept
rank. Older replays omit these values and use the baseline cooldown display.

The 2026-10-22 capability fix removes an obsolete starter-only whitelist that
silently excluded Charge, Intercept, rage generators and the extended Warrior
kit from training and fights. Warrior talent gates now also apply to the saved
action mask and editor action list. Retrain champions evolved before this fix:
they learned with only Heroic Strike, Hamstring and stance actions available.

## Fury rage and passives

The **Warrior — Fury Passives** preset (`specs/warrior_fury_passives.json`)
spends 51 points in Fury, including 5/5 Enrage, Flurry, Unbridled Wrath and
Dual Wield Specialization and 3/3 Precision. It keeps the same unnamed one-handed
starter weapons (90–135 at 2.6 speed, 55–85 at 1.8 speed) and 700 AP. It is a
mechanics test build, not a named or verified gear set. Unsupported filler talents
remain marked Planned in the editor. Existing editor drafts are not changed.

Unbridled Wrath has a 12%-per-rank chance on landed white attacks, granting one
rage (two with a two-handed main hand). Heroic Strike can trigger this proc
because its reference proc mask includes the white-hit flag, but it does not
generate ordinary white-swing rage. Queueing requires its rage cost; payment
occurs when the swing executes.
Precision adds 1% melee hit per rank. Dual Wield Specialization adds 5% off-hand
damage, 2% off-hand hit and 20% off-hand white rage per rank.

Melee critical hits refresh three Flurry charges. White attacks (including the
Heroic Strike replacement) consume a charge
before a critical refresh, at most once per 0.5 seconds. Each rank adds 5% swing
haste; white rage still uses base weapon speed. Swing timers store unhasted work,
and replay swing countdowns divide it by current haste. Enrage has a 30% chance
on each direct hit event, granting 2% physical damage per rank for 12 seconds.
Following the pinned Go hooks, periodic ticks do not trigger these incoming-hit
callbacks. Multiple physical specials in one physics step are grouped by hand.

`warrior.damage_taken_rage` defaults to true and is exposed as **Incoming hit
rage (provisional)**. It uses the reference coefficient: `10 * hit / max_health`
(e.g. 1000 qualifying damage at 4000 maximum HP grants 2.5 rage). The factor
still lacks client verification. Physical hit attribution is captured before
armor; spell payloads are already resolved for critical hits and partial
resistance. This is a resolved-hit approximation, not a claim to reproduce the
reference engine's uncritical PreOutcomeDamage/ResistanceMultiplier exactly.
Misses, full resists and periodic ticks grant none. This switch can disable the
provisional incoming model without disabling Enrage or white-hit rage.
Berserker Rage doubles this incoming-hit gain while active, following the pinned
reference assumption. Bloodrage is off-GCD and leaves an existing GCD unchanged.

Replay columns 153–162 append interleaved A/B Enrage duration, Flurry charges,
swing-haste multiplier and cumulative effective rage from incoming hits and
Unbridled Wrath. Old replays omit them. NEPL v4 adds Enrage/Flurry observations
(44 inputs); v2/v3 models load with zero weights for the new input connections.
Retrain to make use of the new mechanics.

Warrior can update movement on its reaction interval while the global cooldown
runs. Instant attacks and stance actions retain their chosen movement; ability
masks still gate GCD-bound attacks. Charge and Intercept use an instantaneous
three-yard landing approximation and preserve movement, leaving room inside the
five-yard attack range to react to a moving target. Neural movement uses learned logits plus overridable positioning guidance.

Neuroevolution update: neural ability and movement guidance is restored as finite,
overridable scores for every class. Legal actions are not tactically excluded.
League opponents and candidates use neural policies; ordinary MCTS is unchanged.

### Rage audit (2026-10-22)

Fixed cross-lane instant rage grants from Bloodrage and Improved Berserker Rage:
each cast now grants rage only to the acting SIMD lane. This matters especially
for league training, where divergent fights share a batch. Also restored the
Berserker Rage incoming-rage multiplier and corrected Heroic Strike queue cost,
Unbridled Wrath eligibility and resource/proc ordering. Heroic Strike consumes
Flurry charges just like the reference white-hit proc mask.

See [rage audit](benchmarks/warrior/reviews/rage_audit_2026-10-22.md) for evidence
and unresolved raw-damage/client-validation limitations.

### Gap-closer presentation

Charge and Intercept portraits ease toward their recorded positions over 0.16
seconds of replay time. This is visual only and follows pause, playback speed
and seeking. Click targets follow the displayed portraits. New replays include
opening positions so first-tick charges animate too; older replays need a frame
before the charge. Combat movement and ability timing remain instantaneous.
