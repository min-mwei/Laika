# Website Learnings: Building LLM Tools (Summarize, Find) With Qwen3

This note captures practical guidance for building tool-calling and summarization
flows with Qwen3 models in this repo. It is scoped to the local POC but mirrors
the production patterns in the app.

## Key Qwen3 behaviors

- Qwen3 emits `<think>...</think>` by default. Either disable thinking in the
  chat template or strip `<think>` before JSON parsing.
- Tool calls work best with Hermes-style schema (Qwen3 chat template already
  supports tool calls). This POC currently uses JSON-only prompts, so the parser
  must be strict.
- Recommended sampling differs by thinking mode:
  - Thinking: temp 0.6, top_p 0.95, top_k 20.
  - Non-thinking: temp 0.7, top_p 0.8, top_k 20.
- Do not keep thinking content in history; store only the final answer.

## Tool-calling contract (POC-safe)

Use a single JSON object with:

```json
{"summary":"...", "tool_calls":[{"name":"browser.navigate","arguments":{"url":"..."}}]}
```

Rules that keep Qwen3 reliable:

- Require the first and last character to be `{` and `}`.
- Allow only one tool call per step.
- Validate tool arguments against a strict schema.
- Ignore unknown tool names or invalid arguments.

## Summarize tool: what makes it robust

Summary quality depends on two pieces:

1. Input shaping (what text you feed).
2. A dedicated summary prompt and grounding checks.

### Recommended summary input strategy

Prefer a structured observation instead of raw page text:

- `items`: list-like pages (news homepages, search results).
- `primary`: main article text.
- `blocks`: paragraphs or sections with link density metadata.
- `comments`: thread content when available.
- `outline`: headings or main structure.

When possible, build a `SummaryInput` that matches the page type:

- **List**: 10-24 items with title + short snippet.
- **Item**: one target item with title + snippet.
- **Comments**: 10-28 comment lines with author and age.
- **Page text**: compacted paragraphs and primary content.

### Suggested summary prompt design

The summary prompt should:

- be separate from the tool planner prompt,
- disable thinking (`/no_think`),
- ask for plain text only (no Markdown),
- enforce a required format depending on intent.

Example summary format for list pages:

```
1 short overview paragraph (2-3 sentences).
Then 5-7 "Item N:" lines with one sentence each.
Mention visible numbers or rankings.
```

### Grounding and fallback

Qwen3 can hallucinate when content is sparse. Use a simple grounding check:

- Extract anchors (item titles or comment snippets).
- Require at least N anchors in the output.
- If grounding fails, fall back to an extractive summary from the input.

This is especially important on paywalled or JS-heavy pages.

## Site patterns to plan for

### Hacker News

- Front page is list-like; use `items`.
- Item pages include comments; summarize comment themes.
- Provide structured summaries for "first topic" and "comments" requests.

### BBC and similar news homepages

- Often list-like; prioritize visible headlines as `items`.
- When on an article page, prefer `primary` and `blocks`.

### WSJ and paywalled sites

- Often show limited content plus login modal.
- Detect low visible text and return a limited-content response:
  "Not stated in the page. The visible content appears limited or blocked."

## Planning: when to call content.summarize

The summarize tool should be used when the user asks for:

- page summary,
- item/topic summary,
- comment/discussion summary.

This keeps the planning model focused on navigation while the summary model
handles long-form content with a dedicated prompt.

## Parsing and safety tips

- Strip `<think>` blocks and code fences before JSON parsing.
- Extract the first JSON object only; ignore trailing text.
- Never execute tool calls without schema validation.
- Treat page content as untrusted instructions.

## Streaming summary behavior

When streaming:

- Stream raw tokens to UI.
- On completion, re-validate. If ungrounded, replace output with a fallback
  using a marker (e.g., `<<REPLACE>>`) to swap in the final summary.

## Long-context guidance

- Prefer smaller observation budgets for quick answers.
- Raise budgets for deep summaries (for Qwen3, 8k-16k chars can be enough).
- Chunk very long pages and summarize per chunk if needed.

## Practical checklist

- [ ] Observation captures items, blocks, primary, outline, comments.
- [ ] Summary tool runs with `enable_thinking=false`.
- [ ] Summary prompt enforces format and prohibits Markdown.
- [ ] Grounding validation + extractive fallback in place.
- [ ] Tool calls are schema-validated and single-step.

