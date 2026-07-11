#!/bin/bash
# profiling/run.sh
# Full profiling pipeline: build → compile workload → perf stat → perf record + gem5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$OUTPUT_DIR"

# 1. Compile workload
echo "=== Compiling workload ==="
make -C "$SCRIPT_DIR/workload"
WORKLOAD_BIN="$SCRIPT_DIR/workload/workload"
echo "Workload binary: $WORKLOAD_BIN"

# 2. Verify gem5 binary exists
if [ ! -x "$GEM5_BUILD" ]; then
    echo "ERROR: gem5 binary not found at $GEM5_BUILD"
    echo "Run './build.sh' first or set GEM5_BUILD."
    exit 1
fi

# 3. perf stat — macro metrics
echo ""
echo "=== Layer 1: perf stat ==="
perf stat \
    -e cycles,instructions,cache-references,cache-misses,\
branch-instructions,branch-misses,L1-dcache-load-misses,\
L1-icache-load-misses \
    -o "$OUTPUT_DIR/perf.stat.txt" \
    "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
    --binary "$WORKLOAD_BIN" \
    --output-dir "$OUTPUT_DIR"

echo "perf stat done → $OUTPUT_DIR/perf.stat.txt"
cat "$OUTPUT_DIR/perf.stat.txt"

# 4. perf record — sampling
echo ""
echo "=== Layer 2: perf record ==="
perf record \
    --call-graph dwarf \
    -F 99 \
    -e cycles,instructions,cache-misses,branch-misses \
    -o "$OUTPUT_DIR/perf.data" \
    "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
    --binary "$WORKLOAD_BIN" \
    --output-dir "$OUTPUT_DIR"

echo "perf record done → $OUTPUT_DIR/perf.data"

# 5. Memory trend (Layer 3) — opt-in via MEM_TREND=1
if [ "${MEM_TREND:-0}" = "1" ]; then
    echo ""
    echo "=== Layer 3: memory trend (sidecar) ==="
    mkdir -p "$OUTPUT_DIR"
    "$SCRIPT_DIR/mem/mem_sample.sh" \
        --output-dir "$OUTPUT_DIR" \
        --tag "${MEM_RUN_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo untagged)}" \
        -- "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
        --binary "$WORKLOAD_BIN" --output-dir "$OUTPUT_DIR"
    python3 "$SCRIPT_DIR/mem/analyze_mem.py" \
        --csv "$OUTPUT_DIR/mem_trend.csv" \
        --stats "$OUTPUT_DIR/stats.txt" \
        --policy "$SCRIPT_DIR/mem/mem_thresholds.yaml" || true
fi

echo ""
echo "=== Run complete ==="
echo "Next: run ./analyze.sh to generate reports"
