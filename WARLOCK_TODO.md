# Warlock simulation accuracy TODO

Start with [TODO.md](TODO.md) for current cross-project priorities. This file is
the detailed source of truth for Warlock mechanic coverage.

Scope: the checked-in level 60 Warlock tree (`visualizer/data/talents_warlock.json`)
and the compact PvP kit currently modeled in `src/spec.zig` / `src/combat_spec.zig`.
The current action set includes Agony, Corruption, Fear, Shadow Bolt, Drain Life,
Healthstone, Death Coil, Siphon Life, Shadowburn, Searing Pain, Incinerate, Immolate, Conflagrate, Seduction, and Spell Lock. “Implement” means model
availability, costs, cast/GCD/cooldown, range, effects, interactions, and timing
in both scalar and SIMD combat paths where relevant.

## Status (audited 2026-10-15)

Checked items mean the described supported scope exists, not full game accuracy.
Unchecked items can be partially implemented; their remaining work is called out.
Life Tap, Improved Life Tap, and Curse of Weakness are excluded from completion counts.

## Missing spell implementations

- [ ] **Will not implement:** Life Tap. Its health-to-mana conversion has little value in the current PvP kit; the action slot is better used for combat choices.
- [ ] Add Curse of Exhaustion: curse slot exclusivity, 30% slow, duration, range, and dispel/refresh behavior.
- [ ] Add Amplify Curse activation and its empowered next Curse of Weakness, Bane of Agony, or Curse of Exhaustion.
- [ ] Add Wrack: periodic damage, Shadow DoT amplification, duration, and its relevant talent interactions.
- [ ] Add Bane of Doom: periodic damage, target limitation, and Bane exclusivity.
- [ ] **Out of scope:** Curse of Weakness (low priority for the current PvP kit).
- [ ] Add Curse of Tongues: cast-time slow and curse exclusivity.
- [x] Add Immolate cast, direct hit, periodic damage, and Immolate state in the Warlock and mixed-class simulator paths. Aftermath initial damage and Conflagrate consumption/preservation interactions are implemented.
- [x] Add Incinerate's 25% conditional damage bonus while the target is affected by Immolate.
- [x] Add Searing Pain's cast, mana cost, range, and direct Fire damage. Direct-hit crit chance/damage now resolve through the shared spell resolver; Agonizing Flames, threat, and Demonic Brand remain pending.
- [x] Add Incinerate's cast, mana cost, range, direct Fire damage, and Immolate conditional bonus.
- [ ] Add Soul Fire: cast/cooldown, damage, and Decimation/Pyroclasm interactions.
- [x] Add Conflagrate: talent-gated instant Fire damage, 30m range, 100 mana, standard GCD, 10-second cooldown, Immolate requirement/consumption, Aftermath daze, and Shadow and Flame preservation/buff procs. Base damage is the mean of the checked-in talent tooltip (88–111); critical strikes now use configured crit chance, Fire and Brimstone, and Ruin; level-60 spell-rank tuning remains separate accuracy work.
- [x] Implement Shadowburn's talent-gated instant damage, range, mana cost, and cooldown.
- [x] Apply Shadow and Flame's rank-based Fire damage bonus to modeled Fire damage when the talent is selected.
- [ ] Add Rain of Fire: area damage and Pyroclasm stun chance (requires multi-target support).
- [ ] Add Hellfire: self-damage, area damage, and Pyroclasm stun chance (requires multi-target support).
- [ ] Add Drain Soul: channel, damage/execution behavior, Soul Harvest, and Nightfall proc interaction.
- [ ] Add Drain Mana: channel, mana drain, and Fel Concentration interaction.
- [ ] Add Health Funnel: channel, health cost, pet healing, and Improved Health Funnel effects.
- [ ] Add Demon Skin and Demon Armor: armor/regen effects and Demonic Aegis scaling.
- [ ] Add summon spells for Imp, Voidwalker, Succubus/Incubus, and Felhunter, including cast times, mana costs, and pet replacement.
- [ ] Add Voidwalker Sacrifice and Consume Shadows, including shield/healing and Improved Voidwalker scaling.
- [x] Add Succubus/Incubus Seduction as an off-GCD Warlock action gated by an active Succubus, with range, cooldown, and crowd control. Models a 1.5-second pet cast, separate Seduction diminishing returns, damage breaks, and Improved Sayaad duration scaling. Range currently uses owner-to-target distance rather than pet-to-target distance.
- [ ] Add the remaining pet abilities (Imp Fire Shield; Voidwalker Torment/Suffering; Succubus/Incubus Lash of Pain; Felhunter Devour Magic/Tainted Blood/Paranoia), with authentic cooldowns and effects. Spell Lock is modeled as a Felhunter-only off-GCD interrupt with a 24-second base cooldown (reduced by 2 seconds per Improved Felhunter rank) and 4-second school lockout. Basic autonomous attacks are modeled for each pet kind; non-Imp attacks remain simplified melee placeholders.
- [ ] Add Fel Domination's instant/discounted next summon behavior.
- [ ] Add Healthstone charge/availability and item-use rules; current heal/cooldown approximation does not model item inventory.

