#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [OUTFILE]}
OUT=${2:-hugepage_${PID}_$(date +%Y%m%d_%H%M%S).log}

{
    echo "===== THP SETTINGS ====="

    for f in \
        /sys/kernel/mm/transparent_hugepage/enabled \
        /sys/kernel/mm/transparent_hugepage/defrag; do
        [[ -r "$f" ]] && echo "$f: $(cat "$f")"
    done

    echo
    echo "===== PROCESS SUMMARY ====="
    grep -E \
    'Rss|Pss|AnonHugePages|FilePmdMapped|Shared_Hugetlb|Private_Hugetlb' \
    /proc/"$PID"/smaps_rollup 2>/dev/null || true

    echo
    echo "===== PAGE SIZE DISTRIBUTION ====="

    awk '
    /^KernelPageSize:/ {
        kernel[$2 " " $3]++
    }

    /^MMUPageSize:/ {
        mmu[$2 " " $3]++
    }

    END {
        print "KernelPageSize:"
        for (k in kernel)
            print k, kernel[k]

        print "MMUPageSize:"
        for (k in mmu)
            print k, mmu[k]
    }
    ' /proc/"$PID"/smaps

    echo
    echo "===== VMSTAT THP/COMPACTION ====="
    grep -E \
    'thp_|compact_|allocstall|pgscan_direct' \
    /proc/vmstat

} | tee "$OUT"
