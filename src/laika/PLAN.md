# Laika vNext Implementation Plan (Fortress: Collections + Chat + Transforms)

Purpose: rebuild Laika as a **fortress for web work**: a privacy-first, trustable system inside Safari that turns a user's web session (tabs + search results + the pages they visit) into **collections of sources**, then runs **LLM queries and transforms** with citations and durable artifacts.

This is a greenfield refactor. Backwards compatibility is not a goal. We will reuse proven parts of the existing Laika stack (Safari extension + native host + LLMCP JSON contract + Policy Gate + automation harness), but we will restructure UI and core workflows around collections, not single-page chat.

Primary inspirations (conceptual/UI):
- https://aifoc.us/if-notebooklm-was-a-web-browser/
- `./NotebookLM-Chrome/` (implementation reference for sources UI, chat + citations, transforms, sandboxed rendering, background execution)

Related Laika docs:
- `docs/Laika_pitch.md` (product narrative)
- `docs/LaikaArch.md` (architecture + safety posture)
- `docs/laika_vocabulary.md` (Collect/Ask/Transform pipeline)
- `docs/laika_ui.md` (UI layouts + flows; created in this refactor)
- `docs/llm_context_protocol.md` (LLMCP protocol + tool schemas)
- `docs/logging.md` (logging + audit: JSONL event taxonomy + redaction policy)
- `docs/safehtml_mark.md` (Safe HTML <-> Markdown: capture + rendering + sanitization)
- `docs/automation.md` (Safari end-to-end harness)

---

## North star

Laika should feel like this:

1) You collect what you're already looking at (tabs / selected links / search results) into a named collection.
2) You ask questions that are grounded in that collection (with citations you can click back).
3) You generate structured artifacts (tables, briefs, timelines, study assets) that you can reopen and share.

The point is not "chat about the web". The point is "turn browsing into reliable output".

---

## P0 Scenarios (must work end-to-end)

### Scenario 1: Thread -> collection -> differences -> comparison table + timeline

- User highlights a "thread region" full of outbound links and clicks Collect.
- Laika creates a collection, adds the selected links, and captures each source (bounded snapshot + metadata).
- User asks: "How do these sources differ in their claims? Cite each claim."
- User runs transforms:
  - `comparison` (table output)
  - `timeline` (events + citations)
- User opens the artifact in a viewer tab and can jump back to source URLs.

### Scenario 2: Search -> collect top 10 -> compare options -> save brief

- User is on a search results page (opened manually or via Laika).
- User clicks Collect -> "Top results (10)".
- Laika adds ~8-10 links and captures each source.
- User asks: "Give me a 1-page brief with key takeaways, disagreements, and what to verify. Cite."
- User saves the brief as an artifact and exports to clipboard.

### Scenario 3: Study mode -> sources -> flashcards/quiz

- User collects sources from tabs or search.
- User runs transforms:
  - `flashcards` (Q/A)
  - `quiz` (self-contained; safe rendering)
- User reopens artifacts later from the collection.

---

## Constraints to preserve (Fortress invariants)

- Treat all web content as **untrusted input** (evidence only; never instructions).
- Never send cookies/session tokens/raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep Policy Gate authoritative for risky actions and explicit egress.
- Prefer safe rendering (Markdown -> sanitized HTML). No direct raw HTML injection.
- Keep automation harness runnable and meaningful (fixture-first).
- Keep logs privacy-first by default (redacted, structured JSONL; no raw HTML/cookies; previews only via explicit opt-in). See `docs/logging.md`.

Non-goals (P0):
- Fully agentic browsing that clicks around the web by default.
- Cross-site automation beyond explicit, user-approved "operator mode".
- Perfect capture of every page type; bounded, best-effort capture with clear failures is acceptable.

---

## Product shape (what we're building)

### Collections are first-class

Laika UI must expose:
- a collection switcher
- sources list with capture status
- chat scoped to the active collection
- transforms scoped to the active collection
- artifact list per collection

### Two ways to Collect (P0)

1) From the session:
- current tab
- selected links on the page (via `browser.get_selection_links`)
- selected tabs (optional / permissions-dependent)

2) From search:
- "collect top results" from a search results page tab
- "search + collect" (open a search tab + collect top results)

### Outputs are artifacts, not ephemeral text

Anything that took work should be saveable and reopenable:
- answers (optional)
- transforms (always)
- notes

---

