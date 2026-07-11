#!/bin/bash
# profiling/mem/tests/integration/test_analyzer_cli.sh
# Integration test for analyze_mem.py exit-code contract (spec §4.4).
#
# Validates:
#   1. Normal CSV, no thresholds  → exit 0, report has "Effective configuration"
#   2. Missing CSV                → exit 2
#   3. Leak fixture + strict.yaml → exit 1, report says FAIL
#   4. Normal CSV + lenient.yaml  → exit 0
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
FIXTURES_DIR="$TEST_DIR/../fixtures"
ANALYZER="$PROJECT_ROOT/profiling/mem/analyze_mem.py"

source "$TOOLS_DIR/assert.sh"

# --- Create temp directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Temporary directory: $TMPDIR"

# ============================================================
# Test 1: Normal CSV, no thresholds → exit 0
# ============================================================
echo ""
echo "=== Test 1: Normal CSV, no thresholds ==="

set +e
python3 "$ANALYZER" \
    --csv "$FIXTURES_DIR/mem_trend_normal.csv" \
    --no-plot \
    --report "$TMPDIR/report_test1.md" \
    --metrics "$TMPDIR/metrics_test1.json"
ACTUAL_EXIT=$?
set -e

assert_exit_code 0 "$ACTUAL_EXIT" "normal CSV, no thresholds → exit 0"
assert_file_exists "$TMPDIR/report_test1.md" "report must exist"
assert_file_not_empty "$TMPDIR/report_test1.md" "report must not be empty"
assert_contains "Effective configuration" "$TMPDIR/report_test1.md" \
    "report must contain 'Effective configuration'"

echo "=== Test 1 PASSED ==="

# ============================================================
# Test 2: Missing CSV → exit 2
# ============================================================
echo ""
echo "=== Test 2: Missing CSV ==="

set +e
python3 "$ANALYZER" \
    --csv "$TMPDIR/nonexistent.csv" \
    --no-plot 2>/dev/null
ACTUAL_EXIT=$?
set -e

assert_exit_code 2 "$ACTUAL_EXIT" "missing CSV → exit 2"

echo "=== Test 2 PASSED ==="

# ============================================================
# Test 3: Leak fixture + strict.yaml → exit 1
# ============================================================
echo ""
echo "=== Test 3: Leak fixture + strict.yaml policy ==="

set +e
python3 "$ANALYZER" \
    --csv "$FIXTURES_DIR/mem_trend_leak.csv" \
    --policy "$FIXTURES_DIR/policies/strict.yaml" \
    --no-plot \
    --report "$TMPDIR/report_test3.md" \
    --metrics "$TMPDIR/metrics_test3.json"
ACTUAL_EXIT=$?
set -e

assert_exit_code 1 "$ACTUAL_EXIT" "leak fixture + strict.yaml → exit 1"
assert_file_exists "$TMPDIR/report_test3.md" "report must exist"
assert_file_not_empty "$TMPDIR/report_test3.md" "report must not be empty"
assert_contains "FAIL" "$TMPDIR/report_test3.md" \
    "report must contain FAIL verdict"

echo "=== Test 3 PASSED ==="

# ============================================================
# Test 4: Normal CSV + lenient.yaml → exit 0
# ============================================================
echo ""
echo "=== Test 4: Normal CSV + lenient.yaml policy ==="

set +e
python3 "$ANALYZER" \
    --csv "$FIXTURES_DIR/mem_trend_normal.csv" \
    --policy "$FIXTURES_DIR/policies/lenient.yaml" \
    --no-plot \
    --report "$TMPDIR/report_test4.md" \
    --metrics "$TMPDIR/metrics_test4.json"
ACTUAL_EXIT=$?
set -e

assert_exit_code 0 "$ACTUAL_EXIT" "normal CSV + lenient.yaml → exit 0"

echo "=== Test 4 PASSED ==="

# ============================================================
echo ""
echo "=== All analyzer CLI integration tests passed ==="