## Missing talent implementations

### Affliction

- [ ] **Out of scope:** 105921 Improved Life Tap (Life Tap is excluded).
- [x] 105925 Suppression: +1% spell hit per rank applies to modeled owner direct spells, DoT applications, channel starts, and crowd control. Pet effects do not inherit it; threat reduction remains unmodeled.
- [x] 105923 Malediction: periodic Warlock damage bonus applies to all currently modeled periodic damage, including Drain Life and Siphon Life's transferred healing; add it to future periodic spells as they are implemented.
- [ ] 105922 Soul Harvest: kill-triggered mana regeneration and casting regeneration; requires kill attribution and regen state.
- [x] 105920 Improved Drains: rank-based Drain Life damage and healing are implemented; extend to Drain Soul and Wrack when those spells are added.
- [x] 105919 Improved Bane of Agony: both ranks increase Agony damage by 5% per rank, matching the checked-in talent description. The full rank is retained in the extended talent word for mirror, mixed-class, and cached search effects.
- [x] 105918 Fel Concentration: 23%/47%/70% chance to resist direct-damage pushback while channeling modeled Drain Life. Extend eligibility to Drain Mana, Drain Soul, and Wrack when implemented; periodic damage never causes pushback.
- [ ] 105916 Amplify Curse: empower next eligible curse.
- [x] 105917 Pandemic: rank-based 33%/67%/100% increase to the critical damage bonus applies to modeled Affliction periodic/channel ticks; extend to future eligible spells when added.
- [x] 110876 Malevolence: +1% crit chance per rank applies to modeled eligible direct Shadow damage and Shadow periodic/channel ticks.
- [x] 105914 Nightfall: 2% / 4% proc chance per damaging Corruption or Drain Life tick grants a 10-second Shadow Trance; the next Shadow Bolt is instant and consumes it. Proc timing is snapshotted separately from the Shadow and Flame buff.
- [ ] 105913 Curse of Exhaustion: unlock/modify the spell (spell implementation above).
- [ ] 105911 Soul Siphon: scale drain output based on active Affliction effects.
- [ ] 105909 Wrack: unlock/modify the spell (spell implementation above).

### Demonology

