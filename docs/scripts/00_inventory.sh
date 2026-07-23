#!/usr/bin/env bash
set -u

OUT=${1:-inventory_$(date +%Y%m%d_%H%M%S).log}

exec > >(tee "$OUT") 2>&1

echo "===== DATE / HOST ====="
date -Is
hostname
uname -a

echo
echo "===== CPU SUMMARY ====="
lscpu

echo
echo "===== CPU TOPOLOGY ====="
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE,MAXMHZ,MINMHZ

echo
echo "Logical CPUs:"
nproc --all

echo "Physical cores:"
lscpu -p=CORE,SOCKET |
    grep -v '^#' |
    sort -u |
    wc -l

echo
echo "Sockets:"
lscpu -p=SOCKET |
    grep -v '^#' |
    sort -u |
    wc -l

echo
echo "===== SMT SIBLINGS ====="
for f in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
    printf "%s: " "$(basename "$(dirname "$(dirname "$f")")")"
    cat "$f"
done | sort -V

echo
echo "===== NUMA ====="
if command -v numactl >/dev/null; then
    numactl --hardware
fi

if command -v numastat >/dev/null; then
    numastat -m
fi

echo
echo "===== MEMORY ====="
free -h
grep -E \
'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|AnonPages|AnonHugePages|HugePages' \
/proc/meminfo

echo
echo "===== SWAP ====="
swapon --show || true

echo
echo "===== THP ====="
for f in \
    /sys/kernel/mm/transparent_hugepage/enabled \
    /sys/kernel/mm/transparent_hugepage/defrag; do
    if [[ -r "$f" ]]; then
        echo "$f: $(cat "$f")"
    fi
done

echo
echo "===== PSI ====="
for r in cpu memory io; do
    echo "--- $r ---"
    cat "/proc/pressure/$r" 2>/dev/null || echo "not supported"
done

echo
echo "===== CPU GOVERNOR ====="
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -r "$f" ]] && echo "$f: $(cat "$f")"
done | sort -V | uniq -f1 -c

echo
echo "Saved to $OUT"
