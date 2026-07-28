#!/usr/bin/env python3
"""
profiling/monitor/analyze_symphony_mem.py

Filter daemon's proc_mem.csv for symphony processes, extract workload label
from -d parameter, and report per-process memory trends over time.

Usage:
  python3 analyze_symphony_mem.py --output-dir ./output [--csv symphony_mem.csv]

  # Filter by custom pattern instead of "symphony"
  python3 analyze_symphony_mem.py --output-dir ./output --pattern "gem5.opt"

  # Show per-snapshot detail (not just summary)
  python3 analyze_symphony_mem.py --output-dir ./output --detail
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


def find_csv_files(output_dir: str, name: str) -> list:
    return sorted(Path(output_dir).rglob(name))


def extract_d_label(cmdline: str) -> str:
    """
    Extract the last directory component from `-d <path>` in cmdline.
    Example:
      ".../symphony.opt -d /dept/.../554.roms_sp_2 -r -e ..."
      → "554.roms_sp_2"
    Returns "?" if -d not found.
    """
    m = re.search(r'(?:^|\s)-d\s+(\S+)', cmdline)
    if not m:
        return "?"
    path = m.group(1).rstrip('/')
    return os.path.basename(path)


def extract_trace_label(cmdline: str) -> str:
    """
    Extract a secondary label from --pinball-basename for richer identification.
    Example:
      "--pinball-basename=/project/.../554.roms/pp/pinball_0_3363419.pp/..."
      → "554.roms"
    Returns "" if not found.
    """
    m = re.search(r'--pinball-basename=\S*/(spec\w+|pinball[^/]*)', cmdline)
    if m:
        return m.group(1)
    # Fallback: try to get the benchmark dir before "pp"
    m2 = re.search(r'/traces/[^/]+/[^/]+/[^/]+/([^/]+)/', cmdline)
    if m2:
        return m2.group(1)
    return ""


def format_kb(kb):
    """Format KB as human-readable."""
    try:
        v = int(kb)
    except (ValueError, TypeError):
        return str(kb)
    if v >= 1024 * 1024:
        return f"{v / (1024 * 1024):.2f} GB"
    if v >= 1024:
        return f"{v / 1024:.1f} MB"
    return f"{v} KB"


def format_duration(secs):
    if secs < 60:
        return f"{secs:.0f}s"
    m, s = divmod(int(secs), 60)
    return f"{m}m{s}s"


def main():
    parser = argparse.ArgumentParser(
        description="Analyze symphony process memory trends from daemon CSV"
    )
    parser.add_argument("--output-dir", required=True, help="Daemon output root directory")
    parser.add_argument("--pattern", default="symphony",
                        help="Process name pattern to match in cmdline (default: symphony)")
    parser.add_argument("--csv", default="", help="Optional: write per-snapshot data to this CSV")
    parser.add_argument("--detail", action="store_true",
                        help="Show per-snapshot breakdown (not just summary)")
    parser.add_argument("--top", type=int, default=50, help="Max processes in summary (default: 50)")
    args = parser.parse_args()

    if not os.path.isdir(args.output_dir):
        print(f"ERROR: {args.output_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    proc_files = find_csv_files(args.output_dir, "proc_mem.csv")
    if not proc_files:
        print("ERROR: no proc_mem.csv found", file=sys.stderr)
        sys.exit(1)

    # ---------------------------------------------------------------
    # Pass 1: scan all CSVs, filter symphony rows, build PID → samples
    # ---------------------------------------------------------------
    # Each sample: (ts_ms, wall_clock, rss_kb, pss_kb, uss_kb, swap_kb, label_d, label_trace)
    pid_samples = defaultdict(list)  # pid → [samples]
    pid_labels = {}                  # pid → (label_d, label_trace)
    total_scanned = 0

    for csv_path in proc_files:
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                total_scanned += 1
                cmdline = row.get("cmdline", "")
                if args.pattern not in cmdline:
                    continue

                pid = row.get("pid", "?")
                label_d = extract_d_label(cmdline)
                label_trace = extract_trace_label(cmdline)

                # Track label for this PID (use first-seen)
                if pid not in pid_labels:
                    pid_labels[pid] = (label_d, label_trace)

                try:
                    ts = int(row.get("ts_ms", 0))
                except ValueError:
                    continue

                pid_samples[pid].append({
                    "ts_ms": ts,
                    "wall_clock": row.get("wall_clock", ""),
                    "rss_kb": int(row.get("rss_kb", 0) or 0),
                    "pss_kb": int(row.get("pss_kb", -1) or -1),
                    "uss_kb": int(row.get("uss_kb", -1) or -1),
                    "swap_kb": int(row.get("swap_kb", 0) or 0),
                    "label_d": label_d,
                    "label_trace": label_trace,
                })

    matched_pids = list(pid_samples.keys())
    total_matched = sum(len(v) for v in pid_samples.values())

    print(f"Scanned {total_scanned} proc_mem rows across {len(proc_files)} files")
    print(f"Matched '{args.pattern}': {len(matched_pids)} unique PIDs, {total_matched} samples total")
    print()

    if not matched_pids:
        print("No matching processes found.")
        return

    # ---------------------------------------------------------------
    # Sort samples per PID by timestamp
    # ---------------------------------------------------------------
    for pid in matched_pids:
        pid_samples[pid].sort(key=lambda s: s["ts_ms"])

    # ---------------------------------------------------------------
    # Compute per-PID summary
    # ---------------------------------------------------------------
    summaries = []
    for pid, samples in pid_samples.items():
        label_d, label_trace = pid_labels[pid]

        rss_values = [s["rss_kb"] for s in samples]
        pss_values = [s["pss_kb"] for s in samples if s["pss_kb"] > 0]
        uss_values = [s["uss_kb"] for s in samples if s["uss_kb"] > 0]
        swap_values = [s["swap_kb"] for s in samples]

        first = samples[0]
        last = samples[-1]
        duration_s = (last["ts_ms"] - first["ts_ms"]) / 1000.0

        peak_rss = max(rss_values)
        first_rss = rss_values[0]
        last_rss = rss_values[-1]
        growth = last_rss - first_rss

        summaries.append({
            "pid": pid,
            "label_d": label_d,
            "label_trace": label_trace,
            "samples": len(samples),
            "first_seen": first["wall_clock"],
            "last_seen": last["wall_clock"],
            "duration_s": duration_s,
            "first_rss": first_rss,
            "peak_rss": peak_rss,
            "last_rss": last_rss,
            "growth_kb": growth,
            "peak_pss": max(pss_values) if pss_values else -1,
            "peak_uss": max(uss_values) if uss_values else -1,
            "peak_swap": max(swap_values) if swap_values else 0,
            "samples_list": samples,
        })

    # Sort by peak RSS descending
    summaries.sort(key=lambda s: s["peak_rss"], reverse=True)

    # ---------------------------------------------------------------
    # Print summary table
    # ---------------------------------------------------------------
    print("=" * 130)
    print(f"{'PID':<8} {'Label (-d last dir)':<40} {'Trace':<20} "
          f"{'Samples':<8} {'Duration':<10} "
          f"{'First RSS':<12} {'Peak RSS':<12} {'Last RSS':<12} "
          f"{'Growth':<12} {'Peak Swap':<10}")
    print("-" * 130)

    for s in summaries[:args.top]:
        print(f"{s['pid']:<8} {s['label_d']:<40} {s['label_trace']:<20} "
              f"{s['samples']:<8} {format_duration(s['duration_s']):<10} "
              f"{format_kb(s['first_rss']):<12} {format_kb(s['peak_rss']):<12} "
              f"{format_kb(s['last_rss']):<12} "
              f"{format_kb(s['growth_kb']):<12} {format_kb(s['peak_swap']):<10}")

    if len(summaries) > args.top:
        print(f"... {len(summaries) - args.top} more processes (use --top {len(summaries)} to show all)")

    print("=" * 130)
    print(f"Total: {len(summaries)} processes")
    print()

    # ---------------------------------------------------------------
    # Aggregate by label_d (group multiple PIDs with same workload)
    # ---------------------------------------------------------------
    label_groups = defaultdict(list)
    for s in summaries:
        label_groups[s["label_d"]].append(s)

    if len(label_groups) < len(summaries):
        print("=" * 80)
        print(f"{'Aggregated by -d label':^80}")
        print("=" * 80)
        print(f"{'Label':<40} {'#Procs':<8} {'Sum Peak RSS':<14} {'Max Peak RSS':<14} {'Total Growth':<14}")
        print("-" * 80)

        for label, group in sorted(label_groups.items(), key=lambda x: sum(g["peak_rss"] for g in x[1]), reverse=True):
            sum_peak = sum(g["peak_rss"] for g in group)
            max_peak = max(g["peak_rss"] for g in group)
            total_growth = sum(g["growth_kb"] for g in group)
            print(f"{label:<40} {len(group):<8} {format_kb(sum_peak):<14} "
                  f"{format_kb(max_peak):<14} {format_kb(total_growth):<14}")
        print()

    # ---------------------------------------------------------------
    # Optional: per-snapshot detail
    # ---------------------------------------------------------------
    if args.detail:
        print("=" * 100)
        print("Per-snapshot detail (top processes by peak RSS):")
        print("=" * 100)
        for s in summaries[:min(10, len(summaries))]:
            print(f"\nPID={s['pid']}  Label={s['label_d']}  Trace={s['label_trace']}")
            print(f"  {'Time':<28} {'RSS':<12} {'PSS':<12} {'USS':<12} {'Swap':<10}")
            print(f"  {'-'*28} {'-'*12} {'-'*12} {'-'*12} {'-'*10}")
            for snap in s["samples_list"]:
                print(f"  {snap['wall_clock']:<28} "
                      f"{format_kb(snap['rss_kb']):<12} "
                      f"{format_kb(snap['pss_kb']):<12} "
                      f"{format_kb(snap['uss_kb']):<12} "
                      f"{format_kb(snap['swap_kb']):<10}")
        print()

    # ---------------------------------------------------------------
    # Optional: write per-snapshot CSV
    # ---------------------------------------------------------------
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            writer = csv.writer(f, lineterminator="\n")
            writer.writerow([
                "pid", "label_d", "label_trace",
                "ts_ms", "wall_clock",
                "rss_kb", "pss_kb", "uss_kb", "swap_kb",
            ])
            for s in summaries:
                for snap in s["samples_list"]:
                    writer.writerow([
                        s["pid"], s["label_d"], s["label_trace"],
                        snap["ts_ms"], snap["wall_clock"],
                        snap["rss_kb"], snap["pss_kb"], snap["uss_kb"], snap["swap_kb"],
                    ])
        print(f"Per-snapshot data written to {args.csv}")


if __name__ == "__main__":
    main()
