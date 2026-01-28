# Laika LLM Context Protocol (LLMCP) — JSON + Markdown

This doc defines a **versioned JSON protocol** used between **Laika Agent Core** and an LLM runtime (local or BYO cloud) for:

- sending **sanitized web context** as **Markdown** (captured from the DOM),
- receiving **JSON-only** responses that contain **Markdown** outputs + structured citations,
- proposing **typed tool calls** (policy-gated),
- storing durable conversations and artifacts (SQLite / local storage).

This protocol is designed for the collection-first Laika workflow (sources -> chat with citations -> transforms -> artifacts) and follows the direction explored in:
- https://aifoc.us/if-notebooklm-was-a-web-browser/
- `./NotebookLM-Chrome/` (reference implementation patterns)

Related: `docs/LaikaOverview.md`, `docs/laika_vocabulary.md`, `docs/safehtml_mark.md`, `docs/dom_heuristics.md`, `docs/local_llm.md`, `src/laika/PLAN.md`.

---

## Goals

- **JSON-in / JSON-out**: the model must return a single JSON object (no Markdown-only replies, no code fences).
- **Markdown is canonical**:
  - web capture is stored as Markdown (per-source)
  - assistant output and artifacts are Markdown
- **Safe rendering**: Markdown is rendered to HTML in trusted UI with strict sanitization (see `docs/safehtml_mark.md`).
- **Grounding + citations**: key claims should cite the source(s) they come from.
- **Tool calls are typed**: the model proposes tool calls; Policy Gate mediates allow/ask/deny before execution.
- **Durable history**: store request/response packets (redacted by default) for replay/debug/audit.

## Non-goals

- Sending raw HTML (or full DOM dumps) to models.
- Letting the model execute arbitrary HTML/CSS/JS in privileged UI.
- A general-purpose long-term RAG/vector DB (collections can add this later, but it’s not required for LLMCP).

---

## High-level flow (“summarize this page”)

1) **Observe (Safari)**: content script extracts a normalized representation.
2) **Extract Markdown (trusted)**: page content is converted to Markdown + metadata and signals.
3) **Pack (Agent Core)**: build an LLMCP request with task + context documents.
4) **Infer (LLM)**: model returns JSON containing `assistant.markdown` + `citations` + optional `tool_calls`.
5) **Render (UI)**: Markdown is rendered via a safe pipeline (Markdown renderer + DOMPurify).
6) **Persist**: store the conversation packets (redacted) and any saved artifacts.

Key principle: **web content is untrusted data** even after extraction. The model must treat it as evidence only.

---

## Protocol envelope

All protocol messages are JSON objects with a stable envelope:

```json
{
  "protocol": { "name": "laika.llmcp", "version": 2 },
  "id": "uuid",
  "type": "request",
  "created_at": "2026-01-28T12:34:56.789Z",
  "conversation": { "id": "uuid", "turn": 7 },
  "sender": { "role": "agent" }
}
```

### Required fields

- `protocol.name`: constant `laika.llmcp`
- `protocol.version`: integer (current: `2`)
- `id`: UUID for this packet
- `type`: `"request"` or `"response"`
- `created_at`: ISO-8601 UTC timestamp
- `conversation.id`: UUID that groups turns
- `conversation.turn`: monotonically increasing per conversation
- `sender.role`: `"user" | "agent" | "assistant" | "tool"`

---

## Transport note (how this reaches a model)

Most runtimes accept strings (`system`/`user`). LLMCP is the logical payload:

- **System prompt**: strict JSON-only instructions + an explicit response schema.
- **User content**: serialized request packet (or the request packet’s `input` + `context` object).
- **Local models**: disable “thinking” traces when possible (e.g., Qwen3 `enable_thinking=false`) so responses remain valid JSON.

---

## Request packet (`type: "request"`)

Request packets describe:
- what the user wants (`input.user_message`)
- what the agent wants the model to do (`input.task`)
- what evidence/context is available (`context.documents`)

