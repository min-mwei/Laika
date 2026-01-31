# Laika Architecture: AI Fortress for Web Work (Collections + Transforms)

Laika is a privacy-first **AI fortress** in **Safari (macOS + iOS)**: a protected workspace that captures your browsing session (open tabs, search results, and the pages you visit) as context and turns it into **collections** you can query, compare, and transform into durable artifacts.

Laika's thesis:

- The browser is the execution environment (state, identity, permissions)
- The web is the data source and context
- LLMs are the capability engine that turns context into structures you can reuse

This doc focuses on the core loop:

- **Collect** sources (tabs or search)
- **Ask/Summarize/Compare** with citations
- **Transform** into artifacts (tables, briefs, timelines, study assets)
- **Save/Share** outputs safely

The security posture remains: treat the web as untrusted input, keep actions typed and policy-gated, and keep sensitive context on-device by default.

Related docs:

- `docs/Laika_pitch.md` (product narrative)
- `docs/laika_vocabulary.md` (workflow verbs)
- `docs/laika_ui.md` (UI layouts + flows)
- `docs/llm_context_protocol.md` (LLMCP JSON protocol + tool schemas)
- `docs/logging.md` (logging + audit: JSONL events, redaction, correlation IDs)
- `docs/safehtml_mark.md` (Safe HTML <-> Markdown: capture + rendering + sanitization)

---

## Status

This is a design doc guiding the next iteration of Laika. It is intentionally concrete about:

- user-facing workflows (collections + transforms)
- the data model (sources + artifacts)
- the LLM contract (grounding + citations)
- the safety boundary (tool-only, policy-gated)

Implementation details (exact Safari APIs, UI affordances, storage schema) should be validated with prototypes.

---

## The Core Loop

### 1) Collect
Create or grow a **Collection** from:

- your open tabs / selected links
- a web search (collect the top ~8-10 results)

### 2) Ask / Summarize / Compare
Use the LLM over the collection to:

- answer questions grounded in sources
- produce summaries and key takeaways
- compare options and disagreements

All claims should be traceable via citations.

### 3) Transform
Run named transforms (comparison table, timeline, brief, quiz, etc.) that produce a durable **Artifact**.

### 4) Save / Share
Store artifacts for later and export them explicitly (P0: clipboard + file; P1: share sheet/integrations).

---

## Concepts and Data Model

### Collection
A named workspace holding sources.

Minimum metadata:

- `id`, `title`, `tags?`, `createdAt`, `updatedAt`

### Source
A captured item in a collection.

Minimum metadata:

- `id`, `collectionId`
- `kind`: url | note | image
- `url?`, `normalizedUrl?`, `title?`
- `captureStatus`: pending | captured | failed
- `captureMarkdown` (bounded snapshot), `capturedAt`
- `captureError?` (last failure reason, if any)
- `provenance` (where it came from: tab/search/selection)

Optional but valuable:

- extracted outbound links (for discovery)
- `captureVersion` + `contentHash` (for dedupe/recapture and debugging)
- content signals (paywall/login/overlay)
- per-source summary fields
- image metadata (for multimodal grounding)

### Artifact
A saved output generated from a collection.

Minimum metadata:

- `id`, `collectionId`, `type`, `title`
- renderable content (Markdown; reopenable/offline with no model calls)
- `sourceIds[]` used to generate
- status fields for background/resumable transforms

### Persistence (P0 direction)

Native SQLite is the source of truth for collections/sources/chat/artifacts and capture jobs.

Concrete schema + indexes: `docs/sqlite_schema_v1.sql`.

---

## Collect (Two Entry Points)

Laika should make collection-building fast and low-friction.

### A) Collect From Tabs

User intent: "I already have the sources open. Bundle them."\
Typical UX: select tabs or select links on a page, then collect.

Implementation building blocks:

- `browser.get_selection_links` (read-only extraction of highlighted links)
- `collection.create` / `collection.add_sources`
- `source.capture` (capture bounded Markdown snapshots per URL)

Notes:

- Capture should be bounded (size limits) and provenance-tagged.
- Capture should treat web content as untrusted input.

### B) Collect From Web Search

User intent: "I don't have the sources yet. Build me a reading list."\
Typical UX:

- User opens a search results tab manually and asks: "collect the top 10 results".
- Or user asks Laika: "search for X and collect 10 good sources".

Implementation building blocks:

- `search` (open a search page)
- `browser.observe_dom` (read results page)
- extraction logic (pick top results, avoid obvious spam)
- `collection.add_sources` + `source.capture`

Design constraints:

- Avoid collecting garbage results (SEO pages) when the user asks for "good" sources.
- Prefer diversity (different domains / viewpoints) when appropriate.

---

## LLM Integration (Grounded by Design)

### Protocol

Laika uses a JSON-in/JSON-out context protocol (LLMCP) so:

- web content is carried as **data** (`trust: untrusted`), not instructions
- the model returns **Markdown** (canonical) that Laika renders via a strict Markdown -> safe HTML pipeline
- tool calls are typed and policy-gated

See: `docs/llm_context_protocol.md`.

### Tasks

Core LLM tasks:

