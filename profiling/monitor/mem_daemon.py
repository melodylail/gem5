#!/usr/bin/env python3
"""
profiling/monitor/mem_daemon.py
Background daemon: periodic system-wide memory + process + kswapd monitoring.

Design spec: docs/superpowers/specs/2026-07-23-memory-monitor-daemon-design.md
"""

import argparse
import csv
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import psutil
except ImportError:
    print("ERROR: psutil is required. Install: pip install psutil", file=sys.stderr)
    sys.exit(1)

logger = logging.getLogger("mem_daemon")

# ---------------------------------------------------------------------------
# CSV Schemas
# ---------------------------------------------------------------------------
SYS_MEM_HEADER = [
    "ts_ms", "wall_clock", "memtotal_kb", "memfree_kb", "memavailable_kb",
    "cached_kb", "buffers_kb", "anonpages_kb", "dirty_kb",
    "swaptotal_kb", "swapfree_kb",
    "pgscan_kswapd", "pgsteal_kswapd", "pgscan_direct", "pgsteal_direct",
    "compact_stall", "allocstall_normal",
    "psi_mem_some_avg10", "psi_mem_full_avg10", "psi_io_some_avg10",
]

PROC_MEM_HEADER = [
    "ts_ms", "wall_clock", "pid", "comm", "state", "threads",
    "rss_kb", "vsz_kb", "pss_kb", "uss_kb", "swap_kb",
    "cpu_percent", "cmdline", "mode",
]

KSWAPD_HEADER = [
    "ts_ms", "wall_clock", "pid", "comm", "state", "cpu_percent",
    "rss_kb", "wchan", "stack",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def mono_ms() -> int:
    return int(time.monotonic() * 1000)


def wall_clock() -> str:
    import subprocess
    try:
        return subprocess.check_output(["date", "--iso-8601=seconds"], text=True).strip()
    except Exception:
        return datetime.now().replace(microsecond=0).isoformat()


def get_slice_dir(output_dir: str, wall: str, slice_minutes: int) -> str:
    """YYYY-MM-DD_HH slice directory."""
    ymd_h = wall[:13].replace("T", "_")
    return os.path.join(output_dir, ymd_h)


def ensure_csv(slice_dir: str, filename: str, header: list) -> str:
    """Create slice dir and CSV file with header if not present."""
    os.makedirs(slice_dir, exist_ok=True)
    csv_path = os.path.join(slice_dir, filename)
    if not os.path.exists(csv_path):
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f, lineterminator="\n")
            writer.writerow(header)
    return csv_path


def parse_meminfo() -> dict:
    """Parse /proc/meminfo into a dict of kB values."""
    result = {}
    keys = [
        "MemTotal", "MemFree", "MemAvailable", "Cached", "Buffers",
        "AnonPages", "Dirty", "SwapTotal", "SwapFree",
    ]
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split(":")
            if len(parts) < 2:
                continue
            key = parts[0]
            if key not in keys:
                continue
            val = parts[1].strip().split()[0]  # "12345 kB" -> "12345"
            result[key.lower() + "_kb"] = int(val)
    return result


def parse_vmstat() -> dict:
    """Parse /proc/vmstat for specific counters."""
    result = {}
    keys = [
        "pgscan_kswapd", "pgsteal_kswapd", "pgscan_direct", "pgsteal_direct",
        "compact_stall", "allocstall_normal",
    ]
    with open("/proc/vmstat") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            if parts[0] in keys:
                result[parts[0]] = int(parts[1])
    return result


def parse_psi(path: str) -> dict:
    """Parse /proc/pressure/<resource> for avg10 values."""
    result = {}
    if not os.path.exists(path):
        return result
    with open(path) as f:
        for line in f:
            if line.startswith("some"):
                for token in line.split():
                    if token.startswith("avg10="):
                        result["some_avg10"] = float(token.split("=")[1])
            elif line.startswith("full"):
                for token in line.split():
                    if token.startswith("avg10="):
                        result["full_avg10"] = float(token.split("=")[1])
    return result


# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------
def collect_sys_mem(csv_path: str):
    ts = mono_ms()
    wall = wall_clock()

    mem = parse_meminfo()
    vm = parse_vmstat()
    psi_mem = parse_psi("/proc/pressure/memory")
    psi_io = parse_psi("/proc/pressure/io")

    row = [
        ts, wall,
        mem.get("memtotal_kb", 0),
        mem.get("memfree_kb", 0),
        mem.get("memavailable_kb", 0),
        mem.get("cached_kb", 0),
        mem.get("buffers_kb", 0),
        mem.get("anonpages_kb", 0),
        mem.get("dirty_kb", 0),
        mem.get("swaptotal_kb", 0),
        mem.get("swapfree_kb", 0),
        vm.get("pgscan_kswapd", 0),
        vm.get("pgsteal_kswapd", 0),
        vm.get("pgscan_direct", 0),
        vm.get("pgsteal_direct", 0),
        vm.get("compact_stall", 0),
        vm.get("allocstall_normal", 0),
        psi_mem.get("some_avg10", 0.0),
        psi_mem.get("full_avg10", 0.0),
        psi_io.get("some_avg10", 0.0),
    ]

    with open(csv_path, "a", newline="") as f:
        csv.writer(f, lineterminator="\n").writerow(row)


