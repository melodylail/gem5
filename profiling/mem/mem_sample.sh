#!/bin/bash
# profiling/mem/mem_sample.sh
# Sidecar memory sampler for gem5 (and any process).
#
# Modes:
#   Spawn:  mem_sample.sh [opts] -- <cmd> [args...]
#   Attach: mem_sample.sh --pid <pid> [opts]
#
# Reads /proc/<pid>/smaps_rollup every INTERVAL_S seconds and writes
# timestamped memory samples to a CSV. Falls back to /proc/<pid>/status
# when smaps_rollup is unavailable (PSS/USS/heap columns become -1).
#
# See docs/superpowers/specs/2026-07-09-gem5-memory-trend-design.md §3.1.
set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
if ! command -v bc >/dev/null 2>&1; then
    echo "ERROR: bc is required for mem_sample.sh" >&2
    exit 2
fi

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults (environment overrides these)
# ---------------------------------------------------------------------------
INTERVAL_S="${INTERVAL_S:-1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
MEM_TREND_CSV="${MEM_TREND_CSV:-}"
MEM_SAMPLE_LOG="${MEM_SAMPLE_LOG:-}"
MEM_ALLOW_FALLBACK="${MEM_ALLOW_FALLBACK:-1}"
MEM_RUN_TAG="${MEM_RUN_TAG:-}"
MEM_APPEND="${MEM_APPEND:-0}"
MEM_ATTACH_PID="${MEM_ATTACH_PID:-}"
MEM_MAX_SAMPLES="${MEM_MAX_SAMPLES:-0}"
MEM_MAX_DURATION_S="${MEM_MAX_DURATION_S:-0}"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options] -- <gem5-cmd> [gem5-args...]
       $SCRIPT_NAME --pid <pid> [options]

Sidecar memory sampler. Reads /proc/<pid>/smaps_rollup every
INTERVAL_S seconds and writes timestamped CSV rows until the
target process exits.

Options:
  --interval-s <float>     Sample interval in seconds (default: $INTERVAL_S,
                           env: INTERVAL_S)
  --output-dir <path>      Output directory (default: $OUTPUT_DIR,
                           env: OUTPUT_DIR)
  --csv <path>             CSV output path (default: <output-dir>/mem_trend.csv,
                           env: MEM_TREND_CSV)
  --sample-log <path>      Sampler log path (default: <output-dir>/mem_sample.log,
                           env: MEM_SAMPLE_LOG)
  --allow-fallback         Allow /proc/<pid>/status fallback (default: on,
                           env: MEM_ALLOW_FALLBACK=1)
  --no-allow-fallback      Disable /proc/<pid>/status fallback (exit 3 if
                           smaps_rollup unavailable)
  --tag <label>            Run label recorded in CSV header (env: MEM_RUN_TAG)
  --append                 Append to existing CSV (env: MEM_APPEND=1)
  --pid <pid>              Attach to existing PID (env: MEM_ATTACH_PID)
  --max-samples <int>      Stop sampling after N rows; monitor-only thereafter
                           (default: 0 = unlimited, env: MEM_MAX_SAMPLES)
  --max-duration-s <float> Stop sampling after N seconds; monitor-only thereafter
                           (default: 0 = unlimited, env: MEM_MAX_DURATION_S)
  --help                   Show this help
EOF
    exit 0
}

GEM5_ARGS=()
MODE="spawn"

