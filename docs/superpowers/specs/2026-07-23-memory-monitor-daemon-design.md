# Memory Monitor Daemon — Design Spec

**Date**: 2026-07-23
**Status**: Approved
**Author**: luq

## 1. 概述

构建两个独立的后台常驻 daemon，持续周期性采集系统中所有进程的内存使用信息、系统总体内存状况及 kswapd 回收活动，输出结构化 CSV 供事后回溯分析。

两个实现共享同一套输出规范、CLI 接口和测试契约：
- **方案 A**：纯 Bash（`mem_daemon.sh`），零外部依赖
- **方案 B**：Python（`mem_daemon.py`），需要 `psutil`，更健壮

## 2. 目录结构

```
profiling/monitor/
├── mem_daemon.sh       # 方案 A：Bash daemon
├── mem_daemon.py       # 方案 B：Python daemon
├── env.sh              # 共享环境变量
├── README.md           # 使用文档
└── output/             # 默认输出根目录
    └── 2026-07-23_16/  # 每小时分片
        ├── proc_mem.csv
        ├── sys_mem.csv
        └── kswapd.csv
```

## 3. 运行模式

- **采集范围**：所有进程，包括内核线程和系统进程
- **运行方式**：后台常驻 daemon，一直运行周期采集
- **默认间隔**：5 秒（可配置）
- **采集粒度**：默认 `standard`，可切换 `light` / `detailed`
- **分片策略**：按类别分文件（`proc_mem.csv` / `sys_mem.csv` / `kswapd.csv`）+ 按小时分片目录

## 4. CSV 输出格式

### 4.1 proc_mem.csv（进程级内存）

| 列 | 类型 | 说明 | 模式 |
|---|---|---|---|
| `ts_ms` | int | CLOCK_MONOTONIC 毫秒时间戳 | 全部 |
| `wall_clock` | str | ISO-8601 墙上时间 | 全部 |
| `pid` | int | 进程 PID | 全部 |
| `comm` | str | 进程名 (`/proc/pid/comm`) | 全部 |
| `state` | str | 进程状态 R/S/D/Z/T/... | 全部 |
| `threads` | int | 线程数 | 全部 |
| `rss_kb` | int | RSS (kB) | 全部 |
| `vsz_kb` | int | VSZ (kB) | 全部 |
| `pss_kb` | int | PSS (kB)，不可用时 -1 | std/detail |
| `uss_kb` | int | USS (kB)，不可用时 -1 | std/detail |
| `swap_kb` | int | VmSwap (kB) | std/detail |
| `cpu_percent` | float | %CPU（差值法） | 全部 |
| `cmdline` | str | 完整命令行，截断至 256 字符 | std/detail |
| `mode` | str | `light` / `standard` / `detailed` | 全部 |

### 4.2 sys_mem.csv（系统总体内存）

| 列 | 说明 |
|---|---|
| `ts_ms` | CLOCK_MONOTONIC 毫秒时间戳 |
| `wall_clock` | ISO-8601 墙上时间 |
| `memtotal_kb` | MemTotal |
| `memfree_kb` | MemFree |
| `memavailable_kb` | MemAvailable |
| `cached_kb` | Cached |
| `buffers_kb` | Buffers |
| `anonpages_kb` | AnonPages |
| `dirty_kb` | Dirty |
| `swaptotal_kb` | SwapTotal |
| `swapfree_kb` | SwapFree |
| `pgscan_kswapd` | /proc/vmstat 当前值 |
| `pgsteal_kswapd` | /proc/vmstat 当前值 |
| `pgscan_direct` | /proc/vmstat 当前值 |
| `pgsteal_direct` | /proc/vmstat 当前值 |
| `compact_stall` | /proc/vmstat 当前值 |
| `allocstall_normal` | /proc/vmstat 当前值 |
| `psi_mem_some_avg10` | PSI memory some avg10 |
| `psi_mem_full_avg10` | PSI memory full avg10 |
| `psi_io_some_avg10` | PSI io some avg10 |

### 4.3 kswapd.csv（kswapd 活动）

| 列 | 说明 |
|---|---|
| `ts_ms` | CLOCK_MONOTONIC 毫秒时间戳 |
| `wall_clock` | ISO-8601 墙上时间 |
| `pid` | kswapd 线程 PID |
| `comm` | 进程名（如 kswapd0） |
| `state` | D / R / S |
| `cpu_percent` | %CPU |
| `rss_kb` | kswapd 自身 RSS |
| `wchan` | /proc/pid/wchan |
| `stack` | /proc/pid/stack，多行以 `\|` 合并 |

kswapd 检测方式：`pgrep '^kswapd[0-9]*$'`。kswapd 未运行时写哨兵行 `ts_ms,-,-,-,-,-,-,-`。

## 5. 配置项

