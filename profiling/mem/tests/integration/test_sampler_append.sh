#!/bin/bash
# profiling/mem/tests/integration/test_sampler_append.sh
# Integration test: mem_sample.sh append mode with fake_gem5.
#
# Validates:
#   1. Two runs (fresh then --append) produce a combined CSV
#   2. CSV contains at least one "# segment_start:" marker
#   3. Total data rows >= rows_from_first_run + 3
#   4. ts_ms column is monotonically non-decreasing across all data rows
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SAMPLER="$PROJECT_ROOT/profiling/mem/mem_sample.sh"

source "$TOOLS_DIR/assert.sh"

echo "=== Test: sampler append mode ==="

# --- Build fake_gem5 ---
echo "--- Building fake_gem5 ---"
bash "$TOOLS_DIR/build_fake_gem5.sh"
FAKE_GEM5="$TOOLS_DIR/fake_gem5"
assert_file_exists "$FAKE_GEM5" "fake_gem5 binary must exist after build"

# --- Create temp directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
echo "Temporary directory: $TMPDIR"

CSV="$TMPDIR/mem_trend.csv"

# =====================================================================
# Run 1: fresh spawn (no --append)
# =====================================================================
echo "--- Run 1: fresh spawn (fake_gem5 10 3) ---"
set +e
"$SAMPLER" \
    --output-dir "$TMPDIR" \
    --interval-s 0.5 \
    --tag "test-append-run1" \
    -- "$FAKE_GEM5" 10 3
EXIT1=$?
set -e

assert_exit_code 0 "$EXIT1" "first sampler run must exit 0"
assert_file_exists "$CSV" "CSV must exist after first run"
assert_file_not_empty "$CSV" "CSV must not be empty after first run"

# Count data rows after run 1 (non-comment lines, minus 1 for column header)
TOTAL_NC_RUN1=$(grep -c -v '^#' "$CSV" || true)
N1=$((TOTAL_NC_RUN1 - 1))
echo "Run 1 data rows (N1): $N1"

if [ "$N1" -lt 3 ]; then
    echo "FAIL: expected >=3 data rows from first run, got $N1" >&2
    echo "Full CSV:" >&2
    cat "$CSV" >&2
    exit 1
fi
echo "  ok: >=3 data rows from first run ($N1)"

# =====================================================================
# Run 2: append spawn
# =====================================================================
echo "--- Run 2: append spawn (fake_gem5 10 3) ---"
set +e
"$SAMPLER" \
    --output-dir "$TMPDIR" \
    --interval-s 0.5 \
    --tag "test-append-run2" \
    --append \
    -- "$FAKE_GEM5" 10 3
EXIT2=$?
set -e

assert_exit_code 0 "$EXIT2" "second sampler run must exit 0"

# =====================================================================
# Assertions on combined CSV
# =====================================================================
echo "--- CSV header ---"
head -15 "$CSV"

assert_file_exists "$CSV" "CSV must exist after second run"
assert_file_not_empty "$CSV" "CSV must not be empty after second run"

# Header must contain provenance fields (from run 1, untouched by append)
assert_contains "gem5_cmd" "$CSV" "CSV header must contain gem5_cmd"
assert_contains "test-append-run1" "$CSV" "CSV header must contain first run tag"

# Must contain segment_start marker
assert_contains "# segment_start:" "$CSV" "CSV must contain at least one segment_start marker"

# Header must show attached: false (spawn mode both times)
assert_contains "attached: false" "$CSV" "CSV header must show attached: false"

# Count total data rows after append
TOTAL_NC=$(grep -c -v '^#' "$CSV" || true)
DATA_ROWS_TOTAL=$((TOTAL_NC - 1))
echo "Total data rows after append: $DATA_ROWS_TOTAL"

# Total rows must be >= N1 + 3 (second run added at least 3 data rows)
EXPECTED_MIN=$((N1 + 3))
assert_ge "$DATA_ROWS_TOTAL" "$EXPECTED_MIN" \
    "total rows ($DATA_ROWS_TOTAL) >= run1_rows ($N1) + 3"

# Log must exist and mention append mode
LOG="$TMPDIR/mem_sample.log"
assert_file_exists "$LOG" "Sampler log must exist"
assert_file_not_empty "$LOG" "Sampler log must not be empty"
assert_contains "append mode" "$LOG" "Log should mention append mode"

# =====================================================================
# Verify ts_ms monotonically non-decreasing across all data rows
# =====================================================================
echo "--- Checking ts_ms monotonic ---"
PREV_TS=-1
DATA_LINES=$(grep -v '^#' "$CSV" | tail -n +2)
LINE_NUM=0
while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    TS=$(echo "$line" | cut -d, -f1)
    if [ "$TS" -lt "$PREV_TS" ]; then
        echo "FAIL: ts_ms decreased from $PREV_TS to $TS on data line $LINE_NUM" >&2
        echo "Row: $line" >&2
        exit 1
    fi
    PREV_TS="$TS"
done <<< "$DATA_LINES"
echo "  ok: ts_ms monotonically non-decreasing across $LINE_NUM data rows"

echo ""
echo "=== All append integration tests passed ==="
