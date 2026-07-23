# gem5 AGENTS.md — AI 协作者指南

> gem5 是一个模块化的计算机系统架构研究模拟器，覆盖系统级架构和处理器微架构。
> 官网：https://www.gem5.org | 仓库：https://github.com/gem5/gem5

---

## 一、目录结构

| 目录 | 说明 |
|------|------|
| `src/` | **核心源码**。C++ 实现、Python 封装、Python 标准库均在此目录下 |
| `src/arch/` | ISA 实现：ARM, X86, RISC-V, MIPS, POWER, SPARC 等 |
| `src/cpu/` | CPU 模型（simple, O3, minor 等） |
| `src/mem/` | 内存系统（cache, DRAM, Ruby 一致性协议） |
| `src/dev/` | 设备模型（IO 设备、外设） |
| `src/sim/` | 核心仿真引擎（事件驱动、时钟、系统对象） |
| `src/base/` | 基础工具类（日志、统计、位操作等） |
| `src/python/` | Python 封装层，包括 `m5` 模块和 Pybind 绑定 |
| `src/gpu-compute/` | GPU 计算仿真 |
| `src/proto/` | Protobuf 定义（用于 trace 捕获/回放） |
| `src/systemc/` | SystemC 支持 |
| `build_opts/` | 预制的 gem5 构建配置文件（如 ALL, X86, ARM, RISCV 等） |
| `build_tools/` | gem5 构建流程使用的内部工具 |
| `configs/` | 示例仿真配置脚本（Python），含 `example/`, `common/`, `ruby/` 等 |
| `ext/` | 构建所需的外部依赖包 |
| `system/` | 可选的被仿真系统固件/软件（ARM bootloader 等） |
| `tests/` | 回归测试，包括 `gem5/`（系统级）、`pyunit/`（Python 单元）、`test-progs/`（测试程序） |
| `util/` | 实用工具脚本（m5 终端、checkpoint 升级、Docker 等） |
| `site_scons/` | SCons 构建系统的模块化组件 |
| `include/` | 供外部程序使用的头文件 |
| `.github/` | CI workflows 和 GitHub 配置 |
| `docs/` | 文档源码 |

---

## 二、开发命令

### 2.1 环境准备

```bash
# 安装依赖（Ubuntu）
sudo apt install -y build-essential scons python3-dev zlib1g-dev m4 \
  libprotobuf-dev protobuf-compiler libgoogle-perftools-dev

# 安装 Python 开发依赖
pip install -r requirements.txt
```

### 2.2 构建

```bash
# 构建 所有 ISA 的优化版（最常用）
scons build/ALL/gem5.opt -j$(nproc)

# 构建单个 ISA 的优化版
scons build/X86/gem5.opt -j$(nproc)
scons build/ARM/gem5.opt -j$(nproc)
scons build/RISCV/gem5.opt -j$(nproc)

# 构建 debug 版
scons build/ALL/gem5.debug -j$(nproc)

# 构建 fast 版（无运行时检查）
scons build/ALL/gem5.fast -j$(nproc)

# 列出所有可用的 build_opts
ls build_opts/
```

可选 ISA 名称：`ALL`, `ARM`, `NULL`, `MIPS`, `POWER`, `RISCV`, `SPARC`, `X86`  
构建变体：`.opt`（优化）, `.debug`（调试）, `.fast`（无断言）

### 2.3 运行仿真

```bash
# SE 模式（系统调用仿真）
./build/X86/gem5.opt configs/example/se.py -c /path/to/binary

# FS 模式（全系统仿真）
./build/X86/gem5.opt configs/example/fs.py --disk=/path/to/disk.img --kernel=/path/to/vmlinux
```

### 2.4 代码质量

```bash
# 安装 pre-commit（强烈推荐，提交前自动检查）
pip install pre-commit
pre-commit install

# 手动运行所有 pre-commit 检查
pre-commit run --all-files

# Python 格式化（Black, line-length=79）
black <files_or_directories>

# Python import 排序（isort, profile=black）
isort <files_or_directories>

# C++ 格式化（clang-format，基于 .clang-format）
clang-format -i <file>

# 仅检查，不修改
clang-format --dry-run --Werror <file>
```

---

## 三、测试命令

### 3.1 C++ 单元测试（Google Test）

```bash
# 构建并运行所有单元测试
scons build/ALL/unittests.opt -j$(nproc)

# 构建并运行单个测试文件
scons build/ALL/base/bitunion.test.opt
./build/ALL/base/bitunion.test.opt

# 列出所有测试函数
./build/ALL/base/bitunion.test.opt --gtest_list_tests

# 运行特定测试函数
./build/ALL/base/bitunion.test.opt --gtest_filter=BitUnionData.NormalBitfield
```

### 3.2 Python 单元测试

```bash
# 先构建 gem5 二进制
scons build/ALL/gem5.opt -j$(nproc)

# 运行 Python 单元测试
./build/ALL/gem5.opt tests/run_pyunit.py
```

### 3.3 系统级测试

```bash
cd tests

# 运行 quick 测试（提交 PR 前至少跑这个，约几小时）
./main.py run -j$(nproc)

# 运行 long 测试（约 12 小时）
./main.py run --length=long -j$(nproc)

# 运行 very-long 测试（约数天）
./main.py run --length=very-long -j$(nproc)

# 并行执行（不重新构建，每个 suite 单独跑）
./main.py run --skip-build -t 3

# 列出所有 quick 测试 suites
./main.py list -q --suites

# 运行单个 suite
./main.py run --skip-build --uid SuiteUID:tests/gem5/hello_se/test_hello_se.py:testhello64-static-X86-opt

# 仅重跑上次失败的测试
./main.py rerun
```

