# Design: Memory Usage Trend Evaluation for `gem5.opt`

- **Date:** 2026-07-09
- **Branch:** `perf-profiling`
- **Related work:** `profiling/run.sh`, `profiling/analyze.sh`, `docs/Gem5 高并发仿真性能衰减排查与评估指南.md`
- **Status:** Design approved, awaiting spec review before implementation planning.

## 1. Motivation & scope

The `perf-profiling` branch already ships a two-layer profiling pipeline for
`gem5.opt` (Layer 1 `perf stat`, Layer 2 `perf record` + flamegraph). The
accompanying investigation guide covers *why* Gem5 slows down under high
host-memory concurrency (bandwidth saturation, NUMA, LLC thrash, THP,
disk I/O) but does not provide a first-class mechanism to **evaluate how a
single `gem5.opt` process's host memory footprint evolves over its own
lifetime** — the missing signal for leak detection, baseline capture, and
regression gating.

This design adds that capability as a self-contained **Layer 3: memory
trend** inside the same `profiling/` tree, without touching gem5 source and
without disturbing existing Layer 1 / Layer 2 flows.

### Scope

In scope:

- Single-process, single-run wall-time series of host memory for one
  `gem5.opt` invocation.
- Coarse always-on sidecar sampling (RSS / PSS / USS / heap breakdown via
  `/proc/<pid>/smaps_rollup`).
- Deep on-demand allocation attribution via `heaptrack`.
- Post-run analyzer that correlates the memory series with gem5's own
  `stats.txt`, renders a plot, produces a markdown report and a metrics
  JSON, and evaluates a threshold policy that can gate CI / regression
  runs.
- Full CLI / env / YAML / built-in-default precedence chain for every
  configurable knob.

Out of scope for v1:

- Multi-process aggregation across concurrent LSF jobs (the sidecar is
  designed to attach to any single PID; multi-job dashboards are a follow-up).
- Cross-version comparison workflows (single-run output is the input to
  those; they are a separate spec).
- Gem5-internal instrumentation (getrusage hooks, stats.txt entries).
  Explicitly rejected — see §7.
- Sub-100 ms sampling intervals.
- Non-Linux hosts. `/proc/*/smaps_rollup` is Linux-only; the tool is
  Linux-only by design.

## 2. Architecture

Everything lives in `profiling/` alongside the existing scripts; three
cooperating pieces, all opt-in via environment variables so existing users of
`run.sh` see no change until they set `MEM_TREND=1`.

```
profiling/
├── mem/
│   ├── mem_sample.sh        # sidecar launcher + /proc sampler (bash)
│   ├── analyze_mem.py       # CSV × stats.txt → metrics, plot, gate
│   ├── deep_run.sh          # heaptrack wrapper for on-demand deep mode
│   └── mem_thresholds.yaml  # policy: peak_rss_mb, leak_bps, warmup_seconds
└── run.sh                   # existing; gains a Layer 3 hook
```

Data flow:

```
gem5.opt (PID P) ──┐
                   ├── mem_sample.sh polls /proc/P/smaps_rollup every INTERVAL_S
                   │       → output/mem_trend.csv
gem5 exits ────────┘        (ts,rss,pss,uss,heap,anon,file,swap,gem5_phase)
                   ↓
              analyze_mem.py
              ├── reads output/mem_trend.csv
              ├── reads output/stats.txt   (sim_insts, host_seconds, sim_seconds)
              ├── computes metrics + renders output/mem_trend.png
              ├── writes output/mem_report.md, output/mem_metrics.json
              └── evaluates mem_thresholds.yaml → exit 0 | 1 | 2
```

Deep mode is a physically separate invocation (`deep_run.sh`) that produces
its own `heaptrack.*.gz`. It never runs alongside the sidecar — heaptrack's
2–10× slowdown would dominate the coarse curve. The analyzer opportunistically
appends a heaptrack top-allocators section to the same report when
`--heaptrack` is supplied.

## 3. Components

### 3.1 `mem_sample.sh` — sidecar sampler

