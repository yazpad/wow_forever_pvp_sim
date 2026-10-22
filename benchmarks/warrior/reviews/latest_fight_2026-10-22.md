# Latest Warrior fight review — 2026-10-22

Source: `matches/neuro_custom.lua.json` and its `.search.json`, recorded 15:29.
This review reads the existing replay and current implementation; no fights were rerun.

## Outcome and damage accounting

- Warrior lost at 12.03 seconds; Warlock finished at 1,849.2 HP.
- Warrior dealt 2,196 damage to the Warlock: 182.5 DPS.
- Soul Link redirected 30% to the living Voidwalker. Inferred combined player/pet
  damage was approximately 3,137 (260.8 DPS), including about 941 pet damage.
  The replay damage meter records player damage, not that redirected amount.
- Warlock healed 1,274.7: Death Coil 300, Siphon Life 222, Healthstone 752.8.
  Net player HP pressure was approximately 921.3 damage over the fight.
- Warlock dealt 4,000 damage: Agony 2,017.2, Shadow Bolt 1,673.8,
  Death Coil 309.3. Event rounding accounts for small sum differences.

| Warrior damage source | Damage to Warlock |
| --- | ---: |
| Main-hand white attacks | 549.6 |
| Off-hand white attacks | 566.9 |
| Heroic Strike | 662.5 |
| Whirlwind | 311.7 |
| Hamstring | 63.2 |
| Pummel | 42.1 |
| Bloodthirst | 0 |

## Mechanics and resource findings

Distance stayed between 0 and 2.8 yards: melee access is not the cause here.
The event stream shows five landed main-hand attacks (three white, two Heroic)
and seven landed off-hand attacks. Missing miss/avoid events prevent a complete
attempt-by-attempt audit from this replay alone. Swing intervals do not show an
obvious lost-swing/GCD stall.

Weapons remain the starter configuration: MH 90–135 at 2.6 seconds (43.3 weapon
DPS), OH 55–85 at 1.8 seconds (38.9 weapon DPS before the off-hand multiplier),
700 AP. These are not a named equipment set. White hit is configured at 76%
before talent bonuses, special hit 95%, and base crit 5% before talents/stance.

Rage peaked at 31.8; only 1.93 seconds of frames had at least 30 rage. Bloodthirst
was enabled in the saved action mask but never used; Whirlwind was used once.
Five Heroic Strike queue actions produced two landed Heroic Strikes; queueing
alone does not spend rage. Executing them spends rage and replaces white attacks
that otherwise generate rage (about 9 each for this MH), as the code intends.
Incoming direct-hit rage contributed only 4.5 total and Unbridled Wrath 8 total.
Agony, the largest incoming damage source, is periodic and excluded from the
current direct-hit-only incoming rage model.

Enrage was active throughout recorded frames; Flurry was active about 2.79
seconds. Those passives were not simply absent.

The current Forever white-hit implementation intentionally pays flat rage by
base weapon speed rather than damage. Incoming rage remains a documented
provisional model (10 * direct pre-armor hit / maximum health), so its low
contribution deserves an independent mechanics check before balance tuning.

## Conclusion

This replay does not demonstrate a missing damage multiplier or double armor
application. Modest starter weapons, limited rage, Heroic Strike's resource
tradeoff, Soul Link and substantial healing explain much of the observed low
pressure. Policy choices contribute (no Bloodthirst), but damage/resources and
opponent sustain should be assessed together. No combat stats, tactics or damage
formulas were changed during this review.

## Visual change

Overlapping portraits are separated in presentation coordinates, with colored
arrows pointing to their actual positions. Click targets follow the separated
portraits. Simulation coordinates, distance readouts and projectile positions
remain based on the replay. Visual changes were not runtime tested.