### 3.4 调试测试

```bash
# 增加详细输出
./main.py run -v
./main.py run -vv
./main.py run -vvv
```

测试资源缓存在 `tests/gem5/resources/`，完成后建议删除以释放空间。

---

## 四、代码风格

### 4.1 C++ 风格

gem5 使用定制 C++ 风格（基于 `.clang-format` 配置文件）：

| 规则 | 说明 |
|------|------|
| 行宽 | 最大 79 字符 |
| 缩进 | 4 空格，禁止 Tab |
| 类名 | UpperCamelCase（`ThisIsAClass`） |
| 成员变量 | lowerCamelCase（`thisIsAMember`） |
| 公开访问的成员变量 | 以下划线开头（`_variableWithAccessor`） |
| 局部变量 | snake_case（`this_is_a_local`） |
| 函数名 | lowerCamelCase（`thisIsAFunction`） |
| 函数参数 | snake_case（`parameter_one`） |
| 宏 | 全大写 + 下划线（`THIS_IS_A_MACRO`） |
| 指针声明 | 星号紧贴变量名（`Foo *p`） |
| 函数返回类型 | 定义时独占一行，声明时不换行 |
| 函数体括号 | 独占一行 |
| if/for/while 括号 | 与语句同行，条件后有空格（`if (cond) {`） |
| 访问修饰符 | 缩进 2 空格，成员/方法缩进 4 空格 |

示例：

```cpp
class ExampleClass
{
  private:
    int _fooBar;
    int barFoo;

  public:
    int
    getFooBar()
    {
        return _fooBar;
    }

    int
    aFunction(int parameter_one, int parameter_two)
    {
        int local_variable = 0;
        if (true) {
            local_variable = parameter_one + parameter_two + barFoo;
        }
        return local_variable;
    }
};
```

完整规范见：https://www.gem5.org/documentation/general_docs/development/coding_style

### 4.2 Python 风格

- 使用 **Black** 格式化，行宽 `79`（见 `pyproject.toml`）
- 使用 **isort** 排序 imports，profile 设为 `black`
- 命名遵循 [PEP 8](https://peps.python.org/pep-0008/#naming-conventions)
- **如果修改已有文件，沿用该文件的命名风格**

```bash
# 自动格式化
black --line-length=79 <file>
isort --profile=black <file>
```

### 4.3 Commit 消息规范

```
[tags]: 简短描述（不超过 65 字符）

详细描述（可选，每行不超过 72 字符）。
多段落以空行分隔。

Jira Issue: https://gem5.atlassian.net/browse/GEM5-XXX
```

Tags 参考 `MAINTAINERS.yaml`，常用如：`cpu`, `mem`, `arch-x86`, `arch-arm`, `tests`, `python`, `gpu`, `sim` 等。多个 tag 用逗号分隔。

---

## 五、分支与工作流

| 规则 | 说明 |
|------|------|
| **禁止直接提交到 `stable`** | `stable` 只包含正式发布版本，所有开发在 `develop` 上进行 |
| **禁止直接提交到 `develop`** | 始终创建功能分支，通过 PR 合并 |
| 分支命名 | `new-feature`、`fix-xxx` 等描述性名称 |
| PR 目标 | 始终指向 `upstream` 的 `develop` 分支 |
| 同步上游 | 定期 `git fetch upstream && git rebase upstream/develop` |

```bash
# 创建功能分支
git switch develop
git pull
git switch -c your-feature

# 开发完成后推送到 fork
git push --set-upstream origin your-feature
# 然后通过 GitHub 创建 PR → gem5/gem5 develop
```

---

## 六、禁止事项

1. **禁止直接 push 到 `stable` 或 `develop` 分支** — 必须通过 PR + review
2. **禁止忽略 pre-commit hooks** — 安装 `pre-commit install`，确保提交前自动检查通过
3. **禁止提交未格式化的代码** — C++ 须通过 `clang-format`，Python 须通过 `black` + `isort`
4. **禁止在提交中包含 tab 字符或行尾空白** — pre-commit 会自动检测
5. **禁止 commit 消息超过 65 字符的标题行** — 超过会在 commit-msg hook 失败
6. **禁止跳过 CI 测试提交 PR** — 至少跑 `cd tests && ./main.py run -j<N>` 确认 quick 测试通过
7. **禁止提交未编译的代码** — 确保 `scons build/ALL/gem5.opt` 构建成功后再提交
8. **禁止提交包含 merge conflict 标记的文件** — pre-commit 会自动检测
9. **禁止添加大文件（>500KB）而不经过讨论** — pre-commit 会警告
10. **禁止在 PR 中使用不礼貌语言** — CODE-OF-CONDUCT.md 要求全程文明沟通
11. **禁止修改 `.github/` 目录的文件直接提交到 `stable`** — 必须先提交到 `develop`
12. **禁止在代码中留下调试用的硬编码 print/日志语句** — 确保最终提交干净
13. **禁止自己 assign 已被他人 assigned 的 Jira/Issue** — 先留言确认

---

## 七、常用链接

| 资源 | 链接 |
|------|------|
| 官网 | https://www.gem5.org |
| 文档 | https://www.gem5.org/documentation |
| 入门教程 | https://www.gem5.org/documentation/learning_gem5/introduction |
| 资源下载 | https://resources.gem5.org |
| Issue (GitHub) | https://github.com/gem5/gem5/issues |
| Issue (Jira) | https://gem5.atlassian.net |
| Pull Requests | https://github.com/gem5/gem5/pulls |
| 讨论 | https://github.com/orgs/gem5/discussions |
| Slack | https://www.gem5.org/join-slack |
