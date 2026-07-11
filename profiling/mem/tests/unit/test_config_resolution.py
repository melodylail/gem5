import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import (
    ConfigError,
    resolve_config,
)

DEFAULTS = {
    "warmup_seconds": 30,
    "peak_rss_mb": None,
    "leak_bytes_per_sec": None,
    "rss_per_msim_inst_kb": None,
    "require_stats_txt": False,
    "min_regression_samples": 5,
    "fail_mode": "summary",
}


def test_all_defaults():
    cfg = resolve_config(cli={}, env={}, yaml_path=None, defaults=DEFAULTS)
    for k, v in DEFAULTS.items():
        assert cfg[k] == (v, "default"), f"key={k}"


def test_cli_beats_all():
    cfg = resolve_config(
        cli={"peak_rss_mb": 12000},
        env={"MEM_PEAK_RSS_MB": "8192"},
        yaml_path=None,
        defaults=DEFAULTS,
    )
    assert cfg["peak_rss_mb"] == (12000, "cli")


def test_env_beats_yaml(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("peak_rss_mb: 4096\nwarmup_seconds: 60\n")
    cfg = resolve_config(
        cli={},
        env={"MEM_PEAK_RSS_MB": "8192"},
        yaml_path=yf,
        defaults=DEFAULTS,
    )
    assert cfg["peak_rss_mb"] == (8192, "env")
    assert cfg["warmup_seconds"] == (60, "yaml")


def test_yaml_beats_default(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("warmup_seconds: 45\nfail_mode: fast\n")
    cfg = resolve_config(cli={}, env={}, yaml_path=yf, defaults=DEFAULTS)
    assert cfg["warmup_seconds"] == (45, "yaml")
    assert cfg["fail_mode"] == ("fast", "yaml")


def test_env_type_coercion():
    cfg = resolve_config(
        cli={},
        env={
            "MEM_WARMUP_SECONDS": "90",
            "MEM_MIN_REGRESSION_SAMPLES": "10",
            "MEM_REQUIRE_STATS_TXT": "true",
        },
        yaml_path=None,
        defaults=DEFAULTS,
    )
    assert cfg["warmup_seconds"] == (90, "env")
    assert isinstance(cfg["warmup_seconds"][0], int)
    assert cfg["require_stats_txt"] == (True, "env")


@pytest.mark.parametrize("val", ["false", "0", "False", "no"])
def test_env_false_strings(val):
    cfg = resolve_config(
        cli={},
        env={"MEM_REQUIRE_STATS_TXT": val},
        yaml_path=None,
        defaults=DEFAULTS,
    )
    assert cfg["require_stats_txt"] == (False, "env")


def test_missing_yaml_not_error(tmp_path):
    cfg = resolve_config(
        cli={}, env={}, yaml_path=tmp_path / "nope.yaml", defaults=DEFAULTS
    )
    for k in DEFAULTS:
        assert cfg[k] == (DEFAULTS[k], "default")


def test_unknown_yaml_key_warns(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("warmup_seconds: 30\nfuture_feature: 42\n")
    cfg = resolve_config(cli={}, env={}, yaml_path=yf, defaults=DEFAULTS)
    assert "future_feature" not in cfg
    assert cfg["warmup_seconds"] == (30, "yaml")


def test_all_keys_present(tmp_path):
    cfg = resolve_config(
        cli={"peak_rss_mb": 1024},
        env={"MEM_LEAK_BPS": "262144"},
        yaml_path=None,
        defaults=DEFAULTS,
    )
    for k in DEFAULTS:
        assert k in cfg


def test_malformed_yaml_raises_configerror(tmp_path):
    """Malformed YAML policy must raise ConfigError (not silently return None)."""
    malformed = tmp_path / "malformed.yaml"
    malformed.write_text("warmup_seconds: 30\ninvalid: [unclosed\n")
    with pytest.raises(ConfigError):
        resolve_config(cli={}, env={}, yaml_path=malformed, defaults=DEFAULTS)
