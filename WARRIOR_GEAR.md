# Warrior equipment

The Gear panel now offers **Two-hand set**, **Dual-wield set** and **Shield set**,
plus per-slot item selectors. The preset picker also includes three **Warrior
Item Starter** examples. These use eight Valor armor pieces and these weapon
options:

| Setup | Main hand | Off hand |
| --- | --- | --- |
| Two hand | Arcanite Reaper | Empty |
| Dual wield | Thrash Blade | Mirah's Song |
| Shield | Thrash Blade | Draconian Deflector |

These are partial starter inventories, not researched Pre-BiS or PvP-optimal
sets. Other slots are empty. Existing explicit-stat Warrior presets remain
available. Choosing a new Warrior still starts the existing explicit-stat setup;
item sets are selected with the buttons or preset picker.

## Data and ruleset

`data/warrior_gear.json` contains 12 fixed-stat Classic items, imported from the
local reference checkout's cached Wowhead **Classic** tooltips. Catalog and
individual source-row hashes pin the input data. Each item links to its Classic
source; weapon ranges/speeds, unique restrictions, armor and shield block value
are extracted from those tooltips. Inactive set bonuses are excluded.

This deliberately uses the same Classic item ruleset as the caster catalog.
The Forever planner has different values for some items; they are not silently
mixed into this catalog. For example, its Mirah's Song damage range and several
Valor attributes differ from the Classic cache.

The catalog includes only supported Warrior selections. Known-slot/class and
weapon restrictions, unique items and two-hand/off-hand conflicts are validated
in both the editor and native loader. Equipping a two-hander in the editor clears
the off hand; importing a conflicting loadout returns an error. One-handed swords
can occupy either weapon slot. A main-hand weapon is required while using item
gear; unarmed loadouts are not modeled. Clear items removes the loadout and
restores the previous explicit base stats and weapon configuration.

## Compact stat model

Item-only specs start from the compact Warrior equipment baseline: 4,000 HP,
zero baseline armor/stamina/avoidance, 700 AP, 5% melee crit and 95% white/special
hit. Mana has a one-point placeholder cap and is unused by Warrior combat.
These are simulator assumptions, not verified naked-character attributes.

Equipment contributes:

- Stamina × 10 health, Strength × 2 AP, plus direct item AP.
- Agility × 2 armor and 0.05 percentage points each of melee crit and dodge.
- Item armor, added to raw armor recovered from the baseline reduction; the
  combined reduction is armor / (armor + 5,500).
- Item melee hit/crit; item-resolved dual wield subtracts 19 percentage points
  from white hit before adding item hit. Special hit has no dual-wield penalty.
  Existing explicit `warrior` configurations keep their supplied probabilities.
- A shield supplies at least 5% block chance, its fixed block value, and
  max(0, item Strength / 20 − 1) block value, plus an explicit base block value.
  This treats baseline Strength as absent; its effects belong in explicit base
  inputs until a full Warrior attribute profile is implemented.
- Supported school resistances. Removing the shield clears equipment-derived
  block chance/value and never creates an off-hand weapon attack.

The local reference formula files are hashed in the catalog. Fractional stats
are retained. A shield's **Defense** stat is recorded but does not grant defense
scaling, avoidance or crit suppression. Spirit, Valor set bonuses and Thrash
Blade's proc are unsupported and identified in item tooltips. Weapon skill,
base/racial attributes, melee racials and authentic client rounding remain open.
Shield Bash/Shield Slam and other unsupported abilities are not enabled by an
item selection. Mid-fight weapon swapping is not implemented.

The physical simulation already supports separate dodge/parry/block resolution;
equipment fills those existing inputs. No additional per-tick gear lookup or
caster snapshot columns are introduced.

## JSON and overrides

The same `gear` object used for caster specs now accepts Warrior items. Optional
`gear_base_stats` supplies pre-item character totals, and `gear_base_warrior`
supplies pre-item AP, hit, crit and resource settings. Both are preserved in
editor saves so repeated loading/equipping does not compound item bonuses.

Explicit `combat_stats` and `warrior` objects remain final overrides on load.
Each object replaces its resolved counterpart using that object's existing
field defaults; an omitted field is not a partial merge with equipped totals.
Missing stamina in an old geared export is recovered without adding HP twice.
Item legality is validated even when final overrides are present. Editing gear
recalculates totals from saved bases and replaces manual total-stat edits.

The caster-only `level60_reference_v1` profile still rejects Warrior. This item
milestone does not certify a full Warrior baseline, talent build or race model.

## Validation and reproduction

[WARRIOR_GEAR_AUDIT.md](WARRIOR_GEAR_AUDIT.md) lists seven independent Decimal
cases: the three sets, a weapon-only spec, a missing armor piece, custom bases
and explicit overrides. Native and editor checks cover saving, swapping,
legality and base restoration. A combat check verifies swing timing, damage
ranges, off-hand attacks and guaranteed shield blocking with the equipped stats.

```sh
python3 scripts/audit_gear.py --check
lua visualizer/test_warrior_gear.lua
lua visualizer/test_workspace_gear.lua
```

To verify the source snapshot, run:

```sh
python3 scripts/import_warrior_gear.py --checkout /path/to/mythicsim-forever-engine-go --check
```

To refresh it deliberately, omit `--check`, review the catalog differences,
regenerate native data with `python3 scripts/generate_gear_catalog.py`, and review
`python3 scripts/audit_gear.py --write` output.

After building `mcts_fight`, run `python3 scripts/check_warrior_gear_replays.py`
to verify the three named item presets through two short melee fights. It checks
native weapon/defense inputs and both Lua/JSON replay resource maxima against
the independent fixtures. It does not certify the complete combat model.
