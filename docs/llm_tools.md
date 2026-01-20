# Laika LLM Tools

This doc explains why Laika uses tools, how Qwen3 produces tool calls, and where each tool is implemented and executed in the current prototype.

## Why tools exist

Laika treats the web as untrusted input. The model never takes direct actions in the browser. Instead, it proposes **typed tool calls** that the app can approve, deny, and execute safely.

Tools are necessary for:

- Safety: every action is mediated by Policy Gate and surfaced in trusted UI.
- Determinism: each tool is small and atomic, so retries are predictable.
- Auditability: tool calls and results are structured and loggable.
- Portability: the same contract can target Safari tabs or an app-owned WebView.

## Interaction diagram (agent, browser, tools)

```
User
  │
  ▼
Sidecar UI (in-page iframe in the active tab; fallback panel window: popover.html + popover.js)
  │  native messaging
  ▼
Extension background (background.js)
  │  observe/act routing
  ▼
Native bridge (SafariWebExtensionHandler.swift)
  │  plan request
  ▼
Agent Core (AgentOrchestrator + PolicyGate)
  │  model call
  ▼
Qwen3 (MLX) -> JSON tool_calls
  │
  ├─ allow/ask/deny in Policy Gate
  ▼
Tool execution
  │
  ├─ content_script.js (DOM actions)
  └─ background.js (tab actions)
  │
  ▼
Tool results -> Agent Core -> sidecar UI
```

## Tool lifecycle (one step)

1. Observe: the extension captures page text + element handles and a sanitized list of open tabs in the current window.
2. Plan: the model emits JSON with summary + tool_calls.
3. Gate: Policy Gate returns allow/ask/deny per tool call.
4. Act: allowed tools execute in JS or Swift.
5. Re-observe: capture fresh state after changes or navigation.

## Tool-calling contract (current)

The model must return exactly one JSON object:

```json
{
  "summary": "short user-facing summary",
  "tool_calls": [
    {"name": "browser.click", "arguments": {"handleId": "laika-12"}},
    {"name": "browser.type", "arguments": {"handleId": "laika-7", "text": "example"}}
  ]
}
```

Rules:

- If no action is needed, return an empty `tool_calls` array.
- Use only `handleId` values from the latest observation.
- Tool names must match the allowed list.
- Arguments must be valid JSON values (strings, numbers, booleans, objects).

### Parsing behavior

- `src/laika/model/Sources/LaikaModel/ToolCallParser.swift` extracts the **first JSON object** from model output.
- If no JSON object is found, the output is treated as a summary with **no tool calls**.
- Unknown tool names are ignored (not executed).

## Qwen3 0.6B tool calling

### External specifics (Qwen docs)

From the Qwen3 model card and Qwen-Agent documentation:

- Qwen3 is positioned as strong on **tool calling** and recommends using Qwen-Agent for tool templates and parsing.
- Qwen-Agent supports **parallel function calls** and uses a default `nous` tool-call template (recommended for Qwen3).
- Qwen3 uses a **thinking mode** that emits `<think>...</think>` blocks when `enable_thinking=True`.
- Best practice is to **exclude thinking content from history**, keeping only the final response.
- Recommended sampling settings (from the model card):
  - Thinking mode: `Temperature=0.6`, `TopP=0.95`, `TopK=20`, `MinP=0`.
  - Non-thinking mode: `Temperature=0.7`, `TopP=0.8`, `TopK=20`, `MinP=0`.
- Recommended output length: `max_new_tokens=32768` for most queries (longer for benchmarking).

Sources:

- Qwen3 model card (Hugging Face): https://huggingface.co/Qwen/Qwen3-0.6B
- Qwen-Agent README: https://github.com/QwenLM/Qwen-Agent

### How Laika uses Qwen3 today

Laika does **not** use Qwen-Agent or a native tool-calling API. Instead, Laika uses a JSON-only prompt and a custom parser.

Implementation details:

- Prompt schema: `src/laika/model/Sources/LaikaModel/PromptBuilder.swift`.
- Model runner: `src/laika/model/Sources/LaikaModel/MLXModelRunner.swift`.
- Generation settings in code: `maxTokens=256`, `temperature=0.2`, `topP=0.9`.
- Parser: `src/laika/model/Sources/LaikaModel/ToolCallParser.swift`.
- Model chat template (bundled with the MLX model) supports `<tool_call>...</tool_call>` tags when tools are provided: `src/laika/extension/lib/models/Qwen3-0.6B-MLX-4bit/chat_template.jinja`. Laika does not currently pass tool definitions into the template and instead uses a JSON-only prompt.

Native messaging path:

- The sidecar sends a `plan` request to `SafariWebExtensionHandler.swift`.
- The handler decodes `PlanRequest`, validates origin, and executes the model via `ModelRouter`.
- If no model is found, Laika falls back to a static runner.

Implications:

- Qwen3’s own tool-call templates (as used by Qwen-Agent) are not used. Laika must keep the JSON-only prompt and parser in sync.
- Laika’s generation settings are intentionally conservative to reduce latency on-device, but may underperform relative to Qwen’s recommended settings.
- If Qwen3 emits `<think>...</think>` or extra text, Laika will ignore it unless a valid JSON object is present.

## Context window management

Laika uses a **context pack** rather than raw DOM:

- Goal, origin, mode
- Observation text (budgeted)
- Element list with handles
- Items/outline/blocks summaries from the DOM (including item link candidates)
- Recent tool calls (if available)
- Open tab summaries for the current window (title + origin only)

Multi-tab context (prototype):

- The sidecar asks the background for tab summaries (`laika.tabs.list`) and includes them in the plan request.
- Tool execution stays bound to the tab that was observed; the tab list is for planning context only.

Observation budgets (current):

- The sidecar requests `maxChars: 8000`, `maxElements: 120` (`src/laika/extension/popover.js`).
- The content script can support larger defaults (`maxChars: 4000`, `maxElements: 50`) but the request controls the limit (`src/laika/extension/content_script.js`).
- The sidecar also passes `maxTokens` for model output length (default 2048, capped at 8192).

Pushing toward a 32K token window (design notes):

- **Raise observation budgets** for high-signal pages. Example target: `maxChars` 8k–16k and `maxElements` 80–160. Keep smaller caps for quick summaries.
- **Chunk the observation** when text exceeds a single budget: collect multiple segments (e.g., `chunkIndex`, `chunkCount`, `nextCursor`) and merge or summarize in the Agent Core.
- **Stream chunks** to the Agent Core so the UI stays responsive and the model can start summarizing before the full page is captured.
- **Compress before planning**: summarize large text into a compact “page brief” and keep only selected element handles in the final context pack.
- **Token-aware budgeting**: estimate token cost per chunk and stop when a target token budget is reached.

Proposed chunked observation protocol (small, incremental):

```
Request:
{ "type": "laika.observe", "options": { "maxChars": 4000, "maxElements": 50, "cursor": 0 } }

Response:
{
  "status": "ok",
  "observation": { "url": "...", "title": "...", "text": "...", "elements": [...] },
  "cursor": 4000,
  "done": false
}
```

Notes:

- `cursor` is a character offset into the normalized page text (content script should expose it).
- The sidecar/background repeats requests until `done=true`.
- Agent Core merges chunks or produces a rolling summary before planning.
- This can be added without changing the tool contract; it is a transport upgrade for `observe_dom`.

Long-context guidance (from `docs/local_llm.md`):

- Increase context sizes only when needed.
- Prefer read-only long-context modes for summarization.
- Keep strict token budgets to avoid latency and battery impact.

## Tool categories

- Core navigation: tab- or page-level movement.
- Interaction: click/type/scroll on specific elements.
- Content actions: summarize, find, and extract information.

## Tool catalog (current prototype)

