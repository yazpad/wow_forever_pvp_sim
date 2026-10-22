# Forever Priest Implementation Status & TODO

Reference implementation: `~/mythicsim-forever-engine-go/sim/priest/` and `~/mythicsim-forever-engine-go/docs/beta-pass/priest.md`.
Last updated: 2026-10-18.

---

## 1. Completed Architecture & Mechanics

### 1.1 Original SIMD & SoA Design (extended in section 5)
- **`Spec.priest = 2`** added in [`src/spec.zig`](file:///home/aaron-ma/pvp_sim/src/spec.zig) with compile-time `Duel(a, b)` and `ArenaPool(a, b)` specialization in [`src/multi_spec.zig`](file:///home/aaron-ma/pvp_sim/src/multi_spec.zig) and [`src/search_sim.zig`](file:///home/aaron-ma/pvp_sim/src/search_sim.zig).
- **Original implementation reused existing snapshot storage:** Reuses existing 64-byte aligned `WarlockArenaPool` and `extras` SoA columns so `Snapshot` size and MCTS lane copy/restore speed are 100% preserved:
  - Target debuffs (`!side_a`): `agony_timer` (Shadow Word: Pain), `corruption_timer` (Devouring Plague), `immolate_timer` (Holy Fire DoT), `siphon_timer` (Vampiric Embrace), `fear_timer` (Psychic Scream).
  - Self state (`side_a`): `shadow_lockout` (Renew HoT timer), `soul_link` (Inner Focus active flag `u32`), `fire_lockout` (Inner Focus 180s CD), `conflagrate_cd` (Penance 12s CD), `shadowburn_cd` (Shadow Word: Death 15s CD), `death_coil_cd` (Mind Blast CD), `seduction_cd` (Silence 45s CD), `seduction_cast` (Vampiric Embrace 60s CD), `action6_cd` / `action6_dur` / `extra(.shield)` (Power Word: Shield CD, duration, absorb), `extra(.nova)` (Psychic Scream CD), `extra(.blink)` (Devouring Plague 60s CD), `extra(.lockout)` (Spell lockout), `soul_shards` + `shadow_flame_timer` (Shadow Weaving stacks 0..5 and 15s duration), `conflagrate_pending` (Shadow Word: Death queued immediate damage).
- **16-wide SIMD Talent Decoder ([`src/priest_talents.zig`](file:///home/aaron-ma/pvp_sim/src/priest_talents.zig)):**
  - Branchless `@Vector(16, u32)` -> `@Vector(16, f32)` bitfield unpacking of 31 Priest talents from `u64` (`talent_ranks` low 32 bits, `talent_flags` high 32 bits, zero cross-word splitting).
- **Action Catalog & Codegen:**
  - Updated [`visualizer/data/action_catalog.json`](file:///home/aaron-ma/pvp_sim/visualizer/data/action_catalog.json) and [`scripts/generate_action_catalog.py`](file:///home/aaron-ma/pvp_sim/scripts/generate_action_catalog.py), generating [`src/action_catalog_generated.zig`](file:///home/aaron-ma/pvp_sim/src/action_catalog_generated.zig) and [`visualizer/action_catalog.lua`](file:///home/aaron-ma/pvp_sim/visualizer/action_catalog.lua) with all 20 Priest actions (`0..19`).
- **Full 53-Talent Forever Tree Data:**
  - Created [`visualizer/data/talents_priest.json`](file:///home/aaron-ma/pvp_sim/visualizer/data/talents_priest.json) with all 53 Forever Priest talents across `Discipline` (18), `Holy` (17), and `Shadow Magic` (18) with exact client spell IDs (`106150..110858`), grid positions, prerequisites, and descriptions.
  - Added canonical specs (`shadow_priest`, `disc_priest`, `smite_priest`) in [`src/spec.zig`](file:///home/aaron-ma/pvp_sim/src/spec.zig) and preset JSONs [`specs/shadow_priest.json`](file:///home/aaron-ma/pvp_sim/specs/shadow_priest.json) (`14/0/37`) and [`specs/disc_priest.json`](file:///home/aaron-ma/pvp_sim/specs/disc_priest.json) (`31/20/0`).

### 1.2 Implemented Spells & Talents ([`src/priest_combat.zig`](file:///home/aaron-ma/pvp_sim/src/priest_combat.zig))
- **Shadow Spells:**
  - `Shadow Word: Pain` (Action 1): Instant 18s..24s DoT (`Improved SW:P`), 3s ticks, can crit in Forever (`Darkness` 200% crit multiplier), procs `Shadow Weaving`.
  - `Devouring Plague` (Action 2): Instant 24s DoT, 60s CD, 3s ticks, 100% leech healing, `Devouring Contagion` mana reduction (-15%/-30%).
  - `Psychic Scream` (Action 3): Instant 8m Fear (4s PvP duration), Fear DR tracking, `Improved Psychic Scream` cooldown reduction (-2s/-4s).
  - `Mind Blast` (Action 4): 1.5s cast, 8s..5.5s CD (`Improved Mind Blast`), direct Shadow projectile, procs `Shadow Weaving`.
  - `Mind Flay` (Action 5, talent-gated): 3s channel, 1s ticks, 50% movement slow, `Improved Mind Flay` (+5%/+15% dmg), `Shadow Reach` range.
  - `Silence` (Action 7, talent-gated): Off-GCD 20m interrupt + 5s spell lockout.
  - `Vampiric Embrace` (Action 8, talent-gated): Instant 30s debuff, 60s CD, heals Priest for 20% of all single-target Shadow damage dealt.
  - `Shadow Word: Death` (Action 9): Instant Shadow nuke, 15s CD, `Early Demise` (+15%/+30% crit bonus when target `<= 20%` HP), 10% maximum-health cost if target survives.
- **Discipline & Holy Spells:**
  - `Power Word: Shield` (Action 6): Instant absorb shield (`Improved PW:S` +7%/+14%/+20%, `Twin Disciplines` +1..5%), `Soul Warding` (-4s CD to 11s, -15% mana).
  - `Flash Heal` (Action 11): 1.5s cast heal, `Renewed Hope` (+2%/+4% crit on shielded self), `Divine Aegis` (5%/10%/15% of critical heal added to shield), blocked in Shadowform.
  - `Renew` (Action 12): Instant 15s HoT, 3s ticks, `Improved Renew` (+5%/+10%/+15%), blocked in Shadowform.
  - `Holy Fire` (Action 13): 3.5s..3.0s cast (`Divine Fury`), direct Holy damage + 10s DoT (2s ticks); allowed in Shadowform per Forever `talents.go`.
  - `Smite` (Action 14): 2.5s..2.0s cast (`Divine Fury`), direct Holy damage, `Power in Light` (+3..15% damage while Holy Fire DoT is active on target); allowed in Shadowform.
  - `Penance` (Action 15, talent-gated): 2.0s channel (1s ticks), 12s CD, benefits from `Searing Light` and `Power in Light`; blocked in Shadowform.
  - `Inner Focus` (Action 16, talent-gated): Off-GCD buff (180s CD), next spell costs 0 mana and gains +25% crit chance.
- **MCTS, CLI, Analysis & Visualizer:**
  - Wired `.priest` into [`src/mcts.zig`](file:///home/aaron-ma/pvp_sim/src/mcts.zig), [`src/mcts_main.zig`](file:///home/aaron-ma/pvp_sim/src/mcts_main.zig), [`src/learned_value.zig`](file:///home/aaron-ma/pvp_sim/src/learned_value.zig), [`src/fight_analysis.zig`](file:///home/aaron-ma/pvp_sim/src/fight_analysis.zig), and visualizer Lua files ([`visualizer/talents_data.lua`](file:///home/aaron-ma/pvp_sim/visualizer/talents_data.lua), [`visualizer/spec_editor.lua`](file:///home/aaron-ma/pvp_sim/visualizer/spec_editor.lua), [`visualizer/workspace.lua`](file:///home/aaron-ma/pvp_sim/visualizer/workspace.lua), [`visualizer/class_view.lua`](file:///home/aaron-ma/pvp_sim/visualizer/class_view.lua), [`visualizer/unit_frames.lua`](file:///home/aaron-ma/pvp_sim/visualizer/unit_frames.lua)).

---

## 2. Damage sanity audit (2026-10-17)

Compared the combat kernels with the local reference engine's priest spell data
(beta client 1.60.1.69893). Corrected these damage discrepancies:

| Spell | Previous | Corrected |
| --- | --- | --- |
| Mind Blast | 220 base | 490.5 average of the reference 477–504 range |
| Mind Flay | 65 per tick; no crits | 130 per tick; can crit; 0.167 spell power per tick |
| Shadow Word: Death | 190 base | 458 at level 60 |
| Penance | 390 base + 0.570 spell power total | Three 131-damage bolts + 0.855 spell power total |

Regression coverage checks all four spells from either side with zero spell
power, 400 spell power, and guaranteed critical strikes. Existing priest tests
were updated to use the current talent values and preserve immutable talent
configuration when comparing reset arenas. Mind Flay's slow is implemented in
`multi_spec.zig`'s shared movement path.

This is still a compact arena kit: mana costs, GCD, some base damage/healing and
shield values differ from the reference. Holy Fire's rank-eight damage, mana cost, and cast time now match the local
reference (see section 9). PW:S now includes
its client-data 0.10 spell-power coefficient, and SW:D now costs 10% maximum
health when its target survives. The SW:D health cost bypasses absorption and damage mitigation. Penance now delivers three separately resolved bolts at channel start, 1s, and
2s; cancellation removes only the remaining bolts. The opening bolt resolves on
the first physics tick (10ms for recorded matches).
The unimplemented talents below also mean a displayed 51-point build is not yet
a fully simulated 51-point build.

---

## 3. Remaining Forever Priest Talents & Spells TODO

### 3.1 Proc & State Talents (Requires Aura/Timer Tracking)
- [x] **Power Infusion** (`Discipline`, `106154`, 1 rank): 15s buff (+20% spell damage & healing, 3min CD).
- [ ] **Enlightenment** (`Discipline`, `106156`, 5 ranks): +2%/rank Stamina, Intellect, Spirit stat multiplier.
- [ ] **Focused Casting / Martyrdom** (`Discipline`, `106163` / `106161`): 6s buff after receiving a critical strike granting pushback immunity and -10%/20% interrupt duration.
- [ ] **Blessed Recovery** (`Holy`, `106194`, 3 ranks): 6s HoT after taking a melee/ranged critical strike healing 8%/16%/25% of damage taken.
- [ ] **Surge of Light** (`Holy`, `110851`, 3 ranks): Spell criticals have 10%/20%/30% chance to make next Smite or Flash Heal instant and mana-free (cannot crit).
- [ ] **Spirit of Redemption** (`Holy`, `106196`, 1 rank): +5% Spirit and upon death 10s angel form.
- [ ] **Lightwell** (`Holy`, `106199`, 1 rank): Summons Lightwell.
- [x] **Blackout** (`Shadow Magic`, `106187`, 5 ranks): 2%/4%/6%/8%/10% chance on Shadow spell hit to stun target for 3s (shares stun DR).
- [ ] **Mind Melt** (`Shadow Magic`, `110856`, 2 ranks): Mind Flay periodic ticks increase next Mind Blast crit chance by 2%/4% per stack (up to 6 stacks) and reduce Mind Blast mana cost when SW:P is active.
- [ ] **Shadowmend** (`Shadow Magic`, `106173`, 3 ranks): Direct Shadow hits on targets afflicted by SW:P heal the Priest for 10%/20%/30% of a SW:P tick (3s ICD).
- [ ] **Misery** (`Shadow Magic`, `110857`, 5 ranks): SW:P, Mind Flay, and Vampiric Embrace apply +1..5% spell hit taken debuff on target.
- [ ] **Harnessed Shadows** (`Shadow Magic`, `110858`, 2 ranks): In Shadowform, reduces critical strike chance of attacks made against the Priest by 2%/4% and causes Devouring Plague to generate 50%/100% less threat.

### 3.2 Additional Baseline Priest Spells
- [x] **Dispel Magic:** Separate self/enemy actions remove up to two eligible magic effects.
- [ ] **Abolish Disease:** Immediate disease removal plus periodic cleansing remains unimplemented.
- [x] **Mana Burn:** 3s base cast (2.5s/2s with Improved Mana Burn), drains up to 767 mana and deals Shadow damage based on 50% of actual mana burned.
- [x] **Healing spell mana costs:** Level-60 PW:S, Flash Heal, and Renew costs audited against the local Forever client table (section 12).
- [x] **Inner Fire:** Self-cast rank-6 armor buff with a 10-minute duration and 20 charges. Landed modeled pet melee hits consume a charge; enemy Dispel Magic removes the aura. Forever's checked client tooltip lists armor and charges, with no spell-power bonus.
- [ ] **Fear Ward:** Baseline for every Priest in Forever; implement separately from race spells (section 10).
- [ ] **Priest racial spells:** Twelve spells across six races; sourced inventory and implementation checklist in section 10.
- [ ] **Weakened Soul:** 15s (11s with Soul Warding) per-target debuff if multi-unit / team arenas are added (in 1v1, identical to PW:S cooldown).

### 3.3 Visualizer & Match Recorder Polish
- [x] Record and display Priest-specific buff/debuff icons in `src/match_recorder.zig` and `visualizer/unit_frames.lua` (Renew HoT badge, Inner Focus badge, Shadowform badge, Shadow Weaving stack counter).
- [x] Add custom Priest sprite/projectile colors in `visualizer/main.lua` (Holy gold for Smite/Holy Fire/Penance, Shadow purple tendrils for Mind Flay/Mind Blast/SW:D).

## 4. Priest replay attribution and channel timing (2026-10-17)

- Added optional lane-zero recording output outside combat snapshots, enabled
  only for fight recording. Search rollouts retain the existing snapshot format.
- Priest periodic damage is recorded under SW:P, Devouring Plague, Holy Fire,
  Mind Flay, or Penance instead of being grouped under SW:P. Absorption and
  overkill use the same proportional attribution convention as projectiles.
- Flash Heal, Renew, Devouring Plague, and Vampiric Embrace emit effective healing
  events, including when incoming damage on the same tick exceeds healing.
- SW:D backlash emits a self-damage event instead of being credited to the
  opponent. Self spells and Flash Heal cast events target the priest in replays.
- Penance has an opening bolt and two subsequent one-second bolts. Regression
  tests check both sides, cancellation, and simultaneous healing/damage.

Missing talents and tactical search choices remain separate work. Existing replay artifacts are not rewritten; generate a fresh fight to see
the corrected events.


## 5. Priest parity pass (2026-10-17)

- Shadow and Discipline presets now contain validated Priest equipment and
  resolved stats (2,530 health, 2,695 mana, 348 Shadow power). Robe of Winter
  Night replaces the Warlock-only Robe of the Void; manual stat overrides and
  explicit equipment remain preserved. New Priests and older bare presets also
  receive valid starter gear in the editor.
- Blackout decodes 2% per rank, up to 10%, on landed Shadow damage events,
  including periodic/channel damage. It interrupts casts, freezes movement and
  has a separate stun DR category (3s, 1.5s, 0.75s, immune; 18s reset after the
  stun ends). The event eligibility follows the compact kit's Shadow damage
  model; a Forever combat-log audit of application-versus-periodic procs remains
  desirable. Replay columns 109/110 show stun timers, with a Blackout badge/event.
- Shadow Reach adds 10%/20% range to targeted offensive Shadow spells. Psychic
  Scream retains its 8m radius. Existing Improved Mind Flay range is multiplied
  by Shadow Reach.
- PW:S includes the 0.10 coefficient from the local beta client spell table,
  before shield talents. Other compact base values/costs remain unchanged.
- SW:D's health cost is 10% maximum health after outgoing damage resolves,
  with no health cost for a miss or killing blow. Shields cannot absorb it and
  it is recorded as self health loss.
- Will of the Forsaken is selectable (action 20), usable during Fear/Charm,
  costs no mana, has a 120s cooldown and 1.5s GCD, and clears those effects.
  It does not clear Horror, stun or Mage Polymorph or grant lasting immunity.
  See RACIALS.md for verified sources.

The two original talent words retain their layout; a third immutable word stores
Blackout and Shadow Reach. It is excluded from snapshots and copied to workers.
Six dynamic stun/DR columns (two sides) add 24 bytes to Snapshot. This supersedes
the earlier zero-growth claim above; the separate category prevents stuns from
sharing Horror or Fear timers. Existing search fingerprints change accordingly.

For an exact equal-stat comparison with the latest Warlock, load
`specs/shadow_priest_equal_stats.json` (2,670 HP, 2,515 mana, 354 Shadow power).
This temporary preset uses explicit matched stats, including final crit chance,
rather than claiming a physical equipment set with those totals.


## 6. Priest utility actions (2026-10-17)

- Added Power Infusion (21), Dispel Magic (Self, 22), Dispel Magic (Enemy,
  23), and Mana Burn (24) to the shared action catalog, editor, search masks,
  tactical priors, and replay attribution. Existing action IDs stay stable.
- Power Infusion's talent point now loads from the Discipline preset and canonical
  build. It is off-GCD, costs 20% of the compact engine's 1,000 base mana, lasts
  15s, and has a 180s cooldown. Dynamic damage/healing gain 20%; absorption does
  not. Two dedicated columns per side preserve its timer/cooldown in snapshots.
  Replay columns 111/112 show duration and 113/114 show cooldown.
- Rank-two Dispel removes up to two eligible auras in deterministic priority order.
  Self dispel removes magic DOTs and movement effects according to the opponent
  class; it preserves Warlock curses and Priest diseases. Enemy dispel removes
  shields, Power Infusion, Renew, and Inner Focus. Shield/PI cooldowns remain.
  It costs 18% base mana before Mental Agility and uses a 1.5s GCD
  (the original hardcoded 180 mana was corrected in section 13).
  Offensive dispel rolls spell hit. Per-aura dispel resistance and random aura
  selection remain unimplemented; no unmodeled Warlock buffs are invented.
- Mana Burn follows the local beta client table: 270 mana, 30m range, 3s cast,
  up to 767 mana burned, damage based on half of actual resource loss.
  Improved Mana Burn reduces cast time by 0.5s per rank. Completion checks
  range/hit; cancellation cannot drain mana. Normal shields/mitigation apply
  to damage, while resource loss bypasses absorption.
- New actions have tactical priors; Inner Focus receives more search priority.
  This does not enforce a rotation or establish that shield timing is optimal.
- Pain Suppression is excluded from this roadmap: it was introduced in TBC
  and is absent from the checked-in Forever talent tree and local reference
  Priest implementation. The earlier TODO entry was unsupported; do not add
  it without explicit Forever source evidence.
- Other remaining kit gaps include Abolish Disease, Greater Heal,
  Holy Nova, Priest racial spells, and the unchecked proc talents above.

The editor previously exported only 13 configurable spells, truncating larger
loadouts. It now holds 23, fits the bar to available width, preserves all old
configured slots during migration, and packs unlocked spells into new builds.
The checked-in Priest loadouts include the new baseline utility spells and
Discipline includes Power Infusion. Existing custom loadouts preserve their
selections; add new spells through the editor or reload an updated preset.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed all
138 tests. `lua visualizer/test_priest_utility.lua`, `test_racials.lua`, and
`test_gear.lua` passed. Zig 0.14's debug LLVM backend crashes with
`Cannot emit physreg copy instruction`; ReleaseSafe and ReleaseFast compile.
The broader workspace UI test stops at its scrolling assertion (line 212),
also reproduced with the original slot count/default packing restored in a
temporary module; that unrelated test failure remains open.

The generated search-choice capacity remains 63: the conservative largest
class bound is 59 after accounting for stationary casts and unused catalog
IDs. This avoids increasing every node to 75 entries and exceeding the
existing 32-worker/512 MB configuration solely because the catalog grew.

Fresh validation replay: `matches/priest_utility_vs_soul_link.lua` (+ JSON and
search metadata). Preserved both fighters' original recorded stats and the
original Warlock talents/pet, with 16,384 rollouts, 32 workers, and 512 MB.
Priest won at 33.14s, used PI/Inner Focus at the opener, and shielded at 3.76s
and 18.08s. One deterministic sample demonstrates availability and integration,
not optimal tactics or a matchup win rate. ReleaseFast binaries are installed
in `zig-out/bin` for the visualizer.


## 7. Priest replay aura badges (2026-10-18)

- Fresh recordings append columns 115–124 as A/B pairs: Renew duration,
  Inner Focus active, Shadowform active, Shadow Weaving duration, and stacks.
  Both JSON and Lua exports preserve every existing column. These fields are
  recording-only and do not enlarge combat snapshots.
- Unit frames display all four auras, including the Shadow Weaving stack count.
  Buffs have their own row below debuffs to avoid overlapping cooldown icons.
  Permanent/consumable buffs have no countdown; expired Weaving stacks are hidden.
- Older recordings omit these optional fields and remain readable. Generate a
  fresh replay to see these badges; missing historical state is not inferred.

Validation: ReleaseSafe tests passed (139/139). Priest utility/aura, racial,
and gear Lua checks passed. Regression coverage includes recorded column
positions, independent A/B state, inactive stacks, and older replay frames.


## 8. Priest replay spell colors (2026-10-18)

- Priest combatant tokens use an ivory/gold tint. Smite, Holy Fire, and Penance
  use gold damage text, missiles, and impact colors; Shadow spells use purple.
- Mind Flay has animated purple tendrils and Penance a gold channel effect.
  Class-scoped action routing keeps the green Drain Life beam exclusive to
  Warlocks, including in older recordings. Modern recorded missiles and legacy
  hit-triggered visuals share the spell palette.
- Shared effects live in `visualizer/spell_visuals.lua`.

Validation: Lua syntax checks and the existing Priest utility/aura, racial, and
gear checks passed. Headless effect checks covered class/action routing, Holy
and Shadow palettes, channel geometry, zero-length channels, and line-width
restoration. An interactive Love2D visual review was not performed.


## 9. Holy Fire mechanics pass (2026-10-18)

- [x] Correct rank-eight Holy Fire against the local Forever reference:
  `sim/priest/holy_fire.go` and `sim/priest/spell_data_auto_gen.go`
  (beta client 1.60.1.69893, spell 15261).
- Base cast is 3.5s, reduced to 3.0s by five ranks of Divine Fury;
  mana cost is 255 before existing Mental Agility/Inner Focus modifiers.
- Direct damage uses the average of 184–232 (208), plus 0.75 Holy power.
  Five noncritical ticks at two-second intervals each deal 15 plus 0.05
  Holy power. The prior 18 DPS incorrectly dealt 36 base damage per tick;
  the corrected base is 7.5 DPS. The periodic coefficient was already correct.
- Regression coverage checks both sides, baseline/max Divine Fury, mana spent,
  no damage before cast completion, zero/400 Holy power, guaranteed direct
  critical strikes, all five noncritical ticks, and debuff expiry.

The generated client table marks periodic crit capability, but the reference
Holy Fire implementation explicitly resolves `OutcomeTick` (noncritical).
This pass follows that implemented behavior; changing tick crits requires a
separate source/mechanics decision. Other compact-kit spell costs and base
values remain unaudited where noted above.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed
140/140 tests. Formatting checks passed for all four touched Zig files.


## 10. Forever Priest racial spell roadmap (researched 2026-10-18)

Fear Ward and Devouring Plague are baseline at level 20. Each Priest race
instead has the following pair. The descriptions below follow Blizzard's
[Priest/Warrior deep dive](https://news.blizzard.com/en-us/article/24301514/world-of-warcraft-forever-class-deep-dives-priest-and-warrior).
“Unchanged” is Blizzard's description, not verification of current rank values.

| Race | TODO spell | Announced behavior |
| --- | --- | --- |
| Dwarf | [ ] Desperate Prayer | Unchanged. |
| Dwarf | [ ] Chastise | Humanoid damage/root (2s); instant; 120s cooldown. |
| Human | [ ] Divine Grace | Ally-only heal below 50%; clears Weakened Soul; instant; announced 300s cooldown. |
| Human | [ ] Feedback | Unchanged. |
| Night Elf | [ ] Starshards | Increased damage; 30s cooldown. |
| Night Elf | [ ] Elune's Grace | Melee/ranged hit chance reduced 50%; 15s/three misses; 300s cooldown. |
| Gnome | [ ] Confounding Flash | Five-target confusion (3s), damage breaks; 0.5s cast; 120s cooldown. |
| Gnome | [ ] Contingency Plan | 30s ward; below 35% triggers absorb/HoT, stacks with PW:S/Renew; instant; announced 300s cooldown. |
| Troll | [ ] Hex of Weakness | Unchanged. |
| Troll | [ ] Shadowguard | Unchanged. |
| Undead | [ ] Touch of Weakness | Unchanged. |
| Undead | [ ] Dark Sacrifice | Health-to-mana over time; Spirit scaling. |

### Beta corrections and unresolved parameters

The [official beta development notes, updated October 15](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-15/2360696)
confirm these requirements:

- [ ] Contingency Plan can crit; verify which triggered components crit and how
  their scaling is resolved before implementing.
- [ ] Starshards receives Twilight Focus pushback protection.
- [ ] Dark Sacrifice health loss must not break damage-sensitive crowd control;
  its mana gain scales with Spirit. Do not reuse ordinary incoming damage
  without preserving this exception.

- [ ] Resolve Divine Grace/Contingency Plan cooldowns against the selected
  beta build: the announcement says 5 minutes, while a
  [build 70245 comparison](https://bindonforever.com/articles/priest-racial-spells-cooldowns-and-quiet-changes)
  reports 10 minutes. Treat this as a reported conflict, not a resolved tuning
  change. Verify spell IDs, rank, build and tooltip/effect data together.
- [ ] Verify max-rank amounts, mana costs, GCDs, range, school, coefficients,
  dispel rules and charges for all twelve spells. In particular, do not fill
  the five “unchanged” entries from Classic assumptions or obsolete spell pages.
- [ ] Dark Sacrifice reference lead: local
  `~/mythicsim-forever-engine-go/docs/beta-pass/priest.md` identifies IDs
  1277324–1277328 and rank-five 1600 health/mana over 15s, 600s cooldown;
  its spirit formula needs reconciliation with current client data.
  [Indexed rank-four spell data](https://www.wowhead.com/forever/spell=1277327/dark-sacrifice)
  shows a 15s aura, 3s intervals, 600s cooldown and Spirit in the tooltip,
  but tooltip and raw effect amounts disagree. Do not substitute this rank
  for level-60 rank five.

### Simulator implementation work

- [ ] Add Dwarf and Night Elf race support through spec parsing, editor,
  serialization, combat state and worker initialization; preserve existing
  race IDs and keep class/race eligibility explicit.
- [ ] Implement baseline Fear Ward for every Priest, with verified consumption,
  duration, cooldown, dispel behavior and Fear/Horror category interactions.
- [ ] Add race-gated actions, loadout/editor entries, action masks, search
  priors, replay attribution and aura/cooldown badges for the spells above.
  Keep general race abilities tracked separately in `RACIALS.md` and
  `VISUALIZER_TODO.md` section 14.
- [ ] For current self-versus-enemy duels, Divine Grace has no legal friendly
  target: defer it until allied targets exist; never turn it into a self-heal.
- [ ] Design Contingency Plan's armed ward, health-threshold trigger and separate
  absorb/HoT state. Verify self-target eligibility and trigger order against
  lethal hits before offering it in duels.
- [ ] Give Confounding Flash an audited control category, DR and damage-break
  behavior; do not assume it shares Psychic Scream's Fear timer.
- [ ] Audit reactive spell triggers, charge consumption, ICDs, mana depletion,
  healing reduction and pet/periodic eligibility where relevant to Feedback,
  Shadowguard, Touch of Weakness and Hex of Weakness.
- [ ] Add both-side regression coverage for eligibility, resource costs,
  cooldowns, cast cancellation, control/DR, dispels, proc boundaries,
  snapshot/restore, worker copies and replay fields as each spell lands.

Research/documentation only: none of these twelve spells is marked implemented.

## 11. Core Shadow spell mana audit (2026-10-18)

- [x] Replace compact mana placeholders for level-60 Shadow Word: Pain,
  Mind Blast, and Mind Flay with costs from the local reference's
  `sim/priest/spell_data_auto_gen.go` (beta client 1.60.1.69893).
- SW:P rank eight (10894): 45 -> 470 mana; Mind Blast rank nine (10947):
  60 -> 350 mana; Mind Flay rank six (18807): 45 -> 205 mana.
- Existing Shadowform, Mental Agility and Inner Focus modifiers still apply.
  Mental Agility reduces SW:P, but does not reduce Mind Blast or Mind Flay.
- Both-side regression coverage checks insufficient-mana rejection, exact-cost
  availability/spending, Shadowform discounts and zero-mana Inner Focus casts.

These changes increase mana pressure in fresh simulations. Other compact costs,
GCD values and unaudited damage/healing values remain outstanding; historical
replays retain their recorded results.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed
141/141 tests. Zig formatting passed for the touched source files.

## 12. Core healing spell mana audit (2026-10-18)

- [x] Replace placeholder mana costs using the local reference's generated
  `sim/priest/spell_data_auto_gen.go`, rather than its commented-out healing
  implementations (which contain older spell data).
- Power Word: Shield rank ten (10901): 70 -> 500 mana.
- Flash Heal rank seven (10917): 75 -> 380 mana.
- Renew rank ten (25315): 55 -> 410 mana.
- Preserve Mental Agility on PW:S/Renew, Soul Warding on PW:S, and free
  Inner Focus casts. Flash Heal does not receive the instant-spell discount.
- Both-side regression coverage checks rejection below cost without spending
  mana or starting the GCD, availability/spending at exact cost, combined
  discounts, and Inner Focus consumption versus retention during Flash Heal.

Silence and Mana Burn are already implemented; baseline work remains before
racial parity. In particular, Abolish Disease, Fear Ward, Greater
Heal, Holy Nova, unaudited healing/absorb amounts, and unchecked talents above
remain open. This pass changes mana costs only; PW:S duration/absorb and
Flash Heal/Renew healing values still need their own mechanics audit.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed
142/142 tests. Zig formatting, `git diff --check`, and
`lua visualizer/test_priest_utility.lua` passed.

## 13. Dispel Magic percentage mana cost (2026-10-18)

- [x] Replace the hardcoded 180-mana cost in both action masks and spending
  with `Priest.BaseMana * Priest.DispelManaFraction`.
- The local Forever reference defines level-60 Priest class base mana as
  1376 (`sim/core/base_stats.go`) and rank-two Dispel Magic (988) as 18%
  (`sim/priest/spell_data_auto_gen.go`). The resulting cost is 247.68 mana
  before Mental Agility, or 222.912 at rank three. The simulator retains
  fractional mana; Intellect and gear do not increase class base mana.
- Inner Focus still makes either Dispel free and is consumed on use.
- Both-side tests cover self/enemy targets, all Mental Agility ranks,
  insufficient-mana rejection, exact-cost spending, and zero-mana Inner Focus.
  Different maximum mana pools preserve the same class-base cost.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed
143/143 tests. Zig formatting and `git diff --check` passed.

## 14. GCD and Dispel Magic replay audit (2026-10-18)

- [x] **Correct the Priest spell GCD baseline.** All ordinary Priest spells,
  including Dispel Magic and Mana Burn, now use 1.5 seconds. The local
  reference's `sim/core/cast.go` explicitly disables GCD haste scaling;
  `Cast.EffectiveTime()` enforces the one-second floor but does not apply
  haste. `Unit.SpellGCD()` alone would misleadingly suggest haste scaling.
  Cast progress still benefits from haste; Silence, Inner Focus and Power
  Infusion retain their existing off-GCD behavior.
  - Both-side regression checks cover Shield-to-Dispel rejection at 1.01s
    and 1.49s, availability after expiry, with/without racial haste,
    off-GCD action availability, Inner Focus activation preserving the GCD,
    and self-dispel preserving Shield absorption.
  - Recorded matches use 10ms ticks; floating-point timer subtraction can
    move availability to the next tick after the theoretical 1.50s boundary.
- [ ] **Audit Dispel Magic selection and resistance.** Self-dispel currently
  removes up to two effects in fixed priority order (against Warlock:
  Fear, Seduction, Corruption, Immolate, Siphon Life), without a dispel
  resistance roll. Verify Forever's selection and resistance rules and
  implement applicable mechanics with reproducible RNG and snapshot tests.
  Keep curses/diseases excluded and preserve the caster's beneficial buffs.
- Observed self-dispels do remove the recorded eligible effects: at 16.84s,
  Corruption and Siphon Life both disappear while Curse of Agony remains;
  at 23.39s, Siphon Life disappears while PW:S absorb is preserved. The
  2.64s self-dispel consumes Inner Focus and is free. These observations
  confirm replay effects, not full mechanics parity.

Original audit validation: replay event/frame inspection and source comparison.
`zig build test` (Debug) failed during compilation with LLVM's
`Cannot emit physreg copy instruction`; tests did not execute in this audit.

Source audit follow-up: the local reference has Dispel Magic's generated spell
record but no Priest Dispel implementation or general aura-selection/resistance
resolver. Selection/randomness and per-aura resistance remain open; the current
fixed-priority behavior is not being presented as verified Forever parity.

GCD implementation validation: `zig build test -Doptimize=ReleaseSafe --summary
all` passed 144/144 tests; `lua visualizer/test_priest_utility.lua` passed.
Fresh replay: `matches/priest_gcd_audit.lua` (plus JSON/search metadata),
using the original matchup's talents, pet and recorded stats with 16,384
rollouts, 16 workers and 512 MB. The Human racial crit bonus is removed from
its input stat before spec loading to avoid adding it twice.
Replay inspection: original final stats, talents and pet match the historical
recording. Minimum Priest on-GCD cast spacing is 1.51s. Self-dispel at 4.57s
removes Corruption (9.45s remaining) and preserves Curse of Agony (17.26s).
The fight ends at 15.22s with a Priest win; this sample does not establish a
matchup win rate or optimal decisions. Existing replays were preserved.

## 15. Mana Burn search coverage and healing amounts (2026-10-18)

- [x] Include Mana Burn in ordinary Priest rollout continuations. Previously it
  was legal at the search root and in random exploration but absent from the
  scripted continuation priority list. Power Infusion, both Dispels and Will
  of the Forsaken were also absent and now participate when legal.
- Mana Burn continuation policy favors enemies with 384–1534 mana, while
  preserving urgent healing and finishing priorities. These are search tuning
  thresholds, not spell rules; root search retains all legal Mana Burn choices.
  The short-horizon heuristic still has no explicit mana-value term, and this
  change does not establish optimal play or guarantee a cast in every match.
- Confirmed the local generated rank-five Mana Burn record (10876) specifies
  270 mana, 3s cast, 30m range and 767 mana burned. Existing completion tests
  cover limited target mana, shields, misses, cancellation and range failure.
- [x] Replace level-60 healing/absorb placeholders using the generated client
  table: PW:S (10901) 420 -> 928 base absorb; Flash Heal (10917) 340 -> 841
  base healing; Renew (25315) 108 -> 166 healing per three-second tick.
  Existing spell-power coefficients and talent modifiers remain applied.
- PW:S duration, cooldown versus Weakened Soul, and other healing mechanics
  still require their own audit. This completes the base-amount portion only.
- Added both-side regression tests for literal client healing/absorb amounts
  and rollout selection of Mana Burn and utility actions.

Validation: `zig build test -Doptimize=ReleaseSafe --summary all` passed
155/155 tests. Priest utility and automatic-action Lua tests, Zig formatting
and `git diff --check` passed.
