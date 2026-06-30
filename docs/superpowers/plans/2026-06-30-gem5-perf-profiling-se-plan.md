# gem5 X86 SE Mode perf Profiling — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 搭建 perf profiling 环境, 对 gem5 X86 SE 模式的执行过程采样分析, 定位 CPU 热点和 cache miss。

**Architecture:** 独立 `profiling/` 目录包含 env.sh(环境入口)、build.sh(构建封装)、workload.c(4阶段计算负载)、se_profile.py(gem5 stdlib SE脚本)、run.sh(perf+gem5全流程)、analyze.sh(分析脚本)。所有路径通过 env.sh 中的 GEM5_HOME 变量控制, 跨机器可迁移。

**Tech Stack:** gem5 v25.1.0.1 stdlib, gcc, perf 6.14, bash, C

**Ref:** `docs/superpowers/specs/2026-06-30-gem5-perf-profiling-se-design.md`

---

## Phase 1: Infrastructure (Tasks 1–4)

### Task 1: Create directory structure and .gitignore

**Objective:** 建立 profiling/ 目录树, output/ 加入 .gitignore

**Files:**
- Create: `profiling/.gitignore`
- Create: `profiling/` 下的子目录

**Step 1: 创建目录和 .gitignore**

```bash
mkdir -p profiling/{workload,configs,output}
```

**Step 2: 写 profiling/.gitignore**

```gitignore
output/
*.pyc
__pycache__/
```

**Step 3: 验证**

```bash
ls -la profiling/
ls -la profiling/workload/ profiling/configs/ profiling/output/
```

Expected: 三个子目录存在, output/ 为空。

**Step 4: Commit**

```bash
git add profiling/
git commit -m "profiling: create directory structure"
```

---

### Task 2: Write env.sh

**Objective:** 环境入口脚本, 设置 GEM5_HOME 和 GEM5_BUILD 变量

**Files:**
- Create: `profiling/env.sh`

**Step 1: 写 env.sh**

```bash
#!/bin/bash
# profiling/env.sh
# 唯一需要编辑的文件 — 设置 gem5 项目路径
# 也可通过 export GEM5_HOME=/path/to/gem5 覆盖

export GEM5_HOME="${GEM5_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
export GEM5_BUILD="${GEM5_BUILD:-$GEM5_HOME/build/ALL/gem5.opt}"
```

**Step 2: 验证变量正确**

```bash
source profiling/env.sh
echo "GEM5_HOME=$GEM5_HOME"
echo "GEM5_BUILD=$GEM5_BUILD"
```

Expected:
```
GEM5_HOME=/home/luq/Dev/opensource/gem5
GEM5_BUILD=/home/luq/Dev/opensource/gem5/build/ALL/gem5.opt
```

**Step 3: Commit**

```bash
git add profiling/env.sh
git commit -m "profiling: add env.sh — environment entry point"
```

---

### Task 3: Write build.sh

**Objective:** 封装 scons 构建命令, 接受 -j 参数

**Files:**
- Create: `profiling/build.sh`

**Step 1: 写 build.sh**

```bash
#!/bin/bash
# profiling/build.sh
# 构建 gem5 X86 opt 版本
# Usage: ./build.sh [-j N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

cd "$GEM5_HOME"
echo "Building gem5 at $GEM5_HOME ..."
scons build/ALL/gem5.opt -j "${1:-$(nproc)}"
echo "Build complete: $GEM5_BUILD"
```

**Step 2: 加执行权限**

```bash
chmod +x profiling/build.sh
```

**Step 3: 验证脚本可解析**

```bash
bash -n profiling/build.sh
```

Expected: 无输出（语法正确）。

**Step 4: Commit**

```bash
git add profiling/build.sh
git commit -m "profiling: add build.sh — scons build wrapper"
```

---

## Phase 2: Test Workload (Tasks 4–5)

### Task 4: Write workload.c

**Objective:** 4 阶段计算密集型 C 程序, 模拟 SPEC CPU 负载特征

**Files:**
- Create: `profiling/workload/workload.c`

