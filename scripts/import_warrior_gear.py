"""Import a small Classic Warrior catalog from the pinned local tooltip cache."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'assets/db_inputs/wowhead_item_tooltips.csv'
SLOTS = {'head':16731,'shoulder':16733,'chest':16730,'wrist':16735,'hands':16737,'waist':16736,'legs':16732,'feet':16734}
WEAPONS = {12784:'axe',17705:'sword',15806:'sword'}


def extract(checkout):
    contents = (checkout / SOURCE).read_bytes()
    lines = {int(line.split(',',1)[0]):line for line in contents.decode().splitlines() if line.split(',',1)[0].isdigit()}
    items = []
    for slot, item_id in [*SLOTS.items(), *(('main_hand',i) for i in WEAPONS), ('off_hand',12602)]:
        raw = lines[item_id]
        record=json.loads(raw.split(',',1)[1])
        # A set's inactive bonuses are not passive stats on this item.
        passive=re.split(r'<span class="q"><a href="/classic/item-set=',record['tooltip'])[0]
        text = html.unescape(re.sub(r'<[^>]*>',' ',passive))
        stats = {}
        for key, marker in [('strength',4),('agility',3),('stamina',7),('intellect',5),('spirit',6)]:
            match = re.search(r'<!--stat'+str(marker)+r'-->\+(\d+)',passive)
            if match:stats[key]=int(match[1])
        for key, pattern in {'armor':r'(\d+) Armor','attack_power':r'\+(\d+) Attack Power',
                             'melee_hit':r'Improves your chance to hit by (\d+)%',
                             'melee_crit':r'Improves your chance to get a critical strike by (\d+)%',
                             'defense':r'Increased Defense \+(\d+)',
                             'fire_resistance':r'\+(\d+) Fire Resistance'}.items():
            match=re.search(pattern,text)
            if match:stats[key]=int(match[1])
        name = record["name"]
        item={'id':item_id,'name':name,'class':'warrior','slot':slot,'stats':stats,
              'quality':record['quality'],'icon':record['icon'],
              'unique':'Unique' in text,'url':f'https://www.wowhead.com/classic/item={item_id}',
              'source_row_sha256':hashlib.sha256(raw.encode()).hexdigest()}
        notes=[]
        if item_id in WEAPONS:
            damage=re.search(r'<!--dmg-->(\d+) - (\d+) Damage',passive)
            two_hand='Two-Hand' in text
            item.update(weapon={'min':int(damage[1]),'max':int(damage[2]),'speed':float(re.search(r'<!--spd-->([\d.]+)',passive)[1]),'two_handed':two_hand},
                        weapon_type=WEAPONS[item_id],two_hand=two_hand,off_hand_eligible=not two_hand)
        else:item['armor_type']='shield' if item_id==12602 else 'plate'
        if item_id==12602:item['shield_block']=int(re.search(r'(\d+) Block',text)[1])
        if 'Chance on hit:' in text:notes.append('Weapon proc is not simulated.')
        if 'defense' in stats:notes.append('Defense is recorded but does not alter avoidance or critical strike suppression.')
        if 'Set:' in text or 'item-set=' in raw:notes.append('Set bonuses are not simulated.')
        if 'spirit' in stats:notes.append('Spirit grants no regeneration in the current simulator.')
        if notes:item['effect_note']=' '.join(notes)
        items.append(item)
    base=dict(SLOTS)
    return {'version':'Classic level 60 Warrior starters v1; fixed passive stats only',
            'source':SOURCE,'source_sha256':hashlib.sha256(contents).hexdigest(),
            'formula_sources':{path:hashlib.sha256((checkout/path).read_bytes()).hexdigest() for path in
                               ['sim/core/base_stats.go','sim/core/unit.go','sim/core/spell_outcome.go','sim/warrior/warrior.go']},
            'ruleset_note':'Uses cached Classic tooltips; do not substitute Forever planner values. Starter examples, not verified PvP or Pre-BiS recommendations.',
            'items':items,
            'starters':{'two_hand':dict(base,main_hand=12784),
                        'dual_wield':dict(base,main_hand=17705,off_hand=15806),
                        'shield':dict(base,main_hand=17705,off_hand=12602)}}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout',type=Path,required=True)
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args();catalog=extract(args.checkout)
    destination=ROOT/'data/warrior_gear.json'
    if args.check:
        if json.loads(destination.read_text())!=catalog:raise SystemExit('Warrior catalog changed; review source differences')
    else:destination.write_text(json.dumps(catalog,indent=2)+'\n')
    print(f"Verified {len(catalog['items'])} Warrior items from the pinned Classic tooltip cache.")


if __name__=='__main__':main()
