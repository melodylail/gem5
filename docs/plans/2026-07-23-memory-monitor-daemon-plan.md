# Memory Monitor Daemon — TDD Implementation Plan

> **For Hermes:** Use TDD (test-driven-development skill). RED-GREEN-REFACTOR per task.
> Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Build two independent daemons (Bash + Python) that periodically sample system-wide process memory, system memory overview, and kswapd activity to CSV with hourly sharding.

**Architecture:** Both daemons share the same output contract (CSV format, CLI interface, signal behavior). Tests run against fake processes and validate CSV output. Each daemon is a single self-contained file.

**Tech Stack:** Bash 4+, Python 3.10+, psutil, bc, pytest, shell test harness (assert.sh)

**Design Spec:** `docs/superpowers/specs/2026-07-23-memory-monitor-daemon-design.md`

---

## Phase 0: Infrastructure

### Task 0.1: Create directory skeleton

**Objective:** Set up `profiling/monitor/` with env.sh, README stub, test harness.

**Files:**
- Create: `profiling/monitor/env.sh`
- Create: `profiling/monitor/README.md`

**Step 1: Create env.sh**

```bash
cat > profiling/monitor/env.sh << 'ENVEOF'
#!/bin/bash
# profiling/monitor/env.sh — shared environment for mem_daemon.sh and mem_daemon.py
export OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output}"
export INTERVAL_S="${INTERVAL_S:-5}"
export MEM_MODE="${MEM_MODE:-standard}"
export MEM_DURATION_S="${MEM_DURATION_S:-0}"
export MEM_MAX_SAMPLES="${MEM_MAX_SAMPLES:-0}"
export MEM_SLICE_M="${MEM_SLICE_M:-60}"
ENVEOF
chmod +x profiling/monitor/env.sh
```

**Step 2: Verify env.sh syntactically**

Run: `bash -n profiling/monitor/env.sh` → Expected: silent (no syntax error)

**Step 3: Write README stub**

Create `profiling/monitor/README.md` with placeholder content.

**Step 4: Commit**

```bash
git add profiling/monitor/env.sh profiling/monitor/README.md
git commit -m "misc: add memory monitor daemon skeleton"
```

### Task 0.2: Verify fake_gem5 test harness is usable

**Objective:** Confirm the existing `profiling/mem/tests/tools/fake_gem5` builds and runs correctly as a multi-instance test target.

**Step 1: Build fake_gem5**

```bash
cd profiling/mem/tests/tools && bash build_fake_gem5.sh
```

Expected: binary `fake_gem5` created, exit 0.

**Step 2: Run single instance**

```bash
profiling/mem/tests/tools/fake_gem5 10 &
PID=$!
sleep 2
ps -p $PID -o pid,comm,rss --no-headers
kill $PID 2>/dev/null
```

Expected: process with name `fake_gem5`, RSS > 0.

**Step 3: Run 10 concurrent instances**

```bash
for i in $(seq 1 10); do profiling/mem/tests/tools/fake_gem5 30 & done
sleep 2
pgrep -c fake_gem5
killall fake_gem5 2>/dev/null
```

Expected: `pgrep -c` returns 10.

**Step 4: Commit** (only if build artifacts changed)

---

## Phase 1: Bash Daemon — Core Collection

### Task 1.1: RED — Write test for sys_mem.csv header + one sample row (light mode)

**Objective:** Write a test script that runs a stripped-down sys_mem collector for 1 sample and validates CSV schema.

**Files:**
- Create: `profiling/monitor/tests/test_sys_mem.sh`

**Step 1: Write failing test**

```bash
#!/bin/bash
# profiling/monitor/tests/test_sys_mem.sh
# Test: sys_mem.csv schema validation

set -euo pipefail
source profiling/mem/tests/tools/assert.sh
OUTDIR=$(mktemp -d)
trap "rm -rf $OUTDIR" EXIT

# This will fail because mem_daemon.sh doesn't exist yet
bash profiling/monitor/mem_daemon.sh --sys-only --max-samples 1 --output-dir "$OUTDIR" 2>/dev/null

# Verify CSV exists
assert_file_exists "$OUTDIR"/*/sys_mem.csv

# Verify header
HEADER=$(head -1 "$OUTDIR"/*/sys_mem.csv)
assert_contains "$HEADER" "ts_ms"
assert_contains "$HEADER" "memtotal_kb"
assert_contains "$HEADER" "memfree_kb"
assert_contains "$HEADER" "psi_mem_some_avg10"

# Verify exactly 1 data row
DATA_ROWS=$(grep -cv '^#' "$OUTDIR"/*/sys_mem.csv | tail -1 || echo 0)
assert_eq "$DATA_ROWS" "1"

echo "PASS: test_sys_mem"
```

