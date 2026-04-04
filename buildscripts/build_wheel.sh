#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build a Python wheel from the ir2vec package directory (Phase 3).
#
# Prerequisites:
#   - build_binding.sh has placed the ir2vec .so in package/ir2vec/
#   - test_module.sh has verified the module imports correctly
#   - package/ir2vec/ contains __init__.py, vocab.py, and vocab_data/
#
# This script:
#   1. Validates the package directory structure (including vocab data)
#   2. Builds a wheel using pip
#   3. Repairs the wheel with auditwheel (manylinux tag from MANYLINUX_PLAT)
#   4. Outputs the final wheel to a dist/ directory
#
# Usage: ./buildscripts/build_wheel.sh <python-executable> [package-dir] [output-dir]
#
# Environment variables:
#   MANYLINUX_PLAT  - Override the manylinux platform tag (e.g., manylinux_2_28_x86_64).
#                     In CI (manylinux containers), set this explicitly.
#                     If unset, auto-detects from auditwheel show.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_EXE="${1:?Usage: build_wheel.sh <python-executable> [package-dir] [output-dir]}"
PACKAGE_DIR="${2:-$REPO_ROOT/package}"
OUTPUT_DIR="${3:-$REPO_ROOT/dist}"

PYTHON_EXE="$(readlink -f "$(command -v "$PYTHON_EXE")" 2>/dev/null || echo "$PYTHON_EXE")"
PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "=== IR2Vec Wheel Build (Phase 3) ==="
echo "Python      : $("$PYTHON_EXE" --version 2>&1) ($PYTHON_EXE)"
echo "Package dir : $PACKAGE_DIR"
echo "Output dir  : $OUTPUT_DIR"
echo "======================================"

# --- Step 1: Validate package structure ---
echo ">>> Validating package structure ..."

if [ ! -f "$PACKAGE_DIR/pyproject.toml" ]; then
    echo "ERROR: pyproject.toml not found in $PACKAGE_DIR"
    exit 1
fi
echo "  pyproject.toml: OK"

# Check native module exists in ir2vec/ subdirectory
MODULE_FILE=$(find "$PACKAGE_DIR/ir2vec" -maxdepth 1 \
    -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)
if [ -z "$MODULE_FILE" ]; then
    echo "ERROR: No ir2vec native module (.so/.pyd) found in $PACKAGE_DIR/ir2vec/"
    echo "Run build_binding.sh first (output dir should be $PACKAGE_DIR/ir2vec/)."
    exit 1
fi
echo "  Native module:  $(basename "$MODULE_FILE")"

# Check Python package files
for f in ir2vec/__init__.py ir2vec/vocab.py ir2vec/vocab_data/__init__.py; do
    if [ ! -f "$PACKAGE_DIR/$f" ]; then
        echo "ERROR: $f not found in $PACKAGE_DIR"
        echo "Ensure the ir2vec package directory is properly set up."
        exit 1
    fi
done
echo "  __init__.py:    OK"
echo "  vocab.py:       OK"
echo "  vocab_data/:    OK"

# Check vocab JSON files
VOCAB_COUNT=$(find "$PACKAGE_DIR/ir2vec/vocab_data" -name "*.json" 2>/dev/null | wc -l)
if [ "$VOCAB_COUNT" -eq 0 ]; then
    echo "WARNING: No vocabulary JSON files in ir2vec/vocab_data/"
    echo "The wheel will not include bundled vocabularies."
else
    echo "  Vocab files:    $VOCAB_COUNT JSON file(s)"
fi

# --- Step 2: Install build tools ---
echo ">>> Installing build tools ..."
"$PYTHON_EXE" -m pip install --upgrade pip setuptools wheel --quiet

# --- Step 3: Build the wheel ---
echo ">>> Building wheel ..."
WHEEL_TMPDIR=$(mktemp -d)
"$PYTHON_EXE" -m pip wheel "$PACKAGE_DIR" \
    --no-build-isolation \
    --no-deps \
    --no-cache-dir \
    -w "$WHEEL_TMPDIR"

