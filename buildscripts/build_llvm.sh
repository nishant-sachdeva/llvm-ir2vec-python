#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build LLVM with IR2Vec support (Phase 1).
# Produces an installed LLVM prefix that Phase 2 links against.
#
# This script builds all LLVM static libraries plus LLVMEmbUtils, then
# runs `cmake --install` to produce a clean install prefix. Phase 2 uses
# this prefix to build the nanobind Python module.
#
# Note: LLVMEmbUtils is marked BUILDTREE_ONLY in its CMakeLists.txt, so
# it is NOT included in the install. Phase 2 compiles it from source
# (it's just one .cpp file) and links against the installed LLVM libraries.
#
# Usage: ./buildscripts/build_llvm.sh [llvm-project-dir] [build-dir] [install-dir]
#
# Environment variables:
#   LLVM_TARGETS_TO_BUILD  - semicolon-separated targets (default: "host")
#   CMAKE_BUILD_TYPE       - Release, RelWithDebInfo, etc. (default: Release)
#   PARALLEL_JOBS          - number of parallel compile jobs (default: nproc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LLVM_VERSION=$(cat "$REPO_ROOT/LLVM_VERSION")
LLVM_SRC_DIR="${1:-$REPO_ROOT/llvm-project}"
BUILD_DIR="${2:-$REPO_ROOT/build-llvm}"
INSTALL_DIR="${3:-$REPO_ROOT/llvm-install}"

TARGETS="${LLVM_TARGETS_TO_BUILD:-host}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
JOBS="${PARALLEL_JOBS:-$(nproc 2>/dev/null || echo 4)}"

echo "=== IR2Vec LLVM Build (Phase 1) ==="
echo "LLVM version : $LLVM_VERSION"
echo "Source dir    : $LLVM_SRC_DIR"
echo "Build dir     : $BUILD_DIR"
echo "Install dir   : $INSTALL_DIR"
echo "Targets       : $TARGETS"
echo "Build type    : $BUILD_TYPE"
echo "Parallel jobs : $JOBS"
echo "===================================="

# --- Step 1: Clone LLVM if not already present ---
if [ ! -d "$LLVM_SRC_DIR/llvm" ]; then
    echo ">>> Cloning llvm-project at $LLVM_VERSION ..."
    git clone --depth 1 --branch "$LLVM_VERSION" \
        https://github.com/llvm/llvm-project.git "$LLVM_SRC_DIR"
else
    echo ">>> Using existing LLVM source at $LLVM_SRC_DIR"
fi

# --- Step 2: Configure ---
# Key decisions:
#   LLVM_ENABLE_PIC=ON       - Required: .a libs link into a shared .so
#   LLVM_BUILD_TOOLS=OFF     - Skip ~40 executables we don't need
#   LLVM_TARGETS_TO_BUILD    - Only host arch (minimises build time + size)
#   All optional deps OFF    - No zlib/zstd/libxml2/libedit → no extra .so deps
#   CMAKE_INSTALL_PREFIX     - Where `cmake --install` places the output
#   LLVM_IR2VEC_ENABLE_PYTHON_BINDINGS=OFF - Binding built in Phase 2

echo ">>> Configuring LLVM ..."
cmake -G Ninja -S "$LLVM_SRC_DIR/llvm" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DLLVM_TARGETS_TO_BUILD="$TARGETS" \
    -DLLVM_ENABLE_PIC=ON \
    \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_BUILD_LLVM_C_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    \
    -DLLVM_IR2VEC_ENABLE_PYTHON_BINDINGS=OFF

# --- Step 3: Build ---
echo ">>> Building LLVM libraries + LLVMEmbUtils ..."
cmake --build "$BUILD_DIR" -j "$JOBS"

# --- Step 4: Install ---
echo ">>> Installing LLVM to $INSTALL_DIR ..."
cmake --install "$BUILD_DIR"

# --- Step 5: Verify ---
echo ">>> Verifying install artifacts ..."

CORE_LIB=$(find "$INSTALL_DIR/lib" -name "libLLVMCore.a" 2>/dev/null | head -1)
if [ -z "$CORE_LIB" ]; then
    echo "ERROR: libLLVMCore.a not found in $INSTALL_DIR/lib/"
    exit 1
fi
echo "  Found: $CORE_LIB"

LLVM_CMAKE_CONFIG=$(find "$INSTALL_DIR" -name "LLVMConfig.cmake" 2>/dev/null | head -1)
if [ -z "$LLVM_CMAKE_CONFIG" ]; then
    echo "ERROR: LLVMConfig.cmake not found in $INSTALL_DIR"
    exit 1
fi
echo "  Found: $LLVM_CMAKE_CONFIG"

# LLVMEmbUtils is BUILDTREE_ONLY — intentionally not installed.
# Phase 2 compiles it from source (Utils.cpp) alongside the binding.
echo ""
echo "  Note: LLVMEmbUtils is BUILDTREE_ONLY and not in the install prefix."
echo "  Phase 2 will compile it from source (Utils.cpp) alongside the binding."

echo ""
echo "=== Phase 1 complete ==="
echo "Install prefix: $INSTALL_DIR"
echo "Next: run Phase 2 (build_binding.sh) for each Python version."