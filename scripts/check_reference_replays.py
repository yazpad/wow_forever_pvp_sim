"""Smoke-check reference profiles through the built CLI and recorded replays."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/mcts_fight')
    args = parser.parse_args()
    fixtures = {case['name']: case for case in json.loads((ROOT / 'src/testdata/reference_stats.json').read_text())}
    with tempfile.TemporaryDirectory(prefix='pvp-reference-replays-') as temporary:
        directory = Path(temporary)
        for names in [('warlock_human_geared', 'frost_mage_human_geared'),
                      ('warlock_gnome_talent_resources', 'priest_human_geared')]:
            paths = []
            for side, name in zip('ab', names):
                source = fixtures[name]['input']
                if source['race'] == 'human':
                    path = ROOT / 'specs' / (source['class'] + '_reference_level60.json')
                else:
                    path = directory / (side + '.json')
                    path.write_text(json.dumps(source))
                paths.append(path)
            output = directory / 'replay.lua'
            result = subprocess.run([str(args.binary.resolve()), '--spec-id-a', str(paths[0]),
                                     '--spec-id-b', str(paths[1]), '--seconds', '0.1',
                                     '--rollouts', '1', '--workers', '1', '--nodes', '16',
                                     '--depth', '1', '--evaluator', 'heuristic',
                                     '--truncation-ticks', '1', '--output', str(output)],
                                    cwd=ROOT, capture_output=True, text=True)
            if result.returncode:
                raise SystemExit(result.stdout + result.stderr)
            replay = json.loads(Path(str(output) + '.json').read_text())
            search = json.loads(Path(str(output) + '.search.json').read_text())
            for side, name in zip('ab', names):
                for key in ['max_health', 'max_mana']:
                    actual = replay['meta'][key + '_' + side]
                    if not math.isclose(actual, fixtures[name]['runtime_expected'][key], abs_tol=.001):
                        raise SystemExit(f'Replay resource mismatch: {name}/{key}: {actual}')
                    actual = search['options']['combat_stats_' + side][key]
                    if not math.isclose(actual, fixtures[name]['native_expected'][key], abs_tol=.001):
                        raise SystemExit(f'Native input mismatch: {name}/{key}: {actual}')
            # Parse the actual Lua artifact as the visualizer does, comparing all
            # four resource maxima to the independently checked JSON artifact.
            expected = replay['meta']
            lua = ['local replay=dofile(arg[1])']
            for key in ['max_health_a', 'max_health_b', 'max_mana_a', 'max_mana_b']:
                lua.append(f'assert(math.abs(replay.meta.{key}-{expected[key]})<.001)')
            check = directory / 'check.lua'
            check.write_text('\n'.join(lua) + '\n')
            subprocess.run(['lua', str(check), str(output)], check=True, cwd=ROOT)
    print('Two recorded fights passed: three caster profiles, racial/talent resources, native inputs and Lua/JSON replay maxima.')


if __name__ == '__main__':
    main()
