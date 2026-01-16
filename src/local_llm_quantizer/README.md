# local_llm_quantizer

Utilities for converting/quantizing Hugging Face LLMs for on-device inference.

This folder currently focuses on converting Qwen3-0.6B into the MLX 4-bit format
used by `mlx_lm`.

## Requirements

- macOS on Apple Silicon (MLX only runs on macOS/arm64).
- Python 3.10+ (examples use 3.12).
- Disk space for the source model cache and output directory.

## Qwen3-0.6B → MLX 4-bit

This repo includes a small Python CLI that converts `Qwen/Qwen3-0.6B` into an MLX 4-bit model directory compatible with `mlx_lm.load()`.

### Setup

```bash
cd src/local_llm_quantizer
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Optional faster downloads (Hugging Face):

```bash
pip install hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
```

### Convert (quickstart)

```bash
python convert_qwen3_to_mlx_4bit.py --out-dir ./Qwen3-0.6B-MLX-4bit
```

### CLI reference

Key options for `convert_qwen3_to_mlx_4bit.py`:

- `--hf-model` (default: `Qwen/Qwen3-0.6B`): HF model id or local path.
- `--revision`: HF revision (branch/tag/commit).
- `--out-dir`: output directory (must not exist unless `--overwrite`).
- `--overwrite`: delete `--out-dir` first.
- `--bits` (default: 4): quantization bits.
- `--group-size` (default: 128): quantization group size.
- `--q-mode` (default: `affine`): MLX quantization mode.
- `--dtype`: dtype for non-quantized parameters (`float16`, `bfloat16`, `float32`).
- `--upload-repo`: upload the converted model to HF.
- `--hf-transfer`: enable `hf_transfer` for faster downloads.
- `--allow-non-apple-silicon`: bypass the Apple Silicon check (conversion still requires MLX).

### Use the converted model

```python
from mlx_lm import load, generate

model, tokenizer = load("./Qwen3-0.6B-MLX-4bit")
print(generate(model, tokenizer, prompt="Hello world!", max_tokens=64))
```

### Smoke test

```bash
python smoke_test_mlx_model.py --model-dir ./Qwen3-0.6B-MLX-4bit
```

By default this runs a small suite (hello, exact-text, JSON, single-word).

Single-prompt mode:

```bash
python smoke_test_mlx_model.py --mode single --model-dir ./Qwen3-0.6B-MLX-4bit --prompt "Hello!"
```

## Output layout

The converter writes a self-contained MLX model directory that looks like:

- `model.safetensors` + `model.safetensors.index.json`
- `config.json`
- `tokenizer.json` + `tokenizer_config.json`
- `generation_config.json`
- `chat_template.jinja`
- optional: `LICENSE`, `vocab.json`, `merges.txt`

## Troubleshooting

- `KeyError: 'qwen3'` in Transformers: update `transformers` and `mlx_lm`.
- Conversion fails on Intel macs: MLX requires Apple Silicon.
- Slow downloads: set `HF_HOME` to a fast disk and use `hf_transfer`.
