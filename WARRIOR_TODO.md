# Forever Warrior TODO

Implementation checklist. Created 2026-10-21; first foundation pass 2026-10-21.
Target: level-60 Forever PvP, starting with the existing 1v1 arena.

## Current implementation status

- [x] Pin local reference sources with per-file hashes and build metadata;
  document source conflicts and provisional rage assumptions in
  [the source audit](data/warrior_sources/README.md).
- [x] Generate a staged 53-talent tree (17 Arms / 18 Fury / 18 Protection)
  using newer reference layout and generated client base spell IDs.
- [x] Add four-word rank packing, rank/tier/prerequisite/51-point validation,
  and per-lane SIMD decoding; retain unsupported talent ranks without claiming
  their runtime effects work.
- [x] Add isolated SIMD rage/stance primitives: resource caps, effective gains,
  atomic spending, retention, shared stance cooldown and derived modifiers.
- [x] Add reference white-hit rage and explicitly provisional damage-taken rage,
  plus weapon-roll/AP damage primitives.
- [x] Add Lua loader support and regression coverage for the staged Warrior
  trees, prerequisite checks, 51-point cap and talent hash round trips.
- [x] Integrate optional Warrior dynamic columns into mixed-class arenas,
  snapshots, staging and MCTS workers without growing caster-only state.
- [x] Add autonomous main/off-hand swings, queued Heroic Strike (including
  cancellation, deferred costs, white fallback and miss refunds), stance actions
  and Hamstring. Use the existing compact hit/avoid/crit and armor inputs;
  authentic separate PvP dodge/parry/block/facing remains unimplemented.
- [x] Add Charge and Intercept actions using the pinned Forever spell data:
  range/stance/cooldown/rage gates, Improved Charge and Improved Intercept,
  gap closing, Intercept damage and diminishing-return stuns.
- [x] Add Mortal Strike with normalized weapon damage, rank-four base damage,
  stance/rage/range gates, cooldown, miss refund and the 50% healing reduction
  applied to simulated healing for its audited 10-second duration.
- [x] Add rank-seven Rend and Improved Rend scaling with seven periodic ticks,
  Battle Stance gating, miss refund and replay damage attribution.
- [x] Add Overpower with dodge-triggered five-second window, Battle Stance
  gating, rank-four normalized damage, Improved Overpower critical bonus and
  replay damage attribution.
- [x] Integrate Physical mitigation, Inner Fire charges, shield absorption,
  Soul Link damage splitting, cast pushback, Fear/control checks and slow movement.
- [x] Add a headless integration fixture: `zig build warrior-demo -Doptimize=ReleaseSafe`.
- [x] Add two-hand and dual-wield starter presets with explicit weapon/AP inputs,
  strict talent/config validation and editor save/load preservation.
- [x] Enable Warrior selection, all three talent trees, real icons, editable weapon
  stats, red rage bars, stance/swing indicators, queue and Hamstring badges.
- [x] Enable CLI fight generation and Lua/JSON replay playback. Record
  effective main-hand, off-hand, Heroic Strike and Hamstring hits separately.
- [x] Support frozen Warrior configuration and extended snapshots in saved
  counterfactual analysis; preserve legacy caster snapshot and frame types.
- [ ] Enable Warrior neuroevolution through the existing Evolve/Train workflow,
  including champion save/load, Quick Fight, Polished fight and batch evaluation.
  See the explicit neuro integration gates in section 7.
- [x] Add Execute and Pummel to the Warrior action catalog and combat kernel.
  Execute is gated below 20% target health and spends up to 45 rage; Pummel
  interrupts an active cast in Berserker Stance and applies a four-second
  spell lockout. Their source values still need the client parity gate below.
- [x] Add Berserker Rage with its audited 30-second cooldown, 10-second
  fear/incapacitate protection, CC break and Improved Berserker Rage instant
  resource bonus. Improved Berserker Rage movement-impairment removal remains.
