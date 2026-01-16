# model_playground (AI21-Jamba2-3B hello world)

Minimal Python "hello world" for `ai21labs/AI21-Jamba2-3B` using Hugging Face Transformers, with Apple Silicon (MPS) support.

## Setup

```bash
cd src/model_playground
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python hello_world.py
```

Apple Silicon (MPS):

```bash
python hello_world.py --device mps
```

This model uses Mamba layers. On non-CUDA devices (MPS/CPU), Transformers must use the naive Mamba implementation (`use_mamba_kernels=False`); `hello_world.py` applies this automatically. You can force it explicitly with `--no-mamba-kernels`.

If you hit an MPS kernel error, enable CPU fallback for unsupported ops:

```bash
PYTORCH_ENABLE_MPS_FALLBACK=1 python hello_world.py --device mps
```

## Notes on performance

- The model card recommends CUDA-focused speedups (`flash-attn`, `mamba-ssm`, `causal-conv1d`); these are typically unavailable on macOS/MPS. This sample aims to run with stock PyTorch+Transformers.
- For faster startup, set `HF_HOME` to a fast disk and keep the model cached.
