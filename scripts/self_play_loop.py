#!/usr/bin/env python3
"""Phase 3: Self-Play Generation & Iteration Loop for Universal AlphaZero / PUCT Architecture.

This script implements:
1. Data Generation Pipeline:
   - Self-play generation across matchup combinations (Warlock x Warlock, Mage x Warlock,
     Warlock x Mage, Mage x Mage) guided by PUCT search with leaf evaluation from the current model.
   - Extracts training tuples: (s_t, pi_action, pi_move, z).
2. Model Fitting:
   - PyTorch-free NumPy gradient-descent / Adam optimizer fitting the universal multi-task loss:
     L = (z - V(s))^2 + cross_entropy(pi_act, P_act) + cross_entropy(pi_mv, P_mv) + L2_reg
3. Iteration Loop:
   - Trains iteratively over generations.
   - Saves model checkpoints compatible with the native AVX2 SIMD inference engine.
"""

import argparse
import glob
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import numpy as np

# Model constants matching src/universal_model.zig
IN_DIM = 52
H1 = 64
H2 = 64
ACT_DIM = 9
MOVE_DIM = 3

class UniversalModelNP:
    def __init__(self, filename=None):
        if filename and os.path.exists(filename):
            self.load(filename)
        else:
            # Random initialization
            scale1 = np.sqrt(2.0 / IN_DIM)
            self.w1 = (np.random.uniform(-1, 1, (H1, IN_DIM)) * scale1).astype(np.float32)
            self.b1 = np.zeros(H1, dtype=np.float32)

            scale2 = np.sqrt(2.0 / H1)
            self.w2 = (np.random.uniform(-1, 1, (H2, H1)) * scale2).astype(np.float32)
            self.b2 = np.zeros(H2, dtype=np.float32)

            scale3 = np.sqrt(2.0 / H2)
            self.w_val = (np.random.uniform(-1, 1, H2) * scale3).astype(np.float32)
            self.b_val = np.float32(0.0)

            self.w_act = (np.random.uniform(-1, 1, (ACT_DIM, H2)) * scale3).astype(np.float32)
            self.b_act = np.zeros(ACT_DIM, dtype=np.float32)

            self.w_move = (np.random.uniform(-1, 1, (MOVE_DIM, H2)) * scale3).astype(np.float32)
            self.b_move = np.zeros(MOVE_DIM, dtype=np.float32)

    def load(self, filename):
        with open(filename, 'rb') as f:
            magic = f.read(4)
            if magic != b'UNIV':
                raise ValueError(f"Invalid magic: {magic}")
            version, = struct.unpack('<I', f.read(4))
            if version != 1:
                raise ValueError(f"Unsupported version: {version}")
            self.w1 = np.frombuffer(f.read(H1 * IN_DIM * 4), dtype=np.float32).reshape(H1, IN_DIM).copy()
            self.b1 = np.frombuffer(f.read(H1 * 4), dtype=np.float32).copy()
            self.w2 = np.frombuffer(f.read(H2 * H1 * 4), dtype=np.float32).reshape(H2, H1).copy()
            self.b2 = np.frombuffer(f.read(H2 * 4), dtype=np.float32).copy()
            self.w_val = np.frombuffer(f.read(H2 * 4), dtype=np.float32).copy()
            self.b_val, = struct.unpack('<f', f.read(4))
            self.w_act = np.frombuffer(f.read(ACT_DIM * H2 * 4), dtype=np.float32).reshape(ACT_DIM, H2).copy()
            self.b_act = np.frombuffer(f.read(ACT_DIM * 4), dtype=np.float32).copy()
            self.w_move = np.frombuffer(f.read(MOVE_DIM * H2 * 4), dtype=np.float32).reshape(MOVE_DIM, H2).copy()
            self.b_move = np.frombuffer(f.read(MOVE_DIM * 4), dtype=np.float32).copy()

    def save(self, filename):
        with open(filename, 'wb') as f:
            f.write(b'UNIV')
            f.write(struct.pack('<I', 1))
            f.write(self.w1.astype(np.float32).tobytes())
            f.write(self.b1.astype(np.float32).tobytes())
            f.write(self.w2.astype(np.float32).tobytes())
            f.write(self.b2.astype(np.float32).tobytes())
            f.write(self.w_val.astype(np.float32).tobytes())
            f.write(struct.pack('<f', float(self.b_val)))
            f.write(self.w_act.astype(np.float32).tobytes())
            f.write(self.b_act.astype(np.float32).tobytes())
            f.write(self.w_move.astype(np.float32).tobytes())
            f.write(self.b_move.astype(np.float32).tobytes())


