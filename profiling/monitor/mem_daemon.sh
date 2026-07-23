#!/bin/bash
# profiling/monitor/mem_daemon.sh
# Background daemon: periodic system-wide memory + process + kswapd monitoring.
#
# Usage:
#   ./mem_daemon.sh [--sys-only] [--proc-only] [--mode light|standard|detailed]
#           [--interval 5] [--max-samples 0] [--duration 0]
#           [--slice-minutes 60] [--output-dir ./output]
#
# Design spec: docs/superpowers/specs/2026-07-23-memory-monitor-daemon-design.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults (environment overrides)
# ---------------------------------------------------------------------------
INTERVAL_S="${INTERVAL_S:-5}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
MEM_MODE="${MEM_MODE:-standard}"
MEM_DURATION_S="${MEM_DURATION_S:-0}"
MEM_MAX_SAMPLES="${MEM_MAX_SAMPLES:-0}"
MEM_MODE="${MEM_MODE:-standard}"
MEM_SLICE_M="${MEM_SLICE_M:-60}"

SYS_ONLY=0
PROC_ONLY=0
FULL_MODE=0

if [ $# -eq 0 ]; then
    FULL_MODE=1
fi

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --sys-only) SYS_ONLY=1; shift ;;
        --proc-only) PROC_ONLY=1; shift ;;
        --interval) INTERVAL_S="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --mode) MEM_MODE="$2"; shift 2 ;;
        --duration) MEM_DURATION_S="$2"; shift 2 ;;
        --max-samples) MEM_MAX_SAMPLES="$2"; shift 2 ;;
        --slice-minutes) MEM_SLICE_M="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --sys-only             Collect system memory stats only"
            echo "  --proc-only            Collect process memory stats only"
            echo "  --interval SECONDS     Sampling interval (default: 5)"
            echo "  --output-dir PATH      Output root directory (default: ./output)"
            echo "  --mode MODE            light | standard | detailed (default: standard)"
            echo "  --duration SECONDS     Total runtime, 0=forever (default: 0)"
            echo "  --max-samples N        Max samples, 0=unlimited (default: 0)"
            echo "  --slice-minutes N      Directory slice interval in minutes (default: 60)"
            echo "  --help                 This help"
            exit 0
            ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: timestamp
# ---------------------------------------------------------------------------
get_mono_ms() {
    awk '{printf "%.0f", $1 * 1000}' /proc/uptime
}

