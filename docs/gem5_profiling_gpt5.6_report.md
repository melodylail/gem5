判断优先级
1. **CPU 调度不足、SMT sibling 竞争、CPU affinity 不合理**
2. **共享 LLC 被 230 个 gem5 进程冲刷，进一步放大 gem5 固有的前端瓶颈**
3. **swap、direct reclaim、memory PSI stall**
4. **全核负载导致 CPU 频率下降**
5. **NUMA 局部内存不足或跨 socket 访问**
6. **DRAM 带宽饱和**
7. **共享存储 I/O**
8. **THP/内存规整问题**

特别需要修正的是：

> **不能仅凭 1.76 TB 内存被使用，就推断 DRAM 带宽一定饱和。**

论文发现，单个 gem5 进程：

- 是**单线程**应用；
- 主要瓶颈是 instruction front-end；
- iCache、iTLB miss 高；
- µOp cache 利用率低；
- DRAM bandwidth 很低；
- 单进程 LLC occupancy 约为 255 KB～3.1 MB。

因此，大量 RSS 不等于大量活跃 DRAM 流量。5～20 GB RSS 中可能包含模拟内存、page cache、冷页和很少访问的页。

但是，230 个进程的累计活跃 LLC footprint 可能达到：

```text
230 × 255 KB ≈ 58.7 MB
230 × 3.1 MB ≈ 713 MB
```

这通常远大于单个 socket 的 LLC。结果可能是：

```text
多个 gem5 进程
    ↓
LLC/iCache/TLB 相互干扰
    ↓
前端 stall 增加
    ↓
IPC 下降
    ↓
单 job hostInstRate 下降
```

论文还给出了两个非常关键的依据：

- 同一 Xeon 上，关闭 SMT、每个物理核运行一个 gem5，相比填满 hardware threads，运行时间平均减少约 **47%**；
- CPU 从 3.1 GHz 降到 1.2 GHz，gem5 时间增加约 **2.67 倍**。

所以，**SMT + cache contention + 降频**叠加后可以产生几倍下降，但如果真的达到稳定的 **10 倍下降**，还要重点寻找：

- job 实际只得到约 10% CPU；
- swap/direct reclaim；
- memory PSI；
- 严重 I/O wait；
- 特定 NUMA node 内存耗尽。

---

# 一、建议的总体实验方法

不要直接比较“内存低于10%时的某个 job”和“内存80%时另一个 job”。

选择一个固定的 canary job，确保：

- 相同 gem5 binary；
- 相同配置；
- 相同 checkpoint；
- 相同 simulated CPU model；
- 相同 ROI；
- 相同 `simInsts` 或 `simTicks`；
- 使用独立输出目录；
- 固定到相同的 physical core 和 NUMA node。

然后按以下并发规模测试：

```text
1
物理核数的25%
物理核数的50%
物理核数的75%
物理核数的100%
全部SMT threads
230 jobs
```

每个点记录：

```text
hostInstRate
hostTickRate
job %CPU
task-clock
IPC
iTLB miss
iCache miss
branch miss
CPU frequency
LLC miss
memory PSI
swap/reclaim
NUMA locality
DRAM bandwidth
I/O latency
```

