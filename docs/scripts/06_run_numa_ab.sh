#!/usr/bin/env bash
set -eu

CPU_LIST=${1:?Usage: $0 CPU_LIST NODE OUTDIR -- command ...}
NODE=${2:?}
OUT=${3:?}
shift 3

if [[ "${1:-}" == "--" ]]; then
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "Missing command"
    exit 1
fi

mkdir -p "$OUT/local" "$OUT/interleave"

echo "===== LOCAL NODE TEST ====="

(
    cd "$OUT/local"
    /usr/bin/time -v \
        numactl \
        --physcpubind="$CPU_LIST" \
        --membind="$NODE" \
        "$@"
) > "$OUT/local/stdout.log" 2> "$OUT/local/time.log"

echo "===== INTERLEAVE TEST ====="

(
    cd "$OUT/interleave"
    /usr/bin/time -v \
        numactl \
        --physcpubind="$CPU_LIST" \
        --interleave=all \
        "$@"
) > "$OUT/interleave/stdout.log" 2> "$OUT/interleave/time.log"

grep -H \
    'Elapsed (wall clock) time\|Percent of CPU this job got\|Maximum resident' \
    "$OUT"/*/*.log || true
