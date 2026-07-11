import io
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import (
    compute_metrics,
    evaluate_gate,
    load_csv,
    resolve_config,
    write_metrics_json,
    write_report,
)

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
DEFAULTS = {
    "warmup_seconds": 30,
    "peak_rss_mb": None,
    "leak_bytes_per_sec": None,
    "rss_per_msim_inst_kb": None,
    "require_stats_txt": False,
    "min_regression_samples": 5,
    "fail_mode": "summary",
}


def test_write_report_contains_effective_config(tmp_path):
    h, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    cfg = resolve_config(cli={}, env={}, yaml_path=None, defaults=DEFAULTS)
    m = compute_metrics(s, None, cfg)
    v, code, fails = evaluate_gate(m, cfg, True)
    rp = tmp_path / "report.md"
    write_report(h, s, m, cfg, v, fails, None, rp)
    text = rp.read_text()
    assert "Effective configuration" in text
    assert "warmup_seconds" in text
    assert "default" in text  # source tag


def test_write_report_with_breach(tmp_path):
    h, s = load_csv(FIXTURES / "mem_trend_leak.csv")
    cfg = resolve_config(
        cli={},
        env={"MEM_PEAK_RSS_MB": "10"},
        yaml_path=None,
        defaults=DEFAULTS,
    )
    m = compute_metrics(s, None, cfg)
    v, code, fails = evaluate_gate(m, cfg, True)
    rp = tmp_path / "report.md"
    write_report(h, s, m, cfg, v, fails, None, rp)
    text = rp.read_text()
    assert "FAIL" in text or "fail" in text.lower()
    assert "peak_rss" in text.lower()


def test_write_metrics_json(tmp_path):
    h, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    cfg = resolve_config(cli={}, env={}, yaml_path=None, defaults=DEFAULTS)
    m = compute_metrics(s, None, cfg)
    v, code, fails = evaluate_gate(m, cfg, True)
    jp = tmp_path / "metrics.json"
    write_metrics_json(h, m, cfg, v, fails, jp)
    data = json.loads(jp.read_text())
    assert "peak_rss_kb" in data
    assert "effective_config" in data
    assert data["gate"]["verdict"] == "pass"


def test_render_plot_no_crash(tmp_path):
    """render_plot produces a PNG, or returns None if matplotlib unavailable."""
    h, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    cfg = resolve_config(cli={}, env={}, yaml_path=None, defaults=DEFAULTS)
    m = compute_metrics(s, None, cfg)
    from analyze_mem import render_plot

    pp = tmp_path / "plot.png"
    result = render_plot(s, m, cfg, pp)
    if result is not None:
        assert result.suffix == ".png"
        assert result.stat().st_size > 0
