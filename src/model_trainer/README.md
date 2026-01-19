# model_trainer

Full fine-tuning for Qwen3-0.6B on JSONL chat data.

## Setup

```bash
cd /Users/minwei/code/Laika/src/model_trainer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Data format

Each line is a JSON object with chat `messages`:

```json
{"messages":[{"role":"system","content":"..."},
{"role":"user","content":"..."},
{"role":"assistant","content":"..."}]}
```

Alternative format (also supported):

```json
{"prompt":"...","response":"..."}
```

Reasoning datasets in `data/*_reasoning.jsonl` include a `<think>...</think>` block
before the JSON response in the assistant message.

## Train

Non-reasoning:

```bash
python train.py \
  --model-name Qwen/Qwen3-0.6B \
  --train-file data/train.jsonl \
  --eval-file data/test.jsonl \
  --output-dir Qwen3-0.6B-finetuned \
  --bf16
```

Reasoning:

```bash
python train.py \
  --model-name Qwen/Qwen3-0.6B \
  --train-file data/train_reasoning.jsonl \
  --eval-file data/test_reasoning.jsonl \
  --output-dir Qwen3-0.6B-finetuned-reasoning \
  --bf16 \
  --enable-thinking
```

## Outputs

- Fine-tuned model in the `--output-dir` you choose
- `training_stats.json` with merged train/eval metrics
- `train_results.json` and `eval_results.json` from the Trainer

## Notes

- Full fine-tuning is GPU-intensive. Expect to need a CUDA-capable GPU with enough VRAM.
- Use `--no-mask-user-tokens` if you want to train on all tokens instead of masking user/system turns.