**Step 2: Verify RED**

Run: `bash profiling/monitor/tests/test_sys_mem.sh`
Expected: FAIL — `mem_daemon.sh` not found or exits with error.

**Step 3: Commit test**

```bash
git add profiling/monitor/tests/test_sys_mem.sh
git commit -m "misc: add failing test for sys_mem collector"
```

### Task 1.2: GREEN — Implement sys_mem collection in mem_daemon.sh

**Objective:** Write minimal bash code to collect one sample of system memory stats to CSV.

**Files:**
- Create: `profiling/monitor/mem_daemon.sh`

**Step 1: Implement minimal sys_mem collector**

Write `mem_daemon.sh` skeleton that:
1. Parses `--sys-only`, `--max-samples`, `--output-dir` from CLI
2. Creates output directory with hourly timestamp
3. Writes CSV header to `sys_mem.csv`
4. Reads `/proc/meminfo`, `/proc/vmstat`, `/proc/pressure/memory`
5. Writes one data row
6. Exits

**Step 2: Run test**

```bash
bash profiling/monitor/tests/test_sys_mem.sh
```

Expected: PASS.

**Step 3: Run bash syntax check**

```bash
bash -n profiling/monitor/mem_daemon.sh
```

Expected: silent.

**Step 4: Commit**

```bash
git add profiling/monitor/mem_daemon.sh
git commit -m "misc: implement sys_mem collection in mem_daemon.sh"
```

### Task 1.3: RED — Write test for proc_mem.csv (light mode)

**Objective:** Test that the daemon can list all running processes and sample their RSS/VSZ.

**Files:**
- Create: `profiling/monitor/tests/test_proc_mem_light.sh`

**Step 1: Write failing test**