- [ ] 105905 Improved Health Funnel: increase healing, reduce health cost/threat, and remove pet-health restriction.
- [x] 105908 Improved Imp: rank-scaled Imp Firebolt damage (+10% per rank) is applied; the Fire Shield effect remains unsupported until Fire Shield exists.
- [x] 105907 Demonic Embrace: +3% total stamina per rank, with the resulting health applied to both sides, mixed combat, cached search, editor previews, Fight starting health, and replay maxima. Uses explicit pre-talent stamina and the compact 10 HP per point model; legacy gear saves recover stamina in the editor. Verified base/racial stamina and authentic rounding remain stat accuracy work.
- [ ] 105902 Demonic Aegis: increase Demon Skin/Demon Armor effects.
- [ ] 105904 Improved Voidwalker: increase Voidwalker ability effects.
- [ ] 105903 Fel Vitality: Warlock maximum mana and pet maximum health now increase by 5% per rank (up to 15%). Pet mana is not modeled; add pet mana and apply this talent's pet-mana bonus when that resource is introduced.
- [ ] 105899 Demonic Energies: heal pet from spell damage and transfer Life Tap mana to pet.
- [ ] 105901 Improved Sayaad: Seduction duration now increases by 10% per rank before diminishing returns in mirror and mixed combat. Lash of Pain, Soothing Kiss, and Lesser Invisibility hooks remain pending those abilities.
- [x] 105900 Demonic Sacrifice: select a sacrifice pet per spec and apply its checked-in Forever effect (Imp: +15% Shadow; Voidwalker: +2% max Mana / 4 sec; Succubus/Incubus: +15% Fire; Felhunter: +3% max Health / 4 sec). With Demonic Pact, select a separate active demon. Mid-fight summon cancellation and pet replacement remain unmodeled.
- [ ] 105898 Master Summoner: reduce summon cast time and mana cost.
- [ ] 105897 Decimation: reduce Soul Fire cooldown and trigger its execute cast/damage/cost bonus.
- [ ] 105895 Fel Domination: unlock/modify summon spells (spell implementation above).
- [ ] 105896 Demonic Brand: Searing Pain brand and empowered pet attacks.
- [ ] 105894 Improved Felhunter: Spell Lock cooldown now decreases by 2 seconds per rank (24/22/20/18 seconds) in mirror and mixed combat. Tainted Blood, Devour Magic, and Paranoia hooks remain pending those abilities.
- [x] 105892 Soul Link: redirect 30% of incoming damage to an active pet and increase Warlock and pet damage by 3%; pet damage recipient, overkill, and simultaneous death behavior are implemented.
- [x] 105893 Demonic Knowledge: the checked-in Forever talent grants owner and pet spell damage equal to 33%/67%/100% of owner level while a living demon is active. Owner school spell power and Imp Firebolt use this bonus; melee pets do not. Recomputed from live state in scalar setup, mirror/mixed SIMD and cached search; pet death removes the bonus. The Imp uses the compact 2/3.5 Firebolt spell-power coefficient.
- [x] 105891 Master Demonologist: living Imp grants +2% Fire damage/rank to owner and pet Firebolt; living Succubus grants +2% Shadow damage/rank to owner (pet Shadow spells are not yet modeled); living Voidwalker reduces physical damage by 2%/rank; living Felhunter reduces magic damage by 2%/rank. Physical pet melee and magical owner/Imp attacks use distinct mitigation. Bonuses disappear on pet death. Pet-targeted attacks are not supported; Soul Link transfers already-mitigated damage without a second reduction. Setup and replay show active badges.
- [ ] 105890 Demonic Pact: initial spec setup permits a separate active pet alongside the selected sacrifice effect. Retention/cancellation across mid-fight summons remains pending summon actions.

### Destruction

- [ ] 105881 Destructive Reach: increase damaging spell range.
- [x] 105889 Improved Shadow Bolt: landed Shadow Bolt crits apply a 12-second debuff increasing Shadow damage taken by 4% per rank (up to 20%), with 4 charges consumed by incoming Shadow damage hits/ticks, refreshing on new landed SB crits. debuff duration, stack count, and timers are recorded in telemetry and displayed in unit frames and overhead nameplates.
- [x] 105885 Molten Skin: reduces all incoming player damage by 2% per rank, including spell, drain, and pet damage.
- [x] 105887 Cataclysm: reduces mana cost by 3%/6%/10% for Shadow Bolt, Shadowburn, Searing Pain, Incinerate, Immolate, and Conflagrate. Action availability uses the same discounted costs.
- [x] 105886 Aftermath: +10% Immolate initial damage per rank and 20% Conflagrate daze chance per rank (50% movement slow for 5 seconds).
- [x] 105883 Ruin: +20% critical damage bonus per rank for currently modeled direct Destruction spells (1.5x base crit through 2x at rank 5). Extend to future eligible spells as added.
- [x] 105884 Shadowburn: talent unlock gates the action; modeled direct hit, range, mana cost, and cooldown.
- [x] 105882 Intensity: 23%/47%/70% chance to resist direct-damage pushback for modeled Destruction hard casts (Shadow Bolt, Searing Pain, Incinerate, Immolate). Fear and Drain Life do not inherit it; extend to future eligible casts/channels.
- [x] 105879 Agonizing Flames: increase Searing Pain critical chance (+3%/+7%/+10%) and Destruction damage (+3%/+7%/+10%).
- [x] 105880 Conflagrate: unlock gates the spell; effects are implemented above.
- [ ] 105878 Pyroclasm: add stun chance to Soul Fire, Rain of Fire, and Hellfire.
- [ ] 105876 Bane of Havoc: mark one target and copy the specified share of damage dealt to other targets (requires multi-target support).
- [x] 105877 Fire and Brimstone: increases Conflagrate crit chance by 8%/17%/25%, matching the checked-in descriptions.
- [x] 105875 Shadow and Flame (Conflagrate): rank-scaled Shadow damage buff (+2% per rank for 20 seconds) and chance to preserve Immolate (20% per rank). Shadowburn's Fire bonus still uses the existing permanent approximation; its timed activation and authentic Soul Shard refund rolls remain pending.
- [x] 105874 Incinerate: talent-gate the modeled cast and direct Fire damage; the 25% Immolate conditional bonus is implemented.