## Architecture (reuse + changes)

We keep:
- Safari extension (content script + background + UI surfaces).
- Native messaging to the macOS host for model execution.
- LLMCP JSON-only contract with Markdown inputs/outputs.
- Policy Gate patterns and typed tool validation.
- Automation harness approach (local fixtures + Safari UI driver).

We change:
- UI becomes a multi-pane collection-centric app (sources/chat/transforms/settings) instead of a single chat box.
- Agent orchestration splits into two modes:
  - Collection mode (P0): read-first (ask/transform), no browsing actions unless explicitly asked.
  - Operator mode (P1+): gated browser actions with explicit approvals and hard stops.
- Persistence becomes collection-centric (sources/artifacts), not just chat history.

---

## Frontend/build choice (P0 decision)

The vNext UI is no longer a "chat box". It's a small app (tabs, lists, modals, background statuses, artifact viewer).

Decision:
- UI: **Preact + TypeScript**
- Build: **Vite**
- Keep the extension background + content script in plain JS initially if that reduces migration risk, then convert when stable.

Why:
- easier to build and maintain a multi-pane UI (state, routing, components)
- easy to adopt "boring good" libraries:
  - Markdown rendering + sanitization (`markdown-it`/`marked` + DOMPurify)
  - DOM -> Markdown capture (`@mozilla/readability` + Turndown)
- enables unit tests for renderer/extractor logic in a normal Node test runner

Packaging constraint:
- the Safari extension ships static JS/CSS assets; Vite should emit into a deterministic folder inside `src/laika/extension/` so Xcode can bundle it.

Repository layout (proposed):
- UI source: `src/laika/extension/ui/`
- Built assets: `src/laika/extension/ui_dist/` (either committed, or built as part of `src/laika_build.sh`)

Security constraint:
- production bundles must be CSP-compatible (no `eval`/`new Function`; no remote code).

---

## Decisions to lock (before coding)

These are the choices that keep the implementation from drifting.

As of 2026-01-29, we are treating the following as confirmed/locked for Phase 0:

- Storage ownership: native SQLite is the source of truth; extension storage is for prefs/flags/small caches only (never source bodies).
- Capture bounds: captured sources are stored as bounded Markdown; default `maxMarkdownChars = 24_000` with explicit truncation markers.
- Citation schema: structured citations with `source_id` (or `doc_id` for single-page), `url`, `quote` (+ optional `locator`, `confidence`).
- Search extraction: "collect top N" uses `browser.observe_dom` items with guardrails (http(s) only, dedupe by normalized URL, skip noise links, optional host diversity cap).
- Renderer: Markdown is canonical; render with `markdown-it` (no raw HTML passthrough) + DOMPurify allowlist + safe link post-processing.
- Tool schema versioning: one schema version per release; strict validation; reject unknown tool names/extra keys; add harness coverage for new tools.

---

## Feedback integration (2026-01-30)

We are incorporating the review notes in `src/feedback.md` as follows:

### Immediate P0 actions (this iteration)
Goal: complete these before moving on to P1 work. Status is tracked inline.

- **Tool surface gating (done):** expose only tools with end-to-end implementations; reject stubbed transforms/artifacts/integrations in plan validation and background allowlist until implemented.
- **Collection context budgeting (done):** cap per-source markdown and overall context size to keep answers stable as collections grow; prefer ranked/trimmed sources when over budget.
- **Capture bookkeeping fixes (done):** populate `capture_jobs.dedupe_key`, increment `attempt_count` on each attempt, and fix relative link extraction.
- **URL normalization consistency (done):** remove tracking parameters and normalize query ordering in the native store; apply similar normalization for pasted/selected URLs in the UI.
- **Durable answers (done):** store answer events in SQLite with citations and reopen via the answer viewer (viewer falls back to stored chat events).
- **Background capture queue (done):** claim `capture_jobs` in the background and run `source.capture` without requiring the sidecar UI.
- **Read-only markdown output (done):** ensure `output.format="markdown"` routes through a markdown-only system prompt for collection answers; JSON parsing is bypassed when markdown output is requested.
- **Context packing fix (done):** prefer `observation.text` for chunking (or whichever is longer), and avoid duplicating identical excerpts in multiple fields.
- **Coverage retry trim (done):** when coverage is missing, retry with only missing sources + prior answer context (avoid resending full collection).
- **Page summarize markdown path (done):** `web.summarize` requests emit `output.format="markdown"` and route through markdown prompting in `generatePlan`.
- **JSON capture start heuristic (done):** start JSON capture at the first `{` anywhere in output rather than disabling after non-JSON preamble.
- **Markdown prompt compaction (done):** stop JSON-encoding full request objects for markdown tasks; send a compact Markdown pack instead.
  - Approach: build a Markdown pack from LLMCP docs (collection sources + page summaries/chunks) with lightweight headers + URLs, and use it for `output.format="markdown"` tasks in the model runner.