### Request schema (v2)

```json
{
  "protocol": { "name": "laika.llmcp", "version": 2 },
  "id": "uuid",
  "type": "request",
  "created_at": "2026-01-28T12:34:56.789Z",
  "conversation": { "id": "uuid", "turn": 7 },
  "sender": { "role": "agent" },

  "input": {
    "user_message": { "id": "uuid", "text": "summarize this page" },
    "task": { "name": "web.summarize", "args": { "style": "concise" } }
  },

  "context": {
    "documents": [
      {
        "doc_id": "doc:web:summary",
        "kind": "web.observation.summary.v2",
        "trust": "untrusted",
        "source": { "browser": "safari", "tab_id": "optional" },
        "content": { "...": "typed content object" }
      }
    ]
  },

  "output": { "format": "json" }
}
```

Notes:
- `trust="untrusted"` is required for any document derived from web content.
- `output.format="json"` is fixed in v2.

---

## Context documents (v2)

### Web observation summary (`kind: "web.observation.summary.v2"`)

This is the primary page capture format for single-page workflows.

```json
{
  "doc_type": "web.observation.summary.v2",
  "url": "https://example.com",
  "title": "Example",
  "captured_at": "2026-01-28T12:34:56.789Z",

  "markdown": "# Example\\n\\nMain content as markdown...",
  "extracted_links": [
    { "url": "https://...", "text": "link text", "context": "surrounding text" }
  ],

  "signals": ["paywall_or_login", "overlay_blocking"]
}
```

Design notes:
- `markdown` is **canonical**: this is what we persist for sources and what we send to models.
- For feed/list/search pages, we may include additional structured fields (items/comments) for robustness, but the canonical content is still Markdown.

### Observation chunks (`kind: "web.observation.chunk.v2"`) (optional)

For long pages, include additional chunk documents:

```json
{
  "doc_type": "web.observation.chunk.v2",
  "url": "https://example.com",
  "title": "Example",
  "chunk_index": 1,
  "chunk_count": 3,
  "markdown": "..."
}
```

Chunking rules:
- chunks are 1-based and ordered by `chunk_index`
- the model should read all chunks before responding

---

## Collection documents (multi-source workflows)

### Collection index (`kind: "collection.index.v1"`)

A lightweight list of sources in a collection.

```json
{
  "doc_type": "collection.index.v1",
  "collection_id": "col:123",
  "title": "Model release coverage",
  "sources": [
    { "source_id": "src:1", "url": "https://...", "title": "...", "captured_at": "2026-01-28T01:02:03Z" }
  ]
}
```

### Collection source (`kind: "collection.source.v1"`)

Captured sources are normalized, size-bounded, and stored/sent as Markdown.

```json
{
  "doc_type": "collection.source.v1",
  "collection_id": "col:123",
  "source_id": "src:1",
  "url": "https://example.com/story",
  "title": "Example story",
  "captured_at": "2026-01-28T01:02:03Z",
  "markdown": "# Example story\\n\\n...",
  "extracted_links": [{ "url": "https://...", "text": "...", "context": "..." }]
}
```

Packing recommendation:
- include one `collection.index.v1` doc + N `collection.source.v1` docs
- for large collections, include only the top-N full sources and summarize the rest (heuristic or two-pass)

---

## Tasks (recommended v2 set)

Core tasks:
- `web.summarize`: summarize a single observed/captured page (Markdown input -> Markdown output)
- `web.answer`: answer a question grounded in provided context (collection packs)
- `web.extract`: extract structured fields from page(s) (returns JSON structures inside the LLMCP response)

Transforms:
- `transform.run`: generate a named artifact from a collection (still returns Markdown)

---

## Response packet (`type: "response"`)

Responses must be JSON-only and match the schema below.

### Response schema (v2)

