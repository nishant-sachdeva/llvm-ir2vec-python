# ir2vec-python

Build and distribution infrastructure for [IR2Vec](https://llvm.org/docs/MLGO.html#ir2vec) Python bindings.

IR2Vec is an LLVM IR embedding framework that generates vector representations
of LLVM IR for use in machine learning-based compiler optimization. This
repository automates building LLVM with IR2Vec enabled, compiling the Python
bindings, producing platform-specific wheels, and publishing them to PyPI.

For the source code of IR2Vec itself, see the
[LLVM monorepo](https://github.com/llvm/llvm-project/tree/main/llvm/tools/llvm-ir2vec).

## Installation
```bash
pip install ir2vec
```

## License

Apache License v2.0 with LLVM Exceptions. See [LICENSE.txt](LICENSE.txt) for details.