#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build the IR2Vec nanobind Python module (Phase 2).
#
# This script takes the LLVM build tree from Phase 1, reconfigures it with
# Python bindings enabled for a specific Python interpreter, and builds only
# the nanobind module. Since all LLVM static libraries are already built,
# this step is fast (~30 seconds).
#
# The output is a shared library like:
#   ir2vec.cpython-312-x86_64-linux-gnu.so
#
# After this script, run test_module.sh to verify the module before packaging.
#
# Usage: ./buildscripts/build_binding.sh <python-executable> [build-dir] [output-dir]
#
# Arguments:
#   python-executable  - Path to the Python interpreter to build for
#                        (e.g., /usr/bin/python3.12, python3, etc.)
#   build-dir          - LLVM build directory from Phase 1
#                        (default: ./build-llvm)
#   output-dir         - Where to copy the final .so file
#                        (default: ./package)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_EXE="${1:?Usage: build_binding.sh <python-executable> [build-dir] [output-dir]}"
PYTHON_EXE="$(readlink -f "$(command -v "$PYTHON_EXE")" 2>/dev/null || echo "$PYTHON_EXE")"
BUILD_DIR="${2:-$REPO_ROOT/build-llvm}"
OUTPUT_DIR="${3:-$REPO_ROOT/package}"

# Validate inputs
if ! command -v "$PYTHON_EXE" &>/dev/null; then
    echo "ERROR: Python executable not found: $PYTHON_EXE"
    exit 1
fi

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: No CMakeCache.txt in $BUILD_DIR"
    echo "Run build_llvm.sh (Phase 1) first."
    exit 1
fi

# Get Python version info for logging
PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Binding Build (Phase 2) ==="
echo "Python        : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "Build dir     : $BUILD_DIR"
echo "Output dir    : $OUTPUT_DIR"
echo "======================================="

# --- Step 1: Ensure nanobind is installed for this Python ---
echo ">>> Ensuring nanobind is installed ..."
"$PYTHON_EXE" -m pip install nanobind --quiet 2>/dev/null || {
    echo "ERROR: Failed to install nanobind for $PYTHON_EXE"
    echo "Make sure pip is available: $PYTHON_EXE -m pip --version"
    exit 1
}

NANOBIND_CMAKE_DIR=$("$PYTHON_EXE" -m nanobind --cmake_dir 2>/dev/null) || {
    echo "ERROR: nanobind installed but --cmake_dir failed"
    exit 1
}
echo "  nanobind cmake dir: $NANOBIND_CMAKE_DIR"

# --- Step 2: Reconfigure with Python bindings ON ---
# We re-run cmake on the existing build tree. This is fast because:
#   - All LLVM libraries are already built (not rebuilt)
#   - CMake only picks up the new settings (Python bindings ON)
#   - Only the ir2vec nanobind target is new
echo ">>> Reconfiguring with Python bindings enabled ..."
cmake -S "$(grep 'CMAKE_HOME_DIRECTORY' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2)" \
      -B "$BUILD_DIR" \
    -DLLVM_IR2VEC_ENABLE_PYTHON_BINDINGS=ON \
    -DPython_EXECUTABLE="$PYTHON_EXE" \
    -DPython3_EXECUTABLE="$PYTHON_EXE" \
    -Dnanobind_DIR="$NANOBIND_CMAKE_DIR"

# --- Step 3: Build only the nanobind module ---
# The target name is "ir2vec" (from nanobind_add_module(ir2vec ...) in
# Bindings/CMakeLists.txt). This links against LLVMEmbUtils and
# transitively against all required LLVM static libraries.
echo ">>> Building nanobind module ..."
cmake --build "$BUILD_DIR" --target ir2vec -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# --- Step 4: Find and copy the built module ---
echo ">>> Locating built module ..."

# The module will be named like:
#   ir2vec.cpython-312-x86_64-linux-gnu.so  (Linux)
#   ir2vec.cpython-312-darwin.so             (macOS)
#   ir2vec.cpython-312-x86_64.pyd            (Windows)
MODULE_FILE=$(find "$BUILD_DIR" -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)

if [ -z "$MODULE_FILE" ]; then
    echo "ERROR: Built nanobind module not found in $BUILD_DIR"
    echo "Expected a file matching ir2vec.cpython-* or ir2vec*.pyd"
    exit 1
fi

echo "  Found: $MODULE_FILE"

mkdir -p "$OUTPUT_DIR"
cp "$MODULE_FILE" "$OUTPUT_DIR/"

DEST="$OUTPUT_DIR/$(basename "$MODULE_FILE")"
echo "  Copied to: $DEST"

echo ""
echo "=== Phase 2 complete ==="
echo "Module: $DEST"
echo "Python: $PY_VERSION"
echo ""
echo "Next steps:"
echo "  1. Verify:  ./buildscripts/test_module.sh $PYTHON_EXE $OUTPUT_DIR"
echo "  2. Package: ./buildscripts/build_wheel.sh $PYTHON_EXE $OUTPUT_DIR"