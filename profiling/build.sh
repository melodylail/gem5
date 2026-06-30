#!/bin/bash
# profiling/build.sh
# Build gem5 X86 opt variant
# Usage: ./build.sh [-j N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

cd "$GEM5_HOME"
echo "Building gem5 at $GEM5_HOME ..."
scons build/ALL/gem5.opt -j "${1:-$(nproc)}"
echo "Build complete: $GEM5_BUILD"
