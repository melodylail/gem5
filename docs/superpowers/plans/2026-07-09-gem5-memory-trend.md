# Memory Usage Trend Evaluation for gem5.opt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Layer 3 memory-trend evaluation to the existing `profiling/` pipeline — a bash sidecar sampler + Python analyzer that produce CSV, plot, report, JSON metrics, and a threshold-based gate without touching gem5 source.

**Architecture:** Three cooperating pieces under `profiling/mem/`: `mem_sample.sh` (sidecar /proc sampler in bash), `analyze_mem.py` (post-run CSV x stats.txt analyzer in Python 3.8+), `deep_run.sh` (heaptrack wrapper). Opt-in via `MEM_TREND=1` in `profiling/run.sh`.

**Tech Stack:** Python 3.8+ (stdlib + matplotlib + pyyaml), bash (set -euo pipefail), C (fake_gem5 test tool), pytest + syrupy (unit), bash assert.sh (integration/e2e)

## Global Constraints

- Python 3.8+; deps: stdlib, `matplotlib`, `pyyaml` (both in gem5's `requirements.txt`)
- Bash scripts: `set -euo pipefail`, matching existing `profiling/*.sh` style
- No `rm -rf $OUTPUT_DIR` — analyzer writes fresh filenames, cleanup is user's job
- No `sudo` — hardened-kernel access handled by smaps_rollup fallback
- No network, no root, no >200 MB memory in any test
- Analyzer unit-test coverage >=90%; sampler integration coverage >=80% on reachable branches
- `MEM_TREND=1` opt-in — existing `profiling/run.sh` users see no behavior change
- Commit tags: `misc:` for tools/scripts, `doc:` for docs (validated against MAINTAINERS.yaml)
- Linux-only; tests marked `skipif(sys.platform != "linux")`
- CLI > env > YAML > default precedence for every configurable knob
- Gate exit codes: 0=pass, 1=threshold breached, 2=cannot evaluate

---

### Task 1: Scaffolding + policy YAML

**Files:**
- Create: `profiling/mem/mem_thresholds.yaml`
- Create: `profiling/mem/tests/__init__.py`
- Create: `profiling/mem/tests/unit/__init__.py`
- Create: `profiling/mem/tests/unit/conftest.py`

**Interfaces:**
- Consumes: *(none — first task)*
- Produces: `mem_thresholds.yaml` (default policy — all thresholds unset/commented), `conftest.py` with `skipif` marker

- [ ] **Step 1: Create mem_thresholds.yaml**

```yaml
# profiling/mem/mem_thresholds.yaml
# Default policy. All thresholds are unset (commented) — the default gate is
# "no thresholds → pass". Uncomment and set values to enable gating.
# Per-workload policies go under profiling/mem/policies/<workload>.yaml.

# warmup_seconds: 30
#   Seconds from run start to exclude from leak detection (startup ramp).
#
# peak_rss_mb: 8192
#   Fail if peak RSS exceeds this value (megabytes).
#
# leak_bytes_per_sec: 524288
#   Fail if post-warmup RSS growth rate exceeds this (bytes/second).
#
# rss_per_msim_inst_kb: null
#   RSS cost per million simulated instructions. null = compute but don't gate.
#
# require_stats_txt: false
#   If true, fail when stats.txt is absent/unparseable.
#
# min_regression_samples: 5
#   Minimum post-warmup samples needed to compute growth_rate.
#
# fail_mode: summary
#   'summary' = evaluate all thresholds before reporting.
#   'fast'    = stop at first breach.
```

- [ ] **Step 2: Create __init__.py files and conftest.py**

```python
# profiling/mem/tests/__init__.py
```

```python
# profiling/mem/tests/unit/__init__.py
```

```python
# profiling/mem/tests/unit/conftest.py
"""Shared fixtures and markers for analyzer unit tests."""
import sys
import pytest


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "linux_only: test requires Linux /proc filesystem",
    )


def pytest_collection_modifyitems(config, items):
    skip_linux = pytest.mark.skip(
        reason="test requires Linux /proc"
    )
    for item in items:
        if "linux_only" in item.keywords and sys.platform != "linux":
            item.add_marker(skip_linux)
```

- [ ] **Step 3: Run: verify conftest works**

```bash
cd profiling/mem/tests/unit && python -m pytest --collect-only 2>&1 | head -5
```

- [ ] **Step 4: Commit**

```bash
mkdir -p profiling/mem/tests/unit
git add profiling/mem/mem_thresholds.yaml \
        profiling/mem/tests/__init__.py \
        profiling/mem/tests/unit/__init__.py \
        profiling/mem/tests/unit/conftest.py
git commit -m "misc: add memory trend scaffolding and default policy YAML"
```

---

### Task 2: Config resolution — `resolve_config()`

**Files:**
- Create: `profiling/mem/analyze_mem.py` (stub with resolve_config only)
- Create: `profiling/mem/tests/unit/test_config_resolution.py`

**Interfaces:**
- Produces: `resolve_config(cli: dict, env: dict, yaml_path: Optional[Path], defaults: dict) -> dict[str, tuple[Any, str]]`

- [ ] **Step 1: Write failing tests**

```python
# profiling/mem/tests/unit/test_config_resolution.py
import sys, os, pytest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import resolve_config

DEFAULTS = {
    "warmup_seconds": 30, "peak_rss_mb": None, "leak_bytes_per_sec": None,
    "rss_per_msim_inst_kb": None, "require_stats_txt": False,
    "min_regression_samples": 5, "fail_mode": "summary",
}

def test_all_defaults():
    cfg = resolve_config(cli={}, env={}, yaml_path=None, defaults=DEFAULTS)
    for k, v in DEFAULTS.items():
        assert cfg[k] == (v, "default"), f"key={k}"

def test_cli_beats_all():
    cfg = resolve_config(cli={"peak_rss_mb": 12000}, env={"MEM_PEAK_RSS_MB": "8192"},
                         yaml_path=None, defaults=DEFAULTS)
    assert cfg["peak_rss_mb"] == (12000, "cli")

def test_env_beats_yaml(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("peak_rss_mb: 4096\nwarmup_seconds: 60\n")
    cfg = resolve_config(cli={}, env={"MEM_PEAK_RSS_MB": "8192"}, yaml_path=yf, defaults=DEFAULTS)
    assert cfg["peak_rss_mb"] == (8192, "env")
    assert cfg["warmup_seconds"] == (60, "yaml")

def test_yaml_beats_default(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("warmup_seconds: 45\nfail_mode: fast\n")
    cfg = resolve_config(cli={}, env={}, yaml_path=yf, defaults=DEFAULTS)
    assert cfg["warmup_seconds"] == (45, "yaml")
    assert cfg["fail_mode"] == ("fast", "yaml")

def test_env_type_coercion():
    cfg = resolve_config(cli={}, env={"MEM_WARMUP_SECONDS": "90",
        "MEM_MIN_REGRESSION_SAMPLES": "10", "MEM_REQUIRE_STATS_TXT": "true"},
        yaml_path=None, defaults=DEFAULTS)
    assert cfg["warmup_seconds"] == (90, "env")
    assert isinstance(cfg["warmup_seconds"][0], int)
    assert cfg["require_stats_txt"] == (True, "env")

@pytest.mark.parametrize("val", ["false","0","False","no"])
def test_env_false_strings(val):
    cfg = resolve_config(cli={}, env={"MEM_REQUIRE_STATS_TXT": val},
                         yaml_path=None, defaults=DEFAULTS)
    assert cfg["require_stats_txt"] == (False, "env")

def test_missing_yaml_not_error(tmp_path):
    cfg = resolve_config(cli={}, env={}, yaml_path=tmp_path/"nope.yaml", defaults=DEFAULTS)
    for k in DEFAULTS:
        assert cfg[k] == (DEFAULTS[k], "default")

def test_unknown_yaml_key_warns(tmp_path):
    yf = tmp_path / "p.yaml"
    yf.write_text("warmup_seconds: 30\nfuture_feature: 42\n")
    cfg = resolve_config(cli={}, env={}, yaml_path=yf, defaults=DEFAULTS)
    assert "future_feature" not in cfg
    assert cfg["warmup_seconds"] == (30, "yaml")

def test_all_keys_present(tmp_path):
    cfg = resolve_config(cli={"peak_rss_mb": 1024}, env={"MEM_LEAK_BPS": "262144"},
                         yaml_path=None, defaults=DEFAULTS)
    for k in DEFAULTS:
        assert k in cfg
```

- [ ] **Step 2: Run → FAIL (ImportError)**

```bash
cd profiling/mem/tests/unit && python -m pytest test_config_resolution.py -v 2>&1 | tail -3
```

- [ ] **Step 3: Implement resolve_config in analyze_mem.py**

```python
# profiling/mem/analyze_mem.py
"""Memory trend analyzer for gem5.opt — CSV x stats.txt -> metrics, plot, gate."""
import os, sys, warnings
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

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


def resolve_config(cli: Dict[str, Any], env: Dict[str, str],
                   yaml_path: Optional[Path],
                   defaults: Dict[str, Any]) -> Dict[str, Tuple[Any, str]]:
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
        with open(yaml_path, "r", encoding="utf-8") as fh:
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
```

- [ ] **Step 4: Run tests → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_config_resolution.py -v
```

- [ ] **Step 5: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_config_resolution.py
git commit -m "misc: add resolve_config with CLI > env > YAML > default precedence"
```

---

### Task 3: CSV parser — `load_csv()`

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add load_csv + helpers)
- Create: `profiling/mem/tests/unit/test_csv_parser.py`
- Create: `profiling/mem/tests/fixtures/mem_trend_normal.csv`
- Create: `profiling/mem/tests/fixtures/mem_trend_appended.csv`
- Create: `profiling/mem/tests/fixtures/mem_trend_malformed.csv`

