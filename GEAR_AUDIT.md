# Gear stat audit

Offline arithmetic audit of the checked-in catalog. Expected values use an independent
Python Decimal calculation; Lua and Zig consume the same frozen cases. This checks
arithmetic and parity, not the authenticity of imported item tooltip values.

## Item contributions

Values below exclude the fixture base stats, talents and racial passives.

| Case | Stamina | Intellect | Armor | Generic power | Shadow power | Fire power | Frost power | Hit % | Crit % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| warlock_prebis | 67 | 101 | 534 | 293 | 61 | 0 | 0 | 1 | 2 |
| mage_prebis | 56 | 97 | 528 | 264 | 0 | 0 | 71 | 2 | 3 |
| priest_starter | 53 | 113 | 519 | 247 | 101 | 0 | 40 | 1 | 2 |
| warlock_without_head | 59 | 93 | 466 | 263 | 61 | 0 | 0 | 1 | 2 |
| mage_staff_swap | 56 | 89 | 528 | 230 | 0 | 36 | 107 | 2 | 3 |
| mage_sword_swap | 56 | 89 | 528 | 250 | 0 | 0 | 71 | 2 | 4 |
| mage_horde_ring_swap | 56 | 104 | 528 | 282 | 0 | 0 | 50 | 2 | 3 |
| empty_equipment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Mage Pre-BiS has 20 frost resistance; the staff swap has 20 fire and 40 frost
resistance. The catalog can provide at most 2% legal item spell hit; the 99%
hit cap is therefore not exercised by these loadouts. Spirit is totaled but
does not grant regeneration. Random suffixes, set bonuses and item actives
remain unsupported.

## Compact baseline versus the local reference

The runtime uses 2,000 HP, 1,000 mana and zero base stamina unless supplied.
The pinned reference instead uses class attributes and the first-20-point
resource offsets below. These are unbuffed Human comparisons before talents
and racial passives; they are not newly verified character presets.

| Class | Reference naked HP | Reference naked mana | Base stamina | Base intellect | Compact geared HP / mana | Reference geared HP / mana |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| warlock | 1884 | 2743 | 65 | 110 | 2670 / 2515 | 2554 / 4258 |
| frost_mage | 1640 | 2808 | 45 | 125 | 2560 / 2455 | 2200 / 4263 |
| priest | 1717 | 2896 | 50 | 120 | 2530 / 2695 | 2247 / 4591 |

Changing to the reference baseline also changes Demonic Embrace scaling:
Warlock Pre-BiS has 67 item stamina. Five ranks currently add 100.5 HP;
including 65 reference base stamina would add 198 HP under the existing
unrounded talent formula. Base health and total stamina must change together.

The current gear crit conversion uses 60.6 intellect per 1% for Warlock and
59.5 for Mage/Priest. The reference coefficients are 0.0165 and 0.0168
percentage points per intellect; these rounded representations are close,
but not identical. Race offsets, base crit, agility-derived armor, talent
rounding and buffs still need validation before normal presets change.

The opt-in `level60_reference_v1` profile now exercises these reference
attributes, all five race offsets, reference crit coefficients and additive
raw armor. Source conflicts and rounding policy are documented in
[STAT_PROFILES.md](STAT_PROFILES.md); 32 independent cases are listed in
[REFERENCE_STAT_AUDIT.md](REFERENCE_STAT_AUDIT.md).

## Provenance and reproduction

Reference checkout HEAD: `51da1856fc932401bd880e3691cba14b33039dc1`. The file hashes in
[the pinned snapshot](data/stat_sources/forever_level60.json) identify the actual
local files; HEAD alone does not certify an unmodified checkout or client parity.
The snapshot also pins race offsets, crit coefficients and source-policy conflicts.

Run `python3 scripts/audit_gear.py --check` to check every expected total and
this report. Add `--reference-checkout /path/to/mythicsim-forever-engine-go`
to verify source hashes. Use `--write` only for an intentional fixture update.

Editor/native parity checks: `lua visualizer/test_gear.lua` and
`zig test src/spec.zig -O ReleaseFast -mcpu=x86_64_v3 --test-filter native`.

The setup/Fight integration checks run with
`lua visualizer/test_workspace_gear.lua`. Recorded replay comparison remains
a separate validation task.