while [ $# -gt 0 ]; do
    case "$1" in
        --interval-s)
            INTERVAL_S="$2"; shift 2 ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --csv)
            MEM_TREND_CSV="$2"; shift 2 ;;
        --sample-log)
            MEM_SAMPLE_LOG="$2"; shift 2 ;;
        --allow-fallback)
            MEM_ALLOW_FALLBACK=1; shift ;;
        --no-allow-fallback)
            MEM_ALLOW_FALLBACK=0; shift ;;
        --tag)
            MEM_RUN_TAG="$2"; shift 2 ;;
        --append)
            MEM_APPEND=1; shift ;;
        --pid)
            MEM_ATTACH_PID="$2"; MODE="attach"; shift 2 ;;
        --max-samples)
            MEM_MAX_SAMPLES="$2"; shift 2 ;;
        --max-duration-s)
            MEM_MAX_DURATION_S="$2"; shift 2 ;;
        --help)
            usage ;;
        --)
            shift
            GEM5_ARGS=("$@")
            break ;;
        -*)
            echo "ERROR: unknown flag: $1" >&2
            usage ;;
        *)
            echo "ERROR: unexpected positional argument '$1' (use -- to separate gem5 command)" >&2
            usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ "$MODE" = "spawn" ]; then
    if [ ${#GEM5_ARGS[@]} -eq 0 ]; then
        echo "ERROR: spawn mode requires a command after --" >&2
        usage
    fi
elif [ "$MODE" = "attach" ]; then
    if [ -z "$MEM_ATTACH_PID" ]; then
        echo "ERROR: attach mode requires --pid <pid>" >&2
        usage
    fi
    if [ ${#GEM5_ARGS[@]} -gt 0 ]; then
        echo "ERROR: --pid and positional gem5 command are mutually exclusive" >&2
        exit 2
    fi
fi

# Basic interval sanity check (bc may not be available; warn only if checkable)
_min_interval=0.1
if command -v bc >/dev/null 2>&1; then
    if [ "$(echo "$INTERVAL_S < $_min_interval" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        echo "WARNING: interval ${INTERVAL_S}s < ${_min_interval}s; measurement noise may dominate" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
CSV_PATH="${MEM_TREND_CSV:-$OUTPUT_DIR/mem_trend.csv}"
SAMPLE_LOG="${MEM_SAMPLE_LOG:-$OUTPUT_DIR/mem_sample.log}"

# Truncate log (append mode keeps prior log; fresh run starts clean)
if [ "$MEM_APPEND" != "1" ] || [ ! -f "$SAMPLE_LOG" ]; then
    : > "$SAMPLE_LOG"
fi

log_msg() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z'): $*" >> "$SAMPLE_LOG"
}

# ---------------------------------------------------------------------------
# Helper: read smaps_rollup  (primary data source)
# ---------------------------------------------------------------------------
_read_smaps_rollup() {
    local rss=0 pss=0 private_dirty=0 private_clean=0
    local shared_clean=0 shared_dirty=0 anon=0 swap=0

    while IFS=: read -r key val; do
        val="${val//kB/}"
        val="${val// /}"
        case "$key" in
            Rss)            rss="$val" ;;
            Pss)            pss="$val" ;;
            Private_Dirty)  private_dirty="$val" ;;
            Private_Clean)  private_clean="$val" ;;
            Shared_Clean)   shared_clean="$val" ;;
            Shared_Dirty)   shared_dirty="$val" ;;
            Anonymous)      anon="$val" ;;
            Swap)           swap="$val" ;;
        esac
    done < "/proc/$PID/smaps_rollup"

    RSS_KB="$rss"
    PSS_KB="$pss"
    USS_KB=$((private_dirty + private_clean))
    HEAP_KB="$(_read_heap_kb)"
    ANON_KB="$anon"
    FILE_KB=$((shared_clean + private_clean + shared_dirty))
    if [ "$FILE_KB" -lt 0 ]; then FILE_KB=0; fi
    SWAP_KB="$swap"
}

_read_heap_kb() {
    # Extract [heap] VMA Rss from smaps.  smaps_rollup does not break out
    # heap separately, so we do a targeted grep on the full smaps file.
    # Returns 0 when [heap] is absent or smaps is unreadable.
    grep -A 15 '\[heap\]' "/proc/$PID/smaps" 2>/dev/null | \
        grep -m1 '^Rss:' | \
        awk '{print $2}' || echo "0"
}

# ---------------------------------------------------------------------------
# Helper: read /proc/<pid>/status  (fallback when smaps_rollup unavailable)
# ---------------------------------------------------------------------------
_read_status_fallback() {
    local rss=0 swap=0

    while IFS=: read -r key val; do
        val="${val//kB/}"
        val="${val// /}"
        case "$key" in
            VmRSS) rss="$val" ;;
            VmSwap) swap="$val" ;;
        esac
    done < "/proc/$PID/status"

    RSS_KB="$rss"
    PSS_KB=-1
    USS_KB=-1
    HEAP_KB=-1
    ANON_KB=-1
    FILE_KB=-1
    SWAP_KB="$swap"
}

