# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

"""Built-in vocabulary files shipped with the ir2vec package.

Each attribute is a string path to the corresponding JSON vocabulary file
bundled inside the installed wheel. These can be passed directly to
``ir2vec.initEmbedding(vocabPath=...)``.

Example usage::

    import ir2vec

    tool = ir2vec.initEmbedding(
        filename="module.ll",
        mode="sym",
        vocabPath=ir2vec.vocab.seedEmbedding75D,
    )

Available vocabularies:

- ``ir2vec.vocab.seedEmbedding75D``  — 75-dimensional seed embeddings
- ``ir2vec.vocab.seedEmbedding100D`` — 100-dimensional seed embeddings
- ``ir2vec.vocab.seedEmbedding300D`` — 300-dimensional seed embeddings
"""

import importlib.resources as _resources


def _resolve(filename: str) -> str:
    """Return the filesystem path to a bundled vocab file.

    Uses importlib.resources to locate the file inside the installed
    package, which works correctly regardless of how the package was
    installed (wheel, editable, zip, etc.).

    On Python 3.9+ this uses the modern ``files()`` API.  The returned
    path is stable for the lifetime of the process.
    """
    # importlib.resources.files() returns a Traversable.
    # .joinpath(filename) locates the file inside the ir2vec.vocab_data package.
    # str() gives us the filesystem path.
    #
    # For installed wheels the files are already extracted on disk, so
    # str() returns a real path directly.  For zipped installs,
    # importlib may extract to a temporary location — but that's handled
    # transparently.
    ref = _resources.files("ir2vec.vocab_data").joinpath(filename)

    # as_posix() / __fspath__ may not exist on all Traversable impls,
    # so we go through the context manager to guarantee a real path.
    # However, for wheels-on-disk (our case) str() is sufficient and
    # avoids the context-manager lifecycle issue.
    path = str(ref)
    return path


# ------------------------------------------------------------------
# Public attributes — each is a string path to a vocab JSON file.
# Users pass these directly to initEmbedding(vocabPath=...).
# ------------------------------------------------------------------

seedEmbedding75D:  str = _resolve("seedEmbeddingVocab75D.json")
seedEmbedding100D: str = _resolve("seedEmbeddingVocab100D.json")
seedEmbedding300D: str = _resolve("seedEmbeddingVocab300D.json")