Bash script; single responsibility: launch (or attach to) gem5 and, in
parallel, write timestamped memory samples until it exits.

Contract:

- **Inputs:** env / CLI / positional gem5 argv (see §5 for full knob list).
- **Outputs:**
  - `output/mem_trend.csv` — timestamped samples with a
    `# `-prefixed provenance header (host, kernel, pid, interval, gem5_cmd,
    start_wall, tag).
  - `output/mem_sample.log` — sampler diagnostics.
- **Lifecycle (spawn mode):** `exec gem5.opt … &` → capture `$PID` and
  `/proc/$PID/starttime` → loop reading `/proc/$PID/smaps_rollup` until the
  PID exits or its `starttime` changes (PID-reuse guard) → forward gem5's
  exit code.
- **Lifecycle (attach mode):** identical, but no fork; `$PID` supplied by
  `--pid`. Exit code semantics differ; see §5.
- **Fallback:** if `smaps_rollup` is unreadable (kernel <4.14, hardened
  kernels), fall back to `/proc/$PID/status` for RSS/VmSize; PSS/USS/heap
  columns filled with `-1` and header notes `smaps_rollup_unavailable: true`.
- **Signal handling (spawn mode):** SIGINT/SIGTERM forwarded to gem5, waits
  for exit, flushes CSV, exits 130/143.
- **Signal handling (attach mode):** SIGINT/SIGTERM exits sampler cleanly,
  target left running.
- **Overhead:** ~50 µs per sample; <1 % of wall time at any interval ≥ 0.1 s.

The bash choice is deliberate: keeps host-side dependencies to `awk` +
coreutils (matches existing `profiling/*.sh` scripts) and avoids a Python
process that itself allocates while measuring another process's allocations.

### 3.2 `analyze_mem.py` — post-run analyzer + gate

Single-file Python 3.8+ script. Dependencies: stdlib, `matplotlib`, `pyyaml`
(both present in gem5's `requirements.txt`).

Contract:

- **Inputs:** CSV, optional `stats.txt`, optional policy YAML, optional
  heaptrack glob. All paths follow the precedence chain in §5.
- **Outputs:**
  - `output/mem_metrics.json` — computed metrics + effective config.
  - `output/mem_report.md` — human-readable report with the "Effective
    configuration" table (values tagged by source: `cli` / `env` / `yaml` /
    `default`), metrics table, plot embed, gate verdict, and — when
    `--heaptrack` is present — top-10 allocators.
  - `output/mem_trend.png` — RSS + PSS + heap over time, shaded warmup
    region, horizontal lines at policy thresholds.
- **Computed metrics:**
  - `peak_rss_kb`, `peak_pss_kb`, `final_rss_kb`.
  - `warmup_end_s` (from policy, default 30 s).
  - `growth_rate_kb_per_s_post_warmup` — linear regression slope on RSS
    after warmup; `null` if fewer than `min_regression_samples` post-warmup
    samples.
  - `rss_per_msim_inst_kb` — `(peak_rss - baseline_rss) / (sim_insts / 1e6)`
    when `stats.txt` present.
  - Per-segment slopes when the CSV contains `# segment_start:` markers.
- **Gate:** for each threshold present in the effective config, compare and
  log PASS / FAIL. Exit code follows §4.4.

Pure-function seam: `compute_metrics(samples, stats) -> dict` is where unit
tests hook in.

### 3.3 `deep_run.sh` — on-demand heap attribution

Thin wrapper: `exec heaptrack -o "$OUTPUT_DIR/$PREFIX" "$GEM5_BUILD" "$@"`.

- Requires `heaptrack` on PATH; prints an install hint
  (`apt install heaptrack` / `dnf install heaptrack`) and exits 127 if
  missing.
- Explicitly **does not** support `--pid` (heaptrack is an LD_PRELOAD
  allocator interposer; attach-to-running is impossible with it — documented
  in `--help`).
- Never runs alongside the sidecar.

### 3.4 `mem_thresholds.yaml` — policy

Fully optional; a project can commit per-workload policies under
`profiling/mem/policies/<workload>.yaml` and pass them via
`--policy` / `MEM_POLICY_YAML`.