# ---------------------------------------------------------------------------
# Core: take one sample, write one CSV row
# Returns 1 when the target process is gone (caller should break).
# ---------------------------------------------------------------------------
sample_one() {
    local now_mono ts_ms

    # PID-reuse guard: compare /proc/<pid>/stat field 22 (starttime)
    if [ -n "${STARTTIME:-}" ] && [ -f "/proc/$PID/stat" ]; then
        local cur_st
        cur_st="$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null || echo "")"
        if [ -n "$cur_st" ] && [ "$cur_st" != "$STARTTIME" ]; then
            log_msg "PID $PID starttime changed ($STARTTIME -> $cur_st); treating as exit"
            now_mono="$(awk '{print $1}' /proc/uptime)"
            ts_ms="$(echo "($now_mono - $START_MONO) * 1000 + ${TS_OFFSET:-0}" | bc | cut -d. -f1)"
            echo "${ts_ms},0,-1,-1,-1,0,0,0,exited" >> "$CSV_PATH"
            return 1
        fi
    fi

    # Timestamp (CLOCK_MONOTONIC via /proc/uptime)
    now_mono="$(awk '{print $1}' /proc/uptime)"
    ts_ms="$(echo "($now_mono - $START_MONO) * 1000 + ${TS_OFFSET:-0}" | bc | cut -d. -f1)"

    # Read memory counters
    if [ -f "/proc/$PID/smaps_rollup" ] && [ -r "/proc/$PID/smaps_rollup" ]; then
        _read_smaps_rollup
    elif [ "$MEM_ALLOW_FALLBACK" = "1" ] && [ -f "/proc/$PID/status" ]; then
        log_msg "smaps_rollup unavailable for PID $PID; falling back to /proc/$PID/status"
        if [ "$FALLBACK_NOTED" = "0" ]; then
            echo "# smaps_rollup_unavailable: true" >> "$CSV_PATH"
            FALLBACK_NOTED=1
            log_msg "noted smaps_rollup_unavailable in CSV"
        fi
        _read_status_fallback
    elif [ "$MEM_ALLOW_FALLBACK" = "0" ]; then
        log_msg "smaps_rollup unavailable for PID $PID and fallback disabled; exiting"
        exit 3
    else
        log_msg "no readable /proc source for PID $PID; treating as exited"
        echo "${ts_ms},0,-1,-1,-1,0,0,0,exited" >> "$CSV_PATH"
        return 1
    fi

    echo "${ts_ms},${RSS_KB:-0},${PSS_KB:--1},${USS_KB:--1},${HEAP_KB:--1},${ANON_KB:-0},${FILE_KB:-0},${SWAP_KB:-0},$GEM5_PHASE" \
        >> "$CSV_PATH"

    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    return 0
}

# ---------------------------------------------------------------------------
# Signal handling (spawn mode: forward to gem5 child)
# ---------------------------------------------------------------------------
_forward_signal() {
    local sig="$1"
    log_msg "received $sig"
    if [ "$MODE" = "spawn" ] && [ -n "${GEM5_PID:-}" ]; then
        if kill -0 "$GEM5_PID" 2>/dev/null; then
            log_msg "forwarding $sig to gem5 PID $GEM5_PID"
            kill -"$sig" "$GEM5_PID" 2>/dev/null || true
            # Wait for gem5 to exit after signal
            wait "$GEM5_PID" 2>/dev/null || true
            GEM5_EXIT_CODE=$?
        fi
    fi
    log_msg "sampler exiting after signal (gem5 exit code: ${GEM5_EXIT_CODE:-143})"
    exit "${GEM5_EXIT_CODE:-143}"
}

trap '_forward_signal TERM' SIGTERM
trap '_forward_signal INT' SIGINT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Capture wall-clock timestamp once for the header
START_WALL="$(date --iso-8601=seconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)"
START_MONO="$(awk '{print $1}' /proc/uptime)"

log_msg "sampler starting (mode=$MODE, interval_s=$INTERVAL_S)"

if [ "$MODE" = "spawn" ]; then
    # --- Spawn mode: fork gem5 in background ---
    log_msg "spawning: ${GEM5_ARGS[*]}"

    "${GEM5_ARGS[@]}" &
    GEM5_PID=$!
    PID="$GEM5_PID"

    # Brief pause to let gem5 exec and populate /proc
    sleep 0.05

    if ! kill -0 "$PID" 2>/dev/null; then
        log_msg "gem5 failed to start (PID $PID not found)"
        wait "$GEM5_PID" 2>/dev/null || true
        GEM5_EXIT_CODE=$?
        log_msg "gem5 exit code: ${GEM5_EXIT_CODE:-1}"
        exit "${GEM5_EXIT_CODE:-1}"
    fi

    log_msg "gem5 started with PID $PID"
elif [ "$MODE" = "attach" ]; then
    PID="$MEM_ATTACH_PID"
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: PID $PID does not exist or is not accessible" >&2
        exit 2
    fi
    log_msg "attached to PID $PID"
fi

# Capture PID starttime for reuse guard
STARTTIME=""
if [ -f "/proc/$PID/stat" ]; then
    STARTTIME="$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null || echo "")"
    log_msg "captured starttime: $STARTTIME"
fi

# --- Write CSV header ---
HOSTNAME="$(hostname 2>/dev/null || uname -n)"
KERNEL="$(uname -r)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo 4096)"

