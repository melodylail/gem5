#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-perf_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

if [[ ! -d /proc/"$PID" ]]; then
    echo "PID $PID does not exist"
    exit 1
fi

echo "Available related events:" > "$OUT/available_events.txt"

perf list 2>/dev/null |
    grep -Ei \
    'topdown|frontend|front.end|icache|iTLB|LLC|branch|cache.miss|stalled' \
    >> "$OUT/available_events.txt" || true

COMMON_EVENTS="
task-clock,
cycles,
instructions,
branches,
branch-misses,
cache-references,
cache-misses,
page-faults,
major-faults,
context-switches,
cpu-migrations
"

COMMON_EVENTS=$(echo "$COMMON_EVENTS" | tr -d '[:space:]')

perf stat \
    -p "$PID" \
    -I 1000 \
    -x, \
    -e "$COMMON_EVENTS" \
    -o "$OUT/perf_common.csv" \
    -- sleep "$SECONDS"

# 以下事件并非所有CPU都支持，因此单独尝试。
OPTIONAL_EVENTS="
iTLB-loads,
iTLB-load-misses,
dTLB-loads,
dTLB-load-misses,
L1-icache-load-misses,
LLC-loads,
LLC-load-misses
"

OPTIONAL_EVENTS=$(echo "$OPTIONAL_EVENTS" | tr -d '[:space:]')

perf stat \
    -p "$PID" \
    -I 1000 \
    -x, \
    -e "$OPTIONAL_EVENTS" \
    -o "$OUT/perf_optional.csv" \
    -- sleep "$SECONDS" 2>"$OUT/perf_optional.error" || true

echo "Saved to $OUT"
