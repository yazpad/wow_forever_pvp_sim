#!/usr/bin/env bash
# run_fight.sh - Convenience Spec vs Spec MCTS Matchup Runner for PVP_SIM
# Usage: ./run_fight.sh [SPEC_A] [SPEC_B] [PRESET/OPTIONS]
# Examples:
#   ./run_fight.sh warlock frost_mage
#   ./run_fight.sh warlock frost_mage --fast
#   ./run_fight.sh warlock frost_mage --deep
#   ./run_fight.sh warlock frost_mage --no-gui

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Defaults
SPEC_A="warlock"
SPEC_B="frost_mage"
PRESET="standard"
NO_GUI=false
EXTRA_ARGS=()
ROLLOUTS_OVERRIDE=""
WORKERS_OVERRIDE=""
EVALUATOR_OVERRIDE=""

ROLLOUTS=4096
WORKERS=8
EVALUATOR="rollout"
ALGORITHM="puct"
BOUNDARY="event"
OUTPUT="matches/latest.lua"

# Parse positional arguments and flags
POS_INDEX=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast)
            PRESET="fast"
            shift
            ;;
        --standard)
            PRESET="standard"
            shift
            ;;
        --deep)
            PRESET="deep"
            shift
            ;;
        --no-gui)
            NO_GUI=true
            shift
            ;;
        --rollouts)
            ROLLOUTS_OVERRIDE="$2"
            shift 2
            ;;
        --workers)
            WORKERS_OVERRIDE="$2"
            shift 2
            ;;
        --evaluator)
            EVALUATOR_OVERRIDE="$2"
            shift 2
            ;;
        --algorithm)
            ALGORITHM="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: ./run_fight.sh [spec_a] [spec_b] [preset/flags]"
            echo ""
            echo "Specs: warlock, frost_mage"
            echo "Presets:"
            echo "  --fast      1,024 rollouts, 4 workers, terminal rollout"
            echo "  --standard  4,096 rollouts, 8 workers, terminal rollout [DEFAULT]"
            echo "  --deep      16,384 rollouts, 16 workers, terminal rollout"
            echo ""
            echo "Flags:"
            echo "  --no-gui    Generate match replay without launching LÖVE visualizer"
            echo "  --output    Path to output file (default: matches/latest.lua)"
            echo ""
            echo "Examples:"
            echo "  ./run_fight.sh warlock frost_mage"
            echo "  ./run_fight.sh frost_mage warlock --fast"
            echo "  ./run_fight.sh warlock frost_mage --deep"
            exit 0
            ;;
        *)
            if [[ $POS_INDEX -eq 0 && "$1" != --* ]]; then
                SPEC_A="$1"
                POS_INDEX=1
            elif [[ $POS_INDEX -eq 1 && "$1" != --* ]]; then
                SPEC_B="$1"
                POS_INDEX=2
            else
                EXTRA_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Apply Presets
case "$PRESET" in
    fast)
        ROLLOUTS=1024
        WORKERS=4
        EVALUATOR="rollout"
        ;;
    standard)
        ROLLOUTS=4096
        WORKERS=8
        EVALUATOR="rollout"
        ;;
    deep)
        ROLLOUTS=16384
        WORKERS=16
        EVALUATOR="rollout"
        ;;
esac

# Explicit flags take precedence over presets, regardless of argument order.
ROLLOUTS="${ROLLOUTS_OVERRIDE:-$ROLLOUTS}"
WORKERS="${WORKERS_OVERRIDE:-$WORKERS}"
EVALUATOR="${EVALUATOR_OVERRIDE:-$EVALUATOR}"

# Ensure binaries are built
if [[ ! -f "zig-out/bin/mcts_fight" ]]; then
    echo "==> Building pvp_sim and mcts_fight in ReleaseFast mode..."
    zig build -Doptimize=ReleaseFast
fi

mkdir -p matches

echo "=========================================================="
echo " PVP_SIM Spec vs Spec MCTS Runner"
echo " Matchup:     ${SPEC_A} vs ${SPEC_B} (MCTS PUCT on both ends)"
echo " Preset:      ${PRESET} (${ROLLOUTS} rollouts, ${WORKERS} workers, ${EVALUATOR})"
echo " Output:      ${OUTPUT}"
echo "=========================================================="

CMD=("./zig-out/bin/mcts_fight"
    "--spec-a" "$SPEC_A"
    "--spec-b" "$SPEC_B"
    "--rollouts" "$ROLLOUTS"
    "--workers" "$WORKERS"
    "--evaluator" "$EVALUATOR"
    "--algorithm" "$ALGORITHM"
    "--boundary" "$BOUNDARY"
    "--output" "$OUTPUT")

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    CMD+=("${EXTRA_ARGS[@]}")
fi

"${CMD[@]}"

echo ""
echo "==> Match generation complete: ${OUTPUT}"

if [[ "$NO_GUI" == false ]]; then
    if command -v love &>/dev/null; then
        echo "==> Launching LÖVE visualizer with replay..."
        love visualizer "$OUTPUT"
    else
        echo "==> love command not found in PATH; skipping visualizer."
    fi
fi
