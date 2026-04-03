#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Verify that the built ir2vec nanobind module loads correctly.
#
# This script must pass before packaging a wheel. It ensures:
#   1. All runtime dependencies (numpy) are available
#   2. The .so imports without undefined symbol errors
#   3. LLVM was properly statically linked (no libLLVM*.so needed)
#
# Usage: ./buildscripts/test_module.sh <python-executable> <module-dir>
#
# Arguments:
#   python-executable  - The Python interpreter the module was built for
#   module-dir         - Directory containing the ir2vec.cpython-*.so file

set -euo pipefail

PYTHON_EXE="${1:?Usage: test_module.sh <python-executable> <module-dir>}"
MODULE_DIR="${2:?Usage: test_module.sh <python-executable> <module-dir>}"

PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Module Verification ==="
echo "Python     : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "Module dir : $MODULE_DIR"
echo "==================================="

# --- Check 1: Module file exists ---
echo ">>> Checking module file exists ..."
MODULE_FILE=$(find "$MODULE_DIR" -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)
if [ -z "$MODULE_FILE" ]; then
    echo "FAIL: No ir2vec module found in $MODULE_DIR"
    exit 1
fi
echo "  Found: $MODULE_FILE"

# --- Check 2: Runtime dependencies available ---
echo ">>> Checking runtime dependencies ..."
"$PYTHON_EXE" -m pip install numpy --quiet || {
    echo "FAIL: Could not install numpy"
    exit 1
}
echo "  numpy: OK"

# --- Check 3: Module imports successfully ---
echo ">>> Importing module ..."
"$PYTHON_EXE" -c "
import sys, os
sys.path.insert(0, '$MODULE_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('ir2vec', '$MODULE_FILE')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('  Import: OK')
print(f'  Module object: {mod}')
" || {
    echo ""
    echo "FAIL: Module import failed."
    echo ""
    echo "Common causes:"
    echo "  - Undefined symbols: LLVM was not fully statically linked."
    echo "    Check that Phase 1 used LLVM_LINK_LLVM_DYLIB=OFF."
    echo "  - Python version mismatch: the .so was built for a different"
    echo "    Python than the one being tested."
    echo "  - Missing dependencies: run ldd (Linux) or otool -L (macOS)"
    echo "    on the .so to see what it links against."
    echo ""
    echo "Debug with:"
    echo "  ldd $MODULE_FILE"
    echo "  $PYTHON_EXE -c \"import importlib.util; spec = importlib.util.spec_from_file_location('ir2vec', '$MODULE_FILE'); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)\""
    exit 1
}

# --- Check 4: No unexpected dynamic dependencies ---
echo ">>> Checking dynamic dependencies ..."
if command -v ldd &>/dev/null; then
    # Linux: check that we don't depend on libLLVM*.so
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
    # macOS: same check
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