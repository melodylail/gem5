#!/bin/bash
# profiling/mem/deep_run.sh — On-demand heap attribution via heaptrack.
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
HEAPTRACK_PREFIX="${HEAPTRACK_PREFIX:-heaptrack.gem5}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --prefix) HEAPTRACK_PREFIX="$2"; shift 2 ;;
        --pid) echo "ERROR: --pid not supported with heaptrack (LD_PRELOAD interposer)" >&2; exit 2 ;;
        --) shift; break ;;
        -h|--help) echo "Usage: deep_run.sh [opts] -- <gem5_cmd> [args...]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 2 ;;
    esac
done

[ $# -eq 0 ] && { echo "ERROR: no command"; exit 2; }

if ! command -v heaptrack &>/dev/null; then
    echo "ERROR: heaptrack not found. Install: apt install heaptrack" >&2
    exit 127
fi

mkdir -p "$OUTPUT_DIR"
exec heaptrack -o "$OUTPUT_DIR/${HEAPTRACK_PREFIX}" "$@"
