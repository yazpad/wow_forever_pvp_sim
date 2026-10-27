# Visualizer workspace checklist

Start with [TODO.md](TODO.md) for current priorities and checklist ownership.

Goal: edit either fighter's spec, see the setup immediately in the arena,
adjust starting positions, and run a fight from that setup.

Navigation is consolidated into the Arena workspace. Fight replays and Matrix
are collapsible, scrollable sections under Settings. Arena is the only top-level
entry; Analysis remains implemented but hidden. F2/F4 toggle and reveal the
corresponding Settings section, including for --fights/--matrix launches.

Current progress: the Arena workspace has separate fighter drafts, scrollable
spec controls, live summaries, Save spec, and Fight from temporary snapshots.
Both characters can be dragged to starting coordinates. The existing Arena
renderer, effects, telemetry, timeline, and camera controls run inside the center
panel in Playback mode. Edit positions returns to setup and preserves drafts.
Editing a spec automatically returns to setup. Setup and playback now share the
arena renderer, grid, camera, fighter/pet tokens and telemetry HUD. Zoom/pan and
camera reset work in both modes, and mode switches preserve framing. Settings now use reusable dropdown menus with direct option selection, current-value
highlighting, Escape/outside-click dismissal, and input blocking. The real Love2D repeat-fight flow is now validated. Player specs now use
mutually exclusive collapsible sections, stacked talent icon trees, and an editable
ability icon grid. Each talent school has a collapsible illustrated panel; open
state is remembered separately for each player and class, with point totals visible
when collapsed. Clicking either arena fighter selects its section in setup or
playback; starting positions move only after a five-pixel drag threshold.

Validation: ReleaseFast simulator build; Lua syntax and scripted checks for
drafts, stats, pets, dragging, snapshots, simulator coordinates and pet placement;
embedded playback checks covering updates, scrub/play controls, zoom, edit/replay
switching, and coordinate mapping at 960x540, 1280x720, and 2560x1080. Reviewed the
running GUI and a screenshot of embedded playback at 2560x1080.
Shared-arena regression checks (`lua visualizer/test_workspace.lua`, also run with
LuaJIT) cover rendering, both fighters' dragging at 45/100/300% zoom with pan,
coordinate round trips, mode switching, live class/pet updates and legacy replay
rendering at 960x540, 1280x720 and 2560x1080. Reviewed an offscreen Love2D setup
screenshot at 1280x720 with real fonts/icons. Spec-panel checks also cover draft
preservation, collapsing/expanding both players, selecting recorded fighter
positions, click jitter, talent allocation/removal, pet/talent loadout restrictions
and the loadout passed to Fight. Reviewed offscreen Love2D talent/ability panels,
hover details at 1280x720, and Player B expanded at 960x540. The real Love2D repeat-fight check now covers this flow. School-collapse checks cover all six schools, independent
player/class state, unchanged drafts and playback preservation at three window
sizes. Reviewed illustrated expanded/collapsed panels in offscreen Love2D at
1280x720 and 960x540. Background atlas and generation prompt are in
`visualizer/art/`. Dropdown regression checks cover every Settings option, launch
values, menu bounds, dismissal, and underlying-input blocking with Lua and LuaJIT
at all three window sizes. Preset selection now reuses these menus with named choices and a “Preset: <Name>” label; player and school headers use drawn chevrons. Preset regression checks cover both players, preservation of the other draft/settings/positions, return from playback to setup, selected-value highlighting, dismissal, empty libraries and scrolling long libraries at all three window sizes. Real Love2D dropdown bounds and dismissal were reviewed at all three sizes.

Classic unit frames now share one renderer for Warlock and Mage in setup and
playback, with circular class portraits, inset nameplates, HP/MP bars, a gold
selected-player ring, cast/channel bars, cooldowns, buffs/debuffs, shield totals,
and pet identity/health. Regression checks cover distinct telemetry for both
sides, cast countdown/direction, all eight simultaneous effects, icon bounds,
and legacy rows with missing optional columns. Lua and LuaJIT workspace checks
pass. Reviewed real Love2D setup at 1280x720 and mixed-class combat screenshots
at 960x540 and 2560x1080, including a full effect row and Mage shield absorb.