```yaml
warmup_seconds: 30
peak_rss_mb: 8192              # fail if peak RSS exceeds this
leak_bytes_per_sec: 524288     # fail if post-warmup growth exceeds this
rss_per_msim_inst_kb: null     # null == "computed, but no threshold"
require_stats_txt: false
min_regression_samples: 5
fail_mode: summary             # 'summary' | 'fast'
```

Additive semantics: unknown keys warn and are ignored, so new analyzer
versions stay backwards-compatible with policies written for older analyzers.

### 3.5 `profiling/run.sh` integration

One added block, gated on `MEM_TREND=1`, that runs alongside the existing
layers:

```bash
if [ "${MEM_TREND:-0}" = "1" ]; then
  echo "=== Layer 3: memory trend (sidecar) ==="
  "$SCRIPT_DIR/mem/mem_sample.sh" \
      --output-dir "$OUTPUT_DIR" \
      --tag "${MEM_RUN_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo untagged)}" \
      -- "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
      --binary "$WORKLOAD_BIN" --output-dir "$OUTPUT_DIR"
  python3 "$SCRIPT_DIR/mem/analyze_mem.py" \
      --csv "$OUTPUT_DIR/mem_trend.csv" \
      --stats "$OUTPUT_DIR/stats.txt" \
      --policy "$SCRIPT_DIR/mem/mem_thresholds.yaml"
fi
```

Deep mode is a standalone invocation the user runs manually when the coarse
curve flags something worth investigating.

## 4. Data flow, timing, and error handling

### 4.1 Sampler happy path (spawn mode)

```
t0: mem_sample.sh starts, records t0_wall (CLOCK_REALTIME) and
    t0_mono (CLOCK_MONOTONIC). Forks gem5.opt as background child,
    captures $PID.
t0..tN: every INTERVAL_S seconds, reads /proc/$PID/smaps_rollup atomically;
        one row per sample; ts_ms = (now_mono - t0_mono) * 1000.
tN: gem5 exits with code E. Sampler writes a final row with a flush marker,
    closes CSV, exits with code E.
tN+ε: run.sh invokes analyze_mem.py.
```

Two design decisions worth naming:

- **Monotonic clock for the `ts_ms` column; wall clock recorded once in the
  header comment.** Wall-clock jumps (NTP, DST) don't distort growth-rate
  math; the header still lets the report say when the run happened.
- **"Read then sleep", not "sleep then read".** The first sample captures
  gem5 immediately after fork/exec so initial RSS reflects a real startup
  baseline.

### 4.2 CSV shape

```
# gem5_cmd: build/ALL/gem5.opt configs/se_profile.py --binary …
# start_wall: 2026-07-09T14:03:11+08:00
# interval_s: 1
# pid: 48211
# host: hostname, kernel: 6.8.0-…, page_size: 4096
# tag: <optional run label>
# attached: false                          # true in --pid mode
# segment_start: 2026-07-09T14:03:11+08:00 # appears once per --append segment
ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase
0,42116,41870,41200,15360,26756,15360,0,unknown
1000,68432,67901,66800,38912,29520,15360,0,unknown
…
```

Header comments are `# `-prefixed so standard CSV readers skip them
trivially; the analyzer parses them to reconstruct provenance.

### 4.3 Stats.txt reading

- **Read:** `sim_insts` (aliased `simInsts` in some gem5 versions),
  `host_seconds` (`hostSeconds`), `sim_seconds` (`simSeconds`).
- **On multiple dumps:** use the final dump (last `End Simulation Statistics`
  block).
- **On missing keys:** log warning; corresponding metrics become `null`.
- **Not read (out of scope for v1):** `config.ini`, `config.json`, gem5
  stdout/stderr.

### 4.4 Failure modes & exit codes

