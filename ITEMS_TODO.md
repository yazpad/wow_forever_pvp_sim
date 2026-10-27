# Items and equipment roadmap

Make equipment a first-class simulator input for normal geared fights. Keep
explicit gearless fixtures for mechanic isolation and historical comparisons.

## Existing support

- [x] Offline fixed-stat caster catalog, 17 equipment slots, starter loadouts,
  editor selection and saved equipment (`visualizer/gear.lua`,
  `data/vanilla_gear.json`).
- [x] Resolve caster gear into combat stats for Fight setup, resource caps,
  search snapshots and replay. See [GEAR.md](GEAR.md) for current limitations.
- [x] Native caster item resolution from the shared offline catalog, with
  frozen editor parity fixtures. Explicit exported `combat_stats` retain
  precedence; gear-only specs resolve from `gear_base_stats` or compact defaults.
  Initial Warrior item loading is now supported; see [WARRIOR_GEAR.md](WARRIOR_GEAR.md).
- [ ] Item actives, procs, enchants and set bonuses.

## 1. First milestone: consistent equipment and stats

- [ ] Pin the intended item ruleset and data provenance. Existing gear is
  Vanilla level 60; class mechanics include Forever changes. Record overrides
  explicitly rather than assuming those sources agree.
- [ ] Audit base class/race attributes and derived stats before expanding the
  catalog. Track base, item, talent and buff contributions separately; replace
  compact defaults for normal geared presets once verified.
  Independent arithmetic and local reference comparison are now recorded in
  [GEAR_AUDIT.md](GEAR_AUDIT.md); authentic class/race inputs remain unverified.
- [ ] Define a versioned equipment schema: item IDs, slots, empty slots, weapon
  metadata, and explicit stat-override precedence. Preserve legacy specs without
  silently adding gear or counting exported stats twice.
- [ ] Resolve equipment in the native spec-loading path so headless CLI,
  training, search and editor fights share the same validated inputs. Use one
  canonical catalog/formula definition or generated data with parity checks.
  Caster native resolution and frozen editor parity checks are implemented;
  Warrior equipment and the broader verified stat model remain open.
- [ ] Validate unknown IDs, class/armor/weapon restrictions, unique items,
  duplicate slots and two-hand/off-hand conflicts. Report invalid loadouts
  instead of silently repairing imported specs.
- [ ] Audit caster health, mana, armor, school power, hit, crit and resistances;
  show unsupported stats/effects explicitly. Spirit currently adds no regen.
