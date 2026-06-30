#!/bin/bash
# profiling/env.sh
# 唯一需要编辑的文件 — 设置 gem5 项目路径
# 也可通过 export GEM5_HOME=/path/to/gem5 覆盖

export GEM5_HOME="${GEM5_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export GEM5_BUILD="${GEM5_BUILD:-$GEM5_HOME/build/ALL/gem5.opt}"
