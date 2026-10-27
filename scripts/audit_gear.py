"""Independent Decimal audit of the frozen gear cases; imports no game resolver.

Use --check for CI. Use --write only when reviewing new catalog/formula inputs.
An optional --reference-checkout verifies the pinned local reference hashes.
"""
import argparse
from collections import defaultdict
from decimal import Decimal, getcontext
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'src/testdata/equipment_parity.json'
REPORT = ROOT / 'GEAR_AUDIT.md'
getcontext().prec = 40
D = Decimal


def calculate(case, items):
    totals = defaultdict(lambda: D(0))
    for item_id in case['input']['gear'].values():
        if item_id:
            for stat, value in items[item_id]['stats'].items():
                totals[stat] += D(str(value))
    base = {key: D(str(value)) for key, value in case['input'].get('gear_base_stats', {}).items()}
    expected = dict(base)
    expected.update(
        max_health=base.get('max_health', D(2000)) + totals['stamina'] * 10,
        max_mana=base.get('max_mana', D(1000)) + totals['intellect'] * 15,
        stamina=base.get('stamina', D(0)) + totals['stamina'],
        spell_hit_chance=min(D('.99'), D('.96') + totals['spell_hit'] / 100),
        spell_crit_chance=min(D(1), base.get('spell_crit_chance', D(0)) + totals['spell_crit'] / 100
                              + totals['intellect'] / (D('60.6') if case['input']['class'] == 'warlock' else D('59.5')) / 100),
        armor_damage_reduction=1 - (1 - base.get('armor_damage_reduction', D(0))) * D(5500) / (5500 + totals['armor']),
    )
    for school in ['shadow', 'fire', 'frost']:
        key = school + '_power'
        expected[key] = base.get(key, D(0)) + totals['spell_power'] + totals[key]
    for school in ['shadow', 'fire', 'frost', 'arcane']:
        key = school + '_resistance'
        expected[key] = base.get(key, D(0)) + totals[key]
    return {key: float(value) for key, value in expected.items()}, dict(totals)


def calculate_reference(case, items, reference):
    source = case['input']
    c = reference['classes'][source['class']]
    r = reference['race_offsets'][source['race']]
    stamina = D(c['stamina'] + r['stamina'])
    intellect = D(c['intellect'] + r['intellect'])
    armor = D(2 * (c['agility'] + r['agility']))
    coefficient = D(str(c['spell_crit_percent_per_intellect'])) / 100
    base = {'level': 60, 'stamina': int(stamina),
            'max_health': c['health'] + int(stamina)*10 - 180,
            'max_mana': c['mana'] + int(intellect)*15 - 280,
            'spell_hit_chance': .96,
            'spell_crit_chance': float(D(str(c['base_spell_crit_percent']))/100 + intellect*coefficient),
            'armor_damage_reduction': float(armor / (armor+5500))}
    independent = {'input': dict(source, gear=source.get('gear', {}), gear_base_stats=base)}
    expected, totals = calculate(independent, items)
    total_intellect = intellect + totals.get('intellect', D(0))
    total_armor = armor + totals.get('armor', D(0))
    expected['spell_crit_chance'] = float(min(D(1), D(str(c['base_spell_crit_percent']))/100 + total_intellect*coefficient + totals.get('spell_crit', D(0))/100))
    expected['armor_damage_reduction'] = float(total_armor / (total_armor+5500))
    expected.update(source.get('combat_stats', {}))
    native = dict(expected)
    if source['race'] == 'gnome':
        native['max_mana'] = float(D(str(native['max_mana'])) * D('1.05'))
    native['spell_crit_chance'] = min(1, native['spell_crit_chance'] + {'human': .02, 'orc': .01}.get(source['race'], 0))
    runtime = dict(native)
    talents = source.get('trees', {}).get('Demonology', {}) if source['class'] == 'warlock' else {}
    runtime['max_health'] = float(D(str(native['max_health'])) + D(str(native['stamina'])) * D('.3') * talents.get('105907', 0))
    runtime['max_mana'] = float(D(str(native['max_mana'])) * (1 + D('.05') * talents.get('105903', 0)))
    return {'expected': expected, 'native_expected': native, 'runtime_expected': runtime}


