#!/usr/bin/env python3
"""
profiling/monitor/compare_symphony_runs.py

Compare symphony memory usage across two runs of the same workload.

Usage:
  python3 compare_symphony_runs.py --run-a ./run1_output --run-b ./run2_output
  python3 compare_symphony_runs.py --run-a ./run1_output --run-b ./run2_output --csv diff.csv
  python3 compare_symphony_runs.py --run-a ./before --run-b ./after --pattern gem5.opt
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from pathlib import Path


def find_csv_files(output_dir: str, name: str) -> list:
    return sorted(Path(output_dir).rglob(name))


def extract_d_label(cmdline: str) -> str:
    m = re.search(r'(?:^|\s)-d\s+(\S+)', cmdline)
    if not m:
        return "?"
    path = m.group(1).rstrip('/')
    return os.path.basename(path).split('_sp_')[0]  # normalize: 554.roms_sp_2 → 554.roms


def load_proc_csv(csv_files: list, pattern: str) -> dict:
    """
    Scan proc_mem CSVs, filter by pattern, group by (pid, label_d).
    Returns { pid: { label_d, rss_samples: [...], pss_samples: [...], uss_samples: [...], swap_samples: [...],
                     first_seen, last_seen, duration_s } }
    """
    pid_data = {}  # pid → dict
    total = 0
    matched = 0

    for f in csv_files:
        with open(f) as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                total += 1
                cmdline = row.get("cmdline", "")
                if pattern not in cmdline:
                    continue
                matched += 1

                pid = row.get("pid", "?")
                label_d = extract_d_label(cmdline)
                try:
                    ts_ms = int(row.get("ts_ms", 0))
                except ValueError:
                    continue
                wall = row.get("wall_clock", "")
                rss = int(row.get("rss_kb", 0) or 0)
                pss = int(row.get("pss_kb", -1) or -1)
                uss = int(row.get("uss_kb", -1) or -1)
                swap = int(row.get("swap_kb", 0) or 0)

                if pid not in pid_data:
                    pid_data[pid] = {
                        "label_d": label_d,
                        "samples": [],
                    }
                pid_data[pid]["samples"].append({
                    "ts_ms": ts_ms, "wall": wall,
                    "rss": rss, "pss": pss, "uss": uss, "swap": swap,
                })

    print(f"  scanned {total} rows, matched {matched} with '{pattern}'", file=sys.stderr)

    # Sort samples per PID by timestamp, compute summary
    for pid, data in pid_data.items():
        data["samples"].sort(key=lambda s: s["ts_ms"])
        first = data["samples"][0]
        last = data["samples"][-1]
        duration_s = (last["ts_ms"] - first["ts_ms"]) / 1000.0

        data["first_seen"] = first["wall"]
        data["last_seen"] = last["wall"]
        data["duration_s"] = duration_s
        data["sample_count"] = len(data["samples"])

        rss_vals = [s["rss"] for s in data["samples"]]
        pss_vals = [s["pss"] for s in data["samples"] if s["pss"] > 0]
        uss_vals = [s["uss"] for s in data["samples"] if s["uss"] > 0]
        swap_vals = [s["swap"] for s in data["samples"]]

        data["peak_rss"] = max(rss_vals)
        data["avg_rss"] = sum(rss_vals) / len(rss_vals) if rss_vals else 0
        data["first_rss"] = rss_vals[0]
        data["last_rss"] = rss_vals[-1]
        data["peak_pss"] = max(pss_vals) if pss_vals else -1
        data["avg_pss"] = sum(pss_vals) / len(pss_vals) if pss_vals else -1
        data["peak_uss"] = max(uss_vals) if uss_vals else -1
        data["avg_uss"] = sum(uss_vals) / len(uss_vals) if uss_vals else -1
        data["peak_swap"] = max(swap_vals) if swap_vals else 0
        data["growth_kb"] = rss_vals[-1] - rss_vals[0]

    return pid_data


def format_kb(v):
    try:
        v = int(v)
    except (ValueError, TypeError):
        return str(v)
    if v >= 1024 * 1024:
        return f"{v / (1024 * 1024):.2f}"
    if v >= 1024:
        return f"{v / 1024:.1f}"
    return str(v)


def fmt_label(kb):
    if kb >= 1024 * 1024:
        return "GB"
    if kb >= 1024:
        return "MB"
    return "KB"


def fmt_pct(ratio, abs_diff_kb=0):
    """Format ratio as percentage or fold."""
    if ratio is None or ratio == float("inf") or ratio == float("-inf"):
        return "—"
    if ratio == 0:
        return "0%"
    # For tiny absolute diffs, show KB rather than misleading ratio
    if abs_diff_kb > 0 and (ratio < 0.9 or ratio > 1.1) and abs_diff_kb < 10 * 1024:
        return f"{'±' if abs_diff_kb < 0 else '+'}{int(abs_diff_kb)}KB"
    if ratio > 2:
        return f"{ratio:.1f}x"
    if ratio > 1:
        return f"+{(ratio - 1) * 100:.0f}%"
    if ratio < 1:
        pct = (1 - ratio) * 100
        if pct > 95:
            return f"{1 / ratio:.1f}x"
        return f"-{pct:.0f}%"
    return "0%"


def main():
    parser = argparse.ArgumentParser(description="Compare symphony memory across two runs")
    parser.add_argument("--run-a", required=True, help="First run output directory")
    parser.add_argument("--run-b", required=True, help="Second run output directory")
    parser.add_argument("--pattern", default="symphony", help="Process pattern to match (default: symphony)")
    parser.add_argument("--top", type=int, default=100, help="Max rows to show (default: 100)")
    parser.add_argument("--csv", default="", help="Output comparison CSV")
    parser.add_argument("--only-common", action="store_true", help="Only show workloads present in both runs")
    args = parser.parse_args()

    for name, d in [("--run-a", args.run_a), ("--run-b", args.run_b)]:
        if not os.path.isdir(d):
            print(f"ERROR: {name} = '{d}' is not a directory", file=sys.stderr)
            sys.exit(1)

    print(f"Loading run-a: {args.run_a}")
    files_a = find_csv_files(args.run_a, "proc_mem.csv")
    data_a = load_proc_csv(files_a, args.pattern)
    print(f"  → {len(data_a)} processes found\n")

    print(f"Loading run-b: {args.run_b}")
    files_b = find_csv_files(args.run_b, "proc_mem.csv")
    data_b = load_proc_csv(files_b, args.pattern)
    print(f"  → {len(data_b)} processes found\n")

    if not data_a or not data_b:
        print("ERROR: one or both runs have no matching data", file=sys.stderr)
        sys.exit(1)

    # Aggregate by label_d (multiple PIDs may share same label)
    def aggregate_by_label(data):
        agg = defaultdict(lambda: {
            "count": 0,
            "sum_peak_rss": 0, "peak_rss": 0, "avg_rss": 0,
            "peak_pss": 0, "avg_pss": 0,
            "peak_uss": 0, "avg_uss": 0,
            "peak_swap": 0, "sum_growth": 0,
        })
        for pid, info in data.items():
            lbl = info["label_d"]
            d = agg[lbl]
            d["count"] += 1
            d["sum_peak_rss"] += info["peak_rss"]
            d["peak_rss"] = max(d["peak_rss"], info["peak_rss"])
            d["avg_rss"] = max(d["avg_rss"], info["avg_rss"])
            d["peak_pss"] = max(d["peak_pss"], info["peak_pss"])
            d["avg_pss"] = max(d["avg_pss"], info["avg_pss"])
            d["peak_uss"] = max(d["peak_uss"], info["peak_uss"])
            d["avg_uss"] = max(d["avg_uss"], info["avg_uss"])
            d["peak_swap"] = max(d["peak_swap"], info["peak_swap"])
            d["sum_growth"] += info["growth_kb"]
        return agg

    label_a = aggregate_by_label(data_a)
    label_b = aggregate_by_label(data_b)

    all_labels = sorted(set(list(label_a.keys()) + list(label_b.keys())))
    common = [l for l in all_labels if l in label_a and l in label_b]

    if args.only_common:
        all_labels = common

    print("=" * 150)
    print(f"{'Workload':<35} {'Run':<6} {'#PIDs':<6} {'PeakRSS':<10} {'AvgRSS':<10} "
          f"{'PeakPSS':<10} {'AvgPSS':<10} {'PeakUSS':<10} {'Growth':<10} {'RSS Chg':<10}")
    print("-" * 150)

    for label in all_labels:
        a = label_a.get(label)
        b = label_b.get(label)

        if a and b:
            # Side by side
            for side, data, chg_marker in [("A", a, True), ("B", b, False)]:
                chg = ""
                if chg_marker and b:
                    ratio = data["peak_rss"] / b["peak_rss"] if b["peak_rss"] > 0 else None
                    chg = fmt_pct(ratio, abs(data["peak_rss"] - b["peak_rss"]))
                else:
                    chg = ""

                print(f"{label:<35} {side:<6} {data['count']:<6} "
                      f"{format_kb(data['peak_rss']):>8}   {format_kb(data['avg_rss']):>8}   "
                      f"{format_kb(data['peak_pss']):>8}   {format_kb(data['avg_pss']):>8}   "
                      f"{format_kb(data['peak_uss']):>8}   {format_kb(data['sum_growth']):>8}   "
                      f"{chg:>8}")

            # Diff row
            if a and b:
                diff_peak = a["peak_rss"] - b["peak_rss"]
                diff_avg = a["avg_rss"] - b["avg_rss"]
                diff_pss = a["peak_pss"] - b["peak_pss"]
                diff_uss = a["peak_uss"] - b["peak_uss"]

                dir_color = "Δ"
                peak_dir = f"{dir_color}{format_kb(abs(diff_peak))}" if diff_peak != 0 else "—"
                avg_dir = f"{dir_color}{format_kb(abs(diff_avg))}" if diff_avg != 0 else "—"

                print(f"{'':<35} {'Δ':<6} {'':<6} "
                      f"{peak_dir:>8}   {avg_dir:>8}   "
                      f"{f'{dir_color}{format_kb(abs(diff_pss))}':>8}   "
                      f"{'':>8}   "
                      f"{f'{dir_color}{format_kb(abs(diff_uss))}':>8}   "
                      f"{'':>8}   "
                      f"{fmt_pct(diff_peak / b['peak_rss'] if b['peak_rss'] > 0 else None, abs(diff_peak))}")
            print()

        elif a:
            print(f"{label:<35} {'A':<6} {a['count']:<6} "
                  f"{format_kb(a['peak_rss']):>8}   {format_kb(a['avg_rss']):>8}   "
                  f"{format_kb(a['peak_pss']):>8}   {format_kb(a['avg_pss']):>8}   "
                  f"{format_kb(a['peak_uss']):>8}   {format_kb(a['sum_growth']):>8}   "
                  f"{'only-A':>8}")
            print()
        elif b:
            print(f"{label:<35} {'B':<6} {b['count']:<6} "
                  f"{format_kb(b['peak_rss']):>8}   {format_kb(b['avg_rss']):>8}   "
                  f"{format_kb(b['peak_pss']):>8}   {format_kb(b['avg_pss']):>8}   "
                  f"{format_kb(b['peak_uss']):>8}   {format_kb(b['sum_growth']):>8}   "
                  f"{'only-B':>8}")
            print()

    print("=" * 150)
    print(f"Totals — A: {len(data_a)} PIDs, B: {len(data_b)} PIDs, common: {len(common)} workloads")
    print()

    # Per-PID detail for common workloads
    print("=" * 120)
    print("Per-PID detail for common workloads:")
    print("=" * 120)

    # Build per-PID comparison
    rows = []
    for label in common:
        a_pids = {pid: info for pid, info in data_a.items() if info["label_d"] == label}
        b_pids = {pid: info for pid, info in data_b.items() if info["label_d"] == label}

        # Match by rank (top N by peak RSS in each run)
        a_sorted = sorted(a_pids.values(), key=lambda x: x["peak_rss"], reverse=True)
        b_sorted = sorted(b_pids.values(), key=lambda x: x["peak_rss"], reverse=True)

        max_len = max(len(a_sorted), len(b_sorted))
        for i in range(max_len):
            a_info = a_sorted[i] if i < len(a_sorted) else None
            b_info = b_sorted[i] if i < len(b_sorted) else None

            a_peak = a_info["peak_rss"] if a_info else None
            b_peak = b_info["peak_rss"] if b_info else None

            if a_peak and b_peak:
                ratio = a_peak / b_peak if b_peak > 0 else None
                chg = fmt_pct(ratio, abs(a_peak - b_peak))
            else:
                chg = "only-A" if a_peak else "only-B"

            rows.append({
                "label": label,
                "rank": i + 1,
                "a_pid": a_info and list(a_pids.keys())[list(a_pids.values()).index(a_info)] if a_info else "—",
                "b_pid": b_info and list(b_pids.keys())[list(b_pids.values()).index(b_info)] if b_info else "—",
                "a_peak_rss": a_peak or 0,
                "b_peak_rss": b_peak or 0,
                "a_avg_rss": int(a_info["avg_rss"]) if a_info else 0,
                "b_avg_rss": int(b_info["avg_rss"]) if b_info else 0,
                "a_peak_pss": a_info["peak_pss"] if a_info else 0,
                "b_peak_pss": b_info["peak_pss"] if b_info else 0,
                "a_peak_uss": a_info["peak_uss"] if a_info else 0,
                "b_peak_uss": b_info["peak_uss"] if b_info else 0,
                "a_growth": a_info["growth_kb"] if a_info else 0,
                "b_growth": b_info["growth_kb"] if b_info else 0,
                "a_samples": a_info["sample_count"] if a_info else 0,
                "b_samples": b_info["sample_count"] if b_info else 0,
                "chg": chg,
            })

    # Sort by peak RSS in run A descending
    rows.sort(key=lambda r: r["a_peak_rss"], reverse=True)

    print(f"{'Workload':<35} {'#':<4} {'PID A':<8} {'PID B':<8} "
          f"{'PeakRSS A':<10} {'PeakRSS B':<10} {'AvgRSS A':<10} {'AvgRSS B':<10} "
          f"{'PeakPSS A':<10} {'PeakPSS B':<10} {'Chg':<10}")
    print("-" * 120)

    for r in rows[:args.top]:
        print(f"{r['label']:<35} {r['rank']:<4} {r['a_pid']:<8} {r['b_pid']:<8} "
              f"{format_kb(r['a_peak_rss']):>8}   {format_kb(r['b_peak_rss']):>8}   "
              f"{format_kb(r['a_avg_rss']):>8}   {format_kb(r['b_avg_rss']):>8}   "
              f"{format_kb(r['a_peak_pss']):>8}   {format_kb(r['b_peak_pss']):>8}   "
              f"{r['chg']:>8}")

    if len(rows) > args.top:
        print(f"... {len(rows) - args.top} more rows (use --top {len(rows)} to show all)")

    print()
    print("Change legend: Nx = fold increase, +N% / -N% = percentage change, — = identical, only-A/B = only in one run")

    # Optional CSV output
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            writer = csv.writer(f, lineterminator="\n")
            writer.writerow([
                "label", "rank", "pid_a", "pid_b",
                "peak_rss_a_kb", "peak_rss_b_kb",
                "avg_rss_a_kb", "avg_rss_b_kb",
                "peak_pss_a_kb", "peak_pss_b_kb",
                "peak_uss_a_kb", "peak_uss_b_kb",
                "growth_a_kb", "growth_b_kb",
                "samples_a", "samples_b",
                "change",
            ])
            for r in rows:
                writer.writerow([
                    r["label"], r["rank"],
                    r["a_pid"], r["b_pid"],
                    r["a_peak_rss"], r["b_peak_rss"],
                    r["a_avg_rss"], r["b_avg_rss"],
                    r["a_peak_pss"], r["b_peak_pss"],
                    r["a_peak_uss"], r["b_peak_uss"],
                    r["a_growth"], r["b_growth"],
                    r["a_samples"], r["b_samples"],
                    r["chg"],
                ])
        print(f"\nComparison CSV written to {args.csv}")


if __name__ == "__main__":
    main()