- **Open-tab readiness + retry (done):** treat new tabs as a handshake: `browser.open_tab` waits for content-script readiness; if missing, reload once and re-inject, then (if still missing) re-open in the same window. Only as a last resort fall back to `browser.navigate` in the current tab. Log error details so we can diagnose host/permission failures.
- **Streaming markdown to UI (pending):** stream markdown outputs into the popover/answer viewer for faster perceived latency.
- **Prompt/packing telemetry (done):** log prompt size stats (`systemPromptChars`, `userPromptChars`, `contextChars`) and packing metrics (`chunkCount`, `textChars`, `primaryChars`).
- **Goal parse heuristic gating (done):** avoid extra model calls when heuristics can resolve page/item/comment intent.

### P1 follow-ups (design work queued)
- **Capture pipeline ownership:** evaluate a native-managed scheduler + retry/backoff policy now that the background queue claims jobs.
- **On-demand content scripts:** avoid heavy global injection (Readability/Turndown) and only inject when capture is requested.
- **Collection answer ranking/compression:** add ranking + summary compression to keep citations stable within budget.

### Feedback integration (2026-01-31)

Immediate P0 actions (this iteration):
- **Summarize observes include Markdown (done):** set `includeMarkdown=true` + `captureMode`/`captureMaxChars` defaults in popover/harness; disable `captureLinks` for summarize flows to reduce noise.
- **Capture reuse by navigation (done):** cache Readability/Turndown capture results per `navigationGeneration` + options to avoid repeated heavy DOM parsing during multi-step runs.
- **Chunking tail coverage (done):** remove implicit max-chunk caps, align chunk sizing with `captureMaxChars`, and include a tail sample chunk when truncation happens.
- **LLM pack de-duplication (done):** when `markdownChunks` are present, omit full `markdown` from the summary doc and rely on chunk docs only.
- **Capture links default (done):** default `captureLinks=false` for summarize/observe, explicitly enable for `source.capture` only.

Additional P0 actions (this iteration):
- **MaxTokens override without reload (done):** keep model runners alive across per-request token changes; apply max token caps per request instead of reloading the model.
- **Capture job lease reset (done):** requeue stale `running` capture jobs so pending sources do not get stuck indefinitely after crashes.
- **Run cache LRU (done):** add a small LRU/TTL for `cachedListItemsByRun` to prevent unbounded growth.
- **Observe defaults centralized (done):** share observe budgets across UI/agent/harness to avoid drift.
- **Answer viewer durability (done):** open answers via stored chat events instead of ephemeral in-memory payloads.
- **Fallback capture cleanup (done):** remove link lists and use paragraph-aware truncation for fallback markdown.
- **Capture noise split (done):** separate noise tags vs selectors to avoid Turndown selector misuse.
- **Collection answer ranking + summary fallback (done):** rank sources by question overlap and use per-source summaries to fit more sources into budget.

### Feedback integration (2026-01-31 continued)

Immediate P0 actions (this iteration):
- **Long-page chunk sampling (done):** replace head+tail truncation with head + evenly-spaced mid chunks + tail to preserve middle coverage.
- **Markdown citations block (done):** require a deterministic `---CITATIONS---` block for markdown answers and parse it into `assistant.citations`.
- **Navigation tool tab identity (done):** return `tabId` (and `url`) from `browser.navigate/back/forward/refresh` and standardize error details.
- **Focus-once readiness (done):** only focus the newly created tab once during readiness retries to reduce flake.
- **Capture status clarity (done):** surface capture job state (queued/running) so “pending” is not ambiguous.
- **Capture error taxonomy (done):** ensure capture failures always return `errorDetails` with stable `code` and `stage`.
- **Markdown postprocess module + tests (done):** move post-process helpers to a shared module and add unit tests.
- **Fixture-based capture tests (done):** add a Playwright-based harness that runs capture on HTML fixtures and asserts key content is preserved.