**Step 1: 写 workload.c**

```c
/* profiling/workload/workload.c
 * Synthetic SPEC-style compute kernel for gem5 SE mode profiling.
 * 4 phases: FP matrix multiply, integer hash, branch-heavy sort, memory streaming.
 * Target: ~200M-500M instructions, ~10-30s wall clock in gem5 SE mode.
 *
 * Compile: gcc -O2 -static -o workload workload.c -lm
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define N 256
#define HASH_ITERS 200000
#define SORT_SIZE 10000
#define STREAM_SIZE (32 * 1024 * 1024)  /* 32 MiB */

/* --- Phase 1: Matrix Multiply (FMA, cache pressure) --- */
static void
phase1_matrix_multiply(void)
{
    double *a = aligned_alloc(64, N * N * sizeof(double));
    double *b = aligned_alloc(64, N * N * sizeof(double));
    double *c = aligned_alloc(64, N * N * sizeof(double));
    if (!a || !b || !c) {
        fprintf(stderr, "phase1: alloc failed\n");
        exit(1);
    }

    for (int i = 0; i < N * N; i++) {
        a[i] = (double)(i % 997) / 1000.0;
        b[i] = (double)((i * 3) % 997) / 1000.0;
        c[i] = 0.0;
    }

    for (int i = 0; i < N; i++) {
        for (int k = 0; k < N; k++) {
            double aik = a[i * N + k];
            for (int j = 0; j < N; j++) {
                c[i * N + j] += aik * b[k * N + j];
            }
        }
    }

    double checksum = 0.0;
    for (int i = 0; i < N * N; i++) {
        checksum += c[i];
    }
    printf("  phase1: matrix %dx%d checksum=%.2f\n", N, N, checksum);

    free(a);
    free(b);
    free(c);
}

/* --- Phase 2: Hash computation (integer ALU, bit ops) --- */
static uint32_t
rotl32(uint32_t x, int n)
{
    return (x << n) | (x >> (32 - n));
}

static void
phase2_hash_compute(void)
{
    /* Simplified SHA-256-like mixing */
    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    uint32_t data[16];

    for (int iter = 0; iter < HASH_ITERS; iter++) {
        for (int i = 0; i < 16; i++) {
            data[i] = state[i % 8] ^ (iter * 0x9e3779b9 + i);
        }

        for (int round = 0; round < 64; round++) {
            uint32_t s1 = rotl32(state[4], 6) ^ rotl32(state[4], 11)
                          ^ rotl32(state[4], 25);
            uint32_t ch = (state[4] & state[5]) ^ (~state[4] & state[6]);
            uint32_t temp1 = state[7] + s1 + ch
                             + data[round % 16] + round * 0x428a2f98;

            uint32_t s0 = rotl32(state[0], 2) ^ rotl32(state[0], 13)
                          ^ rotl32(state[0], 22);
            uint32_t maj = (state[0] & state[1])
                           ^ (state[0] & state[2])
                           ^ (state[1] & state[2]);
            uint32_t temp2 = s0 + maj;

            state[7] = state[6];
            state[6] = state[5];
            state[5] = state[4];
            state[4] = state[3] + temp1;
            state[3] = state[2];
            state[2] = state[1];
            state[1] = state[0];
            state[0] = temp1 + temp2;
        }
    }

    printf("  phase2: hash %d iters final state[0]=0x%08x\n",
           HASH_ITERS, state[0]);
}

/* --- Phase 3: Branch-heavy sort (branch predictor stress) --- */
static int
cmp_int(const void *a, const void *b)
{
    int ia = *(const int *)a;
    int ib = *(const int *)b;
    return (ia > ib) - (ia < ib);
}

static void
phase3_branch_sort(void)
{
    int *arr = malloc(SORT_SIZE * sizeof(int));
    if (!arr) {
        fprintf(stderr, "phase3: malloc failed\n");
        exit(1);
    }

    srand(42);
    for (int i = 0; i < SORT_SIZE; i++) {
        arr[i] = rand() % SORT_SIZE;
    }

    qsort(arr, SORT_SIZE, sizeof(int), cmp_int);

    int sorted = 1;
    for (int i = 1; i < SORT_SIZE; i++) {
        if (arr[i] < arr[i - 1]) {
            sorted = 0;
            break;
        }
    }
    printf("  phase3: sorted %d elements, sorted=%d\n", SORT_SIZE, sorted);

    free(arr);
}

/* --- Phase 4: Memory streaming (prefetcher / bandwidth) --- */
static void
phase4_memory_stream(void)
{
    size_t size = STREAM_SIZE;
    char *src = aligned_alloc(64, size);
    char *dst = aligned_alloc(64, size);
    if (!src || !dst) {
        fprintf(stderr, "phase4: alloc failed\n");
        exit(1);
    }

    memset(src, 0xAB, size);

    /* Forward copy */
    memcpy(dst, src, size);
    /* Backward copy */
    for (size_t i = 0; i < size; i++) {
        src[i] = dst[size - 1 - i];
    }
    /* Forward copy again */
    memcpy(dst, src, size);

    size_t checksum = 0;
    for (size_t i = 0; i < size; i++) {
        checksum += (unsigned char)dst[i];
    }
    printf("  phase4: stream %zu MiB checksum=%zu\n",
           size / (1024 * 1024), checksum);

    free(src);
    free(dst);
}

/* --- Main --- */
int
main(void)
{
    printf("=== gem5 SE profiling workload ===\n");

    phase1_matrix_multiply();
    phase2_hash_compute();
    phase3_branch_sort();
    phase4_memory_stream();

    printf("=== done ===\n");
    return 0;
}
```

