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
# Usage: ./buildscripts/build_binding.sh <python-executable> [build-dir] [output-dir] [llvm-source-dir]
#
# Arguments:
#   python-executable  - Path to the Python interpreter to build for
#                        (e.g., /usr/bin/python3.12, python3, etc.)
#   build-dir          - LLVM build directory from Phase 1
#                        (default: ./build-llvm)
#   output-dir         - Where to copy the final .so file
#                        (default: ./package)
#   llvm-source-dir    - Path to llvm-project source root
#                        (default: auto-detect from CMakeCache.txt, or ./llvm-project)
#
# Environment variables:
#   LLVM_SRC_DIR       - Override the LLVM source directory (alternative to arg 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_EXE="${1:?Usage: build_binding.sh <python-executable> [build-dir] [output-dir] [llvm-source-dir]}"
PYTHON_EXE="$(readlink -f "$(command -v "$PYTHON_EXE")" 2>/dev/null || echo "$PYTHON_EXE")"
BUILD_DIR="${2:-$REPO_ROOT/build-llvm}"
OUTPUT_DIR="${3:-$REPO_ROOT/package}"
LLVM_SRC_ARG="${4:-${LLVM_SRC_DIR:-}}"

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

# --- Resolve the LLVM source directory ---
# Phase 1 records the absolute source path in CMakeCache.txt as CMAKE_HOME_DIRECTORY.
# In CI, Phase 2 runs in a different job where that path may not exist (the LLVM
# source tree is not transferred, only the build artifacts). We handle this by:
#   1. Accepting an explicit source dir via argument or env var
#   2. Falling back to the cached path from CMakeCache.txt
#   3. Falling back to ./llvm-project (relative to repo root)
#   4. If none exist, cloning LLVM at the expected location

CACHED_SRC_DIR="$(grep '^CMAKE_HOME_DIRECTORY' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2)"

resolve_llvm_source() {
    # Priority 1: Explicit argument or env var
    if [ -n "$LLVM_SRC_ARG" ] && [ -d "$LLVM_SRC_ARG/llvm" ]; then
        echo "$LLVM_SRC_ARG/llvm"
        return
    fi
    if [ -n "$LLVM_SRC_ARG" ] && [ -f "$LLVM_SRC_ARG/CMakeLists.txt" ]; then
        # User passed the llvm/ subdirectory directly
        echo "$LLVM_SRC_ARG"
        return
    fi

    # Priority 2: Cached path from Phase 1
    if [ -n "$CACHED_SRC_DIR" ] && [ -d "$CACHED_SRC_DIR" ]; then
        echo "$CACHED_SRC_DIR"
        return
    fi

    # Priority 3: Common relative locations
    for candidate in \
        "$REPO_ROOT/llvm-project/llvm" \
        "$REPO_ROOT/llvm-project" \
        "./llvm-project/llvm" \
        "./llvm-project"; do
        if [ -d "$candidate" ] && [ -f "$candidate/CMakeLists.txt" ]; then
            echo "$candidate"
            return
        fi
    done

    # Not found
    return 1
}

LLVM_CMAKE_SRC=""
if LLVM_CMAKE_SRC="$(resolve_llvm_source)"; then
    echo ">>> Found LLVM source at: $LLVM_CMAKE_SRC"
else
    # Need to clone LLVM. Read the version from LLVM_VERSION file.
    LLVM_VERSION_FILE="$REPO_ROOT/LLVM_VERSION"
    if [ ! -f "$LLVM_VERSION_FILE" ]; then
        echo "ERROR: LLVM source not found and no LLVM_VERSION file to clone from."
        echo "Searched:"
        echo "  - Argument/env: $LLVM_SRC_ARG"
        echo "  - CMakeCache:   $CACHED_SRC_DIR"
        echo "  - Relative:     $REPO_ROOT/llvm-project/llvm"
        echo ""
        echo "Either:"
        echo "  1. Pass the LLVM source path as argument 4"
        echo "  2. Set LLVM_SRC_DIR environment variable"
        echo "  3. Ensure llvm-project/ exists in the repo root"
        exit 1
    fi

    LLVM_VERSION="$(cat "$LLVM_VERSION_FILE" | tr -d '[:space:]')"
    CLONE_DIR="$REPO_ROOT/llvm-project"

    echo ">>> LLVM source not found at cached path: $CACHED_SRC_DIR"
    echo ">>> Cloning llvm-project at $LLVM_VERSION (shallow) ..."
    git clone --depth 1 --branch "$LLVM_VERSION" \
        https://github.com/llvm/llvm-project.git "$CLONE_DIR"

    LLVM_CMAKE_SRC="$CLONE_DIR/llvm"

    if [ ! -d "$LLVM_CMAKE_SRC" ]; then
        echo "ERROR: Cloned llvm-project but $LLVM_CMAKE_SRC does not exist"
        exit 1
    fi
fi

# --- Update CMakeCache.txt if source path has changed ---
# If the recorded CMAKE_HOME_DIRECTORY differs from our resolved source,
# we need to update it so cmake doesn't reject the reconfigure.
RESOLVED_SRC="$(cd "$LLVM_CMAKE_SRC" && pwd)"
if [ "$CACHED_SRC_DIR" != "$RESOLVED_SRC" ]; then
    echo ">>> Updating CMAKE_HOME_DIRECTORY in CMakeCache.txt"
    echo "    Old: $CACHED_SRC_DIR"
    echo "    New: $RESOLVED_SRC"
    sed -i.bak "s|^CMAKE_HOME_DIRECTORY:INTERNAL=.*|CMAKE_HOME_DIRECTORY:INTERNAL=$RESOLVED_SRC|" \
        "$BUILD_DIR/CMakeCache.txt"

    # Also update CMAKE_CACHEFILE_DIR-related source path references
    # that CMake might check during reconfigure
    if grep -q "^LLVM_MAIN_SRC_DIR:PATH=" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
        sed -i.bak "s|^LLVM_MAIN_SRC_DIR:PATH=.*|LLVM_MAIN_SRC_DIR:PATH=$RESOLVED_SRC|" \
            "$BUILD_DIR/CMakeCache.txt"
    fi

    # Fix any other references to the old source path
    OLD_PARENT="$(dirname "$CACHED_SRC_DIR")"
    NEW_PARENT="$(dirname "$RESOLVED_SRC")"
    if [ "$OLD_PARENT" != "$NEW_PARENT" ]; then
        sed -i.bak "s|$OLD_PARENT|$NEW_PARENT|g" "$BUILD_DIR/CMakeCache.txt"
    fi
    rm -f "$BUILD_DIR/CMakeCache.txt.bak"
fi

# Get Python version info for logging
PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Binding Build (Phase 2) ==="
echo "Python        : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "LLVM source   : $LLVM_CMAKE_SRC"
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
cmake -S "$LLVM_CMAKE_SRC" \
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