#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [INTERVAL] [OUTDIR]}
SECONDS=${2:-120}
INTERVAL=${3:-5}
OUT=${4:-numa_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

numactl --hardware > "$OUT/hardware.txt"
numastat -m > "$OUT/system_memory.before"
numastat > "$OUT/system_numa.before"

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        CPU=$(ps -o psr= -p "$PID" | tr -d ' ' || true)
        echo "Current CPU: $CPU"

        if [[ -n "$CPU" ]]; then
            NODE_LINK=$(
                find "/sys/devices/system/cpu/cpu${CPU}" \
                    -maxdepth 1 -type l -name 'node*' \
                    2>/dev/null |
                head -1
            )

            if [[ -n "$NODE_LINK" ]]; then
                echo "Current NUMA node: $(basename "$NODE_LINK")"
            fi
        fi

        echo "--- process CPU affinity ---"
        taskset -pc "$PID" || true

        echo "--- process NUMA memory ---"
        numastat -p "$PID" || true

        echo "--- per-node free memory ---"
        numastat -m |
            grep -E 'Node|MemFree|MemUsed|Active|Inactive|FilePages|AnonPages' ||
            true

        sleep "$INTERVAL"
    done
) > "$OUT/timeline.log"

numastat -m > "$OUT/system_memory.after"
numastat > "$OUT/system_numa.after"
cp /proc/"$PID"/numa_maps "$OUT/numa_maps.final" 2>/dev/null || true

echo "Saved to $OUT"
