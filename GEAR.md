# Vanilla pre-raid gear

The visualizer's **Gear** section has a selector for each of the 17 equipment slots, an **Equip pre-BiS** button, and a clear button that restores the previous base stats. Gear belongs to each player's spec and is included in saved specs and temporary Fight specs. Both starting fighters and newly selected classes default to their class Pre-BiS set. Explicit saved equipment is preserved, including empty slots. Loading a gearless preset manually retains its original stats until gear is selected.

The offline catalog (`data/vanilla_gear.json`) contains 37 fixed-stat caster Vanilla candidates, including Dire Maul. Recommendations are based on the [Icy Veins Mage](https://www.icy-veins.com/wow-classic/mage-dps-pre-raid-gear) and [Warlock](https://www.icy-veins.com/wow-classic/warlock-dps-pre-raid-gear) pre-raid lists. These are PvE pre-raid starting points, not PvP-optimal sets. The preset uses fixed-stat alternatives where lists recommend random “of Wrath” items. It includes crafted profession/class items and an Alliance quest ring (Songstone of Ironforge); the equivalent Horde ring is available in the dropdown. It is not restricted to launch-phase availability.

Item IDs and passive stats are imported from Wowhead's **Classic** tooltip endpoint, with a source link on every record. Inactive set bonuses are excluded. The Archivist Cape entry explicitly includes only its deterministic base stats. Regenerate from the repository root with `python3 scripts/import_vanilla_gear.py` (requires network access). Then run `python3 scripts/generate_gear_catalog.py` to refresh the native catalog. Builds check that the generated catalog matches the JSON. No network is needed to use either resolver.

## Resolution

Native spec loading now validates and resolves caster `gear` item IDs from the
same offline catalog as the editor. Omitted slots and item ID `0` are empty.
Unknown slots/IDs, invalid slot/class combinations, duplicate unique items and
two-hand/off-hand conflicts are rejected. Initial Warrior weapon, armor and shield loadouts are supported; see
[WARRIOR_GEAR.md](WARRIOR_GEAR.md).

Precedence preserves existing editor saves: explicit `combat_stats` are final
pre-racial totals (including manual overrides), so equipment is validated but
never added again. Legacy exports missing `stamina` recover it from equipment
without adding health twice. Without `combat_stats`, items add to `gear_base_stats`, or to
the compact defaults if no base is supplied. An explicit
`stat_profile: "level60_reference_v1"` instead selects the provisional class/race
baseline described in [STAT_PROFILES.md](STAT_PROFILES.md). Race passives then apply once.
Specs without a profile retain their previous gearless behavior. A frozen three-class fixture
checks editor/native parity; this does not verify authentic class/race baselines.

Gear adds to the existing compact simulator baseline (normally 2,000 health and 1,000 mana), rather than selecting a Vanilla race's base attributes:

- Each point of gear stamina adds 10 health; intellect adds 15 mana and class-specific spell crit (59.5 intellect per 1% for Mage; 60.6 for Warlock).
- Equipping gear selects level-60 equal-level PvP hit: 96% base, plus item spell hit, capped at 99%. Talent hit bonuses remain in the engine.
- Generic spell damage adds to each supported damage school. School-specific damage adds only to that school. Direct spells and periodic damage/healing use explicit coefficients before existing talent multipliers; pets do not inherit owner spell power.
- Armor contributes physical reduction using `armor / (armor + 400 + 85 * 60)`.
- Resource caps, search staging, snapshots, Fight setup and replay bars use the resolved maximum health and mana.

The simulator remains a compact kit, including non-Vanilla abilities and shorter durations. Spell-power integration uses Vanilla-style coefficients for shared spells, adapted to the compact DPS/tick model; it does not make the full combat model patch-accurate. Spirit is totaled but does not change the existing mana regeneration model. Random suffix rolls, enchants, consumables, item procs and on-use effects are excluded. The available set pieces cannot activate any set bonus in this catalog.

Checks: `lua visualizer/test_gear.lua`, `lua visualizer/test_workspace_gear.lua`, and `zig build test -Doptimize=ReleaseFast -Dcpu=x86_64_v3`. Zig 0.14's Debug/native build may fail with LLVM's `Cannot emit physreg copy instruction` on AVX-512 hosts.


Priest now uses the shared caster starter set with the unrestricted Robe of
Winter Night instead of a class-restricted robe. Both Priest presets persist
this valid loadout and its resolved stats. This is a comparable temporary caster
set, not a newly researched Priest pre-BiS recommendation. Priest currently uses
the editor's shared non-Warlock intellect-to-crit conversion.

## Independent stat audit

[GEAR_AUDIT.md](GEAR_AUDIT.md) records independently calculated item contributions,
full starter totals, representative swaps, and a comparison with pinned local
Forever base attributes. Eight frozen cases agree across Python Decimal, Lua
and Zig; setup and exported Fight inputs agree with the same expected totals.
A native staging/snapshot check also verifies gear plus Gnome, Demonic Embrace
and Fel Vitality resource bonuses are applied once.

Run `python3 scripts/audit_gear.py --check` or `zig build audit-gear` to verify the
frozen totals and report. This audit does not certify the imported item data or
switch normal presets to authentic class/race baselines. The report identifies
remaining baseline, rounding, supported-effect and replay verification work.

## Provisional class/race profiles

The preset picker now includes Reference Level 60 Warlock, Mage and Priest.
They opt into pinned local reference attributes, race offsets, crit scaling and
additive raw armor. [STAT_PROFILES.md](STAT_PROFILES.md) explains the base-crit
source conflict, pinned caster racials and unrounded floating-point policy.
[REFERENCE_STAT_AUDIT.md](REFERENCE_STAT_AUDIT.md) lists all 32 checked cases.
Normal presets retain the compact baseline until client/source conflicts are
resolved. Race changes in a reference profile recompute equipped totals.

## Warrior item starters

Warrior now has a separate, pinned Classic catalog of 12 items, three starter
loadouts, editor selectors and native resolution. Weapons drive damage/speed;
shields drive armor and block inputs without creating an off-hand attack.
[WARRIOR_GEAR.md](WARRIOR_GEAR.md) documents the compact baseline, override rules
and unsupported effects. [WARRIOR_GEAR_AUDIT.md](WARRIOR_GEAR_AUDIT.md) lists seven
independently checked cases. Existing explicit weapon presets remain available.
