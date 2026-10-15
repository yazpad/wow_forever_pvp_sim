# Warlock simulation accuracy TODO

Scope: the checked-in level 60 Warlock tree (`visualizer/data/talents_warlock.json`)
and the compact PvP kit currently modeled in `src/spec.zig` / `src/combat_spec.zig`.
The current action set includes Agony, Corruption, Fear, Shadow Bolt, Drain Life,
Healthstone, Death Coil, Siphon Life, Shadowburn, Searing Pain, Incinerate, Immolate, and Conflagrate. “Implement” means model
availability, costs, cast/GCD/cooldown, range, effects, interactions, and timing
in both scalar and SIMD combat paths where relevant.

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
- [x] Add Searing Pain's cast, mana cost, range, and direct Fire damage. Critical chance/damage, threat, and Demonic Brand interaction remain unmodeled.
- [x] Add Incinerate's cast, mana cost, range, direct Fire damage, and Immolate conditional bonus.
- [ ] Add Soul Fire: cast/cooldown, damage, and Decimation/Pyroclasm interactions.
- [x] Add Conflagrate: talent-gated instant Fire damage, 30m range, 100 mana, standard GCD, 10-second cooldown, Immolate requirement/consumption, Aftermath daze, and Shadow and Flame preservation/buff procs. Base damage is the mean of the checked-in talent tooltip (88–111); level-60 spell-rank tuning and critical strikes remain separate accuracy work.
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
- [x] Add Succubus/Incubus Seduction as an off-GCD Warlock action gated by an active Succubus, with range, cooldown, and crowd control. The first model applies instantly and reuses Fear diminishing returns and damage-break behavior; pet cast time and the separate incapacitate DR category remain unmodeled.
- [ ] Add the remaining pet abilities (Imp Fire Shield; Voidwalker Torment/Suffering; Succubus/Incubus Lash of Pain; Felhunter Devour Magic/Tainted Blood/Paranoia), with authentic cooldowns and effects. Spell Lock is modeled as a Felhunter-only off-GCD interrupt with a 24-second cooldown and 4-second spell lockout. Basic autonomous attacks are modeled for each pet kind; non-Imp attacks remain simplified melee placeholders.
- [ ] Add Fel Domination's instant/discounted next summon behavior.
- [ ] Add Healthstone charge/availability and item-use rules; current heal/cooldown approximation does not model item inventory.

## Missing talent implementations

### Affliction

- [ ] **Out of scope:** 105921 Improved Life Tap (Life Tap is excluded).
- [ ] 105925 Suppression: spell hit and threat reduction; hit currently has no combat resolution.
- [x] 105923 Malediction: periodic Warlock damage bonus applies to all currently modeled periodic damage, including Drain Life and Siphon Life's transferred healing; add it to future periodic spells as they are implemented.
- [ ] 105922 Soul Harvest: kill-triggered mana regeneration and casting regeneration; requires kill attribution and regen state.
- [x] 105920 Improved Drains: rank-based Drain Life damage and healing are implemented; extend to Drain Soul and Wrack when those spells are added.
- [x] 105919 Improved Bane of Agony: both ranks increase Agony damage by 5% per rank, matching the checked-in talent description.
- [ ] 105918 Fel Concentration: chance to resist damage interruption for listed drain channels.
- [ ] 105916 Amplify Curse: empower next eligible curse.
- [ ] 105917 Pandemic: increased crit damage bonus for listed Affliction spells; requires crit system.
- [ ] 110876 Malevolence: Shadow spell critical chance; requires crit system.
- [ ] 105914 Nightfall: proc Shadow Trance from Corruption/drain effects and make next Shadow Bolt instant.
- [ ] 105913 Curse of Exhaustion: unlock/modify the spell (spell implementation above).
- [ ] 105911 Soul Siphon: scale drain output based on active Affliction effects.
- [ ] 105909 Wrack: unlock/modify the spell (spell implementation above).

### Demonology

- [ ] 105905 Improved Health Funnel: increase healing, reduce health cost/threat, and remove pet-health restriction.
- [x] 105908 Improved Imp: rank-scaled Imp Firebolt damage (+10% per rank) is applied; the Fire Shield effect remains unsupported until Fire Shield exists.
- [ ] 105907 Demonic Embrace: increase Warlock stamina/health.
- [ ] 105902 Demonic Aegis: increase Demon Skin/Demon Armor effects.
- [ ] 105904 Improved Voidwalker: increase Voidwalker ability effects.
- [ ] 105903 Fel Vitality: increase pet health/mana and Warlock maximum mana.
- [ ] 105899 Demonic Energies: heal pet from spell damage and transfer Life Tap mana to pet.
- [ ] 105901 Improved Sayaad: increase Lash of Pain/Soothing Kiss effect and Seduction/Lesser Invisibility duration.
- [x] 105900 Demonic Sacrifice: select a sacrifice pet per spec and apply its checked-in Forever effect (Imp: +15% Shadow; Voidwalker: +2% max Mana / 4 sec; Succubus/Incubus: +15% Fire; Felhunter: +3% max Health / 4 sec). With Demonic Pact, select a separate active demon. Mid-fight summon cancellation and pet replacement remain unmodeled.
- [ ] 105898 Master Summoner: reduce summon cast time and mana cost.
- [ ] 105897 Decimation: reduce Soul Fire cooldown and trigger its execute cast/damage/cost bonus.
- [ ] 105895 Fel Domination: unlock/modify summon spells (spell implementation above).
- [ ] 105896 Demonic Brand: Searing Pain brand and empowered pet attacks.
- [ ] 105894 Improved Felhunter: improve Felhunter abilities and reduce Spell Lock cooldown.
- [x] 105892 Soul Link: redirect 30% of incoming damage to an active pet and increase Warlock and pet damage by 3%; pet damage recipient, overkill, and simultaneous death behavior are implemented.
- [ ] 105893 Demonic Knowledge: add pet-dependent spell damage.
- [ ] 105891 Master Demonologist: apply pet-type-specific owner and pet effects.
- [ ] 105890 Demonic Pact: retain Demonic Sacrifice effect across different summons.

