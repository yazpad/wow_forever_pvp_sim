# Warrior: beta client pass (17 September 2026)

Beta build `1.60.1.69893` against Classic Era `1.15.9.69722`, read with `tools/data_watch/spell_client.py`,
`tools/data_watch/trait_curve.mjs` and the client's `SpellAuraOptions` (proc chances) and `SpellShapeshift` (stance
requirements) tables. Every number below is the beta client's.

## How the spells were read

- The sim registers one rank per ability, the one a level 60 warrior uses, so each value below is that rank's.
- Warrior abilities carry no spell power coefficient (the client's 1 on weapon strikes means "not set"), so nothing
  here is a coefficient change. What moved is base damage, cooldowns, durations and one threat value.
- Where the sim matched neither client before this pass: Bloodthirst (+30), Mortal Strike (+85) and Shield Slam
  (421-439) carried rank 1's numbers on the rank 4 id, read off the talent tooltips; Shield Slam also added Block Value
  twice and 15% of attack power, which was Season of Discovery's rune version.

## Spells changed (18 ranks, 13 abilities)

| Spell | Sim before | Forever beta |
|---|---|---|
| Bloodthirst 23894 | 35% AP + 30 | 35% AP + 48 (rank 4; 30/37/43/48 across ranks 1-4). Classic Era is 45% AP flat |
| Mortal Strike 21553 | weapon + 85 | weapon + 160 (rank 4, same as Era; 85 is rank 1) |
| Shield Slam 23925 | 421-439 + 2 x Block Value + 15% AP | 640-670 + Block Value (Era 342-358 + Block Value) |
| Revenge, all 6 ranks (sim uses 11601 / 25288) | 12-14, 18-22, 25-31, 43-53, 64-78, 81-99 | 20-24, 31-37, 43-53, 73-91, 109-133, 138-168 |
| Thunder Clap 11581 | 4 sec cooldown, 10% slow (15% with Conqueror's 5 piece) | 6 sec cooldown, 20% slow (25% with the set; the set's +5 is kept) |
| Slam 11605 | no cooldown | 15 sec cooldown on every rank |
| Sunder Armor 11597 | 261 flat threat (2.25 x 2 x level) | 1013 threat, now an explicit threat effect in the spell |
| Shield Block 2565 | 5 sec | 7 sec |
| Last Stand 12975 | 10 min cooldown | 3 min cooldown |
| Enrage (talent 12317, buff 13048) | 30% chance per point capped at 100%, flat 2% Physical damage | flat 30% chance, 2/4/6/8/10% Physical damage |
| Spearing Strike 1310222 (new) | not simulated | 15 Rage, 20 sec cooldown, 40% normalized weapon damage, +80% against Giants and Dragonkin |
| Blood Craze 16488 (talent) | not simulated | 1/2/3% of maximum health over 6 sec (3 ticks) after being crit, Bloodthirst damage, or a hit over 20% of maximum health |
| Battle Shout (warrior's own shout) | Improved Battle Shout assumed baseline (+25%) | talent bonus removed; see core below |

Unchanged in the client (checked against Era): Heroic Strike 11567/25286, Cleave 20569, Execute 20662, Hamstring 7373,
Overpower 11585, Rend 6547/11572/11573/11574, Whirlwind 1680, Pummel 6554, Bloodrage 2687, Berserker Rage 18499,
Recklessness 1719, Death Wish 12328 (the sim already had Forever's 5% damage taken), Sweeping Strikes 12292, Deep
Wounds (20/40/60% over 12 sec in 4 ticks), Flurry (5-25%), Shield Wall 871 (the sim already had 60% / 12 sec / 15 min).
Stance requirements in `SpellShapeshift` match the sim for every registered ability, including Thunder Clap in Battle
and Defensive Stance.

## Checklist lines

**Resolved**

- `sim/warrior/demoralizing_shout.go:15` (assumed baseline): confirmed. Rank 5 reduces attack power by 196, which is
  Classic's 140 plus Improved Demoralizing Shout's 40%, and lasts 45 sec. TODO removed. Core's base (146) and duration
  (30 sec) need a core change, below.
- `sim/warrior/shield_wall.go` (Improved Shield Wall rank 2, 15 min / 60% / 12 sec): confirmed. Curve reads 5.5 / 11 min
  (-330000 / -660000 ms); the spell is 900 sec cooldown, -60%, 12 sec. No number moved; TODO removed.
- `sim/warrior/shouts.go:55` (Improved Battle Shout assumed baseline): contradicted. Rank 7 gives 139 attack power
  (Classic 232) for 3 min (Classic 2), rank 6 111 (Classic 185): Forever cut the shout by 40% rather than folding the
  talent in. The warrior now passes 0 Improved Battle Shout points (290 -> 232 AP); core still needs 232 -> 139.
- `sim/warrior/talents.go:76` (Weaponmaster): confirmed, curves read 1/2/3/4/5% crit, 3/6/9/12/15% armor ignored,
  1/2/3/4/5% extra attack (proc spell 12281 at 5% max, 200 ms internal cooldown). TODO removed.
- `sim/warrior/talents.go:177` (Unbridled Wrath 12% per point): confirmed, curve 12/24/36/48/60, 1 Rage (2 with a
  two-handed weapon). TODO removed.
- `sim/warrior/talents.go:206` (Dual Wield Specialization): confirmed, curves read 5-25% damage, 20-100% Rage, 2-10%
  hit. TODO removed.
- `sim/warrior/talents.go:234` (Enrage chance per rank): changed. The chance is a flat 30% (`SpellAuraOptions.ProcChance`
  of 12317) and the ranks scale the damage, 2/4/6/8/10%. Sim before: 30/60/90/100/100% chance for a flat 2%.
- `sim/warrior/talents.go:376` (Master of Defense rank 2): confirmed as the code already read it. Curve 50 / 100%, and
  the Rage is a flat 5 (23602, 50 tenths), so rank 2 doubles only the chance.
- `sim/warrior/talents.go:402` (Bastion 2% per point): confirmed, curve 2/4/6/8/10. TODO removed.
- `sim/warrior/talents.go:413` (2% per point): no TODO is left at this line in the code; the two remaining 2% per point
  talents, Bastion and Toughness, both read 2/4/6/8/10 in the client.
- `sim/warrior/talents.go:422` (Focused Rage 1 Rage per point): confirmed, curve -10/-20/-30 tenths of Rage. TODO removed.
- Baseline: Slam no longer resets the swing timer: the client puts this on Improved Slam ("In addition, Slam no longer
  interrupts your melee swing time"), which is how `slam.go` already models it. New in the client: a 15 sec cooldown
  on every Slam rank, now applied.
- Baseline: Thunder Clap usable in Defensive Stance: confirmed, `SpellShapeshift` mask is Battle + Defensive (Era: Battle).
- Baseline: Improved Shield Wall shortens the cooldown: confirmed, see above.
- Baseline: `sim/warrior/stances.go:41` Tactical Mastery: confirmed. Tactical Mastery 1310185 is a baseline passive
  (learned at 14) that retains 10 Rage, and Improved Tactical Mastery adds 3/6/9/12/15. `stances.go` already applies
  both (the checklist text predates that); the stale Battle Stance manifest note is corrected.
- Unread talent: Spearing Strike: implemented (numbers above). No shipped APL casts it yet.
- Unread talent: Blood Craze: implemented as a self heal (numbers above).

**Open**

- Baseline: Victory Rush: still not modelled. The client has it baseline at level 20 (402927): 30 sec cooldown, heals
  10% (Season of Discovery's version: 30%), dummy value 15. It still needs a killing blow, which a boss encounter
  never gives.
- Unread talent: Concussion Blow: a stun with no damage, and raid bosses are immune.
- Unread talent: Vanguard: lets Charge be used in Defensive Stance; the sim has no Charge.

## Spellbook diff (`--learned warrior` vs `--learned warrior --era`)

New in Forever:
- Tactical Mastery 1310185 (baseline passive, 10 Rage), modelled.
- Slam rank 1 1240193 (level 20, weapon + 16): Slam's old ranks each move up one (11605 is now "Rank 5"). The sim uses
  11605 at level 60, unaffected.
- Spearing Strike 1310222 (talent ability), implemented.
- Racials: Berserking 20554, Expansive Mind 1259802, Eureka! 1259813, Touch of the Grave 1260189 (core racials, not
  reviewed here), plus Journeyman Riding, Equip Transmog Outfit and two dummy spells.

Removed: Season of Discovery tuning passives 446658 / 446847, and the Era variants of Command 21563 and Berserking 26296.

Also changed in baseline spells the sim does not register: Taunt cooldown 10 -> 8 sec, Retaliation cooldown 30 -> 15 min,
Throw gains a 0.5 sec cast, Demoralizing Shout all ranks +40% and 45 sec, Battle Shout all ranks -40% and 3 min.
Devastate 403196 and Victory Rush 402927 still sit in the warrior skill line in both builds (Season of Discovery runes in
Era); Devastate is not in the Forever talent tree, so it is left out.

## Core changes needed (not made here)

- `sim/core/buffs.go` Battle Shout: rank 7 232 -> 139, rank 6 193 -> 111 (Era 185), and duration 2 -> 3 min (Booming
  Voice no longer extends it; it widens the radius). Other ranks: 9, 21, 33, 51, 78.
- `sim/core/debuffs.go` Demoralizing Shout: the warrior passes 5 Improved Demoralizing Shout points, so 146 x 1.4 = 204
  where the client gives 196 (base should be 140), and the duration should be 45 sec (Booming Voice no longer extends it).
- `sim/core/debuffs.go` Thunder Clap's aura: fine as is, the warrior now passes 20.

## Surprises in the data

- Sunder Armor has an explicit threat effect (`Effect 63`): 1, 405, 608, 810, 1013 by rank, about 17.5 per level against
  Classic's server side 4.5 per level. Applied as 1013 flat threat before stance and talent multipliers.
- Slam now has a 15 sec cooldown, which makes it a filler at best for Arms.
- Overpower carries a second power cost: 1 of power type 4 with `OptionalCost` 4. Nothing in the sim or in the tooltip
  explains it; left unmodelled.
- Thunder Clap's slow moved from aura 138 to aura 319 (melee attack speed only) and doubled.
- Recklessness moved from aura 52 to 290 (crit chance), same 100%.
- Two definitions share the name Two-Handed Weapon Specialization in the trait tables (1/2/3 and 3/6/9); the warrior tree
  export reads 1/2/3, which the sim uses.

## DPS (Average-Default)

| Test | Before | After |
|---|---|---|
| TestP1DPSWarrior (Fury) | 938.98 dps, 874.30 tps | 942.09 dps, 878.68 tps |
| TestP1TankWarrior (Protection) | 550.58 dps, 1164.90 tps, 662.98 dtps | 545.28 dps, 1174.53 tps, 635.99 dtps |
