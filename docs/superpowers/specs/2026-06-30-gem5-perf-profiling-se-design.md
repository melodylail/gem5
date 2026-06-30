# gem5 X86 SE Mode perf Profiling Design

> Date: 2026-06-30
> Status: Approved
> Target: gem5 v25.1.0.1

## 1. Overview

使用 perf 对 gem5 X86 仿真器的 SE (syscall emulation) 模式运行过程进行 profiling，定位 CPU 级热点和 cache miss，找出可优化的执行路径。

**范围**: Phase 1 — perf 采样分析（valgrind/callgrind 留作 Phase 2）。

**核心决策**:

| 决策 | 选择 | 理由 |
|------|------|------|
| CPU 模型 | `CPUTypes.TIMING` | 比 Atomic 真实，比 O3 profiling 开销小 |
| 构建变体 | `gem5.opt` | 优化 + 符号表，热点分布接近生产 |
| 指令数 | ~200M-500M | 够 perf 采几千样本，wall time ~10-30s |
| perf events | cycles, instructions, cache-misses, branch-misses | 覆盖 IPC、缓存、分支预测三维度 |
| callgraph | `--call-graph dwarf` | 解决 gem5 虚函数调用链丢失问题 |

## 2. Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ test_prog   │────▶│  gem5 X86 SE     │────▶│  perf record     │
│ (C,静态链接) │     │  (build/ALL/opt) │     │  cycles,inst,     │
│ ~10秒计算    │     │  SimpleCPU/Timing│     │  cache-miss,br-miss│
└─────────────┘     └──────────────────┘     └────────┬─────────┘
                                                       │
                                          ┌────────────▼─────────┐
                                          │  perf report / annotate│
                                          │  + FlameGraph (svg)    │
                                          │  + cache-miss 统计     │
                                          └──────────┬────────────┘
                                                     │
                                          ┌──────────▼─────────┐
                                          │  分析报告 (.md)      │
                                          │  热点函数 TOP-N      │
                                          │  优化建议            │
                                          └─────────────────────┘
```

## 3. Test Workload

一个 C 程序 `workload.c`，静态链接，模拟 SPEC CPU 负载特征。四个计算阶段覆盖不同 CPU 子系统：

| Phase | 内容 | 目标子系统 |
|-------|------|-----------|
| 1 | 矩阵乘法 (double, N=256) | FPU + cache 压力 |
| 2 | SHA-256 风格哈希计算 | 整数 ALU + bit ops |
| 3 | 分支密集排序 (quicksort, N=10000) | Branch predictor |
| 4 | memcpy 流式读写 | 内存带宽 / prefetcher |

**目标指标**:

| 属性 | 目标值 |
|------|--------|
| 总指令数 | ~200M-500M |
| wall clock (gem5 SE) | ~10-30 秒 |
| 浮点比例 | ~30% |
| 分支密度 | ~15% |

编译: `gcc -O2 -static -o workload workload.c -lm`

## 4. File Structure

```
profiling/                        ← 独立目录，可整体迁移
├── env.sh                        ← 唯一需要编辑的文件（GEM5_HOME）
├── build.sh                      ← scons build 封装
├── workload/
│   ├── workload.c                ← 测试负载源码
│   └── Makefile                  ← gcc -O2 -static
├── configs/
│   └── se_profile.py             ← SE 模式 gem5 stdlib 脚本
├── run.sh                        ← perf + gem5 全流程
├── analyze.sh                    ← perf 后分析脚本
└── output/                        ← 所有输出 (git ignored)
    ├── perf.data
    ├── perf.stat.txt
    ├── perf_report_hotspots.txt
    ├── perf_report_cache.txt
    ├── perf_report_branch.txt
    ├── flamegraph.svg
    ├── stats.txt
    └── report.md
```

## 5. Build & Environment

### env.sh

```bash
# 唯一需要编辑的环境入口。或 export GEM5_HOME 覆盖。
export GEM5_HOME="${GEM5_HOME:-/path/to/gem5}"
export GEM5_BUILD="${GEM5_BUILD:-$GEM5_HOME/build/ALL/gem5.opt}"
```

### build.sh

```bash
#!/bin/bash
source "$(dirname "$0")/env.sh"
cd "$GEM5_HOME" || exit 1
scons build/ALL/gem5.opt -j "${1:-$(nproc)}"
```

### Dependencies

```bash
# 构建依赖
sudo apt install -y build-essential scons python3-dev zlib1g-dev m4 \
    libprotobuf-dev protobuf-compiler libgoogle-perftools-dev

# profiling 工具
sudo apt install -y linux-tools-common linux-tools-generic  # perf
sudo apt install -y valgrind                                 # Phase 2 备用

