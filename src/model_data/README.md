# model_data

Generate JSONL training data for `src/model_trainer` using OpenAI GPT-5.2 models (default model: `gpt-5.2-high`).
This project builds a sanitized page snapshot (no raw HTML, no cookies) and asks the model to
produce a plan plus tool-call JSON. The output is split into train/test and written to
`src/model_trainer/data` by default.

The OpenAI client code is reused from `src/openai_model`. Auth is read from environment variables
or `~/.codex/auth.json`; it is never copied into this repo.

## Setup

```bash
cd /Users/minwei/code/Laika/src/model_data
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python generate_dataset.py \
  --model gpt-5.2-high \
  --output-dir /Users/minwei/code/Laika/src/model_trainer/data
```

If auth resolves to a ChatGPT session (from `~/.codex/auth.json`), the script will
automatically switch to the ChatGPT Codex backend and map GPT-5.2 variants to `gpt-5.2-codex`.
To force the OpenAI API backend instead, pass a base URL explicitly:

```bash
python generate_dataset.py \
  --model gpt-5.2-high \
  --base-url https://api.openai.com/v1
```

Optional flags:

```bash
python generate_dataset.py \
  --urls-file seed_sites.json \
  --questions-file seed_questions.json \
  --max-questions-per-page 6 \
  --eval-ratio 0.1
```

Dry run (prints prompts without calling the model):

```bash
python generate_dataset.py --dry-run
```

## Outputs

- `train.jsonl` and `test.jsonl` (plain JSON responses)
- `train_reasoning.jsonl` and `test_reasoning.jsonl` (includes `<think>` plan + JSON)
- `dataset_manifest.json` with run metadata and counts

Each JSONL record follows the `model_trainer` format:

```json
{"messages":[{"role":"system","content":"..."},{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}
```

## Notes

- Auth lookup order: `CODEX_API_KEY` or `OPENAI_API_KEY`, then `~/.codex/auth.json`.
- When using ChatGPT auth, the resolved model/base URL are recorded in `dataset_manifest.json`.
- The snapshot includes URL, title, main text, headings, links, and form fields.
- Hacker News snapshots also include an `HN Topics` list with `commentsUrl`, plus `HN Comments`
  when the page is an HN item thread.
- If a task needs actions, the model is asked to emit exactly one tool call per example.
- HN topic and comment questions are generated as multi-step examples (tool call -> new snapshot -> summary)
  with Comet-style headings such as `Topic overview` or `Comment themes`.
- ChatGPT Codex output is normalized from `tool/args` to `name/arguments` before writing JSONL.
- The seed questions and values live in `seed_questions.json`.
- Research sources used to expand seed questions are listed in `research_sources.md`.
