#!/usr/bin/env python3
"""Measure integrated automatic pets; optionally compare a pre-pet binary.

Build ReleaseFast first. Measurements include changed search paths and fight
lengths; ticks/s and rollouts/s answer different questions.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='zig-out/bin/mcts_fight')
parser.add_argument('--before', help='Optional pre-pet binary, with pets absent')
parser.add_argument('--rollouts', type=int, default=10000)
parser.add_argument('--samples', type=int, default=3)
parser.add_argument('--output', type=Path, default=Path('benchmarks/mcts/pet_mvp_results.json'))
args = parser.parse_args()
if args.rollouts <= 0 or args.samples <= 0:
    parser.error('rollouts and samples must be positive')

cases = [('none', args.binary, ['--pet-a', 'none', '--pet-b', 'none'])]
for kind in ('imp', 'succubus', 'felhunter', 'voidwalker'):
    cases.append((kind, args.binary, ['--pet-a', kind, '--pet-b', kind]))
if args.before:
    cases.insert(0, ('before', args.before, []))
runs = []
for sample in range(args.samples):
    order = cases if sample % 2 == 0 else list(reversed(cases))
    for name, binary, pet_args in order:
        command = [binary, '--benchmark', '--spec-a', 'warlock', '--spec-b', 'warlock',
                   '--workers', '1', '--rollouts', str(args.rollouts), '--rounds', '1',
                   '--seed', str(1 + sample), '--evaluator', 'heuristic', *pet_args]
        data = json.loads(subprocess.check_output(command, text=True))
        runs.append(dict(case=name, sample=sample, command=command, result=data))
        print(name, sample, data['rollouts_per_second'], 'rollouts/s', flush=True)

summary = {}
for name, _, _ in cases:
    results = [r['result'] for r in runs if r['case'] == name]
    summary[name] = {key: statistics.median(r[key] for r in results)
                     for key in ('rollouts_per_second', 'ticks_per_second', 'memory_bytes')}
baseline = summary['none']
for name, result in summary.items():
    result['rollout_rate_change_pct_vs_none'] = 100 * (result['rollouts_per_second'] / baseline['rollouts_per_second'] - 1)
    result['tick_rate_change_pct_vs_none'] = 100 * (result['ticks_per_second'] / baseline['ticks_per_second'] - 1)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(
    note='One worker, opening position, both sides have the same pet. Medians across seeds; changed combat/search workloads are not an isolated physics overhead.',
    summary=summary, runs=runs), indent=2) + '\n')
print(json.dumps(summary, indent=2))