# FlameGraph
git clone https://github.com/brendangregg/FlameGraph.git ~/FlameGraph
```

## 6. SE Mode Script

`configs/se_profile.py` 使用 gem5 stdlib，最小化配置：

- **CPU**: `SimpleProcessor(cpu_type=CPUTypes.TIMING, isa=ISA.X86, num_cores=1)`
- **Cache**: `PrivateL1SharedL2CacheHierarchy(l1d=32KB, l1i=32KB, l2=256KB)`
- **Memory**: `SingleChannelDDR3_1600("1GiB")`
- **Board**: `SimpleBoard(clk_freq="3GHz", ...)`
- **Binary**: 通过 `argparse --binary` 参数传入，不硬编码路径
- **Output**: 通过 `argparse --output-dir` 参数传入

## 7. Profiling Pipeline (三层)

### Layer 1: `perf stat` — 宏观指标

```bash
perf stat -e cycles,instructions,cache-references,cache-misses,\
branch-instructions,branch-misses,L1-dcache-load-misses,\
L1-icache-load-misses \
    "$GEM5_BUILD" configs/se_profile.py --binary workload --output-dir output
```

解读基准:

| 指标 | 健康范围 | 不健康暗示 |
|------|---------|-----------|
| IPC | > 1.0 | < 0.5 → 数据依赖停顿或 I-cache miss |
| L1 dcache miss | < 5% | > 15% → 内存布局或 prefetch |
| Branch miss | < 3% | > 10% → 解释器式 dispatch 分支难预测 |

### Layer 2: `perf record` + `perf report` — 热点定位

```bash
perf record --call-graph dwarf -F 99 \
    -e cycles,instructions,cache-misses,branch-misses \
    "$GEM5_BUILD" configs/se_profile.py --binary workload --output-dir output

# 按库/函数分层
perf report --hierarchy --sort=dso,symbol

# 纯文本 TOP-N
perf report --stdio --sort=overhead --percent-limit=1 > output/perf_report_hotspots.txt

# cache-miss 按函数
perf report --stdio --sort=symbol -e cache-misses > output/perf_report_cache.txt

# branch-miss 按函数
perf report --stdio --sort=symbol -e branch-misses > output/perf_report_branch.txt
```

### Layer 3: `perf annotate` + FlameGraph — 逐指令

```bash
# 对 TOP-3 热点做指令级注释
perf annotate -s <top_hot_function>

# FlameGraph
perf script | ~/FlameGraph/stackcollapse-perf.pl | \
    ~/FlameGraph/flamegraph.pl > output/flamegraph.svg
```

## 8. Analysis Checklist

跑完 profiling 后按此清单出报告：

1. [ ] IPC 是否健康？不健康 → 找 stall 源
2. [ ] TOP-10 热点函数按 gem5 子系统分类
3. [ ] 每个热点的 perf annotate 揭示最慢指令
4. [ ] cache-miss 集中在哪些函数 → 数据结构布局问题？
5. [ ] branch-miss 集中在哪些函数 → switch-case / 虚函数 dispatch？

## 9. Output & Deliverables

| 文件 | 内容 |
|------|------|
| `output/perf.stat.txt` | perf stat 原始输出 |
| `output/perf.data` | perf record 采样数据 |
| `output/perf_report_hotspots.txt` | TOP-20 热点函数 |
| `output/perf_report_cache.txt` | cache-misses 按函数 |
| `output/perf_report_branch.txt` | branch-misses 按函数 |
| `output/flamegraph.svg` | FlameGraph |
| `output/stats.txt` | gem5 自身统计 |
| `output/report.md` | 综合分析报告 |

### report.md 结构

1. **Summary**: IPC, cache-miss%, branch-miss%, cycles, wall time
2. **Top Hotspots**: 按 overhead% 排序，标注 gem5 子系统
3. **Cache Miss Analysis**: Dcache/Icache miss 按函数 + 可能原因
4. **Branch Miss Analysis**: 分支预测失败热点 + 模式
5. **Optimization Suggestions**: 每项含数据支撑、预期收益、改动思路、风险评估
6. **FlameGraph**: 嵌入链接/截图
7. **Appendix**: 完整原始数据

核心原则: 每条优化建议必须**有数据支撑**，不做无依据猜测。

## 10. Migration

迁移到其他机器只需:

```bash
cd profiling/
# 编辑 env.sh: 修改 GEM5_HOME
# 或直接:
export GEM5_HOME=/new/path/to/gem5
./build.sh
./run.sh
./analyze.sh
```

## 11. Non-Goals (Phase 2)

以下不在 Phase 1 范围内，留作后续：

- valgrind/callgrind 指令级调用图分析
- SCons `--gprof`/`--pprof` 内置 profiling
- gem5 源码级优化实施
- O3 CPU 模型 profiling
- FS (全系统仿真) 模式 profiling