def collect_proc_mem(csv_path: str, mode: str):
    ts = mono_ms()
    wall = wall_clock()

    with open(csv_path, "a", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")

        for proc in psutil.process_iter(["pid", "name", "status", "memory_info",
                                          "num_threads", "cpu_times", "cmdline"]):
            try:
                pinfo = proc.info
                pid = pinfo["pid"]
                comm = pinfo["name"] or ""
                state = (pinfo["status"] or "?")[0]  # first char
                threads = pinfo["num_threads"] or 0
                rss = (pinfo["memory_info"].rss if pinfo["memory_info"] else 0) // 1024
                vsz = (pinfo["memory_info"].vms if pinfo["memory_info"] else 0) // 1024
                cpu_times = pinfo["cpu_times"]
                cpu_pct = (cpu_times.user + cpu_times.system) if cpu_times else 0.0

                if mode == "light":
                    pss = -1
                    uss = -1
                    swap_kb = -1
                    cmdline = ""
                else:
                    # Standard / detailed: get extended memory info
                    try:
                        mem_full = proc.memory_full_info()
                        pss = mem_full.pss // 1024 if mem_full.pss is not None else -1
                        uss = mem_full.uss // 1024 if mem_full.uss is not None else -1
                        swap_kb = mem_full.swap // 1024 if getattr(mem_full, 'swap', None) else 0  # noqa
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pss = -1
                        uss = -1
                        swap_kb = -1

                    try:
                        cmdline = " ".join(proc.cmdline())
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        cmdline = ""

                writer.writerow([
                    ts, wall, pid, comm, state, threads,
                    rss, vsz, pss, uss, swap_kb,
                    round(cpu_pct, 1), cmdline, mode,
                ])
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue


def collect_kswapd(csv_path: str):
    ts = mono_ms()
    wall = wall_clock()
    found = False

    def read_wchan(pid: int) -> str:
        try:
            with open(f"/proc/{pid}/wchan") as f:
                return f.read().strip()
        except Exception:
            return ""

    def read_stack(pid: int) -> str:
        try:
            with open(f"/proc/{pid}/stack") as f:
                return "|".join(line.strip() for line in f)
        except Exception:
            return "requires_root"

    with open(csv_path, "a", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        for proc in psutil.process_iter(["pid", "name", "status",
                                          "memory_info", "cpu_times"]):
            try:
                name = proc.info["name"]
                if not name or not name.startswith("kswapd"):
                    continue
                found = True
                pid = proc.info["pid"]
                state = (proc.info["status"] or "?")[0]
                rss = (proc.info["memory_info"].rss if proc.info["memory_info"] else 0) // 1024
                cpu_times = proc.info["cpu_times"]
                cpu_pct = (cpu_times.user + cpu_times.system) if cpu_times else 0.0
                wchan = read_wchan(pid)
                stack = read_stack(pid)
                writer.writerow([
                    ts, wall, pid, name, state, round(cpu_pct, 1),
                    rss, wchan, stack,
                ])
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        if not found:
            writer.writerow([ts, wall, "-", "-", "-", "-", "-", "-", "-"])


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
signal_received = None
extra_sample = False


def on_signal(sig, frame):
    global signal_received, extra_sample
    if sig in (signal.SIGTERM, signal.SIGINT):
        signal_received = sig
    elif sig == signal.SIGUSR1:
        extra_sample = True


# ---------------------------------------------------------------------------
# Daemonize
# ---------------------------------------------------------------------------
def daemonize():
    """Double-fork to background."""
    pid = os.fork()
    if pid > 0:
        sys.exit(0)
    os.setsid()
    pid = os.fork()
    if pid > 0:
        sys.exit(0)
    os.chdir("/")
    os.umask(0)
    # Redirect stdio
    with open("/dev/null", "r") as devnull:
        os.dup2(devnull.fileno(), sys.stdin.fileno())
    with open("/dev/null", "w") as devnull:
        os.dup2(devnull.fileno(), sys.stdout.fileno())
        os.dup2(devnull.fileno(), sys.stderr.fileno())


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global extra_sample, signal_received

    parser = argparse.ArgumentParser(description="Memory monitor daemon")
    parser.add_argument("--interval", type=float, default=5, help="Sample interval in seconds (default: 5)")
    parser.add_argument("--output-dir", default="./output", help="Output root directory")
    parser.add_argument("--mode", choices=["light", "standard", "detailed"], default="standard")
    parser.add_argument("--duration", type=int, default=0, help="Total runtime in seconds (0=forever)")
    parser.add_argument("--max-samples", type=int, default=0, help="Max samples (0=unlimited)")
    parser.add_argument("--slice-minutes", type=int, default=60, help="Directory slice interval in minutes")
    parser.add_argument("--daemonize", action="store_true", help="Daemonize (double-fork)")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    parser.add_argument("--sys-only", action="store_true")
    parser.add_argument("--proc-only", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stderr)],
    )

    if args.daemonize:
        daemonize()
        # Reconfigure logging to file after daemonize
        log_path = os.path.join(args.output_dir, "mem_monitor.log")
        logging.basicConfig(
            level=getattr(logging, args.log_level),
            format="%(asctime)s [%(levelname)s] %(message)s",
            handlers=[logging.FileHandler(log_path)],
        )

    full_mode = not args.sys_only and not args.proc_only

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        signal.signal(signal.SIGUSR1, on_signal)
    except AttributeError:
        pass  # SIGUSR1 not available on this platform

    sample_count = 0
    current_slice_dir = ""
    end_ts = time.time() + args.duration if args.duration > 0 else 0

    logger.info(f"Starting daemon: mode={args.mode}, interval={args.interval}s, output={args.output_dir}")

    while True:
        # Handle SIGUSR1 extra sample
        if extra_sample:
            extra_sample = False
            sample_count += 1
            continue  # extra sample will be taken below

        wall = wall_clock()
        slice_dir = get_slice_dir(args.output_dir, wall, args.slice_minutes)

        if slice_dir != current_slice_dir:
            current_slice_dir = slice_dir

        # Collect system memory
        if full_mode or args.sys_only:
            csv_p = ensure_csv(current_slice_dir, "sys_mem.csv", SYS_MEM_HEADER)
            collect_sys_mem(csv_p)

        # Collect process memory
        if full_mode or args.proc_only:
            csv_p = ensure_csv(current_slice_dir, "proc_mem.csv", PROC_MEM_HEADER)
            collect_proc_mem(csv_p, args.mode)

        # Collect kswapd
        if full_mode:
            csv_p = ensure_csv(current_slice_dir, "kswapd.csv", KSWAPD_HEADER)
            collect_kswapd(csv_p)

        sample_count += 1

        # Check termination
        if signal_received is not None:
            logger.info(f"Received signal {signal_received}, exiting")
            sys.exit(0)

        if args.max_samples > 0 and sample_count >= args.max_samples:
            break

        if end_ts and time.time() >= end_ts:
            break

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
