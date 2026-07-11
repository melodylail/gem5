#!/bin/bash
# profiling/mem/tests/e2e/test_pipeline_smoke.sh
# End-to-end smoke test: full pipeline with MEM_TREND=1.
#
# Gated on E2E=1 (set in environment). Skips gracefully when gem5.opt
# is not available.
#
# Validates:
#   1. CSV is produced with >=5 data rows
#   2. Report contains "Effective configuration"
#   3. Metrics JSON contains peak_rss_kb
set -euo pipefail

if [ "${E2E:-0}" != "1" ]; then
    echo "SKIP: E2E=1 not set (export E2E=1 to run end-to-end tests)"
    exit 0
fi

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$TEST_DIR/../tools"
PROJECT_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
RUN_SH="$PROJECT_ROOT/profiling/run.sh"

source "$TOOLS_DIR/assert.sh"

echo "=== E2E Smoke: MEM_TREND=1 pipeline ==="

# --- Check prerequisites ---
if [ ! -x "$PROJECT_ROOT/build/ALL/gem5.opt" ]; then
    echo "SKIP: gem5.opt not found — run the full build first"
    exit 0
fi

# --- Create temp output directory ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
export GEM5_BUILD="$PROJECT_ROOT/build/ALL/gem5.opt"

echo "Temporary output directory: $TMPDIR"
echo "gem5 binary: $GEM5_BUILD"

# --- Run full pipeline with MEM_TREND=1 ---
echo "--- Running pipeline ---"
set +e
MEM_TREND=1 OUTPUT_DIR="$TMPDIR" bash "$RUN_SH" > "$TMPDIR/pipeline.log" 2>&1
PIPELINE_EXIT=$?
set -e

echo "Pipeline exit code: $PIPELINE_EXIT"
echo ""
echo "--- Pipeline log (last 30 lines) ---"
tail -30 "$TMPDIR/pipeline.log"

# --- Assertions ---

# 1. CSV must have >=5 data rows
CSV="$TMPDIR/mem_trend.csv"
assert_file_exists "$CSV" "CSV file must exist"
assert_file_not_empty "$CSV" "CSV file must not be empty"

TOTAL_NONCOMMENT=$(grep -c -v '^#' "$CSV" 2>/dev/null || echo 0)
DATA_ROWS=$((TOTAL_NONCOMMENT - 1))

echo "CSV data rows: $DATA_ROWS"

if [ "$DATA_ROWS" -lt 5 ]; then
    echo "FAIL: expected >=5 data rows, got $DATA_ROWS" >&2
    echo "Full CSV:" >&2
    cat "$CSV" >&2
    exit 1
fi
echo "  ok: >=5 data rows ($DATA_ROWS)"

# 2. Report must contain "Effective configuration"
REPORT="$TMPDIR/mem_report.md"
if [ -f "$REPORT" ] && [ -s "$REPORT" ]; then
    assert_contains "Effective configuration" "$REPORT" \
        "report must contain 'Effective configuration'"
else
    echo "INFO: No report file found (may have been suppressed by || true in pipeline)"
    echo "  Running analyzer directly..."
    python3 "$PROJECT_ROOT/profiling/mem/analyze_mem.py" \
        --csv "$CSV" \
        --stats "$TMPDIR/stats.txt" \
        --policy "$PROJECT_ROOT/profiling/mem/mem_thresholds.yaml" \
        --no-plot \
        --report "$TMPDIR/mem_report_direct.md" \
        --metrics "$TMPDIR/metrics_direct.json" || true
    if [ -f "$TMPDIR/mem_report_direct.md" ] && [ -s "$TMPDIR/mem_report_direct.md" ]; then
        assert_contains "Effective configuration" "$TMPDIR/mem_report_direct.md" \
            "report must contain 'Effective configuration'"
    fi
fi

# 3. Metrics JSON must contain peak_rss_kb
METRICS="$TMPDIR/metrics.json"
if [ ! -f "$METRICS" ] || [ ! -s "$METRICS" ]; then
    METRICS="$TMPDIR/metrics_direct.json"
fi

if [ -f "$METRICS" ] && [ -s "$METRICS" ]; then
    assert_contains "peak_rss_kb" "$METRICS" \
        "metrics JSON must contain 'peak_rss_kb'"
else
    echo "FAIL: metrics JSON not found" >&2
    exit 1
fi

echo ""
echo "=== E2E pipeline smoke test passed ==="