Player headers now use class-colored borders, prominent class-icon menu buttons,
player titles and clipped class/spec subtitles. Class menus contain only Warlock
and Mage (Frost), work while collapsed, and leave section expansion unchanged.
Separate text class buttons are removed. School headers have inset borders,
clearer spacing, chevrons and point totals over the retained artwork. Regression
checks exercise both players in expanded/collapsed states at all three sizes,
preserve the other draft and shared settings/positions, verify live class/pet/
talent updates and Fight loadout/stat snapshots, and check menu dismissal and
same-class selections. Reviewed real Love2D headers/artwork at 1280x720 and
2560x1080 and Player B expanded with Player A's class menu open at 960x540.

Center-view cleanup is complete: fighter tokens use six-pixel HP and three-pixel
MP bars without numeric HP labels; pet tokens retain icons and thinner health
bars without name/HP text. Setup guidance is windowless text at the bottom,
with coordinates and distance retained and crit/hit/ability summaries removed.
The vacated setup footer also accepts fighter selection/dragging above the text;
playback keeps its scrubber panel. Lua/LuaJIT workspace checks and Lua syntax
checks pass. Reviewed real Love2D setup at 960x540 and 1280x720 and mixed-class
playback with depleted HP/MP, casts and effects at 2560x1080.

The arena banner is removed in setup and playback. Classic frames start at the
reclaimed top edge and fighter hit regions follow the new HUD bounds; playback
timing, outcome and zoom readout are in the scrubber footer. Settings scrolls
independently with Fight/status fixed below. Replays show names, date, duration,
damage and outcome, and load into center playback. Matrix retains spec filters,
batch presets, run/refresh controls, progress/errors and replay actions, using a
vertical matchup result list to fit the narrow panel. Analysis and the separate
Fights/Matrix tabs are hidden; F2/F4 reveal their Settings sections and F5/Tab no
longer navigate to hidden screens. Legacy launch flags open the matching section.
Lua/LuaJIT regression checks cover replay loading, scroll/input bounds, shortcut
routing, draft/settings/camera preservation, Matrix filters, batch pair counts,
preset launch values and replay actions. Reviewed real offscreen Love2D setup,
playback, Matrix controls and scrolled matchup results across 960x540, 1280x720
and 2560x1080. The real Love2D repeat-fight check now covers this flow.

Repeat-fight validation is complete. `visualizer/tests/repeat_fight` runs the real
Love2D event handlers, worker thread and ReleaseFast simulator twice. It enters
an unsaved stat through the GUI, switches players, drags both fighters, resizes,
clicks Fight, verifies recorded stats/talents/ability masks/HP/pets/coordinates,
returns to setup, changes pet/talent/loadout/position, and launches again while
preserving the other draft. Temporary snapshots are verified and cleaned by the
worker. Real dropdown Escape/outside-click dismissal and bounds pass at 960x540,
1280x720 and 2560x1080; screenshots were reviewed. A separate real CLI launch with
`--distance 20` verified centered starting coordinates without explicit position
overrides. ReleaseFast build, Lua/LuaJIT workspace checks and Lua syntax checks
pass. The review also removed the stale left-panel generation message and formats
drag-derived distance values to one decimal place. Commands are in CLI_REFERENCE.

## 1. Panel workspace and shared setup

- [x] Introduce shared fight setup state for both specs, pets, stats, starting
  positions, and simulation settings.
- [x] Place Specs on the left, Arena in the center, and Settings with the Fight
  button on the right.
- [x] Add a Fighter A/B selector to the Specs panel, preserving each fighter's
  edits when switching between them.
- [x] Adapt the existing spec editor and settings controls for panel widths,
  scrolling, and window resizing.
- [x] Keep setup preview and replay state distinct, with a clear way to return
  to setup and preserve edits after playback.

## 2. Live spec editing and fight generation

- [x] Connect talents, stats, pets, and ability edits to the shared setup.
- [x] Immediately reflect edits in arena portraits, labels, pets, and stat
  summaries.
- [x] Run Fight using the current edited specs without requiring a manual save;
  pass complete spec snapshots to the simulator.
- [x] Capture the setup at fight launch so edits during generation cannot change
  the running fight or its recorded metadata.
- [x] Show generation progress and actionable errors in Settings, and load the
  completed fight into arena playback with controls below it. Generation status and
  simulator errors are shown; playback runs in the center panel.
