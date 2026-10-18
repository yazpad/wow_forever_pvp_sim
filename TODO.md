# Project TODO — start here

Use this file for current priorities and links to detailed checklists. Keep
mechanic-level completion status in the relevant checklist rather than duplicating
it here. Last reviewed: 2026-10-16.

## Next implementation order

1. [x] Show active Soul Link and Demonic Sacrifice buffs on character unit frames
   in setup and playback. See [Visualizer section 13](VISUALIZER_TODO.md#13-soul-link-and-demonic-sacrifice-buffs).
2. [x] Implement Nightfall: eligible periodic/drain procs, Shadow Trance state and
   consumption, and instant next Shadow Bolt.
3. [x] Implement Improved Shadow Bolt: landed-crit trigger, Shadow vulnerability,
   duration, charges, consumption and refresh behavior.
4. [x] Implement Agonizing Flames: Searing Pain crit chance and Destruction damage.
5. Implement passive owner/pet stat talents, starting with Demonic Embrace and
   Fel Vitality, then Demonic Knowledge and Master Demonologist. Ensure maximum
   HP/mana and pet-dependent effects agree between simulation and visualizer.

Steps 2–5 are tracked in [WARLOCK_TODO.md](WARLOCK_TODO.md). This order prioritizes
making existing builds faithful before expanding the spell catalog.

## Which checklist to use

| File | Purpose |
| --- | --- |
| [TODO.md](TODO.md) | Current priorities and entry point for all TODOs. |
| [PRIEST_TODO.md](PRIEST_TODO.md) | Forever Priest class implementation status, SIMD column mapping, and remaining talents/spells. |
| [WARLOCK_TODO.md](WARLOCK_TODO.md) | Warlock spells, talents, pets, combat accuracy and mechanic validation. |
| [VISUALIZER_TODO.md](VISUALIZER_TODO.md) | Arena/editor UI, replay presentation and visual validation. |
| [MCTS_TODO.md](MCTS_TODO.md) | Search, performance and historical implementation roadmap. Older UI/combat entries may be superseded by the focused checklists. |

## Warlock status and later work

The simulator supports 15 combat actions, autonomous pet attacks, periodic
scheduling/crits, hit/resist resolution, pushback, Soul Link and initial Demonic
Sacrifice effects. Talent selection in the editor does not guarantee a runtime
effect: many talents remain missing or partially modeled. Consult the detailed
Warlock checklist before relying on a build comparison.

- Finish partial existing talent hooks: Cataclysm beyond Shadow Bolt, timed
  Shadowburn/Shadow and Flame behavior, and remaining pet utility effects.
- Expand spells: curses, Wrack, Bane of Doom, Soul Fire, Drain Soul/Mana, armor
  buffs and Health Funnel. Life Tap and Curse of Weakness remain excluded.
- Finish pet mechanics: Voidwalker Sacrifice shield, Devour Magic/dispels,
  authentic melee abilities, pet mana and mid-fight summoning/replacement.
- Verify Forever resistance formulas and baseline/gear-derived stats.
- Record and display per-spell misses, full/partial resists and critical strikes
  through missile travel and simultaneous impacts.

Health-bar colors and Voidwalker disappearance with Sacrifice: none were fixed
and validated on 2026-10-16; see Visualizer section 12.

## Race selection

Race selectors now sit beside class selectors in the left panel and persist in
editor presets and Fight snapshots. Simulator specs now validate race/class combinations, and MCTS recordings retain
race. Forever Ruthless (+2% spell crit), Savage (+1% spell crit), Expansive Mind
(+5% maximum mana), Blood Fury, Berserking and Escape Artist have caster runtime
effects. Select active racials in the Abilities loadout. Orc Mage and Troll
Warlock combinations are supported;
see [RACIALS.md](RACIALS.md) for the pinned tuning source and limitations.
The complete 20-racial checklist, known mechanics, tuning conflicts and remaining
verification tasks are in
[Visualizer section 14](VISUALIZER_TODO.md#14-race-selection-and-racial-mechanics).

## Gear stat audit

- [ ] Audit selected gear against independently calculated expected character
  stats, including Pre-BiS totals, baseline assumptions, talent/buff effects and
  agreement between editor, simulator and replay. See
  [Visualizer section 15](VISUALIZER_TODO.md#15-gear-defaults-and-stat-audit).