- [ ] Add Bloodrage's audited 60-second cooldown, 10 instant Rage and 10
  one-Rage ticks over 10 seconds; Improved Bloodrage scales both. Health cost
  and the triggered regen interaction still need source interpretation.
- [ ] Add the remaining first Arms kit.
  Initial item-based gear is supported; full talent effects remain pending.

See [Warrior setup and playback](WARRIOR.md) for the current workflow.

The first arena pass uses explicit weapon/AP/hit/crit configuration. Warrior
starts with zero mana and gains no mana regeneration. Incoming direct-hit rage is now enabled using the explicitly provisional
reference coefficient and resolved-hit attribution; see WARRIOR.md for its
critical/resistance approximation and opt-out switch. Talent support remains partial; the editor reports support per talent. Flurry
swing haste and off-hand damage/hit/rage talent hooks are now implemented.
Weapon swapping and the other unchecked talent effects remain pending.

Caster-only snapshots retain the exact existing type and 956-byte layout.
Warrior matchups append 60 dynamic bytes per Warrior; immutable configuration
stays outside snapshots and is installed separately in workers. The shared
action count is still 26 and choice capacity is still 63, preserving caster
search-node capacity. [Performance evidence](benchmarks/warrior/README.md) shows
byte-identical compiled caster benchmark code before and after this pass, with
15 timing samples per binary/matchup. Caster tick median changes were −0.68% to
+0.45%; copy median changes were +0.51% to +1.57%, consistent with noise for
identical code. This is a microbenchmark result, not a full MCTS throughput claim.

The detailed entries below remain completion gates for a playable class. Passing
the isolated foundation tests does not establish live-client parity. The older
54-talent inventory included Vitality; the pinned newer reference has 53 and no
Vitality entry. Exclusion is documented and still needs final client signoff.

Validation for the original foundation pass: `zig build test-warrior -Doptimize=ReleaseSafe`
passed 7/7 tests; `zig build test -Doptimize=ReleaseSafe` passed 165/165.
Warrior talent, automatic-action, Priest utility and racial Lua checks passed;
generated data integrity and formatting checks passed. The full regression run
also exposed three stale Priest rollout-test calls and an existing Inner Fire
enemy-dispel merge bug in optimized action staging; both were corrected, and the
existing full-versus-optimized staging regression now passes.

Arena integration validation: `zig build test -Doptimize=ReleaseSafe` passed
175/175 tests, including two-sided swings, shields/armor/Inner Fire, off-hand
rage, queue refunds/cancellation, slow expiry, snapshot continuation/RNG,
simultaneous versus one-sided staging, Soul Link, absorption-aware pushback and
two-worker MCTS. Warrior talent, automatic-action, Priest utility and racial Lua
checks also passed. The UI still does not offer Warrior as a playable class;
ordinary fight recording is now supported. Warrior neural training and champion
policy playback are wired; end-to-end validation and performance gates remain open.
All five standard ReleaseFast executables built successfully. The headless
fixture and raw before/after benchmark observations are saved in
`benchmarks/warrior/`.

## 1. Establish the Forever rules

- [ ] Pin the client build and record sources for each spell/talent: IDs, ranks,
  costs, cooldowns, durations, stance/weapon requirements, coefficients and procs.
- [ ] Audit the local reference against client data; distinguish verified values,
  assumptions, PvE-only behavior and missing PvP behavior. Do not import Vanilla
  or later-expansion mechanics just because their names match.
- [ ] Import all three Forever trees with exact positions, ranks, prerequisites,
  descriptions and icons; validate the level-60 point budget and tier rules.
- [ ] Resolve conflicts between older talent JSON/overrides and the newer client
  audit, including Enrage. Resolve Blood Crazed/Blood Craze naming and IDs.
- [ ] Inventory every baseline and talent ability. Mark each as implemented,
  deferred with a reason, or irrelevant to the current arena; never imply that
  displaying a talent means it works in combat.

Local references (inputs to audit, not automatic authority):

