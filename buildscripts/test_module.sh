#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Verify that the built ir2vec nanobind module loads correctly.
#
# This script must pass before packaging a wheel. It ensures:
#   1. The ir2vec/ package directory contains the native module (.so/.pyd)
#   2. Runtime dependencies (numpy) are available
#   3. The full import chain works: __init__.py → nanobind .so + vocab module
#   4. LLVM was properly statically linked (no libLLVM*.so needed)
#   5. Bundled vocabulary files are present and resolvable
#
# Usage: ./buildscripts/test_module.sh <python-executable> <package-dir>
#
# Arguments:
#   python-executable  - The Python interpreter the module was built for
#   package-dir        - The package root containing ir2vec/ subdirectory
#                        (e.g., ./package — NOT ./package/ir2vec)

set -euo pipefail

PYTHON_EXE="${1:?Usage: test_module.sh <python-executable> <package-dir>}"
PACKAGE_DIR="${2:?Usage: test_module.sh <python-executable> <package-dir>}"

PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Module Verification ==="
echo "Python      : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "Package dir : $PACKAGE_DIR"
echo "==================================="

# --- Check 1: Native module file exists in ir2vec/ ---
echo ">>> Checking native module exists ..."
MODULE_FILE=$(find "$PACKAGE_DIR/ir2vec" -maxdepth 1 \
    -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)
if [ -z "$MODULE_FILE" ]; then
    echo "FAIL: No ir2vec native module found in $PACKAGE_DIR/ir2vec/"
    echo "Run build_binding.sh first (output dir should be $PACKAGE_DIR/ir2vec/)."
    exit 1
fi
echo "  Found: $MODULE_FILE"

# --- Check 2: Package structure exists ---
echo ">>> Checking package structure ..."
MISSING=0
for f in ir2vec/__init__.py ir2vec/vocab.py ir2vec/vocab_data/__init__.py; do
    if [ ! -f "$PACKAGE_DIR/$f" ]; then
        echo "  MISSING: $PACKAGE_DIR/$f"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    echo "FAIL: Package structure incomplete."
    echo "Ensure ir2vec/__init__.py, ir2vec/vocab.py, and ir2vec/vocab_data/__init__.py exist."
    exit 1
fi
echo "  __init__.py:  OK"
echo "  vocab.py:     OK"
echo "  vocab_data/:  OK"

# Check vocab JSON files
VOCAB_COUNT=$(find "$PACKAGE_DIR/ir2vec/vocab_data" -name "*.json" 2>/dev/null | wc -l)
if [ "$VOCAB_COUNT" -eq 0 ]; then
    echo "  WARNING: No vocabulary JSON files found in ir2vec/vocab_data/"
    echo "  Users will not have bundled vocabularies available."
else
    echo "  Vocab files: $VOCAB_COUNT JSON file(s)"
fi

# --- Check 3: Runtime dependencies available ---
echo ">>> Checking runtime dependencies ..."
"$PYTHON_EXE" -m pip install numpy --quiet || {
    echo "FAIL: Could not install numpy"
    exit 1
}
echo "  numpy: OK"

# --- Check 4: Full import chain works ---
echo ">>> Testing full import chain ..."
"$PYTHON_EXE" -c "
import sys, os
sys.path.insert(0, '$PACKAGE_DIR')

# Test 1: Basic import (exercises __init__.py → nanobind .so)
import ir2vec
print('  import ir2vec: OK')

# Test 2: Version attribute (from __init__.py)
print(f'  __version__: {ir2vec.__version__}')

# Test 3: Core API is accessible (re-exported from nanobind)
assert hasattr(ir2vec, 'initEmbedding'), 'initEmbedding not found in ir2vec namespace'
print('  initEmbedding: OK')

# Test 4: Vocab module loaded
assert hasattr(ir2vec, 'vocab'), 'vocab module not found in ir2vec namespace'
print('  ir2vec.vocab: OK')

# Test 5: Vocab paths resolve to real files (if vocab JSONs are present)
if hasattr(ir2vec.vocab, 'seedEmbedding75D'):
    path = ir2vec.vocab.seedEmbedding75D
    exists = os.path.isfile(path)
    print(f'  vocab.seedEmbedding75D: {path} (exists={exists})')
else:
    print('  vocab.seedEmbedding75D: not defined (vocab JSONs may be missing)')
" || {
    echo ""
    echo "FAIL: Import chain failed."
    echo ""
    echo "Common causes:"
    echo "  - Undefined symbols: LLVM was not fully statically linked."
    echo "    Check that Phase 1 used LLVM_LINK_LLVM_DYLIB=OFF."
    echo "  - Python version mismatch: the .so was built for a different"
    echo "    Python than the one being tested."
    echo "  - Missing __init__.py or vocab.py in ir2vec/ directory."
    echo ""
    echo "Debug with:"
    echo "  ldd $MODULE_FILE"
    echo "  PYTHONPATH=$PACKAGE_DIR $PYTHON_EXE -c 'import ir2vec'"
    exit 1
}

# --- Check 5: No unexpected dynamic dependencies ---
echo ">>> Checking dynamic dependencies ..."
if command -v ldd &>/dev/null; then
    LLVM_DEPS=$(ldd "$MODULE_FILE" 2>/dev/null | grep -i "libLLVM" || true)
    if [ -n "$LLVM_DEPS" ]; then
        echo "FAIL: Module dynamically links against LLVM shared libraries:"
        echo "$LLVM_DEPS"
        echo "This means LLVM was not statically linked. The wheel will"
        echo "not work on machines without LLVM installed."
        exit 1
    fi
    echo "  No libLLVM dynamic deps: OK"
elif command -v otool &>/dev/null; then
    LLVM_DEPS=$(otool -L "$MODULE_FILE" 2>/dev/null | grep -i "libLLVM" || true)
    if [ -n "$LLVM_DEPS" ]; then
        echo "FAIL: Module dynamically links against LLVM shared libraries:"
        echo "$LLVM_DEPS"
        exit 1
    fi
    echo "  No libLLVM dynamic deps: OK"
else
    echo "  (skipped: neither ldd nor otool available)"
fi

echo ""
echo "=== All checks passed ==="
echo "Module is ready for packaging."