**Interfaces:**
- Produces: `load_csv(path: Path) -> Tuple[Dict[str, Any], List[Dict[str, float]]]`

- [ ] **Step 1: Create CSV fixtures**

```bash
mkdir -p profiling/mem/tests/fixtures
```

**profiling/mem/tests/fixtures/mem_trend_normal.csv:**
```
# gem5_cmd: build/ALL/gem5.opt configs/se_profile.py --binary workload
# start_wall: 2026-07-09T14:03:11+08:00
# interval_s: 1.0
# pid: 48211
# host: testhost, kernel: 6.8.0-test, page_size: 4096
# tag: normal-run
# attached: false
ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase
0,42116,41870,41200,15360,26756,15360,0,unknown
1000,48432,48101,47400,19456,28976,15360,0,unknown
2000,54632,54201,53500,23552,31176,15360,0,unknown
3000,60832,60401,59600,27648,33376,15360,0,unknown
4000,66032,65501,64600,30720,35576,15360,0,unknown
5000,71232,70601,69600,33792,37776,15360,0,unknown
6000,76432,75701,74600,36864,39976,15360,0,unknown
7000,81632,80801,79600,39936,42176,15360,0,unknown
8000,85832,84901,83600,41984,44176,15360,0,unknown
9000,90032,89001,87600,44032,46176,15360,0,unknown
```

**profiling/mem/tests/fixtures/mem_trend_appended.csv:**
```
# gem5_cmd: build/ALL/gem5.opt configs/se_profile.py --binary workload
# start_wall: 2026-07-09T14:03:11+08:00
# interval_s: 1.0
# pid: 48214
# host: testhost, kernel: 6.8.0-test, page_size: 4096
# tag: appended-run
# attached: true
ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase
0,40000,39500,39000,10000,30000,10000,0,unknown
1000,41000,40400,39900,11000,30000,10000,0,unknown
2000,42000,41300,40800,12000,30000,10000,0,unknown
# segment_start: 2026-07-09T14:05:00+08:00
3000,42000,41300,40800,12000,30000,10000,0,unknown
4000,43000,42300,41800,13000,30000,10000,0,unknown
```

**profiling/mem/tests/fixtures/mem_trend_malformed.csv:**
```
# gem5_cmd: test
# start_wall: 2026-07-09T14:03:11+08:00
# interval_s: 1.0
# pid: 1
# host: testhost, kernel: 6.8.0-test, page_size: 4096
# tag: malformed
# attached: false
ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase
0,1000,990,980,100,900,100,0,unknown
1000,2000,1990,1980
2000,3000,2990,2980,300,2700,300,0,unknown
```

- [ ] **Step 2: Write failing test**

```python
# profiling/mem/tests/unit/test_csv_parser.py
import sys, tempfile, os
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
    with tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False) as f:
        f.write("# gem5_cmd: test\n# start_wall: 2026-01-01\n"
                "# interval_s: 1.0\n# pid: 1\n"
                "# host: h, kernel: k, page_size: 4096\n"
                "# tag: empty\n# attached: false\n"
                "ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase\n")
    try:
        h, s = load_csv(Path(f.name))
        assert s == []
        assert h["tag"] == "empty"
    finally:
        os.unlink(f.name)
```

- [ ] **Step 3: Run → FAIL (ImportError)**

- [ ] **Step 4: Add load_csv to analyze_mem.py**

```python
# Add after resolve_config block in analyze_mem.py

_DATA_COLUMNS = [
    "ts_ms", "rss_kb", "pss_kb", "uss_kb", "heap_kb",
    "anon_kb", "file_kb", "swap_kb", "gem5_phase",
]
_NUMERIC_COLS = frozenset(_DATA_COLUMNS[:-1])


def load_csv(path: Path) -> Tuple[Dict[str, Any], list]:
    """Parse memory trend CSV. Returns (header_dict, samples_list)."""
    if not path.is_file():
        raise FileNotFoundError(f"CSV not found: {path}")

    header: Dict[str, Any] = {
        "gem5_cmd": "", "start_wall": "", "interval_s": 1.0,
        "pid": 0, "host": "", "kernel": "", "page_size": 4096,
        "tag": "", "attached": False, "smaps_rollup_unavailable": False,
        "segments": [],
    }
    samples: list = []
    expected = len(_DATA_COLUMNS)

    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n\r")
            if line.startswith("#"):
                content = line[1:].strip()
                if content.startswith("segment_start:"):
                    header["segments"].append(content.split(":", 1)[1].strip())
                elif ":" in content:
                    k, _, v = content.partition(":")
                    k, v = k.strip().lower(), v.strip()
                    if k == "gem5_cmd": header["gem5_cmd"] = v
                    elif k == "start_wall": header["start_wall"] = v
                    elif k == "interval_s": header["interval_s"] = float(v)
                    elif k == "pid": header["pid"] = int(v)
                    elif k == "host": _parse_host_line(v, header)
                    elif k == "tag": header["tag"] = v
                    elif k == "attached":
                        header["attached"] = v.lower() in ("true", "1", "yes")
                    elif k == "smaps_rollup_unavailable":
                        header["smaps_rollup_unavailable"] = v.lower() in ("true", "1", "yes")
                continue
            if not line.strip():
                continue
            fields = line.split(",")
            if fields[0].strip() == "ts_ms":
                continue
            if len(fields) != expected:
                warnings.warn(f"skipping malformed row: expected {expected} cols, got {len(fields)}")
                continue
            sample = {}
            for i, col in enumerate(_DATA_COLUMNS):
                val = fields[i].strip()
                sample[col] = float(val) if col in _NUMERIC_COLS and val else 0.0
            samples.append(sample)
    return header, samples


def _parse_host_line(value: str, header: Dict[str, Any]) -> None:
    for part in [p.strip() for p in value.split(",")]:
        if ":" not in part: continue
        k, _, v = part.partition(":")
        k, v = k.strip().lower(), v.strip()
        if k in ("host", "hostname"): header["host"] = v
        elif k == "kernel": header["kernel"] = v
        elif k == "page_size": header["page_size"] = int(v)
```

