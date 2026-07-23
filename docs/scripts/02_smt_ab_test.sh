#!/usr/bin/env bash
set -eu

CPU0=${1:?Usage: $0 CPU0 CPU_SIBLING NUMA_NODE OUTDIR}
CPU1=${2:?}
NODE=${3:?}
OUT=${4:?}

: "${CANARY_CMD:?Set CANARY_CMD}"
: "${INTERFERER_CMD:?Set INTERFERER_CMD}"

mkdir -p "$OUT/solo" "$OUT/smt"

echo "===== SOLO TEST ====="

(
    cd "$OUT/solo"
    /usr/bin/time -v \
        numactl --physcpubind="$CPU0" --membind="$NODE" \
        bash -lc "$CANARY_CMD"
) > "$OUT/solo/stdout.log" 2> "$OUT/solo/time.log"

echo "===== SMT CONTENTION TEST ====="

(
    cd "$OUT/smt"

    numactl --physcpubind="$CPU1" --membind="$NODE" \
        bash -lc "$INTERFERER_CMD" \
        > interferer.stdout.log \
        2> interferer.stderr.log &

    INTERFERER_PID=$!
    sleep 5

    /usr/bin/time -v \
        numactl --physcpubind="$CPU0" --membind="$NODE" \
        bash -lc "$CANARY_CMD" \
        > canary.stdout.log \
        2> canary.time.log

    kill "$INTERFERER_PID" 2>/dev/null || true
    wait "$INTERFERER_PID" 2>/dev/null || true
)

echo "Results:"
grep -H \
    'Elapsed (wall clock) time\|Percent of CPU this job got\|Maximum resident' \
    "$OUT"/*/*.log || true