- [x] Add initial Warrior weapons, shields and starter equipment; derive damage ranges,
  speed and melee stats from equipped items. Coordinate with
  [Warrior equipment work](WARRIOR_TODO.md#6-gear-stats-and-race).
- [ ] Expand the catalog with source-verified PvP candidates and class-valid
  starter sets, including a researched Priest set.

Acceptance: the same loadout produces independently checked totals in editor,
native CLI and replay; saving/loading/re-equipping does not change those totals;
a weapon swap changes Warrior damage and ability eligibility correctly.
The existing [stat audit](VISUALIZER_TODO.md#15-gear-defaults-and-stat-audit)
remains the detailed UI checklist.

## 2. On-use items

- [ ] Select a small, source-verified initial set: a PvP control-break trinket
  and a temporary stat-buff item. Document supported effects and exclusions.
- [ ] Define effect IDs, targeting, duration, charges, cooldowns, shared cooldown
  groups and combat eligibility independently of item display names.
- [ ] Derive available item actions from equipped items; expose legality and
  cooldowns to search and the editor without fixed per-class item slots.
- [ ] Include active effects, charges and cooldowns in reset, cloning and MCTS
  snapshots. Preserve seeded reproducibility and resource-cap behavior.
- [ ] Record equipped items and activation/expiration events; display item
  cooldowns and buffs in playback. Replays must retain their starting loadout.

Acceptance: an unequipped item cannot activate; cooldown sharing and effect
expiration work; restoring a search snapshot reproduces the same outcome.

## 3. Procs and broader item mechanics

- [ ] Add explicit trigger events, eligibility, proc chance or PPM rules,
  internal cooldowns, stacking and refresh policy for selected audited effects.
- [ ] Resolve event ordering, periodic/pet eligibility and proc recursion rules;
  route randomness through the existing deterministic simulation RNG.
- [ ] Add enchants and set bonuses using the same stat/effect machinery.
- [ ] Add random suffixes, consumables and weapon swapping only after their
  rules and intended scope are documented.

## 4. Validation and rollout

- [ ] Add independent expected-total fixtures, legal/illegal loadouts and
  legacy-spec compatibility checks for the first milestone.
  Eight independently calculated full-set/swap cases now cover editor, native
  loading, setup and Fight export. A focused native staging/snapshot test checks
  racial/talent resource contributions. Broader replay comparison remains open.
- [ ] Add focused combat checks for each implemented effect, including resets,
  simultaneous events, snapshots and replay consistency.
- [ ] Benchmark representative geared matchups and search throughput; keep
  immutable item definitions outside mutable per-tick/snapshot state.
- [ ] Version training/evaluation loadouts and record catalog/ruleset identity
  so gear changes cannot silently alter model comparisons.
- [ ] Document supported items/effects and switch normal starter workflows to
  the verified geared presets; retain explicitly labeled gearless benchmarks.

Recommended implementation order: milestone 1, then one complete on-use item
through simulation/search/replay, then additional effects. Do not treat a
selectable item as fully supported when its effect is still missing.

### Native caster resolution validation (2026-10-23)

All 14 spec-loader tests and both Lua gear suites pass, including frozen
Warlock/Mage/Priest totals, invalid equipment and legacy stat overrides.
The full ReleaseFast/x86_64_v3 suite reports 184/186 passing. Remaining failures:
`pet snapshots replay exactly through both action staging paths without new choices`
and `forced choices need no simulations and preserve combat state`.
Both pass in isolation with the original spec loader; the full-suite failure
cause was unresolved at that milestone. It was later traced to uninitialized
unused Warlock action-mask slots; see the regression fix below. No combat/search
behavior was changed in the original equipment milestone.

### Independent arithmetic audit (2026-10-23)

`python3 scripts/audit_gear.py --check` verifies eight frozen cases using Python
Decimal without importing either runtime resolver. The audit is a build gate
and is also available as `zig build audit-gear`. See [GEAR_AUDIT.md](GEAR_AUDIT.md)
for item totals, unsupported effects and pinned local reference comparisons.
The default 2,000 HP / 1,000 mana profile remains unchanged: reference base
attributes, crit, racial offsets and talent rounding require further validation.

### Opt-in level-60 reference profiles (2026-10-23)

`level60_reference_v1` now resolves three caster classes and five races through
native loading and the editor, with explicit class/race attributes, reference
crit coefficients and additive raw armor. Three provisional presets expose it
without migrating existing compact/custom specs. Thirty-two independent cases
cover naked/geared stats, saved overrides and supported resource talents.

The importer verifies class attributes, race offsets and crit scaling against
the saved local Forever planner. Base crit conflicts (engine nonzero, planner
zero), weapon-gated engine racials versus this project's pinned caster tuning,
and unverified client rounding are documented in [STAT_PROFILES.md](STAT_PROFILES.md).
Normal preset migration and authentic client validation remain open.

Two short CLI fights now check provisional profile resources through native
search inputs and recorded Lua/JSON metadata for all three casters, including
Gnome + Demonic Embrace + Fel Vitality. Reproduce with
`python3 scripts/check_reference_replays.py` after building `mcts_fight`.
This verifies starting resource totals; full combat replay validation remains open.

Final profile validation: all 15 native loader tests, both Lua gear suites,
32 independent profile cases and two recorded-fight smoke checks pass. The
full ReleaseFast/x86_64_v3 suite passes 187/189 tests, retaining the same two
pet-snapshot/forced-choice MCTS failures recorded above; all new gear/profile
integration tests pass.


### Initial Warrior equipment (2026-10-23)

Twelve pinned Classic items now support three partial starter inventories in
the native loader, editor and preset picker. Shared validation handles class,
slot, unique and two-hand/off-hand restrictions. Item ranges/speeds drive swings;
shield blocks use existing physical resolution and never create an off-hand
attack. Seven independent cases cover totals, bases, overrides and saves.

Explicit `combat_stats` / `warrior` remain final overrides. `gear_base_stats` /
`gear_base_warrior` retain the pre-item inputs for repeatable recalculation.
The base is still a compact model: authentic Warrior attributes, defense,
weapon skill, melee racials, proc/set effects and broader item choices remain
open. Details and source hashes: [WARRIOR_GEAR.md](WARRIOR_GEAR.md).

Warrior milestone validation: all 16 native loader tests, the equipped-swing/block
integration check, Warrior gear/UI checks and workspace exports pass. All 17
Warrior selectors remain reachable with bounded menus at three window sizes.
Two recorded Warrior fights cover all three item presets; caster replay smoke
checks also pass. Full ReleaseFast/x86_64_v3 regression: 189/191 passing, with
the same two previously recorded pet-snapshot/forced-choice MCTS failures.


### Warlock action-mask regression fix (2026-10-23)

Both recurring pet-snapshot/forced-choice MCTS failures shared one cause:
Warlock mask builders left unused shared-catalog slots 21–25 uninitialized.
Stack contents could make placeholder actions appear legal, changing choices
between calls or preventing the forced-no-op search shortcut under Horror.
Both builders now initialize every slot to false before enabling supported
actions. The original failing assertions are retained, and a new regression
checks placeholders across both actors, all SIMD lanes, races, pets and control
states through raw and class-aware mask APIs. Focused tests and recorded-fight
smoke checks pass.

Regression baseline restored: the full ReleaseFast/x86_64_v3 suite passes
192/192 tests on two consecutive runs. The rebuilt fight generator also passes
both caster-reference and Warrior-equipment recorded-replay smoke checks.
The earlier pet-snapshot and forced-choice failures are resolved.