- `~/mythicsim-forever-engine-go/docs/beta-pass/warrior.md`
  (2026-09-17 audit, client build `1.60.1.69893`).
- `~/mythicsim-forever-engine-go/sim/warrior/`, including generated spell data.
- `~/mythicsim-forever-engine-go/tools/forever_talents/data/warrior.json`
  and `overrides/warrior.json` (contain older assumptions).

Reference audit flags to preserve: baseline Tactical Mastery retains 10 rage;
Improved Tactical Mastery adds retention; Spearing Strike is a Forever talent;
Weaponmaster and Dual Wield Specialization have multiple effects; Slam has a
cooldown; Thunder Clap permits Defensive Stance. Verify the audit's values
against the chosen target build before treating them as current rules.

## 2. Class and state integration

- [ ] Add Warrior to spec parsing, serialization, CLI, class selectors and every
  class dispatch, preserving existing class IDs and saved presets.
- [ ] Define explicit warrior configuration and dynamic SoA state: rage, stance,
  main/off-hand swings, queued attack, cooldowns, proc windows and auras.
- [ ] Separate immutable equipment/talent configuration from snapshot state.
  Cover reset, lane copy, MCTS restore, workers and deterministic continuation.
- [ ] Extend the shared action catalog/generator and automatic capabilities for
  baseline, talent, stance, equipment and racial requirements.
- [ ] Audit the current u32 action masks, shared action count, reserved IDs and
  MCTS choice bounds before adding the full spellbook; widen storage if needed.
- [ ] Measure snapshot size and throughput impact; retain aligned SIMD execution
  and avoid per-tick allocations.

## 3. Physical combat foundations

- [ ] Weapon damage ranges, weapon speed, AP scaling, normalized special attacks,
  two-hand/one-hand/dual-wield rules and off-hand penalties.
- [ ] Autonomous main/off-hand swings, initial timing, haste, movement/range
  checks, queued next-swing replacement and cancellation; verify swing resets.
- [x] Distinguish dodge, parry and block in Warrior melee rolls; Overpower opens
  only on dodge, while block value reduces landed damage. Legacy aggregate
  avoidance remains supported as dodge.
- [ ] Complete PvP melee resolution: defense, expertise, weapon skill and
  separate white/special attack rules. Do not apply PvE glancing/crushing rules.
- [ ] Armor mitigation/reduction/penetration, block value, physical damage
  modifiers and bleeds bypassing armor according to verified rules.
- [ ] Facing and behind-target restrictions: either implement positional support
  or document a deliberate arena approximation and its effect on avoidance.
- [ ] Rage cap, initial rage, generation from damage dealt/taken and weapon hits,
  absorption interactions, costs, miss/avoidance refunds and out-of-combat decay.
  Verify formulas and rounding rather than adapting mana regeneration.
- [ ] Battle, Defensive and Berserker Stance: modifiers, switching cooldown/GCD,
  retained rage and ability gating; verify stance changes during CC/casts.
- [ ] Melee damage interacts correctly with shields, Soul Link/pets, Inner Fire
  charges, pushback, damage-breaking CC and defensive/crit-triggered talents.

## 4. Ability checklist

Every entry needs source-checked numbers, legal-action masks, execution,
resource/cooldown behavior and replay attribution. Names below are audit targets;
exact availability and behavior must be confirmed for Forever.

- [ ] Auto Attack / stop attack and Heroic Strike queue.
- [x] Charge and Intercept: stance/range/cooldown/rage gates, rage generation,
  damage and stun diminishing returns. Gap closing is instantaneous to three-yard
  melee distance; continuous travel and collision behavior remain an arena approximation.
- [ ] Hamstring; Piercing Howl; roots from Improved Hamstring.
- [x] Rend: rank-seven bleed, seven ticks over 21 seconds, Improved Rend scaling
  and miss refund. Deep Wounds, refresh/stack behavior and proc eligibility remain.