def parse_training_file(filename):
    """Parses binary training tuples recorded by mcts_fight."""
    with open(filename, 'rb') as f:
        magic = f.read(4)
        if magic != b'TRND':
            return None
        count, = struct.unpack('<I', f.read(4))
        if count == 0:
            return None

        # Each record:
        # 1 byte spec_self, 1 byte spec_opp, 1 byte side, 1 byte pad = 4 bytes
        # 24 floats state_self = 96 bytes
        # 24 floats state_opp = 96 bytes
        # 9 floats action_probs = 36 bytes
        # 3 floats move_probs = 12 bytes
        # 1 float z = 4 bytes
        # Total = 248 bytes per record
        rec_len = 4 + 96 + 96 + 36 + 12 + 4
        buf = f.read(count * rec_len)
        if len(buf) < count * rec_len:
            return None

    # Vectorized decode using numpy
    dt = np.dtype([
        ('spec_self', 'u1'),
        ('spec_opp', 'u1'),
        ('side', 'u1'),
        ('pad', 'u1'),
        ('state_self', '<f4', (24,)),
        ('state_opp', '<f4', (24,)),
        ('action_probs', '<f4', (9,)),
        ('move_probs', '<f4', (3,)),
        ('z', '<f4'),
    ])
    records = np.frombuffer(buf, dtype=dt, count=count)

    # Encode 52-dim inputs: [Spec_Self (2 one-hot), State_Self (24), Spec_Opp (2 one-hot), State_Opp (24)]
    X = np.zeros((count, IN_DIM), dtype=np.float32)
    # Spec Self one-hot
    spec_self = records['spec_self']
    X[spec_self == 0, 0] = 1.0  # warlock
    X[spec_self == 1, 1] = 1.0  # frost_mage
    X[:, 2:26] = records['state_self']

    # Spec Opp one-hot
    spec_opp = records['spec_opp']
    X[spec_opp == 0, 26] = 1.0
    X[spec_opp == 1, 27] = 1.0
    X[:, 28:52] = records['state_opp']

    Y_val = records['z'].copy()
    Y_act = records['action_probs'].copy()
    Y_move = records['move_probs'].copy()

    return X, Y_val, Y_act, Y_move


