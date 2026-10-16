#!/usr/bin/env python3
"""Fresh value-only experiment: fit shared/per-class MLPs and summarize paired arenas.
Run with OPENBLAS_NUM_THREADS=1 to avoid thread overhead on these tiny matrices.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path
import subprocess
import numpy as np

INPUTS, HIDDEN = 58, 16
ROOT = Path(__file__).resolve().parents[1]


def read_games(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def dataset(games):
    x, y, weights = [], [], []
    for game in games:
        # Give each trajectory equal total weight; adjacent states are correlated.
        n = len(game['samples'])
        for sample in game['samples']:
            x.extend(sample['x'])
            y.extend([game['reward_a'], -game['reward_a']])
            weights.extend([1 / n, 1 / n])
    return np.array(x, dtype=np.float32), np.array(y, dtype=np.float32), np.array(weights, dtype=np.float32)


def init(seed):
    rng = np.random.default_rng(seed)
    return [rng.normal(0, np.sqrt(2 / INPUTS), (HIDDEN, INPUTS)).astype(np.float32),
            np.zeros(HIDDEN, np.float32), rng.normal(0, .1, HIDDEN).astype(np.float32), np.zeros(1, np.float32)]


def predict(params, x):
    w, b, v, c = params
    return np.tanh(np.maximum(0, x @ w.T + b) @ v + c[0])


def fit(train, validation, seed, epochs):
    x, y, weights = train
    vx, vy, vw = validation
    if len(x) == 0 or len(vx) == 0:
        raise ValueError('Each model needs both training and validation trajectories')
    params = init(seed)
    momentum = [np.zeros_like(p) for p in params]
    variance = [np.zeros_like(p) for p in params]
    rng = np.random.default_rng(seed)
    best, best_loss, step = None, float('inf'), 0
    for epoch in range(epochs):
        order = rng.permutation(len(x))
        for start in range(0, len(x), 256):
            ids = order[start:start + 256]
            bx, by, bw = x[ids], y[ids], weights[ids]
            w, b, v, c = params
            pre = bx @ w.T + b
            h = np.maximum(0, pre)
            out = np.tanh(h @ v + c[0])
            delta = 2 * (out - by) * (1 - out * out) * bw / bw.sum()
            dh = delta[:, None] * v * (pre > 0)
            grads = [dh.T @ bx + 1e-4 * w, dh.sum(axis=0), h.T @ delta + 1e-4 * v, np.array([delta.sum()])]
            step += 1
            for p, m, variance_p, grad in zip(params, momentum, variance, grads):
                m *= .9
                m += .1 * grad
                variance_p *= .999
                variance_p += .001 * grad * grad
                p -= .002 * (m / (1 - .9 ** step)) / (np.sqrt(variance_p / (1 - .999 ** step)) + 1e-8)
        loss = float(np.average((predict(params, vx) - vy) ** 2, weights=vw))
        if loss < best_loss:
            best_loss = loss
            best = [p.copy() for p in params]
    return best, {'validation_mse': best_loss,
                  'training_mse': float(np.average((predict(best, x) - y) ** 2, weights=weights)),
                  'train_rows': len(x), 'validation_rows': len(vx)}


def encode(params):
    w, b, v, c = params
    return dict(w=w.tolist(), bias=b.tolist(), out=v.tolist(), out_bias=float(c[0]))


def select(data, index):
    x, y, weights = data
    ids = (x[:, 0] == (1 if index == 0 else 0))
    return x[ids], y[ids], weights[ids]


def train(args):
    games = read_games(args.data)
    fingerprints = {g['fingerprint'] for g in games}
    if len(fingerprints) != 1:
        raise ValueError('Mixed simulator versions')
    # Split by whole fight, never adjacent states; stratify by matchup.
    train_games, val_games = [], []
    for matchup in range(4):
        group = [g for g in games if g['seed'] % 4 == matchup]
        for i, game in enumerate(group):
            (val_games if i % 5 == 0 else train_games).append(game)
    tr, va = dataset(train_games), dataset(val_games)
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'schema': 1, 'fingerprint': next(iter(fingerprints)), 'seed': args.seed,
              'data_sha256': hashlib.sha256(args.data.read_bytes()).hexdigest(),
              'trainer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'training_seeds': [g['seed'] for g in train_games], 'validation_seeds': [g['seed'] for g in val_games],
              'architecture': [INPUTS, HIDDEN, 1], 'parameters_per_network': HIDDEN * INPUTS + 2 * HIDDEN + 1,
              'models': {}}
    for mode in ['shared', 'class']:
        mode_started = time.monotonic()
        models, metrics = [], []
        for i in range(1 if mode == 'shared' else 2):
            p, metric = fit(tr if mode == 'shared' else select(tr, i), va if mode == 'shared' else select(va, i), args.seed + i, args.epochs)
            models.append(encode(p))
            metrics.append(metric)
        if mode == 'shared':
            models *= 2  # Fixed native bundle layout; inference uses only the first network.
        bundle = dict(schema=1, fingerprint=report['fingerprint'], mode=mode, networks=models)
        path = args.output / f'{mode}.json'
        path.write_text(json.dumps(bundle, allow_nan=False))
        report['models'][mode] = {'networks': metrics, 'fit_seconds': time.monotonic() - mode_started}
    zero = encode([np.zeros((HIDDEN, INPUTS), np.float32), np.zeros(HIDDEN, np.float32),
                   np.zeros(HIDDEN, np.float32), np.zeros(1, np.float32)])
    (args.output / 'zero.json').write_text(json.dumps(dict(schema=1, fingerprint=report['fingerprint'],
                                                        mode='class', networks=[zero, zero])))
    (args.output / 'training.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


def summarize(args):
    reports = {}
    paired_scores = []
    for path in args.files:
        games = read_games(path)
        pairs = {}
        for g in games:
            pairs.setdefault(g['seed'], []).append(g)
        if any(len(pair) != 2 or {g['candidate_side'] for g in pair} != {'a', 'b'} for pair in pairs.values()):
            raise ValueError('Expected complete controller-swapped pairs')
        by_seed = {seed: np.mean([g['score'] for g in pair]) for seed, pair in pairs.items()}
        paired_scores.append(by_seed)
        scores = np.array(list(by_seed.values()))
        rng = np.random.default_rng(12345)
        ci = np.quantile(rng.choice(scores, (10000, len(scores)), replace=True).mean(axis=1), [.025, .975])
        def per_call(prefix):
            return sum(g[prefix + '_seconds'] for g in games) / max(1, sum(g[prefix + '_calls'] for g in games))
        reports[str(path)] = dict(games=len(games), pairs=len(pairs), score=float(scores.mean()),
            paired_bootstrap_95_ci=ci.tolist(), wins=sum(g['score'] == 1 for g in games),
            draws=sum(g['score'] == .5 for g in games), losses=sum(g['score'] == 0 for g in games),
            base_mean_decision_ms=per_call('base') * 1000, candidate_mean_decision_ms=per_call('candidate') * 1000,
            total_base_seconds=sum(g['base_seconds'] for g in games), total_candidate_seconds=sum(g['candidate_seconds'] for g in games),
            candidate_median_fight_p95_ms=float(np.median([g['candidate_p95_seconds'] for g in games])) * 1000,
            by_matchup={m: float(np.mean([g['score'] for g in games if g['class_a'] + '/' + g['class_b'] == m]))
                        for m in sorted({g['class_a'] + '/' + g['class_b'] for g in games})})
    if len(paired_scores) == 2 and paired_scores[0].keys() == paired_scores[1].keys():
        difference = np.array([paired_scores[0][seed] - paired_scores[1][seed] for seed in paired_scores[0]])
        rng = np.random.default_rng(987)
        ci = np.quantile(rng.choice(difference, (10000, len(difference)), replace=True).mean(axis=1), [.025, .975])
        reports['paired_architecture_difference'] = {'first': str(args.files[0]), 'second': str(args.files[1]),
            'mean_score_difference': float(difference.mean()), 'paired_bootstrap_95_ci': ci.tolist()}
    print(json.dumps(reports, indent=2))


def verify(args):
    checks = {}
    for path in args.models:
        bundle = json.loads(path.read_text())
        probe = args.output / (path.stem + '_probe.jsonl')
        subprocess.run([str(ROOT / 'zig-out/bin/learning_arena'), '--probe', '--model', str(path), '--output', str(probe)], check=True)
        rows = read_games(probe)
        x = np.array([row['x'] for row in rows], np.float32)
        expected = []
        for model in bundle['networks']:
            params = [np.array(model['w'], np.float32), np.array(model['bias'], np.float32),
                      np.array(model['out'], np.float32), np.array([model['out_bias']], np.float32)]
            expected.append(predict(params, x))
        error = float(np.max(np.abs(np.array(expected).T - np.array([row['predictions'] for row in rows]))))
        if error > 2e-5:
            raise AssertionError(f'Native/Python mismatch: {error}')
        checks[str(path)] = {'max_absolute_native_python_error': error}
    rng = np.random.default_rng(123)
    x = rng.uniform(-1, 1, (64, INPUTS)).astype(np.float32)
    y = np.tanh(2 * x[:, 4] - x[:, 24]).astype(np.float32)
    data = x, y, np.ones(len(x), np.float32)
    _, metric = fit(data, data, 19, 250)
    if metric['training_mse'] > .003:
        raise AssertionError(f'Tiny-data fit failed: {metric}')
    checks['synthetic_overfit'] = metric
    (args.output / 'integrity.json').write_text(json.dumps(checks, indent=2))
    print(json.dumps(checks, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    p = subs.add_parser('train')
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seed', type=int, default=17)
    p.add_argument('--epochs', type=int, default=120)
    p.set_defaults(func=train)
    p = subs.add_parser('summarize')
    p.add_argument('files', nargs='+', type=Path)
    p.set_defaults(func=summarize)
    p = subs.add_parser('verify')
    p.add_argument('models', nargs='+', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.set_defaults(func=verify)
    args = parser.parse_args()
    args.func(args)
