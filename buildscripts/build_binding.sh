#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build the IR2Vec nanobind Python module (Phase 2).
#
# Builds a standalone CMake project against a pre-installed LLVM prefix
# from Phase 1. Compiles only 2 files:
#   1. Utils.cpp    → LLVMEmbUtils (ir2vec utility library, BUILDTREE_ONLY upstream)
#   2. PyIR2Vec.cpp → ir2vec nanobind module
#
# Total compile time: ~30 seconds (2 files + 1 link step).
# No LLVM objects are recompiled.
#
# Usage: ./buildscripts/build_binding.sh <python-exe> <llvm-install> <llvm-source> [output-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_EXE="${1:?Usage: build_binding.sh <python-exe> <llvm-install> <llvm-source> [output-dir]}"
LLVM_INSTALL_DIR="${2:?Usage: build_binding.sh <python-exe> <llvm-install> <llvm-source> [output-dir]}"
LLVM_SRC_DIR="${3:?Usage: build_binding.sh <python-exe> <llvm-install> <llvm-source> [output-dir]}"
OUTPUT_DIR="${4:-$REPO_ROOT/package}"
BUILD_DIR="$REPO_ROOT/build-binding"

PYTHON_EXE="$(readlink -f "$(command -v "$PYTHON_EXE")" 2>/dev/null || echo "$PYTHON_EXE")"

# --- Validate inputs ---
if ! command -v "$PYTHON_EXE" &>/dev/null; then
    echo "ERROR: Python executable not found: $PYTHON_EXE"
    exit 1
fi

LLVM_INSTALL_DIR="$(cd "$LLVM_INSTALL_DIR" && pwd)"

# Find LLVMConfig.cmake
LLVM_CMAKE_DIR=""
for candidate in \
    "$LLVM_INSTALL_DIR/lib/cmake/llvm" \
    "$LLVM_INSTALL_DIR/lib64/cmake/llvm" \
    "$LLVM_INSTALL_DIR/share/llvm/cmake"; do
    if [ -f "$candidate/LLVMConfig.cmake" ]; then
        LLVM_CMAKE_DIR="$candidate"
        break
    fi
done
if [ -z "$LLVM_CMAKE_DIR" ]; then
    echo "ERROR: LLVMConfig.cmake not found in $LLVM_INSTALL_DIR"
    echo "Expected at: $LLVM_INSTALL_DIR/lib/cmake/llvm/LLVMConfig.cmake"
    echo "Run build_llvm.sh (Phase 1) first."
    exit 1
fi

# Find ir2vec source directory
IR2VEC_SRC=""
for candidate in \
    "$LLVM_SRC_DIR/llvm/tools/llvm-ir2vec" \
    "$LLVM_SRC_DIR/tools/llvm-ir2vec"; do
    if [ -d "$candidate" ] && [ -f "$candidate/CMakeLists.txt" ]; then
        IR2VEC_SRC="$(cd "$candidate" && pwd)"
        break
    fi
done
if [ -z "$IR2VEC_SRC" ]; then
    echo "ERROR: llvm-ir2vec source not found in $LLVM_SRC_DIR"
    exit 1
fi

# Verify the specific source files we need
if [ ! -f "$IR2VEC_SRC/lib/Utils.cpp" ]; then
    echo "ERROR: $IR2VEC_SRC/lib/Utils.cpp not found"
    exit 1
fi
BINDING_CPP=""
for candidate in \
    "$IR2VEC_SRC/Bindings/PyIR2Vec.cpp" \
    "$IR2VEC_SRC/bindings/PyIR2Vec.cpp"; do
    if [ -f "$candidate" ]; then
        BINDING_CPP="$candidate"
        break
    fi
done
if [ -z "$BINDING_CPP" ]; then
    echo "ERROR: PyIR2Vec.cpp not found in $IR2VEC_SRC/Bindings/"
    exit 1
fi

PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Binding Build (Phase 2) ==="
echo "Python        : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "LLVM install  : $LLVM_INSTALL_DIR"
echo "LLVM cmake    : $LLVM_CMAKE_DIR"
echo "IR2Vec source : $IR2VEC_SRC"
echo "Binding source: $BINDING_CPP"
echo "Build dir     : $BUILD_DIR"
echo "Output dir    : $OUTPUT_DIR"
echo "======================================="

# --- Step 1: Ensure nanobind is installed ---
echo ">>> Ensuring nanobind is installed ..."
"$PYTHON_EXE" -m pip install nanobind --quiet 2>/dev/null || {
    echo "ERROR: Failed to install nanobind for $PYTHON_EXE"
    exit 1
}

NANOBIND_CMAKE_DIR=$("$PYTHON_EXE" -m nanobind --cmake_dir 2>/dev/null) || {
    echo "ERROR: nanobind installed but --cmake_dir failed"
    exit 1
}
echo "  nanobind cmake dir: $NANOBIND_CMAKE_DIR"

# --- Step 2: Generate standalone CMakeLists.txt ---
#
# Replicates the upstream build of:
#   lib/CMakeLists.txt    → add_llvm_library(LLVMEmbUtils STATIC Utils.cpp
#                             BUILDTREE_ONLY LINK_COMPONENTS Analysis CodeGen Core Support Target)
#   Bindings/CMakeLists.txt → nanobind_add_module(ir2vec ...) + link LLVMEmbUtils
#
# Uses find_package(LLVM) + llvm_map_components_to_libnames() to resolve
# the same component list into the installed .a libraries.

