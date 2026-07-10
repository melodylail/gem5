import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import (
    compute_metrics,
    load_csv,
)

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def _cfg(**kw):
    base = {
        "warmup_seconds": (30, "default"),
        "peak_rss_mb": (None, "default"),
        "leak_bytes_per_sec": (None, "default"),
        "rss_per_msim_inst_kb": (None, "default"),
        "require_stats_txt": (False, "default"),
        "min_regression_samples": (5, "default"),
        "fail_mode": ("summary", "default"),
    }
    base.update(kw)
    return base


def test_peak_and_final():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg())
    assert m["peak_rss_kb"] == 90032.0
    assert m["final_rss_kb"] == 90032.0


def test_peak_pss():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg())
    assert m["peak_pss_kb"] == 89001.0


def test_rss_per_msim():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, {"sim_insts": 1_500_000_000}, _cfg())
    expected = (90032.0 - 42116.0) / 1500.0
    assert m["rss_per_msim_inst_kb"] == pytest.approx(expected, rel=1e-6)


def test_rss_per_msim_null_no_stats():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg())
    assert m["rss_per_msim_inst_kb"] is None


def test_rss_per_msim_null_zero_insts():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, {"sim_insts": 0}, _cfg())
    assert m["rss_per_msim_inst_kb"] is None


def test_insufficient_samples():
    """3 samples, warmup=30 => 0 post-warmup => growth_rate None"""
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg(warmup_seconds=(60, "default")))
    assert m["growth_rate_kb_per_s_post_warmup"] is None
    assert m["growth_rate_reason"] == "insufficient_samples"


def test_linear_ramp():
    """50 samples at 1s interval, RSS = 10000 + 2*ts_seconds. Slope = 2 KB/s."""
    samples = []
    for i in range(50):
        t_s = float(i)
        samples.append(
            {
                "ts_ms": t_s * 1000.0,
                "rss_kb": 10000.0 + 2.0 * t_s,
                "pss_kb": 0.0,
                "uss_kb": 0.0,
                "heap_kb": 0.0,
                "anon_kb": 0.0,
                "file_kb": 0.0,
                "swap_kb": 0.0,
                "gem5_phase": "ok",
            }
        )
    m = compute_metrics(samples, None, _cfg(warmup_seconds=(10, "default")))
    assert m["growth_rate_kb_per_s_post_warmup"] is not None
    assert m["growth_rate_kb_per_s_post_warmup"] == pytest.approx(2.0, abs=0.1)
    assert m["n_post_warmup"] == 40


def test_sample_counts():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg())
    assert m["n_samples"] == 10
    assert m["n_post_warmup"] == 0  # all within 0-9s < 30s warmup