- [x] Overpower: dodge-triggered window, stance and avoidance rules.
- [x] Mortal Strike: weapon strike and 50% healing-reduction aura with expiry.
  Dispel support remains pending.
- [x] Bloodthirst: rank-four 35% AP + 48 physical damage, 30 rage, six-second
  cooldown, miss refund and 10% movement speed for ten seconds on landing.
  Blood Craze healing and other proc interactions remain pending.
- [x] Whirlwind: Berserker Stance, eight-yard range, 25 rage, ten-second
  cooldown, normalized main-hand attack and Raging Blows off-hand attack.
  Multiple targets remain deferred in the 1v1 arena.
- [ ] Cleave; Sweeping Strikes: single-target behavior and explicit
  deferral of secondary-target effects until a target model supports them.
- [ ] Slam: cast time, movement, pushback, cooldown and Improved Slam swing behavior.
- [x] Execute: 20% health gate, base/extra rage spending and miss refund. The
  current rank-six 600 base + 15 damage per extra Rage model is provisional.
- [ ] Spearing Strike: talent gating and verified weapon/target-type effects;
  defer mounted-target/dismount rules explicitly if mounts are absent.
- [x] Pummel: Berserker Stance, cast interrupt, four-second lockout and cooldown.
  Rank/parity values need client signoff; Shield Bash and shared cooldown rules
  remain pending, as does Improved Shield Bash silence.
- [ ] Bloodrage: immediate/periodic rage and Improved Bloodrage are implemented;
  resolve the health cost and regen interaction before closing this item.
- [x] Berserker Rage: Fear/Horror and Seduction break/immunity, activation while
  feared/incapacitated, 10-second duration, 30-second cooldown and Improved
  Berserker Rage resource bonus. Stun is not broken; root removal chance remains.
- [ ] Battle Shout; Demoralizing Shout; Sunder Armor; Thunder Clap:
  duration, stacking, AP/armor/attack-speed effects and talent changes.
- [x] Death Wish: talent gate, ten rage, three-minute cooldown, 30-second
  duration, 20% physical damage, 5% incoming damage penalty and Fear immunity.
  Horror, Seduction and Polymorph are not Fear.
- [ ] Recklessness; Retaliation: damage/crit/immunity/retaliation,
  incoming-damage penalties, charges and shared cooldowns where applicable.
- [ ] Shield Block; Revenge proc window; Shield Slam including magic dispel.
- [ ] Shield Wall; Last Stand temporary maximum/current-health transitions.
- [ ] Disarm, Intimidating Shout, Concussion Blow: CC categories, DR, breaks,
  immunity interactions and equipment/stat changes.
- [ ] Baseline Victory Rush: verify kill requirement; normally unavailable in a
  fresh 1v1 without a qualifying kill. Do not grant a free opening heal.
- [ ] Audit remaining spellbook: ranged attacks, Taunt, Challenging Shout,
  Mocking Blow and utility. Record PvP relevance and intentional deferrals.
- [ ] Equipment switching: decide supported shield/weapon swap actions, GCD and
  swing/rage consequences; do not silently grant shield abilities with a 2H.

## 5. Full Forever talent inventory

For every talent: confirm client IDs/ranks and prerequisites, implement each
runtime effect, test rank scaling and expose accurate support status in the UI.
The inventory below comes from the local Forever tree and needs the audit above.

### Arms

- [x] Improved Heroic Strike (3 ranks).
- [ ] Deflection (5 ranks).
- [x] Improved Rend (3 ranks; damage scaling implemented).
- [ ] Improved Charge (2 ranks).
- [x] Improved Tactical Mastery (5 ranks).
- [x] Improved Overpower (2 ranks; critical-strike bonus implemented).
- [ ] Anger Management (1 rank).
- [ ] Deep Wounds (3 ranks).
- [ ] Spearing Strike (1 rank).
- [ ] Two-Handed Weapon Specialization (3 ranks).
- [ ] Impale (2 ranks).
- [ ] Bloodthrill (5 ranks).
- [ ] Sweeping Strikes (1 rank).
- [ ] Weaponmaster (5 ranks).
- [ ] Improved Slam (2 ranks).
- [ ] Improved Hamstring (3 ranks).
- [x] Mortal Strike (1 rank; action implemented, healing debuff UI display pending).

