#!/usr/bin/env python3
"""Reproduce MCTS throughput or paired quality experiments (Python stdlib only).
Build first: zig build -Doptimize=ReleaseFast
Quality mode can take several minutes. Results and playable fights are retained.
"""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--suite', choices=['speed', 'quality'], default='speed')
parser.add_argument('--output', type=Path, default=Path('evaluation_runs/mcts'))
parser.add_argument('--rollouts', type=int, nargs='+', default=[10000])
parser.add_argument('--workers', type=int, nargs='+', default=[1, 2, 4, 8, 16])
parser.add_argument('--seeds', type=int, nargs='+', default=[1, 2, 3, 4])
parser.add_argument('--algorithm', choices=['exp3', 'uct', 'puct'], default='puct')
parser.add_argument('--evaluator', choices=['rollout', 'heuristic', 'neural'], default='rollout')
parser.add_argument('--boundary', choices=['event', 'tick'], default='event')
parser.add_argument('--opponent', choices=['heuristic', 'random', 'champion'], default='heuristic')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
with (args.output / (args.suite + '.jsonl')).open('w') as output:
    for budget in args.rollouts:
        for workers in args.workers:
            base = ['zig-out/bin/mcts_fight', '--rollouts', str(budget),
                    '--workers', str(workers), '--algorithm', args.algorithm,
                    '--evaluator', args.evaluator, '--boundary', args.boundary]
            if args.suite == 'speed':
                for a, b in [('warlock', 'warlock'), ('frost_mage', 'warlock'),
                             ('frost_mage', 'frost_mage')]:
                    command = base + ['--benchmark', '--rounds', '2', '--spec-a', a, '--spec-b', b]
                    result = subprocess.run(command, check=True, text=True, capture_output=True)
                    print(result.stdout, end='', flush=True)
                    output.write(result.stdout)
                    output.flush()
            else:
                for seed in args.seeds:
                    for side in ['a', 'b']:
                        replay = args.output / f'{args.algorithm}_{budget}_{workers}_{seed}_{side}.lua'
                        command = base + ['--seed', str(seed), '--opponent', args.opponent,
                                          '--search-side', side, '--output', str(replay)]
                        subprocess.run(command, check=True)
                        data = json.loads(Path(str(replay) + '.search.json').read_text())
                        result = dict(data['summary'], budget=budget, workers=workers,
                                      seed=seed, side=side, algorithm=args.algorithm, opponent=args.opponent)
                        output.write(json.dumps(result) + '\n')
                        output.flush()
