#!/usr/bin/env bash
set -u

OUT=${1:-lsf_audit_$(date +%Y%m%d_%H%M%S)}
shift || true

mkdir -p "$OUT"

echo "===== LSF HOST INFO =====" > "$OUT/summary.txt"
hostname >> "$OUT/summary.txt"

if command -v bhosts >/dev/null; then
    bhosts -l "$(hostname)" > "$OUT/bhosts.log" 2>&1 || true
fi

if command -v lsload >/dev/null; then
    lsload -l "$(hostname)" > "$OUT/lsload.log" 2>&1 || true
fi

if [[ $# -eq 0 ]]; then
    echo "No job IDs supplied."
    echo "Usage: $0 OUTDIR JOBID1 JOBID2 ..."
    exit 0
fi

for JOBID in "$@"; do
    bjobs -l "$JOBID" \
        > "$OUT/bjobs_${JOBID}.log" 2>&1 || true

    bacct -l "$JOBID" \
        > "$OUT/bacct_${JOBID}.log" 2>&1 || true
done

grep -RniE \
'MAX MEM|AVG MEM|MEMLIMIT|Requested Resources|rusage|CPU time|RUNLIMIT|Execution' \
"$OUT" > "$OUT/extracted.txt" || true

cat "$OUT/extracted.txt"