### Fury

- [ ] Booming Voice (5 ranks).
- [x] Cruelty (5 ranks; one percentage point of melee crit per rank).
- [ ] Iron Will (5 ranks).
- [x] Unbridled Wrath (5 ranks).
- [ ] Improved Cleave (3 ranks).
- [ ] Piercing Howl (1 rank).
- [ ] Blood Craze (3 ranks; older export: Blood Crazed).
- [x] Boundless Rage (3 ranks).
- [ ] Dual Wield Specialization (5 ranks; off-hand rage implemented, damage/hit pending).
- [ ] Raging Blows (1 rank; Whirlwind off-hand strike implemented, Cleave cost
  reduction pending).
- [x] Enrage (5 ranks).
- [ ] Improved Execute (2 ranks).
- [x] Precision (3 ranks).
- [x] Death Wish (1 rank; damage modifiers and Fear immunity).
- [ ] Improved Intercept (2 ranks).
- [x] Improved Berserker Rage (2 ranks; instant Rage implemented, movement
  impairment removal chance pending).
- [x] Flurry (5 ranks).
- [x] Bloodthirst (1 rank; active ability and movement aura).

### Protection

- [ ] Shield Specialization (5 ranks).
- [ ] Anticipation (5 ranks).
- [ ] Improved Bloodrage (2 ranks).
- [ ] Toughness (5 ranks).
- [ ] Improved Thunder Clap (3 ranks).
- [ ] Last Stand (1 rank).
- [ ] Master of Defense (2 ranks).
- [ ] Improved Revenge (3 ranks).
- [ ] Defiance (3 ranks).
- [ ] Improved Sunder Armor (3 ranks).
- [ ] Improved Disarm (3 ranks).
- [ ] Vanguard (1 rank).
- [ ] Improved Shield Wall (2 ranks).
- [ ] Concussion Blow (1 rank).
- [ ] Improved Shield Bash (2 ranks).
- [ ] Focused Rage (3 ranks).
- [ ] Bastion (5 ranks).
- [ ] Shield Slam (1 rank).

## 6. Gear, stats and race

- [x] Add an initial legal Warrior catalog, weapon/shield metadata and three
  starter inventories with independently checked compact stat totals; preserve
  explicit overrides. See [WARRIOR_GEAR.md](WARRIOR_GEAR.md). Authentic class/race
  baselines, broader item choices and unsupported effects remain below.
- [ ] Resolve Strength/Agility/Stamina, AP, armor, melee hit/crit, weapon skill,
  defense, dodge/parry/block, block value and talent/racial modifiers once.
- [ ] Audit Forever race/class eligibility and melee racial effects, including
  active racials; existing caster-only racial bonuses are insufficient.
- [ ] Save initial rage, stance, weapon setup and precombat buffs explicitly.
- [ ] Create validated Arms, Fury and Protection presets from the audited tree;
  do not assign unverified Vanilla talent strings or call partial builds complete.

## 7. Search, recording and visualizer

- [ ] Integrate Warrior in simulation/search dispatch, observations, legal masks,
  tactical priors, fight analysis and evaluation; audit training model/version
  compatibility if action or observation dimensions change.
- [ ] Expose rage, stance, swing/proc windows, weapon requirements and available
  actions to search. Keep movement independent and support chasing/closing gaps.
- [ ] Check decisions to pool/spend rage, interrupt, stance-switch, use defenses,
  maintain pressure and enter melee; avoid a mandatory scripted rotation.
- [ ] Add rage bars, stance display, weapon/attack animations, talent icons,
  cooldowns, proc indicators and buff/debuff badges to setup and playback.