- [x] Keep saving and loading named specs available for reuse.

## 3. Starting positions

- [x] Add individual starting coordinates to the simulator launch interface and
  replay metadata, retaining compatibility with distance-based launches.
- [x] Make both characters draggable in setup, using arena world coordinates
  and respecting arena bounds.
- [x] Display starting coordinates and distance, with a reset to default positions.
- [x] Ensure character dragging works with arena resizing, zoom, and pan.
- [x] Initialize fighters and pets consistently from the selected positions and
  use those positions in the generated fight.

## 4. Seamless setup and playback visuals

- [x] Use the same arena presentation in setup and playback: grid, world scale,
  camera framing, character tokens, labels, pets, and health/resource displays.
- [x] Preserve the camera position and zoom when switching between setup and
  playback so the center panel does not visually jump or change layouts.
- [x] Keep the arena and HUD layout consistent while changing the available
  controls for editing starting positions versus playing a recorded fight.
- [x] Make spec changes immediately visible in the shared setup presentation.

## 5. Collapsible player specs with icons

- [x] Replace the Fighter A/B selector and text-heavy spec list with two
  collapsible sections in the left panel, one for each player.
- [x] Expanding one player's section collapses the other while preserving both
  players' drafts.
- [x] Clicking a character in the 2D arena expands that player's spec section
  and collapses the other, in both setup and playback.
- [x] Distinguish character selection from dragging so selecting a player does
  not accidentally move their starting position.
- [x] Stack the selected player's talent trees vertically, using talent icons
  with visible ranks and editable point allocation.
- [x] Make each talent school independently collapsible, retaining its point
  total while collapsed and remembering open state per player/class.
- [x] Add school-specific background artwork behind the talent nodes and headers.
- [x] Show the abilities taken into the simulation as a grid of icons, with
  names/details on hover and a clear way to edit the loadout.
- [x] Keep the ability grid synchronized with the actual simulation loadout,
  including talent and pet restrictions.
- [x] Keep stats and pet controls accessible within each player's expanded
  section, with scrolling that works at smaller window sizes.

## 6. Dropdown menus

- [x] Add a reusable dropdown control with a visible current selection and an
  explicit menu of choices, replacing click-to-cycle selection.
- [x] Replace the Worker threads cycle button with a dropdown listing all
  supported thread counts.
- [x] Use dropdowns for the other Settings choices: rollouts per decision,
  algorithm, leaf scorer, and starting distance.
- [x] Support selecting an option, highlighting the current value, dismissing
  with Escape or an outside click, and keeping menus within the window bounds.
- [x] Ensure open menus appear above panels and consume input so clicking an
  option cannot also activate an underlying control or drag an arena fighter.

### Remaining selectors and expand/collapse indicators

- [x] Replace the literal `v` / `>` indicators on Player A/B and talent-school
  headers with drawn chevrons that reflect expanded/collapsed state.
- [x] Replace “Next saved spec” with a dropdown labeled “Preset: <Name>”, showing
  the current preset name and allowing direct selection from named saved specs.
- [x] Reuse the Settings dropdown styling and input handling for the preset menu;
  preserve the other player's draft and shared setup when selecting a preset.

## 7. Classic-style unit frames

- [x] Redesign both arena unit frames to resemble classic unit frames: a
  prominent circular portrait, framed nameplate, health bar, and mana bar.
- [x] Use consistent portrait and bar proportions, readable names and vitals,
  and a clear selected-player indication for both Warlock and Mage.
- [x] Arrange cast bars, buffs/debuffs, cooldowns, and pet information around
  the classic frame without obscuring the arena or losing existing telemetry.
- [x] Apply the same frame styling in setup and playback, with live draft
  values in setup and recorded values during playback.
- [x] Keep both frames readable and free of overlap at smaller window sizes.

## 8. Left-panel visual redesign and class selection

- [x] Redesign the player and talent-school collapsible sections with clearer
  hierarchy, spacing, borders, and expand/collapse indicators; improve the
  current button-like headers while retaining school background artwork.
- [x] Make each player's current class icon a prominent part of its header,
  visible while the player section is expanded or collapsed.
