#!/usr/bin/env python3

import sys
import csv
from pathlib import Path

KEYS = [
    "hostSeconds",
    "hostInstRate",
    "hostTickRate",
    "simInsts",
    "simTicks",
]

def parse_stats(path):
    values = {}

    with open(path, "r", errors="replace") as f:
        for line in f:
            fields = line.split()

            if len(fields) < 2:
                continue

            key = fields[0]

            if key not in KEYS:
                continue

            try:
                values[key] = float(fields[1])
            except ValueError:
                pass

    return values

def main():
    if len(sys.argv) < 3:
        print(
            "Usage: compare_gem5_stats.py "
            "baseline=stats.txt highload=stats.txt [...]",
            file=sys.stderr,
        )
        sys.exit(1)

    rows = []

    for item in sys.argv[1:]:
        if "=" not in item:
            raise SystemExit(f"Invalid argument: {item}")

        label, path = item.split("=", 1)
        values = parse_stats(path)
        values["label"] = label
        values["path"] = str(Path(path))
        rows.append(values)

    base_inst_rate = rows[0].get("hostInstRate")
    base_tick_rate = rows[0].get("hostTickRate")

    writer = csv.writer(sys.stdout)

    writer.writerow([
        "label",
        "hostSeconds",
        "hostInstRate",
        "hostInstRate_vs_baseline",
        "hostTickRate",
        "hostTickRate_vs_baseline",
        "simInsts",
        "simTicks",
        "path",
    ])

    for row in rows:
        inst_rate = row.get("hostInstRate")
        tick_rate = row.get("hostTickRate")

        inst_ratio = (
            inst_rate / base_inst_rate
            if inst_rate is not None and base_inst_rate
            else ""
        )

        tick_ratio = (
            tick_rate / base_tick_rate
            if tick_rate is not None and base_tick_rate
            else ""
        )

        writer.writerow([
            row["label"],
            row.get("hostSeconds", ""),
            inst_rate if inst_rate is not None else "",
            inst_ratio,
            tick_rate if tick_rate is not None else "",
            tick_ratio,
            row.get("simInsts", ""),
            row.get("simTicks", ""),
            row["path"],
        ])

if __name__ == "__main__":
    main()
