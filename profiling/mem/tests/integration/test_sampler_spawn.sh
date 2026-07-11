#!/bin/bash
# profiling/mem/tests/integration/test_sampler_spawn.sh
# Integration test: mem_sample.sh spawn mode with fake_gem5.
#
# Validates:
#   1. CSV is produced with >=3 data rows
#   2. CSV header contains provenance fields (gem5_cmd, tag)
#   3. mem_sample.log exists
#   4. Sampler exit code matches fake_gem5 exit code
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SAMPLER="$PROJECT_ROOT/profiling/mem/mem_sample.sh"

source "$TOOLS_DIR/assert.sh"

echo "=== Test: sampler spawn mode ==="

# --- Build fake_gem5 ---
echo "--- Building fake_gem5 ---"
bash "$TOOLS_DIR/build_fake_gem5.sh"
FAKE_GEM5="$TOOLS_DIR/fake_gem5"
assert_file_exists "$FAKE_GEM5" "fake_gem5 binary must exist after build"

# --- Create temp directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Temporary directory: $TMPDIR"

# --- Run sampler in spawn mode ---
echo "--- Running sampler ---"
set +e
"$SAMPLER" \
    --output-dir "$TMPDIR" \
    --interval-s 0.5 \
    --tag "test-spawn" \
    -- "$FAKE_GEM5" 10 5
ACTUAL_EXIT=$?
set -e

echo "Sampler exit code: $ACTUAL_EXIT"

# --- Assertions ---
CSV="$TMPDIR/mem_trend.csv"
LOG="$TMPDIR/mem_sample.log"

assert_file_exists "$CSV" "CSV file must exist"
assert_file_not_empty "$CSV" "CSV file must not be empty"

echo "--- CSV header ---"
head -10 "$CSV"

# Header must contain provenance fields
assert_contains "gem5_cmd" "$CSV" "CSV header must contain gem5_cmd"
assert_contains "test-spawn" "$CSV" "CSV header must contain tag value"

# Log must exist
assert_file_exists "$LOG" "Sampler log must exist"
assert_file_not_empty "$LOG" "Sampler log must not be empty"

# --- Count data rows ---
# Non-comment, non-empty lines; subtract 1 for the column-name header.
TOTAL_NONCOMMENT=$(grep -c -v '^#' "$CSV" || true)
DATA_ROWS=$((TOTAL_NONCOMMENT - 1))

echo "Total non-comment lines: $TOTAL_NONCOMMENT"
echo "Data rows (excluding column header): $DATA_ROWS"

if [ "$DATA_ROWS" -lt 3 ]; then
    echo "FAIL: expected >=3 data rows, got $DATA_ROWS" >&2
    echo "Full CSV:" >&2
    cat "$CSV" >&2
    exit 1
fi
echo "  ok: >=3 data rows ($DATA_ROWS)"

# --- Verify each data row has exactly 9 columns ---
DATA_LINES=$(grep -v '^#' "$CSV" | tail -n +2)
while IFS= read -r line; do
    COLS=$(echo "$line" | tr ',' '\n' | wc -l)
    if [ "$COLS" -ne 9 ]; then
        echo "FAIL: data row has $COLS columns, expected 9: $line" >&2
        exit 1
    fi
done <<< "$DATA_LINES"
echo "  ok: all data rows have 9 columns"

# --- Sampler exit code must match fake_gem5 (0 for normal exit) ---
assert_exit_code 0 "$ACTUAL_EXIT" "sampler must exit with fake_gem5 exit code (0)"

echo ""
echo "=== All spawn integration tests passed ==="