| Category | Tool name | Description | Tool params | Implementation | Runs in |
| --- | --- | --- | --- | --- | --- |
| Observation | `browser.observe_dom` | Capture/refresh page text + element handles. The agent may call this when it needs more context. | `{ "maxChars": number, "maxElements": number, "maxBlocks": number, "maxPrimaryChars": number, "maxOutline": number, "maxOutlineChars": number, "maxItems": number, "maxItemChars": number }` | `src/laika/extension/content_script.js` (`observeDom`) | Content script (Safari tab) |
| Core navigation | `browser.open_tab` | Open a URL in a new tab. | `{ "url": "https://example.com" }` | `src/laika/extension/background.js` (`handleTool`) | Extension background |
| Core navigation | `browser.navigate` | Navigate the current tab to a URL. | `{ "url": "https://example.com" }` | `src/laika/extension/background.js` (`handleTool`) | Extension background |
| Core navigation | `browser.back` | Go back in history. | `{}` | `src/laika/extension/background.js` (`handleTool`) | Extension background |
| Core navigation | `browser.forward` | Go forward in history. | `{}` | `src/laika/extension/background.js` (`handleTool`) | Extension background |
| Core navigation | `browser.refresh` | Reload the current page. | `{}` | `src/laika/extension/background.js` (`handleTool`) | Extension background |
| Interaction | `browser.click` | Click a visible element by `handleId`. | `{ "handleId": "laika-12" }` | `src/laika/extension/content_script.js` (`applyTool`) | Content script |
| Interaction | `browser.type` | Type text into an input/textarea by `handleId`. | `{ "handleId": "laika-7", "text": "query" }` | `src/laika/extension/content_script.js` (`applyTool`) | Content script |
| Interaction | `browser.scroll` | Scroll the page by a vertical delta. | `{ "deltaY": 400 }` | `src/laika/extension/content_script.js` (`applyTool`) | Content script |
| Interaction | `browser.select` | Select a dropdown option by `handleId`. | `{ "handleId": "laika-9", "value": "Option" }` | `src/laika/extension/content_script.js` (`applyTool`) | Content script |
| Content actions | `content.summarize` | Summarize page or scoped element. | `{ "scope": "page"|"item"|"comments" }` or `{ "handleId": "laika-5" }` | Swift Agent Core (`SummaryService`) | Swift (local model) |

Notes for `content.summarize`:

- Summaries are validated against observation anchors; if the output is ungrounded, Laika falls back to an extractive summary built from the observed text/items.
- Streaming summaries may replace provisional output when the validator fails.

## Proposed tools (not yet implemented)

No additional tools are queued beyond the current catalog.
| Content actions | `content.find` | Search in-page or on the web for more info. | `{ "query": "SEC filing deadlines", "scope": "page"|"web" }` | Swift + `background.js` | Swift + extension background |

## Where tools are defined and gated

- Tool names and call structs: `src/laika/shared/Sources/LaikaShared/ToolTypes.swift`.
- Policy Gate: `src/laika/shared/Sources/LaikaShared/Policy.swift`.
- Orchestrator and policy binding: `src/laika/app/Sources/LaikaAgentCore/AgentCore.swift`.
- Native messaging bridge: `src/laika/LaikaApp/Laika/Laika Extension/SafariWebExtensionHandler.swift`.

Current policy behavior:

- `browser.observe_dom` is allowed.
- Action tools are marked `ask` by default (approval required).
- Sensitive field blocking is defined in Policy Gate, but `fieldKind` is currently always `.unknown` in the orchestrator.

## Autodrive guidance

Autodrive can be useful when the site is low-risk and the user explicitly asks for it. It should be constrained otherwise:

- Default to read-only actions.
- Require approval for clicks and typing.
- Block or require explicit approval for login, MFA, payments, account changes, or downloads.
- If no page context is available, ask the user to provide context manually.

## References (internal)

- `docs/AIBrowser.md` for architecture, trust boundaries, and UI roles.
- `docs/local_llm.md` for context window management and thinking trace handling.
- `src/laika/model/Sources/LaikaModel/PromptBuilder.swift` for the tool JSON schema.
- `src/laika/model/Sources/LaikaModel/ToolCallParser.swift` for parsing behavior.
- `src/laika/extension/content_script.js` and `src/laika/extension/background.js` for tool execution.
