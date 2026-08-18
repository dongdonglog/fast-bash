#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/netmon_bpfel.o"}
CLANG_BIN=${CLANG:-clang}
MULTIARCH=$(gcc -print-multiarch 2>/dev/null || true)
INCLUDES=(-I/usr/include)
[[ -z $MULTIARCH ]] || INCLUDES+=("-I/usr/include/$MULTIARCH")

"$CLANG_BIN" -O2 -g -target bpf -D__TARGET_ARCH_x86 \
  "${INCLUDES[@]}" -c "$SCRIPT_DIR/netmon.c" -o "$OUTPUT"
