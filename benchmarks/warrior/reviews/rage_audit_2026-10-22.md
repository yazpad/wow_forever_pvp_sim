# Warrior rage audit — 2026-10-22

## Evidence and fixes

Audited against hash-pinned local Forever reference files, not assumed Classic
mechanics. This is reference parity work; provisional reference values still
need client measurements.

| Area | Finding | Change |
| --- | --- | --- |
| SIMD instant rage | Bloodrage and Improved Berserker Rage added rage to all 16 lanes whenever any lane cast | Mask both grants to the acting lanes |
| Berserker Rage | Incoming-hit rage multiplier absent | Apply 2x while the aura is active; follows provisional reference |
| Bloodrage | Incorrect GCD requirement and 1.5s GCD assignment | Permit during GCD; do not start/reset GCD |
| Heroic Strike queue | Allowed below the ability cost | Require 15 minus Improved Heroic Strike rank to queue; payment still deferred |
| Unbridled Wrath | Excluded Heroic Strike | Allow landed Heroic Strike to proc through its white-hit flag |
| Rage at cap | Heroic Strike's resource procs processed before cost | Spend/refund before applying on-hit resource procs |
| Flurry | Heroic Strike excluded from charge consumption | Include replacement swings through shared white-hit flag |

Sources: `core_rage.go`, `ruleset.go`, `talents.go`, `berserker_rage.go`,
`bloodrage.go`, `heroic_strike_cleave.go`, `core_flags.go` and `stances.go` in
`data/warrior_sources`. Four newly imported files have hashes in the manifest.

The SIMD leak is particularly relevant to neuroevolution: candidate fights in a
batch could get rage from unrelated lanes, while single-lane replay lacks that
source. Fixing it removes an artificial resource advantage during training.
Existing weight files remain loadable, but training should be resumed/repeated
against corrected mechanics; older champions may depend on the resource leak.

## Rules retained

- Landed white rage = base speed * 3.46 for 1H, or * 4.5 for 2H.
- Off-hand applies 0.5 * (1 + 0.2 * Dual Wield Specialization rank).
- Weapon damage, AP, crit and haste do not directly increase rage per swing.
  Haste increases swing frequency. Base-versus-hasted speed is a reference assumption.
- Misses/dodges/parries grant no white rage; a landed fully blocked hit still does.
- Heroic Strike replaces the MH white hit, generates no ordinary white-hit rage,
  and uses the special hit table. Unbridled Wrath is a separate possible proc.
- Improved Bloodrage scales immediate and periodic rage by 1 + 0.25 * rank.
- Stance retention caps existing rage at 10 + 3 * Improved Tactical Mastery rank.
- Incoming rage remains 10 * qualifying raw hit / maximum HP, now doubled during
  Berserker Rage. It is capped by maximum rage and excludes periodic damage.
- The pinned Go dispatch separates OnSpellHitTaken from OnPeriodicDamageTaken;
  adding Agony/Corruption/other periodic rage would contradict that reference.

For the earlier 12.03s reviewed fight, landed MH whites generated approximately
3 * 8.996 = 26.988 rage; seven OH whites at rank-5 DWS generated about 43.596.
The two landed Heroic Strikes spent 30 rage and displaced approximately 17.992
ordinary MH rage, before considering the corrected Wrath proc eligibility.
This explains why extra weapon damage alone would not fix rage starvation.
The earlier 4.5 incoming rage observation does not establish a missing decimal
factor: most incoming damage was Agony and therefore outside the direct-hit hook.

## Remaining discrepancies and uncertainty

The reference derives incoming rage from PreOutcomeDamage / ResistanceMultiplier,
including target-side damage modifiers but excluding critical multipliers, block
and resistance. The current compact path carries already-resolved spell payloads
and pre-armor resolved melee hits. Critical hits can inflate its rage input;
partial resists/blocks can reduce it. Target-side modifiers are not reproduced
exactly. Fixing this correctly requires preserving separate raw-hit metadata
through projectile queues and instant-hit resolution; inferring it from final HP
loss would be incorrect. Grouped same-hand physical events also remain an
approximation for incoming proc opportunities. These limits were already
documented and are explicitly retained rather than replaced with a guessed formula.

The coefficient 10, Berserker Rage's 2x and base weapon speed assumption still
require independent client validation. No weapon, AP, damage or policy tuning was
performed. No training benchmark or automated tests were run for this audit.
