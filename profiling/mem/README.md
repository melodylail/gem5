# Memory Trend Profiling

Sidecar memory sampler and analyzer for gem5 (and any process).

## Quickstart: Pipeline Mode

Run the full profiling pipeline with memory trend Layer 3 enabled:

```bash
MEM_TREND=1 ./profiling/run.sh
```

This spawns gem5 inside `mem_sample.sh`, samples RSS/PSS/USS every second,
and runs `analyze_mem.py` on the resulting CSV + stats.txt.

Output (in `profiling/output/`):
- `mem_trend.csv` -- time-series memory samples
- `mem_report.md` -- markdown report with metrics and gate verdict
- `metrics.json` -- machine-readable metrics (peak_rss_kb, growth_rate, etc.)
- `mem_sample.log` -- sampler log

## Standalone Sampler

Use `mem_sample.sh` directly for on-demand sampling of any command:

```bash
./mem_sample.sh --output-dir ./out --tag my-run -- \
    build/ALL/gem5.opt configs/example/se.py -c ./tests/test-progs/hello/bin/arm/linux/hello
```

```bash
./mem_sample.sh --output-dir ./out --interval-s 2 --tag nightly -- \
    build/ALL/gem5.opt configs/example/se.py -c my_workload
```

### Key options

| Flag | Default | Description |
|------|---------|-------------|
| `--interval-s` | 1.0 | Sample interval in seconds (env: `INTERVAL_S`) |
| `--output-dir` | `./output` | Output directory (env: `OUTPUT_DIR`) |
| `--csv` | `<output-dir>/mem_trend.csv` | CSV output path (env: `MEM_TREND_CSV`) |
| `--tag` | (git short hash) | Run label in CSV header (env: `MEM_RUN_TAG`) |
| `--append` | off | Append to existing CSV (env: `MEM_APPEND=1`) |
| `--max-samples` | 0 (unlimited) | Stop sampling after N rows (env: `MEM_MAX_SAMPLES`) |
| `--max-duration-s` | 0 (unlimited) | Stop sampling after N seconds (env: `MEM_MAX_DURATION_S`) |

## Attach Mode

Attach the sampler to an already-running gem5 process:

```bash
./mem_sample.sh --pid <PID> --output-dir ./out --tag attach-test
```

Press Ctrl+C to stop sampling. The CSV, log, and (optional) analysis are
written on exit.

## Analyzer CLI

`analyze_mem.py` computes metrics from a CSV (and optionally `stats.txt`),
then evaluates them against a threshold policy YAML.

```bash
python3 analyze_mem.py \
    --csv mem_trend.csv \
    --stats stats.txt \
    --policy mem_thresholds.yaml \
    --report report.md \
    --metrics metrics.json
```

### Common workflows

```bash
# Pass gate (no thresholds configured)
python3 analyze_mem.py --csv mem_trend.csv --no-plot

# Gate with custom thresholds via CLI
python3 analyze_mem.py --csv mem_trend.csv \
    --peak-rss-mb 4096 \
    --leak-bytes-per-sec 102400 \
    --warmup-seconds 30

# Fail fast (stop at first breach)
python3 analyze_mem.py --csv mem_trend.csv \
    --policy strict.yaml --fail-fast

# Include stats.txt for rss_per_msim_inst_kb metric
python3 analyze_mem.py --csv mem_trend.csv --stats stats.txt
```

All threshold knobs are also available as environment variables (see
`--help` for the full `MEM_*` env var listing).

## Deep Mode (Heaptrack)

For heap attribution when a leak is suspected, use `deep_run.sh`:

```bash
# Install heaptrack first
apt install heaptrack

# Run gem5 under heaptrack
./deep_run.sh --output-dir ./heaptrack_out -- \
    build/ALL/gem5.opt configs/example/se.py -c my_workload

# Feed heaptrack output to analyzer
python3 analyze_mem.py \
    --csv mem_trend.csv \
    --heaptrack "heaptrack_out/heaptrack.gem5.*.gz"
```

## Append Mode

Append samples to an existing CSV without overwriting:

```bash
MEM_APPEND=1 ./mem_sample.sh --output-dir ./out --tag run2 -- \
    build/ALL/gem5.opt configs/example/se.py -c another_workload
```

The new run's header block and data rows are appended after the existing
content.

## Testing

```bash
# Unit tests (pytest)
cd profiling/mem/tests/unit && python3 -m pytest -v

# Integration tests
for t in profiling/mem/tests/integration/test_*.sh; do bash "$t"; done

# E2E smoke test (requires gem5.opt)
E2E=1 bash profiling/mem/tests/e2e/test_pipeline_smoke.sh
```

Unit tests cover metrics computation, CSV parsing, config resolution,
gate evaluation, and plotting. Integration tests validate the sampler
and analyzer CLI contracts using synthetic fixtures. The E2E smoke test
runs the full pipeline end-to-end.