| Component | Scenario | Behavior |
|---|---|---|
| Sampler | Gem5 fails to start | Sampler exits with gem5's exit code; no CSV. |
| Sampler | Gem5 crashes mid-run | Final row `gem5_phase=crashed`; sampler exits with gem5's exit code; analyzer runs on partial CSV and marks `run_status: incomplete`. |
| Sampler | `smaps_rollup` unreadable | Fall back to `status`; PSS/USS/heap = `-1`; header notes fallback; unless `--no-allow-fallback` set (then exit 3). |
| Sampler | SIGINT/SIGTERM | Spawn mode: forward to gem5, flush CSV, exit 130/143. Attach mode: exit cleanly, target untouched. |
| Sampler | Disk full | Log to `mem_sample.log`, kill gem5, exit 1. |
| Sampler | PID reused | `starttime` guard catches it; treated as gem5 exit. |
| Sampler | Sampler-cap reached | Write final row `gem5_phase=sampler_cap_reached`. Spawn mode: switch to monitor-only until gem5 exits (preserves exit-code invariant). Attach mode: exit 0. |
| Analyzer | CSV missing | Exit 2, `error: mem_trend.csv not found`. |
| Analyzer | CSV empty | Exit 2, `error: no samples collected`. |
| Analyzer | `stats.txt` missing | Correlation section skipped; `_per_msim_inst` metrics omitted. Gate failure only if `require_stats_txt: true`. |
| Analyzer | `stats.txt` unparseable | Warn, treat as absent. |
| Analyzer | Policy YAML syntax error | Exit 2, `error: policy: <yaml error>`. |
| Analyzer | Unknown policy key | Warn, ignore. |
| Analyzer | <`min_regression_samples` post-warmup | `growth_rate: null` with `reason: insufficient_samples`; threshold skipped, not failed. |
| Analyzer | Matplotlib unavailable | Skip plot, warn in report; report and gate still produced. Not fatal. |
| Analyzer | Threshold breached | Exit 1. `fail_mode=summary` evaluates all first; `fail_mode=fast` stops at first breach. |
| Deep runner | `heaptrack` missing | Exit 127, install hint. |
| Deep runner | Gem5 crashes under heaptrack | Partial heaptrack file still readable; analyzer marks `deep_mode_run_status: incomplete`. |
| Deep runner | `--pid` supplied | Reject with clear error (impossible with heaptrack). |

**Gate exit-code contract:**

- `0` — all evaluated thresholds passed, or no thresholds present.
- `1` — one or more thresholds failed. Report and JSON still written.
- `2` — analyzer could not evaluate (missing CSV, bad policy, unresolvable
  config). Distinguishes "signal says regression" from "we don't have a
  signal".

`run.sh` treats exit 1 as a hard fail and exit 2 as a loud warning — a
broken evaluator shouldn't kill an otherwise successful profiling run.

### 4.5 Cross-cutting rules

- Every script starts with `set -euo pipefail`, matching existing style.
- No `rm -rf $OUTPUT_DIR`; the analyzer writes fresh filenames and leaves
  prior artifacts in place. Cleanup is the user's job.
- No `sudo`. Hardened-kernel access issues are handled by the `smaps_rollup`
  fallback, not by escalation.

## 5. CLI / env / YAML / default precedence

Every knob follows the same resolution chain, highest priority first:

1. Explicit CLI flag (`--interval-s 0.5`).
2. Environment variable (`INTERVAL_S=0.5`).
3. Policy YAML entry (analyzer only).
4. Built-in default in code.

Missing a value at every level is fine — the tool proceeds with its default.
The effective value and its source are recorded in
`mem_report.md` → "Effective configuration" and in `mem_metrics.json`.

### 5.1 `mem_sample.sh` knobs

