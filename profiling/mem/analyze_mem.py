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


def compute_metrics(
    samples: list,
    stats: Optional[Dict[str, float]],
    cfg: Dict[str, Tuple[Any, str]],
) -> Dict[str, Any]:
    """Compute memory trend metrics from samples and optional stats."""
    warmup_s = cfg.get("warmup_seconds", (30, "default"))[0]
    min_samp = cfg.get("min_regression_samples", (5, "default"))[0]

    peak_rss = max(s["rss_kb"] for s in samples) if samples else 0.0
    peak_pss = max(s["pss_kb"] for s in samples) if samples else 0.0
    final_rss = samples[-1]["rss_kb"] if samples else 0.0
    baseline = samples[0]["rss_kb"] if samples else 0.0

    post = [s for s in samples if s["ts_ms"] >= warmup_s * 1000.0]
    growth_rate = None
    growth_reason = None
    if len(post) >= min_samp:
        xv = [s["ts_ms"] / 1000.0 for s in post]
        yv = [s["rss_kb"] for s in post]
        growth_rate, _ = _linear_regression(xv, yv)
    elif len(post) > 0:
        growth_reason = "insufficient_samples"
    else:
        growth_reason = "insufficient_samples"

    rss_per_msim = None
    if stats and stats.get("sim_insts", 0) > 0:
        rss_per_msim = (peak_rss - baseline) / (
            stats["sim_insts"] / 1_000_000.0
        )

    return {
        "peak_rss_kb": peak_rss,
        "peak_pss_kb": peak_pss,
        "final_rss_kb": final_rss,
        "warmup_end_s": warmup_s,
        "growth_rate_kb_per_s_post_warmup": growth_rate,
        "growth_rate_reason": growth_reason,
        "rss_per_msim_inst_kb": rss_per_msim,
        "n_samples": len(samples),
        "n_post_warmup": len(post),
    }


def _linear_regression(x: list, y: list) -> Tuple[float, float]:
    """Simple OLS: returns (slope, intercept)."""
    n = len(x)
    if n < 2:
        return 0.0, y[0] if n == 1 else 0.0
    sx, sy = sum(x), sum(y)
    sxx = sum(xi * xi for xi in x)
    sxy = sum(xi * yi for xi, yi in zip(x, y))
    denom = n * sxx - sx * sx
    if abs(denom) < 1e-15:
        return 0.0, sy / n
    slope = (n * sxy - sx * sy) / denom
    return slope, (sy - slope * sx) / n


def evaluate_gate(
    metrics: dict,
    cfg: Dict[str, Tuple[Any, str]],
    stats_present: bool,
) -> Tuple[str, int, list]:
    """Evaluate all configured thresholds. Returns (verdict, exit_code, failures)."""
    if cfg.get("require_stats_txt", (False, "d"))[0] and not stats_present:
        return (
            "fail",
            1,
            [
                {
                    "metric": "stats.txt",
                    "reason": "stats.txt required but absent",
                }
            ],
        )

    fail_mode = cfg.get("fail_mode", ("summary", "d"))[0]
    failures = []

    def _check(
        metric_key, current, threshold_cfg_key, unit_conv=1.0, label=None
    ):
        thr = cfg.get(threshold_cfg_key, (None, "d"))[0]
        if thr is None or current is None:
            return False
        if current * unit_conv > thr:
            failures.append(
                {
                    "metric": label or metric_key,
                    "current": current,
                    "threshold": thr,
                    "unit": metric_key,
                }
            )
            return True
        return False

    checks = [
        (
            "peak_rss_mb",
            metrics.get("peak_rss_kb"),
            "peak_rss_mb",
            1.0 / 1024.0,
            "peak_rss_mb",
        ),
        (
            "leak_bytes_per_sec",
            metrics.get("growth_rate_kb_per_s_post_warmup"),
            "leak_bytes_per_sec",
            1024.0,
            "leak_bytes_per_sec",
        ),
        (
            "rss_per_msim_inst_kb",
            metrics.get("rss_per_msim_inst_kb"),
            "rss_per_msim_inst_kb",
            1.0,
            "rss_per_msim_inst_kb",
        ),
    ]

    for metric_key, current, threshold_cfg_key, unit_conv, label in checks:
        breached = _check(
            metric_key, current, threshold_cfg_key, unit_conv, label
        )
        if breached and fail_mode == "fast":
            break

    if failures:
        return ("fail", 1, failures)
    return ("pass", 0, [])