### Feedback integration (2026-02-01)

Immediate P0 actions (this iteration):
- **Citations block reachability (done):** require the `---CITATIONS---` block whenever a collection-scoped markdown answer is requested (not just `collection.answer`), and add a unit test that exercises the prompt + parser.
- **Auto capture mode (done):** when `captureMode="auto"` and markdown is requested, pick list/article mode based on the already-computed observation shape before running Readability.
- **Optional link extraction (done):** default `source.capture` to `captureLinks=false` and only enable when explicitly requested.
- **Long-page coverage test (done):** add a fixture assertion that fails under head+tail truncation and passes under head+mid+tail sampling.
- **Plan consistency (done):** update “Capture limits” to reflect the actual sampling/marker behavior for content-script capture vs fallback.

### Persistence boundaries (source of truth)

P0 decision: **native SQLite is the source of truth** for user data.

- Native app (SQLite): `Collection`, `Source` (including `captureMarkdown`), `Artifact`, `ChatEvent`, capture jobs/queue, usage records.
- Extension storage: UI prefs (sidecar placement, last active collection per window), automation flags, small caches (never source bodies).
- Viewer tabs/windows: read artifacts from native SQLite (via native messaging), not from page state.
- Schema reference: `docs/sqlite_schema_v1.sql` (tables + indexes).

Sync (P0):
- No cross-device sync.
- Multiple UI surfaces (sidecar/panel/viewer) share state by talking to the same native store.

### IDs + schema conventions

P0 decision: **string IDs with a type prefix + UUID**.

- `Collection.id`: `col_<uuid>`
- `Source.id`: `src_<uuid>`
- `Artifact.id`: `art_<uuid>`
- `ChatEvent.id`: `chat_<uuid>`
- `CaptureJob.id`: `job_<uuid>`

Source fields to add early (for dedupe + recapture):
- `normalizedUrl` (for URL sources)
- `contentHash` (hash of `captureMarkdown`)
- `captureVersion` (int; bump when capture algorithm changes)
- `captureError` (string; last failure reason for UI)

Indexing (SQLite):
- `(collectionId, createdAt)` and `(collectionId, updatedAt)` on collections/artifacts/chat
- `(collectionId, capturedAt)` on sources
- `normalizedUrl` (unique per collection, or unique globally depending on future UX)

### Capture limits (what "bounded" means)

P0 capture contract:
- Store bounded **Markdown** per source: `captureMarkdown`.
- Default cap: `maxMarkdownChars = 24_000` (tunable).
- Truncation strategy (content-script capture):
  - Sample **head + evenly-spaced mid chunks + tail** within the budget.
  - Append a generic marker that does **not** imply first/last coverage:
    - `[Truncated: captured partial content]`
- Fallback truncation (background observe fallback):
  - Keep head + tail and insert:
    - `...\\n\\n[Truncated: captured first N chars and last M chars]`
- Optional chunking (if needed for large sources):
  - `chunkSize = 8_000`, `maxChunks = 6` (stored as separate rows or a side table).

### Search extraction (top N results)

P0 decision: for "collect top 10" on search pages:
- Use `browser.observe_dom` and prefer `observation.items[]` (already tuned for list/search pages).
- Extract up to N URLs with guardrails:
  - http(s) only
  - dedupe by `normalizedUrl`
  - skip obvious noise links (login/privacy/terms/share/rss/etc.)
  - keep lightweight diversity (cap same-host results, e.g. max 2 per host) when the user asks for "good sources"

Engines (P0):
- Support at least the engines already detected by the current extractor (Google/Bing/DuckDuckGo).
- Treat per-engine selectors as an optimization; keep a generic fallback that works on fixture pages.

### Citation model (concrete contract)

P0 citation object must be sufficient for a user to verify a claim quickly:
- `source_id` (preferred for collections) or `doc_id` (single-page)
- `url`
- `quote` (short excerpt)
- optional: `locator` (text fragment or section hint) and `confidence` (0..1)

### Renderer choice (single shared pipeline)

P0 decision:
- Markdown renderer: **markdown-it**
- Sanitizer: **DOMPurify** with a strict allowlist
- One shared config/module used by sidecar + panel + viewer so outputs are consistent.

### Tool schema versioning + rollout

