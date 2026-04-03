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
pip install ir2vec
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

## Source

This package is part of the LLVM Project:
https://github.com/llvm/llvm-project/tree/main/llvm/tools/llvm-ir2vec

## License

Apache License v2.0 with LLVM Exceptions.
See https://llvm.org/LICENSE.txt for details.