| Knob | CLI flag | Env var | Default |
|---|---|---|---|
| Sample interval (s) | `--interval-s <float>` | `INTERVAL_S` | `1.0` |
| Output directory | `--output-dir <path>` | `OUTPUT_DIR` | `./output` |
| CSV output path | `--csv <path>` | `MEM_TREND_CSV` | `$OUTPUT_DIR/mem_trend.csv` |
| Sampler log path | `--sample-log <path>` | `MEM_SAMPLE_LOG` | `$OUTPUT_DIR/mem_sample.log` |
| `/proc/status` fallback | `--allow-fallback` / `--no-allow-fallback` | `MEM_ALLOW_FALLBACK` (`0`/`1`) | `1` (on) |
| Run tag | `--tag <label>` | `MEM_RUN_TAG` | `""` |
| Append to existing CSV | `--append` | `MEM_APPEND=1` | off |
| Attach to existing PID | `--pid <pid>` | `MEM_ATTACH_PID` | *(none; spawn mode)* |
| Max samples | `--max-samples <int>` | `MEM_MAX_SAMPLES` | `0` (unlimited) |
| Max duration (s) | `--max-duration-s <float>` | `MEM_MAX_DURATION_S` | `0` (unlimited) |
| Gem5 command | positional after `--` | — | — |

Values <0.1 s for `--interval-s` warn (measurement noise dominates).

`--pid` is mutually exclusive with a positional gem5 argv; both supplied →
exit 2 with clear error.

`--append` semantics: the sampler reads the last data row's `ts_ms` at
startup, records it as an offset, and every new sample's `ts_ms` = offset +
monotonic elapsed since sampler start. A stitched CSV is one monotonically
increasing timeline. One `# segment_start:` comment line is prepended to
each appended run. **Header validation:** if the existing CSV's data-column
header row differs from the current sampler's (e.g., older version), append
is refused with exit 2 rather than silently producing a corrupt file. The
segment-start comment line is written into the CSV body (not before the
existing header) so column layout stays valid.

### 5.2 `analyze_mem.py` knobs

**Paths**

| Knob | CLI flag | Env var | Default |
|---|---|---|---|
| Input CSV | `--csv <path>` | `MEM_TREND_CSV` | `./output/mem_trend.csv` |
| Gem5 stats.txt | `--stats <path>` | `GEM5_STATS_TXT` | `<csv-dir>/stats.txt` |
| Policy YAML | `--policy <path>` | `MEM_POLICY_YAML` | `profiling/mem/mem_thresholds.yaml` (skipped if absent) |
| Heaptrack glob | `--heaptrack <glob>` | `MEM_HEAPTRACK_GLOB` | *(none)* |
| Report output | `--report <path>` | `MEM_REPORT_MD` | `<csv-dir>/mem_report.md` |
| Metrics JSON | `--metrics <path>` | `MEM_METRICS_JSON` | `<csv-dir>/mem_metrics.json` |
| Plot PNG | `--plot <path>` | `MEM_PLOT_PNG` | `<csv-dir>/mem_trend.png` |
| Disable plot | `--no-plot` | `MEM_NO_PLOT=1` | plot on |
| Run tag override | `--tag <label>` | `MEM_RUN_TAG` | read from CSV header |

**Thresholds & analysis parameters** — every one is optional; unset =
threshold not evaluated.

| Knob | CLI flag | Env var | YAML key | Default |
|---|---|---|---|---|
| Warmup window (s) | `--warmup-seconds <int>` | `MEM_WARMUP_SECONDS` | `warmup_seconds` | `30` |
| Peak RSS (MB) | `--peak-rss-mb <float>` | `MEM_PEAK_RSS_MB` | `peak_rss_mb` | *(unset)* |
| Post-warmup leak (bytes/s) | `--leak-bytes-per-sec <float>` | `MEM_LEAK_BPS` | `leak_bytes_per_sec` | *(unset)* |
| RSS per M-simInsts (KB) | `--rss-per-msim-kb <float>` | `MEM_RSS_PER_MSIM_KB` | `rss_per_msim_inst_kb` | *(unset)* |
| Require stats.txt | `--require-stats-txt` | `MEM_REQUIRE_STATS_TXT` | `require_stats_txt` | `false` |
| Min post-warmup samples | `--min-regression-samples <int>` | `MEM_MIN_REGRESSION_SAMPLES` | `min_regression_samples` | `5` |
| Gate mode | `--fail-fast` / `--fail-summary` | `MEM_FAIL_MODE` | `fail_mode` | `summary` |

`--help` prints this whole surface grouped as **paths** and **thresholds**,
each row showing default and env-var name — same pattern gem5's own SCons
help uses.

