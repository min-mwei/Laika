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

High-detail run (higher budgets + thinking enabled):

```bash
python laika_poc.py \
  --url https://news.ycombinator.com \
  --prompt "Tell me about the first topic." \
  --detail-mode
```

When `--detail-mode` is enabled, the POC will fall back to a structured summary builder if the model ignores the requested headings.

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

## Design (detailed)

### Goals

- Emulate Laika's plan/act loop with a local Qwen3 MLX 4-bit model.
- Preserve the tool-calling contract in `docs/llm_tools.md`.
- Keep the model view limited to sanitized text + metadata (no cookies, no raw HTML).
- Provide a high-detail summary experience with small-model constraints.

### Non-goals

- Production browser automation or DOM mutation.
- High-fidelity rendering, JS execution, or interactive login flows.
- Any cloud-based inference or data exfiltration.

### High-level flow

1. Load a local MLX model and tokenizer.
2. Fetch the URL with a simple HTTP client (no cookies).
3. Extract a sanitized observation:
   - visible text (focus text if possible),
   - element handles for basic tool simulation,
   - HN topic metadata when on Hacker News pages,
   - HN comment threads when on Hacker News item pages.
4. Build a prompt matching Laika's JSON tool-call schema.
5. Run the model and parse the first JSON object from output.
6. Execute at most one tool per step (navigate/observe/type/etc.).
7. Re-observe and repeat until the model returns no tool calls.

### Data model (POC-level)

- `Observation`:
  - `url`, `title`, `text`, `elements`
  - `topics` (HN front page topics)
  - `hn_story` (HN item metadata)
  - `hn_comments` (HN comment list)
- `ContextPack`: observation + recent tool calls/results + tab summaries.
- `ToolCall`/`ToolResult`: typed per `docs/llm_tools.md`.

### Tool execution

Tools are local simulations, not browser-native actions:

- `browser.navigate/open_tab/back/forward/refresh`: fetches and replaces the page HTML.
- `browser.click`: follows a link handle by URL.
- `browser.type/select/scroll`: recorded as simple local state.
- `browser.observe_dom`: re-extracts observation text/handles.
- `content.summarize/find`: local text operations or a simple web search.

All tool calls are schema-validated before execution, mirroring Laika's safety gates.

### Prompting and parsing

- System prompt requires a single JSON object with `summary` and `tool_calls`.
- The parser strips `<think>` blocks and code fences, then extracts the first JSON object.
- Unknown tool names are ignored.

### Hacker News specific parsing

The POC detects HN front pages and item pages:

- Front page: extracts `title`, `url`, `commentsUrl`, `points`, `comments`.
- Item page: extracts comment rows with `author`, `age`, `text`, `indent`.

This allows "first topic" flows to:

1. Navigate to the first topic URL.
2. If the user asks about comments, navigate to the comments URL.
3. Summarize the article or thread based on extracted content.

### Detail-mode behavior

`--detail-mode` is a policy layer to help Qwen3-0.6B match high-detail depth:

- Raises budgets (`max_chars`, `max_elements`, `max_tokens`).
- Enables thinking mode and higher sampling values.
- Adds a structured summary fallback if the model ignores headings.

This preserves model freedom but ensures a well-structured answer when it fails.

### Structured summary fallback

When detail mode is enabled and the model does not follow the response format:

- The POC builds a sectioned summary from extracted text and HN metadata.
- The output mirrors the "Topic overview / Key technical points / Why notable" pattern.
- Comment summaries look for theme cues (tools, capture devices, file formats, culture).

This fallback is intentionally simple and rule-based.

### Focus text extraction

To avoid long boilerplate, the extractor:

- Removes nav/header/footer/aside blocks.
- Prefers `<article>` or `<main>` content.
- Falls back to the largest content section if needed.

### Safety constraints

- No cookies or session data are sent.
- No raw HTML is sent to the model.
- Only sanitized text and metadata are passed.
- Tool calls are schema-validated and can be rejected by policy.

### Limitations

- No JS execution or dynamic DOM; content is static HTML.
- Some pages have weak structure; focus extraction may miss content.
- Qwen3-0.6B can be brittle on long or multi-step tasks.
- HN comment extraction is best-effort and may miss edge cases.