- [ ] Record swing/special/bleed damage, misses/avoids/blocks/crits, rage events,
  interrupts, healing reduction, stance changes and effective healing/absorption.
- [ ] Version replay additions safely; keep old caster replays readable and use
  class/resource metadata instead of assuming every combatant has mana.

### Warrior neuroevolution and the existing workflow

- [ ] Policy contract: define Warrior observations for rage, stance, weapon,
  swing/queue/proc windows, cooldowns, movement and opponent state; define the
  legal-action mask from the same rules as the simulator.
- [ ] Policy runtime: enable Warrior policy encoding/inference and MCTS rollout
  use; verify movement, action legality and divergent SIMD lanes.
- [ ] Model lifecycle: version observation/action schemas, retain compatibility
  with existing Priest/Warlock models (or reject incompatible files clearly),
  and save/load Warrior champions with class and configuration identity.
- [ ] Arena execution: dispatch Warrior on either side in training and evaluation,
  including mirrors and mixed Priest/Warlock/Mage matchups. Install each side's
  immutable preset/editor configuration and reset rage, stance, swings and other
  Warrior state per episode and worker.
- [ ] Workflow wiring: enable Warrior in the existing Evolve/Train launch path
  using both editor drafts, talent ranks and weapon settings.
- [ ] Fight/evaluation wiring: support Quick Fight, Polished fight and batch
  evaluation with compatible champions, both side assignments and saved replays.
- [ ] End-to-end validation: run a short evolution, save/reload and resume a
  champion, run champion fights and batch evaluation, and cover cancellation and
  failure handling. Remove unsupported-class guards only as each path is proven.
- [ ] Regression and cost check: recheck Priest/Warlock training, model loading
  and evaluation, and compare training/inference throughput before and after.

Planning estimate: a medium-to-large integration, roughly 5–8 focused engineering
days once Warrior combat mechanics and the editor configuration format are stable.
The main cost is the policy observation/action contract and model compatibility,
followed by arena setup/reset and workflow wiring; end-to-end regression and
throughput checks account for the remaining effort. This is an estimate, not a
schedule commitment, and assumes no major redesign of the current neuro runner.

## 8. Validation and completion gates

- [ ] Deterministic mechanics tests on both sides and divergent SIMD lanes:
  rage boundaries/refunds, swing timing/queues, stance retention, armor/avoidance,
  weapon gating, proc consumption, expiry and simultaneous events.
- [ ] CC tests against Priest/Warlock/Mage: Fear versus Horror, roots/slows,
  stuns/DR, interrupt lockouts, dispels, healing reduction and immunity expiry.
- [ ] Snapshot/worker continuation matches uninterrupted simulation with identical
  RNG; no dynamic warrior state leaks between fights or lanes.
- [ ] Golden numerical cases from the pinned client/reference with discrepancies
  explained; distinguish source parity from deliberate arena approximations.
- [ ] Editor save/load, talent validation, capability updates, gear totals and
  replay/UI tests; generated catalog is reproducible.
- [ ] Warrior mirror and both orientations against Priest, Warlock and Frost Mage;
  verify warrior-specific effects with existing pet attacks and defenses.
- [ ] Re-run existing class regressions and appropriate SIMD/MCTS performance
  checks. Compare win rates across seeds; one replay does not prove balance.
- [ ] Produce reviewable replays and document remaining mechanics, approximations
  and unsupported talents before declaring the class complete.

## Suggested implementation order

1. Pin Forever data and resolve tree discrepancies.
2. Add class/configuration, physical attacks, rage and stance state.
3. Deliver a playable Arms slice: swings, Charge/Intercept, Hamstring, Rend,
   Mortal Strike, Overpower, Execute, Pummel and core rage/fear tools, including
   the talents needed by its preset and complete search/editor/replay plumbing.
4. Finish Arms and defensive/utility interactions, then Fury and Protection.
5. Close every talent/ability audit item, validate cross-class behavior and
   measure performance. Clearly label partial support throughout.