### 5.3 `deep_run.sh` knobs

| Knob | CLI flag | Env var | Default |
|---|---|---|---|
| Output directory | `--output-dir <path>` | `OUTPUT_DIR` | `./output` |
| Heaptrack file prefix | `--prefix <name>` | `HEAPTRACK_PREFIX` | `heaptrack.gem5` |
| Gem5 command | positional after `--` | — | — |

### 5.4 Worked example — precedence chain

```bash
# YAML sets peak_rss_mb: 8192, leak_bytes_per_sec: 524288, warmup_seconds: 30.
# Env overrides the leak threshold for this shell.
# CLI overrides peak just for this invocation.

export MEM_LEAK_BPS=262144
python3 analyze_mem.py \
    --csv output/mem_trend.csv \
    --policy profiling/mem/mem_thresholds.yaml \
    --peak-rss-mb 12000
```

Effective values: `peak_rss_mb=12000` (cli), `leak_bytes_per_sec=262144`
(env), `warmup_seconds=30` (yaml), everything else default.

### 5.5 Worked example — LSF attach

Enables the 230-concurrent-LSF-jobs scenario without changing job commands.

```bash
# Called per LSF job by a small monitor wrapper:
profiling/mem/mem_sample.sh \
    --pid "$GEM5_PID" \
    --append \
    --tag "$LSB_JOBID-node$LSB_HOSTS" \
    --interval-s 5 \
    --max-duration-s 43200 \
    --output-dir "/scratch/mem_trends/$LSB_JOBID"
```

Same analyzer, same policy, same gate.

## 6. Testing strategy

Three tiers: **unit** (fast, hermetic, always run), **integration**
(subprocess-driven, needs real `/proc`), **e2e** (needs a built gem5). Plus
a snapshot test for the report format.

### 6.1 Layout

```
profiling/mem/tests/
├── unit/
│   ├── test_config_resolution.py    # precedence: CLI > env > YAML > default
│   ├── test_csv_parser.py           # header, comments, segments, malformed rows
│   ├── test_metrics.py              # peak/final/growth-rate/rss-per-msim math
│   ├── test_gate.py                 # threshold evaluation + exit-code table
│   └── test_stats_txt_parser.py     # keys, missing keys, multiple dumps
├── integration/
│   ├── test_sampler_spawn.sh        # sidecar over a fake gem5
│   ├── test_sampler_attach.sh       # --pid mode against fake target
│   ├── test_sampler_append.sh       # --append across two segments
│   ├── test_sampler_caps.sh         # --max-samples, --max-duration-s
│   └── test_analyzer_cli.sh         # analyzer against fixture CSVs
├── e2e/
│   └── test_pipeline_smoke.sh       # real gem5.opt, tiny SE workload
└── fixtures/
    ├── stats_normal.txt
    ├── stats_multi_dump.txt
    ├── stats_missing_keys.txt
    ├── mem_trend_normal.csv
    ├── mem_trend_leak.csv
    ├── mem_trend_flat_short.csv     # <5 post-warmup samples
    ├── mem_trend_appended.csv       # two segments
    └── policies/
        ├── strict.yaml
        ├── lenient.yaml
        └── malformed.yaml
```

