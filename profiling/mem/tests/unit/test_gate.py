import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import evaluate_gate


def _cfg(**kw):
    base = {
        "warmup_seconds": (30, "d"),
        "peak_rss_mb": (None, "d"),
        "leak_bytes_per_sec": (None, "d"),
        "rss_per_msim_inst_kb": (None, "d"),
        "require_stats_txt": (False, "d"),
        "min_regression_samples": (5, "d"),
        "fail_mode": ("summary", "d"),
    }
    base.update(kw)
    return base


def test_no_thresholds_pass():
    v, code, fails = evaluate_gate({}, _cfg(), True)
    assert code == 0 and v == "pass"


def test_all_pass():
    m = {
        "peak_rss_kb": 1000,
        "growth_rate_kb_per_s_post_warmup": 10.0,
        "rss_per_msim_inst_kb": 5.0,
    }
    c = _cfg(
        peak_rss_mb=(2000, "c"),
        leak_bytes_per_sec=(20480.0, "c"),
        rss_per_msim_inst_kb=(10.0, "c"),
    )
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 0


def test_peak_breached():
    m = {"peak_rss_kb": 10_000_000}  # ~10GB
    c = _cfg(peak_rss_mb=(1000, "c"))  # 1GB limit
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 1
    assert any("peak_rss" in f["metric"] for f in fails)


def test_leak_breached():
    m = {
        "growth_rate_kb_per_s_post_warmup": 1000.0,
        "growth_rate_reason": None,
    }
    c = _cfg(leak_bytes_per_sec=(500.0 * 1024, "c"))  # 500 KB/s
    # 1000 KB/s > 500 KB/s
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 1


def test_leak_null_skipped():
    m = {
        "growth_rate_kb_per_s_post_warmup": None,
        "growth_rate_reason": "insufficient_samples",
    }
    c = _cfg(leak_bytes_per_sec=(100.0, "c"))
    v, code, _ = evaluate_gate(m, c, True)
    assert code == 0  # null => skip, not fail


def test_fail_fast_stops_early():
    m = {
        "peak_rss_kb": 10_000_000,
        "growth_rate_kb_per_s_post_warmup": 1000.0,
    }
    c = _cfg(
        peak_rss_mb=(1000, "c"),
        leak_bytes_per_sec=(500.0, "c"),
        fail_mode=("fast", "c"),
    )
    _, code, fails = evaluate_gate(m, c, True)
    assert code == 1
    assert len(fails) == 1  # stopped after first


def test_fail_summary_collects_all():
    m = {
        "peak_rss_kb": 10_000_000,
        "growth_rate_kb_per_s_post_warmup": 9999.0,
    }
    c = _cfg(
        peak_rss_mb=(1000, "c"),
        leak_bytes_per_sec=(1.0, "c"),
        fail_mode=("summary", "c"),
    )
    _, code, fails = evaluate_gate(m, c, True)
    assert code == 1 and len(fails) == 2


def test_require_stats_absent():
    c = _cfg(require_stats_txt=(True, "c"))
    v, code, fails = evaluate_gate({}, c, False)
    assert code == 1
    assert any("stats.txt" in f["metric"] for f in fails)


def test_require_stats_present():
    c = _cfg(require_stats_txt=(True, "c"))
    v, code, _ = evaluate_gate({}, c, True)
    assert code == 0


def test_rss_per_msim_breached():
    m = {"rss_per_msim_inst_kb": 50.0}
    c = _cfg(rss_per_msim_inst_kb=(10.0, "c"))
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 1
    assert any("rss_per_msim" in f["metric"] for f in fails)