```json
{
  "protocol": { "name": "laika.llmcp", "version": 2 },
  "id": "uuid",
  "type": "response",
  "created_at": "2026-01-28T12:34:57.123Z",
  "conversation": { "id": "uuid", "turn": 7 },
  "sender": { "role": "assistant" },
  "in_reply_to": { "request_id": "uuid" },

  "assistant": {
    "title": "Optional short title",
    "markdown": "Markdown output as a single string...",
    "citations": [
      { "source_id": "src:1", "url": "https://...", "quote": "short supporting excerpt" }
    ]
  },

  "tool_calls": []
}
```

Rules:
- `assistant.markdown` is required.
- `tool_calls` is allowed but optional; it must be an array.
- Tool calls are **proposals** only; Policy Gate is authoritative.

### Citation shape (v2)

Minimum recommended fields:
- `source_id` (for collection outputs) and/or `doc_id` (for single-page observations)
- `url` (for opening the underlying source)
- `quote` (short excerpt supporting the claim)

The UI should treat citations as first-class objects, not “just text”.

---

## Why tool calls exist

Laika treats the web as untrusted input. The model never takes direct actions in the browser. Instead it proposes **typed tool calls** that the app can approve/deny and execute safely.

Tools exist for:
- safety (policy-gated execution)
- determinism (small atomic actions)
- auditability (structured logs)
- portability (same contract works for tabs or an app-owned WebView)

---

## Tool call schema (v2)

Tool calls are schema-validated before execution.

Tool call item shape:

```json
{ "name": "browser.click", "arguments": { "handleId": "laika-1" } }
```

Notes:
- `arguments` may be `{}` for tools that take no parameters.
- Tool calls must not include keys beyond the schema.

### Browser primitives (Safari extension)

- `browser.observe_dom`: `{ "maxChars"?: int, "maxElements"?: int, "maxBlocks"?: int, "maxPrimaryChars"?: int, "maxOutline"?: int, "maxOutlineChars"?: int, "maxItems"?: int, "maxItemChars"?: int, "maxComments"?: int, "maxCommentChars"?: int, "rootHandleId"?: string }`
- `browser.get_selection_links`: `{ "maxLinks"?: int }`
- `browser.click`: `{ "handleId": string }`
- `browser.type`: `{ "handleId": string, "text": string }`
- `browser.select`: `{ "handleId": string, "value": string }`
- `browser.scroll`: `{ "deltaY": number }`
- `browser.open_tab`: `{ "url": string }`
- `browser.navigate`: `{ "url": string }`
- `browser.back`: `{}`
- `browser.forward`: `{}`
- `browser.refresh`: `{}`
- `search`: `{ "query": string, "engine"?: string, "newTab"?: boolean }`

### App-level primitives (trusted local executors)

- `artifact.save`: `{ "title": string, "markdown": string, "tags"?: [string], "redaction"?: "default"|"none" }`
- `artifact.share`: `{ "artifactId": string, "format": "markdown"|"text"|"json"|"csv"|"pdf", "filename"?: string, "target"?: "share_sheet"|"clipboard"|"file" }`
- `artifact.open`: `{ "artifactId": string, "target"?: "workspace"|"browser", "newTab"?: boolean }`
- `integration.invoke`: `{ "integration": string, "operation": string, "payload": object, "idempotencyKey"?: string }`
- `app.calculate`: `{ "expression": string, "precision"?: number }`

Collections + sources:
- `collection.create`: `{ "title": string, "tags"?: [string] }`
- `collection.add_sources`: `{ "collectionId": string, "sources": [{ "type": "url", "url": string, "title"?: string } | { "type": "note", "title"?: string, "text": string }] }`
- `collection.list_sources`: `{ "collectionId": string }`
- `source.capture`: `{ "collectionId": string, "url": string, "mode"?: "auto"|"article"|"list", "maxChars"?: int }`
- `source.refresh`: `{ "sourceId": string }`

