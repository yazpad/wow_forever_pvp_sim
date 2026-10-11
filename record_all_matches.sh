#!/usr/bin/env bash
set -e

echo "=========================================================="
echo " ⚔️  RECORDING ALL SPEC VS SPEC & BOT MATCHUP DUELS"
echo "=========================================================="

mkdir -p models matches

# 1. Run round-robin matrix across all trained models and record 100Hz match trajectories
echo "Simulating SIMD round-robin matrix and recording fight trajectories into matches/..."
./zig-out/bin/pvp_sim \
  --eval-matrix models/ \
  --matrix-duels 32 \
  --matrix-out spec_matrix.lua \
  --record-all-matches matches/

echo ""
echo "✅ All spec matchups recorded! Generated matches:"
ls -lh matches/*.lua | tail -n 10
echo "Total stored fight trajectories: $(ls -1 matches/*.lua | wc -l)"
echo ""
echo "To open the unified Love2D monitoring dashboard with tabs:"
echo "  love visualizer"