P0 decision:
- Tool schemas are versioned and validated in trusted code.
- Unknown tool names/extra keys are rejected at the boundary (validator is authoritative).
- Rolling out a new tool requires:
  - adding it to the schema + validator,
  - updating the system prompt that enumerates allowed tools,
  - adding at least one harness scenario that exercises it.

### Concurrency + dedupe (soft locks)

P0 decision: avoid double-running captures/transforms by treating "background work" as durable jobs.

Guidance:
- Prefer soft locks: persisted job status + best-effort in-process de-dupe sets.
- Never assume a lock survived restart. On startup:
  - reset `capture_jobs.status` from `running` -> `queued` and resume,
  - reset `artifacts.status` from `running` -> `pending` and resume or mark failed with a reason.

Capture de-dupe (direction):
- De-dupe by `(collectionId, normalizedUrl, captureVersion)`.
- Implementation: compute a stable `capture_jobs.dedupe_key = sha256("capture:" + collectionId + ":" + normalizedUrl + ":" + captureVersion)`.
- Enforce "only one active capture job at a time" (unique partial index) and short-circuit if an identical job is already queued/running.

Transform de-dupe (direction):
- De-dupe by `(collectionId, transformType, sourceIds hash, config hash)`.
- Implementation: compute `artifacts.dedupe_key = sha256("transform:" + collectionId + ":" + transformType + ":" + sourceIdsHash + ":" + configHash)`.
- Enforce "only one active transform per dedupe key" (unique partial index) to avoid duplicate artifacts and confusing UI.

---

## Data model (vNext)

Minimum entities (no compat required):

- Collection
  - `id`, `title`, `createdAt`, `updatedAt`, `tags?`

- Source
  - `id`, `collectionId`
  - `kind`: `url` | `note` | `image`
  - `url?`, `title?`, `capturedAt`, `updatedAt`
  - `normalizedUrl?`
  - `captureStatus`: `pending` | `captured` | `failed`
  - `captureVersion` (int)
  - `contentHash` (hash of `captureMarkdown`)
  - `captureError` (string; last failure)
  - `captureSummary` (short)
  - `captureMarkdown` (bounded; may be chunked)
  - `links[]` (extracted outbound links; optional P0)

- ChatEvent (per collection)
  - `id`, `collectionId`, `role`, `contentMarkdown`, `citations[]`, `createdAt`

- Artifact
  - `id`, `collectionId`, `type`, `title`, `contentMarkdown`, `sourceIds[]`, `citations[]`, `createdAt`, `updatedAt`
  - `status` for background transforms: `pending` | `running` | `completed` | `failed` | `cancelled`
  - `dedupeKey` (stable hash; prevents duplicate active runs)

 - CaptureJob (recommended P0)
  - `id`, `collectionId`, `sourceId`, `url`
  - `status`: `queued` | `running` | `succeeded` | `failed` | `cancelled`
  - `attemptCount`, `maxAttempts`, `lastError`, `createdAt`, `updatedAt`
  - `dedupeKey` (stable hash; prevents duplicate active runs)

---

## Tools and contracts (what needs to exist)

We will align on the tool surface defined in `docs/llm_context_protocol.md` and extend it as needed.

P0 tool set (minimum):

- Collect / storage
  - `collection.create`
  - `collection.add_sources`
  - `collection.list_sources`
  - `source.capture`
  - `source.refresh` (optional P0; useful for stale sources)

- Ask / transforms
  - `web.answer` (LLMCP task; collection-scoped)
  - `transform.list_types`
  - `transform.run`

- Artifacts
  - `artifact.save`
  - `artifact.open`
  - `artifact.share`

Browser primitives already present and heavily reused:
- `browser.observe_dom`
- `browser.get_selection_links`
- `browser.open_tab` / `browser.navigate` (for capture pipeline)
- `search` (open search tab)

Rendering contract (P0):
- Markdown is the canonical output for chat + artifacts.
- Renderer must support GFM-style tables and sanitize links/content (see `docs/safehtml_mark.md`).
- Interactive HTML artifacts (if ever supported) must render only in a sandboxed viewer surface (P1+).

Citations contract (P0):
- answers/transforms must return structured citations per claim/section, mapped to `Source.id` and URL.
- UI shows citations as clickable chips/cards and can open source URLs (optionally with `#:~:text=` fragments when available).

---

## Key risks (P0) and mitigations

- Safari background capture reliability: background tabs may not fully render.
  - Mitigate with: wait-for-ready + timeouts, retries, and "capture from existing tab if already open" preference.
