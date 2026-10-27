"""Pin the first Forever item effect from the local saved planner metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
SOURCE='assets/db_inputs/wowhead_forever_gearplanner.txt'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout',type=Path,required=True);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    source=(args.checkout/SOURCE).read_text();items=[]
    for item_id in [274445,274444]:
        match=re.search(r'"'+str(item_id)+r'":\{"id":'+str(item_id)+r',',source)
        item=json.JSONDecoder().raw_decode(source[match.start()+len(str(item_id))+3:])[0]
        if item['stats']['cooldown']!=300000:raise SystemExit('Greater Insignia cooldown changed; review effect tuning')
        items.append({'id':item_id,'name':item['name'],'slot':'trinket','all_classes':True,'unique':True,'unique_group':'pvp_control_break','stats':{},'quality':item['quality'],'icon':item['icon'],'url':f'https://www.wowhead.com/forever/item={item_id}','effect_id':'forever_greater_insignia_v1','cooldown_seconds':item['stats']['cooldown']/1000,'effect_note':'Use: removes modeled movement impairments and control. 300 sec cooldown; no ongoing immunity.'})
    snapshot={'ruleset':'Forever Greater Insignia v1; distinct from Classic class-specific insignias','source':SOURCE,'source_sha256':hashlib.sha256(source.encode()).hexdigest(),'effect_source':'https://www.wowhead.com/forever/item=274444/greater-insignia-of-the-horde','spell_id':438273,'items':items}
    destination=ROOT/'data/item_actives.json'
    if args.check:
        if json.loads(destination.read_text())!=snapshot:raise SystemExit('Item active snapshot changed; review before importing')
    else:destination.write_text(json.dumps(snapshot,indent=2)+'\n')
    print('Both Greater Insignia variants match the pinned Forever planner metadata.')
if __name__=='__main__':main()