def train_epoch(model, X, Y_val, Y_act, Y_move, lr=0.002, batch_size=256, l2_reg=1e-4, adam_state=None):
    """Fits universal dual-head network using Adam optimizer."""
    n_samples = X.shape[0]
    indices = np.random.permutation(n_samples)

    if adam_state is None:
        adam_state = {
            't': 0,
            'm': {k: np.zeros_like(getattr(model, k)) for k in ['w1', 'b1', 'w2', 'b2', 'w_val', 'b_val', 'w_act', 'b_act', 'w_move', 'b_move']},
            'v': {k: np.zeros_like(getattr(model, k)) for k in ['w1', 'b1', 'w2', 'b2', 'w_val', 'b_val', 'w_act', 'b_act', 'w_move', 'b_move']},
        }

    beta1 = 0.9
    beta2 = 0.999
    eps = 1e-8

    total_loss_val = 0.0
    total_loss_act = 0.0
    total_loss_mv = 0.0
    n_batches = 0

    for start_idx in range(0, n_samples, batch_size):
        batch_idx = indices[start_idx:start_idx + batch_size]
        xb = X[batch_idx]
        yb_val = Y_val[batch_idx]
        yb_act = Y_act[batch_idx]
        yb_mv = Y_move[batch_idx]
        B = xb.shape[0]

        # Forward pass
        # Trunk Layer 1
        z1 = xb @ model.w1.T + model.b1
        h1 = np.maximum(0.0, z1)

        # Trunk Layer 2
        z2 = h1 @ model.w2.T + model.b2
        h2 = np.maximum(0.0, z2)

        # Value Head: fast tanh approx = u / (1 + |u|)
        val_lin = h2 @ model.w_val + model.b_val
        val_pred = val_lin / (1.0 + np.abs(val_lin))

        # Action Logits & Softmax
        act_logits = h2 @ model.w_act.T + model.b_act
        act_logits_shift = act_logits - np.max(act_logits, axis=1, keepdims=True)
        exp_act = np.exp(act_logits_shift)
        act_probs = exp_act / (np.sum(exp_act, axis=1, keepdims=True) + 1e-9)

        # Move Logits & Softmax
        mv_logits = h2 @ model.w_move.T + model.b_move
        mv_logits_shift = mv_logits - np.max(mv_logits, axis=1, keepdims=True)
        exp_mv = np.exp(mv_logits_shift)
        mv_probs = exp_mv / (np.sum(exp_mv, axis=1, keepdims=True) + 1e-9)

        # Losses
        loss_val = np.mean((val_pred - yb_val) ** 2)
        loss_act = -np.mean(np.sum(yb_act * np.log(act_probs + 1e-9), axis=1))
        loss_mv = -np.mean(np.sum(yb_mv * np.log(mv_probs + 1e-9), axis=1))

        total_loss_val += loss_val
        total_loss_act += loss_act
        total_loss_mv += loss_mv
        n_batches += 1

        # Backpropagation
        # 1. dL/d(val_pred) = 2 * (val_pred - yb_val) / B
        d_val_pred = (2.0 * (val_pred - yb_val)) / B
        # d(val_pred)/d(val_lin) = 1 / (1 + |val_lin|)^2
        d_val_lin = d_val_pred / ((1.0 + np.abs(val_lin)) ** 2)

        grad_w_val = d_val_lin @ h2 + l2_reg * model.w_val
        grad_b_val = np.float32(np.sum(d_val_lin))

        # 2. dL/d(act_logits) = (act_probs - yb_act) / B
        d_act_logits = (act_probs - yb_act) / B
        grad_w_act = d_act_logits.T @ h2 + l2_reg * model.w_act
        grad_b_act = np.sum(d_act_logits, axis=0)

        # 3. dL/d(mv_logits) = (mv_probs - yb_mv) / B
        d_mv_logits = (mv_probs - yb_mv) / B
        grad_w_move = d_mv_logits.T @ h2 + l2_reg * model.w_move
        grad_b_move = np.sum(d_mv_logits, axis=0)

        # Gradient into h2
        dh2 = (np.outer(d_val_lin, model.w_val) +
               d_act_logits @ model.w_act +
               d_mv_logits @ model.w_move)
        dz2 = dh2 * (z2 > 0)

        grad_w2 = dz2.T @ h1 + l2_reg * model.w2
        grad_b2 = np.sum(dz2, axis=0)

        # Gradient into h1
        dh1 = dz2 @ model.w2
        dz1 = dh1 * (z1 > 0)

        grad_w1 = dz1.T @ xb + l2_reg * model.w1
        grad_b1 = np.sum(dz1, axis=0)

        # Adam parameter update
        adam_state['t'] += 1
        t = adam_state['t']
        grads = {
            'w1': grad_w1, 'b1': grad_b1,
            'w2': grad_w2, 'b2': grad_b2,
            'w_val': grad_w_val, 'b_val': grad_b_val,
            'w_act': grad_w_act, 'b_act': grad_b_act,
            'w_move': grad_w_move, 'b_move': grad_b_move
        }

        for k, g in grads.items():
            if k == 'b_val':
                m = adam_state['m'][k]
                v = adam_state['v'][k]
                m_new = beta1 * m + (1.0 - beta1) * g
                v_new = beta2 * v + (1.0 - beta2) * (g ** 2)
                adam_state['m'][k] = m_new
                adam_state['v'][k] = v_new
                m_hat = m_new / (1.0 - (beta1 ** t))
                v_hat = v_new / (1.0 - (beta2 ** t))
                model.b_val -= float(lr * m_hat / (np.sqrt(v_hat) + eps))
            else:
                m = adam_state['m'][k]
                v = adam_state['v'][k]
                m[:] = beta1 * m + (1.0 - beta1) * g
                v[:] = beta2 * v + (1.0 - beta2) * (g ** 2)
                m_hat = m / (1.0 - (beta1 ** t))
                v_hat = v / (1.0 - (beta2 ** t))
                update = lr * m_hat / (np.sqrt(v_hat) + eps)
                param = getattr(model, k)
                param -= update

    return (total_loss_val / n_batches,
            total_loss_act / n_batches,
            total_loss_mv / n_batches,
            adam_state)


