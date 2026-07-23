# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**gem5** is a modular computer-system architecture simulator for researching hardware designs, system software, and optimizations. It supports multiple ISAs (X86, ARM, RISC-V, MIPS, POWER, SPARC) and uses **SCons** for building, with Python for configuration and C++ for core simulation.

Key resources:
- [Official website](https://www.gem5.org)
- [Documentation](https://www.gem5.org/documentation)
- [Learning gem5](https://www.gem5.org/documentation/learning_gem5/introduction)

---

## Build System

gem5 uses **SCons** (Python-based build system). All builds follow the pattern: `scons build/<ISA>/<target>` where:
- `<ISA>`: `ALL`, `X86`, `ARM`, `RISCV`, `MIPS`, `POWER`, `SPARC`, or `NULL`
- `<target>`: `gem5.opt` (optimized), `gem5.debug` (debug), `gem5.fast` (no assertions/tracing)

### Common Build Commands

```bash
# Optimized build for all ISAs (most common)
scons build/ALL/gem5.opt -j$(nproc)

# Single ISA
scons build/X86/gem5.opt -j$(nproc)
scons build/ARM/gem5.opt -j$(nproc)
scons build/RISCV/gem5.opt -j$(nproc)

# Debug build (with debug symbols and runtime checks)
scons build/ALL/gem5.debug -j$(nproc)

# Fast build (optimized, no debug info or assertions)
scons build/ALL/gem5.fast -j$(nproc)

# Show all available build options
scons -h
```

### Build Options

Common SCons flags (use `scons --help` for full list):
- `--ignore-style`: Skip style checking hooks
- `--with-cxx-config`: Build with C++-based configuration support
- `--with-lto`: Enable Link-Time Optimization
- `--with-asan`: Build with Address Sanitizer
- `--with-ubsan`: Build with Undefined Behavior Sanitizer
- `--gprof`, `--pprof`: Enable profiler support
- `--linker={bfd,gold,lld,mold}`: Choose linker

---

## Testing

### C++ Unit Tests (Google Test)

```bash
# Build and run all C++ unit tests
scons build/ALL/unittests.opt -j$(nproc)

# Run a specific test file
./build/ALL/base/bitunion.test.opt

# List all test functions
./build/ALL/base/bitunion.test.opt --gtest_list_tests

# Run specific test function
./build/ALL/base/bitunion.test.opt --gtest_filter=BitUnionData.NormalBitfield
```

### Python Unit Tests

```bash
# Build gem5 first (required)
scons build/ALL/gem5.opt -j$(nproc)

# Run Python unit tests
./build/ALL/gem5.opt tests/run_pyunit.py
```

### System-Level Tests (Regression Tests)

```bash
cd tests

# Quick tests (default, ~few hours) — run before PRs
./main.py run -j$(nproc)

# Long tests (~12 hours)
./main.py run --length=long -j$(nproc)

# Very-long tests (~days)
./main.py run --length=very-long -j$(nproc)

# Skip rebuild, run with 3 parallel suites
./main.py run --skip-build -t 3

# List all quick test suites
./main.py list -q --suites

# Run a specific test suite
./main.py run --skip-build --uid SuiteUID:path/to/test.py:testname-X86-opt

# Rerun only failed tests from last run
./main.py rerun

# Verbose output
./main.py run -vv
```

Test resources (GEM5 kernel/disk images) cache in `tests/gem5/resources/`—delete after testing to free space.

---

## Code Quality & Formatting

### Pre-commit Hooks (Mandatory)

```bash
# Install hooks (run once per clone)
pip install -r requirements.txt
pre-commit install

# Manually run all checks
pre-commit run --all-files

# Run specific check
pre-commit run <hook-id>
```

Hooks enforce:
- **C++ formatting** via `clang-format` (79-char max, 4-space indent)
- **Python formatting** via `black` (79-char line-length)
- **Import sorting** via `isort` (black profile)
- **Trailing whitespace** and **merge conflict markers**
- **Commit message length** (max 65 chars for title)
- **Large file detection** (warns on files >500KB)

### Manual Formatting

```bash
# C++ formatting
clang-format -i <file>
clang-format --dry-run --Werror <file>  # Check only

# Python formatting
black --line-length=79 <file>
isort <file>  # Import sorting

# Type checking
mypy --strict <file>
```

### Code Style Quick Reference

**C++ style guide**: https://www.gem5.org/documentation/general_docs/development/coding_style
- Class names: `UpperCamelCase`
- Member variables: `lowerCamelCase`
- Private members: `_prefixWithUnderscore`
- Local variables: `snake_case`
- Function parameters: `snake_case`
- Max line width: 79 characters
- Indent: 4 spaces (no tabs)

**Python style guide**: PEP 8 + Black (79-char lines)
- Follow existing file conventions when modifying
- Type annotations on all function signatures
- Use `black` and `isort` for consistency

---

## Architecture

| Directory | Purpose |
|-----------|---------|
| `src/` | Core simulator source code (C++ and Python) |
| `src/arch/` | ISA implementations (ARM, X86, RISC-V, MIPS, POWER, SPARC) |
| `src/cpu/` | CPU models (simple, O3, minor, in-order) |
| `src/mem/` | Memory system (caches, DRAM, coherence protocols) |
| `src/sim/` | Core simulation engine (events, clocks, statistics) |
| `src/base/` | Utilities (logging, bit operations, serialization) |
| `src/python/` | Python bindings and m5 module |
| `src/dev/` | Device models (I/O devices, peripherals) |
| `configs/` | Example simulation configuration scripts (Python) |
| `configs/example/` | SE (system-call emulation) and FS (full-system) examples |
| `configs/ruby/` | Memory protocol configurations |
| `tests/` | Regression and unit tests |
| `tests/gem5/` | System-level test suites |
| `tests/pyunit/` | Python unit tests |
| `util/` | Utility scripts and tools (m5 terminal, checkpoint upgrade, etc.) |
| `build_opts/` | Pre-defined build configurations for each ISA |

### Key Code Patterns

**Simulation objects** live in `src/` as C++ classes with Python wrappers. They're instantiated in Python config scripts (`configs/`), then C++ runs the simulation loop.

**Configuration** happens via Python scripts (e.g., `configs/example/se.py`, `configs/example/fs.py`) that instantiate and connect system objects, then sim starts.

**ISA-specific code** is isolated in `src/arch/<isa>/` to support multiple architectures cleanly.

---

## Branch Workflow

| Rule | Details |
|------|---------|
| **Never push to `stable` or `develop` directly** | Always use feature branches + PR review |
| **Base new work on `develop`** | Clone/fork, branch from `develop`, submit PRs targeting `upstream/develop` |
| **Branch naming** | Use descriptive names: `new-feature`, `fix-xxx`, `refactor-cache`, etc. |
| **Keep in sync** | Before PR: `git fetch upstream && git rebase upstream/develop` |
| **Pre-commit before push** | Run `pre-commit run --all-files` and fix any issues |
| **Build before commit** | Ensure `scons build/ALL/gem5.opt` succeeds |

---

## Prohibited Actions

1. ❌ Direct commits to `stable` or `develop`
2. ❌ Skipping `pre-commit install` hooks
3. ❌ Committing unformatted C++ (must pass `clang-format`)
4. ❌ Committing unformatted Python (must pass `black` + `isort`)
5. ❌ Commit messages with title >65 characters
6. ❌ PRs without passing quick tests (`cd tests && ./main.py run`)
7. ❌ Committing non-compiling code to `develop`
8. ❌ Tab characters or trailing whitespace (caught by pre-commit)
9. ❌ Debug `print()` or hardcoded log statements left in code
10. ❌ Large files (>500KB) without discussion

---

## Running Simulations

### SE Mode (System-Call Emulation)

```bash
./build/X86/gem5.opt configs/example/se.py -c /path/to/binary [args...]
```

### FS Mode (Full-System)

```bash
./build/X86/gem5.opt configs/example/fs.py \
  --kernel=/path/to/vmlinux \
  --disk=/path/to/disk.img
```

Output stats and traces go to `m5out/` by default.

---

## Useful Links

- **Jira Issue Tracker**: https://gem5.atlassian.net
- **GitHub Issues**: https://github.com/gem5/gem5/issues
- **GitHub Discussions**: https://github.com/orgs/gem5/discussions
- **Slack Community**: https://www.gem5.org/join-slack
- **Mailing Lists**: gem5-users@gem5.org, gem5-dev@gem5.org
- **gem5 Resources**: https://resources.gem5.org
