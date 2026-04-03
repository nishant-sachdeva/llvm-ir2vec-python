<!--
Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
See https://llvm.org/LICENSE.txt for license information.
SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
-->

# ir2vec

Python bindings for [IR2Vec](https://llvm.org/docs/MLGO.html#ir2vec), an LLVM IR
embedding framework that generates vector representations of LLVM IR for use
in machine learning-based compiler optimization.

## Requirements

- Python >= 3.10
- NumPy

## Installation

```bash
pip install llvm-ir2vec
```

## Usage

```python
import ir2vec

emb = ir2vec.Embedder(
    filename="module.ll",
    mode="sym",
    vocab_path="/path/to/vocab.json",
)
embeddings = emb.getFuncEmbMap()
```
## Note on Package Naming

This package is published on testPyPI as `llvm-ir2vec` but the Python module
is imported as `ir2vec`:
```bash
pip install llvm-ir2vec
```
```python
import ir2vec
```

If you have another package installed that also provides an `ir2vec` module,
there may be a conflict. Uninstall the conflicting package before using this one.

## Source

This package is part of the LLVM Project:
https://github.com/llvm/llvm-project/tree/main/llvm/tools/llvm-ir2vec

## License

Apache License v2.0 with LLVM Exceptions.
See https://llvm.org/LICENSE.txt for details.