### Destruction

- [ ] 105881 Destructive Reach: increase damaging spell range.
- [ ] 105889 Improved Shadow Bolt: Shadow Bolt crit debuff and increased Shadow damage taken; requires crits/debuff.
- [x] 105885 Molten Skin: reduces all incoming player damage by 2% per rank, including spell, drain, and pet damage.
- [x] 105887 Cataclysm: reduces Shadow Bolt mana cost by 3%/rank (10% at rank 3); Shadow Bolt is the only currently modeled Destruction spell.
- [x] 105886 Aftermath: +10% Immolate initial damage per rank and 20% Conflagrate daze chance per rank (50% movement slow for 5 seconds).
- [ ] 105883 Ruin: increase critical damage bonus for Destruction spells; requires crit system.
- [x] 105884 Shadowburn: talent unlock gates the action; modeled direct hit, range, mana cost, and cooldown.
- [ ] 105882 Intensity: chance to resist damage interruption while casting/channeling Destruction spells.
- [ ] 105879 Agonizing Flames: increase Searing Pain critical chance and Destruction damage.
- [x] 105880 Conflagrate: unlock gates the spell; effects are implemented above.
- [ ] 105878 Pyroclasm: add stun chance to Soul Fire, Rain of Fire, and Hellfire.
- [ ] 105876 Bane of Havoc: mark one target and copy the specified share of damage dealt to other targets (requires multi-target support).
- [ ] 105877 Fire and Brimstone: increase Conflagrate crit chance.
- [x] 105875 Shadow and Flame (Conflagrate): rank-scaled Shadow damage buff (+2% per rank for 20 seconds) and chance to preserve Immolate (20% per rank). Shadowburn's Fire bonus still uses the existing permanent approximation; its timed activation and authentic Soul Shard refund rolls remain pending.
- [x] 105874 Incinerate: talent-gate the modeled cast and direct Fire damage; Immolate conditional bonus remains pending Immolate.

## Accuracy foundations needed by the spell/talent work

- [x] Add focused SIMD-lane coverage for decoded Warlock talent effects (Cataclysm mana ranks, Improved Bane of Agony, Bane cast time, Malediction/Shadow Mastery, and Improved Drains).
- [ ] Add spell hit, miss/resist, critical strikes, and crit damage modifiers; wire Suppression, Malevolence, Pandemic, Ruin, Improved Shadow Bolt, Agonizing Flames, and Fire and Brimstone.
- [ ] Add interruptible cast/channel state and damage-based interruption rolls; wire Fel Concentration and Intensity.
- [ ] Add dispel, purge, and spell lockout behavior for effects and pet abilities.
- [ ] Add pet state, including health, mana, active/sacrificed status, and death/summon transitions.
- [ ] Add multiple targets and area/damage-copy resolution for Rain of Fire, Hellfire, Bane of Havoc, and Soul Siphon effect counting.
- [ ] Add per-spell range and target eligibility instead of relying on the current shared range approximation. Siphon Life now enforces its 30m range; remaining actions still need their own ranges.
- [ ] Add combat metadata/effect state for curse exclusivity, debuff refresh/stacking, diminishing returns where applicable, and proc randomness.
- [ ] Add scalar-vs-SIMD parity coverage for each implemented Warlock spell and talent effect.

## Action and spec configuration

- [x] Let the spec editor track a spec's available action capabilities from the supported action catalog and save/load that list; keep movement intent (advance, stand, kite) separate from action slots.
- [x] Apply each saved action loadout to runtime action masks and search choices; always retain the reserved Idle/Maneuver and Cancel Cast actions.
- [x] Generate action IDs, counts, and maximum choice capacity from the shared catalog for specs, mixed-class simulation, and search. The MCTS choice buffer scales to three movement variants per action.

## Current talent coverage

The packed talent word currently carries ranks for Improved Corruption,
Malediction, Improved Drains, Improved Bane of Agony, Siphon Life, Shadow
Mastery, Unholy Power, Improved Imp, Soul Link, Bane, Molten Skin, Cataclysm,
Shadowburn, Shadow and Flame, Aftermath, Conflagrate, and Demonic Sacrifice. Demonic Pact is parsed and
stored but has no combat effect until summons are modeled. Recognized does not
imply complete: the checklist above records missing hooks and partial scope.
