#!/bin/bash
# profiling/monitor/tests/test_proc_mem_standard.sh
# Test: proc_mem standard mode — validates PSS/USS/VmSwap/cmdline are present

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$(dirname "$SCRIPT_DIR")"
ASSERT_SH="$MONITOR_DIR/../mem/tests/tools/assert.sh"
FAKE_GEM5="$MONITOR_DIR/../mem/tests/tools/fake_gem5"

source "$ASSERT_SH"

OUTDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "=== RED: proc_mem standard mode test ==="

"$FAKE_GEM5" 5 60 &
PID1=$!

sleep 2

set +e
"$MONITOR_DIR/mem_daemon.sh" \
    --proc-only \
    --mode standard \
    --max-samples 1 \
    --output-dir "$OUTDIR" \
    > "$OUTDIR/daemon.log" 2>&1
EXIT_CODE=$?
set -e

echo "daemon exit: $EXIT_CODE"

PROC_CSV=$(find "$OUTDIR" -name "proc_mem.csv" -type f 2>/dev/null | head -1)
assert_file_exists "$PROC_CSV" "proc_mem.csv should exist"

# Find fake_gem5 row
LINE=$(grep ",${PID1}," "$PROC_CSV" | head -1)
echo "fake_gem5 row: $LINE"

PSS=$(echo "$LINE" | cut -d, -f9)
USS=$(echo "$LINE" | cut -d, -f10)
SWAP=$(echo "$LINE" | cut -d, -f11)
CMDLINE=$(echo "$LINE" | cut -d, -f13)

# Standard mode: PSS > 0 (fake_gem5 allocates real pages)
if [ "$PSS" -le 0 ] 2>/dev/null; then
    echo "FAIL: pss_kb should be positive in standard mode, got $PSS" >&2
    exit 1
fi
echo "  ok: pss_kb=$PSS (positive)"

if [ "$USS" -le 0 ] 2>/dev/null; then
    echo "FAIL: uss_kb should be positive in standard mode, got $USS" >&2
    exit 1
fi
echo "  ok: uss_kb=$USS (positive)"

# Swap should be >= 0
if [ "$SWAP" -lt 0 ] 2>/dev/null; then
    echo "FAIL: swap_kb should be >= 0, got $SWAP" >&2
    exit 1
fi
echo "  ok: swap_kb=$SWAP"

# cmdline should not be empty for fake_gem5
if [ -z "$CMDLINE" ] || [ "$CMDLINE" = '""' ]; then
    echo "FAIL: cmdline should not be empty in standard mode" >&2
    exit 1
fi
echo "  ok: cmdline present"

echo "PASS: test_proc_mem_standard"
