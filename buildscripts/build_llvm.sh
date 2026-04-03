#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build LLVM with IR2Vec support (Phase 1).
# Produces static libraries that Phase 2 links into per-Python-version wheels.
#
# This script builds all LLVM static libraries plus LLVMEmbUtils. We build
# all libraries (rather than cherry-picking targets) because:
#   - LLVMEmbUtils depends on Analysis, CodeGen, Core, Support, Target
#   - Each of those has deep transitive deps (e.g., CodeGen -> MC, SelectionDAG,
#     Target -> TargetParser, etc.)
#   - With LLVM_BUILD_TOOLS=OFF and LLVM_ENABLE_PROJECTS="", building "all"
#     only produces static libraries (~15-20 min), not executables
#   - This is more robust than enumerating every transitive dependency
#
# The nanobind Python module is NOT built here — that happens in Phase 2
# (per Python version). We set LLVM_IR2VEC_ENABLE_PYTHON_BINDINGS=OFF but
# still need the ir2vec source tree present so that LLVMEmbUtils is found
# by CMake (it lives in llvm/tools/llvm-ir2vec/lib/).
#
# Usage: ./buildscripts/build_llvm.sh [llvm-project-dir] [build-dir]
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

TARGETS="${LLVM_TARGETS_TO_BUILD:-host}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
JOBS="${PARALLEL_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "=== IR2Vec LLVM Build (Phase 1) ==="
echo "LLVM version : $LLVM_VERSION"
echo "Source dir    : $LLVM_SRC_DIR"
echo "Build dir     : $BUILD_DIR"
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
# Key decisions documented inline:
#
# LLVM_ENABLE_PIC=ON
#   Required. The static .a libraries will be linked into a shared .so
#   (the nanobind module). Without PIC, the linker will fail with
#   "relocation R_X86_64_32 against `.rodata' can not be used when
#   making a shared object".
#
# LLVM_BUILD_TOOLS=OFF
#   We don't need llvm-as, llc, opt, etc. in the wheel. This is the
#   single biggest time saver — skips building ~40 executables.
#   NOTE: This also prevents the llvm-ir2vec executable from building,
#   but that's fine — we only need LLVMEmbUtils (the library).
#
# LLVM_TARGETS_TO_BUILD=host
#   Only build codegen for the host architecture. For MIR mode support,
#   users would need the target their IR was compiled for. "host" covers
#   the common case (analyzing IR from the same machine). We can expand
#   this later (e.g., "X86;AArch64;RISCV") at the cost of larger wheels.
#
# All optional dependencies OFF
#   zlib, zstd, terminfo, libxml2, libedit — none of these are needed
#   for IR2Vec embeddings. Disabling them means the resulting .so has
#   no dynamic dependencies beyond libc/libstdc++/libm, which makes
#   auditwheel happy.
#
# LLVM_IR2VEC_ENABLE_PYTHON_BINDINGS=OFF
#   The nanobind module is built in Phase 2 (per Python version).
#   We only build the LLVM libraries and LLVMEmbUtils here.

echo ">>> Configuring LLVM ..."
cmake -G Ninja -S "$LLVM_SRC_DIR/llvm" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
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
# Build everything. With TOOLS=OFF and PROJECTS="", "all" means:
#   - intrinsics_gen (TableGen: generates Intrinsics*.inc headers)
#   - All LLVM static libraries (Core, Analysis, CodeGen, MC, Target, ...)
#   - LLVMEmbUtils (the IR2Vec utility library, from llvm/tools/llvm-ir2vec/lib/)
#
# This does NOT build any executables (tools are off), so it's faster
# than a full LLVM build. Typical time: 15-25 min on a 4-core CI runner.
echo ">>> Building LLVM libraries + LLVMEmbUtils ..."
cmake --build "$BUILD_DIR" -j "$JOBS"

# --- Step 4: Verify ---
# Sanity check that the critical artifacts exist.
echo ">>> Verifying build artifacts ..."

# LLVMEmbUtils should be in lib/
EMBUTILS_LIB=$(find "$BUILD_DIR/lib" -name "libLLVMEmbUtils.a" -o -name "LLVMEmbUtils.lib" 2>/dev/null | head -1)
if [ -z "$EMBUTILS_LIB" ]; then
    echo "ERROR: libLLVMEmbUtils.a not found in $BUILD_DIR/lib/"
    echo "Build may have failed or llvm-ir2vec source not found in tree."
    exit 1
fi
echo "  Found: $EMBUTILS_LIB"

# LLVMCore should also exist (sanity check for LLVM libraries)
CORE_LIB=$(find "$BUILD_DIR/lib" -name "libLLVMCore.a" -o -name "LLVMCore.lib" 2>/dev/null | head -1)
if [ -z "$CORE_LIB" ]; then
    echo "ERROR: libLLVMCore.a not found in $BUILD_DIR/lib/"
    exit 1
fi
echo "  Found: $CORE_LIB"

echo ""
echo "=== Phase 1 complete ==="
echo "Build artifacts in: $BUILD_DIR"
echo "Next: run Phase 2 (build_binding.sh) for each Python version."