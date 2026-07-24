# Memory Monitor Daemon — 部署与使用手册

## 1. 交付物

```
mem-monitor/
├── start.sh            # 一键管理脚本（start / stop / status / analyze）
├── mem_daemon.sh       # Bash daemon（零依赖）
├── mem_daemon.py       # Python daemon（需要 psutil）
├── analyze_kswapd.py   # kswapd 分析工具
├── env.sh              # 配置文件（编辑此文件调整参数）
└── README.md           # 本文档
```

## 2. 依赖检查

```bash
# Bash daemon 依赖（默认已安装）
which bc          # 应该有，没有则 apt install bc
which nohup       # 必有

# Python daemon 依赖（仅 --engine python 时需要）
pip install psutil
```

## 3. 配置

编辑 `env.sh`：

```bash
export INTERVAL_S=5          # 采样间隔（秒），默认 5
export MEM_MODE=standard     # light | standard | detailed
export OUTPUT_DIR=./output   # 输出目录
```

## 4. 启动 / 管理

```bash
# 启动（默认 bash 引擎，零依赖）
./start.sh start

# 启动（Python 引擎，更快，需 psutil）
./start.sh start python

# 查看运行状态
./start.sh status

# 重启
./start.sh restart

# 优雅停止（发 SIGTERM，完成当前采样后退出）
./start.sh stop
```

## 5. 输出结构

```
output/
└── 2026-07-24_16/        # 每小时一个子目录
    ├── sys_mem.csv         # 系统总内存 + vmstat + PSI
    ├── proc_mem.csv        # 所有进程 RSS/PSS/USS/cmdline
    └── kswapd.csv          # kswapd 线程 state/wchan/stack
```

## 6. 分析：kswapd 活跃时谁是内存大户

```bash
# 默认：kswapd 活跃时 Top 20 进程
./start.sh analyze

# 自定义：Top 30，±15s 匹配窗口
./start.sh analyze 30 15

# 等价于直接调用
python3 analyze_kswapd.py --output-dir ./output --top 20 --window-s 10
```

检测逻辑（任一触发）：
1. **pgscan_kswapd 增长** → kswapd 实际做了页面回收（最可靠）
2. **state=R 或 D** → kswapd 正在运行或阻塞在 I/O

输出示例：
```
Event #1: 2026-07-24T16:30:05+08:00 (ts_ms=12345678)
  Reason: pgscan_kswapd +15234 (100000 -> 115234)
  Memory context:  MemFree=256MB, SwapFree=3.8GB, Dirty=12MB
                   pgscan_kswapd=115234, PSI mem some=2.34

  Top 20 processes by RSS (±10s window):
  Rank  PID   RSS         USS         Name        Cmdline
  1     12345 15.3 GB     14.8 GB     gem5.opt    /path/gem5.opt --outdir=...
  2     12346 14.1 GB     13.9 GB     gem5.opt    /path/gem5.opt --outdir=...
  ...
```

## 7. CSV 字段速查

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

kswapd 未运行时写哨兵行 `ts_ms,-,-,-,-,-,-,-`。

## 8. 采集模式

| mode | RSS/VSZ | PSS/USS | VmSwap | cmdline | 开销 |
|------|:---:|:---:|:---:|:---:|:---:|
| `light` | ✓ | -1 | -1 | 空 | 最低 |
| `standard` | ✓ | ✓ | ✓ | ✓ | 中等 |
| `detailed` | ✓ | ✓ | ✓ | ✓ | 最高 |

## 9. 信号控制

| 信号 | 行为 |
|------|------|
| SIGTERM / SIGINT | 完成当前采样后优雅退出 |
| SIGUSR1 | 立即触发一次额外采样（手动快照） |

```bash
# 手动触发一次快照
kill -USR1 $(cat output/mem_daemon.pid)

# 优雅停止
kill -TERM $(cat output/mem_daemon.pid)
```

## 10. 典型使用场景

### 场景 A：长期后台监控

```bash
# 编辑 env.sh，设 INTERVAL_S=10 MEM_MODE=standard
./start.sh start
# 一直后台跑，启动时用 nohup，重启后需手动再启（可配 systemd）
```

### 场景 B：200 个 gem5 并发性能退化排查

```bash
# 1. 问题出现时启动采集（或提前一直跑着）
./start.sh start

# 2. 等问题复现后，用分析工具定位
./start.sh analyze 20   # kswapd 活跃时 Top 20 内存进程

# 3. 交叉验证：pgscan_kswapd 增长 + top 进程 RSS
#    如果 top 进程是 gem5 → cache contention + memory pressure
#    如果 top 进程是其他 job → 调度或 cgroup 问题
```

### 场景 C：单次故障快照

```bash
# 启动后立即发 SIGUSR1 快照，采集几轮后停
./start.sh start
sleep 3
kill -USR1 $(cat output/mem_daemon.pid)
sleep 20
./start.sh stop
./start.sh analyze
```

## 11. 磁盘空间

| 场景 | 进程数 | 间隔 | 每小时 CSV 大小 |
|------|:---:|:---:|:---:|
| 开发机 | ~400 | 5s | ~50 MB |
| LSF 节点 | ~200 (gem5) | 5s | ~30 MB |
| 空载节点 | ~200 | 30s | ~3 MB |

建议：生产环境设 `INTERVAL_S=10~30`，定期清理旧目录。
