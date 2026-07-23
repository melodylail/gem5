#!/usr/bin/env bash
set -u

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-profile_${PID}_$(date +%Y%m%d_%H%M%S)}

if [[ ! -d /proc/"$PID" ]]; then
    echo "PID $PID does not exist"
    exit 1
fi

mkdir -p "$OUT"

echo "Profiling PID=$PID for ${SECONDS}s into $OUT"

date -Is > "$OUT/start_time.txt"
ps -fp "$PID" > "$OUT/process.txt"
cat /proc/"$PID"/status > "$OUT/status.before"
cat /proc/"$PID"/smaps_rollup > "$OUT/smaps_rollup.before" 2>/dev/null || true
cat /proc/vmstat > "$OUT/vmstat.before"
cat /proc/meminfo > "$OUT/meminfo.before"

timeout "$SECONDS" vmstat -w -t 1 \
    > "$OUT/vmstat.log" 2>&1 &

if command -v mpstat >/dev/null; then
    timeout "$SECONDS" mpstat -P ALL 1 \
        > "$OUT/mpstat.log" 2>&1 &
fi

if command -v pidstat >/dev/null; then
    timeout "$SECONDS" pidstat -h -p "$PID" -u -r -d -w 1 \
        > "$OUT/pidstat.log" 2>&1 &
fi

if command -v iostat >/dev/null; then
    timeout "$SECONDS" iostat -xz 1 \
        > "$OUT/iostat.log" 2>&1 &
fi

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        for r in cpu memory io; do
            echo "--- $r ---"
            cat "/proc/pressure/$r" 2>/dev/null || true
        done
        sleep 1
    done
) > "$OUT/psi.log" &

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        ps -o pid,psr,stat,pcpu,pmem,rss,vsz,nlwp,wchan:32,etime,cmd \
            -p "$PID"
        sleep 1
    done
) > "$OUT/process_watch.log" &

wait || true

cat /proc/"$PID"/status > "$OUT/status.after" 2>/dev/null || true
cat /proc/"$PID"/smaps_rollup > "$OUT/smaps_rollup.after" 2>/dev/null || true
cat /proc/vmstat > "$OUT/vmstat.after"
cat /proc/meminfo > "$OUT/meminfo.after"
date -Is > "$OUT/end_time.txt"

echo "Done: $OUT"