- [x] Clicking the class icon opens a class-selection menu containing only
  Warlock and Mage (the currently supported Frost Mage implementation).
- [x] Replace the separate Warlock/Frost Mage text buttons with this icon-based
  class selector and provide a hover hint that makes its purpose discoverable.
- [x] Keep class selection distinct from expanding/collapsing the player section
  and from selecting a fighter in the arena.
- [x] Reflect a class change immediately in the player's icon, talent schools,
  abilities, stats/pet controls, arena presentation, and next Fight snapshot,
  preserving the other player's draft and shared starting positions/settings.

## 9. Center 2D view cleanup

- [x] Remove pet-name labels from arena pet tokens; keep the identifying icons.
- [x] Make arena token HP bars thinner and remove numeric remaining-HP labels.
- [x] Add a thin MP bar alongside the token HP display.
- [x] Replace the framed “Drag fighters / wheel to zoom” help window with a
  windowless text label at the bottom of the center view.
- [x] Remove the A/B crit, hit, and ability-count summaries from the center view.

## 10. Remove the arena banner

- [x] Remove the entire top banner inside the 2D view that says “PVP ARENA”,
  reclaiming its space in both setup and playback.
- [x] Adjust arena/HUD spacing and hit regions after removing the banner;
  keep camera controls and playback timing available where needed.

## 11. Replays and Matrix under Settings

- [x] Add a collapsible Fight replays section under Settings containing the
  existing replay browser; selecting a replay loads it into center playback.
- [x] Remove the separate Fights tab and update navigation/shortcuts to match.
- [x] Add a collapsible Matrix section under Settings, preserving the existing
  matrix functionality within the consolidated workspace.
- [x] Remove the separate Matrix tab and update navigation/shortcuts to match.
- [x] Hide Analysis and remove its top-level navigation entry for now, retaining
  its implementation for future use.
- [x] Keep the Settings sections usable with scrolling at smaller window sizes,
  preserving fighter drafts, positions and simulation settings while browsing
  replays, expanding/collapsing sections or working with Matrix.

## 12. Health-bar color and Voidwalker visibility

- [x] Keep health-bar colors constant as health decreases; only the filled
  length should change. Apply consistently to unit frames and arena tokens.
- [x] Investigate and fix the reported missing Voidwalker when `Sacrifice: none`
  and `Pet: voidwalker` are selected. Verify the pet appears in setup and in
  generated fight playback for either player.

Health colors now remain fixed as HP decreases, including fighter and pet arena
bars; classic unit frames already used constant colors. The missing Voidwalker
was a simulator initialization bug: learning Demonic Sacrifice suppressed the
active pet even with `sacrifice_pet: none`. Initialization now requires an actual
sacrificed demon before removing the pet. The real Love2D repeat-fight test adds
a third fight with both players using Voidwalkers, Sacrifice: none and the talent
learned, checking setup pet identity/HP, snapshot settings and generated replay
pet identity/positive HP. ReleaseFast build, Lua/LuaJIT workspace checks and the
three-fight GUI test pass; playback screenshots were reviewed.

## 13. Soul Link and Demonic Sacrifice buffs

- [x] Show Soul Link as a buff on the character unit frame when active.
- [x] Show Demonic Sacrifice (DS) as a buff on the character unit frame when
  active, reflecting the sacrificed demon.
- [x] Reflect actual active effects in setup and recorded playback for either
  player; learning the talent alone must not show an inactive buff.

## Completion checks

- [x] Edit A, switch to B, and switch back: both drafts retain their changes and
  the preview reflects them immediately.
- [x] Generate a fight from unsaved edits and confirm the replay uses those specs,
  stats, pets, and starting positions.
- [x] Drag each fighter, resize the window, and confirm displayed positions and
  simulator positions agree.
- [x] Return from playback to setup, adjust a spec or position, and run again
  without losing the rest of the setup. Mode switching and preserved edits are
  covered by scripted checks and the real Love2D repeat-fight flow.
- [x] Confirm existing replay loading and distance-based CLI launches still work.
- [x] Switch between setup and playback: the arena styling, framing, and token
  presentation remain consistent.
- [x] Click either character: the matching spec section expands and the other
  collapses, without losing edits or unintentionally moving the character.
- [x] Confirm the talent icons/ranks and ability icon grid match the selected
  player's spec and the loadout submitted to the simulator.