def calculate_warrior(case, items):
    source=case['input']
    totals=defaultdict(lambda:D(0))
    for item_id in source['gear'].values():
        if item_id:
            for key,value in items[item_id]['stats'].items():totals[key]+=D(str(value))
    base={'max_health':4000,'max_mana':1};base.update(source.get('gear_base_stats',{}))
    config={'attack_power':700,'crit':.05,'white_hit':.95,'special_hit':.95,'starting_rage':0,'starting_stance':'battle','damage_taken_rage':True}
    config.update(source.get('gear_base_warrior',{}))
    main=items[source['gear']['main_hand']]
    off=items.get(source['gear'].get('off_hand',0))
    dual=bool(off and off.get('weapon'))
    shield=bool(off and off.get('shield_block'))
    config.update(main_hand=main['weapon'],off_hand=off['weapon'] if dual else None,shield=shield)
    config['attack_power']=float(D(str(config['attack_power']))+2*totals['strength']+totals['attack_power'])
    config['crit']=float(min(D(1),D(str(config['crit']))+totals['agility']*D('.0005')+totals['melee_crit']/100))
    config['white_hit']=float(min(D(1),max(D(0),D(str(config['white_hit']))-(D('.19') if dual else 0)+totals['melee_hit']/100)))
    config['special_hit']=float(min(D(1),D(str(config['special_hit']))+totals['melee_hit']/100))
    stats=dict(base)
    stats.update(max_health=float(D(str(base['max_health']))+totals['stamina']*10),max_mana=1,
                 stamina=float(D(str(base.get('stamina',0)))+totals['stamina']),
                 melee_avoidance_chance=0,
                 melee_dodge_chance=float(D(str(base.get('melee_dodge_chance',0)))+D(str(base.get('melee_avoidance_chance',0)))+totals['agility']*D('.0005')),
                 melee_block_chance=max(.05,base.get('melee_block_chance',0)) if shield else 0,
                 melee_block_value=float(D(str(base.get('melee_block_value',0)))+D(off['shield_block'])+max(D(0),totals['strength']*D('.05')-1)) if shield else 0)
    reduction=D(str(base.get('armor_damage_reduction',0)))
    if reduction<1:
        armor=5500*reduction/(1-reduction)+totals['armor']+2*totals['agility']
        stats['armor_damage_reduction']=float(armor/(armor+5500))
    for school in ['shadow','fire','frost','arcane']:
        key=school+'_resistance';stats[key]=float(D(str(base.get(key,0)))+totals[key])
    if 'combat_stats' in source:
        recovered_stamina=stats['stamina']
        stats={key:0 for key in stats}
        stats.update(max_health=2000,max_mana=1000)
        stats.update(source['combat_stats'])
        if 'stamina' not in source['combat_stats']:stats['stamina']=recovered_stamina
    if 'warrior' in source:
        config={'main_hand':{'min':180,'max':270,'speed':3.6,'two_handed':True},'off_hand':None,'shield':False,
                'attack_power':700,'crit':.05,'white_hit':.95,'special_hit':.95,'starting_rage':0,
                'starting_stance':'battle','damage_taken_rage':True}
        config.update(source['warrior'])
    return {'expected_stats':stats,'expected_warrior':config}


