# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

import glob
from setuptools import setup, find_packages
from setuptools.dist import Distribution


class BinaryDistribution(Distribution):
    """Mark this distribution as containing platform-specific binaries."""

    def has_ext_modules(self):
        return True


# Collect native module files (.so / .pyd / .dylib) in ir2vec/
native_extensions = (
    glob.glob("ir2vec/*.so")
    + glob.glob("ir2vec/*.pyd")
    + glob.glob("ir2vec/*.dylib")
)

if not native_extensions:
    import warnings

    warnings.warn(
        "No native module (.so/.pyd/.dylib) found in ir2vec/. "
        "The wheel will be missing the compiled bindings. "
        "Run buildscripts/build_binding.sh first.",
        stacklevel=1,
    )


setup(
    packages=find_packages(),
    package_data={
        "ir2vec": [
            # The pre-built nanobind .so/.pyd/.dylib
            "*.so",
            "*.pyd",
            "*.dylib",
        ],
        "ir2vec.vocab_data": [
            # Bundled vocabulary JSON files
            "*.json",
        ],
    },
    distclass=BinaryDistribution,
)