Transforms:
- `transform.list_types`: `{}`
- `transform.run`: `{ "collectionId": string, "type": string, "config"?: object }`

---

## Markdown output rules (prompt contract)

System prompts for v2 must enforce:

- Output **only JSON** that matches the response schema.
- Put all human-readable content in `assistant.markdown`.
- Do not output raw HTML in `assistant.markdown` (Markdown only).
- Cite sources using `assistant.citations` (and optionally inline markers like `[1]` in Markdown if helpful).
- If sources don’t support the answer, say so and suggest what to collect next.

---

## Capture + rendering (source of truth)

LLMCP assumes **Markdown is canonical** for both:
- captured sources (`*.markdown` in context docs), and
- model outputs (`assistant.markdown` and `artifact.contentMarkdown`).

The detailed, security-sensitive rules for:
- DOM/HTML -> Markdown capture, and
- Markdown -> safe HTML rendering/sanitization

live in: `docs/safehtml_mark.md`.

---

## Storing JSON conversation in SQLite

Store packets after applying a storage redaction policy.

Default policy should avoid persisting raw page captures inside LLM packets (full Markdown bodies) unless explicitly enabled for debugging:

- Always store: user prompts, assistant markdown, citations, tool calls + results (if recorded)
- Prefer storing: digests + short previews for context documents in the conversation log
- Store full captured source Markdown in the **collection/source store**, not in the chat log

### Proposed schema (v1)

```sql
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  title TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  turn INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  sender_role TEXT NOT NULL,          -- user|agent|assistant|tool
  packet_type TEXT NOT NULL,          -- request|response|tool (future)
  in_reply_to_request_id TEXT,
  model_id TEXT,
  packet_json TEXT NOT NULL,
  FOREIGN KEY(conversation_id) REFERENCES conversations(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_turn
  ON messages(conversation_id, turn);
```

---

## Robustness and safety considerations

- **Instruction/data separation**: all web-derived docs are `trust="untrusted"`.
- **Strict JSON parsing**: reject non-JSON; optionally strip code fences in a safe “repair” mode.
- **Large Markdown strings**: validate output size; enforce caps; compress/summarize context before sending.
- **Redaction**: never include cookies/session tokens; strip credential-like query params.
- **UI safety**: never inject raw model output; always sanitize rendered HTML.

---

## Example: “summarize this page” (abbreviated)

### Request

```json
{
  "protocol": { "name": "laika.llmcp", "version": 2 },
  "id": "req-1",
  "type": "request",
  "created_at": "2026-01-28T12:34:56.789Z",
  "conversation": { "id": "c-1", "turn": 1 },
  "sender": { "role": "agent" },
  "input": {
    "user_message": { "id": "u-1", "text": "summarize this page" },
    "task": { "name": "web.summarize", "args": { "style": "concise" } }
  },
  "context": {
    "documents": [
      {
        "doc_id": "doc:web:summary",
        "kind": "web.observation.summary.v2",
        "trust": "untrusted",
        "content": {
          "doc_type": "web.observation.summary.v2",
          "url": "https://example.com",
          "title": "Example",
          "markdown": "# Example\\n\\n..."
        }
      }
    ]
  },
  "output": { "format": "json" }
}
```

### Response

```json
{
  "protocol": { "name": "laika.llmcp", "version": 2 },
  "id": "res-1",
  "type": "response",
  "created_at": "2026-01-28T12:34:57.123Z",
  "conversation": { "id": "c-1", "turn": 1 },
  "sender": { "role": "assistant" },
  "in_reply_to": { "request_id": "req-1" },
  "assistant": {
    "title": "Summary",
    "markdown": "## Summary\\n\\n- ...\\n\\n## What to verify\\n\\n- ...",
    "citations": [{ "doc_id": "doc:web:summary", "url": "https://example.com", "quote": "..." }]
  },
  "tool_calls": []
}
```
