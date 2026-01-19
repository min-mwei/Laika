# model_playground (Laika MLX POC)

Python proof-of-concept that emulates Laika's tool-calling loop with a local Qwen3 MLX 4-bit model. It:

- loads a converted Qwen3 MLX model,
- fetches pages without cookies,
- extracts sanitized text + element handles,
- asks the model to emit JSON tool calls (per `docs/llm_tools.md`),
- executes tools and re-observes until the model returns a final summary.

## Setup

Convert the model to MLX 4-bit first:

```bash
cd src/local_llm_quantizer
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python convert_qwen3_to_mlx_4bit.py --out-dir ./Qwen3-0.6B-MLX-4bit
```

Install the POC dependencies (Apple Silicon required for MLX):

```bash
cd src/model_playground
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python laika_poc.py \
  --url https://news.ycombinator.com \
  --prompt "What is this page about?"
```

If you stored the MLX model elsewhere, pass `--model-dir /path/to/Qwen3-0.6B-MLX-4bit`.

Comet-style run (higher budgets + thinking enabled):

```bash
python laika_poc.py \
  --url https://news.ycombinator.com \
  --prompt "Tell me about the first topic." \
  --comet-mode
```

When `--comet-mode` is enabled, the POC will fall back to a structured summary builder if the model ignores the requested headings.

Interactive loop:

```bash
python laika_poc.py \
  --url https://news.ycombinator.com \
  --interactive
```

Example 2 (from `docs/llm_tools.md`):

```text
User> What is this page about?
User> Tell me about the first topic.
```

Notes:

- The POC never sends raw HTML to the model; it only sends extracted text, titles, and link metadata.
- Qwen3 can emit `<think>...</think>` blocks; the parser strips them before JSON parsing.
- On Hacker News front pages, the POC extracts a topic list (title, url, commentsUrl, points, comments) to resolve "first topic" and comment requests.
- On Hacker News item pages, the POC extracts comment threads (author, age, points, indent) and feeds them into the prompt for deeper summaries.
- To try larger Qwen models, pass a different `--model-dir` pointing at a converted MLX model (for example, Qwen3-4B).