**Step 2: 验证编译**

```bash
gcc -O2 -static -o /tmp/workload_test profiling/workload/workload.c -lm
/tmp/workload_test
rm /tmp/workload_test
```

Expected: 四个 phase 输出 checksum/state[0]/sorted/checksum。

**Step 3: Commit**

```bash
git add profiling/workload/workload.c
git commit -m "profiling: add synthetic SPEC-style compute workload"
```

---

### Task 5: Write workload Makefile

**Objective:** 封装 workload 编译命令

**Files:**
- Create: `profiling/workload/Makefile`

**Step 1: 写 Makefile**

```makefile
# profiling/workload/Makefile
.PHONY: all clean

all: workload

workload: workload.c
	gcc -O2 -static -o workload workload.c -lm

clean:
	rm -f workload
```

注意：Makefile 必须用 Tab 缩进，不是空格。

**Step 2: 验证编译**

```bash
make -C profiling/workload/
file profiling/workload/workload
```

Expected: `ELF 64-bit LSB executable, x86-64, statically linked`.

**Step 3: Commit**

```bash
git add profiling/workload/Makefile
git commit -m "profiling: add workload Makefile"
```

---

## Phase 3: SE Mode Script (Task 6)

### Task 6: Write se_profile.py

**Objective:** gem5 stdlib SE 模式脚本, 最小化配置, 通过 argparse 接受 binary 和 output-dir

**Files:**
- Create: `profiling/configs/se_profile.py`

**Step 1: 写 se_profile.py**