- `web.summarize`: summarize a single observed/captured page
- `web.answer`: answer a question using provided context (including multi-source collection packs)
- `web.extract`: extract structured fields (dates, prices, entities) from a page or collection context

Transforms are treated as higher-level tasks that still run through the same safety boundary:

- `transform.run` over a collection -> produces an artifact

### Citations (Non-Negotiable)

Laika should enforce a citations contract:

- If a claim is based on sources, it must cite.
- If the sources don't support an answer, it must say so.

Citations should be machine-readable so UI can:

- show evidence cards
- jump back to the source URL
- optionally highlight relevant fragments when available

### Context Management (Scaling Beyond 5 Sources)

When collections are small, include full captured Markdown for all sources.

When collections are large, avoid overflow by using one of:

- **Heuristic compression**: include full text for a few sources, summaries for the next tier, titles only for the rest.
- **Two-pass compression**: use an LLM pass to rank sources by relevance to the current question, then summarize mid-tier sources.

A longer-term option is an **agentic read-on-demand** mode where the model starts from a source index and requests specific sources to read.

### Multimodal Sources (Images)

Collections may include images (screenshots, diagrams, figures) alongside text sources.

Design intent:

- If a vision-capable model is available (local VLM or BYO cloud), include images as first-class context so answers/transforms can incorporate visual evidence.
- If only text-only models are available, treat images as references (and optionally add a local OCR/extraction step as a future enhancement).

Guardrails:

- limit the number of images included per request (to control cost and payload)
- preserve provenance (where the image came from)
- keep rendering safe (never execute model-authored scripts)

---

## Transforms (Artifacts, Not Chat)

Transforms are named generators that produce durable outputs.

Design goals:

- predictable output formats (tables, briefs, timelines)
- configuration per transform type (counts, tone, depth)
- background/resumable execution
- safe rendering via Markdown -> sanitized HTML

Implementation building blocks (planned):

- `transform.list_types`
- `transform.run`
- `artifact.save` / `artifact.open`

Security note:

- Transforms should produce Markdown by default, rendered through the same sanitization pipeline as chat.
- If Laika ever supports interactive HTML outputs, they must run in a sandboxed viewer with no extension privileges.

---

## Discover (Suggested Next Sources)

Discovery is how collections grow intelligently:

- extract outbound links from captured sources
- ask the model to rank which links are most valuable to add next
- present 8-10 suggestions with reasons
- let the user add them via Collect

This should be explicit and user-driven (no auto-open, no auto-collect).

---

## Usage and Cost Metering

Even in a collection-first product, users need feedback loops.

Laika should be able to track (locally):

- which operations ran (collect, answer, summarize, transform)
- token usage when using cloud models
- estimated cost (when pricing is known)

This is primarily a product and debugging feature:

- gives users a mental model of "what just happened"
- helps teams choose when to use local vs cloud models
- makes background transforms and retries auditable

---

## Privacy and Safety Posture

Laika should preserve these invariants even in collection workflows:

- **No cloud browser**: the browser session stays local.
- **On-device by default**: local inference is preferred.
- **Optional BYO cloud models**: if enabled, send redacted context packs only (never cookies/session tokens).
- **Web content is untrusted**: treat it as evidence only.
- **Tool-only execution**: the model proposes typed tool calls; Policy Gate mediates allow/ask/deny.
- **Explicit egress**: share/export/integrations are always explicit.

---

## High-Level Architecture (Fortress Loop)

At a high level:

- the Safari extension reads the page (observe) and performs allowed browser primitives
- Agent Core packages context, runs the model, and persists collections/artifacts
- UI is a small **Preact + TypeScript** app (built with **Vite**) that renders safe Markdown and provides controls for collect/transform/share (shared across sidecar/panel/viewer)

```text
Untrusted Web (Safari tab)
  |  observe + safe primitives
  v
Safari Extension (observe/act, UI)
  |  typed messages
  v
Agent Core (policy gate, storage, model runner)
  |  LLMCP request/response
  v
LLM Runtime (local by default; optional BYO cloud)
```

---

## Goal Parsing + Heuristic Gating (P0)

Goal parsing should avoid extra model calls when heuristics are confident:

- If the user clearly asks for **comments**, classify as `commentSummary`.
- If the user names an **ordinal/item** on list-like pages, classify as `itemSummary`.
- If the user explicitly asks for a **summary/overview**, classify as `pageSummary`.

Only call the model for goal parsing when intent is ambiguous or action-oriented. Log whether the goal plan came from the model, heuristics, or fallback rules so we can audit impact on accuracy and latency.

---

## References

- "If NotebookLM Was a Web Browser" (inspiration for browser-native source collection workflows): https://aifoc.us/if-notebooklm-was-a-web-browser/
- Google: NotebookLM "Discover sources" (search-first source gathering): https://blog.google/technology/google-labs/notebooklm-discover-sources/
- Perplexity: Comet (session-native AI browsing direction): https://www.perplexity.ai/comet
- Microsoft: Copilot Mode in Edge (tabs/history as context): https://www.microsoft.com/edge/copilot-mode
- TechCrunch: Copilot Mode in Edge (summary + framing): https://techcrunch.com/2025/07/28/microsoft-edge-is-now-an-ai-browser-with-launch-of-copilot-mode/
