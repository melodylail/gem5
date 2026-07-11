#!/bin/bash
# profiling/mem/tests/tools/build_fake_gem5.sh
set -euo pipefail
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$TOOLS_DIR/fake_gem5"
if [ -f "$BINARY" ] && [ "$BINARY" -nt "$TOOLS_DIR/fake_gem5.c" ]; then
    echo "fake_gem5 up to date: $BINARY"
    exit 0
fi
echo "Building fake_gem5..."
cc -std=c11 -Wall -Wextra -O2 -o "$BINARY" "$TOOLS_DIR/fake_gem5.c"
echo "Built: $BINARY"