echo ">>> Generating standalone CMakeLists.txt ..."
mkdir -p "$BUILD_DIR"

cat > "$BUILD_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.20)
project(ir2vec-binding LANGUAGES CXX)

# --- Find pre-installed LLVM ---
find_package(LLVM REQUIRED CONFIG)
message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
message(STATUS "LLVM install prefix: ${LLVM_INSTALL_PREFIX}")

list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include(AddLLVM)
include(HandleLLVMOptions)

# Guard: the .a libraries must have been built with PIC for shared linking
if(NOT LLVM_ENABLE_PIC)
  message(FATAL_ERROR
    "Python bindings require LLVM_ENABLE_PIC=ON. "
    "Rebuild LLVM (Phase 1) with -DLLVM_ENABLE_PIC=ON")
endif()

include_directories(${LLVM_INCLUDE_DIRS})
separate_arguments(LLVM_DEFINITIONS_LIST NATIVE_COMMAND "${LLVM_DEFINITIONS}")
add_definitions(${LLVM_DEFINITIONS_LIST})

# --- Resolve LLVM component libraries ---
# Same LINK_COMPONENTS as upstream lib/CMakeLists.txt
llvm_map_components_to_libnames(EMBUTILS_LLVM_LIBS
  Analysis
  CodeGen
  Core
  Support
  Target
)
message(STATUS "LLVMEmbUtils LLVM deps: ${EMBUTILS_LLVM_LIBS}")

# --- Build LLVMEmbUtils as a static library ---
# Upstream uses add_llvm_library(... BUILDTREE_ONLY) which is not usable
# outside the LLVM build tree. We replicate it as a plain static library.
add_library(LLVMEmbUtils STATIC
  ${IR2VEC_SOURCE_DIR}/lib/Utils.cpp
)

target_include_directories(LLVMEmbUtils PRIVATE
  ${IR2VEC_SOURCE_DIR}/lib
  ${IR2VEC_SOURCE_DIR}
  ${LLVM_INCLUDE_DIRS}
)

# LLVM is compiled with -fno-exceptions -fno-rtti via HandleLLVMOptions.
# LLVMEmbUtils is LLVM code, so it must match. The global flags from
# HandleLLVMOptions already set this, but we make it explicit.
if(NOT MSVC)
  target_compile_options(LLVMEmbUtils PRIVATE -fno-exceptions -fno-rtti)
endif()
target_compile_features(LLVMEmbUtils PRIVATE cxx_std_17)

target_link_libraries(LLVMEmbUtils PUBLIC ${EMBUTILS_LLVM_LIBS})

# --- Find nanobind and Python ---
find_package(nanobind CONFIG REQUIRED)
find_package(Python ${BINDINGS_MINIMUM_PYTHON_VERSION}
  COMPONENTS Interpreter Development.Module REQUIRED)

# --- Build the nanobind module ---
nanobind_add_module(ir2vec MODULE
  ${IR2VEC_BINDING_SOURCE}
)

# Python bindings need exceptions and RTTI to convert C++ exceptions
# to Python exceptions. These target-level flags override the global
# -fno-exceptions/-fno-rtti from HandleLLVMOptions for this target only.
# This follows the MLIR Python bindings pattern.
if(NOT MSVC)
  target_compile_options(ir2vec PRIVATE -fexceptions -frtti)
endif()
target_compile_features(ir2vec PRIVATE cxx_std_17)

target_link_libraries(ir2vec PRIVATE LLVMEmbUtils)

# The upstream Bindings/CMakeLists.txt does:
#   target_include_directories(ir2vec PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/..)
# which is the llvm-ir2vec/ root. PyIR2Vec.cpp may include headers as
# "lib/Utils.h" (relative to root) or "Utils.h" (from lib/ directly).
# We add both to cover either pattern.
target_include_directories(ir2vec PRIVATE
  ${IR2VEC_SOURCE_DIR}
  ${IR2VEC_SOURCE_DIR}/lib
  ${LLVM_INCLUDE_DIRS}
)

message(STATUS "Will build: LLVMEmbUtils (1 file) + ir2vec nanobind module (1 file)")
EOF

# --- Step 3: Configure ---
echo ">>> Configuring binding build ..."
cmake -G Ninja -S "$BUILD_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_DIR="$LLVM_CMAKE_DIR" \
    -DIR2VEC_SOURCE_DIR="$IR2VEC_SRC" \
    -DIR2VEC_BINDING_SOURCE="$BINDING_CPP" \
    -DBINDINGS_MINIMUM_PYTHON_VERSION="3.10" \
    -DPython_EXECUTABLE="$PYTHON_EXE" \
    -DPython3_EXECUTABLE="$PYTHON_EXE" \
    -Dnanobind_DIR="$NANOBIND_CMAKE_DIR"

# --- Step 4: Build ---
echo ">>> Building nanobind module ..."
cmake --build "$BUILD_DIR" --target ir2vec \
    -j "$(nproc 2>/dev/null || echo 4)"

# --- Step 5: Find and copy the built module ---
echo ">>> Locating built module ..."

MODULE_FILE=$(find "$BUILD_DIR" -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)

if [ -z "$MODULE_FILE" ]; then
    echo "ERROR: Built nanobind module not found in $BUILD_DIR"
    echo ""
    echo "Files in build dir:"
    find "$BUILD_DIR" -name "*.so" -o -name "*.pyd" -o -name "*.dylib" 2>/dev/null || true
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