if [ "$MEM_APPEND" = "1" ] && [ -f "$CSV_PATH" ]; then
    # Validate existing CSV header matches expected column schema
    _expected_header="ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase"
    _existing_header="$(grep -m1 -v '^#' "$CSV_PATH" 2>/dev/null || echo "")"
    if [ -n "$_existing_header" ] && [ "$_existing_header" != "$_expected_header" ]; then
        echo "ERROR: existing CSV header mismatch" >&2
        echo "  expected: $_expected_header" >&2
        echo "  found:    $_existing_header" >&2
        exit 2
    fi
    log_msg "append mode: header validated, reading existing CSV for offset"

    _last_line="$(tail -1 "$CSV_PATH" 2>/dev/null || echo "")"
    if [ -n "$_last_line" ] && ! echo "$_last_line" | grep -q '^#'; then
        _last_ts="$(echo "$_last_line" | cut -d, -f1)"
        if [ "$_last_ts" -gt 0 ] 2>/dev/null; then
            TS_OFFSET="$_last_ts"
            log_msg "append offset (last ts_ms): $TS_OFFSET"
        fi
    fi

    # Write segment-start marker into CSV body
    echo "# segment_start: $START_WALL" >> "$CSV_PATH"
else
    # Fresh CSV: write provenance header then column header
    {
        echo "# gem5_cmd: ${GEM5_ARGS[*]:-$MEM_ATTACH_PID}"
        echo "# start_wall: $START_WALL"
        echo "# interval_s: $INTERVAL_S"
        echo "# pid: $PID"
        echo "# host: $HOSTNAME, kernel: $KERNEL, page_size: $PAGE_SIZE"
        echo "# tag: ${MEM_RUN_TAG:-}"
        echo "# attached: $([ "$MODE" = "attach" ] && echo "true" || echo "false")"
    } > "$CSV_PATH"

    echo "ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase" \
        >> "$CSV_PATH"
fi

# --- Sampling loop ---
SAMPLE_COUNT=0
SAMPLE_START_MONO="$START_MONO"
GEM5_PHASE="unknown"
MONITOR_ONLY=0
FALLBACK_NOTED=0

log_msg "beginning sampling loop (interval=${INTERVAL_S}s)"

while true; do
    # Check if gem5 is still alive
    if [ "$MODE" = "spawn" ]; then
        if ! kill -0 "$GEM5_PID" 2>/dev/null; then
            log_msg "gem5 PID $GEM5_PID has exited"
            _now_mono="$(awk '{print $1}' /proc/uptime)"
            _ts_ms="$(echo "($_now_mono - $START_MONO) * 1000 + ${TS_OFFSET:-0}" | bc | cut -d. -f1)"
            echo "${_ts_ms},0,-1,-1,-1,0,0,0,crashed" >> "$CSV_PATH"
            break
        fi
    else
        if ! kill -0 "$PID" 2>/dev/null; then
            log_msg "target PID $PID has exited"
            break
        fi
    fi

    # Check duration cap (before taking this sample)
    if [ "$MONITOR_ONLY" = "0" ] && [ "$MEM_MAX_DURATION_S" != "0" ]; then
        _elapsed="$(echo "$(awk '{print $1}' /proc/uptime) - $SAMPLE_START_MONO" | bc -l)"
        if [ "$(echo "$_elapsed >= $MEM_MAX_DURATION_S" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            log_msg "max duration reached (${MEM_MAX_DURATION_S}s); capping"
            _now_mono="$(awk '{print $1}' /proc/uptime)"
            _ts_ms="$(echo "($_now_mono - $START_MONO) * 1000 + ${TS_OFFSET:-0}" | bc | cut -d. -f1)"
            echo "${_ts_ms},0,-1,-1,-1,0,0,0,sampler_cap_reached" >> "$CSV_PATH"
            MONITOR_ONLY=1
        fi
    fi

    # Take sample (skip data rows when in monitor-only mode after cap)
    if [ "$MONITOR_ONLY" = "0" ]; then
        if ! sample_one; then
            break
        fi

        # Check sample count cap (after writing)
        if [ "$MEM_MAX_SAMPLES" != "0" ] && [ "$SAMPLE_COUNT" -ge "$MEM_MAX_SAMPLES" ]; then
            log_msg "max samples reached ($MEM_MAX_SAMPLES); capping"
            MONITOR_ONLY=1
            _now_mono="$(awk '{print $1}' /proc/uptime)"
            _ts_ms="$(echo "($_now_mono - $START_MONO) * 1000 + ${TS_OFFSET:-0}" | bc | cut -d. -f1)"
            echo "${_ts_ms},0,-1,-1,-1,0,0,0,sampler_cap_reached" >> "$CSV_PATH"
        fi
    fi

    sleep "$INTERVAL_S"
done

# --- Wait for gem5 and forward exit code (spawn mode) ---
if [ "$MODE" = "spawn" ]; then
    wait "$GEM5_PID" 2>/dev/null || true
    GEM5_EXIT_CODE=$?
    log_msg "gem5 exited with code $GEM5_EXIT_CODE"
    exit "$GEM5_EXIT_CODE"
else
    log_msg "target PID $PID exited; sampler done"
    exit 0
fi