- [ ] **Step 5: Run → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_csv_parser.py -v
```

- [ ] **Step 6: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_csv_parser.py \
        profiling/mem/tests/fixtures/
git commit -m "misc: add CSV parser load_csv with segment and malformed-row handling"
```

---

### Task 4: Stats.txt parser — `load_stats()`

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add load_stats)
- Create: `profiling/mem/tests/unit/test_stats_txt_parser.py`
- Create: `profiling/mem/tests/fixtures/stats_normal.txt`
- Create: `profiling/mem/tests/fixtures/stats_multi_dump.txt`

**Interfaces:**
- Produces: `load_stats(path: Path) -> Optional[Dict[str, float]]`

- [ ] **Step 1: Create fixture stats files**

**profiling/mem/tests/fixtures/stats_normal.txt:**
```
---------- Begin Simulation Statistics ----------
sim_insts                     1500000000                       # Number of instructions simulated
sim_seconds                      0.001000                       # Number of seconds simulated
host_seconds                    45.234000                       # Real time elapsed on the host
---------- End Simulation Statistics ----------
```

**profiling/mem/tests/fixtures/stats_multi_dump.txt:**
```
---------- Begin Simulation Statistics ----------
simInsts                       500000000
simSeconds                     0.000300
hostSeconds                    15.000000
---------- End Simulation Statistics ----------
---------- Begin Simulation Statistics ----------
simInsts                      1500000000
simSeconds                     0.001000
hostSeconds                    45.234000
---------- End Simulation Statistics ----------
```

- [ ] **Step 2: Write failing test**

```python
# profiling/mem/tests/unit/test_stats_txt_parser.py
import sys; from pathlib import Path; import pytest
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
    f = tmp_path / "j.txt"; f.write_text("not gem5"); assert load_stats(f) is None
```

- [ ] **Step 3: Run → FAIL**

- [ ] **Step 4: Implement load_stats**

```python
# Add to analyze_mem.py

_STAT_ALIASES = {
    "sim_insts": ["sim_insts", "simInsts"],
    "host_seconds": ["host_seconds", "hostSeconds"],
    "sim_seconds": ["sim_seconds", "simSeconds"],
}

def load_stats(path: Path) -> Optional[Dict[str, float]]:
    """Parse gem5 stats.txt. Multi-dump: last block wins."""
    if not path.is_file():
        warnings.warn(f"stats.txt not found: {path}"); return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        warnings.warn(f"cannot read stats.txt: {path}"); return None
    if "Begin Simulation Statistics" not in text:
        warnings.warn(f"no stats block in {path}"); return None
    blocks = text.split("---------- Begin Simulation Statistics ----------")
    result = {}
    for block in blocks:
        for line in block.splitlines():
            line = line.strip()
            if not line or line.startswith("---"): continue
            for norm, aliases in _STAT_ALIASES.items():
                for alias in aliases:
                    if line.startswith(alias + " ") or line.startswith(alias + "\t"):
                        parts = line.split()
                        for p in parts[1:]:
                            if p.startswith("#"): break
                            try: result[norm] = float(p)
                            except ValueError: pass
                            break
                        break
    return result if result else None
```

- [ ] **Step 5: Run → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_stats_txt_parser.py -v
```

- [ ] **Step 6: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_stats_txt_parser.py \
        profiling/mem/tests/fixtures/stats_normal.txt \
        profiling/mem/tests/fixtures/stats_multi_dump.txt
git commit -m "misc: add stats.txt parser load_stats with multi-dump support"
```

---

### Task 5: Metrics computation — `compute_metrics()`

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add compute_metrics + _linear_regression)
- Create: `profiling/mem/tests/unit/test_metrics.py`

**Interfaces:**
- Consumes: `load_csv` (Task 3), `load_stats` (Task 4)
- Produces: `compute_metrics(samples: list, stats: Optional[Dict], cfg: Dict[str, Tuple[Any, str]]) -> Dict[str, Any]`

- [ ] **Step 1: Write failing test**

```python
# profiling/mem/tests/unit/test_metrics.py
import sys; from pathlib import Path; import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import compute_metrics, load_csv

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"

def _cfg(**kw):
    base = {"warmup_seconds": (30, "default"), "peak_rss_mb": (None, "default"),
        "leak_bytes_per_sec": (None, "default"), "rss_per_msim_inst_kb": (None, "default"),
        "require_stats_txt": (False, "default"), "min_regression_samples": (5, "default"),
        "fail_mode": ("summary", "default")}
    base.update(kw); return base

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
        samples.append({"ts_ms": t_s * 1000.0, "rss_kb": 10000.0 + 2.0 * t_s,
            "pss_kb": 0.0, "uss_kb": 0.0, "heap_kb": 0.0,
            "anon_kb": 0.0, "file_kb": 0.0, "swap_kb": 0.0, "gem5_phase": "ok"})
    m = compute_metrics(samples, None, _cfg(warmup_seconds=(10, "default")))
    assert m["growth_rate_kb_per_s_post_warmup"] is not None
    assert m["growth_rate_kb_per_s_post_warmup"] == pytest.approx(2.0, abs=0.1)
    assert m["n_post_warmup"] == 40

def test_sample_counts():
    _, s = load_csv(FIXTURES / "mem_trend_normal.csv")
    m = compute_metrics(s, None, _cfg())
    assert m["n_samples"] == 10
    assert m["n_post_warmup"] == 0  # all within 0-9s < 30s warmup
```

- [ ] **Step 2: Run → FAIL (ImportError)**

- [ ] **Step 3: Implement compute_metrics**

```python
# Add to analyze_mem.py

def compute_metrics(samples: list, stats: Optional[Dict[str, float]],
                    cfg: Dict[str, Tuple[Any, str]]) -> Dict[str, Any]:
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
        rss_per_msim = (peak_rss - baseline) / (stats["sim_insts"] / 1_000_000.0)

    return {
        "peak_rss_kb": peak_rss, "peak_pss_kb": peak_pss,
        "final_rss_kb": final_rss, "warmup_end_s": warmup_s,
        "growth_rate_kb_per_s_post_warmup": growth_rate,
        "growth_rate_reason": growth_reason,
        "rss_per_msim_inst_kb": rss_per_msim,
        "n_samples": len(samples), "n_post_warmup": len(post),
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
```

- [ ] **Step 4: Run → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_metrics.py -v
```

- [ ] **Step 5: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_metrics.py
git commit -m "misc: add compute_metrics with linear regression and RSS-per-MsimInst"
```

---

### Task 6: Gate evaluation — `evaluate_gate()`

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add evaluate_gate)
- Create: `profiling/mem/tests/unit/test_gate.py`

**Interfaces:**
- Consumes: `compute_metrics` (Task 5), `resolve_config` (Task 2)
- Produces: `evaluate_gate(metrics: dict, cfg: dict, stats_present: bool) -> Tuple[str, int, list]`
  - Returns `(verdict, exit_code, failures_list)` where exit_code ∈ {0, 1, 2}

- [ ] **Step 1: Write failing test**

