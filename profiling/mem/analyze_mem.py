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


_DATA_COLUMNS = [
    "ts_ms",
    "rss_kb",
    "pss_kb",
    "uss_kb",
    "heap_kb",
    "anon_kb",
    "file_kb",
    "swap_kb",
    "gem5_phase",
]
_NUMERIC_COLS = frozenset(_DATA_COLUMNS[:-1])


def load_csv(path: Path) -> Tuple[Dict[str, Any], list]:
    """Parse memory trend CSV. Returns (header_dict, samples_list)."""
    if not path.is_file():
        raise FileNotFoundError(f"CSV not found: {path}")

    header: Dict[str, Any] = {
        "gem5_cmd": "",
        "start_wall": "",
        "interval_s": 1.0,
        "pid": 0,
        "host": "",
        "kernel": "",
        "page_size": 4096,
        "tag": "",
        "attached": False,
        "smaps_rollup_unavailable": False,
        "segments": [],
    }
    samples: list = []
    expected = len(_DATA_COLUMNS)

    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n\r")
            if line.startswith("#"):
                content = line[1:].strip()
                if content.startswith("segment_start:"):
                    header["segments"].append(content.split(":", 1)[1].strip())
                elif ":" in content:
                    k, _, v = content.partition(":")
                    k, v = k.strip().lower(), v.strip()
                    if k == "gem5_cmd":
                        header["gem5_cmd"] = v
                    elif k == "start_wall":
                        header["start_wall"] = v
                    elif k == "interval_s":
                        header["interval_s"] = float(v)
                    elif k == "pid":
                        header["pid"] = int(v)
                    elif k == "host":
                        _parse_host_line(v, header)
                    elif k == "tag":
                        header["tag"] = v
                    elif k == "attached":
                        header["attached"] = v.lower() in ("true", "1", "yes")
                    elif k == "smaps_rollup_unavailable":
                        header["smaps_rollup_unavailable"] = v.lower() in (
                            "true",
                            "1",
                            "yes",
                        )
                continue
            if not line.strip():
                continue
            fields = line.split(",")
            if fields[0].strip() == "ts_ms":
                continue
            if len(fields) != expected:
                warnings.warn(
                    f"skipping malformed row: expected {expected} cols, got {len(fields)}"
                )
                continue
            sample = {}
            for i, col in enumerate(_DATA_COLUMNS):
                val = fields[i].strip()
                if col in _NUMERIC_COLS:
                    sample[col] = float(val) if val else 0.0
                else:
                    sample[col] = val
            samples.append(sample)
    return header, samples


def _parse_host_line(value: str, header: Dict[str, Any]) -> None:
    parts = [p.strip() for p in value.split(",")]
    if parts and ":" not in parts[0]:
        header["host"] = parts[0]
    for part in parts:
        if ":" not in part:
            continue
        k, _, v = part.partition(":")
        k, v = k.strip().lower(), v.strip()
        if k in ("host", "hostname"):
            header["host"] = v
        elif k == "kernel":
            header["kernel"] = v
        elif k == "page_size":
            header["page_size"] = int(v)


_STAT_ALIASES = {
    "sim_insts": ["sim_insts", "simInsts"],
    "host_seconds": ["host_seconds", "hostSeconds"],
    "sim_seconds": ["sim_seconds", "simSeconds"],
}


def load_stats(path: Path) -> Optional[Dict[str, float]]:
    """Parse gem5 stats.txt. Multi-dump: last block wins."""
    if not path.is_file():
        warnings.warn(f"stats.txt not found: {path}")
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        warnings.warn(f"cannot read stats.txt: {path}")
        return None
    if "Begin Simulation Statistics" not in text:
        warnings.warn(f"no stats block in {path}")
        return None
    blocks = text.split("---------- Begin Simulation Statistics ----------")
    result = {}
    for block in blocks:
        for line in block.splitlines():
            line = line.strip()
            if not line or line.startswith("---"):
                continue
            for norm, aliases in _STAT_ALIASES.items():
                for alias in aliases:
                    if line.startswith(alias + " ") or line.startswith(
                        alias + "\t"
                    ):
                        parts = line.split()
                        for p in parts[1:]:
                            if p.startswith("#"):
                                break
                            try:
                                result[norm] = float(p)
                            except ValueError:
                                pass
                            break
                        break
    return result if result else None


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