Unit tests use `pytest` (matches gem5's `tests/pyunit/`). Integration and
e2e use bash with a tiny `assert.sh` helper (matches `profiling/*.sh`).

### 6.2 Unit tests — highest-value coverage

`test_config_resolution.py` — proves the precedence chain from §5.

```python
def test_cli_beats_env_beats_yaml_beats_default(tmp_path):
    yaml = tmp_path / "p.yaml"
    yaml.write_text("peak_rss_mb: 8192\nwarmup_seconds: 30\n")
    cfg = resolve_config(
        cli={"peak_rss_mb": 12000},
        env={"MEM_LEAK_BPS": "262144"},
        yaml_path=yaml,
        defaults={"warmup_seconds": 30, "fail_mode": "summary"},
    )
    assert cfg["peak_rss_mb"] == (12000, "cli")
    assert cfg["leak_bytes_per_sec"] == (262144, "env")
    assert cfg["warmup_seconds"] == (30, "yaml")
    assert cfg["fail_mode"] == ("summary", "default")
```

Every knob from §5 gets a row in a table-driven test. The `(value, source)`
tuple return is what feeds the "Effective configuration" report section, so
this test also protects that reporting.

`test_metrics.py` — pure math on synthetic samples:

- Peak / final / warmup boundaries correct with integer and float `ts_ms`.
- Growth rate is `null` when post-warmup samples < `min_regression_samples`.
- Slope matches `numpy.polyfit` on a hand-computed linear ramp within 1e-6.
- `rss_per_msim_inst_kb` returns `null` on `sim_insts == 0` (no
  divide-by-zero).
- Appended CSV: per-segment slopes on the right rows; whole-file slope
  covers the union.

`test_gate.py` — the exit-code table from §4.4 executed:

```
scenario                                              → exit
no policy, no thresholds                              → 0
all thresholds passed                                 → 0
one threshold breached, fail_mode=summary             → 1 (all logged)
first threshold breached, fail_mode=fast              → 1 (later skipped)
require_stats_txt=true, stats.txt absent              → 1
policy YAML syntax error                              → 2
CSV missing                                           → 2
CSV empty                                             → 2
matplotlib import fails                               → 0 (warning)
```

`test_csv_parser.py` — header parsing, `# segment_start:` markers, wrong-
column-count rows logged and skipped, `-1` fallback rows tolerated.

`test_stats_txt_parser.py` — real gem5 stats fixture; parses `sim_insts` /
`host_seconds` / `sim_seconds`; handles both naming conventions
(`sim_insts` vs `simInsts`); picks the **last** dump when there are three.

### 6.3 Integration tests — subprocess, real `/proc`

Every integration test uses a **fake gem5**, `tests/tools/fake_gem5.c`
(~40 lines of C):

```c
// argv: fake_gem5 <alloc_mb_per_sec> <duration_s> [--stats-out <path>]
// Allocates alloc_mb_per_sec per second (touches pages so they hit RSS),
// prints "Beginning simulation!" after 1 s, and optionally writes a
// gem5-shaped stats.txt on exit.
```

Compiled on first run (`cc -o tests/tools/fake_gem5 …`), cached thereafter.
Gives a process with byte-controlled RSS growth, so sampler output is
checkable within a small tolerance.

Coverage:

- `test_sampler_spawn.sh` — smoke: CSV exists, header comments present,
  ≥ 9 data rows over 5 s at 0.5 s interval, last minus first RSS ≈ 50 MB.
- `test_sampler_attach.sh` — background fake_gem5, `--pid` sampler,
  CSV grows, sampler exits when target exits, `# attached: true` in header.
- `test_sampler_append.sh` — two runs, `--append`, monotonic `ts_ms`
  across boundary, two `# segment_start:` lines, per-segment slopes
  approximately correct.
- `test_sampler_caps.sh` — spawn mode: `--max-samples 5` yields exactly 5
  rows; `--max-duration-s 2` at 0.5 s interval yields ~4 rows; final row
  `gem5_phase=sampler_cap_reached`; sampler stays alive in monitor-only
  mode until fake_gem5 exits and forwards its exit code (preserves the
  spawn-mode invariant from §4.4). Attach mode: same caps cause immediate
  exit 0 with the target left running (verified by asserting fake_gem5
  is still alive after sampler returns).
- `test_analyzer_cli.sh` — analyzer over each fixture CSV × each fixture
  policy; exit codes match §4.4; `mem_report.md` contains "Effective
  configuration" with correct source tags.

### 6.4 E2E test

`test_pipeline_smoke.sh` — guard against integration drift with real gem5:

```bash
scons build/ALL/gem5.opt -j$(nproc)     # skipped if binary exists
MEM_TREND=1 profiling/run.sh
```

Asserts:

- `output/mem_trend.csv` exists with ≥ 5 rows.
- `output/mem_report.md` exists and contains "Effective configuration".
- `output/mem_metrics.json` contains `sim_insts` correlation (proves
  stats.txt merge worked against a real gem5 output).
- Gate exit code is 0 with the default policy.

Runs only when `E2E=1` — kept out of the default pytest loop because it
needs a built gem5.

### 6.5 Snapshot test

`test_report_snapshot.py` — analyzer against `mem_trend_leak.csv` +
`strict.yaml`, diffs `mem_report.md` against a checked-in golden.
Regeneration is a deliberate, reviewable step
(`pytest --snapshot-update` via `syrupy`).

### 6.6 Coverage & rules

- Analyzer: ≥ 90 % line coverage (it holds the real logic).
- Sampler: ≥ 80 % branch coverage on decisions reachable with fake_gem5.
- No network, no root, no > 200 MB memory in any test.
- AAA structure per `~/.claude/rules/common/testing.md`.
- Fixtures under `fixtures/` are versioned; regeneration is a manual step
  through a checked-in `regenerate_fixtures.sh`.

### 6.7 Explicitly not tested

- Real heaptrack — not guaranteed on every dev box, and its output
  stability is heaptrack's problem. The `--heaptrack` code path is tested
  by feeding the analyzer a pre-captured `heaptrack_print` text output as
  a fixture.
- Cross-platform. Everything is Linux-only and tests are marked
  `skipif(sys.platform != "linux")`.
- Sub-100 ms sampling intervals. Off-menu.

## 7. Alternatives considered

### 7.1 Always run under `heaptrack`

Launch gem5 under heaptrack every time; parse the heaptrack file for both
time series and attribution.

- **Pros:** single tool, richest data.
- **Cons:** 2–10× slowdown means the curve is dominated by heaptrack
  overhead — defeats the "coarse always-on" goal.
- **Rejected** in favor of the sidecar-plus-optional-heaptrack split.

### 7.2 In-tree gem5 instrumentation

Patch gem5 to periodically emit host RSS into `stats.txt` via `getrusage()`
or `/proc/self/statm`.

- **Pros:** perfect `sim_insts` ↔ memory correlation in one file.
- **Cons:** modifies upstream gem5 (against the branch discipline in
  `CLAUDE.md`); sample rate = gem5's stat-dump rate (very coarse for long
  runs); no attribution path; hard to toggle per-run.
