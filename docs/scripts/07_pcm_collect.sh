#!/usr/bin/env bash
set -eu

MODE=${1:?Usage: $0 MODE [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-pcm_${MODE}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

case "$MODE" in
    basic)
        TOOL=pcm
        ;;
    memory)
        TOOL=pcm-memory
        ;;
    numa)
        TOOL=pcm-numa
        ;;
    power)
        TOOL=pcm-power
        ;;
    *)
        echo "MODE must be: basic, memory, numa, power"
        exit 1
        ;;
esac

if ! command -v "$TOOL" >/dev/null; then
    echo "$TOOL is not installed"
    exit 1
fi

echo "Running $TOOL for ${SECONDS}s"

sudo timeout "$SECONDS" "$TOOL" 1 \
    > "$OUT/${TOOL}.log" 2>&1 || true

echo "Saved to $OUT/${TOOL}.log"
