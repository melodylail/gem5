#!/bin/bash
# profiling/analyze.sh
# Generate reports from perf.data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
PERF_DATA="$OUTPUT_DIR/perf.data"

if [ ! -f "$PERF_DATA" ]; then
    echo "ERROR: perf.data not found at $PERF_DATA"
    echo "Run './run.sh' first."
    exit 1
fi

# FlameGraph path
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/FlameGraph}"

echo "=== Generating perf reports ==="

# 1. Hotspots by function
echo "[1/4] Top hotspot functions..."
perf report --stdio --sort=overhead,dso,symbol \
    -i "$PERF_DATA" \
    > "$OUTPUT_DIR/perf_report_hotspots.txt"
echo "  → $OUTPUT_DIR/perf_report_hotspots.txt"

# 2. Cache misses by function
echo "[2/4] Cache miss analysis..."
perf report --stdio --sort=overhead,symbol \
    -i "$PERF_DATA" -e cache-misses \
    > "$OUTPUT_DIR/perf_report_cache.txt"
echo "  → $OUTPUT_DIR/perf_report_cache.txt"

# 3. Branch misses by function
echo "[3/4] Branch miss analysis..."
perf report --stdio --sort=overhead,symbol \
    -i "$PERF_DATA" -e branch-misses \
    > "$OUTPUT_DIR/perf_report_branch.txt"
echo "  → $OUTPUT_DIR/perf_report_branch.txt"

# 4. FlameGraph (if available)
echo "[4/4] FlameGraph..."
if [ -d "$FLAMEGRAPH_DIR" ]; then
    perf script -i "$PERF_DATA" \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" \
        > "$OUTPUT_DIR/flamegraph.svg"
    echo "  → $OUTPUT_DIR/flamegraph.svg"
else
    echo "  SKIP: FlameGraph not found at $FLAMEGRAPH_DIR"
    echo "  Install: git clone https://github.com/brendangregg/FlameGraph.git ~/FlameGraph"
fi

echo ""
echo "=== Analysis complete ==="
echo "Files in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR/"