- Large source payloads (storage + LLM context limits).
  - Mitigate with: bounded `captureMarkdown`, relevance ranking before `web.answer`, and per-source summaries for mid-tier sources.
- Multi-surface UI state drift (sidecar/panel/viewer disagree on active collection).
  - Mitigate with: one "active collection" source of truth in native store + a small shared state subscription API.
- Privacy invariants drift over time.
  - Mitigate with: boundary validators (no raw HTML/cookies), unit tests that assert sanitization and redaction, and harness scenarios that catch regressions.
- Concurrency hazards (double-running captures/transforms; confusing status/UI).
  - Mitigate with: explicit job statuses + dedupe keys in SQLite, partial unique indexes for "active" jobs, and restart-safe resumption rules.

---

## UI work (P0)

See `docs/laika_ui.md` for detailed layout and flows.

We will build a single UI that can render in:
- the attached sidecar (in-page)
- the detached panel window
- the artifact viewer tab

Key UI features:
- collection switcher (create/rename/delete)
- Sources view (list + capture state + add/collect affordances)
- Chat view (streaming status + citations cards)
- Transforms view (cards + run + results list)
- Settings view (model selection; privacy toggles; automation toggles)

---

## Implementation phases

## Recommended early implementation sequence (vertical slice)

We should build vNext as a single end-to-end slice before expanding breadth:

1) Phase 0 UI shell + shared Markdown renderer (tables + sanitization).
2) Minimal persistence (collections + sources + artifacts) in native SQLite.
3) Collect flow v1: current tab + selection links + capture status UI.
4) Capture pipeline v1: Readability -> Turndown -> bounded `captureMarkdown` (+ retry).
5) `web.answer` with citations over a small, fixed top-N source set.
6) First artifact: `comparison` transform + viewer (Markdown table).

This aligns the codebase, docs, and harness around one "real" workflow early.

### Phase 0 — Reset + foundations (1-2 weeks)

Goal: make the codebase ready for collection-centric work.

- Replace the popover UI with a new app shell (tabs: Sources / Chat / Transforms / Settings).
- Extract a shared Markdown renderer (Markdown -> sanitized HTML) from the UI and add:
  - table support
  - better link styling and copy affordances
- Wire the shared renderer into the current UI surfaces (popover sidecar/panel) for Markdown output rendering.
- Define the new persistence interfaces (Swift + JS) for collections/sources/artifacts.
- Update tool schema snapshots / validators to include P0 tool names and reject unknown keys.
- Establish a shared renderer module and tests:
  - `src/laika/extension/lib/markdown_renderer.js` as the canonical Markdown -> safe HTML path.
  - Unit tests under `src/laika/extension/tests/markdown_renderer.test.js` (tables, links, HTML passthrough disabled).
- Update validator + snapshot to match `docs/llm_context_protocol.md`:
  - `src/laika/extension/lib/plan_validator.js`
  - `src/laika/shared/Tests/LaikaSharedTests/Resources/tool_schema_snapshot.json`

Exit criteria:
- UI shell loads in both sidecar and panel window.
- Renderer supports tables and is shared across surfaces.
- Tool validation accepts P0 tool names (even if handlers are stubbed).

### Phase 1 - Collections + Sources UI (2-3 weeks)

Goal: users can create collections and add sources from session/search.

- Implement collection CRUD:
  - create, rename, delete
  - set active collection
- Implement Source list UI with capture status and basic metadata.
- Implement Collect flows:
  - current tab -> add as source
  - selection links -> add N sources
  - search results page -> collect top N links
  - paste URLs + add note
- Add a capture queue UI (progress, failures, retry).

Exit criteria:
- Scenario 1 collection creation + adding selected links works.
- Scenario 2 collect top results works (at least for fixture search pages).

### Phase 2 - Source capture pipeline (2-3 weeks)

Goal: sources have usable Markdown snapshots for Q&A and transforms.

- Implement `source.capture`:
  - open URL in background tab (or capture from existing tab if already open)
  - run content-script capture (Readability -> Turndown -> bounded Markdown)
  - fallback to `browser.observe_dom` -> best-effort Markdown when direct capture fails
  - persist `captureVersion` + `contentHash` and set `captureError` on failures
  - extract outbound links list (optional P0)
- Persist captured sources (SQLite in native host preferred; extension storage only for small metadata).
- Implement refresh/retry semantics.

