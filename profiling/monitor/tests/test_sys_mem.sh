#!/bin/bash
# profiling/monitor/tests/test_sys_mem.sh
# RED test: validates sys_mem.csv schema from mem_daemon.sh
# Expected to FAIL until mem_daemon.sh implements --sys-only --max-samples

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"
ASSERT_SH="$MONITOR_DIR/../mem/tests/tools/assert.sh"

# shellcheck source=../mem/tests/tools/assert.sh
source "$ASSERT_SH"

OUTDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR"' EXIT

echo "=== RED: sys_mem test ==="

# Call the daemon (does not exist yet — expected to fail)
set +e
"$MONITOR_DIR/mem_daemon.sh" \
    --sys-only \
    --max-samples 1 \
    --output-dir "$OUTDIR" \
    > "$OUTDIR/daemon.log" 2>&1
EXIT_CODE=$?
set -e

echo "daemon exit: $EXIT_CODE"
echo "--- daemon log ---"
cat "$OUTDIR/daemon.log"
echo "---"

# Find the sys_mem.csv (under hourly subdirectory)
SYS_CSV=$(find "$OUTDIR" -name "sys_mem.csv" -type f 2>/dev/null | head -1)

if [ -z "$SYS_CSV" ]; then
    echo "FAIL: sys_mem.csv not found" >&2
    exit 1
fi

echo "Found: $SYS_CSV"

# Verify header columns
HEADER=$(head -1 "$SYS_CSV")
echo "Header: $HEADER"

for col in ts_ms wall_clock memtotal_kb memfree_kb memavailable_kb \
    cached_kb buffers_kb anonpages_kb dirty_kb swaptotal_kb swapfree_kb \
    pgscan_kswapd pgsteal_kswapd pgscan_direct pgsteal_direct \
    compact_stall allocstall_normal \
    psi_mem_some_avg10 psi_mem_full_avg10 psi_io_some_avg10; do
    if ! echo "$HEADER" | grep -q "$col"; then
        echo "FAIL: missing column '$col' in header" >&2
        exit 1
    fi
done
echo "  ok: all header columns present"

# Count data rows (exclude lines starting with #)
DATA_ROWS=$(grep -c '^[0-9]' "$SYS_CSV" 2>/dev/null || echo 0)
echo "Data rows: $DATA_ROWS"

if [ "$DATA_ROWS" -ne 1 ]; then
    echo "FAIL: expected 1 data row, got $DATA_ROWS" >&2
    exit 1
fi
echo "  ok: exactly 1 data row"

# Validate ts_ms is a positive integer and wall_clock is ISO-8601
LINE1=$(grep '^[0-9]' "$SYS_CSV" | head -1)
TS_MS=$(echo "$LINE1" | cut -d, -f1)
WALL=$(echo "$LINE1" | cut -d, -f2)
MEMTOTAL=$(echo "$LINE1" | cut -d, -f3)

if [ "$TS_MS" -le 0 ] 2>/dev/null; then
    echo "FAIL: ts_ms should be positive, got '$TS_MS'" >&2
    exit 1
fi
echo "  ok: ts_ms = $TS_MS (positive)"

if ! echo "$WALL" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
    echo "FAIL: wall_clock not ISO-8601: $WALL" >&2
    exit 1
fi
echo "  ok: wall_clock = $WALL (ISO-8601)"

if [ "$MEMTOTAL" -le 0 ] 2>/dev/null; then
    echo "FAIL: memtotal_kb should be positive, got '$MEMTOTAL'" >&2
    exit 1
fi
echo "  ok: memtotal_kb = $MEMTOTAL (positive)"

echo "PASS: test_sys_mem"
