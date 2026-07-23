#!/bin/bash
# profiling/monitor/env.sh — shared environment for mem_daemon.sh and mem_daemon.py
export OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output}"
export INTERVAL_S="${INTERVAL_S:-5}"
export MEM_MODE="${MEM_MODE:-standard}"
export MEM_DURATION_S="${MEM_DURATION_S:-0}"
export MEM_MAX_SAMPLES="${MEM_MAX_SAMPLES:-0}"
export MEM_SLICE_M="${MEM_SLICE_M:-60}"
