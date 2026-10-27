"""Pin level-60 reference stats and cross-check them against a saved planner.

No network access. --check verifies the checked-in snapshot against the checkout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'data/stat_sources/forever_level60.json'
CLASSES = {'warlock': ('Warlock', '9'), 'frost_mage': ('Mage', '8'), 'priest': ('Priest', '5')}
RACES = {'human': ('Human', '1'), 'gnome': ('Gnome', '7'), 'orc': ('Orc', '2'), 'undead': ('Undead', '5'), 'troll': ('Troll', '8')}
ATTRIBUTES = {'health': ('Health', '1'), 'mana': ('Mana', '0'), 'agility': ('Agility', '3'), 'strength': ('Strength', '4'), 'intellect': ('Intellect', '5'), 'spirit': ('Spirit', '6'), 'stamina': ('Stamina', '7')}
FILES = ['sim/core/base_stats.go', 'sim/core/character.go', 'sim/core/mana.go',
         'sim/core/stats/deps.go', 'sim/core/racials.go', 'sim/core/specializations.go',
         'sim/warlock/talents.go', 'assets/db_inputs/wowhead_forever_gearplanner.txt']


def extract(checkout):
    text = (checkout / FILES[0]).read_text()
    planner_text = (checkout / FILES[-1]).read_text()
    def planner(key):
        match = re.search(r'WH.setPageData\("wow.gearPlanner.classicplus\.' + key + r'"\s*,\s*', planner_text)
        return json.JSONDecoder().raw_decode(planner_text[match.end():])[0]
    def section(name):
        return text.split('var ' + name + ' =', 1)[1].split('\nvar ', 1)[0]
    def block(name, key):
        return re.search(r'proto\.\w+_' + key + r':\s*\{(.*?)\}', section(name), re.S)[1]
    bases, crit = planner('baseStats'), planner('critSpell')
    classes = {}
    for cls, (go, number) in CLASSES.items():
        values = block('ClassBaseStats', 'Class' + go)
        row = {key: int(re.search(r'stats\.' + symbol + r':\s*(\d+)', values)[1]) for key, (symbol, _) in ATTRIBUTES.items()}
        for key, (_, field) in ATTRIBUTES.items():
            if row[key] != bases['stats'][number][field][60]:
                raise ValueError(f'Engine/planner attribute mismatch: {cls}/{key}')
        row['base_spell_crit_percent'] = float(re.search(r'stats.SpellCrit:\s*([\d.]+)', block('ClassBaseCrit', 'Class' + go))[1])
        row['spell_crit_percent_per_intellect'] = float(re.search(r'proto.Class_Class' + go + r':\s*([\d.]+)', section('CritPerIntAtLevel'))[1])
        if row['spell_crit_percent_per_intellect'] != crit[number][60]:
            raise ValueError(f'Engine/planner crit scaling mismatch: {cls}')
        row['planner_base_spell_crit_percent'] = planner('baseCritSpell')[number]
        classes[cls] = row
    offsets = {}
    for race, (go, number) in RACES.items():
        values = block('RaceOffsets', 'Race' + go)
        row = {}
        for key in ['agility', 'strength', 'intellect', 'spirit', 'stamina']:
            symbol, field = ATTRIBUTES[key]
            match = re.search(r'stats\.' + symbol + r':\s*(-?\d+)', values)
            row[key] = int(match[1]) if match else 0
            if row[key] != bases['raceOffsets'][number][field]:
                raise ValueError(f'Engine/planner race offset mismatch: {race}/{key}')
        offsets[race] = row
    # Pin the actual offset expressions rather than relying on comments.
    if 'character.AddStat(stats.Health, 20-10*20)' not in (checkout / FILES[1]).read_text():
        raise ValueError('Health formula changed')
    if 'character.AddStat(stats.Mana, 20-15*20*modifier)' not in (checkout / FILES[2]).read_text():
        raise ValueError('Mana formula changed')
    return {
        'version': 1,
        'description': 'Local level-60 reference profile. Attributes/offsets/crit scaling agree with saved planner; base crit conflicts are explicit. Not certified client data.',
        'checkout_head': subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip(),
        'files': {path: hashlib.sha256((checkout / path).read_bytes()).hexdigest() for path in FILES},
        'classes': classes, 'race_offsets': offsets,
        'resource_offsets': {'health': -180, 'mana': -280},
        'source_formulas': {'health': 'class health + 10 * total stamina - 180', 'mana': 'class mana + 15 * total intellect - 280'},
        'rounding': 'Reference dependency and Demonic Embrace calculations use floating-point values without explicit flooring. Client rounding is unverified.',
        'racial_policy': 'Use this project\'s pinned caster racials; the reference engine weapon-gates Human/Orc crit and is not authoritative for those bonuses.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    snapshot = extract(args.checkout)
    if args.check:
        if json.loads(DESTINATION.read_text()) != snapshot:
            raise SystemExit('Reference snapshot changed; review before importing')
    else:
        DESTINATION.write_text(json.dumps(snapshot, indent=2) + '\n')
    print('Three class baselines, five race offsets and intellect crit coefficients match the saved planner.')


if __name__ == '__main__':
    main()