## Preset and visualizer pass (2026-10-21)

- `specs/warrior_two_hand.json` and `specs/warrior_dual_wield.json` are explicit
  starter configurations, each with three supported Improved Heroic Strike
  points. They are not full Arms/Fury builds or verified item sets.
- Warrior settings use the `warrior` preset object for weapons, AP, hit/crit,
  starting rage and stance. Talent ranks come only from the three saved trees;
  a second `warrior.build` input is rejected. Invalid rank IDs, tiers and weapon
  combinations are rejected. Empty Lua tree arrays round-trip as empty trees.
- Warrior replay rows append 12 values (columns 125–136), while caster-only
  rows remain 124 values and caster recording frames remain 496 bytes. Warrior
  recording frames are 544 bytes. Search snapshots remain 956 bytes for casters,
  1,028 for a single Warrior and 1,100 for Warrior mirrors after adding
  Charge/Intercept, Mortal Strike, Rend and Overpower state.
- Lane-zero melee telemetry is optional and excluded from snapshots/workers.
  Events use class-local replay IDs 21 (main hand) and 22 (off hand), or the
  actual Heroic Strike/Hamstring/Rend IDs. Shields, mitigation, Soul Link and overkill
  scale effective damage using the existing proportional attribution convention.
- The workspace retains the evolution workflow; Warrior evolution is pending.
  New starter presets do not change the previous default launch pair. Setup
  previews do not display transient actions from a previously loaded replay.
- Validation: 178/178 ReleaseSafe tests; Warrior UI/data, automatic actions,
  Priest utility, gear, racial, combat-log and workspace gear Lua checks passed.
  The real offscreen Love2D test selected both presets, rendered the Arms grid
  and weapon controls, edited an unsaved draft, generated a worker replay fixture, checked
  frozen metadata, replayed damage/rage/stances and resized the window.
- Generated both Warrior-versus-Priest and reverse-side Priest-versus-dual-wield
  replays. The reverse replay contains separate off-hand damage and isolated B
  rage columns. Saved Warrior analysis completed 15 alternatives with two
  continuations and verified the simulator fingerprint.
- The broader existing `test_workspace.lua` still fails in its MCTS-settings
  dropdown-scroll assertions. Its geometry, class/talent, draft and launch
  checks pass before that point; the real GUI Warrior path passes separately.

Screenshots: [setup](benchmarks/warrior/warrior_setup.png),
[talents](benchmarks/warrior/warrior_talents.png),
[playback](benchmarks/warrior/warrior_replay.png).

### Fury implementation continuation (2026-10-22)

Bloodthirst, Whirlwind and Death Wish are available through automatic action
selection, neural training, MCTS and replay recording. Raging Blows adds the
Whirlwind off-hand strike; its Cleave cost reduction is still pending. Cruelty
adds its melee critical chance. Stance/gap-closer tactical priors now favor
closing distance, useful stance changes and preserving rage for specials.
These are soft policy biases, not a mandatory rotation.

`specs/warrior_fury.json` is an explicit 0/31/0 starter preset, not a complete
51-point build or a verified equipment set. Remaining unsupported filler talents
continue to show their support status in the editor.

NEPL v3 appends five Fury observations to the 36 existing inputs. Loading v2
copies its input weights and output layer and sets new input weights to zero.
Retrain Warrior champions for the expanded action set and changed tactical priors.
Caster feature values are unchanged; new caster feature slots are zero.
Warrior snapshots now append 30 dynamic words (120 bytes) per Warrior; the
older size observations above describe earlier implementation passes.
Validation gates above remain open until combat and training runs are requested.

### Capability and cooldown correction

The latest captured user fight exposed a stale class capability whitelist:
Warrior mask 58375 allowed only IDs 0, 1, 2, 10, 13, 14 and 15. The kernel's
extended actions existed but were unreachable through normal launches. Removed
that whitelist and added Warrior talent gates to saved masks and editor action
lists. Charge and Intercept now have replay cooldown indicators, including the
talent-adjusted Intercept cooldown. Existing champions require retraining.