```python
#!/usr/bin/env python3
"""
gem5 SE mode profiling script.
Usage: gem5.opt se_profile.py --binary <elf> --output-dir <dir>
"""
import argparse
import os
from pathlib import Path

import m5
from m5.objects import Root

from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.classic.private_l1_shared_l2_cache_hierarchy import (
    PrivateL1SharedL2CacheHierarchy,
)
from gem5.components.memory.single_channel import SingleChannelDDR3_1600
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.simulate.simulator import Simulator


def parse_args():
    parser = argparse.ArgumentParser(
        description="gem5 X86 SE mode profiling runner"
    )
    parser.add_argument(
        "--binary",
        required=True,
        help="Path to the statically-linked X86 ELF binary",
    )
    parser.add_argument(
        "--output-dir",
        default="output",
        help="Directory for gem5 stats output",
    )
    parser.add_argument(
        "--arguments",
        nargs="*",
        default=[],
        help="Arguments to pass to the workload binary",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Verify binary exists
    binary_path = Path(args.binary).resolve()
    if not binary_path.exists():
        raise FileNotFoundError(f"Binary not found: {binary_path}")

    # Cache hierarchy
    cache_hierarchy = PrivateL1SharedL2CacheHierarchy(
        l1d_size="32kB",
        l1i_size="32kB",
        l2_size="256kB",
    )

    # Memory
    memory = SingleChannelDDR3_1600("1GiB")

    # Processor
    processor = SimpleProcessor(
        cpu_type=CPUTypes.TIMING,
        num_cores=1,
        isa=ISA.X86,
    )

    # Board
    board = SimpleBoard(
        clk_freq="3GHz",
        processor=processor,
        memory=memory,
        cache_hierarchy=cache_hierarchy,
    )

    # Set SE workload
    board.set_se_binary_workload(
        binary=str(binary_path),
        arguments=args.arguments,
    )

    # Simulator
    simulator = Simulator(board=board)

    # Run
    print(f"Starting gem5 SE simulation...")
    print(f"  binary:   {binary_path}")
    print(f"  CPU:      TIMING, 1 core @ 3GHz")
    print(f"  cache:    L1I 32KB, L1D 32KB, L2 256KB")
    print(f"  memory:   DDR3-1600, 1GiB")
    simulator.run()

    print(f"Simulation complete.")


if __name__ == "__m5_main__":
    main()
```

**Step 2: 语法检查**

```bash
python3 -c "import py_compile; py_compile.compile('profiling/configs/se_profile.py', doraise=True)"
```

Expected: 无输出（导入 m5 模块会失败，但语法检查用 py_compile 不应该触发导入）。

**Step 3: Commit**

```bash
git add profiling/configs/se_profile.py
git commit -m "profiling: add SE mode stdlib script"
```

---

## Phase 4: Run & Analyze Scripts (Tasks 7–8)

### Task 7: Write run.sh

**Objective:** 全流程脚本 — 编译 workload → perf stat → perf record + gem5

**Files:**
- Create: `profiling/run.sh`

**Step 1: 写 run.sh**

```bash
#!/bin/bash
# profiling/run.sh
# Full profiling pipeline: build → compile workload → perf stat → perf record + gem5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$OUTPUT_DIR"

# 1. Compile workload
echo "=== Compiling workload ==="
make -C "$SCRIPT_DIR/workload"
WORKLOAD_BIN="$SCRIPT_DIR/workload/workload"
echo "Workload binary: $WORKLOAD_BIN"

# 2. Verify gem5 binary exists
if [ ! -x "$GEM5_BUILD" ]; then
    echo "ERROR: gem5 binary not found at $GEM5_BUILD"
    echo "Run './build.sh' first or set GEM5_BUILD."
    exit 1
fi

# 3. perf stat — 宏观指标
echo ""
echo "=== Layer 1: perf stat ==="
perf stat \
    -e cycles,instructions,cache-references,cache-misses,\
branch-instructions,branch-misses,L1-dcache-load-misses,\
L1-icache-load-misses \
    -o "$OUTPUT_DIR/perf.stat.txt" \
    "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
    --binary "$WORKLOAD_BIN" \
    --output-dir "$OUTPUT_DIR"

echo "perf stat done → $OUTPUT_DIR/perf.stat.txt"
cat "$OUTPUT_DIR/perf.stat.txt"

# 4. perf record — 采样
echo ""
echo "=== Layer 2: perf record ==="
perf record \
    --call-graph dwarf \
    -F 99 \
    -e cycles,instructions,cache-misses,branch-misses \
    -o "$OUTPUT_DIR/perf.data" \
    "$GEM5_BUILD" "$SCRIPT_DIR/configs/se_profile.py" \
    --binary "$WORKLOAD_BIN" \
    --output-dir "$OUTPUT_DIR"

echo "perf record done → $OUTPUT_DIR/perf.data"
echo ""
echo "=== Run complete ==="
echo "Next: run ./analyze.sh to generate reports"
```