def generate_self_play(exec_path, model_path, output_dir, n_matches=20, rollouts=256, workers=8, gen=0):
    """Runs self-play fights across matchup pairings and outputs training datasets."""
    pairings = [
        ('warlock', 'frost_mage'),
        ('frost_mage', 'warlock'),
        ('warlock', 'warlock'),
        ('frost_mage', 'frost_mage'),
    ]

    tuple_files = []
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    matches_dir = Path(output_dir) / f'gen_{gen}_matches'
    matches_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n[Gen {gen}] Generating {n_matches} self-play duels with PUCT search (rollouts={rollouts})...")
    t0 = time.time()
    for i in range(n_matches):
        spec_a, spec_b = pairings[i % len(pairings)]
        seed = 1000 * gen + i + 1
        out_lua = matches_dir / f"duel_{i:03d}_{spec_a}_vs_{spec_b}.lua"
        out_bin = matches_dir / f"tuples_{i:03d}.bin"

        cmd = [
            exec_path,
            '--spec-a', spec_a,
            '--spec-b', spec_b,
            '--workers', str(workers),
            '--rollouts', str(rollouts),
            '--algorithm', 'puct',
            '--evaluator', 'neural',
            '--model', model_path,
            '--truncation-ticks', '0',
            '--seed', str(seed),
            '--record-training', str(out_bin),
            '--output', str(out_lua),
        ]

        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"Error running match {i}: {res.stderr}")
            continue

        if out_bin.exists():
            tuple_files.append(str(out_bin))

        if (i + 1) % 5 == 0 or (i + 1) == n_matches:
            dt = time.time() - t0
            print(f"  Generated {i + 1}/{n_matches} duels ({dt:.1f}s elapsed, {len(tuple_files)} files saved)...")

    return tuple_files


