#!/usr/bin/env python3
"""Run sequential shared/class comparisons without concurrent timing interference."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--modes', nargs='+', default=['class', 'shared'])
p.add_argument('--models', type=Path, default=Path('evaluation_runs/value_pilot/models'))
p.add_argument('--output', type=Path, required=True)
p.add_argument('--games', type=int, default=32, help='Scenario pairs per architecture')
p.add_argument('--seed', type=int, default=30000)
p.add_argument('--rollouts', type=int, default=256)
p.add_argument('--baseline-rollouts', type=int, default=256)
p.add_argument('--mix', type=float, default=.5)
p.add_argument('--ms', type=int, default=0)
p.add_argument('--terminal-baseline', action='store_true')
p.add_argument('--full-health', action='store_true')
p.add_argument('--default-pets', action='store_true')
p.add_argument('--nodes', type=int, default=1024)
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
binary = ROOT / 'zig-out/bin/learning_arena'
manifest = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'commands': []}
files = []
for mode in args.modes:
    model = args.models / f'{mode}.json'
    output = args.output / f'{mode}.jsonl'
    command = [str(binary), '--games', str(args.games), '--seed', str(args.seed),
        '--rollouts', str(args.rollouts), '--baseline-rollouts', str(args.baseline_rollouts),
        '--mix', str(args.mix), '--ms', str(args.ms), '--model', str(model), '--output', str(output)]
    if args.nodes != 1024:
        command += ['--nodes', str(args.nodes)]
    if args.default_pets:
        command += ['--default-pets']
    if args.full_health:
        command += ['--full-health']
    if args.terminal_baseline:
        command += ['--terminal-baseline']
    print(mode, ' '.join(command), flush=True)
    started = time.monotonic()
    subprocess.run(command, check=True, cwd=ROOT)
    manifest['commands'].append({'argv': command, 'wall_seconds': time.monotonic() - started,
        'model_sha256': hashlib.sha256(model.read_bytes()).hexdigest()})
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    files.append(str(output))
summary = subprocess.check_output([sys.executable, str(ROOT / 'scripts/value_learning.py'), 'summarize', *files], text=True)
(args.output / 'summary.json').write_text(summary)
print(summary, flush=True)