RAW_WHEEL=$(find "$WHEEL_TMPDIR" -name "*.whl" | head -1)
if [ -z "$RAW_WHEEL" ]; then
    echo "ERROR: Wheel build produced no .whl file"
    ls -la "$WHEEL_TMPDIR"
    exit 1
fi
echo "  Raw wheel: $(basename "$RAW_WHEEL")"

# Quick sanity: verify the vocab files are inside the wheel
echo ">>> Verifying wheel contents ..."
if ! unzip -l "$RAW_WHEEL" | grep -q "vocab_data/.*\.json"; then
    echo "WARNING: Vocabulary JSON files not found inside the wheel."
    echo "Check that setup.py includes package_data for ir2vec.vocab_data."
fi
if ! unzip -l "$RAW_WHEEL" | grep -q "ir2vec/__init__.py"; then
    echo "ERROR: ir2vec/__init__.py not found inside the wheel."
    echo "The wheel is missing the Python package. Check pyproject.toml and setup.py."
    echo ""
    echo "Wheel contents:"
    unzip -l "$RAW_WHEEL"
    exit 1
fi
echo "  Wheel contents: OK"

# --- Step 4: Repair the wheel with auditwheel ---
mkdir -p "$OUTPUT_DIR"

echo ">>> Repairing wheel with auditwheel ..."
"$PYTHON_EXE" -m pip install auditwheel --quiet 2>/dev/null || {
    echo "ERROR: Could not install auditwheel"
    exit 1
}

# Show wheel analysis
echo "  auditwheel show:"
"$PYTHON_EXE" -m auditwheel show "$RAW_WHEEL" || true

# Determine platform tag:
#   - CI sets MANYLINUX_PLAT explicitly (e.g., manylinux_2_28_x86_64)
#   - Local builds auto-detect from auditwheel show
if [ -n "${MANYLINUX_PLAT:-}" ]; then
    PLAT="$MANYLINUX_PLAT"
    echo "  Using MANYLINUX_PLAT from environment: $PLAT"
else
    PLAT=$("$PYTHON_EXE" -m auditwheel show "$RAW_WHEEL" 2>/dev/null \
        | grep -oP 'manylinux_\d+_\d+_\w+' | head -1 || true)
    if [ -z "$PLAT" ]; then
        echo "WARNING: Could not detect manylinux platform tag."
        echo "Copying wheel without auditwheel repair."
        cp "$RAW_WHEEL" "$OUTPUT_DIR/"
        rm -rf "$WHEEL_TMPDIR"
        FINAL_WHEEL=$(find "$OUTPUT_DIR" -name "*.whl" | sort | tail -1)
        echo ""
        echo "=== Phase 3 complete (unrepaired) ==="
        echo "Wheel: $FINAL_WHEEL"
        exit 0
    fi
    echo "  Auto-detected platform: $PLAT"
fi

"$PYTHON_EXE" -m auditwheel repair "$RAW_WHEEL" \
    --plat "$PLAT" \
    -w "$OUTPUT_DIR"

# Cleanup
rm -rf "$WHEEL_TMPDIR"

# --- Step 5: Report ---
FINAL_WHEEL=$(find "$OUTPUT_DIR" -name "*.whl" | sort | tail -1)
if [ -z "$FINAL_WHEEL" ]; then
    echo "ERROR: No final wheel found in $OUTPUT_DIR"
    exit 1
fi

echo ""
echo "=== Phase 3 complete ==="
echo "Wheel: $FINAL_WHEEL"
echo "Size:  $(du -h "$FINAL_WHEEL" | cut -f1)"
echo ""
echo "To inspect:  unzip -l $FINAL_WHEEL"
echo "To install:  pip install $FINAL_WHEEL"
echo "To publish:  twine upload --repository testpypi $FINAL_WHEEL"