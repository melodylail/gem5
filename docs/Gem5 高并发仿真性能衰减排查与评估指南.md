# Gem5 高并发仿真性能衰减排查与评估指南

## 1. 问题背景
在一台拥有 2.2T 内存的服务器上，通过 LSF 提交了 230 个 Gem5 仿真任务。每个任务的内存需求在 5G-20G 不等。虽然通过调度策略控制了整体内存消耗不超过 80%（避免了 OOM），但在系统内存使用率达到 80% 左右时，发现部分任务的运行时间比系统空闲（内存使用率 \( < 10\% \)）时慢了约 10 倍。

**结论：这种情况在高性能计算（HPC）和密集型仿真环境（如 Gem5）中是比较正常的。**
虽然限制了全局内存使用率，但高并发和高内存占用会导致底层硬件资源的严重争抢。

---

## 2. 速度变慢的核心原因及确认方法

### 2.1 内存带宽瓶颈 (Memory Bandwidth Saturation)
Gem5 仿真器在运行时会频繁进行内存读写。当 230 个任务同时运行时，服务器的**内存总线带宽**可能已经被完全打满。此时 CPU 必须等待数据传输，导致任务执行时间大幅延长。
* **确认方法**：使用 `pcm-memory` (Intel) 或 `amd-uprof` (AMD) 监控实时的内存带宽利用率。如果读写带宽接近硬件理论上限，即为带宽瓶颈。

### 2.2 NUMA 节点不平衡与跨节点访问 (NUMA Effects)
2.2T 内存的服务器通常是多路（Multi-Socket）NUMA 架构。如果任务的 CPU 核心和分配到的内存不在同一个 NUMA 节点上，跨节点访问延迟极高。此外，即使全局内存只有 80%，某个局部 NUMA 节点可能已经耗尽内存并触发 Swap。
* **确认方法**：
  * 运行 `numastat -m` 查看各个 NUMA 节点的内存使用情况。
  * 运行 `numastat -s` 查看 `numa_miss` 和 `numa_foreign`，数值高说明存在大量跨节点访问。
  * 使用 `free -h` 或 `vmstat 1` 检查 Swap 使用情况。

### 2.3 CPU 核心超载与上下文切换 (CPU Oversubscription)
如果服务器的物理核心数少于 230（例如只有 128 核），多个 Gem5 进程将共享同一个物理核心，导致频繁的上下文切换。超线程（Hyper-Threading）对计算密集型任务提升有限，甚至会因争抢缓存导致变慢。
* **确认方法**：
  * 使用 `lscpu` 确认物理核心数。
  * 使用 `top` 或 `htop` 查看 Load Average，远大于物理核心数说明 CPU 严重超载。
  * 使用 `vmstat 1` 观察 `cs`（Context Switch）列，数值异常高说明切换开销巨大。

### 2.4 最后一级缓存 (LLC) 争抢与 TLB Miss
230 个独立进程会导致 CPU 的 L3 缓存（Last Level Cache）被严重挤占（Cache Thrashing）。大量内存的寻址也会导致 TLB（Translation Lookaside Buffer）频繁 Miss。
* **确认方法**：使用 `perf stat -e cache-misses,cache-references,dTLB-load-misses -p <PID>` 观察缓存未命中率。

### 2.5 透明大页 (THP) 导致的系统停顿
Linux 默认开启 THP。在内存碎片化严重（80% 使用率）时，内核的 `khugepaged` 进程会消耗大量 CPU 资源进行内存碎片整理，甚至阻塞申请内存的进程。
* **确认方法**：
  * 查看 `cat /proc/vmstat | grep thp`，如果 `thp_fault_fallback` 很高，说明 THP 正在拖慢系统。
  * `top` 中观察是否有 `khugepaged` 进程占用大量 CPU。

### 2.6 磁盘 I/O 争抢
230 个任务同时向磁盘写入 Trace 或 Log 数据，可能会打满存储的 IOPS 或写入带宽。
* **确认方法**：使用 `iostat -x 1` 查看 `%util` 和 `await`。如果 `%util` 接近 100% 且 `await` 很高，说明是 I/O 瓶颈。

---

## 3. 如何有效评估 Job 的运行速度及受影响程度

要量化受影响的程度，需要建立**基准（Baseline）**，并结合宏观、微观和应用层指标进行对比。

### 3.1 建立基准线 (Baseline)
在**系统空闲（Host 内存和 CPU 使用率极低）**的情况下，单独运行一个代表性的 Gem5 job，记录各项指标作为“理想状态”的基准。

### 3.2 宏观评估：时间维度的对比
使用 `time` 命令或 LSF 报告 (`bhist -l`) 查看时间：
* **Real Time (墙上时间)**：任务从开始到结束的绝对时间。
* **User Time (用户态 CPU 时间)**：CPU 真正花在执行 Gem5 代码上的时间。

**评估逻辑**：
* **场景 A**：Real Time 暴增，但 User Time 变化不大 \(\rightarrow\) 进程在大量“等待”（CPU 核心超载排队或 I/O 阻塞）。
* **场景 B**：Real Time 和 User Time 同步暴增 \(\rightarrow\) CPU 一直在工作但效率极低（内存带宽打满、LLC 争抢或跨 NUMA 访问）。

### 3.3 应用层评估：Gem5 内部统计指标
提取仿真结束后生成的 `stats.txt` 文件中的关键指标：
* `hostSeconds`：宿主机消耗的真实时间。
* `simInsts`：仿真的总指令数。
* **核心公式**：
  \[
  仿真速度 = \frac{simInsts}{hostSeconds}
  \]
  *(即宿主机每秒仿真的指令数)*

**性能衰减率计算**：
\[
性能衰减率 = \left(1 - \frac{高负载下的仿真速度}{基准仿真速度}\right) \times 100\%
\]

### 3.4 微观评估：硬件性能指标
在高负载时，使用 `perf` 对慢 Job 进行抽样分析：

perf stat -p <PID> -d sleep 10

重点观察：

IPC (Instructions Per Cycle)：正常在 1.0-2.0，如果降到 0.1，说明 CPU 大部分时间在停顿（Stall），是内存/缓存瓶颈的铁证。
LLC-load-misses：未命中率飙升说明 L3 缓存被挤爆。
3.5 总结与量化表格示例
建议在 LSF 脚本中自动提取数据并生成如下表格，以便直观判定瓶颈：

Job     ID	内存占用	NUMA节点	    Host CPU负载	墙上时间(Real)	CPU时间(User)	仿真速度(Insts/s)	速度下降倍数
1001    	15G	Node 0	10%	        1.0 小时	                    0.98 小时	    1,200,000	        1.0x (Baseline)
2055	    15G	Node 1	80%	        10.5 小时	                10.2 小时	    114,000	            10.5x

### 3.6 宿主机内存趋势评估 (Host Memory Trend Evaluation)

参见 [`profiling/mem/README.md`](../../profiling/mem/README.md)。

快速启用：`MEM_TREND=1 ./profiling/run.sh`

---

## 4. 优化建议
限制并发数：结合物理核心数和内存带宽来限制并发量，而非仅看内存容量。
绑定 NUMA 节点：使用 numactl 或 LSF 亲和性调度，将任务强制绑定到特定 NUMA 节点。
关闭 THP 碎片整理：执行 echo madvise > /sys/kernel/mm/transparent_hugepage/defrag。
优化 I/O：将输出目录指向本地高速 NVMe SSD，或关闭不必要的 Trace 输出。
