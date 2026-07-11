#!/bin/bash
# profiling/mem/tests/integration/test_sampler_caps.sh
# Integration test: mem_sample.sh sampling caps (--max-samples, --max-duration-s).
#
# Validates:
#   1. Spawn with --max-samples 3 → CSV has sampler_cap_reached, <=4 data rows
#   2. Attach mode with --max-duration-s 2 → target alive after sampler exits
#   3. Spawn mode with --max-duration-s 2 → cap marker + gem5 exit code forwarded
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SAMPLER="$PROJECT_ROOT/profiling/mem/mem_sample.sh"

source "$TOOLS_DIR/assert.sh"

echo "=== Test: sampler caps ==="

# --- Build fake_gem5 ---
echo "--- Building fake_gem5 ---"
bash "$TOOLS_DIR/build_fake_gem5.sh"
FAKE_GEM5="$TOOLS_DIR/fake_gem5"
assert_file_exists "$FAKE_GEM5" "fake_gem5 binary must exist after build"

# --- Create temp directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
echo "Temporary directory: $TMPDIR"

# =========================================================================
# Test 1: Spawn mode with --max-samples 3
#
# We kill the sampler after the cap is reached (before fake_gem5 exits) so
# that the last CSV row is the sampler_cap_reached marker (no "crashed"
# row from gem5 exit).  In spawn mode the signal handler forwards SIGTERM
# to fake_gem5, so both exit together.
# =========================================================================
echo ""
echo "=== Test 1: spawn mode with --max-samples 3 ==="

mkdir -p "$TMPDIR/test1"
echo "--- Running sampler (--max-samples 3, spawn fake_gem5 10 10) ---"
"$SAMPLER" \
    --output-dir "$TMPDIR/test1" \
    --interval-s 0.5 \
    --max-samples 3 \
    --tag "test-max-samples" \
    -- "$FAKE_GEM5" 10 10 &
SAMPLER_PID=$!

# Wait for cap to be reached (3 samples * 0.5s ≈ 1.5s, plus margin)
sleep 3

# Kill sampler — signal handler forwards to fake_gem5, both exit
set +e
kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
set -e

CSV1="$TMPDIR/test1/mem_trend.csv"
assert_file_exists "$CSV1" "Test 1: CSV must exist"
assert_file_not_empty "$CSV1" "Test 1: CSV must not be empty"

echo "--- Test 1 CSV ---"
cat "$CSV1"

# Count data rows (non-comment, non-header)
TOTAL_NC1=$(grep -c -v '^#' "$CSV1" || true)
DATA_ROWS1=$((TOTAL_NC1 - 1))
echo "Test 1 data rows: $DATA_ROWS1"

# Must have at most 4 data rows (3 samples + 1 cap marker)
if [ "$DATA_ROWS1" -gt 4 ]; then
    echo "FAIL: Test 1: expected <=4 data rows, got $DATA_ROWS1" >&2
    echo "Full CSV:" >&2
    cat "$CSV1" >&2
    exit 1
fi
echo "  ok: <=4 data rows ($DATA_ROWS1)"

# Must contain sampler_cap_reached marker
assert_contains "sampler_cap_reached" "$CSV1" "Test 1: CSV must contain sampler_cap_reached"

# Last non-comment row must be the cap marker (not "crashed" — we killed
# before gem5 exited)
LAST_LINE1=$(grep -v '^#' "$CSV1" | tail -1)
if echo "$LAST_LINE1" | grep -q "sampler_cap_reached"; then
    echo "  ok: final data row has gem5_phase=sampler_cap_reached"
else
    echo "FAIL: Test 1: final data row is not sampler_cap_reached" >&2
    echo "  Last line: $LAST_LINE1" >&2
    exit 1
fi

# =========================================================================
# Test 2: Attach mode with --max-duration-s 2
#
# Sampler enters monitor-only mode after the cap but does not exit.  We
# kill it externally; in attach mode the signal handler does NOT forward
# the signal, so the target process survives.
# =========================================================================
echo ""
echo "=== Test 2: attach mode with --max-duration-s 2 ==="

