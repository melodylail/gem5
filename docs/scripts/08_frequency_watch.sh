#!/usr/bin/env bash
set -eu

CPU_LIST=${1:-0-$(($(nproc)-1))}
SECONDS=${2:-120}
OUT=${3:-frequency_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

if command -v turbostat >/dev/null; then
    sudo timeout "$SECONDS" \
        turbostat \
        --quiet \
        -c "$CPU_LIST" \
        --show Package,Core,CPU,Busy%,Bzy_MHz \
        -i 1 \
        > "$OUT/turbostat.log" 2>&1 || true
else
    echo "turbostat not installed" > "$OUT/turbostat.log"
fi

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        for cpu in ${CPU_LIST//,/ }; do
            f="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq"
            [[ -r "$f" ]] && echo "cpu${cpu} $(cat "$f") kHz"
        done

        sleep 1
    done
) > "$OUT/cpufreq_sysfs.log"

echo "Saved to $OUT"
