#!/usr/bin/env python3
"""
profiling/monitor/analyze_kswapd.py
Analyze kswapd activity and identify top memory consumers.

Detects kswapd activation from:
  1. kswapd.csv: state='R' or 'D', or cpu_percent > 0
  2. sys_mem.csv: pgscan_kswapd increasing between consecutive samples

For each activation window, extracts top-N memory consumers from proc_mem.csv.

Usage:
  python3 analyze_kswapd.py --output-dir <path> [--top 20] [--window-s 10]
"""

import argparse
import csv
import os
import sys
from collections import defaultdict
from pathlib import Path


def find_csv_files(output_dir: str, name: str) -> list:
    """Find all CSV files matching `name` under output_dir (recursive)."""
    return sorted(Path(output_dir).rglob(name))


def load_kswapd(path: str) -> list:
    """Load kswapd.csv, return list of dicts."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def load_sys_mem(path: str) -> list:
    """Load sys_mem.csv, return list of dicts."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def load_proc_mem(path: str) -> list:
    """Load proc_mem.csv, return list of dicts."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def detect_kswapd_active(kswapd_rows: list, sys_mem_rows: list, window_s: int) -> list:
    """
    Detect kswapd activation events.
    
    Primary signals:
      1. pgscan_kswapd increased between samples (actual page scanning happened)
      2. kswapd state = R or D (actively running or blocked on I/O)
    
    Returns list of (ts_ms, wall_clock, reason, details).
    """
    events = []

    # Method 1: pgscan_kswapd increased between samples (most reliable)
    for i in range(1, len(sys_mem_rows)):
        prev = int(sys_mem_rows[i - 1].get("pgscan_kswapd", 0))
        curr = int(sys_mem_rows[i].get("pgscan_kswapd", 0))
        if curr > prev:
            delta = curr - prev
            events.append({
                "ts_ms": int(sys_mem_rows[i]["ts_ms"]),
                "wall_clock": sys_mem_rows[i].get("wall_clock", ""),
                "reason": f"pgscan_kswapd +{delta} ({prev} -> {curr})",
                "source": "sys_mem.csv",
            })

    # Method 2: kswapd state = R or D (running or blocked on I/O)
    for row in kswapd_rows:
        state = row.get("state", "")
        if state in ("R", "D"):
            events.append({
                "ts_ms": int(row["ts_ms"]),
                "wall_clock": row.get("wall_clock", ""),
                "reason": f"kswapd state={state} (running or blocked on I/O)",
                "source": "kswapd.csv",
            })

    # Sort by timestamp
    events.sort(key=lambda e: e["ts_ms"])

    # Deduplicate events within window_s
    merged = []
    for ev in events:
        if not merged:
            merged.append(ev)
            continue
        last = merged[-1]
        if ev["ts_ms"] - last["ts_ms"] <= window_s * 1000:
            # Merge: keep the one with more interesting reason
            if "kswapd state" not in last["reason"] and "kswapd state" in ev["reason"]:
                last["reason"] = ev["reason"]
            elif "pgscan_kswapd" in ev["reason"]:
                last["reason"] = last["reason"] + "; " + ev["reason"]
        else:
            merged.append(ev)

    return merged


def find_top_processes(proc_mem_rows: list, target_ts_ms: int, window_s: int, top_n: int) -> list:
    """
    Find top-N processes by RSS within ±window_s of target_ts_ms.
    Returns list of (rss_kb, row_dict).
    """
    window_ms = window_s * 1000
    candidates = []

    for row in proc_mem_rows:
        try:
            ts = int(row["ts_ms"])
        except (ValueError, KeyError):
            continue
        if abs(ts - target_ts_ms) > window_ms:
            continue
        try:
            rss = int(row.get("rss_kb", 0))
        except (ValueError, KeyError):
            rss = 0
        if rss > 0:
            candidates.append((rss, row))

    # Deduplicate by PID within this window (keep max RSS)
    pid_best = {}
    for rss, row in candidates:
        pid = row.get("pid", "?")
        if pid not in pid_best or rss > pid_best[pid][0]:
            pid_best[pid] = (rss, row)

    # Sort by RSS descending, take top N
    sorted_procs = sorted(pid_best.values(), key=lambda x: x[0], reverse=True)
    return sorted_procs[:top_n]


def format_size(kb: int) -> str:
    """Format KB as human-readable."""
    if kb >= 1024 * 1024:
        return f"{kb / (1024 * 1024):.1f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"


def main():
    parser = argparse.ArgumentParser(
        description="Analyze kswapd activity and find top memory consumers"
    )
    parser.add_argument("--output-dir", required=True, help="Daemon output root directory")
    parser.add_argument("--top", type=int, default=20, help="Number of top processes to show (default: 20)")
    parser.add_argument("--window-s", type=int, default=10, help="Time window for matching (default: 10s)")
    args = parser.parse_args()

    output_dir = args.output_dir
    if not os.path.isdir(output_dir):
        print(f"ERROR: {output_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Load all CSVs
    kswapd_files = find_csv_files(output_dir, "kswapd.csv")
    sys_mem_files = find_csv_files(output_dir, "sys_mem.csv")
    proc_mem_files = find_csv_files(output_dir, "proc_mem.csv")

    if not kswapd_files:
        print("ERROR: no kswapd.csv found", file=sys.stderr)
        sys.exit(1)
    if not proc_mem_files:
        print("ERROR: no proc_mem.csv found", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(kswapd_files)} kswapd.csv, {len(sys_mem_files)} sys_mem.csv, {len(proc_mem_files)} proc_mem.csv")
    print()

    # Load all data
    all_kswapd = []
    for f in kswapd_files:
        all_kswapd.extend(load_kswapd(str(f)))

    all_sys_mem = []
    for f in sys_mem_files:
        all_sys_mem.extend(load_sys_mem(str(f)))

    all_proc_mem = []
    for f in proc_mem_files:
        all_proc_mem.extend(load_proc_mem(str(f)))

    print(f"Loaded {len(all_kswapd)} kswapd rows, {len(all_sys_mem)} sys_mem rows, {len(all_proc_mem)} proc_mem rows")
    print()

    # Detect kswapd activation
    events = detect_kswapd_active(all_kswapd, all_sys_mem, args.window_s)

    if not events:
        print("No kswapd activation detected in the data.")
        print()
        print("kswapd state summary:")
        states = defaultdict(int)
        for row in all_kswapd:
            states[row.get("state", "?")] += 1
        for s, c in sorted(states.items()):
            print(f"  state={s}: {c} samples")
        print()
        print("pgscan_kswapd summary:")
        if all_sys_mem:
            first = int(all_sys_mem[0].get("pgscan_kswapd", 0))
            last = int(all_sys_mem[-1].get("pgscan_kswapd", 0))
            delta = last - first
            print(f"  first: {first}, last: {last}, delta: {delta}")
        return

    print(f"Detected {len(events)} kswapd activation event(s):")
    print()

    for i, ev in enumerate(events):
        print(f"{'=' * 80}")
        print(f"Event #{i + 1}: {ev['wall_clock']} (ts_ms={ev['ts_ms']})")
        print(f"  Reason: {ev['reason']}")
        print(f"  Source: {ev['source']}")
        print()

        # Find sys_mem context at this time
        for sm in all_sys_mem:
            try:
                sts = int(sm["ts_ms"])
            except (ValueError, KeyError):
                continue
            if abs(sts - ev["ts_ms"]) <= args.window_s * 1000:
                print(f"  Memory context:")
                print(f"    MemFree:     {format_size(int(sm.get('memfree_kb', 0)))}")
                print(f"    MemAvailable:{format_size(int(sm.get('memavailable_kb', 0)))}")
                print(f"    SwapFree:    {format_size(int(sm.get('swapfree_kb', 0)))}")
                print(f"    Dirty:       {format_size(int(sm.get('dirty_kb', 0)))}")
                print(f"    pgscan_kswapd: {sm.get('pgscan_kswapd', 0)}")
                print(f"    pgsteal_kswapd:{sm.get('pgsteal_kswapd', 0)}")
                print(f"    PSI mem some:  {sm.get('psi_mem_some_avg10', 0)}")
                print(f"    PSI mem full:  {sm.get('psi_mem_full_avg10', 0)}")
                break
        print()

        # Top processes
        top = find_top_processes(all_proc_mem, ev["ts_ms"], args.window_s, args.top)
        if not top:
            print("  No process data found in this window.")
        else:
            print(f"  Top {args.top} processes by RSS (±{args.window_s}s window):")
            print(f"  {'Rank':<6} {'PID':<8} {'RSS':<12} {'USS':<12} {'Name':<20} {'Cmdline'}")
            print(f"  {'-' * 6} {'-' * 8} {'-' * 12} {'-' * 12} {'-' * 20} {'-' * 30}")
            for rank, (rss, row) in enumerate(top, 1):
                pid = row.get("pid", "?")
                comm = row.get("comm", "?")[:20]
                cmdline = row.get("cmdline", "")[:80]
                uss = row.get("uss_kb", "?")
                print(f"  {rank:<6} {pid:<8} {format_size(rss):<12} {format_size(int(uss) if uss not in ('-1','?',None) else 0):<12} {comm:<20} {cmdline}")
        print()


if __name__ == "__main__":
    main()
