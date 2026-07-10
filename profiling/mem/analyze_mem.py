"""Memory trend analyzer for gem5.opt — CSV x stats.txt -> metrics, plot, gate."""

import os
import sys
import warnings
from pathlib import Path
from typing import (
    Any,
    Dict,
    Optional,
    Tuple,
)

try:
    import yaml
except ImportError:
    yaml = None

_ENV_MAP: Dict[str, str] = {
    "warmup_seconds": "MEM_WARMUP_SECONDS",
    "peak_rss_mb": "MEM_PEAK_RSS_MB",
    "leak_bytes_per_sec": "MEM_LEAK_BPS",
    "rss_per_msim_inst_kb": "MEM_RSS_PER_MSIM_KB",
    "require_stats_txt": "MEM_REQUIRE_STATS_TXT",
    "min_regression_samples": "MEM_MIN_REGRESSION_SAMPLES",
    "fail_mode": "MEM_FAIL_MODE",
}

_TRUTHY = frozenset({"1", "true", "yes", "on"})
_FALSEY = frozenset({"0", "false", "no", "off", ""})


def _coerce(value: Any, template: Any) -> Any:
    if template is None:
        if isinstance(value, str):
            try:
                return int(value)
            except ValueError:
                try:
                    return float(value)
                except ValueError:
                    pass
        return value
    if isinstance(template, bool):
        if isinstance(value, str):
            lower = value.strip().lower()
            if lower in _TRUTHY:
                return True
            if lower in _FALSEY:
                return False
        return bool(value)
    if isinstance(template, int):
        return int(value)
    if isinstance(template, float):
        return float(value)
    return value


def resolve_config(
    cli: Dict[str, Any],
    env: Dict[str, str],
    yaml_path: Optional[Path],
    defaults: Dict[str, Any],
) -> Dict[str, Tuple[Any, str]]:
    """Resolve effective config. Returns {key: (value, source)}.
    Priority: CLI > env > YAML > default."""
    result: Dict[str, Tuple[Any, str]] = {}
    for key, default_val in defaults.items():
        value, source = default_val, "default"
        yaml_val = _read_yaml_key(yaml_path, key) if yaml_path else None
        if yaml_val is not None:
            value, source = yaml_val, "yaml"
        env_var = _ENV_MAP.get(key)
        if env_var and env_var in env:
            value, source = _coerce(env[env_var], default_val), "env"
        if key in cli and cli[key] is not None:
            value, source = cli[key], "cli"
        result[key] = (value, source)
    return result


def _read_yaml_key(yaml_path: Optional[Path], key: str) -> Optional[Any]:
    if yaml_path is None or not yaml_path.is_file():
        return None
    if yaml is None:
        warnings.warn("pyyaml not installed; cannot read policy YAML")
        return None
    try:
        with open(yaml_path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except Exception:
        warnings.warn(f"policy YAML syntax error in {yaml_path}")
        return None
    if not isinstance(data, dict):
        return None
    for k in data:
        if k not in _ENV_MAP:
            warnings.warn(f"unknown key '{k}' in policy YAML; ignored")
    return data.get(key)
