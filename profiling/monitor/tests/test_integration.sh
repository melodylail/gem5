#!/bin/bash
# profiling/monitor/tests/test_integration.sh
# Integration test: full daemon runs (bash + python) with fake_gem5 processes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"
FAKE_GEM5="$MONITOR_DIR/../mem/tests/tools/fake_gem5"
ASSERT_SH="$MONITOR_DIR/../mem/tests/tools/assert.sh"
source "$ASSERT_SH"

OUTDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "=== Integration Test: Bash + Python daemons ==="

# --- Launch 10 fake_gem5 processes ---
FAKE_PIDS=()
for i in $(seq 1 10); do
    "$FAKE_GEM5" 2 120 &
    FAKE_PIDS+=($!)
done
sleep 3
echo "Launched ${#FAKE_PIDS[@]} fake_gem5 instances"

# --- Run Bash daemon ---
BASH_OUT="$OUTDIR/bash"
echo "Running bash daemon..."
"$MONITOR_DIR/mem_daemon.sh" \
    --interval 2 --duration 20 --mode standard \
    --output-dir "$BASH_OUT" > "$OUTDIR/bash.log" 2>&1 &
BASH_DAEMON_PID=$!

# Wait for bash daemon
wait $BASH_DAEMON_PID 2>/dev/null || true

# --- Verify bash output ---
echo "Verifying bash output..."
assert_file_exists "$(find "$BASH_OUT" -name sys_mem.csv -type f | head -1)" "bash sys_mem.csv"
assert_file_exists "$(find "$BASH_OUT" -name proc_mem.csv -type f | head -1)" "bash proc_mem.csv"
assert_file_exists "$(find "$BASH_OUT" -name kswapd.csv -type f | head -1)" "bash kswapd.csv"

# --- Run Python daemon ---
PY_OUT="$OUTDIR/python"
echo "Running python daemon..."
python3 "$MONITOR_DIR/mem_daemon.py" \
    --interval 2 --duration 20 --mode standard \
    --output-dir "$PY_OUT" > "$OUTDIR/python.log" 2>&1 &
PY_DAEMON_PID=$!

wait $PY_DAEMON_PID 2>/dev/null || true

# --- Verify python output ---
echo "Verifying python output..."
assert_file_exists "$(find "$PY_OUT" -name sys_mem.csv -type f | head -1)" "python sys_mem.csv"
assert_file_exists "$(find "$PY_OUT" -name proc_mem.csv -type f | head -1)" "python proc_mem.csv"
assert_file_exists "$(find "$PY_OUT" -name kswapd.csv -type f | head -1)" "python kswapd.csv"

# --- Cross-check: both daemons found fake_gem5 pids ---
for pid in "${FAKE_PIDS[@]}"; do
    BASH_FOUND=$(grep -c ",${pid}," "$(find "$BASH_OUT" -name proc_mem.csv | head -1)" 2>/dev/null || echo 0)
    PY_FOUND=$(grep -c ",${pid}," "$(find "$PY_OUT" -name proc_mem.csv | head -1)" 2>/dev/null || echo 0)
    echo "  PID $pid: bash=$BASH_FOUND rows, python=$PY_FOUND rows"
    [ "$BASH_FOUND" -ge 2 ] || { echo "WARN: bash only found $BASH_FOUND samples for PID $pid"; }
    [ "$PY_FOUND" -ge 2 ] || { echo "WARN: python only found $PY_FOUND samples for PID $pid"; }
done

# --- Cross-check: sys_mem columns match ---
BASH_HEADER=$(head -1 "$(find "$BASH_OUT" -name sys_mem.csv | head -1)")
PY_HEADER=$(head -1 "$(find "$PY_OUT" -name sys_mem.csv | head -1)")
if [ "$BASH_HEADER" != "$PY_HEADER" ]; then
    echo "FAIL: sys_mem.csv headers differ!" >&2
    echo "bash: $BASH_HEADER"
    echo "py:   $PY_HEADER"
    exit 1
fi
echo "  ok: sys_mem.csv headers match"

# Cleanup
kill "${FAKE_PIDS[@]}" 2>/dev/null || true
echo "=== PASS: integration test ==="