gem5 官方对 `hostSeconds`、`hostTickRate` 和 `hostInstRate` 的定义与上述用法一致。([gem5.org](https://www.gem5.org/documentation/learning_gem5/part1/gem5_stats/?utm_source=openai))

---

# 二、脚本 0：收集服务器基本拓扑

保存为 `00_inventory.sh`：

```bash
#!/usr/bin/env bash
set -u

OUT=${1:-inventory_$(date +%Y%m%d_%H%M%S).log}

exec > >(tee "$OUT") 2>&1

echo "===== DATE / HOST ====="
date -Is
hostname
uname -a

echo
echo "===== CPU SUMMARY ====="
lscpu

echo
echo "===== CPU TOPOLOGY ====="
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE,MAXMHZ,MINMHZ

echo
echo "Logical CPUs:"
nproc --all

echo "Physical cores:"
lscpu -p=CORE,SOCKET |
    grep -v '^#' |
    sort -u |
    wc -l

echo
echo "Sockets:"
lscpu -p=SOCKET |
    grep -v '^#' |
    sort -u |
    wc -l

echo
echo "===== SMT SIBLINGS ====="
for f in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
    printf "%s: " "$(basename "$(dirname "$(dirname "$f")")")"
    cat "$f"
done | sort -V

echo
echo "===== NUMA ====="
if command -v numactl >/dev/null; then
    numactl --hardware
fi

if command -v numastat >/dev/null; then
    numastat -m
fi

echo
echo "===== MEMORY ====="
free -h
grep -E \
'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|AnonPages|AnonHugePages|HugePages' \
/proc/meminfo

echo
echo "===== SWAP ====="
swapon --show || true

echo
echo "===== THP ====="
for f in \
    /sys/kernel/mm/transparent_hugepage/enabled \
    /sys/kernel/mm/transparent_hugepage/defrag; do
    if [[ -r "$f" ]]; then
        echo "$f: $(cat "$f")"
    fi
done

echo
echo "===== PSI ====="
for r in cpu memory io; do
    echo "--- $r ---"
    cat "/proc/pressure/$r" 2>/dev/null || echo "not supported"
done

echo
echo "===== CPU GOVERNOR ====="
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -r "$f" ]] && echo "$f: $(cat "$f")"
done | sort -V | uniq -f1 -c

echo
echo "Saved to $OUT"
```

运行：

```bash
chmod +x 00_inventory.sh
./00_inventory.sh
```

首先确认：

- 230 是小于还是大于 physical cores；
- 230 是否接近 logical CPUs；
- 是否启用 SMT；
- 有几个 NUMA node；
- 每个 node 有多少内存；
- swap 是否启用。

---

# 三、脚本 1：对一个慢 gem5 PID 做全局采样

保存为 `01_collect_pid.sh`：

```bash
#!/usr/bin/env bash
set -u

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-profile_${PID}_$(date +%Y%m%d_%H%M%S)}

if [[ ! -d /proc/"$PID" ]]; then
    echo "PID $PID does not exist"
    exit 1
fi

mkdir -p "$OUT"

echo "Profiling PID=$PID for ${SECONDS}s into $OUT"

date -Is > "$OUT/start_time.txt"
ps -fp "$PID" > "$OUT/process.txt"
cat /proc/"$PID"/status > "$OUT/status.before"
cat /proc/"$PID"/smaps_rollup > "$OUT/smaps_rollup.before" 2>/dev/null || true
cat /proc/vmstat > "$OUT/vmstat.before"
cat /proc/meminfo > "$OUT/meminfo.before"

timeout "$SECONDS" vmstat -w -t 1 \
    > "$OUT/vmstat.log" 2>&1 &

if command -v mpstat >/dev/null; then
    timeout "$SECONDS" mpstat -P ALL 1 \
        > "$OUT/mpstat.log" 2>&1 &
fi

if command -v pidstat >/dev/null; then
    timeout "$SECONDS" pidstat -h -p "$PID" -u -r -d -w 1 \
        > "$OUT/pidstat.log" 2>&1 &
fi

if command -v iostat >/dev/null; then
    timeout "$SECONDS" iostat -xz 1 \
        > "$OUT/iostat.log" 2>&1 &
fi

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        for r in cpu memory io; do
            echo "--- $r ---"
            cat "/proc/pressure/$r" 2>/dev/null || true
        done
        sleep 1
    done
) > "$OUT/psi.log" &

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        ps -o pid,psr,stat,pcpu,pmem,rss,vsz,nlwp,wchan:32,etime,cmd \
            -p "$PID"
        sleep 1
    done
) > "$OUT/process_watch.log" &

wait || true

cat /proc/"$PID"/status > "$OUT/status.after" 2>/dev/null || true
cat /proc/"$PID"/smaps_rollup > "$OUT/smaps_rollup.after" 2>/dev/null || true
cat /proc/vmstat > "$OUT/vmstat.after"
cat /proc/meminfo > "$OUT/meminfo.after"
date -Is > "$OUT/end_time.txt"

echo "Done: $OUT"
```

运行：

```bash
./01_collect_pid.sh <gem5-pid> 300
```

## 首先查看

```bash
less profile_*/pidstat.log
less profile_*/vmstat.log
less profile_*/psi.log
```

单线程 gem5 在正常获得一个 CPU 时，通常应该接近：

```text
%CPU ≈ 100%
```

如果高并发时只剩：

```text
%CPU = 10%～20%
```

那么 10 倍变慢已经可以直接解释：它实际只获得了十分之一左右的 CPU 时间。

`vmstat` 中：

- `r` 是 runnable processes；
- `b` 是等待 I/O 的 blocked processes；
- `si/so` 是每秒 swap-in/swap-out；
- `cs` 是 context switches；
- `wa` 是 I/O wait。([man7.org](https://www.man7.org/linux/man-pages/man8/vmstat.8.html?utm_source=openai))

---

# 四、实验 1：验证 CPU oversubscription

## 判断指标

```bash
PHYSICAL_CORES=$(
    lscpu -p=CORE,SOCKET |
    grep -v '^#' |
    sort -u |
    wc -l
)

echo "Physical cores = $PHYSICAL_CORES"

vmstat -w 1
```

如果：

```text
r 长期明显大于 physical cores
```

并且慢 job：

```text
%CPU 明显低于100%
nonvoluntary context switches很高
CPU PSI some很高
```

优先判定为 CPU scheduling contention。

PSI 中的 `some` 表示至少有任务因该资源阻塞；memory/io 的 `full` 表示所有非 idle 任务同时被阻塞，持续出现通常意味着严重 thrashing。([docs.kernel.org](https://docs.kernel.org/6.10/accounting/psi.html?utm_source=openai))

## 提取 PSI

```bash
awk '
/^some/ {
    for (i=1; i<=NF; i++)
        if ($i ~ /^avg10=/) print $i
}
' /proc/pressure/cpu
```

### 典型判断

| 结果 | 解释 |
|---|---|
| job `%CPU≈100%` | job 基本获得完整单核 |
| job `%CPU≈50%` | 平均只能获得半个核 |
| job `%CPU≈10%` | 调度本身可解释约10倍下降 |
| CPU PSI 高、memory/io PSI 低 | CPU 竞争 |
| `r` 长期高于物理核数 | runnable queue 过长 |

---

# 五、实验 2：验证 SMT sibling 竞争

论文已经明确指出，gem5 对 SMT 很敏感。最直接的办法是：让同一个 canary job 分别在“独占物理核”和“SMT sibling 同时繁忙”两种情况下运行。

## 找出 SMT sibling

```bash
CPU=20
cat /sys/devices/system/cpu/cpu${CPU}/topology/thread_siblings_list
```

假设输出：

```text
20,116
```

说明 CPU 20 和 116 是同一个物理核的两个 hardware threads。

## 脚本

保存为 `02_smt_ab_test.sh`：

```bash
#!/usr/bin/env bash
set -eu

CPU0=${1:?Usage: $0 CPU0 CPU_SIBLING NUMA_NODE OUTDIR}
CPU1=${2:?}
NODE=${3:?}
OUT=${4:?}

: "${CANARY_CMD:?Set CANARY_CMD}"
: "${INTERFERER_CMD:?Set INTERFERER_CMD}"

mkdir -p "$OUT/solo" "$OUT/smt"

echo "===== SOLO TEST ====="

(
    cd "$OUT/solo"
    /usr/bin/time -v \
        numactl --physcpubind="$CPU0" --membind="$NODE" \
        bash -lc "$CANARY_CMD"
) > "$OUT/solo/stdout.log" 2> "$OUT/solo/time.log"

echo "===== SMT CONTENTION TEST ====="

(
    cd "$OUT/smt"

    numactl --physcpubind="$CPU1" --membind="$NODE" \
        bash -lc "$INTERFERER_CMD" \
        > interferer.stdout.log \
        2> interferer.stderr.log &

    INTERFERER_PID=$!
    sleep 5

    /usr/bin/time -v \
        numactl --physcpubind="$CPU0" --membind="$NODE" \
        bash -lc "$CANARY_CMD" \
        > canary.stdout.log \
        2> canary.time.log

    kill "$INTERFERER_PID" 2>/dev/null || true
    wait "$INTERFERER_PID" 2>/dev/null || true
)

echo "Results:"
grep -H \
    'Elapsed (wall clock) time\|Percent of CPU this job got\|Maximum resident' \
    "$OUT"/*/*.log || true
```

运行示例：

```bash
export CANARY_CMD='/path/gem5.opt --outdir=canary_out config.py ...'
export INTERFERER_CMD='/path/gem5.opt --outdir=interferer_out config.py ...'

./02_smt_ab_test.sh 20 116 0 smt_test
```

注意：

- 两个 gem5 必须使用不同的 `--outdir`；
- 如果 workload 会修改 checkpoint/disk image，也必须复制为独立文件；
- CPU 20 必须属于 NUMA node 0。

## 判断

如果 SMT contention 测试相对于 solo：

```text
hostInstRate 下降30%～50%
IPC下降
iCache/LLC miss增加
```

就和论文中的观察高度一致。

但 **SMT 通常不足以单独解释10倍**。如果单独 SMT 只慢1.5～2倍，还要继续检查 CPU share、reclaim 和 cache contention。

---

# 六、实验 3：验证论文中的 front-end/cache 瓶颈

论文最重要的结论是 gem5：

- front-end bound；
- iCache miss 高；
- iTLB miss 高；
- branch resteer 高；
- µOp cache coverage 低；
- 复杂模型如 O3/Minor 更明显。

`perf stat` 可以附加到指定 PID，并以周期方式输出计数器。不同 CPU 型号支持的事件有所不同，应先用 `perf list` 检查。([man7.org](https://man7.org/linux/man-pages/man1/perf-stat.1.html?utm_source=openai))

## 通用 perf 脚本

保存为 `03_perf_gem5.sh`：

```bash
#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-perf_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

if [[ ! -d /proc/"$PID" ]]; then
    echo "PID $PID does not exist"
    exit 1
fi

echo "Available related events:" > "$OUT/available_events.txt"

perf list 2>/dev/null |
    grep -Ei \
    'topdown|frontend|front.end|icache|iTLB|LLC|branch|cache.miss|stalled' \
    >> "$OUT/available_events.txt" || true

COMMON_EVENTS="
task-clock,
cycles,
instructions,
branches,
branch-misses,
cache-references,
cache-misses,
page-faults,
major-faults,
context-switches,
cpu-migrations
"

COMMON_EVENTS=$(echo "$COMMON_EVENTS" | tr -d '[:space:]')

perf stat \
    -p "$PID" \
    -I 1000 \
    -x, \
    -e "$COMMON_EVENTS" \
    -o "$OUT/perf_common.csv" \
    -- sleep "$SECONDS"

# 以下事件并非所有CPU都支持，因此单独尝试。
OPTIONAL_EVENTS="
iTLB-loads,
iTLB-load-misses,
dTLB-loads,
dTLB-load-misses,
L1-icache-load-misses,
LLC-loads,
LLC-load-misses
"

OPTIONAL_EVENTS=$(echo "$OPTIONAL_EVENTS" | tr -d '[:space:]')

perf stat \
    -p "$PID" \
    -I 1000 \
    -x, \
    -e "$OPTIONAL_EVENTS" \
    -o "$OUT/perf_optional.csv" \
    -- sleep "$SECONDS" 2>"$OUT/perf_optional.error" || true

echo "Saved to $OUT"
```

运行：

```bash
sudo ./03_perf_gem5.sh <PID> 300
```

## 手工计算 IPC

最终汇总中：

```text
IPC = instructions / cycles
```

例如：

```text
低负载：IPC = 1.2
高负载：IPC = 0.25
```

同时：

```text
job %CPU仍接近100%
cache miss增加
iTLB miss增加
branch miss增加
```

说明 job 不是没获得 CPU，而是**每个 CPU cycle 完成的有效工作减少了**，符合 cache/front-end contention。

## 关键分类

| `%CPU` | IPC | 判断 |
|---:|---:|---|
| 大幅下降 | 差不多 | CPU 调度不足 |
| 接近100% | 大幅下降 | cache/front-end/内存延迟 |
| 大幅下降 | 大幅下降 | CPU contention和cache contention叠加 |
| 接近100% | 差不多 | 需要检查 gem5 phase、频率或I/O |

不要让多个 `perf` 或 PCM 工具同时竞争 PMU。低负载和高负载分别测一次，再比较结果。

---

# 七、实验 4：检查 swap、direct reclaim 和 compaction

这是最能解释稳定10倍甚至更大下降的系统级原因。

保存为 `04_memory_pressure.sh`：

```bash
#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-memory_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

COUNTERS='
pswpin
pswpout
pgmajfault
pgfault
pgscan_direct
pgscan_kswapd
pgsteal_direct
pgsteal_kswapd
allocstall_normal
allocstall_movable
compact_stall
compact_fail
compact_success
thp_fault_alloc
thp_fault_fallback
thp_collapse_alloc
thp_collapse_alloc_failed
'

snapshot_vmstat()
{
    local output=$1

    for c in $COUNTERS; do
        awk -v key="$c" '
            $1 == key {
                print $1, $2
                found=1
            }
            END {
                if (!found)
                    print key, 0
            }
        ' /proc/vmstat
    done > "$output"
}

snapshot_vmstat "$OUT/vmstat.before"

cat /proc/pressure/memory > "$OUT/memory_psi.before"
cat /proc/pressure/io > "$OUT/io_psi.before"

grep -E \
'VmRSS|VmHWM|VmSwap|RssAnon|RssFile|voluntary_ctxt|nonvoluntary_ctxt' \
/proc/"$PID"/status > "$OUT/process.before"

timeout "$SECONDS" vmstat -w -t 1 \
    > "$OUT/vmstat.timeline" 2>&1 &

timeout "$SECONDS" pidstat -h -p "$PID" -r -w 1 \
    > "$OUT/pidstat.timeline" 2>&1 &

(
    end=$(( $(date +%s) + SECONDS ))
    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="
        cat /proc/pressure/memory
        sleep 1
    done
) > "$OUT/memory_psi.timeline" &

wait || true

snapshot_vmstat "$OUT/vmstat.after"

cat /proc/pressure/memory > "$OUT/memory_psi.after"
cat /proc/pressure/io > "$OUT/io_psi.after"

grep -E \
'VmRSS|VmHWM|VmSwap|RssAnon|RssFile|voluntary_ctxt|nonvoluntary_ctxt' \
/proc/"$PID"/status > "$OUT/process.after" || true

join \
    <(sort "$OUT/vmstat.before") \
    <(sort "$OUT/vmstat.after") |
awk '{
    printf "%-30s before=%-15s after=%-15s delta=%s\n",
           $1, $2, $3, $3-$2
}' > "$OUT/vmstat.delta"

cat "$OUT/vmstat.delta"
```

运行：

```bash
./04_memory_pressure.sh <PID> 300
```

## 判断

```bash
cat memory_*/vmstat.delta
```

重点关注：

```text
pswpin
pswpout
pgmajfault
pgscan_direct
pgsteal_direct
allocstall_*
compact_stall
```

### 强证据

| 指标 | 结论 |
|---|---|
| `pswpin/pswpout` 持续增长 | 实际正在 swap |
| `VmSwap` 非零并增长 | 慢进程的页被换出 |
| `pgmajfault` 快速增长 | 等待磁盘读取页面 |
| `pgscan_direct` 增长 | gem5 自己在 direct reclaim |
| `allocstall_*` 增长 | 内存分配因 reclaim stall |
| memory PSI `full` 明显非零 | 严重 memory thrashing |
| `compact_stall` 快速增长 | 内存规整可能造成延迟 |

Linux 内核文档说明，内存规整会移动不同进程的页面，具有非平凡的系统级开销，并可能产生 latency spike。([docs.kernel.org](https://docs.kernel.org/6.15/admin-guide/sysctl/vm.html?utm_source=openai))

---

# 八、实验 5：验证 NUMA locality

Linux 默认倾向于 local allocation，但 NUMA policy、cpuset 和 affinity 都可能改变分配位置；`/proc/<pid>/numa_maps` 可以检查进程各个映射的 NUMA 分布。([docs.kernel.org](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html?utm_source=openai))

保存为 `05_numa_watch.sh`：

```bash
#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [INTERVAL] [OUTDIR]}
SECONDS=${2:-120}
INTERVAL=${3:-5}
OUT=${4:-numa_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

numactl --hardware > "$OUT/hardware.txt"
numastat -m > "$OUT/system_memory.before"
numastat > "$OUT/system_numa.before"

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        CPU=$(ps -o psr= -p "$PID" | tr -d ' ' || true)
        echo "Current CPU: $CPU"

        if [[ -n "$CPU" ]]; then
            NODE_LINK=$(
                find "/sys/devices/system/cpu/cpu${CPU}" \
                    -maxdepth 1 -type l -name 'node*' \
                    2>/dev/null |
                head -1
            )

            if [[ -n "$NODE_LINK" ]]; then
                echo "Current NUMA node: $(basename "$NODE_LINK")"
            fi
        fi

        echo "--- process CPU affinity ---"
        taskset -pc "$PID" || true

        echo "--- process NUMA memory ---"
        numastat -p "$PID" || true

        echo "--- per-node free memory ---"
        numastat -m |
            grep -E 'Node|MemFree|MemUsed|Active|Inactive|FilePages|AnonPages' ||
            true

        sleep "$INTERVAL"
    done
) > "$OUT/timeline.log"

numastat -m > "$OUT/system_memory.after"
numastat > "$OUT/system_numa.after"
cp /proc/"$PID"/numa_maps "$OUT/numa_maps.final" 2>/dev/null || true

echo "Saved to $OUT"
```

运行：

```bash
./05_numa_watch.sh <PID> 300 5
```

## 判断

假设：

```text
gem5 running CPU：NUMA node 0
memory：
Node 0 = 2 GB
Node 1 = 14 GB
```

那么它的大部分内存在远端 node。

但要注意：

> 对论文所测的 gem5 workload，热数据多数能够进入 LLC，因此远端 DRAM 不一定是首要瓶颈。

NUMA 更可疑的场景是：

- 某个 node 的 `MemFree` 已接近0；
- job 在频繁分配内存；
- major/minor faults 很高；
- CPU 在 socket 间迁移；
- `numa_miss`、`numa_foreign` 持续增加。

---

# 九、实验 6：NUMA policy A/B 测试

保存为 `06_run_numa_ab.sh`：

```bash
#!/usr/bin/env bash
set -eu

CPU_LIST=${1:?Usage: $0 CPU_LIST NODE OUTDIR -- command ...}
NODE=${2:?}
OUT=${3:?}
shift 3

if [[ "${1:-}" == "--" ]]; then
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "Missing command"
    exit 1
fi

mkdir -p "$OUT/local" "$OUT/interleave"

echo "===== LOCAL NODE TEST ====="

(
    cd "$OUT/local"
    /usr/bin/time -v \
        numactl \
        --physcpubind="$CPU_LIST" \
        --membind="$NODE" \
        "$@"
) > "$OUT/local/stdout.log" 2> "$OUT/local/time.log"

echo "===== INTERLEAVE TEST ====="

(
    cd "$OUT/interleave"
    /usr/bin/time -v \
        numactl \
        --physcpubind="$CPU_LIST" \
        --interleave=all \
        "$@"
) > "$OUT/interleave/stdout.log" 2> "$OUT/interleave/time.log"

grep -H \
    'Elapsed (wall clock) time\|Percent of CPU this job got\|Maximum resident' \
    "$OUT"/*/*.log || true
```

例如：

```bash
./06_run_numa_ab.sh 20 0 numa_test -- \
    /path/gem5.opt --outdir=m5out config.py ...
```

需要确保两个运行使用独立输出目录，否则第二次会覆盖第一次结果。实际使用时最好把完整命令包装在两个独立 shell script 中。

## 解释

- `membind` 明显快：原始运行可能远端分配严重；
- `interleave` 明显快：原始 node 可能存在局部容量或带宽压力；
- 区别很小：NUMA 不是主要原因；
- `membind` 失败：该 node 没有足够内存，反而证明需要改善调度和 node 内存预留。

生产环境更适合使用 `localprefer`，而不是直接使用可能分配失败的严格 `localonly`。LSF affinity 可以同时指定 CPU binding 和 memory binding。([ibm.com](https://www.ibm.com/docs/en/spectrum-lsf/10.1.0?topic=strings-affinity-string&utm_source=openai))

---

# 十、实验 7：验证 LLC 和 DRAM bandwidth

根据论文，**单个 gem5 的 DRAM bandwidth 很低**，所以该实验的目标不是预设“带宽一定饱和”，而是回答：

> 230 个 gem5 导致 LLC 被冲刷后，是否把原本 LLC-resident 的访问推向 DRAM？

Intel PCM 可以观察：

- IPC；
- CPU frequency；
- cache miss；
- LLC occupancy；
- per-channel DRAM bandwidth；
- local/remote memory access。([github.com](https://github.com/intel/pcm?utm_source=openai))

## PCM 脚本

保存为 `07_pcm_collect.sh`：

```bash
#!/usr/bin/env bash
set -eu

MODE=${1:?Usage: $0 MODE [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-pcm_${MODE}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

case "$MODE" in
    basic)
        TOOL=pcm
        ;;
    memory)
        TOOL=pcm-memory
        ;;
    numa)
        TOOL=pcm-numa
        ;;
    power)
        TOOL=pcm-power
        ;;
    *)
        echo "MODE must be: basic, memory, numa, power"
        exit 1
        ;;
esac

if ! command -v "$TOOL" >/dev/null; then
    echo "$TOOL is not installed"
    exit 1
fi

echo "Running $TOOL for ${SECONDS}s"

sudo timeout "$SECONDS" "$TOOL" 1 \
    > "$OUT/${TOOL}.log" 2>&1 || true

echo "Saved to $OUT/${TOOL}.log"
```

分别运行：

```bash
./07_pcm_collect.sh basic 300 pcm_low_basic
./07_pcm_collect.sh memory 300 pcm_low_memory
./07_pcm_collect.sh numa 300 pcm_low_numa
```

在230个 job 时重复：

```bash
./07_pcm_collect.sh basic 300 pcm_high_basic
./07_pcm_collect.sh memory 300 pcm_high_memory
./07_pcm_collect.sh numa 300 pcm_high_numa
```

不要同时运行多个 PCM/perf 测量，因为它们可能争抢相同 PMU counters。

## 判断

### 情况 A：论文特征仍然成立

```text
DRAM bandwidth仍然很低
IPC下降
LLC miss增加
```

这说明重点是：

- iCache/TLB/front-end；
- LLC capacity/cache interference；
- SMT；
- CPU frequency。

### 情况 B：高并发后发生变化

```text
单进程时DRAM bandwidth很低
230进程时DRAM bandwidth接近平台上限
LLC miss显著增加
```

这表明：

```text
原本在LLC中的热数据
    ↓ 多进程相互驱逐
大量访问落到DRAM
    ↓
带宽和延迟成为二级瓶颈
```

### 情况 C：远端访问很高

```text
remote memory显著增加
local memory比例下降
```

说明 NUMA affinity 需要调整。

---

# 十一、实验 8：检查 CPU 全核降频

论文显示 gem5 simulation time 和 CPU frequency 基本接近线性关系。全核运行230个进程时，Turbo 频率通常会低于单核运行时。

`turbostat` 的 `Bzy_MHz` 可用于观察 CPU 在 busy 状态下的实际平均频率。([docs.kernel.org](https://docs.kernel.org/next/admin-guide/pm/intel-speed-select.html?utm_source=openai))

保存为 `08_frequency_watch.sh`：

```bash
#!/usr/bin/env bash
set -eu

CPU_LIST=${1:-0-$(($(nproc)-1))}
SECONDS=${2:-120}
OUT=${3:-frequency_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

if command -v turbostat >/dev/null; then
    sudo timeout "$SECONDS" \
        turbostat \
        --quiet \
        -c "$CPU_LIST" \
        --show Package,Core,CPU,Busy%,Bzy_MHz \
        -i 1 \
        > "$OUT/turbostat.log" 2>&1 || true
else
    echo "turbostat not installed" > "$OUT/turbostat.log"
fi

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        for cpu in ${CPU_LIST//,/ }; do
            f="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq"
            [[ -r "$f" ]] && echo "cpu${cpu} $(cat "$f") kHz"
        done

        sleep 1
    done
) > "$OUT/cpufreq_sysfs.log"

echo "Saved to $OUT"
```

例如：

```bash
./08_frequency_watch.sh 20,21,22,23 300
```

## 判断

假设：

```text
低并发 Bzy_MHz = 3900
高并发 Bzy_MHz = 2100
```

理论上仅频率因素大约造成：

```text
3900 / 2100 ≈ 1.86倍
```

因此频率可以解释一部分，但不能单独解释10倍。

如果观察到非常低的频率，还要检查：

- CPU thermal throttling；
- package power limit；
- BIOS power profile；
- CPU governor；
- Intel SST 配置；
- 机房散热。

---

# 十二、实验 9：检查共享存储 I/O

保存为 `09_io_watch.sh`：

```bash
#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [SECONDS] [OUTDIR]}
SECONDS=${2:-120}
OUT=${3:-io_${PID}_$(date +%Y%m%d_%H%M%S)}

mkdir -p "$OUT"

timeout "$SECONDS" iostat -xz 1 \
    > "$OUT/iostat.log" 2>&1 &

timeout "$SECONDS" pidstat -h -p "$PID" -d 1 \
    > "$OUT/pidstat_io.log" 2>&1 &

(
    end=$(( $(date +%s) + SECONDS ))

    while (( $(date +%s) < end )); do
        echo "===== $(date -Is) ====="

        cat /proc/pressure/io 2>/dev/null || true

        ps -o pid,stat,psr,pcpu,wchan:40,etime,cmd \
            -p "$PID"

        sleep 1
    done
) > "$OUT/io_psi_process.log" &

wait || true

echo "Saved to $OUT"
```

运行：

```bash
./09_io_watch.sh <PID> 300
```

## 判断

如果看到：

```text
进程状态 D
wchan 指向 filemap/nfs/io_schedule
I/O PSI显著升高
await很高
磁盘%util接近100%
```

说明是 I/O 问题。

重点区分两个阶段：

1. **启动阶段**
   - 读取 checkpoint；
   - 读取 disk image；
   - 230个进程同时启动。

2. **steady-state simulation**
   - 通常更接近 CPU/front-end bound；
   - 除非持续输出 trace。

如果只在启动或 stats dump 时慢，不应把它归因于 gem5 核心执行。

---

# 十三、实验 10：比较 gem5 自己的速度

保存为 `10_compare_gem5_stats.py`：

```python
#!/usr/bin/env python3

import sys
import csv
from pathlib import Path

KEYS = [
    "hostSeconds",
    "hostInstRate",
    "hostTickRate",
    "simInsts",
    "simTicks",
]

def parse_stats(path):
    values = {}

    with open(path, "r", errors="replace") as f:
        for line in f:
            fields = line.split()

            if len(fields) < 2:
                continue

            key = fields[0]

            if key not in KEYS:
                continue

            try:
                values[key] = float(fields[1])
            except ValueError:
                pass

    return values

def main():
    if len(sys.argv) < 3:
        print(
            "Usage: compare_gem5_stats.py "
            "baseline=stats.txt highload=stats.txt [...]",
            file=sys.stderr,
        )
        sys.exit(1)

    rows = []

    for item in sys.argv[1:]:
        if "=" not in item:
            raise SystemExit(f"Invalid argument: {item}")

        label, path = item.split("=", 1)
        values = parse_stats(path)
        values["label"] = label
        values["path"] = str(Path(path))
        rows.append(values)

    base_inst_rate = rows[0].get("hostInstRate")
    base_tick_rate = rows[0].get("hostTickRate")

    writer = csv.writer(sys.stdout)

    writer.writerow([
        "label",
        "hostSeconds",
        "hostInstRate",
        "hostInstRate_vs_baseline",
        "hostTickRate",
        "hostTickRate_vs_baseline",
        "simInsts",
        "simTicks",
        "path",
    ])

    for row in rows:
        inst_rate = row.get("hostInstRate")
        tick_rate = row.get("hostTickRate")

        inst_ratio = (
            inst_rate / base_inst_rate
            if inst_rate is not None and base_inst_rate
            else ""
        )

        tick_ratio = (
            tick_rate / base_tick_rate
            if tick_rate is not None and base_tick_rate
            else ""
        )

        writer.writerow([
            row["label"],
            row.get("hostSeconds", ""),
            inst_rate if inst_rate is not None else "",
            inst_ratio,
            tick_rate if tick_rate is not None else "",
            tick_ratio,
            row.get("simInsts", ""),
            row.get("simTicks", ""),
            row["path"],
        ])

if __name__ == "__main__":
    main()
```

运行：

```bash
chmod +x 10_compare_gem5_stats.py

./10_compare_gem5_stats.py \
    low_load=/results/low/m5out/stats.txt \
    high_load=/results/high/m5out/stats.txt |
column -s, -t
```

如果：

```text
low_load hostInstRate  = 1,000,000
high_load hostInstRate =   100,000
```

则确认 gem5 本身的 host-side simulation throughput 下降10倍。

还要确认：

```text
simInsts基本一致
simTicks基本一致
```

否则可能比较了不同模拟阶段。

---

# 十四、实验 11：验证 THP 和 huge page

这篇论文发现 huge page 减少了 iTLB overhead，但实际 simulation speedup 最高大约只有 **5.9%**。

因此：

> huge page 是优化项，不是解释10倍下降的首要原因。

而且论文不是简单依赖系统默认 THP，它使用额外机制把 gem5 code/text remap 到 huge pages。普通 THP 主要针对 anonymous memory 和 tmpfs/shmem，不应假设开启 THP 就会自动让 gem5 的文件映射代码段使用 huge pages。([docs.kernel.org](https://docs.kernel.org/admin-guide/mm/transhuge.html?utm_source=openai))

## 检查进程实际 page size

保存为 `11_hugepage_check.sh`：

```bash
#!/usr/bin/env bash
set -eu

PID=${1:?Usage: $0 PID [OUTFILE]}
OUT=${2:-hugepage_${PID}_$(date +%Y%m%d_%H%M%S).log}

{
    echo "===== THP SETTINGS ====="

    for f in \
        /sys/kernel/mm/transparent_hugepage/enabled \
        /sys/kernel/mm/transparent_hugepage/defrag; do
        [[ -r "$f" ]] && echo "$f: $(cat "$f")"
    done

    echo
    echo "===== PROCESS SUMMARY ====="
    grep -E \
    'Rss|Pss|AnonHugePages|FilePmdMapped|Shared_Hugetlb|Private_Hugetlb' \
    /proc/"$PID"/smaps_rollup 2>/dev/null || true

    echo
    echo "===== PAGE SIZE DISTRIBUTION ====="

    awk '
    /^KernelPageSize:/ {
        kernel[$2 " " $3]++
    }

    /^MMUPageSize:/ {
        mmu[$2 " " $3]++
    }

    END {
        print "KernelPageSize:"
        for (k in kernel)
            print k, kernel[k]

        print "MMUPageSize:"
        for (k in mmu)
            print k, mmu[k]
    }
    ' /proc/"$PID"/smaps

    echo
    echo "===== VMSTAT THP/COMPACTION ====="
    grep -E \
    'thp_|compact_|allocstall|pgscan_direct' \
    /proc/vmstat

} | tee "$OUT"
```

运行：

```bash
./11_hugepage_check.sh <PID>
```

不要为了验证而直接在生产服务器全局执行：

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

应该先进行隔离的 A/B 测试，并观察：

```text
iTLB miss
compact_stall
hostInstRate
```

---

# 十五、实验 12：检查 LSF 请求值和实际使用值

LSF 的：

```text
rusage[mem=...]
```

是调度资源 reservation，而：

```text
-M
```

属于运行时 memory limit。`-M` 的单位和 enforcement 行为取决于 `LSF_UNIT_FOR_LIMITS`、`LSB_MEMLIMIT_ENFORCE` 和 `LSB_JOB_MEMLIMIT` 等配置。([ibm.com](https://www.ibm.com/docs/en/spectrum-lsf/10.1.0?topic=syntax-memory-limit&utm_source=openai))

## 审计脚本

保存为 `12_lsf_audit.sh`：

```bash
#!/usr/bin/env bash
set -u

OUT=${1:-lsf_audit_$(date +%Y%m%d_%H%M%S)}
shift || true

mkdir -p "$OUT"

echo "===== LSF HOST INFO =====" > "$OUT/summary.txt"
hostname >> "$OUT/summary.txt"

if command -v bhosts >/dev/null; then
    bhosts -l "$(hostname)" > "$OUT/bhosts.log" 2>&1 || true
fi

if command -v lsload >/dev/null; then
    lsload -l "$(hostname)" > "$OUT/lsload.log" 2>&1 || true
fi

if [[ $# -eq 0 ]]; then
    echo "No job IDs supplied."
    echo "Usage: $0 OUTDIR JOBID1 JOBID2 ..."
    exit 0
fi

for JOBID in "$@"; do
    bjobs -l "$JOBID" \
        > "$OUT/bjobs_${JOBID}.log" 2>&1 || true

    bacct -l "$JOBID" \
        > "$OUT/bacct_${JOBID}.log" 2>&1 || true
done

grep -RniE \
'MAX MEM|AVG MEM|MEMLIMIT|Requested Resources|rusage|CPU time|RUNLIMIT|Execution' \
"$OUT" > "$OUT/extracted.txt" || true

cat "$OUT/extracted.txt"
```

运行：

```bash
./12_lsf_audit.sh lsf_result 12345 12346 12347
```

重点寻找：

```text
MAX MEM > requested memory
```

如果大量 job 都低估内存需求，那么“总 request 不超过80%”不能代表实际物理内存只使用80%。

## LSF 提交模板

单线程 gem5 可以参考：

```bash
bsub \
  -n 1 \
  -R "span[hosts=1]" \
  -R "rusage[mem=16000]" \
  -R "affinity[core(1):cpubind=core:membind=localprefer]" \
  -M 20000 \
  -J gem5_job \
  ./run_gem5.sh
```

其中：

```text
-n 1
```

表示申请一个 slot，但还要确认集群的 slot 是否配置为 physical core，不能默认认为一个 slot 就一定是独占物理核。

LSF affinity 语法支持 `cpubind=core` 和 `membind=localprefer/localonly`，但具体可用性取决于版本和集群配置。([ibm.com](https://www.ibm.com/docs/en/spectrum-lsf/10.1.0?topic=strings-affinity-string&utm_source=openai))

---

# 十六、如何把实验结果归因

最终可以使用下面的判断表。

| 观测 | 主要原因 |
|---|---|
| `%CPU` 从100%降到10% | CPU调度竞争，可以直接解释约10倍 |
| `%CPU` 接近100%，IPC下降很多 | cache/front-end contention |
| SMT sibling繁忙后慢1.5～2倍 | SMT/L1/前端竞争 |
| cache/LLC miss高，DRAM带宽仍低 | cache容量和前端问题 |
| LLC miss和DRAM带宽同时上升 | LLC冲刷后转化成DRAM瓶颈 |
| `pswpin/out` 增长 | swap |
| `pgscan_direct`、`allocstall` 增长 | direct reclaim |
| memory PSI `full` 明显非零 | 严重内存thrashing |
| CPU频率由4GHz降至2GHz | 可以解释约2倍 |
| CPU与内存位于不同NUMA node | 远端访问 |
| 某NUMA node `MemFree≈0` | 局部node内存压力 |
| I/O PSI高、进程为D状态 | I/O阻塞 |
| iTLB/iCache miss高但高低负载相似 | gem5固有瓶颈，不是10倍差异的直接原因 |
| THP A/B只有几个百分点 | 符合论文，不是主要根因 |
| `simInsts/simTicks`不同 | 比较了不同simulation phase |

---

# 十七、推荐的实际执行顺序

不要一开始就全部运行。建议按下面顺序，通常两三轮就能定位。

## 第一轮：确认是否只是 CPU 时间不足

```bash
./00_inventory.sh
./01_collect_pid.sh <PID> 300
```

查看：

```text
pidstat %CPU
vmstat r
CPU PSI
```

如果 job 只有约10% CPU，不需要先研究 THP 或 DRAM bandwidth。

## 第二轮：检查10倍下降的系统性原因

```bash
./04_memory_pressure.sh <PID> 300
./09_io_watch.sh <PID> 300
```

检查：

```text
swap
direct reclaim
major fault
memory PSI
I/O PSI
```

## 第三轮：验证论文描述的 gem5 特征

```bash
./03_perf_gem5.sh <PID> 300
./08_frequency_watch.sh <CPU_LIST> 300
```

比较低、高负载时：

```text
IPC
iTLB miss
iCache miss
cache miss
branch miss
Bzy_MHz
```

## 第四轮：大型服务器特有问题

```bash
./05_numa_watch.sh <PID> 300
./07_pcm_collect.sh memory 300
./07_pcm_collect.sh numa 300
```

## 第五轮：受控 A/B

```bash
./02_smt_ab_test.sh ...
./06_run_numa_ab.sh ...
./10_compare_gem5_stats.py ...
```

---

## 最终判断

结合论文，我会把目前最可能的情况描述为：

> 80% memory usage 不是直接原因，而是“230个 gem5 同时运行”的代理指标。gem5 本身是单线程、instruction front-end sensitive 的程序。高并发使其受到 CPU slot/SMT、共享 cache、iCache/iTLB、全核降频的综合影响。论文支持这些因素会造成显著减速，但单靠其中一个通常不足以稳定慢10倍。因此应优先检查单 job 是否仍获得接近100% CPU，以及是否存在 swap、direct reclaim 或 memory PSI full。

其中最关键的三项证据是：

```text
1. 高负载时单个gem5的%CPU
2. 高负载与低负载时的IPC和hostInstRate
3. pswpin/out、pgscan_direct、memory PSI
```

如果结果是：

```text
%CPU≈100%
没有swap/reclaim
IPC下降5～10倍
```

那么论文所描述的 **front-end/cache contention** 就是主要方向。

如果结果是：

```text
%CPU≈10%
```

根本原因首先是 **LSF/OS CPU oversubscription 或 affinity**。

如果结果是：

```text
memory PSI full明显非零
pgscan_direct/pswpin快速增长
```

根本原因首先是 **实际内存压力和页面抖动**，而不是 gem5 固有的微架构特征。
