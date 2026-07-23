# gem5 + 自编译 TCMalloc 集成方案

> 讨论日期：2025-07-15
> 涉及项目：gem5 (`/home/luq/Dev/opensource/gem5`)、google/tcmalloc (`/home/luq/Dev/opensource/tcmalloc`)
> 状态：**方案设计完成，尚未实现**

---

## 1. 背景

gem5 默认使用系统安装的 gperftools（`libgoogle-perftools-dev`）提供的 tcmalloc 来加速内存分配（官方称约 12% 性能提升）。目标是将 gem5 的 tcmalloc 依赖替换为从源码（google/tcmalloc）用 Bazel 编译的版本，以获得最新的分配器优化。

## 2. gem5 现有的 tcmalloc 集成方式

### 2.1 SConstruct 中的检测逻辑

gem5 的 `SConstruct` 第 889-898 行：

```python
if not GetOption('without_tcmalloc'):
    with gem5_scons.Configure(env) as conf:
        if conf.CheckLib('tcmalloc_minimal'):       # 尝试 -ltcmalloc_minimal
            conf.env.Append(CCFLAGS=conf.env['TCMALLOC_CCFLAGS'])
        elif conf.CheckLib('tcmalloc'):              # 回退 -ltcmalloc
            conf.env.Append(CCFLAGS=conf.env['TCMALLOC_CCFLAGS'])
        else:
            warning("You can get a 12% performance improvement by "
                    "installing tcmalloc (libgoogle-perftools-dev package "
                    "on Ubuntu or RedHat).")
```

`CheckLib('tcmalloc_minimal')` 等价于在链接命令中添加 `-ltcmalloc_minimal`，在系统库路径（`/usr/lib/x86_64-linux-gnu/`）查找 `libtcmalloc_minimal.so`。

### 2.2 编译器标志

检测到 tcmalloc 后，gem5 会添加 `TCMALLOC_CCFLAGS`（第 459-762 行）：

```python
# GCC:
TCMALLOC_CCFLAGS = [
    '-fno-builtin-malloc', '-fno-builtin-calloc',
    '-fno-builtin-realloc', '-fno-builtin-free'
]

# Clang:
TCMALLOC_CCFLAGS = ['-fno-builtin']
```

这些标志告诉编译器不要内联 glibc 的 malloc/free，从而让 tcmalloc 的符号覆盖生效。

### 2.3 gem5 源码中的 tcmalloc 使用

gem5 **不直接调用** tcmalloc 的任何 API（如 `MallocExtension`、`MallocHook` 等）。它完全依赖链接期的符号覆盖：tcmalloc 定义了全局 `malloc`/`free`/`calloc`/`realloc` 符号，覆盖 glibc 的实现。

验证：
```bash
grep -rn "tcmalloc\|MallocExtension\|malloc_hook" src/ --include="*.cc" --include="*.hh"
# 结果：空（无直接引用）
```

### 2.4 当前系统安装

```bash
$ dpkg -l libgoogle-perftools-dev
ii  libgoogle-perftools-dev  2.15-3build1  amd64

$ ls /usr/lib/x86_64-linux-gnu/libtcmalloc*
libtcmalloc.a                    # 静态库
libtcmalloc.so -> libtcmalloc.so.4.5.16
libtcmalloc_minimal.a            # 静态库（最小化版）
libtcmalloc_minimal.so -> libtcmalloc_minimal.so.4.5.16
```

## 3. 两个不同的 TCMalloc 项目

这是整个集成中最关键的认知——**系统包和 Bazel 源码是两个不同的项目**：

