# Memory Monitor Daemon

后台常驻 daemon，持续周期性采集系统内存全景数据，输出结构化 CSV 供事后回溯分析。

提供 **Bash** 和 **Python** 两个独立实现，共享同一套输出规范和 CLI 接口。

## 快速开始

```bash
# Bash daemon（零外部依赖，需要 bc）
./profiling/monitor/mem_daemon.sh --interval 5 --mode standard

# Python daemon（需要 psutil: pip install psutil）
./profiling/monitor/mem_daemon.py --interval 5 --mode standard
```

## 输出

按小时分片目录，每个目录含三类 CSV：

```
output/
└── 2026-07-23_16/
    ├── sys_mem.csv      # 系统总体内存 + vmstat + PSI
    ├── proc_mem.csv     # 所有进程内存（PID/RSS/PSS/USS/VmSwap/cmdline）
    └── kswapd.csv       # kswapd 线程状态/wchan/stack
```

## CLI 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--interval SECONDS` | `5` | 采样间隔 |
| `--output-dir PATH` | `./output` | 输出根目录 |
| `--mode light\|standard\|detailed` | `standard` | 采集粒度 |
| `--duration SECONDS` | `0`（永久） | 总运行时长 |
| `--max-samples N` | `0`（不限） | 最大采样次数 |
| `--slice-minutes N` | `60` | 目录分片间隔 |
| `--sys-only` | — | 仅采集系统指标 |
| `--proc-only` | — | 仅采集进程指标 |

Python 额外参数：

| 参数 | 说明 |
|------|------|
| `--daemonize` | 双 fork 守护进程化 |
| `--log-level DEBUG\|INFO\|WARNING` | 日志级别 |

## 采集模式

| 模式 | 说明 |
|------|------|
| `light` | RSS/VSZ/线程数/状态（快速，低开销） |
| `standard` | + PSS/USS/VmSwap/cmdline（推荐） |
| `detailed` | + smaps_rollup 完整分解 |

## 信号处理

| 信号 | 行为 |
|------|------|
| SIGTERM / SIGINT | 完成当前采样后优雅退出 |
| SIGUSR1 | 立即触发一次额外采样 |

## CSV 格式

### sys_mem.csv

```
ts_ms, wall_clock, memtotal_kb, memfree_kb, memavailable_kb, cached_kb,
buffers_kb, anonpages_kb, dirty_kb, swaptotal_kb, swapfree_kb,
pgscan_kswapd, pgsteal_kswapd, pgscan_direct, pgsteal_direct,
compact_stall, allocstall_normal,
psi_mem_some_avg10, psi_mem_full_avg10, psi_io_some_avg10
```

### proc_mem.csv

```
ts_ms, wall_clock, pid, comm, state, threads, rss_kb, vsz_kb,
pss_kb, uss_kb, swap_kb, cpu_percent, cmdline, mode
```

### kswapd.csv

```
ts_ms, wall_clock, pid, comm, state, cpu_percent, rss_kb, wchan, stack
```

kswapd 未运行时写入哨兵行 `ts_ms,-,-,-,-,-,-,-`。

## 运行测试

```bash
# 单元 / 集成测试
for t in profiling/monitor/tests/test_*.sh; do bash "$t"; done

# 需要先安装 psutil
pip install psutil
```

## 与现有工具的关系

| 工具 | 定位 |
|------|------|
| `profiling/mem/mem_sample.sh` | 单进程 sidecar 采样 |
| `docs/scripts/01_collect_pid.sh` | 交互式单次诊断 |
| `docs/scripts/04_memory_pressure.sh` | swap/reclaim 手动增量对比 |
| **本 daemon** | 全系统持续自动化采集 |

## 设计文档

- Spec: `docs/superpowers/specs/2026-07-23-memory-monitor-daemon-design.md`
- Plan: `docs/plans/2026-07-23-memory-monitor-daemon-plan.md`
