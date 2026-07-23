#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-memory_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

COUNTERS='
pswpin
pswpout
pgmajfault
pgfault
pgscan_direct
pgscan_kswapd
pgsteal_direct
pgsteal_kswapd
allocstall_normal
allocstall_movable
compact_stall
compact_fail
compact_success
thp_fault_alloc
thp_fault_fallback
thp_collapse_alloc
thp_collapse_alloc_failed
'

snapshot_vmstat()
{
    local output=$1

    for c in $COUNTERS; do
        awk -v key="$c" '
            $1 == key {
                print $1, $2
                found=1
            }
            END {
                if (!found)
                    print key, 0
            }
        ' /proc/vmstat
    done > "$output"
}

snapshot_vmstat "$OUT/vmstat.before"

cat /proc/pressure/memory > "$OUT/memory_psi.before"
cat /proc/pressure/io > "$OUT/io_psi.before"

grep -E \
'VmRSS|VmHWM|VmSwap|RssAnon|RssFile|voluntary_ctxt|nonvoluntary_ctxt' \
/proc/"$PID"/status > "$OUT/process.before"

timeout "$SECONDS" vmstat -w -t 1 \
    > "$OUT/vmstat.timeline" 2>&1 &

timeout "$SECONDS" pidstat -h -p "$PID" -r -w 1 \
    > "$OUT/pidstat.timeline" 2>&1 &

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        cat /proc/pressure/memory
        sleep 1
    done
) > "$OUT/memory_psi.timeline" &

wait || true

snapshot_vmstat "$OUT/vmstat.after"

cat /proc/pressure/memory > "$OUT/memory_psi.after"
cat /proc/pressure/io > "$OUT/io_psi.after"

grep -E \
'VmRSS|VmHWM|VmSwap|RssAnon|RssFile|voluntary_ctxt|nonvoluntary_ctxt' \
/proc/"$PID"/status > "$OUT/process.after" || true

join \
    <(sort "$OUT/vmstat.before") \
    <(sort "$OUT/vmstat.after") |
awk '{
    printf "%-30s before=%-15s after=%-15s delta=%s\n",
           $1, $2, $3, $3-$2
}' > "$OUT/vmstat.delta"

cat "$OUT/vmstat.delta"
