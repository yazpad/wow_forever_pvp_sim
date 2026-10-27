# Level-60 reference stat profile

The new **Reference Level 60 Warlock / Mage / Priest (Provisional)** presets
opt into `"stat_profile": "level60_reference_v1"`. They use the existing caster
starter items and empty talents. They are stat comparison fixtures, not completed
PvP builds. Normal presets and specs without this field retain their existing
compact or explicit-stat behavior.

## What the profile calculates

The pinned snapshot in `data/stat_sources/forever_level60.json` supplies class
attributes, five race offsets, base spell crit and intellect crit coefficients.
The local engine's class/race attributes and level-60 intellect crit scaling
agree with its saved Wowhead Forever planner data. The importer checks both
sources, and hashes identify the actual source files.

Before talents and racial passives:

- Health = class base health + total stamina × 10 − 180.
- Mana = class base mana + total intellect × 15 − 280.
- Spell crit = engine base crit + total intellect × the pinned class coefficient
  + item crit. Convert percentage points to fractions before simulation.
- Armor = twice total agility + item armor; reduction = armor / (armor + 5,500).
  This adds raw armor before calculating reduction, rather than combining two
  independent reduction percentages as compact custom inputs do.
- Item power, resistances and equal-level spell hit use the existing catalog
  rules. The reference profile supports level 60 and the three caster kits only.

This project's existing racial passives apply afterward, once. Demonic Embrace
and Fel Vitality apply when installing stats in the simulator. Gnome changes the
mana pool, not intellect. Both simulator staging and the editor use that order.
Spirit is recorded in the source snapshot but still grants no regeneration.

## Source choices and unresolved conflicts

The engine has base spell crit of 1.7% Warlock, 0.2% Mage and 0.8% Priest; the
saved planner's corresponding values are zero. This profile explicitly chooses
the engine values. Agreement on attributes does not resolve this crit conflict.

The reference engine weapon-gates Human/Orc crit. This project instead retains
the caster racial tuning already pinned in [RACIALS.md](RACIALS.md): Human +2
percentage points, Orc +1, without a weapon requirement. Importing baseline data
does not replace that policy. Removed Classic racial resistances stay absent.

The reference stat dependency code multiplies and adds floating-point values;
it does not floor stamina, health or mana during those calculations. The profile
therefore retains fractional resources, including talent and racial effects.
Runtime arithmetic uses the simulator's existing `f32` representation; audit
expectations use Decimal. Client rounding, base crit, unsupported buffs and
remaining class talent stat effects still need validation before default
presets can be described as authentic character builds.

## Saves, overrides and editing

Explicit `combat_stats` remain final pre-racial totals, preserving manual edits
on load. They are not added to the profile again. A missing stamina field in a
geared export is recovered from the profile plus items without adding HP twice.

`gear_base_stats` and `stat_profile` are mutually exclusive. The editor exports
resolved stats and the profile marker, omitting `gear_base_stats`. Saving and
loading that export does not change totals. Clearing gear returns to the naked
reference baseline. Choosing a different race recomputes the reference baseline
and equipped stats; like re-equipping gear, it replaces manual total-stat edits.
Selecting a different class starts the existing compact workflow.

Use the preset picker to load a reference preset. The Gear summary identifies
reference stats as provisional. A headless spec can use the same marker with
or without `gear`; unlike loading a legacy Priest preset in the editor, a naked
reference Priest does not automatically receive items.

## Verification

`python3 scripts/audit_gear.py --check` verifies 32 independent reference cases:
three classes × five races × naked/geared, plus talent resources and an explicit
stat override. [REFERENCE_STAT_AUDIT.md](REFERENCE_STAT_AUDIT.md) lists the totals.
Lua checks compare editor saves, race changes, setup and Fight exports. Native
checks compare loading, both fighters and all simulator staging arenas.

To reproduce the pinned source checks:

```sh
python3 scripts/import_stat_reference.py --checkout /path/to/mythicsim-forever-engine-go --check
python3 scripts/generate_gear_catalog.py --check
zig build audit-gear
```

Regenerating source inputs is an explicit data update: run the importer without
`--check`, review source differences, regenerate native data, then review
`python3 scripts/audit_gear.py --write` output. Existing profile semantics should
receive a new version if a source-policy choice changes.

After building the fight generator, run
`python3 scripts/check_reference_replays.py`. Two short recorded fights check
three caster profiles, supported racial/talent resources, native search inputs
and both Lua/JSON replay maxima against the independent fixtures. This smoke
check verifies starting resources, not the complete combat behavior of a build.