- [x] Choose a thread count directly from its dropdown and confirm Fight uses
  that value; check the remaining Settings dropdowns likewise. Covered by scripted event-routing and launch-snapshot checks.
- [x] Open and dismiss menus at small and large window sizes without clipping
  or activating controls underneath them.
- [x] Confirm classic unit frames display the correct portraits, vitals,
  effects, and pet information in setup and playback for both classes.
- [x] Change either player's class through its header icon, including while
  collapsed, without toggling the section or losing the other player's edits.
- [x] Review the redesigned left panel at 960x540, 1280x720, and 2560x1080,
  including player/school expansion, scrolling, backgrounds, and class menus.

- [x] Confirm the PVP ARENA banner is gone in setup and playback, with arena
  framing, unit frames and input regions still aligned.
- [x] Expand Fight replays under Settings and load a replay without losing the
  current fight setup; verify the separate Fights tab is gone.
- [x] Expand Matrix under Settings and verify its existing workflows without a
  separate Matrix tab; confirm Analysis is hidden from navigation.
- [x] Review the consolidated Settings panel at 960x540, 1280x720 and 2560x1080,
  including scrolling, section toggles and replay selection.

## 14. Race selection and racial mechanics

- [x] Add a race icon immediately to the right of each player's class icon,
  with a direct-selection dropdown usable while expanded or collapsed.
- [x] Keep race in independent player drafts, saved presets and Fight spec
  snapshots; default legacy presets to Human. Offer Human, Gnome, Orc, Undead and Troll for both Warlock/Mage per the
  official Forever matrix, preserving race on class changes. Skyborne Mage remains pending.
- [x] Replace the initial race medallions with recognizable race portraits.
- [ ] Show recorded race during playback.
- [x] Parse and validate simulator race/class combinations (legacy default Human)
  and retain race in MCTS JSON/Lua replay metadata.