**Step 2: 加执行权限**

```bash
chmod +x profiling/run.sh
```

**Step 3: 验证语法**

```bash
bash -n profiling/run.sh
```

**Step 4: Commit**

```bash
git add profiling/run.sh
git commit -m "profiling: add run.sh — full profiling pipeline"
```

---

### Task 8: Write analyze.sh

**Objective:** 分析脚本 — perf report + annotate + FlameGraph 生成

**Files:**
- Create: `profiling/analyze.sh`

**Step 1: 写 analyze.sh**

```bash
#!/bin/bash
# profiling/analyze.sh
# Generate reports from perf.data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
PERF_DATA="$OUTPUT_DIR/perf.data"

if [ ! -f "$PERF_DATA" ]; then
    echo "ERROR: perf.data not found at $PERF_DATA"
    echo "Run './run.sh' first."
    exit 1
fi

# FlameGraph path
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/FlameGraph}"

echo "=== Generating perf reports ==="

# 1. Hotspots by function
echo "[1/4] Top hotspot functions..."
perf report --stdio --sort=overhead,dso,symbol \
    -i "$PERF_DATA" \
    > "$OUTPUT_DIR/perf_report_hotspots.txt"
echo "  → $OUTPUT_DIR/perf_report_hotspots.txt"

# 2. Cache misses by function
echo "[2/4] Cache miss analysis..."
perf report --stdio --sort=overhead,symbol \
    -i "$PERF_DATA" -e cache-misses \
    > "$OUTPUT_DIR/perf_report_cache.txt"
echo "  → $OUTPUT_DIR/perf_report_cache.txt"

# 3. Branch misses by function
echo "[3/4] Branch miss analysis..."
perf report --stdio --sort=overhead,symbol \
    -i "$PERF_DATA" -e branch-misses \
    > "$OUTPUT_DIR/perf_report_branch.txt"
echo "  → $OUTPUT_DIR/perf_report_branch.txt"

# 4. FlameGraph (if available)
echo "[4/4] FlameGraph..."
if [ -d "$FLAMEGRAPH_DIR" ]; then
    perf script -i "$PERF_DATA" \
        | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" \
        > "$OUTPUT_DIR/flamegraph.svg"
    echo "  → $OUTPUT_DIR/flamegraph.svg"
else
    echo "  SKIP: FlameGraph not found at $FLAMEGRAPH_DIR"
    echo "  Install: git clone https://github.com/brendangregg/FlameGraph.git ~/FlameGraph"
fi

echo ""
echo "=== Analysis complete ==="
echo "Files in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR/"
```

**Step 2: 加执行权限 + 语法检查**

```bash
chmod +x profiling/analyze.sh
bash -n profiling/analyze.sh
```

**Step 3: Commit**

```bash
git add profiling/analyze.sh
git commit -m "profiling: add analyze.sh — perf report + flamegraph"
```

---

## Phase 5: Execution & Verification (Tasks 9–16)

### Task 9: Install system dependencies

**Objective:** 安装 perf tools 和 FlameGraph

**Commands:**

```bash
# perf tools
sudo apt install -y linux-tools-common linux-tools-generic

# FlameGraph (skip if already exists)
if [ ! -d ~/FlameGraph ]; then
    git clone https://github.com/brendangregg/FlameGraph.git ~/FlameGraph
fi
```

**Verification:**

```bash
perf --version
ls ~/FlameGraph/flamegraph.pl
```

Expected: `perf version 6.14.11`, flamegraph.pl 存在。

---

### Task 10: Build gem5

**Objective:** 构建 gem5 X86 opt 变体

**Commands:**

```bash
cd /home/luq/Dev/opensource/gem5
./profiling/build.sh -j12
```

**Verification:**

```bash
ls -lh build/ALL/gem5.opt
file build/ALL/gem5.opt
```

Expected: ELF 可执行文件，大小约 100-200MB。

---

### Task 11: Compile workload

**Objective:** 编译测试负载，验证本地运行正确

**Commands:**

```bash
cd /home/luq/Dev/opensource/gem5
make -C profiling/workload/
```