Validation: focused Warrior preset capability regression and Lua Fury editor /
side-specific Intercept cooldown checks passed. Replayed the latest captured
Warrior vs Soul Link Warlock fight with the existing saved champions, exactly
matching captured stats, weapons, Warlock talents, pets and opposing action mask.
Correcting capabilities raised Warrior damage from 142.4 to 2179.7; first melee
changed from 5.89s to 0.01s and Intercept was used at 14.56s with a 20s cooldown.
The Warrior still lost. Fixed replay attribution: preserve action damage records
through the physics tick and stop labelling every pending special as Hamstring.
Bloodthirst, Whirlwind and Intercept now have separate damage events. Comparison
artifacts are under `/tmp/warrior-capabilities-fix`; saved user champions and the
original fight were preserved.

### Fury rage/passive continuation

Implemented Unbridled Wrath, Precision, off-hand damage/hit from Dual Wield
Specialization, Enrage and Flurry. Added direct-hit incoming rage using the
provisional pinned formula, with an explicit disable switch. Incoming spell
payloads retain their resolved critical/resistance values rather than the Go
engine's exact PreOutcomeDamage; grouped physical hits and the provisional
coefficient remain client parity gates. Periodic ticks do not trigger the pinned
OnSpellHitTaken callbacks. Snapshot/reset/copy include 39 Warrior words (156
bytes); caster state has no added columns. NEPL v4 has 44 inputs and accepts v2
and v3 models. Replay counters distinguish incoming and Unbridled Wrath rage.

Added a separate `warrior_fury_passives.json` 0/51/0 mechanics preset with Enrage
and Flurry selected. Existing 0/31/0 starter builds have neither talent; saved
editor drafts and their starter weapon stats remain unchanged.

Validation: all 87 Warrior integration/imported regression checks passed in
ReleaseSafe, including passive hit/damage bonuses, Flurry haste, deterministic
snapshot continuation, divergent-lane incoming rage caps and disabling incoming
rage independently of Enrage. Lua checks covered the 51-point preset, config
switch and buff indicators; ReleaseFast executables built successfully.
Legacy champion replay loading and new rage/passive counters were exercised
under `/tmp/warrior-fury-passives-check`. A two-worker, two-epoch v4 training run
saved/reloaded champions and reproduced its final Pair score exactly in a
112-fight batch evaluation. That short fixture still lost every Warrior fight;
these checks establish mechanics/lifecycle behavior, not class balance. Weapons,
AP and saved user champions were not changed.

### Movement during instant attacks and the GCD

Warrior tactical decisions now follow the reaction timer during the global
cooldown. Legal ability masks still enforce the GCD, so this enables movement
and legal off-GCD choices without allowing attacks early. Caster decision rules
are unchanged. Charge and Intercept now end at three yards and preserve the
requested movement intent; five-yard landings plus a GCD-long pause previously
let the target leave melee before Warrior could react. Neural movement uses learned logits plus overridable positioning guidance.

Neuroevolution update: neural ability and movement guidance is restored as finite,
overridable scores for every class. Legal actions are not tactically excluded.
League opponents and candidates use neural policies; ordinary MCTS is unchanged.

### Rage audit correction (2026-10-22)

- Fixed Bloodrage/Improved Berserker Rage instant rage leaking across SIMD lanes.
- Added the reference's provisional 2x incoming-hit rage during Berserker Rage.
- Made Bloodrage off-GCD, including use during an existing GCD.
- Heroic Strike requires cost to queue; spends/refunds before on-hit rage procs.
- Heroic Strike can proc Unbridled Wrath and consumes Flurry through the
  reference's shared white-hit proc flag; it still grants no ordinary white rage.
- Raw incoming-hit crit/resistance/target-modifier parity remains unresolved.
- No policy, equipment or damage coefficients were changed by this audit.
