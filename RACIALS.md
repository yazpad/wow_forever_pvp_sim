# WoW: Forever racial mechanics

Target the tuning in [Wowhead news 383457](https://www.wowhead.com/forever/news/class-racials-in-wow-forever-receive-tuning-adjustments-in-latest-build-383457), supplied by the user on 2026-10-16. Do not substitute Classic racial rules.

Implemented: Human Ruthless adds 2 percentage points of spell crit; Orc Savage
adds 1 point, without a weapon requirement. Base JSON `combat_stats` exclude
racials; loading adds these once and caps crit at 100%. Pets do not inherit them.
The editor summary includes these bonuses. Raw stat editing remains base stats.
Missing race defaults to Human and consequently receives Ruthless.

Also implemented for the supported caster kits: Expansive Mind (+5% maximum
Mana), Blood Fury, Berserking and Escape Artist. Mechanics, durations and
completion limits are tracked only in Visualizer TODO section 14 below.
The Gnome mana bonus is shown in setup/preview; exported stats remain unbuffed.

Select active racials in the Abilities loadout to make them available to MCTS.
Race, cooldowns and buff timers survive combat snapshots and worker restores.
The compact kits retain their 1-second minimum spell GCD.
Blood Fury uses the existing dynamic periodic-stat model; authentic Forever
DoT snapshot rules and owner weapon effects are still unverified/unmodeled.
Buff-specific replay icons/timers remain presentation work.

Verification sources (2026-10-16): [Blizzard’s official overview](https://news.blizzard.com/en-us/article/24304075/create-the-hero-you-want-to-be-in-world-of-warcraft-forever)
confirms +5% maximum resource and Orc Mage/Troll Warlock availability.
[Blood Fury](https://www.wowhead.com/forever/spell=20572/blood-fury),
[Berserking](https://www.wowhead.com/forever/spell=20554/berserking), and
[Escape Artist](https://www.wowhead.com/forever/spell=20589/escape-artist)
provide cast/GCD/cooldown details. Blood Fury’s indexed two-minute cooldown
is superseded by the pinned three-minute tuning article. Some indexed aura
fields show 11 rather than the 10% tooltip; use the pinned article/tooltips.

The [Ruthless](https://www.wowhead.com/forever/spell=20597/ruthless) and
[Savage](https://www.wowhead.com/forever/spell=20574/savage) tooltips match that
news, but their currently indexed effect fields say 3% and 2%. This implementation
pins the user-supplied article/tooltip values, pending clarification of that discrepancy.

The previous +10 Arcane/Shadow Resistance implementation was based on Classic
and has been removed. A legacy spell page existing under `/forever` does not
establish that a race still receives that spell.

The complete 20-entry implementation checklist, including every effect/value
found so far, source conflicts, unknown parameters and validation requirements,
is in [Visualizer TODO section 14](VISUALIZER_TODO.md#14-race-selection-and-racial-mechanics).
Keep mechanic-level progress there rather than maintaining a second inventory here.

Verify exact spell variants, cooldowns and eligibility before implementing further
active abilities. The five current races support both caster kits per Blizzard’s
matrix. Skyborne Mage is eligible but is not yet represented in the editor.


Will of the Forsaken (action 20) now clears Fear and Charm (Seduction), preserving
DR history. It is usable under those effects, costs no mana, uses a 1.5s GCD and
120s cooldown, and grants no lasting immunity. Horror, stun and Mage Polymorph
are not removed. Supported kits do not yet have a separate Sleep effect.
Blizzard's [Forever overview](https://news.blizzard.com/en-us/article/24304075/create-the-hero-you-want-to-be-in-world-of-warcraft-forever)
confirms the three cleansed categories; the [Forever spell data](https://www.wowhead.com/forever/spell=7744/will-of-the-forsaken)
provides the cooldown/GCD and usable-while-controlled flags (verified 2026-10-17).
