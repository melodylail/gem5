import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import load_csv

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def test_header_fields():
    h, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    assert h["gem5_cmd"].startswith("build/ALL/gem5.opt")
    assert "2026-07-09" in h["start_wall"]
    assert h["interval_s"] == 1.0
    assert h["pid"] == 48211
    assert h["host"] == "testhost"
    assert h["kernel"] == "6.8.0-test"
    assert h["page_size"] == 4096
    assert h["tag"] == "normal-run"
    assert h["attached"] is False
    assert h["smaps_rollup_unavailable"] is False


def test_all_data_rows():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    assert len(s) == 10
    assert s[0]["ts_ms"] == 0.0
    assert s[0]["rss_kb"] == 42116.0
    assert isinstance(s[0]["rss_kb"], float)
    assert s[0]["gem5_phase"] == "unknown"


def test_first_and_last():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    assert s[0]["ts_ms"] == 0.0
    assert s[0]["rss_kb"] == 42116.0
    assert s[-1]["ts_ms"] == 9000.0
    assert s[-1]["rss_kb"] == 90032.0


def test_segments():
    h, s = load_csv(FIXTURES / "mem_trend_appended.csv")
    assert "segments" in h
    assert len(h["segments"]) == 1
    assert len(s) == 5


def test_attached_flag():
    h, _ = load_csv(FIXTURES / "mem_trend_appended.csv")
    assert h["attached"] is True


def test_malformed_rows_skipped():
    _, s = load_csv(FIXTURES / "mem_trend_malformed.csv")
    assert len(s) == 2


def test_missing_file_raises():
    with pytest.raises(FileNotFoundError):
        load_csv(Path("/nonexistent/file.csv"))


def test_empty_csv():
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".csv", delete=False
    ) as f:
        f.write(
            "# gem5_cmd: test\n# start_wall: 2026-01-01\n"
            "# interval_s: 1.0\n# pid: 1\n"
            "# host: h, kernel: k, page_size: 4096\n"
            "# tag: empty\n# attached: false\n"
            "ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase\n"
        )
    try:
        h, s = load_csv(Path(f.name))
        assert s == []
        assert h["tag"] == "empty"
    finally:
        os.unlink(f.name)
