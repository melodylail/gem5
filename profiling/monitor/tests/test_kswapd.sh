#!/bin/bash
# profiling/monitor/tests/test_kswapd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"

OUTDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR"' EXIT

echo "=== test_kswapd ==="

"$MONITOR_DIR/mem_daemon.sh" \
    --max-samples 1 \
    --output-dir "$OUTDIR" \
    > "$OUTDIR/daemon.log" 2>&1

KSWAPD_CSV=$(find "$OUTDIR" -name "kswapd.csv" -type f 2>/dev/null | head -1)

if [ -z "$KSWAPD_CSV" ]; then
    echo "FAIL: kswapd.csv not found" >&2
    exit 1
fi
echo "Found: $KSWAPD_CSV"

# Verify header columns
HEADER=$(head -1 "$KSWAPD_CSV")
for col in ts_ms wall_clock pid comm state cpu_percent rss_kb wchan stack; do
    echo "$HEADER" | grep -q "$col" || { echo "FAIL: missing '$col'" >&2; exit 1; }
done
echo "  ok: all header columns present"

# At least 1 row
ROWS=$(grep -c '^[0-9]' "$KSWAPD_CSV" 2>/dev/null || echo 0)
[ "$ROWS" -ge 1 ] || { echo "FAIL: no data rows" >&2; exit 1; }
echo "  ok: $ROWS data row(s)"

# Check first data row columns
LINE=$(grep '^[0-9]' "$KSWAPD_CSV" | head -1)
NCOLS=$(echo "$LINE" | tr ',' '\n' | wc -l)
[ "$NCOLS" -eq 9 ] || { echo "FAIL: expected 9 columns, got $NCOLS" >&2; exit 1; }
echo "  ok: 9 columns per row"

echo "PASS: test_kswapd"