def warrior_report(cases):
    lines=['# Warrior equipment checks','','Independent Decimal expectations for the compact Warrior item model.',
           'See [WARRIOR_GEAR.md](WARRIOR_GEAR.md) for provenance and unsupported effects.','',
           '| Case | HP | AP | White hit % | Crit % | Armor reduction % | Shield block |',
           '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for case in cases:
        s,c=case['expected_stats'],case['expected_warrior']
        values=[s['max_health'],c['attack_power'],c['white_hit']*100,c['crit']*100,s['armor_damage_reduction']*100,s['melee_block_value']]
        lines.append('| '+case['name']+' | '+' | '.join(f'{v:.6f}'.rstrip('0').rstrip('.') for v in values)+' |')
    return '\n'.join(lines)+'\n'


def reference_report(cases):
    lines = ['# Level-60 reference profile checks', '',
             'Expected totals are independently calculated with Python Decimal. Source choices',
             'and limitations are described in [STAT_PROFILES.md](STAT_PROFILES.md).', '',
             'HP, mana and crit below include this project’s pinned racial passives. Talent',
             'resource bonuses appear only in the runtime HP/mana columns. No client',
             'rounding is asserted.', '',
             '| Case | HP | Mana | Crit % | Armor reduction % | Runtime HP | Runtime mana |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for case in cases:
        n, r = case['native_expected'], case['runtime_expected']
        values = [n['max_health'], n['max_mana'], n['spell_crit_chance']*100,
                  n['armor_damage_reduction']*100, r['max_health'], r['max_mana']]
        lines.append('| ' + case['name'] + ' | ' + ' | '.join(f'{x:.6f}'.rstrip('0').rstrip('.') for x in values) + ' |')
    return '\n'.join(lines) + '\n'


def report(cases, totals, reference):
    lines = ['# Gear stat audit', '',
             'Offline arithmetic audit of the checked-in catalog. Expected values use an independent',
             'Python Decimal calculation; Lua and Zig consume the same frozen cases. This checks',
             'arithmetic and parity, not the authenticity of imported item tooltip values.', '',
             '## Item contributions', '',
             'Values below exclude the fixture base stats, talents and racial passives.', '',
             '| Case | Stamina | Intellect | Armor | Generic power | Shadow power | Fire power | Frost power | Hit % | Crit % |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    keys = ['stamina', 'intellect', 'armor', 'spell_power', 'shadow_power', 'fire_power', 'frost_power', 'spell_hit', 'spell_crit']
    for case, t in zip(cases, totals):
        lines.append('| ' + case['name'] + ' | ' + ' | '.join(str(t.get(k, 0)) for k in keys) + ' |')
    lines += ['', 'Mage Pre-BiS has 20 frost resistance; the staff swap has 20 fire and 40 frost',
              'resistance. The catalog can provide at most 2% legal item spell hit; the 99%',
              'hit cap is therefore not exercised by these loadouts. Spirit is totaled but',
              'does not grant regeneration. Random suffixes, set bonuses and item actives',
              'remain unsupported.', '', '## Compact baseline versus the local reference', '',
              'The runtime uses 2,000 HP, 1,000 mana and zero base stamina unless supplied.',
              'The pinned reference instead uses class attributes and the first-20-point',
              'resource offsets below. These are unbuffed Human comparisons before talents',
              'and racial passives; they are not newly verified character presets.', '',
              '| Class | Reference naked HP | Reference naked mana | Base stamina | Base intellect | Compact geared HP / mana | Reference geared HP / mana |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for case, t in zip(cases[:3], totals[:3]):
        cls = reference['classes'][case['input']['class']]
        hp = cls['health'] + cls['stamina'] * 10 + reference['resource_offsets']['health']
        mana = cls['mana'] + cls['intellect'] * 15 + reference['resource_offsets']['mana']
        dhp, dmp = int(t.get('stamina', 0)) * 10, int(t.get('intellect', 0)) * 15
        lines.append(f"| {case['input']['class']} | {hp} | {mana} | {cls['stamina']} | {cls['intellect']} | {2000+dhp} / {1000+dmp} | {hp+dhp} / {mana+dmp} |")
    lines += ['', 'Changing to the reference baseline also changes Demonic Embrace scaling:',
              'Warlock Pre-BiS has 67 item stamina. Five ranks currently add 100.5 HP;',
              'including 65 reference base stamina would add 198 HP under the existing',
              'unrounded talent formula. Base health and total stamina must change together.', '',
              'The current gear crit conversion uses 60.6 intellect per 1% for Warlock and',
              '59.5 for Mage/Priest. The reference coefficients are 0.0165 and 0.0168',
              'percentage points per intellect; these rounded representations are close,',
              'but not identical. Race offsets, base crit, agility-derived armor, talent',
              'rounding and buffs still need validation before normal presets change.', '',
              'The opt-in `level60_reference_v1` profile now exercises these reference',
              'attributes, all five race offsets, reference crit coefficients and additive',
              'raw armor. Source conflicts and rounding policy are documented in',
              '[STAT_PROFILES.md](STAT_PROFILES.md); 32 independent cases are listed in',
              '[REFERENCE_STAT_AUDIT.md](REFERENCE_STAT_AUDIT.md).', '',
              '## Provenance and reproduction', '',
              f"Reference checkout HEAD: `{reference['checkout_head']}`. The file hashes in",
              '[the pinned snapshot](data/stat_sources/forever_level60.json) identify the actual',
              'local files; HEAD alone does not certify an unmodified checkout or client parity.',
              'The snapshot also pins race offsets, crit coefficients and source-policy conflicts.', '',
              'Run `python3 scripts/audit_gear.py --check` to check every expected total and',
              'this report. Add `--reference-checkout /path/to/mythicsim-forever-engine-go`',
              'to verify source hashes. Use `--write` only for an intentional fixture update.', '',
              'Editor/native parity checks: `lua visualizer/test_gear.lua` and',
              '`zig test src/spec.zig -O ReleaseFast -mcpu=x86_64_v3 --test-filter native`.', '',
              'The setup/Fight integration checks run with',
              '`lua visualizer/test_workspace_gear.lua`. Recorded replay comparison remains',
              'a separate validation task.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--write', action='store_true')
    parser.add_argument('--reference-checkout', type=Path)
    args = parser.parse_args()
    items = {item['id']: item for item in json.loads((ROOT / 'data/vanilla_gear.json').read_text())['items']}
    reference = json.loads((ROOT / 'data/stat_sources/forever_level60.json').read_text())
    if args.reference_checkout:
        for path, digest in reference['files'].items():
            if hashlib.sha256((args.reference_checkout / path).read_bytes()).hexdigest() != digest:
                raise SystemExit(f'Reference source changed: {path}')
    cases = json.loads(FIXTURE.read_text())
    totals = []
    for case in cases:
        expected, item_totals = calculate(case, items)
        totals.append(item_totals)
        if args.write:
            case['expected'] = expected
        elif expected.keys() != case['expected'].keys() or any(abs(value - case['expected'][key]) > 1e-10 for key, value in expected.items()):
            raise SystemExit(f"Independent gear audit failed: {case['name']}")
    output = report(cases, totals, reference)
    if args.write:
        FIXTURE.write_text(json.dumps(cases, indent=2) + '\n')
        REPORT.write_text(output)
    elif not REPORT.exists() or REPORT.read_text() != output:
        raise SystemExit('Gear audit report is stale; review inputs and run with --write')
    reference_fixture = ROOT / 'src/testdata/reference_stats.json'
    reference_cases = json.loads(reference_fixture.read_text())
    for case in reference_cases:
        values = calculate_reference(case, items, reference)
        for key, expected in values.items():
            if args.write:
                case[key] = expected
            elif expected.keys() != case[key].keys() or any(abs(value - case[key][field]) > 1e-10 for field, value in expected.items()):
                raise SystemExit(f"Independent reference audit failed: {case['name']}/{key}")
    reference_output = reference_report(reference_cases)
    reference_doc = ROOT / 'REFERENCE_STAT_AUDIT.md'
    if args.write:
        reference_fixture.write_text(json.dumps(reference_cases, indent=2) + '\n')
        reference_doc.write_text(reference_output)
    elif not reference_doc.exists() or reference_doc.read_text() != reference_output:
        raise SystemExit('Reference stat report is stale')
    warrior_catalog=json.loads((ROOT/'data/warrior_gear.json').read_text())
    warrior_items={item['id']:item for item in warrior_catalog['items']}
    warrior_fixture=ROOT/'src/testdata/warrior_equipment.json'
    warrior_cases=json.loads(warrior_fixture.read_text())
    for case in warrior_cases:
        for key,expected in calculate_warrior(case,warrior_items).items():
            if args.write:case[key]=expected
            elif expected!=case[key]:raise SystemExit(f"Independent Warrior audit failed: {case['name']}/{key}")
    warrior_output=warrior_report(warrior_cases)
    warrior_doc=ROOT/'WARRIOR_GEAR_AUDIT.md'
    if args.write:
        warrior_fixture.write_text(json.dumps(warrior_cases,indent=2)+'\n')
        warrior_doc.write_text(warrior_output)
    elif not warrior_doc.exists() or warrior_doc.read_text()!=warrior_output:raise SystemExit('Warrior gear report is stale')
    print(f'Independent totals verified: {len(cases)} caster gear cases, {len(reference_cases)} reference profiles and {len(warrior_cases)} Warrior loadouts.')


if __name__ == '__main__':
    main()
