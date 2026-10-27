# Level-60 reference profile checks

Expected totals are independently calculated with Python Decimal. Source choices
and limitations are described in [STAT_PROFILES.md](STAT_PROFILES.md).

HP, mana and crit below include this project’s pinned racial passives. Talent
resource bonuses appear only in the runtime HP/mana columns. No client
rounding is asserted.

| Case | HP | Mana | Crit % | Armor reduction % | Runtime HP | Runtime mana |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| warlock_human_naked | 1884 | 2743 | 5.515 | 1.785714 | 1884 | 2743 |
| warlock_human_geared | 2554 | 4258 | 9.1815 | 10.335833 | 2554 | 4258 |
| warlock_gnome_naked | 1874 | 2927.4 | 3.5645 | 1.890831 | 1874 | 2927.4 |
| warlock_gnome_geared | 2544 | 4518.15 | 7.231 | 10.423453 | 2544 | 4518.15 |
| warlock_orc_naked | 1904 | 2698 | 4.4655 | 1.680372 | 1904 | 2698 |
| warlock_orc_geared | 2574 | 4213 | 8.132 | 10.248042 | 2574 | 4213 |
| warlock_undead_naked | 1894 | 2713 | 3.482 | 1.715511 | 1894 | 2713 |
| warlock_undead_geared | 2564 | 4228 | 7.1485 | 10.277325 | 2564 | 4228 |
| warlock_troll_naked | 1894 | 2683 | 3.449 | 1.855817 | 1894 | 2683 |
| warlock_troll_geared | 2564 | 4198 | 7.1155 | 10.394265 | 2564 | 4198 |
| frost_mage_human_naked | 1640 | 2808 | 4.3 | 1.256732 | 1640 | 2808 |
| frost_mage_human_geared | 2200 | 4263 | 8.9296 | 9.806494 | 2200 | 4263 |
| frost_mage_gnome_naked | 1630 | 2995.65 | 2.3504 | 1.362984 | 1630 | 2995.65 |
| frost_mage_gnome_geared | 2190 | 4523.4 | 6.98 | 9.895151 | 2190 | 4523.4 |
| frost_mage_orc_naked | 1660 | 2763 | 3.2496 | 1.150252 | 1660 | 2763 |
| frost_mage_orc_geared | 2220 | 4218 | 7.8792 | 9.717663 | 2220 | 4218 |
| frost_mage_undead_naked | 1650 | 2778 | 2.2664 | 1.185771 | 1650 | 2778 |
| frost_mage_undead_geared | 2210 | 4233 | 6.896 | 9.747292 | 2210 | 4233 |
| frost_mage_troll_naked | 1650 | 2748 | 2.2328 | 1.327592 | 1650 | 2748 |
| frost_mage_troll_geared | 2210 | 4203 | 6.8624 | 9.865618 | 2210 | 4203 |
| priest_human_naked | 1717 | 2896 | 4.816 | 1.433692 | 1717 | 2896 |
| priest_human_geared | 2247 | 4591 | 8.7144 | 9.821282 | 2247 | 4591 |
| priest_gnome_naked | 1707 | 3088.05 | 2.8664 | 1.539563 | 1707 | 3088.05 |
| priest_gnome_geared | 2237 | 4867.8 | 6.7648 | 9.90991 | 2237 | 4867.8 |
| priest_orc_naked | 1737 | 2851 | 3.7656 | 1.327592 | 1737 | 2851 |
| priest_orc_geared | 2267 | 4546 | 7.664 | 9.73248 | 2267 | 4546 |
| priest_undead_naked | 1727 | 2866 | 2.7824 | 1.362984 | 1727 | 2866 |
| priest_undead_geared | 2257 | 4561 | 6.6808 | 9.7621 | 2257 | 4561 |
| priest_troll_naked | 1727 | 2836 | 2.7488 | 1.504298 | 1727 | 2836 |
| priest_troll_geared | 2257 | 4531 | 6.6472 | 9.880387 | 2257 | 4531 |
| warlock_gnome_talent_resources | 2544 | 4518.15 | 7.231 | 10.423453 | 2740.5 | 5195.8725 |
| reference_explicit_stat_override | 4321 | 4567 | 12 | 20 | 4321 | 4567 |