| 参数 | 默认值 | 环境变量 | 说明 |
|---|---|---|---|
| `--interval` | `5` | `INTERVAL_S` | 采样间隔（秒） |
| `--output-dir` | `./output` | `OUTPUT_DIR` | 输出根目录 |
| `--mode` | `standard` | `MEM_MODE` | `light` / `standard` / `detailed` |
| `--duration` | `0` | `MEM_DURATION_S` | 总运行时长，0=永久 |
| `--max-samples` | `0` | `MEM_MAX_SAMPLES` | 最大采样次数，0=不限 |
| `--slice-minutes` | `60` | `MEM_SLICE_M` | 目录分片间隔（分钟） |

CLI 参数优先于环境变量。

## 6. CLI 接口

```bash
# Bash
./mem_daemon.sh --interval 5 --mode standard --output-dir ./output

# Python
./mem_daemon.py --interval 5 --mode standard --output-dir ./output
./mem_daemon.py --daemonize --interval 5 --output-dir /var/log/mem_monitor
```

共同参数：
```
--interval SECONDS       采样间隔（默认 5）
--mode light|standard|detailed  采集粒度（默认 standard，env: MEM_MODE）
--output-dir PATH        输出根目录（默认 ./output）
--duration SECONDS       总时长（0=永久）
--max-samples N          最大采样数（0=不限）
--slice-minutes N        分片间隔分钟（默认 60）
--help                   帮助
```

Python 额外参数：
```
--daemonize              后台守护进程化
--log-level INFO|DEBUG   日志级别
```

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| 进程在读取中间退出 | 静默跳过，记 `[WARN]` 日志 |
| 权限不足（其他用户 smaps_rollup） | light/std 用 `/proc/pid/status` 降级；detail 填 `-2` |
| kswapd 未运行 | kswapd.csv 写哨兵行 |
| /proc/pid/stack 无权限 | 填 `"requires_root"`，不退出 |
| 磁盘满 | 日志告警；连续 3 次写入失败→退出码 2 |
| 时钟回退（NTP） | `ts_ms`（MONOTONIC）做主键，`wall_clock` 仅辅助 |
| 分片切换瞬间 | 上一片写完最后一行再切，不丢采样点 |

## 8. 信号处理

| 信号 | 行为 |
|---|---|
| SIGTERM / SIGINT | 写完当前行后优雅退出（完成最后的采样 → 关闭文件） |
| SIGUSR1 | 立即触发一次额外采样（事件驱动快照） |

## 9. PID 重用防护

读取 `/proc/<pid>/stat` 第 22 字段（`starttime`）。首次采样时记录，后续每次对比。不匹配视为死进程，写 `exited` 行后跳过。

## 10. 方案 A 特化（Bash）

- 零外部依赖（需要 `bc`，默认安装）
- `/proc` 文件系统直读
- 信号处理：`trap` SIGTERM / SIGINT / SIGUSR1
- 日志：`$OUTPUT_DIR/mem_monitor.log`
- 不 daemonize（用户自行用 `nohup` / `&` 后台化）

## 11. 方案 B 特化（Python）

- 依赖 `psutil`（`pip install psutil`）
- `psutil.process_iter()` 加速进程遍历（比逐 `/proc` 遍历快 3-5x）
- `logging` 模块，同时输出 stderr + 文件
- `--daemonize`：`os.fork` 双 fork 守护进程化
- 可扩展：后续容易加 HTTP health endpoint、Prometheus exporter

## 12. 测试策略

| 级别 | 内容 |
|---|---|
| 单元测试（Python） | CSV header 生成、分片路径计算、`/proc/status` 解析 |
| 集成测试 | 起 `sleep 60` 假进程，采集 3 轮，验证 CSV 行数和 schema |
| 压力测试 | 500 个 `fake_gem5`，验证不 OOM、不崩溃、CPU < 5% |
| 对比测试 | 两个 daemon 同时跑，diff `proc_mem.csv` RSS 值 ±5% 以内 |
| 信号测试 | SIGTERM → 最后一行完整、文件未损坏；SIGUSR1 → 额外采样行 |

## 13. 与现有工具的关系

- **`profiling/mem/mem_sample.sh`**：sidecar 单进程采样 → 本 daemon 是全系统多进程持续采集，互补
- **`docs/scripts/01_collect_pid.sh`**：交互式单次诊断 → 本 daemon 是自动化长期采集
- **`docs/scripts/04_memory_pressure.sh`**：手动增量对比 → 本 daemon 的 `sys_mem.csv` 已包含 vmstat 计数器时序列

## 14. 后续扩展方向

- 对接 `profiling/mem/analyze_mem.py`：读取 sys_mem.csv 做趋势分析和 gate 判定
- 加告警阈值：peak_rss / swap 增长 / PGSCAN 突增 → 触发 SIGUSR1 快照或通知
- Prometheus exporter 模式：HTTP endpoint 暴露 metrics
- HTML dashboard：基于 CSV 数据生成自包含暗色 HTML 报告（复用已有 dashboard 技能）
