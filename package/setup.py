# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

import glob
from setuptools import setup
from setuptools.dist import Distribution


class BinaryDistribution(Distribution):
    """Mark this distribution as containing platform-specific binaries.

    This ensures that pip/setuptools produce a platform-tagged wheel
    (e.g., cp312-cp312-manylinux_2_28_x86_64) rather than a pure Python
    wheel (py3-none-any), even though we are not invoking a compiler
    during the pip install step. The native .so/.pyd is pre-built by
    build_binding.sh and placed into this directory before this runs.
    """

    def has_ext_modules(self):
        return True


setup(
    distclass=BinaryDistribution,
    packages=[""],
    package_data={
        "": [
            "*.so",       # Linux
            "*.pyd",      # Windows
            "*.dylib",    # macOS
        ],
    },
)