def render_plot(samples, metrics, cfg, out_path):
    """Render RSS+PSS+heap over time to out_path. Returns Path or None."""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        warnings.warn("matplotlib not available; skipping plot")
        return None

    ts = [s["ts_ms"] / 1000.0 for s in samples]
    rss = [s["rss_kb"] / 1024.0 for s in samples]
    pss = (
        [s["pss_kb"] / 1024.0 for s in samples]
        if any(s.get("pss_kb", -1) >= 0 for s in samples)
        else None
    )
    heap = (
        [s["heap_kb"] / 1024.0 for s in samples]
        if any(s.get("heap_kb", -1) >= 0 for s in samples)
        else None
    )

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot(ts, rss, label="RSS", linewidth=1.5)
    if pss:
        ax.plot(ts, pss, label="PSS", linewidth=1.0, alpha=0.7)
    if heap:
        ax.plot(ts, heap, label="Heap", linewidth=1.0, alpha=0.7)

    warmup = metrics.get("warmup_end_s", 0)
    if warmup > 0:
        ax.axvspan(
            0, warmup, alpha=0.1, color="gray", label=f"Warmup ({warmup}s)"
        )

    peak_rss_mb = cfg.get("peak_rss_mb", (None,))[0]
    if peak_rss_mb:
        ax.axhline(
            y=peak_rss_mb,
            color="red",
            linestyle="--",
            alpha=0.5,
            label=f"Peak limit ({peak_rss_mb} MB)",
        )

    ax.set_xlabel("Wall time (s)")
    ax.set_ylabel("Memory (MB)")
    ax.set_title("gem5.opt Memory Trend")
    ax.legend(fontsize="small")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=100)
    plt.close(fig)
    return out_path


def write_report(
    header,
    samples,
    metrics,
    cfg,
    verdict,
    failures,
    heaptrack_summary,
    out_path,
):
    """Write markdown report to out_path."""
    lines = []
    lines.append("# gem5 Memory Trend Report")
    lines.append("")
    lines.append(
        f"**Verdict:** {verdict.upper()} "
        f"(exit {1 if verdict == 'fail' else 0})"
    )
    lines.append(f"**Tag:** {header.get('tag', '')}")
    lines.append(f"**Start:** {header.get('start_wall', '')}")
    lines.append(f"**PID:** {header.get('pid', '')}")
    lines.append("")

    # Effective configuration
    lines.append("## Effective configuration")
    lines.append("")
    lines.append("| Key | Value | Source |")
    lines.append("|-----|-------|--------|")
    for key in sorted(cfg):
        val, src = cfg[key]
        lines.append(f"| {key} | {val} | {src} |")
    lines.append("")

    # Metrics
    lines.append("## Metrics")
    lines.append("")
    lines.append(
        f"- **Peak RSS:** {metrics.get('peak_rss_kb', 0)/1024:.1f} MB"
    )
    lines.append(
        f"- **Peak PSS:** {metrics.get('peak_pss_kb', 0)/1024:.1f} MB"
    )
    lines.append(
        f"- **Final RSS:** {metrics.get('final_rss_kb', 0)/1024:.1f} MB"
    )
    gr = metrics.get("growth_rate_kb_per_s_post_warmup")
    if gr is not None:
        lines.append(f"- **Growth rate (post-warmup):** {gr:.2f} KB/s")
        lines.append(
            f"- **Growth rate:** {gr * 1024:.0f} B/s "
            f"({gr * 1024 / 1048576:.2f} MB/s)"
        )
    else:
        lines.append(
            f"- **Growth rate:** N/A "
            f"({metrics.get('growth_rate_reason', '')})"
        )
    rpm = metrics.get("rss_per_msim_inst_kb")
    if rpm is not None:
        lines.append(f"- **RSS per M-simInsts:** {rpm:.2f} KB")
    lines.append(
        f"- **Samples:** {metrics.get('n_samples', 0)} total, "
        f"{metrics.get('n_post_warmup', 0)} post-warmup"
    )
    lines.append("")

    # Failures
    if failures:
        lines.append("## Threshold Failures")
        lines.append("")
        for f in failures:
            lines.append(
                f"- **{f['metric']}**: "
                f"{f.get('current', 'N/A')} > "
                f"{f.get('threshold', 'N/A')}"
            )
        lines.append("")

    # Heaptrack
    if heaptrack_summary:
        lines.append("## Heaptrack Summary")
        lines.append("")
        lines.append(heaptrack_summary)
        lines.append("")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out_path


def write_metrics_json(header, metrics, cfg, verdict, failures, out_path):
    """Write machine-readable metrics + config to JSON."""
    import json

    data = {k: v for k, v in metrics.items() if not k.startswith("_")}
    data["tag"] = header.get("tag", "")
    data["start_wall"] = header.get("start_wall", "")
    data["pid"] = header.get("pid", 0)
    data["effective_config"] = {
        k: {"value": v[0], "source": v[1]} for k, v in cfg.items()
    }
    data["gate"] = {
        "verdict": verdict,
        "exit_code": 1 if verdict == "fail" else 0,
        "failures": failures,
    }
    out_path.write_text(
        json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8"
    )
    return out_path


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