```python
# profiling/mem/tests/unit/test_gate.py
import sys; from pathlib import Path; import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import evaluate_gate

def _cfg(**kw):
    base = {"warmup_seconds": (30, "d"), "peak_rss_mb": (None, "d"),
        "leak_bytes_per_sec": (None, "d"), "rss_per_msim_inst_kb": (None, "d"),
        "require_stats_txt": (False, "d"), "min_regression_samples": (5, "d"),
        "fail_mode": ("summary", "d")}
    base.update(kw); return base

def test_no_thresholds_pass():
    v, code, fails = evaluate_gate({}, _cfg(), True)
    assert code == 0 and v == "pass"

def test_all_pass():
    m = {"peak_rss_kb": 1000, "growth_rate_kb_per_s_post_warmup": 10.0,
         "rss_per_msim_inst_kb": 5.0}
    c = _cfg(peak_rss_mb=(2000, "c"), leak_bytes_per_sec=(20480.0, "c"),
             rss_per_msim_inst_kb=(10.0, "c"))
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 0

def test_peak_breached():
    m = {"peak_rss_kb": 10_000_000}  # ~10GB
    c = _cfg(peak_rss_mb=(1000, "c"))  # 1GB limit
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 1
    assert any("peak_rss" in f["metric"] for f in fails)

def test_leak_breached():
    m = {"growth_rate_kb_per_s_post_warmup": 1000.0, "growth_rate_reason": None}
    c = _cfg(leak_bytes_per_sec=(500.0 * 1024, "c"))  # 500 KB/s
    # 1000 KB/s > 500 KB/s
    v, code, fails = evaluate_gate(m, c, True)
    assert code == 1

def test_leak_null_skipped():
    m = {"growth_rate_kb_per_s_post_warmup": None, "growth_rate_reason": "insufficient_samples"}
    c = _cfg(leak_bytes_per_sec=(100.0, "c"))
    v, code, _ = evaluate_gate(m, c, True)
    assert code == 0  # null => skip, not fail

def test_fail_fast_stops_early():
    m = {"peak_rss_kb": 10_000_000, "growth_rate_kb_per_s_post_warmup": 1000.0}
    c = _cfg(peak_rss_mb=(1000, "c"), leak_bytes_per_sec=(500.0, "c"),
             fail_mode=("fast", "c"))
    _, code, fails = evaluate_gate(m, c, True)
    assert code == 1
    assert len(fails) == 1  # stopped after first

def test_fail_summary_collects_all():
    m = {"peak_rss_kb": 10_000_000, "growth_rate_kb_per_s_post_warmup": 9999.0}
    c = _cfg(peak_rss_mb=(1000, "c"), leak_bytes_per_sec=(1.0, "c"),
             fail_mode=("summary", "c"))
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
```

- [ ] **Step 2: Run → FAIL**

- [ ] **Step 3: Implement evaluate_gate**

```python
# Add to analyze_mem.py

def evaluate_gate(metrics: dict, cfg: Dict[str, Tuple[Any, str]],
                  stats_present: bool) -> Tuple[str, int, list]:
    """Evaluate all configured thresholds. Returns (verdict, exit_code, failures)."""
    # Check require_stats_txt
    if cfg.get("require_stats_txt", (False, "d"))[0] and not stats_present:
        return ("fail", 1, [{"metric": "require_stats_txt",
                              "reason": "stats.txt required but absent"}])

    fail_mode = cfg.get("fail_mode", ("summary", "d"))[0]
    failures = []

    def _check(metric_key, current, threshold_cfg_key, unit_conv=1.0, label=None):
        thr = cfg.get(threshold_cfg_key, (None, "d"))[0]
        if thr is None or current is None:
            return
        if current * unit_conv > thr:
            failures.append({"metric": label or metric_key,
                             "current": current, "threshold": thr,
                             "unit": metric_key})
            if fail_mode == "fast":
                return "stop"

    _check("peak_rss_mb", metrics.get("peak_rss_kb", 0), "peak_rss_mb",
           unit_conv=1.0/1024.0, label="peak_rss_mb")
    _check("leak_bytes_per_sec", metrics.get("growth_rate_kb_per_s_post_warmup", 0),
           "leak_bytes_per_sec", unit_conv=1024.0, label="leak_bytes_per_sec")
    _check("rss_per_msim_inst_kb", metrics.get("rss_per_msim_inst_kb"),
           "rss_per_msim_inst_kb", label="rss_per_msim_inst_kb")

    if failures:
        return ("fail", 1, failures)
    return ("pass", 0, [])
```

- [ ] **Step 4: Run → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_gate.py -v
```

- [ ] **Step 5: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_gate.py
git commit -m "misc: add evaluate_gate with summary/fast fail modes and exit codes"
```

---

### Task 7: Plot + report + snapshot test

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add render_plot, write_report, write_metrics_json)
- Create: `profiling/mem/tests/unit/test_report_snapshot.py`
- Create: `profiling/mem/tests/fixtures/policies/strict.yaml`
- Create: `profiling/mem/tests/fixtures/policies/lenient.yaml`
- Create: `profiling/mem/tests/fixtures/mem_trend_leak.csv`

**Interfaces:**
- Consumes: `compute_metrics` (Task 5), `evaluate_gate` (Task 6), `load_csv` (Task 3)
- Produces:
  - `render_plot(samples, metrics, cfg, out_path) -> Optional[Path]`
  - `write_report(header, samples, metrics, cfg, verdict, failures, heaptrack_summary, out_path) -> Path`
  - `write_metrics_json(header, metrics, cfg, verdict, failures, out_path) -> Path`

- [ ] **Step 1: Create fixtures**

**profiling/mem/tests/fixtures/mem_trend_leak.csv:**
```
# gem5_cmd: build/ALL/gem5.opt configs/se_profile.py --binary workload
# start_wall: 2026-07-09T14:03:11+08:00
# interval_s: 5.0
# pid: 48212
# host: testhost, kernel: 6.8.0-test, page_size: 4096
# tag: leak-run
# attached: false
ts_ms,rss_kb,pss_kb,uss_kb,heap_kb,anon_kb,file_kb,swap_kb,gem5_phase
0,50000,49500,49000,10000,40000,10000,0,unknown
5000,52000,51400,50900,12000,40000,10000,0,unknown
10000,54000,53300,52800,14000,40000,10000,0,unknown
15000,56000,55300,54800,16000,40000,10000,0,unknown
20000,59000,58300,57800,19000,40000,10000,0,unknown
25000,62000,61200,60700,22000,40000,10000,0,unknown
30000,65000,64100,63600,25000,40000,10000,0,unknown
35000,68500,67500,67000,28500,40000,10000,0,unknown
40000,72000,70900,70400,32000,40000,10000,0,unknown
45000,75500,74300,73800,35500,40000,10000,0,unknown
50000,79000,77700,77200,39000,40000,10000,0,unknown
55000,82500,81100,80600,42500,40000,10000,0,unknown
60000,86000,84500,84000,46000,40000,10000,0,unknown
```

**profiling/mem/tests/fixtures/policies/strict.yaml:**
```yaml
warmup_seconds: 30
peak_rss_mb: 100
leak_bytes_per_sec: 100
fail_mode: summary
```

**profiling/mem/tests/fixtures/policies/lenient.yaml:**
```yaml
warmup_seconds: 30
peak_rss_mb: 100000
leak_bytes_per_sec: 104857600
fail_mode: summary
```

```bash
mkdir -p profiling/mem/tests/fixtures/policies
```

- [ ] **Step 2: Write tests**

```python
# profiling/mem/tests/unit/test_report_snapshot.py
import sys, io, json; from pathlib import Path; import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from analyze_mem import (load_csv, resolve_config, compute_metrics,
                          evaluate_gate, write_report, write_metrics_json)

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
DEFAULTS = {"warmup_seconds": 30, "peak_rss_mb": None, "leak_bytes_per_sec": None,
    "rss_per_msim_inst_kb": None, "require_stats_txt": False,
    "min_regression_samples": 5, "fail_mode": "summary"}

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
    cfg = resolve_config(cli={}, env={"MEM_PEAK_RSS_MB": "10"},
                         yaml_path=None, defaults=DEFAULTS)
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
```