## Accuracy foundations needed by the spell/talent work

- [x] Add focused SIMD-lane coverage for decoded Warlock talent effects (Cataclysm mana ranks, Improved Bane of Agony, Bane cast time, Malediction/Shadow Mastery, and Improved Drains).
- [x] Add shared direct-spell hit/miss, school-specific full resist, and crit resolution, with distinct outcomes and deterministic per-fighter RNG preserved by snapshots. Wired to Warlock direct spells (including Immolate initial hit and Conflagrate) and existing Mage missiles. Costs/cooldowns still commit on failed casts; failed missiles cause no damage or impact effects. Death Coil resolves hit/resist but cannot crit in this model.
- [x] Add discrete periodic/channel tick scheduling for Agony, Corruption, Immolate, Siphon Life, and Drain Life. First tick follows one interval; final tick occurs at expiry. Successful refresh resets phase, failed refresh preserves it, and cancellation discards partial ticks. Phase derives from quantized snapshotted timers. Tests compare physics step sizes, both sides, and mirror/mixed matchups.
- [x] Add periodic/channel critical strikes, one roll per eligible tick. Pandemic, Malevolence, and Immolate/Ruin are wired. Drain healing uses the same critical/partial-resist multiplier as damage on the existing base HPS; target shields/Soul Link/overkill do not reduce healing in the preserved compact model.
- [x] Extend hit/full-resist resolution to DoT applications, channel starts, crowd control, and interrupts. Failed refreshes preserve effects; costs/cooldowns commit on failure and failed CC does not advance DR. Suppression applies to owner effects only.
- [x] Add Imp Firebolt hit/full-resist/partial-resist/crit and simplified melee pet hit/avoidance/crit/armor resolution, with separate pet stats and RNG. Owner-only hit/crit talents do not leak. Authentic pet stats and full melee attack tables remain accuracy work.
- [x] Add crit-triggered effect hooks, starting with Improved Shadow Bolt; implement Agonizing Flames' Searing Pain crit bonus and Destruction damage bonus (see talent entries above).
- [ ] Resistance foundations now accept raw school resistance, level, and penetration, with binary resistance and mean-preserving adjacent 25% partial buckets. This is an explicit compact approximation; authentic Forever tables and any supported rating conversion remain pending. Unsupported rating inputs are rejected. See CLI_REFERENCE.md for formulas and eligibility.
- [ ] Spec editor now edits and round-trips supported combat stats, with compact defaults and a clearly labeled level-60 example preset. Verified Forever baseline/gear-derived stats remain pending; example probabilities are assumptions, and talent bonuses remain separate.
- [x] Add direct-damage cast/channel pushback and Fel Concentration/Intensity resistance. Individual missile impacts, Conflagrate, and autonomous pet attacks qualify; DoT/channel ticks, misses, full resists, and fully absorbed hits do not. Classic-reference pushbacks are 1.0/0.8/0.6/0.4/0.2 seconds, then 0.2 seconds per hit; normal casts cannot rewind before their start. Channel pushback removes tail duration without advancing tick phase. Counters, natural channel time, and dedicated RNG are snapshotted; counters reset per cast. Forever-specific rule overrides remain unverified; see CLI_REFERENCE.md.
- [ ] Add dispel and purge behavior. Spell Lock school lockouts are implemented, including simultaneous-action and snapshot coverage; Devour Magic and other dispel interactions remain pending.
- [ ] Finish pet state: kind, health, position, attack timer, active/dead checks, initial sacrifice selection, and Soul Link damage/death handling exist. Pet mana, mid-fight summoning/replacement, and sacrifice cancellation transitions remain pending.
- [ ] Add multiple targets and area/damage-copy resolution for Rain of Fire, Hellfire, Bane of Havoc, and Soul Siphon effect counting.
- [ ] Add per-spell range and target eligibility instead of relying on the current shared range approximation. Most modeled spells now enforce action-specific ranges. Agony, Corruption, and Shadow Bolt still share the 35m approximation; pet abilities use owner-to-target distance and need pet geometry/eligibility.
- [ ] Finish combat metadata/effect state: Fear and Seduction have separate DR state; Conflagrate procs use deterministic per-lane RNG preserved by snapshots. Curse/Bane exclusivity and general refresh/stacking/proc rules remain pending.
- [ ] Complete scalar-vs-SIMD parity coverage for each implemented Warlock spell and talent effect. Existing coverage includes decoded damage/cost/cast modifiers, Aftermath, all Improved Sayaad/Improved Felhunter rank combinations, supplied-roll spell outcomes, direct spell impacts, and RNG snapshot replay. Additional coverage now includes periodic timing across physics step sizes, Pandemic scalar/SIMD decode, resistance scalar formulas, application/CC failures, pet attack tables, pet utility RNG staging, and snapshot continuation. Extend parity coverage to future crit-triggered effects and authentic resistance formulas. Pet utility integration coverage exercises both sides, divergent lanes, Seduction DR tiers, and mirror/mixed matchups.
- [ ] Record and display miss, full/partial resist, and crit outcomes in combat events and replay. The resolver currently stores the latest direct-spell outcome per fighter, but visual replays do not label these outcomes separately; preserve per-spell outcomes through missile travel and simultaneous impacts.