def run_pipeline(generations=3, matches_per_gen=20, rollouts=256, workers=8, output_dir="models/universal_alpha"):
    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    # 1. Initialize or load base model
    base_model_path = out_path / "model_gen_0.bin"
    if not base_model_path.exists():
        print(f"Exporting initial warm-start bootstrap model to {base_model_path}...")
        subprocess.run(["zig", "run", "src/export_bootstrap.zig"], check=True)
        subprocess.run(["cp", "bootstrapped_model.bin", str(base_model_path)], check=True)

    exec_path = "./zig-out/bin/mcts_fight"
    current_model = str(base_model_path)

    all_X = []
    all_Y_val = []
    all_Y_act = []
    all_Y_move = []

    for gen in range(1, generations + 1):
        print(f"\n==========================================")
        print(f"      STARTING GENERATION {gen}/{generations}")
        print(f"==========================================")

        # Step 1: Self-Play Data Generation
        t_gen_start = time.time()
        tuple_files = generate_self_play(
            exec_path=exec_path,
            model_path=current_model,
            output_dir=output_dir,
            n_matches=matches_per_gen,
            rollouts=rollouts,
            workers=workers,
            gen=gen,
        )

        # Step 2: Load & Aggregate Tuples
        print(f"\nLoading tuples from {len(tuple_files)} duel traces...")
        gen_X, gen_Y_val, gen_Y_act, gen_Y_move = [], [], [], []
        for tf in tuple_files:
            parsed = parse_training_file(tf)
            if parsed is not None:
                x, y_v, y_a, y_m = parsed
                gen_X.append(x)
                gen_Y_val.append(y_v)
                gen_Y_act.append(y_a)
                gen_Y_move.append(y_m)

        if not gen_X:
            print("No valid training samples generated, aborting.")
            return

        cur_X = np.concatenate(gen_X, axis=0)
        cur_Y_val = np.concatenate(gen_Y_val, axis=0)
        cur_Y_act = np.concatenate(gen_Y_act, axis=0)
        cur_Y_move = np.concatenate(gen_Y_move, axis=0)

        # Accumulate sliding window / replay buffer
        all_X.append(cur_X)
        all_Y_val.append(cur_Y_val)
        all_Y_act.append(cur_Y_act)
        all_Y_move.append(cur_Y_move)

        # Keep last 3 generations in buffer
        if len(all_X) > 3:
            all_X.pop(0)
            all_Y_val.pop(0)
            all_Y_act.pop(0)
            all_Y_move.pop(0)

        train_X = np.concatenate(all_X, axis=0)
        train_Y_val = np.concatenate(all_Y_val, axis=0)
        train_Y_act = np.concatenate(all_Y_act, axis=0)
        train_Y_move = np.concatenate(all_Y_move, axis=0)

        print(f"Dataset Size: {train_X.shape[0]} samples ({cur_X.shape[0]} from this generation)")

        # Step 3: Model Fitting
        print(f"Training Universal Model on {train_X.shape[0]} samples...")
        model = UniversalModelNP(current_model)
        adam_state = None
        epochs = 15
        t_train_start = time.time()
        for ep in range(epochs):
            l_val, l_act, l_mv, adam_state = train_epoch(
                model, train_X, train_Y_val, train_Y_act, train_Y_move,
                lr=0.003 if ep < 10 else 0.001,
                batch_size=128,
                adam_state=adam_state
            )
            if (ep + 1) % 5 == 0 or ep == 0:
                print(f"  Epoch {ep+1:2d}/{epochs}: Val MSE={l_val:.4f}, Act XEnt={l_act:.4f}, Move XEnt={l_mv:.4f}")

        t_train = time.time() - t_train_start
        print(f"Model fitting complete in {t_train:.1f}s.")

        # Step 4: Checkpoint Model
        next_model_path = out_path / f"model_gen_{gen}.bin"
        model.save(str(next_model_path))
        print(f"Saved checkpoint to {next_model_path}")
        current_model = str(next_model_path)

        # Step 5: Verification benchmark against base
        bench_out = out_path / f"bench_gen_{gen}.lua"
        bench_cmd = [
            exec_path,
            '--spec-a', 'warlock',
            '--spec-b', 'frost_mage',
            '--workers', str(workers),
            '--rollouts', str(rollouts),
            '--algorithm', 'puct',
            '--evaluator', 'neural',
            '--model', current_model,
            '--truncation-ticks', '0',
            '--seed', '42',
            '--output', str(bench_out)
        ]
        bench_res = subprocess.run(bench_cmd, capture_output=True, text=True)
        for line in bench_res.stdout.splitlines():
            if line.startswith("Saved "):
                print(f"Benchmark: {line}")

        total_gen_time = time.time() - t_gen_start
        print(f"Generation {gen} finished in {total_gen_time:.1f}s.")

    # Save final universal model
    final_path = out_path / "model_universal_final.bin"
    model.save(str(final_path))
    print(f"\nPhase 3 complete! Final model saved to {final_path}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Phase 3: Self-Play Iteration Loop")
    parser.add_argument('--generations', type=int, default=3, help="Number of self-play iterations")
    parser.add_argument('--matches', type=int, default=12, help="Number of duels per generation")
    parser.add_argument('--rollouts', type=int, default=128, help="MCTS visits per decision")
    parser.add_argument('--workers', type=int, default=8, help="Number of CPU worker threads")
    parser.add_argument('--output-dir', type=str, default="models/universal_alpha", help="Output directory")
    args = parser.parse_args()

    run_pipeline(
        generations=args.generations,
        matches_per_gen=args.matches,
        rollouts=args.rollouts,
        workers=args.workers,
        output_dir=args.output_dir
    )