| 维度 | 系统 gperftools | Bazel google/tcmalloc |
|------|----------------|----------------------|
| **仓库** | [gperftools/gperftools](https://github.com/gperftools/gperftools) | [google/tcmalloc](https://github.com/google/tcmalloc) |
| **版本** | 2.15 (2024) | HEAD (2026) |
| **安装方式** | `apt install libgoogle-perftools-dev` | `bazel build //tcmalloc:tcmalloc` |
| **产物格式** | `.so` (动态) + `.a` (静态) | `.lo` (仅静态 archive，`linkstatic=1`) |
| **库名** | `-ltcmalloc_minimal` / `-ltcmalloc` | 无标准库名（Bazel 内部 label） |
| **动态库** | ✅ 有 `libtcmalloc_minimal.so.4` | ❌ 无 `.so` |
| **符号覆盖** | 动态链接时由 `ld.so` 自动覆盖 | 需要 `alwayslink=1` + `--whole-archive` |
| **导出符号数** | 342 个 (`nm -D` 统计) | 201 个 (`nm` 统计) |
| **大页支持** | 基础 | 256K pages 变体 (`//tcmalloc:tcmalloc_256k_pages`) |

## 4. Bazel tcmalloc 的构建产物分析

### 4.1 构建命令

```bash
cd /home/luq/Dev/opensource/tcmalloc
bazel build //tcmalloc:tcmalloc  # 核心
bazel build //tcmalloc:malloc_extension  # 扩展接口（.a + .so）
```

### 4.2 产物

```bash
$ ls bazel-bin/tcmalloc/
libtcmalloc.lo          # 5.2 MB，静态 archive (ar)，包含 tcmalloc.pic.o
libmalloc_extension.a   # 168 KB，静态库（扩展 API）
libmalloc_extension.so  # 132 KB，动态库（扩展 API）
```

### 4.3 关键构建标志

```python
# tcmalloc/BUILD
cc_library(
    name = "tcmalloc",
    linkstatic = 1,      # 只产生 .a/.lo，不产生 .so
    alwayslink = 1,      # 强制链接器包含所有 .o（即使看似未引用）
)
```

- **`linkstatic = 1`**：Bazel 只生成静态库，不生成动态库
- **`alwayslink = 1`**：这是 tcmalloc 工作的关键。tcmalloc 通过定义全局 `malloc`/`free` 符号覆盖 glibc，但这些符号在 gem5 代码中没有显式引用，普通链接器会丢弃它们。`alwayslink` 确保所有 `.o` 被强制链入。

### 4.4 archive 内容

```bash
$ ar t libtcmalloc.lo
tcmalloc.pic.o    # 单个 PIC 目标文件
```

### 4.5 导出的 malloc 符号

```bash
$ nm libtcmalloc.lo | grep -E " T (malloc|free|calloc|realloc)"
0000000000000000 T malloc
0000000000000a40 T free
0000000000007980 T calloc
                   # 注意：realloc 不是独立符号，而是通过 malloc + free 实现
```

## 5. 集成方案

### 5.1 方案 A：安装为系统库（简单但有坑）

```bash
# 编译
cd tcmalloc && bazel build //tcmalloc:tcmalloc

# 安装到系统路径
sudo cp bazel-bin/tcmalloc/libtcmalloc.lo /usr/local/lib/libtcmalloc_custom.a
sudo ln -sf libtcmalloc_custom.a /usr/local/lib/libtcmalloc_minimal.a

# gem5 不改代码，正常 scons build
scons build/ALL/gem5.opt
```

**问题**：
- SCons 的 `CheckLib('tcmalloc_minimal')` 默认检测动态库（`.so`），静态库（`.a`）可能检测不到
- `alwayslink` 语义丢失：普通 `-ltcmalloc_minimal` 不会用 `--whole-archive`，tcmalloc 的符号覆盖可能不生效
- 污染系统路径

### 5.2 方案 B（推荐）：修改 SConstruct 添加自定义路径

在 `SConstruct` 中添加 `--tcmalloc-dir` 选项。

> **核心设计决策：用 `ld -r` 合并的完整 `.o` 文件，彻底绕过 `--whole-archive`**
>
> **为什么不能直接用 `libtcmalloc.lo` 中的单个 `tcmalloc.pic.o`？**
>
> `libtcmalloc.lo` 只包含 `tcmalloc.cc` 编译出的**单个** `.o`（4.6 MB）。
> 它引用了 131 个 `tcmalloc_internal` 符号（如 `Span::New`）和 466 个 `absl` 符号，
> 但这些定义在其他 38 个 `.o` 文件和 absl 库中。
>
> Bazel 的 `alwayslink = 1` 机制是在**最终二进制链接时**把所有依赖 `.o` 平铺到
> 链接命令行（而非打包进 `.lo`）。脱离 Bazel 环境后，需要手动收集所有 `.o` 并合并。
>
> **解法**：用 `ld -r`（relocatable link）把 167 个 `.o` 合并为一个完整的
> `tcmalloc_merged.o`（13 MB），包含 tcmalloc + absl 的全部实现。

#### 5.2.1 准备阶段：生成合并的 .o 文件

```bash
cd /home/luq/Dev/opensource/tcmalloc
export USE_BAZEL_VERSION=8.4.2
bazelisk build //tcmalloc:tcmalloc

# 创建一个测试 binary 来捕获完整的 .o 文件列表
mkdir -p /tmp/gen_merged
cd /tmp/gen_merged
echo 'int main() { return 0; }' > main.cc
cat > MODULE.bazel << 'EOF'
module(name = "gen_merged", version = "0")
bazel_dep(name = "tcmalloc", version = "0", repo_name = "com_google_tcmalloc")
local_path_override(module_name = "tcmalloc", path = "/home/luq/Dev/opensource/tcmalloc")
EOF
cat > BUILD << 'EOF'
cc_binary(name = "gen", srcs = ["main.cc"], linkstatic = 1,
          deps = ["@com_google_tcmalloc//tcmalloc:tcmalloc"])
EOF

bazelisk build //:gen
EXEC_ROOT=$(bazelisk info execution_root | tail -1)
PARAMS=$(find "$(bazelisk info bazel-bin | tail -1)" -name "gen-0.params")

# 提取所有 tcmalloc + absl 的 .o 文件路径（排除 main.o）
grep '\.pic\.o$' "$PARAMS" | grep -v "gen/main" > obj_list.txt

# 用 ld -r 合并为单个 .o
cd "$EXEC_ROOT"
ld -r -o ~/libs/tcmalloc/tcmalloc_merged.o $(cat /tmp/gen_merged/obj_list.txt)

ls -lh ~/libs/tcmalloc/tcmalloc_merged.o
# tcmalloc_merged.o   13M   完整的 tcmalloc + absl 实现
```

#### 5.2.2 验证合并的 .o

```bash
# 检查关键符号
nm ~/libs/tcmalloc/tcmalloc_merged.o | grep -w malloc      # 应有 T malloc
nm ~/libs/tcmalloc/tcmalloc_merged.o | grep "Span.*New"    # 应有 T ...Span...New
nm --undefined-only ~/libs/tcmalloc/tcmalloc_merged.o | grep "tcmalloc"  # 应仅剩 weak (w)
```

预期：1463 个 T 符号，`malloc`/`free`/`calloc` 全部定义，
仅剩 ~10 个 weak 符号未定义（正常行为）。

#### 5.2.3 SConstruct 修改

```python
# === 在 AddOption 区域（约第 133 行）添加 ===
AddOption('--tcmalloc-dir', action='store', default=None,
          help='Path to directory containing tcmalloc_merged.o')

# === 替换第 889-898 行的 tcmalloc 检测逻辑 ===
if not GetOption('without_tcmalloc'):
    tcmalloc_dir = GetOption('tcmalloc_dir')
    if tcmalloc_dir:
        # 使用自定义编译的 tcmalloc
        env.Append(CCFLAGS=env['TCMALLOC_CCFLAGS'])

        # tcmalloc_merged.o 是用 ld -r 合并的完整 tcmalloc + absl 实现。
        # 作为 .o 传给链接器，所有符号无条件全量链入，
        # 不需要 --whole-archive，兼容 bfd/gold/lld/mold。
        tcmalloc_o = os.path.join(tcmalloc_dir, 'tcmalloc_merged.o')
        if os.path.exists(tcmalloc_o):
            env.Append(LINKFLAGS=[tcmalloc_o])
        else:
            error(f'tcmalloc_merged.o not found at {tcmalloc_o}')
    else:
        # 回退到原来的系统 tcmalloc 检测
        with gem5_scons.Configure(env) as conf:
            if conf.CheckLib('tcmalloc_minimal'):
                conf.env.Append(CCFLAGS=conf.env['TCMALLOC_CCFLAGS'])
            elif conf.CheckLib('tcmalloc'):
                conf.env.Append(CCFLAGS=conf.env['TCMALLOC_CCFLAGS'])
            else:
                warning("You can get a 12% performance improvement by "
                        "installing tcmalloc (libgoogle-perftools-dev package "
                        "on Ubuntu or RedHat).")
```

#### 5.2.4 构建 gem5

```bash
scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc
```

#### 5.2.5 为什么需要合并 167 个 .o

| 层次 | 内容 | 单独使用 |
|------|------|----------|
| `tcmalloc.pic.o` | 仅 `tcmalloc.cc`（4.6 MB） | ❌ 缺少 Span::New 等 131 个符号 |
| `_objs/` 下 39 个 `.o` | tcmalloc 全部源文件（16 MB） | ❌ 缺少 466 个 absl 符号 |
| **`tcmalloc_merged.o`** | **tcmalloc + absl 全部（13 MB）** | **✅ 自包含，无外部依赖** |

`.o` 文件在链接命令行上等同于源文件，所有符号无条件链入，不需要任何
`--whole-archive`，兼容所有链接器。

#### 5.2.6 离线环境操作

```bash
# 从离线包构建 tcmalloc
cd tcmalloc-offline-8.4.2/project
bazel build --config=offline //tcmalloc:tcmalloc

# 创建临时 Bazel workspace 来收集所有 .o（同 5.2.1）
# ...（略，步骤相同，但用 --config=offline）

# 生成 tcmalloc_merged.o 后，复制到 ~/libs/tcmalloc/
# 然后构建 gem5
cd /path/to/gem5
scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc
```

### 5.3 方案 C：LD_PRELOAD 运行时覆盖（零修改）

```bash
# 先把 libtcmalloc.lo 转成 .so
ar x libtcmalloc.lo
gcc -shared -o libtcmalloc_custom.so tcmalloc.pic.o -lpthread

# 运行 gem5 时用 LD_PRELOAD
LD_PRELOAD=/path/to/libtcmalloc_custom.so ./build/ALL/gem5.opt ...
```

**问题**：
- 需要额外步骤将 `.lo` 转为 `.so`
- 编译时的 `-fno-builtin-malloc` 标志不会生效（gem5 仍然用 glibc 内联 malloc）
- 性能不如编译期链接

## 6. 需要考虑的关键事项

### 6.1 alwayslink / --whole-archive / mold 兼容性 / 依赖完整性

这是最关键的技术难点，包含两个层面：

**层面 1：符号覆盖（alwayslink 语义）**

tcmalloc 通过定义全局 `malloc`/`free` 符号覆盖 glibc。但这些符号在 gem5 代码中没有
显式引用。链接器对 `.o` vs `.a` 的处理不同：

```
.o（目标文件）           .a（archive 静态库）
    │                        │
    ▼                        ▼
 所有符号无条件链入         扫描未定义符号表
 不管是否被引用              只拉入能解析未定义符号的 .o
                            丢弃 "没被引用" 的 .o
```

Bazel 用 `alwayslink = 1` + `--whole-archive` 解决。但 mold 链接器对 SCons LINKFLAGS
中的 `--whole-archive` 有兼容性问题。

**层面 2：依赖完整性（.lo 只是冰山一角）**

`libtcmalloc.lo` 仅包含 `tcmalloc.cc` 的 `.o`（4.6 MB），但它引用了：
- 131 个 `tcmalloc_internal` 符号（`Span::New` 等，定义在其他 38 个 `.o` 中）
- 466 个 `absl` 符号（定义在 abseil-cpp 的 128 个 `.o` 中）

Bazel 在最终链接时把所有 167 个 `.o` 平铺到命令行。脱离 Bazel 后必须手动收集。

**最终解法（方案 B 采用）**：

```bash
# 用 ld -r 把 167 个 .o 合并为单个自包含的 .o
ld -r -o tcmalloc_merged.o <所有 .o 文件>
```

`tcmalloc_merged.o`（13 MB）包含 tcmalloc + absl 的完整实现，1463 个代码符号，
作为单个 `.o` 传递给链接器，不需要 `--whole-archive`，兼容所有链接器。

### 6.2 编译器标志

无论用哪种方案，**必须** 在编译 gem5 源码时传递 `TCMALLOC_CCFLAGS`：

```bash
# GCC:
-fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free

# Clang:
-fno-builtin
```

没有这些标志，编译器会内联 glibc 的 malloc 调用，tcmalloc 的符号覆盖无法拦截。

gem5 的 SConstruct 已经在检测到 tcmalloc 时自动添加这些标志，方案 B 中也保留了此逻辑。

### 6.3 符号冲突

如果系统同时安装了 `libgoogle-perftools-dev` 且使用了 `--tcmalloc-dir`，可能出现符号冲突（两套 malloc 实现）。确保：

```bash
# 方案 B 构建时不要同时链接系统 tcmalloc
# SCons 的 CheckLib 不会被触发（因为走了 --tcmalloc-dir 分支）
```

### 6.4 gem5 不使用 tcmalloc 的高级 API

gem5 不调用 `MallocExtension::SetNumericProperty()`、`MallocHook` 等 API。它只用基础的 malloc/free/calloc/realloc 符号覆盖。这意味着：

- 不需要链接 `libmalloc_extension.a`
- 不需要 `malloc_hook` 库
- 只需要核心的 `libtcmalloc.lo`

### 6.5 性能变体选择

Bazel tcmalloc 提供多个编译变体：

| 目标 | 特性 | 适用场景 |
|------|------|----------|
| `//tcmalloc:tcmalloc` | 默认（8K pages） | 通用 |
| `//tcmalloc:tcmalloc_256k_pages` | 256K 大页 | 内核支持 transparent hugepages |
| `//tcmalloc:tcmalloc_numa_aware` | NUMA 感知 | 多 socket 服务器 |
| `//tcmalloc:tcmalloc_large_pages` | 大页 | 兼容旧内核 |

gem5 仿真通常是单线程或低线程并发的内存分配密集型应用，默认变体即可。如果运行在大页启用的服务器上，`tcmalloc_256k_pages` 可能更好。

### 6.6 离线编译兼容

如果 gem5 需要在无网络机器上编译：
- tcmalloc 的 Bazel 离线包（`tcmalloc-offline-8.4.2.tar.gz`）已经包含编译好的 `libtcmalloc.lo`
- 将 `libtcmalloc.lo` 复制到目标机器
- 使用 `--tcmalloc-dir` 指向其所在目录
- gem5 本身的 SCons 编译不受影响

## 7. 验证方法

从三个层面确认自编译的 tcmalloc 确实在 gem5.opt 中生效：**静态二进制分析**、**运行时 API 验证**、**运行行为验证**。

### 7.1 静态二进制分析

#### 7.1.1 `nm` — 确认 `malloc` 符号来源

```bash
nm build/ALL/gem5.opt | grep -w 'T malloc$'
```

| 输出 | 含义 |
|------|------|
| `0000000000XXXXXX T malloc` | ✅ 自编译 tcmalloc 已静态链入（T = 代码段，非 weak） |
| `                 U malloc` | ❌ 未链入，malloc 将来自 glibc（动态解析） |
| `                 W malloc` | ❌ glibc 的 __libc_malloc 弱符号（tcmalloc 未链接） |

#### 7.1.2 区分"系统 gperftools" vs "自编译 tcmalloc"

```bash
# 系统 gperftools 的符号前缀是 tc_
nm build/ALL/gem5.opt | grep ' tc_' | head -5
# 如果有输出 → 链接的是系统 libtcmalloc_minimal.so

# 自编译 tcmalloc 的符号在 tcmalloc::tcmalloc_internal 命名空间下
nm build/ALL/gem5.opt | grep 'tcmalloc.*T ' | wc -l
# 如果 ≥ 100 → 自编译 tcmalloc 已链入
```

#### 7.1.3 `ldd` — 确认不是系统动态库

```bash
ldd build/ALL/gem5.opt | grep -i tcmalloc
# 应为空（自编译 tcmalloc 是静态链接的，不依赖系统 .so）
# 如果显示 libtcmalloc.so / libtcmalloc_minimal.so → 链接的是系统 gperftools
```

### 7.2 运行时 API 验证（最可靠）

#### 7.2.1 写最小测试程序

tcmalloc 内置的 profiling/stats API 是自证身份的最强证据：

```cpp
// ~/verify_tcmalloc.cc
#include <cstdio>
#include <cstdlib>
#include "tcmalloc/malloc_extension.h"

int main() {
    // 只有自编译 tcmalloc (google/tcmalloc) 才有这些 API。
    // 系统 gperftools 的 API 命名不同。
    size_t allocated;
    tcmalloc::MallocExtension::instance()->GetNumericProperty(
        "generic.current_allocated_bytes", &allocated);
    printf("tcmalloc current allocated: %zu bytes\n", allocated);

    // 主动触发分配
    void *p = malloc(1024 * 1024);
    tcmalloc::MallocExtension::instance()->GetNumericProperty(
        "generic.current_allocated_bytes", &allocated);
    printf("after 1MB malloc: %zu bytes\n", allocated);
    free(p);

    // 检查 tcmalloc 内部统计
    tcmalloc::MallocExtension::instance()->GetNumericProperty(
        "tcmalloc.pageheap_free_bytes", &allocated);
    printf("pageheap free: %zu bytes\n", allocated);

    printf("SUCCESS: self-built tcmalloc is active.\n");
    return 0;
}
```

链接到 gem5 的 tcmalloc：

```bash
# 用 gem5 自己链接 tcmalloc 时使用的标志来编译这个小程序
cp ~/verify_tcmalloc.cc /tmp/
cd /tmp

# 关键：把 tcmalloc_merged.o 也链进来，并且包含 tcmalloc 头文件路径
g++ -o verify_tcmalloc verify_tcmalloc.cc \
    -I/home/luq/Dev/opensource/tcmalloc \
    ~/libs/tcmalloc/tcmalloc_merged.o \
    -lpthread -lstdc++

./verify_tcmalloc
# 输出应显示 tcmalloc 内部统计数据
```

#### 7.2.2 GDB 断点验证（零代码修改）

```bash
# 在 malloc 上设断点，看实际进入的是哪个实现
gdb --args build/ALL/gem5.opt configs/example/se.py \
    -c tests/test-progs/hello/bin/x86/linux/hello

(gdb) b malloc
(gdb) run
# 断点触发时，查看调用栈中 malloc 的地址来源：
(gdb) info symbol malloc
# 如果是自编译 tcmalloc：
#   malloc in section .text of .../gem5.opt
# 如果是系统 glibc：
#   malloc in section .text of /lib/x86_64-linux-gnu/libc.so.6
```

### 7.3 运行行为验证

#### 7.3.1 `strace` — 对比内存分配系统调用模式

```bash
# 基线：不用 tcmalloc 的 gem5
scons build/ALL/gem5.opt --without-tcmalloc
strace -e brk,mmap,munmap -c \
    ./build/ALL/gem5.opt configs/example/se.py \
    -c tests/test-progs/hello/bin/x86/linux/hello 2>&1 | tail -10

# 对比：用自编译 tcmalloc 的 gem5
scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc
strace -e brk,mmap,munmap -c \
    ./build/ALL/gem5.opt configs/example/se.py \
    -c tests/test-progs/hello/bin/x86/linux/hello 2>&1 | tail -10

# tcmalloc 的 mmap/brk 模式与 glibc 不同：
# - tcmalloc 倾向于用 mmap（而非 brk）做大块分配
# - mmap 调用次数和模式会有明显差异
```

#### 7.3.2 `LD_PRELOAD` 替换测试

```bash
# 如果 tcmalloc 是静态链入的，LD_PRELOAD 无法覆盖它
# 反之如果 LD_PRELOAD 有效，说明二进制依赖的是动态库
cat > /tmp/fake_malloc.c << 'EOF'
#include <stdlib.h>
void* malloc(size_t n) { write(2, "FAKE\n", 5); abort(); }
EOF
gcc -shared -fPIC -o /tmp/libfakemalloc.so /tmp/fake_malloc.c

# 运行：如果 tcmalloc 已静态链入，LD_PRELOAD 不会触发 abort
# 如果挂了 → 二进制依赖的是动态链接的 malloc
LD_PRELOAD=/tmp/libfakemalloc.so ./build/ALL/gem5.opt --version
# 正常打印版本信息 → ✅ 静态链入的 tcmalloc 在生效
```

### 7.4 性能对比

```bash
# 基线（系统 gperftools 2.15）
scons build/ALL/gem5.opt
time ./build/ALL/gem5.opt configs/example/se.py -c test-progs/hello/bin/x86/linux/hello

# 自编译 tcmalloc
scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc
time ./build/ALL/gem5.opt configs/example/se.py -c test-progs/hello/bin/x86/linux/hello

# 对比运行时间
```

## 8. SConstruct 中相关代码位置速查

| 行号 | 内容 |
|------|------|
| 133-134 | `--without-tcmalloc` 选项定义 |
| 459-463 | `TCMALLOC_CCFLAGS` 初始化为空列表 |
| 728-730 | GCC 的 `TCMALLOC_CCFLAGS` 设置 |
| 762 | Clang 的 `TCMALLOC_CCFLAGS` 设置 |
| 889-898 | tcmalloc 检测和链接逻辑（**需要修改的位置**） |
| 869-872 | pprof 分析器链接（`-lprofiler`，与 tcmalloc 独立） |

## 9. 指定 Bazel 编译产物输出目录

Bazel 默认将编译产物放在 `~/.cache/bazel/` 下，通过 `bazel-bin` 符号链接访问。对于需要将 `.lo`/`.a`/`.so` 复制到固定目录（如用于 gem5 集成或离线分发）的场景，有以下三种方式。

### 9.1 方式一：`bazel info` + `cp`（推荐，最可靠）

编译后直接复制产物到目标目录。得到的是独立文件，不依赖 Bazel cache。

```bash
cd /home/luq/Dev/opensource/tcmalloc
export USE_BAZEL_VERSION=8.4.2

# 编译
bazelisk build //tcmalloc:tcmalloc //tcmalloc:malloc_extension

# 定位产物目录
BAZEL_BIN=$(bazelisk info bazel-bin | tail -1)

# 复制到自定义目录
DIST_DIR=/home/luq/Dev/opensource/tcmalloc/dist
mkdir -p "$DIST_DIR"
cp "$BAZEL_BIN/tcmalloc/libtcmalloc.lo"      "$DIST_DIR/"
cp "$BAZEL_BIN/tcmalloc/libmalloc_extension.a"  "$DIST_DIR/"
cp "$BAZEL_BIN/tcmalloc/libmalloc_extension.so" "$DIST_DIR/"

ls -lh "$DIST_DIR/"
# libtcmalloc.lo          5.2M   静态 archive
# libmalloc_extension.a   164K   静态库
# libmalloc_extension.so  129K   动态库
```

**优点**：产物是真实文件（非符号链接），可以任意拷贝到其他机器，不依赖 Bazel cache。

### 9.2 方式二：`--symlink_prefix`（仅改符号链接位置）

将 `bazel-bin` 等符号链接输出到自定义目录。实际文件仍在 Bazel cache 中。

```bash
bazelisk build //tcmalloc:tcmalloc --symlink_prefix=build/
# 符号链接创建在项目根目录的 build/ 下：
#   build/bin    → ~/.cache/bazel/.../bazel-out/k8-fastbuild/bin
#   build/out    → ~/.cache/bazel/.../bazel-out
#   build/tcmalloc → ~/.cache/bazel/.../execroot/_main
```

**优点**：不复制文件，速度快。
**缺点**：产物仍是符号链接，目标机器需要相同的 cache 路径，不适合分发。

### 9.3 方式三：`--output_base`（改变整个 Bazel 工作目录）

把 Bazel 的所有输出（含 cache 和产物）放到自定义目录。

```bash
bazelisk --output_base=/opt/tcmalloc-build build //tcmalloc:tcmalloc
# 产物在 /opt/tcmalloc-build/.../bazel-out/k8-fastbuild/bin/tcmalloc/libtcmalloc.lo
```

**优点**：完全控制 Bazel 工作目录位置。
**缺点**：cache 与项目分离，增量构建可能重新编译。

### 9.4 gem5 集成推荐流程

```bash
# Step 1: 编译 tcmalloc 并生成合并 .o
cd /home/luq/Dev/opensource/tcmalloc
bazelisk build //tcmalloc:tcmalloc

# 创建临时 workspace 收集完整 .o 列表（见第 5.2.1 节详细步骤）
mkdir -p ~/libs/tcmalloc /tmp/gen_merged
cd /tmp/gen_merged
echo 'int main(){}' > main.cc
# ... 创建 MODULE.bazel + BUILD（见 5.2.1）
bazelisk build //:gen
EXEC_ROOT=$(bazelisk info execution_root | tail -1)
PARAMS=$(find "$(bazelisk info bazel-bin | tail -1)" -name "gen-0.params")
grep '\.pic\.o$' "$PARAMS" | grep -v "gen/main" > obj_list.txt
cd "$EXEC_ROOT"
ld -r -o ~/libs/tcmalloc/tcmalloc_merged.o $(cat /tmp/gen_merged/obj_list.txt)

# Step 2: gem5 构建时指定路径
cd /home/luq/Dev/opensource/gem5
scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc
```

> **离线环境**：详见第 5.2.6 节。

## 10. 操作清单（实施时使用）

1. [ ] 编译 tcmalloc：`cd tcmalloc && bazel build //tcmalloc:tcmalloc`
2. [ ] 生成合并 .o：创建临时 workspace + `ld -r`（见第 5.2.1 节）
3. [ ] 验证 .o：`nm ~/libs/tcmalloc/tcmalloc_merged.o | grep -w malloc`（应有 T）
4. [ ] 修改 gem5 的 `SConstruct`：添加 `--tcmalloc-dir` 选项（第 5.2.3 节代码）
5. [ ] 构建 gem5：`scons build/ALL/gem5.opt --tcmalloc-dir=~/libs/tcmalloc`
6. [ ] 验证链接：`nm build/ALL/gem5.opt | grep -w malloc`
7. [ ] 验证运行：`./build/ALL/gem5.opt configs/example/se.py -c hello`
8. [ ] 性能对比：与系统 gperftools 版本比较运行时间
