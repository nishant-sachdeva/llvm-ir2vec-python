#!/usr/bin/env bash
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Build a Python wheel from the ir2vec package directory (Phase 3).
#
# Prerequisites:
#   - build_binding.sh has placed the ir2vec .so in package/
#   - test_module.sh has verified the module imports correctly
#
# This script:
#   1. Validates the package directory structure
#   2. Builds a wheel using pip
#   3. Repairs the wheel for the target platform:
#      - Linux: auditwheel repair (produces manylinux_2_28 tag)
#      - macOS: delocate-wheel (bundles dylibs, fixes rpaths)
#      - Windows: no repair needed (or delvewheel if required)
#   4. Outputs the final wheel to a dist/ directory
#
# Usage: ./buildscripts/build_wheel.sh <python-executable> [package-dir] [output-dir]
#
# Arguments:
#   python-executable  - Python interpreter (must match the .so in package/)
#   package-dir        - Directory containing pyproject.toml and ir2vec .so
#                        (default: ./package)
#   output-dir         - Where to place the final repaired wheel
#                        (default: ./dist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_EXE="${1:?Usage: build_wheel.sh <python-executable> [package-dir] [output-dir]}"
PACKAGE_DIR="${2:-$REPO_ROOT/package}"
OUTPUT_DIR="${3:-$REPO_ROOT/dist}"

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

MODULE_FILE=$(find "$PACKAGE_DIR" -maxdepth 1 -name "ir2vec.cpython-*" -o -name "ir2vec*.pyd" 2>/dev/null | head -1)
if [ -z "$MODULE_FILE" ]; then
    echo "ERROR: No ir2vec native module (.so/.pyd) found in $PACKAGE_DIR"
    echo "Run build_binding.sh first."
    exit 1
fi
echo "  pyproject.toml: OK"
echo "  Native module:  $(basename "$MODULE_FILE")"

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

RAW_WHEEL=$(find "$WHEEL_TMPDIR" -name "ir2vec-*.whl" | head -1)
if [ -z "$RAW_WHEEL" ]; then
    echo "ERROR: Wheel build produced no .whl file"
    ls -la "$WHEEL_TMPDIR"
    exit 1
fi
echo "  Raw wheel: $(basename "$RAW_WHEEL")"

# --- Step 4: Repair the wheel for the target platform ---
mkdir -p "$OUTPUT_DIR"

OS="$(uname -s)"
case "$OS" in
    Linux)
        echo ">>> Repairing wheel with auditwheel ..."
        "$PYTHON_EXE" -m pip install auditwheel --quiet 2>/dev/null || {
            echo "ERROR: Could not install auditwheel"
            exit 1
        }

        # Detect the platform tag that auditwheel considers compatible.
        # In CI (manylinux container), this will be manylinux_2_28.
        # On a developer machine (e.g., Ubuntu 22.04), it will be higher
        # (e.g., manylinux_2_35). We use whatever auditwheel reports
        # rather than hardcoding, so the script works in both environments.
        echo "  auditwheel show:"
        "$PYTHON_EXE" -m auditwheel show "$RAW_WHEEL" || true

        DETECTED_PLAT=$("$PYTHON_EXE" -m auditwheel show "$RAW_WHEEL" 2>/dev/null \
            | grep -oP 'manylinux_\d+_\d+_\w+' | head -1 || true)

        if [ -z "$DETECTED_PLAT" ]; then
            echo "WARNING: Could not detect manylinux platform tag."
            echo "Copying wheel without auditwheel repair."
            cp "$RAW_WHEEL" "$OUTPUT_DIR/"
        else
            echo "  Detected platform: $DETECTED_PLAT"
            "$PYTHON_EXE" -m auditwheel repair "$RAW_WHEEL" \
                --plat "$DETECTED_PLAT" \
                -w "$OUTPUT_DIR"
        fi
        ;;
    Darwin)
        echo ">>> Repairing wheel with delocate ..."
        "$PYTHON_EXE" -m pip install delocate --quiet 2>/dev/null || {
            echo "ERROR: Could not install delocate"
            exit 1
        }

        "$PYTHON_EXE" -m delocate.cmd.delocate_wheel \
            -w "$OUTPUT_DIR" \
            "$RAW_WHEEL"
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        echo ">>> Windows: copying wheel as-is ..."
        # Windows wheels typically don't need repair if all deps are
        # statically linked. If needed, use delvewheel in the future.
        cp "$RAW_WHEEL" "$OUTPUT_DIR/"
        ;;
    *)
        echo "WARNING: Unknown OS '$OS', copying wheel without repair"
        cp "$RAW_WHEEL" "$OUTPUT_DIR/"
        ;;
esac

# Cleanup
rm -rf "$WHEEL_TMPDIR"

# --- Step 5: Report ---
FINAL_WHEEL=$(find "$OUTPUT_DIR" -name "ir2vec-*.whl" -newer "$PACKAGE_DIR/pyproject.toml" | sort | tail -1)
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