get_wall_clock() {
    date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

# ---------------------------------------------------------------------------
# Helper: slice directory path from wall clock
# ---------------------------------------------------------------------------
get_slice_dir() {
    local wall="$1"
    local slice_m="$2"
    # Extract YYYY-MM-DD_HH from wall clock, adjust for slice
    local ymd_h=$(echo "$wall" | sed 's/T.*//')_$(echo "$wall" | sed 's/.*T//; s/:.*//')
    echo "$OUTPUT_DIR/${ymd_h}"
}

# ---------------------------------------------------------------------------
# Helper: ensure slice directory exists, write sys_mem.csv header if new file
# ---------------------------------------------------------------------------
ensure_sys_mem_csv() {
    local slice_dir="$1"
    local csv="$slice_dir/sys_mem.csv"
    mkdir -p "$slice_dir"
    if [ ! -f "$csv" ]; then
        {
            echo "ts_ms,wall_clock,memtotal_kb,memfree_kb,memavailable_kb,cached_kb,buffers_kb,anonpages_kb,dirty_kb,swaptotal_kb,swapfree_kb,pgscan_kswapd,pgsteal_kswapd,pgscan_direct,pgsteal_direct,compact_stall,allocstall_normal,psi_mem_some_avg10,psi_mem_full_avg10,psi_io_some_avg10"
        } > "$csv"
    fi
    echo "$csv"
}

# ---------------------------------------------------------------------------
# Core: collect one sample of system memory stats
# ---------------------------------------------------------------------------
collect_sys_mem() {
    local csv="$1"
    local ts_ms wall

    ts_ms=$(get_mono_ms)
    wall=$(get_wall_clock)

    # /proc/meminfo snapshot
    local memtotal=0 memfree=0 memavail=0 cached=0 buffers=0
    local anonpages=0 dirty=0 swaptotal=0 swapfree=0

    while IFS=: read -r key val; do
        val="${val//kB/}"; val="${val// /}"
        case "$key" in
            MemTotal)     memtotal="$val" ;;
            MemFree)      memfree="$val" ;;
            MemAvailable) memavail="$val" ;;
            Cached)       cached="$val" ;;
            Buffers)      buffers="$val" ;;
            AnonPages)    anonpages="$val" ;;
            Dirty)        dirty="$val" ;;
            SwapTotal)    swaptotal="$val" ;;
            SwapFree)     swapfree="$val" ;;
        esac
    done < /proc/meminfo

    # /proc/vmstat snapshot
    local pgscan_kswapd=0 pgsteal_kswapd=0 pgscan_direct=0 pgsteal_direct=0
    local compact_stall=0 allocstall_normal=0

    while read -r key val; do
        case "$key" in
            pgscan_kswapd)     pgscan_kswapd="$val" ;;
            pgsteal_kswapd)    pgsteal_kswapd="$val" ;;
            pgscan_direct)     pgscan_direct="$val" ;;
            pgsteal_direct)    pgsteal_direct="$val" ;;
            compact_stall)     compact_stall="$val" ;;
            allocstall_normal) allocstall_normal="$val" ;;
        esac
    done < /proc/vmstat

    # PSI
    local psi_mem_some=0 psi_mem_full=0 psi_io_some=0

    if [ -r /proc/pressure/memory ]; then
        psi_mem_some=$(awk '/^some/' /proc/pressure/memory | awk '{for(i=1;i<=NF;i++) if($i~/^avg10=/) print substr($i,7)}')
        psi_mem_full=$(awk '/^full/' /proc/pressure/memory | awk '{for(i=1;i<=NF;i++) if($i~/^avg10=/) print substr($i,7)}')
    fi
    if [ -r /proc/pressure/io ]; then
        psi_io_some=$(awk '/^some/' /proc/pressure/io | awk '{for(i=1;i<=NF;i++) if($i~/^avg10=/) print substr($i,7)}')
    fi

    echo "${ts_ms},${wall},${memtotal},${memfree},${memavail},${cached},${buffers},${anonpages},${dirty},${swaptotal},${swapfree},${pgscan_kswapd},${pgsteal_kswapd},${pgscan_direct},${pgsteal_direct},${compact_stall},${allocstall_normal},${psi_mem_some:-0},${psi_mem_full:-0},${psi_io_some:-0}" \
        >> "$csv"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
START_MONO=$(awk '{print $1}' /proc/uptime)
SAMPLE_COUNT=0
START_WALL=$(get_wall_clock)
CURRENT_SLICE_DIR=""

run_one_sample() {
    local wall ts_ms
    wall=$(get_wall_clock)

    # Determine slice directory; create on first sample or when hour changes
    local slice_dir
    slice_dir=$(get_slice_dir "$wall" "$MEM_SLICE_M")

    if [ "$slice_dir" != "$CURRENT_SLICE_DIR" ]; then
        CURRENT_SLICE_DIR="$slice_dir"
    fi

    # Collect sys_mem
    if [ "$SYS_ONLY" = "1" ] || [ "$FULL_MODE" = "1" ]; then
        local csv
        csv=$(ensure_sys_mem_csv "$CURRENT_SLICE_DIR")
        collect_sys_mem "$csv"
    fi

    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
}

# --sys-only with --max-samples: just collect N samples and exit
if [ "$SYS_ONLY" = "1" ] && [ "$MEM_MAX_SAMPLES" -gt 0 ]; then
    for _ in $(seq 1 "$MEM_MAX_SAMPLES"); do
        run_one_sample
        sleep "$INTERVAL_S"
    done
    exit 0
fi

# Otherwise: loop forever (or until duration reached)
END_TS=0
if [ "$MEM_DURATION_S" -gt 0 ] 2>/dev/null; then
    END_TS=$(( $(date +%s) + MEM_DURATION_S ))
fi

while true; do
    run_one_sample

    if [ "$MEM_MAX_SAMPLES" -gt 0 ] && [ "$SAMPLE_COUNT" -ge "$MEM_MAX_SAMPLES" ]; then
        break
    fi

    if [ "$END_TS" -gt 0 ] && [ "$(date +%s)" -ge "$END_TS" ]; then
        break
    fi

    sleep "$INTERVAL_S"
done
