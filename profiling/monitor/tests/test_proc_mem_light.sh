#!/bin/bash
# profiling/monitor/tests/test_proc_mem_light.sh
# RED test: validates proc_mem.csv from mem_daemon.sh (light mode)
# Expected to FAIL until mem_daemon.sh implements --proc-only --mode light

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"
ASSERT_SH="$MONITOR_DIR/../mem/tests/tools/assert.sh"
FAKE_GEM5="$MONITOR_DIR/../mem/tests/tools/fake_gem5"

source "$ASSERT_SH"

OUTDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "=== RED: proc_mem light mode test ==="

# Launch 3 fake_gem5 instances in background
"$FAKE_GEM5" 1 60 &
PID1=$!
"$FAKE_GEM5" 1 60 &
PID2=$!
"$FAKE_GEM5" 1 60 &
PID3=$!

sleep 2  # let them start and allocate memory

echo "fake PIDs: $PID1 $PID2 $PID3"

# Run daemon in --proc-only light mode
set +e
"$MONITOR_DIR/mem_daemon.sh" \
    --proc-only \
    --mode light \
    --max-samples 1 \
    --output-dir "$OUTDIR" \
    > "$OUTDIR/daemon.log" 2>&1
EXIT_CODE=$?
set -e

echo "daemon exit: $EXIT_CODE"

# Find proc_mem.csv
PROC_CSV=$(find "$OUTDIR" -name "proc_mem.csv" -type f 2>/dev/null | head -1)
if [ -z "$PROC_CSV" ]; then
    echo "FAIL: proc_mem.csv not found" >&2
    exit 1
fi
echo "Found: $PROC_CSV"

# Verify header
HEADER=$(head -1 "$PROC_CSV")
echo "Header: $HEADER"

for col in ts_ms wall_clock pid comm state threads rss_kb vsz_kb \
    cpu_percent mode; do
    if ! echo "$HEADER" | grep -q "$col"; then
        echo "FAIL: missing column '$col'" >&2
        exit 1
    fi
done
echo "  ok: required columns present"

# Verify light-mode columns are present
for col in pss_kb uss_kb swap_kb cmdline; do
    if ! echo "$HEADER" | grep -q "$col"; then
        echo "FAIL: missing light-mode column '$col'" >&2
        exit 1
    fi
done
echo "  ok: light-mode columns present in header"

# Count rows (exclude # comment lines)
DATA_ROWS=$(grep -c '^[0-9]' "$PROC_CSV" 2>/dev/null || echo 0)
echo "Data rows: $DATA_ROWS"

if [ "$DATA_ROWS" -lt 3 ]; then
    echo "FAIL: expected at least 3 data rows, got $DATA_ROWS" >&2
    exit 1
fi
echo "  ok: at least 3 data rows (one per fake_gem5)"

# Verify each fake_gem5 PID appears
for pid in "$PID1" "$PID2" "$PID3"; do
    if ! grep -q ",${pid}," "$PROC_CSV"; then
        echo "FAIL: PID $pid not found in proc_mem.csv" >&2
        exit 1
    fi
done
echo "  ok: all 3 fake_gem5 PIDs found"

# Verify all rows have mode=light
LIGHT_ROWS=$(grep -c ',light$' "$PROC_CSV" 2>/dev/null || echo 0)
if [ "$LIGHT_ROWS" -lt 3 ]; then
    echo "FAIL: expected at least 3 rows with mode=light, got $LIGHT_ROWS" >&2
    exit 1
fi
echo "  ok: mode=light on all rows"

# Verify light-mode sentinel: pss_kb=-1, uss_kb=-1
for pid in "$PID1" "$PID2" "$PID3"; do
    LINE=$(grep ",${pid}," "$PROC_CSV" | head -1)
    PSS=$(echo "$LINE" | cut -d, -f10)
    USS=$(echo "$LINE" | cut -d, -f11)
    if [ "$PSS" != "-1" ]; then
        echo "FAIL: light mode should have pss_kb=-1, got $PSS" >&2
        exit 1
    fi
    if [ "$USS" != "-1" ]; then
        echo "FAIL: light mode should have uss_kb=-1, got $USS" >&2
        exit 1
    fi
done
echo "  ok: pss_kb=-1, uss_kb=-1 (light mode) for fake_gem5"

echo "PASS: test_proc_mem_light"
