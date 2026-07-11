# Task 6 Report: Gate evaluation -- `evaluate_gate()`

**Status:** DONE

## Commits Made

```
9187256f83 misc: add evaluate_gate: summary/fast fail + exit codes
```

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `profiling/mem/analyze_mem.py` | Modified (+75) | Added `evaluate_gate()` function |
| `profiling/mem/tests/unit/test_gate.py` | Created (+112) | 9 unit tests |

## Test Summary

All 41 unit tests pass (9 new + 32 existing). No regressions.

**New tests (test_gate.py):**

| Test | What it covers |
|------|----------------|
| `test_no_thresholds_pass` | No thresholds configured => pass with code 0 |
| `test_all_pass` | All metrics under thresholds => pass with code 0 |
| `test_peak_breached` | Peak RSS exceeds threshold => fail with code 1 |
| `test_leak_breached` | Leak rate exceeds threshold (KB/s to bytes/s conversion) => fail with code 1 |
| `test_leak_null_skipped` | growth_rate is None => skip check, not fail |
| `test_fail_fast_stops_early` | fail_mode="fast" collects only 1 failure |
| `test_fail_summary_collects_all` | fail_mode="summary" collects all failures |
| `test_require_stats_absent` | stats.txt required but absent => fail with code 1 |
| `test_require_stats_present` | stats.txt required and present => pass with code 0 |

**Coverage:** 86% across `analyze_mem.py` (exceeds 80% threshold)

## Implementation Details

- `evaluate_gate(metrics, cfg, stats_present) -> (verdict, exit_code, failures)`
- Checks three thresholds: `peak_rss_mb`, `leak_bytes_per_sec`, `rss_per_msim_inst_kb`
- Unit conversions: KB to MB (1/1024), KB/s to bytes/s (1024)
- `fail_mode` supports `"summary"` (collect all) and `"fast"` (stop at first breach)
- `require_stats_txt` gate additive check -- returns fail immediately if required and absent
- Null metric values are skipped gracefully (not treated as failures)

## Concerns

None. All tests pass, coverage exceeds threshold, existing tests unaffected.

---

## Post-Review Fix (Task 6 Review)

**Date:** 2026-07-11

### Issues Fixed

1. **Consistent None defaults in `evaluate_gate()`** -- Changed two `metrics.get()` calls from defaulting to `0` to bare `.get()` (None default) to match the existing third call. Located in `profiling/mem/analyze_mem.py`:
   - Line 333: `metrics.get("peak_rss_kb", 0)` -> `metrics.get("peak_rss_kb")`
   - Line 340: `metrics.get("growth_rate_kb_per_s_post_warmup", 0)` -> `metrics.get("growth_rate_kb_per_s_post_warmup")`

2. **Added missing breach test for `rss_per_msim_inst_kb`** -- Added `test_rss_per_msim_breached()` to `profiling/mem/tests/unit/test_gate.py` to verify that rss_per_msim_inst_kb exceeding its threshold produces exit code 1 and a failure entry for that metric.

### Test Results

All 10 tests in `test_gate.py` pass (1 new + 9 existing). No regressions.
