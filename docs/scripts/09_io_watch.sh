#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-io_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

timeout "$SECONDS" iostat -xz 1 \
    > "$OUT/iostat.log" 2>&1 &

timeout "$SECONDS" pidstat -h -p "$PID" -d 1 \
    > "$OUT/pidstat_io.log" 2>&1 &

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        cat /proc/pressure/io 2>/dev/null || true

        ps -o pid,stat,psr,pcpu,wchan:40,etime,cmd \
            -p "$PID"

        sleep 1
    done
) > "$OUT/io_psi_process.log" &

wait || true

echo "Saved to $OUT"
