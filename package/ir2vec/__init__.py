# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

"""IR2Vec: LLVM IR Embedding Framework.

Python bindings for IR2Vec, which generates vector representations of
LLVM IR for use in machine learning-based compiler optimization.

Example usage::

    import ir2vec

    # Use a bundled vocabulary (no manual file management needed):
    tool = ir2vec.initEmbedding(
        filename="module.ll",
        mode="sym",
        vocabPath=ir2vec.vocab.seedEmbedding75D,
    )

    embeddings = tool.getFuncEmbMap()
"""

try:
    from importlib.metadata import version as _get_version
    __version__ = _get_version("llvm-ir2vec")
except Exception:
    # Package not installed (e.g., running from source tree or during testing).
    # Fall back to a default; build_wheel.sh stamps the real version into
    # pyproject.toml from PACKAGE_VERSION before building the wheel.
    __version__ = "0.0.0.dev"

# Re-export everything from the nanobind C++ module so users can write
# ir2vec.initEmbedding(...) etc. directly.
try:
    from ir2vec.ir2vec import *  # noqa: F401, F403
except ImportError as e:
    import sys

    raise ImportError(
        f"Failed to import the IR2Vec native module.\n"
        f"\n"
        f"This usually means one of:\n"
        f"  1. The package was not installed correctly (missing .so/.pyd)\n"
        f"  2. Python version mismatch (built for a different Python)\n"
        f"  3. Platform mismatch (built for a different OS/architecture)\n"
        f"\n"
        f"Your Python: {sys.version}\n"
        f"Your platform: {sys.platform}\n"
        f"\n"
        f"Original error: {e}"
    ) from e

# Make the vocab module available as ir2vec.vocab
from ir2vec import vocab  # noqa: E402, F401