**Verification:**

```bash
profiling/workload/workload
```

Expected: 四个 phase 都输出 checksum/state/sorted/checksum，总运行 < 1 秒。

---

### Task 12: Run perf stat

**Objective:** 在 gem5 SE 模式下跑 workload，收集宏观 perf 指标

**Commands:**

```bash
cd /home/luq/Dev/opensource/gem5/profiling
source env.sh
perf stat \
    -e cycles,instructions,cache-references,cache-misses,\
branch-instructions,branch-misses,L1-dcache-load-misses,\
L1-icache-load-misses \
    "$GEM5_BUILD" configs/se_profile.py \
    --binary workload/workload \
    --output-dir output
```

**Verification:**

- 输出包含 `cycles`, `instructions`, `IPC` (自己算: instructions/cycles)
- IPC 预期 > 0.5

---

### Task 13: Run perf record

**Objective:** 采样 gem5 执行过程，生成 perf.data

**Commands:**

```bash
cd /home/luq/Dev/opensource/gem5/profiling
source env.sh
perf record \
    --call-graph dwarf \
    -F 99 \
    -e cycles,instructions,cache-misses,branch-misses \
    -o output/perf.data \
    "$GEM5_BUILD" configs/se_profile.py \
    --binary workload/workload \
    --output-dir output
```

**Verification:**

```bash
perf report --stdio -i output/perf.data --percent-limit=1 | head -30
```

Expected: TOP-N 函数列表，包含 gem5 内部函数名。

---

### Task 14: Run analyze.sh

**Objective:** 生成 perf 报告和 FlameGraph

**Commands:**

```bash
cd /home/luq/Dev/opensource/gem5/profiling
./analyze.sh
```

**Verification:**

```bash
ls -lh output/perf_report_hotspots.txt \
      output/perf_report_cache.txt \
      output/perf_report_branch.txt \
      output/flamegraph.svg
```

Expected: 四个文件都存在，flamegraph.svg 可打开。

---

### Task 15: Review results and write report.md

**Objective:** 根据 perf 数据写出分析报告

**Commands:**

查看关键数据：

```bash
# IPC
grep -E "cycles|instructions" profiling/output/perf.stat.txt

# TOP-10 热点
head -30 profiling/output/perf_report_hotspots.txt

# Cache miss TOP-10
head -30 profiling/output/perf_report_cache.txt

# Branch miss TOP-10
head -30 profiling/output/perf_report_branch.txt
```

编写 `profiling/output/report.md` 按 [设计文档 Section 9](#) 的结构：

1. Summary (IPC, cache-miss%, branch-miss%)
2. Top Hotspots（按子系统分类）
3. Cache Miss Analysis
4. Branch Miss Analysis
5. Optimization Suggestions（每条有数据支撑）
6. FlameGraph 截图链接

**Verification:** report.md 中每一条优化建议引用了具体的 perf 数据。

---

### Task 16: Final commit

**Objective:** 将 profiling 目录所有文件提交，并将 plan 文件提交

**Commands:**

```bash
# Commit the profiling directory (if any uncommitted changes)
git add profiling/ && git status

# Check for .gitignore preventing output/ from being committed
git check-ignore profiling/output/

# If output/ is properly ignored, commit
git commit -m "profiling: add profiling scripts and reports"

# Also commit the plan file
mkdir -p docs/superpowers/plans
# (plan saved as docs/superpowers/plans/2026-06-30-gem5-perf-profiling-se-plan.md)
git add docs/superpowers/plans/
git commit -m "doc: add implementation plan for perf profiling"
```

**Verification:**

```bash
git log --oneline -5
```

Expected: 16 个 profiling 相关 commit + plan commit。

---

## Post-Implementation

完成后将 `profiling/` 目录整体迁移：

```bash
cp -r profiling/ /other/machine/
cd /other/machine/profiling
# 编辑 env.sh 或 export GEM5_HOME
export GEM5_HOME=/new/path/to/gem5
./build.sh -j$(nproc)
./run.sh
```
