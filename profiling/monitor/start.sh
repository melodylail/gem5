#!/bin/bash
# mem-monitor/start.sh — 一键启动 / 停止 / 状态 管理
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PID_FILE="${OUTPUT_DIR}/mem_daemon.pid"
LOG_FILE="${OUTPUT_DIR}/mem_daemon.log"

cmd_status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid
        pid=$(cat "$PID_FILE")
        local runtime
        runtime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
        echo "daemon running: PID=$pid, uptime=$runtime"
        echo "output: $OUTPUT_DIR"
        return 0
    else
        echo "daemon NOT running"
        return 1
    fi
}

cmd_start() {
    if cmd_status &>/dev/null; then
        echo "daemon already running"
        return 1
    fi
    mkdir -p "$OUTPUT_DIR"
    echo "Starting daemon (mode=$MEM_MODE, interval=${INTERVAL_S}s)..."
    echo "  output: $OUTPUT_DIR"
    echo "  engine: ${1:-auto}"

    local engine="${1:-auto}"
    if [ "$engine" = "python" ]; then
        nohup python3 "$SCRIPT_DIR/mem_daemon.py" \
            --interval "$INTERVAL_S" --mode "$MEM_MODE" \
            --output-dir "$OUTPUT_DIR" \
            >> "$LOG_FILE" 2>&1 &
    else
        nohup "$SCRIPT_DIR/mem_daemon.sh" \
            --interval "$INTERVAL_S" --mode "$MEM_MODE" \
            --output-dir "$OUTPUT_DIR" \
            >> "$LOG_FILE" 2>&1 &
    fi
    echo $! > "$PID_FILE"
    sleep 1
    cmd_status
}

cmd_stop() {
    if ! cmd_status &>/dev/null; then
        echo "daemon not running"
        return 0
    fi
    local pid
    pid=$(cat "$PID_FILE")
    echo "Stopping daemon PID=$pid..."
    kill "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "force killing..."
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "stopped"
}

cmd_analyze() {
    echo "Analyzing kswapd activity..."
    python3 "$SCRIPT_DIR/analyze_kswapd.py" \
        --output-dir "$OUTPUT_DIR" --top "${1:-20}" --window-s "${2:-10}"
}

case "${1:-}" in
    start)
        cmd_start "${2:-auto}"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    restart)
        cmd_stop; sleep 2; cmd_start "${2:-auto}"
        ;;
    analyze)
        cmd_analyze "${2:-20}" "${3:-10}"
        ;;
    *)
        echo "Usage: $0 {start [bash|python] | stop | status | restart | analyze [N] [window_s]}"
        echo ""
        echo "  start          Start daemon (default: bash engine)"
        echo "  start python   Start using Python engine (needs psutil)"
        echo "  stop           Graceful stop (SIGTERM)"
        echo "  status         Check if daemon is running"
        echo "  restart        Stop then start"
        echo "  analyze [N]    Analyze kswapd → top N memory consumers (default: 20)"
        echo ""
        echo "Config (edit env.sh):"
        echo "  INTERVAL_S=${INTERVAL_S}   Sample interval (seconds)"
        echo "  MEM_MODE=${MEM_MODE}   light | standard | detailed"
        echo "  OUTPUT_DIR=${OUTPUT_DIR}"
        exit 0
        ;;
esac