## Recommended implementation order

Current cross-project order is maintained in [TODO.md](TODO.md): active Soul
Link/DS frame indicators first, then Improved Shadow Bolt, Agonizing Flames,
and passive owner/pet stat talents. The spell and talent entries above
remain the detailed acceptance scope.

Completed foundations include discrete DoT/channel ticks, periodic crits,
application/CC/pet hit resolution, and direct-damage pushback with interruption
resistance for the documented compact scope. Verified Forever resistance and
baseline stats, dispels/purges, and replay outcome reporting remain open and can
progress alongside talent work.

## Action and spec configuration

- [x] Replace manual action-slot maintenance with automatically derived class,
  talent, gear, race, and pet capabilities. Retain all supported available actions
  initially and prioritize Fear among baseline Warlock actions. Shared capacity,
  ordering, overflow, and cooldown-display requirements are tracked in
  [Visualizer section 16](VISUALIZER_TODO.md#16-automatic-actions-and-available-cooldowns).
- [x] Let the spec editor track a spec's available action capabilities from the supported action catalog and save/load that list; keep movement intent (advance, stand, kite) separate from action slots.
- [x] Apply each saved action loadout to runtime action masks and search choices; always retain the reserved Idle/Maneuver and Cancel Cast actions.
- [x] Generate action IDs, counts, and maximum choice capacity from the shared catalog for specs, mixed-class simulation, and search. The MCTS choice buffer scales to three movement variants per action.

## Current talent coverage

The packed talent word currently carries ranks for Improved Corruption,
Malediction, Improved Drains, Improved Bane of Agony, Siphon Life, Shadow
Mastery, Unholy Power, Improved Imp, Soul Link, Bane, Molten Skin, Cataclysm,
Shadowburn, Shadow and Flame, Aftermath, Conflagrate, Improved Sayaad, Improved Felhunter, Suppression, Malevolence, Pandemic, Fel Concentration, Intensity, Ruin, Fire and Brimstone, and Demonic Sacrifice. Demonic Pact is parsed and
stored and permits separate initial active/sacrifice pet selection; mid-fight summon behavior is not modeled. Recognized does not
imply complete: the checklist above records missing hooks and partial scope.