Test script that:
1. Launches 3 fake_gem5 instances
2. Runs `mem_daemon.sh --proc-only --mode light --max-samples 1`
3. Validates `proc_mem.csv` header and row count ≥ 3
4. Validates `mode` column = `light`
5. Validates `pss_kb` = `-1` (light mode doesn't collect)

**Step 2: Verify RED**

Run: `bash profiling/monitor/tests/test_proc_mem_light.sh`
Expected: FAIL.

**Step 3: Commit**

```bash
git add profiling/monitor/tests/test_proc_mem_light.sh
git commit -m "misc: add failing test for proc_mem collection (light mode)"
```

### Task 1.4: GREEN — Implement proc_mem collection (light mode)

**Objective:** Add process iteration and light-mode sampling to mem_daemon.sh.

**Step 1: Implement process iteration**

Add to `mem_daemon.sh`:
1. Parse `--proc-only`, `--mode`
2. Loop over `/proc/[0-9]*/`
3. Read `status` (Name, State, VmRSS, VmSize, Threads), `stat` (ppid, utime, stime, starttime)
4. Write one CSV row per process
5. Light mode: pss_kb=-1, uss_kb=-1, swap_kb=-1, cmdline=""

**Step 2: Run light mode test**

```bash
bash profiling/monitor/tests/test_proc_mem_light.sh
```

Expected: PASS.

**Step 3: Commit**

```bash
git commit -am "misc: implement proc_mem light-mode collection in mem_daemon.sh"
```

### Task 1.5: RED — Write test for proc_mem standard mode (PSS/USS/VmSwap/cmdline)

**Files:**
- Create: `profiling/monitor/tests/test_proc_mem_standard.sh`

**Step 1: Write test**

Validates:
1. `pss_kb` > 0, `uss_kb` > 0 (standard mode reads smaps_rollup)
2. `swap_kb` ≥ 0
3. `cmdline` not empty for fake_gem5
4. `mode` = `standard`

**Step 2: Verify RED**
**Step 3: Commit**

### Task 1.6: GREEN — Implement standard mode

**Step 1:** Add smaps_rollup parsing, VmSwap from status, cmdline from /proc/pid/cmdline.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 1.7: RED — Write test for proc_mem detailed mode (smaps_rollup full breakdown)

**Files:**
- Create: `profiling/monitor/tests/test_proc_mem_detailed.sh`

**Step 1: Write test**

Validates detailed mode adds extra columns (anon_kb, file_kb from smaps_rollup).

**Step 2: Verify RED**
**Step 3: Commit**

### Task 1.8: GREEN — Implement detailed mode

**Step 1:** Add Anon/File/Swap breakdown from smaps_rollup to CSV.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 1.9: RED — Write test for kswapd.csv

**Files:**
- Create: `profiling/monitor/tests/test_kswapd.sh`

**Step 1: Write test**

Validates:
1. kswapd.csv has correct header columns
2. If kswapd is running: at least one row with valid PID, state, wchan
3. If kswapd is not running: sentinel row `ts_ms,-,-,-,-,-,-,-`

**Step 2: Verify RED**
**Step 3: Commit**

### Task 1.10: GREEN — Implement kswapd collection

**Step 1:** Add `collect_kswapd()`: pgrep kswapd, read /proc/pid/stat, /proc/pid/wchan, /proc/pid/stack (needs root, graceful degrade).
**Step 2:** Run test → PASS.
**Step 3:** Commit.

---

## Phase 2: Bash Daemon — Runtime Logic

### Task 2.1: RED — Write test for hourly slice rotation

**Files:**
- Create: `profiling/monitor/tests/test_slice_rotation.sh`

**Step 1: Write test**

1. Set `--slice-minutes 1` (1-minute slices for test speed)
2. Run daemon for 90 seconds with `--max-samples 0 --duration 90`
3. Verify at least 2 subdirectories created
4. Verify each subdirectory has its own sys_mem.csv

**Step 2: Verify RED**
**Step 3: Commit**

### Task 2.2: GREEN — Implement slice rotation

**Step 1:** Add logic: before each sample, check if wall clock has crossed slice boundary; if so, close current files, `mkdir -p` new directory, write new headers.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 2.3: RED — Write test for signal handling

**Files:**
- Create: `profiling/monitor/tests/test_signals.sh`

**Step 1: Write test**

1. Start daemon in background with `--max-samples 0 --duration 300` (long enough)
2. Send SIGUSR1 → verify an extra row appears beyond normal interval
3. Send SIGTERM → verify daemon exits cleanly (exit 0), CSV file not truncated

**Step 2: Verify RED**
**Step 3: Commit**

### Task 2.4: GREEN — Implement signal handling

**Step 1:** Add `trap` for SIGTERM/SIGINT (graceful exit) and SIGUSR1 (extra sample).
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 2.5: RED — Write test for PID reuse guard

**Files:**
- Create: `profiling/monitor/tests/test_pid_reuse.sh`

**Step 1: Write test**

1. Start a fake_gem5, record its PID
2. Kill it, immediately start a new unrelated process (may get same PID)
3. Verify daemon detects starttime change and writes `exited` row

**Step 2: Verify RED**
**Step 3: Commit**

### Task 2.6: GREEN — Implement PID reuse guard

**Step 1:** Cache starttime per PID, compare on each sample.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 2.7: Integration test — Full daemon run

**Files:**
- Create: `profiling/monitor/tests/test_full_bash.sh`

**Step 1: Write test**

1. Launch 10 fake_gem5 over 60 seconds
2. Run daemon with `--mode standard --interval 2 --duration 60`
3. Verify: all 3 CSV files exist, proc_mem has rows for fake_gem5, sys_mem has expected columns, kswapd has valid output
4. CPU usage of daemon during run < 5% (check via /proc)

**Step 2:** Run test → PASS.

### Task 2.8: REFACTOR — Extract shared functions

Review `mem_daemon.sh` for duplication. Extract helpers: `write_csv_header()`, `slice_dir()`, `sample_timestamp()`. Re-run all tests.

---

## Phase 3: Python Daemon — Core Collection

### Task 3.1: RED — Write test for sys_mem collector (Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_sys_mem.py`

**Step 1: Write pytest test**

```python
import subprocess, csv, tempfile, os

def test_sys_mem_header_and_one_row():
    outdir = tempfile.mkdtemp()
    subprocess.run([
        "python3", "profiling/monitor/mem_daemon.py",
        "--sys-only", "--max-samples", "1",
        "--output-dir", outdir
    ], check=True, capture_output=True)

    csv_files = list(Path(outdir).rglob("sys_mem.csv"))
    assert len(csv_files) == 1

    with open(csv_files[0]) as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    assert len(rows) == 1
    assert "memtotal_kb" in reader.fieldnames
    assert int(rows[0]["memtotal_kb"]) > 0
```

**Step 2: Verify RED** → FAIL (mem_daemon.py does not exist).

**Step 3: Commit**

### Task 3.2: GREEN — Implement sys_mem in mem_daemon.py

**Step 1:** Create `mem_daemon.py` skeleton: argparse CLI, sys_mem sampling via psutil + /proc reads, CSV output with hourly sharding.

**Step 2:** Run: `pytest profiling/monitor/tests/test_python_sys_mem.py -v` → PASS.

**Step 3:** Commit.

### Task 3.3: RED — Write test for proc_mem (standard mode, Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_proc_mem.py`

**Step 1: Write test** (similar pattern: launch fake_gem5, run --proc-only, validate CSV).

**Step 2: Verify RED**
**Step 3: Commit**

### Task 3.4: GREEN — Implement proc_mem in Python

**Step 1:** Add process iteration via `psutil.process_iter()`, standard mode fields.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 3.5: RED — Write test for all 3 modes (Python)

**Files:**
- Modify: `profiling/monitor/tests/test_python_proc_mem.py`

Add parameterized tests: light mode (pss=-1, uss=-1), standard (pss>0), detailed (extra fields).

**Step 2: Verify RED** → some modes fail.
**Step 3: Commit**

### Task 3.6: GREEN — Implement light and detailed modes in Python

**Step 1:** Conditional fields per mode.
**Step 2:** Run all three modes → PASS.
**Step 3:** Commit.

### Task 3.7: RED — Write test for kswapd (Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_kswapd.py`

**Step 2: Verify RED**
**Step 3: Commit**

### Task 3.8: GREEN — Implement kswapd in Python

**Step 1:** `psutil.process_iter()` filtered by name `^kswapd`, read wchan/stack.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

---

## Phase 4: Python Daemon — Runtime Logic

### Task 4.1: RED — Write test for hourly slice rotation (Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_slice.py`

**Step 2: Verify RED**
**Step 3: Commit**

### Task 4.2: GREEN — Implement slice rotation (Python)

**Step 1:** Same logic as bash: wall-clock boundary detection, mkdir + new headers.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 4.3: RED — Write test for signal handling (Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_signals.py`

**Step 2: Verify RED**
**Step 3: Commit**

### Task 4.4: GREEN — Implement signal handling (Python)

**Step 1:** `signal.signal(SIGTERM, handler)`, `signal.signal(SIGUSR1, handler)`.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 4.5: RED — Write test for --daemonize (Python)

**Files:**
- Create: `profiling/monitor/tests/test_python_daemonize.py`

**Step 1: Write test**

1. Run `mem_daemon.py --daemonize --max-samples 3 --interval 1`
2. Verify parent exits immediately (before child finishes 3 samples)
3. Wait for child, verify CSV has exactly 3 rows

**Step 2: Verify RED**
**Step 3: Commit**

### Task 4.6: GREEN — Implement --daemonize

**Step 1:** `os.fork()` double-fork, close stdio, redirect to /dev/null.
**Step 2:** Run test → PASS.
**Step 3:** Commit.

### Task 4.7: Integration test — Full Python daemon run

**Files:**
- Create: `profiling/monitor/tests/test_full_python.py`

Same pattern as bash integration test (Task 2.7). 10 fake_gem5, 60s, validate all CSVs.

---

## Phase 5: Cross-Validation

### Task 5.1: Side-by-side comparison test

**Files:**
- Create: `profiling/monitor/tests/test_cross_validation.sh`

**Step 1: Write test**

1. Launch 5 fake_gem5
2. Run bash daemon (`--max-samples 3`) and python daemon (`--max-samples 3`) simultaneously
3. Diff `sys_mem.csv` from both: same columns, values within 5%
4. Diff `proc_mem.csv` from both: same PIDs, RSS within ±5%

**Step 2:** Run test → PASS.

### Task 5.2: Stress test — 500 processes

**Files:**
- Create: `profiling/monitor/tests/test_stress.sh`

**Step 1: Write test**

1. Launch 500 fake_gem5 instances
2. Run python daemon for 30 seconds
3. Verify: daemon does not OOM, exit code 0, proc_mem.csv has rows for most fake_gem5 PIDs
4. Verify daemon CPU < 5% during run

**Step 2:** Run test → PASS.

---

## Phase 6: Polish

### Task 6.1: Update README.md with full usage docs

**Files:**
- Modify: `profiling/monitor/README.md`

**Step 1:** Write comprehensive README covering:
- Quickstart (both daemons)
- CLI reference table
- CSV format reference
- Testing instructions
- Relationship to other profiling tools

**Step 2:** Commit.

### Task 6.2: Final test suite run

```bash
# Bash tests
for t in profiling/monitor/tests/test_*.sh; do echo "=== $t ===" && bash "$t"; done

# Python tests
pytest profiling/monitor/tests/test_*.py -v
```

All tests must pass.

---

## Task Summary

| Phase | Tasks | Est. Time |
|-------|-------|-----------|
| 0: Infrastructure | 0.1, 0.2 | 10 min |
| 1: Bash core collection | 1.1–1.10 | 60 min |
| 2: Bash runtime logic | 2.1–2.8 | 45 min |
| 3: Python core collection | 3.1–3.8 | 50 min |
| 4: Python runtime logic | 4.1–4.7 | 35 min |
| 5: Cross-validation | 5.1, 5.2 | 20 min |
| 6: Polish | 6.1, 6.2 | 10 min |
| **Total** | **29 tasks** | **~4 hours** |