- **Rejected.**

## 8. Rollout & migration

- Introduces no new files under `src/`; nothing touches the gem5 build
  system.
- `MEM_TREND` env var is opt-in — existing users of `profiling/run.sh` see
  no behavior change.
- `profiling/mem/mem_thresholds.yaml` ships with all thresholds unset
  (comments only) — the default gate is "no thresholds → pass".
- Documentation update: extend `docs/Gem5 高并发仿真性能衰减排查与评估指南.md`
  with a §3.6 "Host memory trend evaluation" pointing at the new pipeline;
  do that in the implementation PR, not this spec.

## 9. Open questions

None. Any that arise during implementation planning will be resolved in the
plan doc, not this spec.

## 10. Acceptance criteria

A reviewer confirms all of the following before implementation is called
complete:

1. `profiling/mem/` contains the four scripts described in §3.
2. `MEM_TREND=1 profiling/run.sh` produces `output/mem_trend.csv`,
   `output/mem_trend.png`, `output/mem_report.md`, `output/mem_metrics.json`
   without touching gem5 source.
3. Every knob in §5 is honored via CLI, env, YAML (analyzer only), and has
   a documented default.
4. `mem_report.md` contains an "Effective configuration" section tagging
   every value's source.
5. The gate exit-code contract from §4.4 holds under
   `profiling/mem/tests/integration/test_analyzer_cli.sh`.
6. Unit-test coverage of `analyze_mem.py` ≥ 90 %; integration tests pass
   on a stock Linux CI runner without root; `E2E=1` smoke test passes on a
   host with a built `gem5.opt`.
7. `deep_run.sh` correctly rejects `--pid`, prints an install hint when
   `heaptrack` is missing, and produces a heaptrack file the analyzer can
   summarize via `--heaptrack`.