Exit criteria:
- Captured sources have consistent bounded Markdown.
- Capture failures are visible and recoverable.

### Phase 3 - Collection-scoped Chat (Ask/Summarize/Compare) (2-3 weeks)

Goal: ask questions over the collection with citations.

- Implement `web.answer` over collection context packs:
  - include collection index + top-N sources
  - add context compression:
    - single-pass heuristic (fast)
    - two-pass relevance ranking + summarization (better)
- Implement citations extraction and UI:
  - citation chips/cards below the answer
  - click -> open source URL (with fragment when possible)
- Store chat history per collection.

Exit criteria:
- Scenario 1 question produces cited synthesis across sources.
- Chat history persists and renders safely (including tables in answers).

### Phase 4 - Transforms + Artifacts + Viewer (3-4 weeks)

Goal: transform outputs are durable and viewable.

- Implement `transform.list_types` + initial types:
  - `comparison` (table)
  - `timeline` (markdown)
  - `executive_brief` (markdown)
  - `flashcards` (markdown)
  - `quiz` (markdown; safe rendering)
- Implement `transform.run` with:
  - background/resumable execution
  - statuses (`pending/running/completed/failed/cancelled`)
  - stable artifact IDs
- Implement artifact viewer tab:
  - renders `contentMarkdown` with the shared Markdown renderer
  - shows sources used + citations
  - export/copy/share actions

Exit criteria:
- Scenario 1 transforms run and open in viewer.
- Artifacts persist across restarts.

### Phase 5 - Discover (Suggested Links) (P1)

Goal: recommend what to add next.

- Extract outbound links from captured sources.
- Use an LLM ranking pass to filter/rank candidate links.
- UI shows top suggestions (title + reason + score) with Add buttons.

Exit criteria:
- Suggested links appears when sources contain links.
- Adding suggestions expands the collection and triggers capture.

### Phase 6 - Settings: models, privacy, usage (P1)

- Local model defaults + optional BYO cloud models (explicit opt-in).
- Usage tracking (tokens/cost) when using cloud models.
- Tool permissions and approvals UI (Operator mode groundwork).

---

## Automation and testing plan (must stay green)

We will extend the existing harness rather than replace it.

### Unit tests (fast)
- Renderer tests:
  - markdown table rendering
  - link sanitization
  - sanitizer strips disallowed tags/attrs (script/iframe/on*)
- Extractor tests:
  - selection links dedupe
  - search result extraction for fixture pages

### Safari end-to-end harness (fixture-first)

Add/upgrade scenarios:
- `collection_selection_links.json` (already exists) -> now asserts that a collection is created with N sources.
- `collection_collect_search_results.json` (new) -> fixture search page -> collect top 10 -> capture completes.
- `collection_answer_differences.json` (new) -> ask across collection -> citations present.
- `transform_comparison_table.json` (new) -> transform -> artifact saved -> viewer renders table.
- `transform_timeline.json` (new)

Harness invariants:
- No raw HTML in logs/outputs by default.
- Timeouts aligned (`runTimeoutMs < harnessTimeout < uiTestTimeout`).
- Runs can reset storage to avoid state bleed.

---

## Migration note (no backwards compatibility)

We will not migrate existing chat history keys or UI behavior. Instead:
- introduce new storage keys / SQLite schema
- replace the current popover UI and plan loop entrypoints
- keep the old code only as reference until the new path is stable, then delete

---

## Resolved decisions (before P0 hardening)

Resolved decisions (2026-01-29):

- Minimum SQLite schema for P0: commit to `docs/sqlite_schema_v1.sql` core tables:
  - `collections`, `sources`, `capture_jobs`, `chat_events`, `artifacts` (+ `meta`).
  - `llm_runs` is optional for P1 (safe to keep in schema; not required for Phase 0).
- Offline artifact viewing (no model calls): YES for P0. Artifact viewer loads `artifacts.content_markdown` from SQLite and renders with the shared Markdown renderer.
- Share/export surface (P0): support `artifact.share` with:
  - `target=clipboard` (required)
  - `target=file` (recommended on macOS; Markdown export)
  - `target=share_sheet` can land in P1 (especially for iOS).
- URL de-dupe scope (P0): per-collection dedupe (unique `(collection_id, normalized_url)` for `kind='url'` sources). Global capture caching can be added later without changing UX.