- [ ] **Step 3: Run → FAIL**

- [ ] **Step 4: Implement render_plot, write_report, write_metrics_json**

```python
# Add to analyze_mem.py

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
    pss = [s["pss_kb"] / 1024.0 for s in samples] if any(s.get("pss_kb", -1) >= 0 for s in samples) else None
    heap = [s["heap_kb"] / 1024.0 for s in samples] if any(s.get("heap_kb", -1) >= 0 for s in samples) else None

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot(ts, rss, label="RSS", linewidth=1.5)
    if pss: ax.plot(ts, pss, label="PSS", linewidth=1.0, alpha=0.7)
    if heap: ax.plot(ts, heap, label="Heap", linewidth=1.0, alpha=0.7)

    warmup = metrics.get("warmup_end_s", 0)
    if warmup > 0:
        ax.axvspan(0, warmup, alpha=0.1, color="gray", label=f"Warmup ({warmup}s)")

    peak_rss_mb = cfg.get("peak_rss_mb", (None,))[0]
    if peak_rss_mb:
        ax.axhline(y=peak_rss_mb, color="red", linestyle="--", alpha=0.5,
                   label=f"Peak limit ({peak_rss_mb} MB)")

    ax.set_xlabel("Wall time (s)")
    ax.set_ylabel("Memory (MB)")
    ax.set_title("gem5.opt Memory Trend")
    ax.legend(fontsize="small")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=100)
    plt.close(fig)
    return out_path


def write_report(header, samples, metrics, cfg, verdict, failures,
                 heaptrack_summary, out_path):
    """Write markdown report to out_path."""
    lines = []
    lines.append("# gem5 Memory Trend Report")
    lines.append("")
    lines.append(f"**Verdict:** {verdict.upper()} (exit {1 if verdict == 'fail' else 0})")
    lines.append(f"**Tag:** {header.get('tag', '')}")
    lines.append(f"**Start:** {header.get('start_wall', '')}")
    lines.append(f"**PID:** {header.get('pid', '')}")
    lines.append("")

    # Effective configuration
    lines.append("## Effective Configuration")
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
    lines.append(f"- **Peak RSS:** {metrics.get('peak_rss_kb', 0)/1024:.1f} MB")
    lines.append(f"- **Peak PSS:** {metrics.get('peak_pss_kb', 0)/1024:.1f} MB")
    lines.append(f"- **Final RSS:** {metrics.get('final_rss_kb', 0)/1024:.1f} MB")
    gr = metrics.get("growth_rate_kb_per_s_post_warmup")
    if gr is not None:
        lines.append(f"- **Growth rate (post-warmup):** {gr:.2f} KB/s")
        lines.append(f"- **Growth rate:** {gr * 1024:.0f} B/s ({gr * 1024 / 1048576:.2f} MB/s)")
    else:
        lines.append(f"- **Growth rate:** N/A ({metrics.get('growth_rate_reason', '')})")
    rpm = metrics.get("rss_per_msim_inst_kb")
    if rpm is not None:
        lines.append(f"- **RSS per M-simInsts:** {rpm:.2f} KB")
    lines.append(f"- **Samples:** {metrics.get('n_samples', 0)} total, "
                 f"{metrics.get('n_post_warmup', 0)} post-warmup")
    lines.append("")

    # Failures
    if failures:
        lines.append("## Threshold Failures")
        lines.append("")
        for f in failures:
            lines.append(f"- **{f['metric']}**: {f.get('current', 'N/A')} > {f.get('threshold', 'N/A')}")
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
    data = {
        "tag": header.get("tag", ""),
        "start_wall": header.get("start_wall", ""),
        "pid": header.get("pid", 0),
        "metrics": {k: v for k, v in metrics.items() if not k.startswith("_")},
        "effective_config": {k: {"value": v[0], "source": v[1]} for k, v in cfg.items()},
        "gate": {"verdict": verdict, "exit_code": 1 if verdict == "fail" else 0,
                 "failures": failures},
    }
    out_path.write_text(json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8")
    return out_path
```

- [ ] **Step 5: Run → PASS**

```bash
cd profiling/mem/tests/unit && python -m pytest test_report_snapshot.py -v
```

- [ ] **Step 6: Commit**

```bash
git add profiling/mem/analyze_mem.py profiling/mem/tests/unit/test_report_snapshot.py \
        profiling/mem/tests/fixtures/mem_trend_leak.csv \
        profiling/mem/tests/fixtures/policies/
git commit -m "misc: add plot, report, and metrics JSON output with config source tracking"
```

---

### Task 8: CLI wiring — `main()`

**Files:**
- Modify: `profiling/mem/analyze_mem.py` (add main + argparse)

**Interfaces:**
- Consumes: all prior analyze_mem functions (Tasks 2-7)
- Produces: `main(argv: list) -> int` — full CLI entry point, all knobs from spec §5.2

- [ ] **Step 1: Add main() with argparse to analyze_mem.py**