mkdir -p "$TMPDIR/test2"

echo "--- Launching fake_gem5 (10 MB/s, 15 s) ---"
"$FAKE_GEM5" 10 15 &
PID=$!
echo "fake_gem5 PID: $PID"

# Let fake_gem5 print "Beginning simulation!" and start allocating
sleep 1

echo "--- Attaching sampler (--max-duration-s 2) ---"
"$SAMPLER" \
    --output-dir "$TMPDIR/test2" \
    --interval-s 0.3 \
    --pid "$PID" \
    --max-duration-s 2 &
SAMPLER_PID=$!
echo "Sampler PID: $SAMPLER_PID"

# Wait for max-duration to be reached (2s + margin)
sleep 4

# Kill the sampler — attach mode signal handler does not forward to target
echo "--- Killing sampler ---"
set +e
kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
set -e

CSV2="$TMPDIR/test2/mem_trend.csv"
assert_file_exists "$CSV2" "Test 2: CSV must exist"
assert_file_not_empty "$CSV2" "Test 2: CSV must not be empty"

echo "--- Test 2 CSV header ---"
head -10 "$CSV2"

# Must contain sampler_cap_reached marker
assert_contains "sampler_cap_reached" "$CSV2" "Test 2: CSV must contain sampler_cap_reached"

# CSV header must show attached mode
assert_contains "attached: true" "$CSV2" "Test 2: CSV header must contain attached: true"

# Verify fake_gem5 is still running (attach mode leaves target alive)
echo "--- Checking fake_gem5 still running ---"
if kill -0 "$PID" 2>/dev/null; then
    echo "  ok: fake_gem5 still running after sampler exited"
else
    echo "FAIL: Test 2: fake_gem5 exited (attach mode should leave target alive)" >&2
    exit 1
fi

# =========================================================================
# Test 3: Spawn mode with --max-duration-s 2
#
# Sampler caps after 2 s, monitors until gem5 exits (~3 s), then exits
# with gem5's exit code.
# =========================================================================
echo ""
echo "=== Test 3: spawn mode with --max-duration-s 2 ==="

mkdir -p "$TMPDIR/test3"
echo "--- Running sampler (--max-duration-s 2, spawn fake_gem5 10 3) ---"
set +e
"$SAMPLER" \
    --output-dir "$TMPDIR/test3" \
    --interval-s 0.3 \
    --max-duration-s 2 \
    --tag "test-max-duration" \
    -- "$FAKE_GEM5" 10 3
EXIT3=$?
set -e

echo "Sampler exit code: $EXIT3"

CSV3="$TMPDIR/test3/mem_trend.csv"
assert_file_exists "$CSV3" "Test 3: CSV must exist"
assert_file_not_empty "$CSV3" "Test 3: CSV must not be empty"

echo "--- Test 3 CSV ---"
cat "$CSV3"

# Must contain sampler_cap_reached marker
assert_contains "sampler_cap_reached" "$CSV3" "Test 3: CSV must contain sampler_cap_reached"

# Verify exit code matches fake_gem5 (0 for normal exit)
assert_exit_code 0 "$EXIT3" "Test 3: sampler must exit with fake_gem5 exit code (0)"

# Verify data rows are bounded (2s / 0.3s ≈ 7 samples + 1 cap + 1 crashed)
TOTAL_NC3=$(grep -c -v '^#' "$CSV3" || true)
DATA_ROWS3=$((TOTAL_NC3 - 1))
echo "Test 3 data rows: $DATA_ROWS3"
MAX_EXPECTED=10
if [ "$DATA_ROWS3" -gt "$MAX_EXPECTED" ]; then
    echo "FAIL: Test 3: expected <=$MAX_EXPECTED data rows, got $DATA_ROWS3" >&2
    echo "Full CSV:" >&2
    cat "$CSV3" >&2
    exit 1
fi
echo "  ok: <=$MAX_EXPECTED data rows ($DATA_ROWS3)"

# --- Cleanup test 2 ---
echo "--- Cleanup ---"
kill "$PID" 2>/dev/null || true

echo ""
echo "=== All sampler caps integration tests passed ==="
