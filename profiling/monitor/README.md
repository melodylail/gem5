# Memory Monitor Daemon

后台常驻 daemon，持续周期性采集系统内存全景数据：

- **进程级**：所有进程（含内核线程）的 RSS/PSS/USS/VmSwap/cmdline
- **系统级**：/proc/meminfo + /proc/vmstat + PSI 指标
- **kswapd**：kswapd 线程状态、CPU、wchan、stack trace

提供 Bash 和 Python 两个独立实现，共享同一套输出规范。

## 快速开始

```bash
# Bash daemon（零依赖）
./profiling/monitor/mem_daemon.sh --interval 5 --mode standard

# Python daemon（需要 psutil）
./profiling/monitor/mem_daemon.py --interval 5 --mode standard
```

详见 design spec 和 implementation plan。