```python
# Add to end of analyze_mem.py

def main(argv=None):
    """Entry point: parse args, load data, compute, report, gate."""
    import argparse
    p = argparse.ArgumentParser(
        description="gem5 memory trend analyzer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # Paths
    pa = p.add_argument_group("paths")
    pa.add("--csv", default=os.environ.get("MEM_TREND_CSV", "./output/mem_trend.csv"),
           help="Input CSV [env: MEM_TREND_CSV]")
    pa.add("--stats", default=os.environ.get("GEM5_STATS_TXT", ""),
           help="gem5 stats.txt [env: GEM5_STATS_TXT]")
    pa.add("--policy", default=os.environ.get("MEM_POLICY_YAML", ""),
           help="Threshold policy YAML [env: MEM_POLICY_YAML]")
    pa.add("--heaptrack", default=os.environ.get("MEM_HEAPTRACK_GLOB", ""),
           help="Heaptrack output glob [env: MEM_HEAPTRACK_GLOB]")
    pa.add("--report", default=os.environ.get("MEM_REPORT_MD", ""),
           help="Report output [env: MEM_REPORT_MD]")
    pa.add("--metrics", default=os.environ.get("MEM_METRICS_JSON", ""),
           help="Metrics JSON [env: MEM_METRICS_JSON]")
    pa.add("--plot", default=os.environ.get("MEM_PLOT_PNG", ""),
           help="Plot PNG [env: MEM_PLOT_PNG]")
    pa.add("--no-plot", action="store_true",
           default=os.environ.get("MEM_NO_PLOT", "0") == "1",
           help="Disable plot [env: MEM_NO_PLOT=1]")
    pa.add("--tag", default=os.environ.get("MEM_RUN_TAG", ""),
           help="Run tag override [env: MEM_RUN_TAG]")

    # Thresholds
    ta = p.add_argument_group("thresholds & analysis")
    ta.add("--warmup-seconds", type=int,
           default=int(os.environ.get("MEM_WARMUP_SECONDS", "0")) or None,
           help="Warmup window (s) [env: MEM_WARMUP_SECONDS]")
    ta.add("--peak-rss-mb", type=float,
           default=float(os.environ.get("MEM_PEAK_RSS_MB", "0")) or None,
           help="Peak RSS limit (MB) [env: MEM_PEAK_RSS_MB]")
    ta.add("--leak-bytes-per-sec", type=float,
           default=float(os.environ.get("MEM_LEAK_BPS", "0")) or None,
           help="Leak rate limit (B/s) [env: MEM_LEAK_BPS]")
    ta.add("--rss-per-msim-kb", type=float,
           default=float(os.environ.get("MEM_RSS_PER_MSIM_KB", "0")) or None,
           help="RSS per M-simInst limit (KB) [env: MEM_RSS_PER_MSIM_KB]")
    ta.add("--require-stats-txt", action="store_true",
           default=os.environ.get("MEM_REQUIRE_STATS_TXT", "0") == "1",
           help="Fail if stats.txt absent [env: MEM_REQUIRE_STATS_TXT]")
    ta.add("--min-regression-samples", type=int,
           default=int(os.environ.get("MEM_MIN_REGRESSION_SAMPLES", "0")) or None,
           help="Min post-warmup samples [env: MEM_MIN_REGRESSION_SAMPLES]")
    ta.add("--fail-fast", action="store_true",
           default=os.environ.get("MEM_FAIL_MODE", "summary") == "fast",
           help="Stop at first breach [env: MEM_FAIL_MODE=fast]")

    args = p.parse_args(argv)

    # Resolve paths
    csv_path = Path(args.csv)
    if not csv_path.is_file():
        print(f"ERROR: mem_trend.csv not found: {csv_path}", file=sys.stderr)
        return 2

    csv_dir = csv_path.parent
    stats_path = Path(args.stats) if args.stats else csv_dir / "stats.txt"
    policy_path = Path(args.policy) if args.policy else None
    if policy_path and not policy_path.is_file():
        policy_path = None  # spec: skip if absent

    report_path = Path(args.report) if args.report else csv_dir / "mem_report.md"
    metrics_path = Path(args.metrics) if args.metrics else csv_dir / "mem_metrics.json"
    plot_path = Path(args.plot) if args.plot else csv_dir / "mem_trend.png"

    # Build CLI overrides dict
    cli = {}
    if args.warmup_seconds is not None: cli["warmup_seconds"] = args.warmup_seconds
    if args.peak_rss_mb is not None: cli["peak_rss_mb"] = args.peak_rss_mb
    if args.leak_bytes_per_sec is not None: cli["leak_bytes_per_sec"] = args.leak_bytes_per_sec
    if args.rss_per_msim_kb is not None: cli["rss_per_msim_inst_kb"] = args.rss_per_msim_kb
    if args.require_stats_txt: cli["require_stats_txt"] = True
    if args.min_regression_samples is not None: cli["min_regression_samples"] = args.min_regression_samples
    cli["fail_mode"] = "fast" if args.fail_fast else "summary"

    # Resolve config
    DEFAULTS = {"warmup_seconds": 30, "peak_rss_mb": None, "leak_bytes_per_sec": None,
        "rss_per_msim_inst_kb": None, "require_stats_txt": False,
        "min_regression_samples": 5, "fail_mode": "summary"}
    cfg = resolve_config(cli=cli, env=os.environ, yaml_path=policy_path, defaults=DEFAULTS)

    # Load data
    header, samples = load_csv(csv_path)
    if not samples:
        print("ERROR: no samples collected", file=sys.stderr)
        return 2

    if args.tag:
        header["tag"] = args.tag

    stats = load_stats(stats_path) if stats_path.is_file() else None

    # Compute
    metrics = compute_metrics(samples, stats, cfg)

    # Plot
    if not args.no_plot:
        plot_result = render_plot(samples, metrics, cfg, plot_path)

    # Gate
    verdict, exit_code, failures = evaluate_gate(metrics, cfg, stats is not None)

    # Heaptrack summary
    heaptrack_text = _summarize_heaptrack(args.heaptrack) if args.heaptrack else None

    # Output
    write_report(header, samples, metrics, cfg, verdict, failures, heaptrack_text, report_path)
    write_metrics_json(header, metrics, cfg, verdict, failures, metrics_path)

    print(f"Report: {report_path}")
    print(f"Metrics: {metrics_path}")
    if not args.no_plot:
        print(f"Plot: {plot_path}")
    print(f"Gate: {verdict} (exit {exit_code})")
    return exit_code


def _summarize_heaptrack(glob_pattern):
    """Return top-10 allocators from heaptrack print output, or None."""
    import glob as glob_mod
    files = glob_mod.glob(glob_pattern)
    if not files:
        warnings.warn(f"no heaptrack files matching: {glob_pattern}")
        return None
    # For v1: look for heaptrack print output (pre-captured text), not .gz parsing
    lines = []
    for fp in files:
        try:
            lines.append(Path(fp).read_text(encoding="utf-8", errors="replace"))
        except Exception:
            pass
    return "\n".join(lines[:200]) if lines else None


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Smoke test CLI**

```bash
cd profiling/mem && python3 analyze_mem.py --help 2>&1 | head -20
cd profiling/mem && python3 analyze_mem.py --csv tests/fixtures/mem_trend_normal.csv --no-plot -h 2>&1 | head -5
```

- [ ] **Step 3: Commit**

```bash
git add profiling/mem/analyze_mem.py
git commit -m "misc: add CLI main() wiring all analyzer knobs"
```

---


### Task 9: Fake gem5 + assert.sh test tools

**Files:**
- Create: `profiling/mem/tests/tools/fake_gem5.c`
- Create: `profiling/mem/tests/tools/assert.sh`
- Create: `profiling/mem/tests/tools/build_fake_gem5.sh`

**Interfaces:**
- Produces: `fake_gem5` binary — deterministic process with controlled RSS growth
- Produces: `assert.sh` — lightweight assertion helpers for bash integration tests

- [ ] **Step 1: Write fake_gem5.c**

```c
/* profiling/mem/tests/tools/fake_gem5.c
 * Deterministic fake gem5 process for sampler integration tests.
 *
 * Usage: fake_gem5 <alloc_mb_per_sec> <duration_s> [--stats-out <path>]
 *
 * Allocates <alloc_mb_per_sec> MB per second (touches pages so RSS grows),
 * prints "Beginning simulation!" after 1 s, and optionally writes a
 * gem5-shaped stats.txt on exit.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <time.h>

static volatile sig_atomic_t keep_running = 1;

static void handle_signal(int sig) {
    keep_running = 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <alloc_mb_per_sec> <duration_s> [--stats-out <path>]\n",
                argv[0]);
        return 1;
    }

    double alloc_mb_per_sec = atof(argv[1]);
    double duration_s = atof(argv[2]);
    const char *stats_out = NULL;

    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--stats-out") == 0 && i + 1 < argc) {
            stats_out = argv[++i];
        }
    }

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    double elapsed = 0.0;
    double total_allocated_mb = 0.0;
    int ticks_per_sec = 10;
    double tick_s = 1.0 / ticks_per_sec;
    double alloc_per_tick_mb = alloc_mb_per_sec / ticks_per_sec;
    long page_size = sysconf(_SC_PAGESIZE);

    usleep(999000);

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    printf("Beginning simulation!\n");
    fflush(stdout);

    while (keep_running && elapsed < duration_s) {
        size_t bytes = (size_t)(alloc_per_tick_mb * 1024.0 * 1024.0);
        if (bytes > 0) {
            char *buf = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (buf != MAP_FAILED) {
                for (size_t off = 0; off < bytes; off += page_size) {
                    buf[off] = (char)(off & 0xff);
                }
                total_allocated_mb += (double)bytes / (1024.0 * 1024.0);
            }
        }

        usleep((useconds_t)(tick_s * 1e6));

        clock_gettime(CLOCK_MONOTONIC, &now);
        elapsed = (now.tv_sec - start.tv_sec) +
                  (now.tv_nsec - start.tv_nsec) / 1e9;
    }

    if (stats_out) {
        FILE *f = fopen(stats_out, "w");
        if (f) {
            fprintf(f, "---------- Begin Simulation Statistics ----------\n");
            fprintf(f, "sim_insts                     %d\n",
                    (int)(elapsed * 50000000));
            fprintf(f, "sim_seconds                   %.6f\n", elapsed / 1000.0);
            fprintf(f, "host_seconds                  %.6f\n", elapsed);
            fprintf(f, "---------- End Simulation Statistics ----------\n");
            fclose(f);
        }
    }

    printf("Simulation complete. Allocated %.1f MB over %.1f s\n",
           total_allocated_mb, elapsed);
    return 0;
}
```

- [ ] **Step 2: Write assert.sh**

```bash
# profiling/mem/tests/tools/assert.sh
# Lightweight assertion helpers for bash integration tests.

assert_file_exists() {
    local file="$1" msg="${2:-expected file to exist: $1}"
    if [ ! -f "$file" ]; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: file exists: $file"
}

assert_file_not_empty() {
    local file="$1" msg="${2:-expected non-empty file: $1}"
    assert_file_exists "$file" "$msg"
    if [ ! -s "$file" ]; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: file not empty: $file"
}

assert_exit_code() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$actual" -ne "$expected" ]; then
        echo "FAIL: expected exit $expected, got $actual${msg:+: $msg}" >&2
        exit 1
    fi
    echo "  ok: exit code $expected"
}

assert_contains() {
    local pattern="$1" file="$2" msg="${3:-expected '$pattern' in $file}"
    if ! grep -q "$pattern" "$file"; then
        echo "FAIL: $msg" >&2
        exit 1
    fi
    echo "  ok: contains '$pattern'"
}

assert_ge() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [ "$(echo "$actual >= $expected" | bc -l 2>/dev/null || echo 0)" != "1" ]; then
        echo "FAIL: expected >= $expected, got $actual${msg:+: $msg}" >&2
        exit 1
    fi
    echo "  ok: $actual >= $expected"
}

echo "assert.sh loaded"
```

- [ ] **Step 3: Write build script**

```bash
#!/bin/bash
# profiling/mem/tests/tools/build_fake_gem5.sh
set -euo pipefail
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$TOOLS_DIR/fake_gem5"
if [ -f "$BINARY" ] && [ "$BINARY" -nt "$TOOLS_DIR/fake_gem5.c" ]; then
    echo "fake_gem5 up to date: $BINARY"
    exit 0
fi
echo "Building fake_gem5..."
cc -std=c11 -Wall -Wextra -O2 -o "$BINARY" "$TOOLS_DIR/fake_gem5.c"
echo "Built: $BINARY"
```

- [ ] **Step 4: Build and verify**

```bash
chmod +x profiling/mem/tests/tools/build_fake_gem5.sh
bash profiling/mem/tests/tools/build_fake_gem5.sh
./profiling/mem/tests/tools/fake_gem5 5 2
echo "Exit: $?"
```

- [ ] **Step 5: Commit all test tools**



### Task 10: Sampler — spawn mode (`mem_sample.sh`)

**Files:**
- Create: `profiling/mem/mem_sample.sh`
- Create: `profiling/mem/tests/integration/test_sampler_spawn.sh`

**Interfaces:**
- Consumes: fake_gem5 (Task 9), assert.sh (Task 9)
- Produces: `mem_sample.sh` — sidecar sampler, spawn mode

- [ ] **Step 1: Write mem_sample.sh**

See spec §3.1 for full contract. The script (~180 lines) implements:
- CLI parsing for all knobs in §5.1 (--interval-s, --output-dir, --csv, --tag, --append, --pid, --max-samples, --max-duration-s)
- Spawn mode: fork gem5 in background, capture PID and /proc/PID/starttime
- Sampling loop: read /proc/PID/smaps_rollup every INTERVAL_S, write CSV rows
- /proc/PID/status fallback when smaps_rollup unavailable (PSS/USS/heap = -1)
- PID-reuse guard via /proc/PID/stat starttime comparison
- Signal handling: SIGINT/SIGTERM forwarded to gem5 in spawn mode
- Cap handling: --max-samples or --max-duration-s → final row with gem5_phase=sampler_cap_reached, then monitor-only until gem5 exits
- Exit code forwarding: sampler exits with gem5's exit code in spawn mode

Write the file at `profiling/mem/mem_sample.sh` with `chmod +x`.

Key implementation pattern for the sampling loop:

```bash
sample() {
    local now_mono ts_ms
    now_mono="$(awk '{print $1}' /proc/uptime)"
    ts_ms="$(echo "($now_mono - $START_MONO) * 1000" | bc | cut -d. -f1)"

    # PID-reuse guard
    if [ -n "$STARTTIME" ] && [ -f "/proc/$PID/stat" ]; then
        local cur_st="$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null || echo "")"
        if [ "$cur_st" != "$STARTTIME" ]; then
            GEM5_PHASE="exited"
            echo "${ts_ms},0,-1,-1,-1,0,0,0,$GEM5_PHASE" >> "$CSV_PATH"
            return 1
        fi
    fi

    # Read smaps_rollup
    if [ -f "/proc/$PID/smaps_rollup" ] && [ -r "/proc/$PID/smaps_rollup" ]; then
        _read_smaps_rollup
    elif [ "$ALLOW_FALLBACK" = "1" ] && [ -f "/proc/$PID/status" ]; then
        _read_status_fallback
    else
        return 1
    fi

    echo "${ts_ms},${RSS_KB:-0},${PSS_KB:--1},${USS_KB:--1},${HEAP_KB:--1},${ANON_KB:-0},${FILE_KB:-0},${SWAP_KB:-0},$GEM5_PHASE" >> "$CSV_PATH"
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    return 0
}
```

- [ ] **Step 2: Write integration test (spawn)**

File: `profiling/mem/tests/integration/test_sampler_spawn.sh`

Test steps:
1. Build fake_gem5 via build_fake_gem5.sh
2. Run: mem_sample.sh --output-dir $TMPDIR --interval-s 0.5 -- fake_gem5 10 5
3. Assert: CSV exists with >=3 data rows, header contains "gem5_cmd" and tag
4. Assert: mem_sample.log exists
5. Cleanup tmpdir

- [ ] **Step 3: Run integration test**

```bash
bash profiling/mem/tests/integration/test_sampler_spawn.sh
```

- [ ] **Step 4: Commit**

```bash
git add profiling/mem/mem_sample.sh profiling/mem/tests/integration/
git commit -m "misc: add mem_sample.sh spawn mode with /proc sampling and integration test"
```

---

### Task 11: Sampler — attach mode

**Files:**
- Modify: `profiling/mem/mem_sample.sh` (already has --pid logic from Task 10)
- Create: `profiling/mem/tests/integration/test_sampler_attach.sh`

- [ ] **Step 1: Write integration test (attach)**

File: `profiling/mem/tests/integration/test_sampler_attach.sh`

Test steps:
1. Launch fake_gem5 5 10 in background, capture PID
2. sleep 1 (let it print "Beginning simulation!")
3. Run: mem_sample.sh --pid $PID --interval-s 0.3 --max-duration-s 3
4. Assert: sampler exits 0, CSV has "attached: true" in header
5. Assert: fake_gem5 still running (attach mode leaves target alive)
6. Kill fake_gem5, cleanup

- [ ] **Step 2: Run → PASS**

```bash
bash profiling/mem/tests/integration/test_sampler_attach.sh
```

- [ ] **Step 3: Commit**

```bash
git add profiling/mem/tests/integration/test_sampler_attach.sh
git commit -m "misc: add sampler attach mode integration test"
```

---

### Task 12: Sampler — append mode

**Files:**
- Create: `profiling/mem/tests/integration/test_sampler_append.sh`

- [ ] **Step 1: Write integration test (append)**

File: `profiling/mem/tests/integration/test_sampler_append.sh`

Test steps:
1. Run 1: mem_sample.sh spawn fake_gem5 10 3 → N1 data rows
2. Run 2: mem_sample.sh --append spawn fake_gem5 10 3
3. Assert: total rows >= N1 + 3, CSV contains >=1 "segment_start:" marker
4. Assert: ts_ms column monotonically increasing across all data rows

- [ ] **Step 2: Run → PASS**

- [ ] **Step 3: Commit**

---

### Task 13: Sampler — caps (--max-samples, --max-duration-s)

**Files:**
- Create: `profiling/mem/tests/integration/test_sampler_caps.sh`

- [ ] **Step 1: Write integration test (caps)**

File: `profiling/mem/tests/integration/test_sampler_caps.sh`

Test steps:
1. Spawn with --max-samples 3 → assert final row has gem5_phase=sampler_cap_reached, <=4 data rows
2. Attach mode with --max-duration-s 2 → assert target still alive after sampler exits
3. Spawn mode with --max-duration-s 2 → assert cap marker, sampler forwards gem5 exit code

- [ ] **Step 2: Run → PASS**

- [ ] **Step 3: Commit**

---

### Task 14: Deep runner + analyzer CLI integration test

**Files:**
- Create: `profiling/mem/deep_run.sh`
- Create: `profiling/mem/tests/integration/test_analyzer_cli.sh`

- [ ] **Step 1: Write deep_run.sh**

```bash
#!/bin/bash
# profiling/mem/deep_run.sh — On-demand heap attribution via heaptrack.
set -euo pipefail
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
HEAPTRACK_PREFIX="${HEAPTRACK_PREFIX:-heaptrack.gem5}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --prefix) HEAPTRACK_PREFIX="$2"; shift 2 ;;
        --pid) echo "ERROR: --pid not supported with heaptrack (LD_PRELOAD interposer)" >&2; exit 2 ;;
        --) shift; break ;;
        -h|--help) echo "Usage: deep_run.sh [opts] -- <gem5_cmd> [args...]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 2 ;;
    esac
done

[ $# -eq 0 ] && { echo "ERROR: no command"; exit 2; }

if ! command -v heaptrack &>/dev/null; then
    echo "ERROR: heaptrack not found. Install: apt install heaptrack" >&2
    exit 127
fi

mkdir -p "$OUTPUT_DIR"
exec heaptrack -o "$OUTPUT_DIR/${HEAPTRACK_PREFIX}" "$@"
```

- [ ] **Step 2: Write analyzer CLI integration test**

File: `profiling/mem/tests/integration/test_analyzer_cli.sh`

Test the exit-code contract from spec §4.4:
1. Normal CSV, no thresholds → exit 0, report has "Effective configuration"
2. Missing CSV → exit 2
3. Leak fixture + strict.yaml policy → exit 1 (peak_rss_mb: 100 breached), report says FAIL
4. Normal CSV + lenient.yaml → exit 0

- [ ] **Step 3: Run integration tests**

```bash
bash profiling/mem/deep_run.sh --help  # verify CLI works (heaptrack may be absent)
bash profiling/mem/tests/integration/test_analyzer_cli.sh
```

- [ ] **Step 4: Commit**

---

### Task 15: run.sh integration + E2E smoke + docs pointer

**Files:**
- Modify: `profiling/run.sh` (add MEM_TREND=1 Layer 3 hook)
- Create: `profiling/mem/tests/e2e/test_pipeline_smoke.sh`
- Create: `profiling/mem/README.md`
- Modify: `docs/Gem5 高并发仿真性能衰减排查与评估指南.md` (add §3.6)

- [ ] **Step 1: Add Layer 3 hook to profiling/run.sh**

After the last echo in run.sh (after Layer 2), add:

```bash
# 5. Memory trend (Layer 3) — opt-in via MEM_TREND=1
if [ "${MEM_TREND:-0}" = "1" ]; then
    echo ""
    echo "=== Layer 3: memory trend (sidecar) ==="
    mkdir -p "$OUTPUT_DIR"
    "$SCRIPT_DIR/mem/mem_sample.sh" \
        --output-dir "$OUTPUT_DIR" \
        --tag "${MEM_RUN_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo untagged)}" \
        -- "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
        --binary "$WORKLOAD_BIN" --output-dir "$OUTPUT_DIR"
    python3 "$SCRIPT_DIR/mem/analyze_mem.py" \
        --csv "$OUTPUT_DIR/mem_trend.csv" \
        --stats "$OUTPUT_DIR/stats.txt" \
        --policy "$SCRIPT_DIR/mem/mem_thresholds.yaml" || true
fi
```

- [ ] **Step 2: Write E2E smoke test**

File: `profiling/mem/tests/e2e/test_pipeline_smoke.sh`

Gated on `E2E=1`. Runs `MEM_TREND=1 profiling/run.sh` with real gem5.opt.
Asserts: CSV >=5 rows, report has "Effective configuration", metrics JSON has peak_rss_kb.

- [ ] **Step 3: Write README.md**

Quickstart covering: pipeline usage, standalone sampler, attach mode, analyzer CLI, deep mode, append mode, testing commands. See spec §8 for rollout details.

- [ ] **Step 4: Add docs pointer**

In `docs/Gem5 高并发仿真性能衰减排查与评估指南.md`, append §3.6:

```markdown
### 3.6 宿主机内存趋势评估 (Host Memory Trend Evaluation)

参见 [`profiling/mem/README.md`](../../profiling/mem/README.md)。

快速启用：`MEM_TREND=1 ./profiling/run.sh`
```

- [ ] **Step 5: Run full test suite**

```bash
# Unit tests
cd profiling/mem/tests/unit && python -m pytest -v

# Integration tests
for t in profiling/mem/tests/integration/test_*.sh; do bash "$t"; done
```

- [ ] **Step 6: Final commit**

All files committed. Plan complete.

---


## Plan Self-Review

### 1. Spec coverage

| Spec section | Task(s) |
|---|---|
| §3.1 mem_sample.sh | Tasks 10-13 |
| §3.2 analyze_mem.py | Tasks 2-8 |
| §3.3 deep_run.sh | Task 14 |
| §3.4 mem_thresholds.yaml | Task 1 |
| §3.5 run.sh integration | Task 15 |
| §4.1-4.4 Data flow, CSV, stats, errors | Tasks 3-6 |
| §5.1-5.4 CLI/env/YAML/default precedence | Tasks 2, 8 |
| §6.1-6.7 Testing strategy | Tasks 9-15 |
| §8 Rollout | Tasks 1, 15 |
| §10 Acceptance criteria (7 items) | All tasks |

No gaps found. All 7 acceptance criteria from spec §10 are covered.

### 2. Placeholder scan

No TBD, TODO, "implement later", or "add appropriate error handling" patterns found.
Every task has concrete file paths, code blocks, and test expectations.

### 3. Type consistency

- `resolve_config()` returns `dict[str, tuple[Any, str]]` — consumed correctly by `compute_metrics()` and `evaluate_gate()` via `_cfg_val()` helper
- `load_csv()` returns `(header_dict, samples_list)` — consumed by `compute_metrics()` and `main()`
- `load_stats()` returns `Optional[dict]` — consumed by `compute_metrics()`
- `compute_metrics()` returns `dict` with keys `peak_rss_kb`, `growth_rate_kb_per_s_post_warmup`, etc. — consumed by `evaluate_gate()`, `render_plot()`, `write_report()`
- `evaluate_gate()` returns `(verdict, exit_code, failures)` — consumed by `main()`
- CSV columns consistent across fixtures, parser, and metrics computation
- Env var names consistent between `_ENV_MAP` in config resolution and `--help` output

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-09-gem5-memory-trend.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — Fresh subagent per task, review between tasks, fast iteration. Use `superpowers:subagent-driven-development`.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

**Which approach?**
