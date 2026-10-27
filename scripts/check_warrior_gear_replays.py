"""Verify Warrior item starters through the built CLI and Lua/JSON replays."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def compare(actual,expected,label):
    if isinstance(expected,dict):
        for key,value in expected.items():compare(actual[key],value,label+'/'+key)
    elif isinstance(expected,(int,float)) and not isinstance(expected,bool):
        if not math.isclose(actual,expected,abs_tol=.001):raise SystemExit(f'{label}: {actual} != {expected}')
    elif actual!=expected:raise SystemExit(f'{label}: {actual} != {expected}')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=ROOT/'zig-out/bin/mcts_fight')
    args=parser.parse_args()
    fixtures={case['name']:case for case in json.loads((ROOT/'src/testdata/warrior_equipment.json').read_text())}
    with tempfile.TemporaryDirectory(prefix='pvp-warrior-gear-') as temporary:
        directory=Path(temporary)
        for names in [('two_hand','shield'),('dual_wield','two_hand')]:
            output=directory/'replay.lua'
            result=subprocess.run([str(args.binary.resolve()),'--spec-id-a',str(ROOT/'specs'/('warrior_gear_'+names[0]+'.json')),
                                   '--spec-id-b',str(ROOT/'specs'/('warrior_gear_'+names[1]+'.json')),
                                   '--distance','3','--seconds','.1','--rollouts','1','--workers','1','--nodes','16',
                                   '--depth','1','--evaluator','heuristic','--truncation-ticks','1','--output',str(output)],
                                  cwd=ROOT,capture_output=True,text=True)
            if result.returncode:raise SystemExit(result.stdout+result.stderr)
            replay=json.loads(Path(str(output)+'.json').read_text())
            search=json.loads(Path(str(output)+'.search.json').read_text())
            for side,name in zip('ab',names):
                expected=fixtures[name]
                compare(search['options']['warrior_'+side],expected['expected_warrior'],name+'/weapons')
                compare(search['options']['combat_stats_'+side],expected['expected_stats'],name+'/stats')
                compare(replay['meta']['max_health_'+side],expected['expected_stats']['max_health'],name+'/recorded_hp')
                compare(replay['meta']['max_mana_'+side],1,name+'/recorded_mana_placeholder')
            lua=['local replay=dofile(arg[1])']
            for key in ['max_health_a','max_health_b','max_mana_a','max_mana_b']:
                lua.append(f"assert(math.abs(replay.meta.{key}-{replay['meta'][key]})<.001)")
            check=directory/'check.lua';check.write_text('\n'.join(lua)+'\n')
            subprocess.run(['lua',str(check),str(output)],check=True,cwd=ROOT)
    print('Two Warrior fights passed: all three item starters, native weapons/defenses and Lua/JSON replay maxima.')


if __name__=='__main__':main()
