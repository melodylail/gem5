import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import load_stats

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def test_parses_standard():
    s = load_stats(FIXTURES / "stats_normal.txt")
    assert s is not None
    assert s["sim_insts"] == pytest.approx(1_500_000_000)
    assert s["host_seconds"] == pytest.approx(45.234)
    assert s["sim_seconds"] == pytest.approx(0.001)


def test_multi_dump_uses_last():
    s = load_stats(FIXTURES / "stats_multi_dump.txt")
    assert s["sim_insts"] == pytest.approx(1_500_000_000)
    assert s["host_seconds"] == pytest.approx(45.234)


def test_missing_file():
    assert load_stats(Path("/nonexistent/stats.txt")) is None


def test_unparseable(tmp_path):
    f = tmp_path / "j.txt"
    f.write_text("not gem5")
    assert load_stats(f) is None