Racial inventory for the five current editor races: **20 total; 6 have runtime effects
within the supported caster kits, 14 pending**. Target Forever, not Classic. Sources:
[full racial guide](https://www.wowhead.com/forever/guide/new-race-class-combinations),
[user-supplied tuning build](https://www.wowhead.com/forever/news/class-racials-in-wow-forever-receive-tuning-adjustments-in-latest-build-383457),
and [implementation/source notes](RACIALS.md). Research recorded 2026-10-16.
The guide is an inventory; prefer the supplied tuning article where they conflict.
Unknown details below are verification tasks, not permission to use Classic values.

### Human — four racials

- [ ] **Will to Survive:** clears stuns. Full tooltip unavailable in the guide;
  verify cooldown, GCD and use while controlled.
- [ ] **Perception:** stealth detection for 20 seconds. Verify cooldown and
  detection strength; usefulness depends on implementing stealth.
- [x] **Ruthless (owner spell portion):** +2 percentage points of crit for all
  spells/attacks, with the former sword requirement removed. Loader adds spell
  crit once, capped at 100%; setup summary includes it. Owner weapon attacks
  remain outside this implementation; do not give this bonus to pets.
  The indexed [spell 20597](https://www.wowhead.com/forever/spell=20597/ruthless)
  effect field says 3%, conflicting with its 2% tooltip and the linked article.
  Current implementation explicitly pins 2%; resolve before changing it.
- [ ] **The Human Spirit:** +5% Spirit. Requires a Spirit/stat/regen model;
  do not approximate it as a flat mana regeneration multiplier.

### Gnome — four racials

- [ ] **Eureka!:** next three qualifying abilities receive 10% lower resource
  cost and 10% more damage (healing for relevant variants). Latest tuning reduces
  the window from 15 to 8 seconds. Article shows Energy, Rage and multiple Mana
  variants, with differing periodic/healing eligibility and changed proc flags.
  [Linked spell 1259813](https://www.wowhead.com/forever/spell=1259813/eureka)
  could not be inspected because of the site's JavaScript challenge. Verify
  Mage/Warlock variant IDs, cooldown, charge use, DoT eligibility/snapshotting,
  and meaning of proc changes before implementation.
- [x] **Expansive Mind:** +5% maximum Mana, applied once to base/gear totals
  during spec loading. Editor summary and preview use the same bonus; exported
  stats remain unbuffed. Confirmed in Blizzard’s official Forever racial overview.
- [ ] **Engineering Specialization:** improves device reliability. Exact effect
  unspecified; depends on adding engineering items and failure mechanics.
- [x] **Escape Artist (supported roots/snares):** instant, 2-minute cooldown,
  1.5-second GCD; clears Mage root/slow and prevents their reapplication for
  3 seconds. Does not clear Warlock DoTs or Daze (a separate mechanic).
  Available to Gnome casters in the action picker and AI when in their loadout.
  Validated cleanse, prevention, expiry, race/GCD gates and both player sides.

### Orc — four racials

- [x] **Savage (owner spell portion):** +1 percentage point of crit for spells
  and abilities, with the former axe requirement removed. Same loader, cap and
  pet exclusions as Ruthless. Owner weapon attacks remain outside this work.
  The indexed [spell 20574](https://www.wowhead.com/forever/spell=20574/savage)
  effect field says 2%, conflicting with its 1% tooltip and the article; pin 1%.
- [x] **Blood Fury (owner spell portion):** +10% school Spell Power for
  15 seconds; 3-minute cooldown pinned to the tuning article, off GCD.
  Scales the power coefficient rather than base spell damage; no pet bonus.
  Periodics follow the engine’s existing dynamic-stat model, not a new claim
  about Forever snapshot rules. Attack Power remains outside the owner kit.
- [ ] **Shatter Curse:** removes Curses/Banes and grants immunity; reduces
  magic damage taken for 8 seconds. Latest tuning changes reduction from 15%
  to 5% and removes an immunity effect entry; verify resulting school/debuff
  immunity flags and cooldown. Test cleanse separately from prevention.
- [ ] **Hardiness:** 20% shorter stun duration, not Classic stun resist chance.
  Verify stacking/order relative to diminishing returns and any minimum duration.

### Undead — four racials

- [ ] **Cannibalize:** restores 7% max Health and Mana every 2 seconds for
  10 seconds; requires a Humanoid/Undead corpse within 5 yards. Movement,
  action or incoming damage cancels it. Verify cooldown and first tick timing;
  corpse availability is an arena-system dependency.
- [ ] **Touch of the Grave:** spell/attack-triggered health drain, up to 5%
  maximum Health. Article has two variants: proc chance 5% to 20%, and 10% to
  30%; both change internal cooldown from 1 to 25 seconds. Guide lists 20%.
  Identify Mage/Warlock variants before choosing a chance. Verify drain amount,
  damage school, heal coupling, eligible events, resistance, and ICD start.
- [ ] **Underwater Breathing:** breath lasts 300% longer; no current arena
  effect because swimming/breath are not modeled.
- [x] **Will of the Forsaken:** clears modeled Charm/Fear (Seduction/Fear),
  including while controlled; 120s CD and 1.5s GCD. No lasting immunity. Preserves
  DR and does not clear Horror, stun or Mage Polymorph. Sleep has no separate
  modeled source yet. Sources and regression coverage: `RACIALS.md`.

### Troll — four racials

- [ ] **Beast Slaying:** +5% damage against Beasts. Requires target creature
  types; do not apply to Humanoid players or Demon pets.
- [x] **Berserking (owner caster portion):** +10% cast/channel progress for
  10 seconds, 3-minute cooldown, off GCD; spell GCDs retain the compact kit’s 1-second minimum.
  Cast progress handles buff expiry within a frame. Does not speed cooldowns,
  DoTs, movement or autonomous pet attacks. Owner weapon attacks are not modeled.
- [ ] **Regeneration:** latest tuning increases both the health regeneration
  bonus and fraction continuing in combat from 10% to 20%. Requires baseline
  health regeneration; this is not 20% maximum Health per second.
- [ ] **Rapid Regeneration:** heals 50% maximum Health over time. The
  [Forever Protection Warrior overview](https://www.wowhead.com/forever/guide/classes/warrior/protection/overview-pve-tank)
  gives 6 seconds and cancellation on movement, actions or damage. Confirm current
  cooldown, ticks, channel rules and interaction with other regeneration effects.

### Shared remaining work

- [ ] Audit Forever race/class availability and add missing eligible races.
  Orc Mage and Troll Warlock are now supported. Skyborne Mage and its racials
  still need editor/simulator support.
- [ ] Revalidate legacy resistance racials against Forever before enabling them.
- [ ] Implement and validate racial base stats, passive bonuses/resistances and
  active racial abilities, including cooldowns and AI action availability.
- [ ] Validate race menus in the real GUI at all three supported window sizes,
  including both players, collapsed headers, scrolling and menu dismissal.

## 15. Gear defaults and stat audit

- [x] Start both fighters and newly selected classes with class-appropriate
  Pre-BiS equipment instead of empty slots, preserving explicit saved loadouts.
- [ ] Audit gear-derived stats against independently calculated expected values
  for the selected items, including complete Warlock/Mage Pre-BiS sets and
  representative individual gear swaps. Verify item data, stamina/health,
  intellect/mana/crit, spell power by school, hit caps, armor and resistances.
  Independent arithmetic for eight full-set/swap cases now matches Lua/Zig and
  setup/Fight exports; see [GEAR_AUDIT.md](GEAR_AUDIT.md). Item-source accuracy,
  the unreachable-with-current-items hit cap and replay comparison remain open.
- [ ] Verify the baseline stats used with equipment match the intended level,
  class and race; distinguish baseline, equipment and talent/buff contributions
  and check that loading or re-equipping gear never counts bonuses twice.
  Provisional opt-in class/race profiles and 32 independent checks are now
  available; see [STAT_PROFILES.md](STAT_PROFILES.md). Source conflicts and
  client rounding prevent marking the authentic-baseline audit complete.
- [ ] Compare expected totals with editor stats, setup HP/MP, serialized Fight
  specs, simulator initialization and recorded replay values; document expected
  ranges and resolve discrepancies so each selected loadout produces plausible
  character stats.

## 16. Automatic actions and available cooldowns

- [x] Derive the supported action set from class baseline abilities, selected
  talents, equipped items (including supported item actives), race, and active
  pet. Recompute on build changes so users do not need to maintain action slots.
  Talent unlocks and essential class abilities should be retained automatically;
  Fear is a high-priority baseline Warlock action.
- [x] Separate build availability from priority and temporary combat legality.
  Use one capability definition for editor display, simulator action masks,
  search choices, Fight snapshots, and replay metadata.
- [x] Expand UI slots and runtime/search capacity as needed to retain every
  supported available action initially. Use shared default priorities for display
  and search ordering; avoid silently excluding actions and biasing build
  comparisons. Optional advanced overrides can follow automatic defaults.
- [ ] Introduce pruning only if search measurements justify it. If a hard limit
  becomes necessary, retain reserved movement/cancel controls, essential class
  actions, and selected talent unlocks/build-defining interactions first. Define
  deterministic overflow priorities and visibly report excluded actions and why.
- [x] Render unit-frame cooldown indicators from the build's action capabilities
  saved at Fight start, with the same rules in setup and replay. A Shadow Priest
  without Power Infusion must not show a PI cooldown. Keep indicators when an
  available action is temporarily blocked by cooldown, mana, silence, or other
  combat conditions; pet indicators should additionally reflect pet state.
- [x] Cover talent, gear, race, and pet changes, capacity growth, and Fight/replay
  round trips. Preserve compatibility with existing saved loadouts and recordings
  using an explicit fallback when older data has no capability metadata.

Implemented: the editor migrates old slot lists to automatic capabilities from the
shared action catalog, recomputes on build changes, and displays a read-only ability
grid. All currently supported actions fit; capacity follows catalog growth. Gear
currently has no supported item-active actions, so gear changes only affect stats.
No search pruning is introduced. Direct CLI legacy specs retain explicit loadouts;
`automatic_actions: true` opts into derived actions. New Lua/JSON recordings save
per-side action masks. Recordings without capability metadata explicitly retain
historical cooldown indicators. Overhead HP/mana and unit frames share maximum-stat
normalization, fixing the hardcoded 2000 HP / 1000 mana bars.

Validation: automatic action/cooldown/vitals regressions, workspace checks at three
sizes, racial/Priest/gear/passive checks, ReleaseFast build and tests, and recorded
Priest fight capability round trips. Debug tests hit a Zig LLVM register-copy error;
ReleaseFast tests pass.
