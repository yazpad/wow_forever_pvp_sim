# Pinned Forever warrior inputs

These are local reference snapshots for the first warrior implementation pass.
`manifest.json` records paths, SHA-256 hashes, checkout HEAD and the client build
claimed by the audit (`1.60.1.69893`). A checkout HEAD does not certify that local
files were unmodified; the file hashes identify the actual imported contents.
They are not a claim of parity with a newer client.

The reference is `~/mythicsim-forever-engine-go`. `spell_data.go` identifies its
upstream as `wowsims/forever@8b7ed8c97`. Source snapshots are covered by the
included MIT license. All implementation and regeneration works offline:

```sh
python3 scripts/generate_warrior_data.py
python3 scripts/generate_warrior_data.py --check
lua visualizer/test_warrior_talents.lua
zig build test-warrior -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

## Decisions and limits

| Topic | Decision / evidence |
| --- | --- |
| Tree layout | Use the newer reference UI tree: Arms 17, Fury 18, Protection 18 (53 total). The older video-derived export has an extra Vitality entry absent from the reference UI, proto and generated spell table. Exclude it from this pinned target; recheck against a client tree before final parity signoff. |
| Canonical IDs | Use the generated client table's base spell ID, replacing zero IDs and outdated Classic IDs in the UI snapshot. Multiple talent ranks may use the same spell ID with separate rank curves. Never assume a rank-one active ability tooltip is the level-60 spell. |
| Blood Craze | Use the newer UI/client name and `bloodCraze` key, base ID 16487. The older export called it Blood Crazed. |
| Enrage | The newer table has a flat 30% proc chance at every rank and 2/4/6/8/10% damage. Discard the older override's increasing proc chance and fixed 2% damage. |
| Tactical Mastery | Baseline 10 rage retained; Improved Tactical Mastery adds 3 per point. Switching caps existing rage and shares a 1s stance cooldown, without the ordinary ability GCD in `stances.go`. |
| Boundless Rage | Maximum rage is 100 + 10 per talent point; not a hardcoded 100 cap. |
| White-swing rage | `ruleset.go`: base weapon speed times 3.46 (one-hand) or 4.5 (two-hand); off-hand pays half before off-hand talent modifiers. Miss/dodge/parry pay zero. Damage and crit do not scale rage. |
| Haste assumption | Using base weapon speed instead of the hasted interval follows the reference; its low-level logs cannot independently establish this. Keep provisional until measured. |
| Incoming-damage rage | Reference assumption: raw pre-armor damage times 10 divided by maximum health. The reference explicitly requests higher-level in-game validation; do not describe this coefficient as client-verified. |
| Stance effects | Reference: Defensive deals/takes 0.9 damage; Berserker takes 1.1 damage and adds 3 percentage points of melee crit; Battle has neither of these combat modifiers. Threat effects are outside the current 1v1 scope. |
| Talent descriptions | Preserve newer reference tooltip parameters separately from runtime support. They still need effect-by-effect verification; the generated `runtime_support` flag distinguishes full, partial and planned effects. |

`scripts/generate_warrior_data.py` verifies the source hashes, generates the
existing Lua talent schema, and generates a four-word Zig rank layout with no
talent crossing a word boundary. Four words are necessary for all 53 talents.
Each prerequisite comes from the tree arrow and requires its parent's maximum
rank, following the reference tree convention.

The arena supports swings, Heroic Strike, stance actions and Hamstring, with
optional Warrior-only snapshot storage and MCTS worker configuration. Two starter
presets, editor selection/weapon controls, and ordinary recorded fights are now
available; see [Warrior setup and playback](../../WARRIOR.md). Metadata marks
Improved Heroic Strike, Improved Tactical Mastery and Boundless Rage as active,
Dual Wield Specialization as partial (rage only), and other talents as planned.

Initial item-based gear is supported. The complete ability/talent kit and neural training remain
unsupported. The compact melee table uses explicit hit, combined avoidance,
crit and armor-reduction inputs rather than verified PvP attack-table rules.
Incoming-damage rage is deliberately not enabled by this arena pass.

## Fury continuation

The 2026-10-22 continuation also pins `bloodthirst.go`, `whirlwind.go` and
`talents.go` from the local reference, with hashes in the manifest. The spell
and talent tables remain the numeric authority: Bloodthirst rank four is
35% AP + 48, with a ten-second 10% movement aura on landing; the reference Go
Bloodthirst code implements damage only. Blood Craze healing is a separate
pending talent. Whirlwind costs 25 rage without a miss refund, deals normalized
weapon damage, and gains a separate off-hand attack with Raging Blows. Its
multiple-target behavior and Cleave cost reduction are deferred. The eight-yard
Whirlwind radius is an explicit arena approximation (the spell table does not
include effect-radius data). Death Wish uses +20% physical damage, +5% all damage
taken and Fear immunity; it does not protect against Horror or incapacitation.
The movement-aura landing rule follows attack aura application, but remains a
client parity gate. Death Wish activation while already feared is not enabled.

## Fury passive and rage continuation

Also pinned `core_rage.go`, `core_spell_result.go` and
`core_spell_resistances.go` to identify incoming-hit hook and RawDamage behavior.
The runtime now implements the Unbridled Wrath, Flurry, Precision, Enrage and
Dual Wield Specialization curves in the pinned tables/talents.go. Incoming rage
uses the provisional factor 10 against maximum HP with resolved pre-armor hit
values. Spell payload critical/partial-resistance values and grouped same-hand
physical specials are explicit arena approximations; no client parity is claimed.
Direct-event hooks exclude DoTs/channels, matching the pinned Go dispatch.

## Rage audit correction (2026-10-22)

Additionally pinned `berserker_rage.go`, `bloodrage.go`,
`heroic_strike_cleave.go` and `core_flags.go` from the same local reference.
Their exact hashes are recorded in the manifest; as with the earlier imports,
the checkout identity does not certify unmodified files or client parity.

Berserker Rage doubles incoming-hit rage while active (explicitly provisional in
the reference). Bloodrage has no GCD. Heroic Strike requires its cost to queue
and spends/refunds at execution; its combined auto/special proc mask excludes
ordinary white-swing rage (exact mask comparison in `core_rage.go`) but permits
Unbridled Wrath and consumes Flurry (bit overlap in `talents.go`/`core_flags.go`).
The runtime now follows those rules and masks instant rage gains per acting lane.
The raw incoming damage limitations above remain; this is not full client parity.
