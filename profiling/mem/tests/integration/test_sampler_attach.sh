#!/bin/bash
# profiling/mem/tests/integration/test_sampler_attach.sh
# Integration test: mem_sample.sh attach mode with fake_gem5.
#
# Validates:
#   1. CSV is produced with "attached: true" in header
#   2. fake_gem5 is left running (attach mode does not kill target)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SAMPLER="$PROJECT_ROOT/profiling/mem/mem_sample.sh"

source "$TOOLS_DIR/assert.sh"

echo "=== Test: sampler attach mode ==="

# --- Build fake_gem5 ---
echo "--- Building fake_gem5 ---"
bash "$TOOLS_DIR/build_fake_gem5.sh"
FAKE_GEM5="$TOOLS_DIR/fake_gem5"
assert_file_exists "$FAKE_GEM5" "fake_gem5 binary must exist after build"

# --- Create temp directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
echo "Temporary directory: $TMPDIR"

# --- Launch fake_gem5 in background ---
echo "--- Launching fake_gem5 (5 MB/s, 10 s) ---"
"$FAKE_GEM5" 5 10 &
PID=$!
echo "fake_gem5 PID: $PID"

# Let fake_gem5 print "Beginning simulation!" and start allocating
sleep 1

# --- Run sampler in attach mode ---
echo "--- Running sampler (attach mode, interval=0.3s, max-duration=3s) ---"

# Run in background so we can verify fake_gem5 is still alive after sampling.
# The sampler enters monitor-only mode after max-duration-s, remaining alive
# until the target PID exits.
"$SAMPLER" \
    --output-dir "$TMPDIR" \
    --interval-s 0.3 \
    --pid "$PID" \
    --max-duration-s 3 &
SAMPLER_PID=$!
echo "Sampler PID: $SAMPLER_PID"

# Wait for sampling phase to complete (max-duration 3s + margin)
sleep 4

# --- Assertions ---
CSV="$TMPDIR/mem_trend.csv"
LOG="$TMPDIR/mem_sample.log"

echo "--- CSV header ---"
head -10 "$CSV"

assert_file_exists "$CSV" "CSV file must exist"
assert_file_not_empty "$CSV" "CSV must not be empty"

# Header must contain attached: true
assert_contains "attached: true" "$CSV" "CSV header must contain attached: true"

# Log must exist
assert_file_exists "$LOG" "Sampler log must exist"
assert_file_not_empty "$LOG" "Sampler log must not be empty"

# --- Verify fake_gem5 is still running (attach mode leaves target alive) ---
echo "--- Checking fake_gem5 still running ---"
if kill -0 "$PID" 2>/dev/null; then
    echo "  ok: fake_gem5 still running"
else
    echo "FAIL: fake_gem5 exited (attach mode should leave target alive)" >&2
    exit 1
fi

# --- Cleanup ---
echo "--- Cleanup ---"
kill "$PID" 2>/dev/null || true

# Wait for sampler to detect target exit and finish
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_EXIT=$?
echo "Sampler exit code: $SAMPLER_EXIT"

echo ""
echo "=== All attach integration tests passed ==="
