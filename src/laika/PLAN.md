# Laika vNext Implementation Plan (Fortress: Collections + Chat + Transforms)

Purpose: rebuild Laika as a **fortress for web work**: a privacy-first, trustable system inside Safari that turns a user's web session (tabs + search results + the pages they visit) into **collections of sources**, then runs **LLM queries and transforms** with citations and durable artifacts.

This is a greenfield refactor. Backwards compatibility is not a goal. We will reuse proven parts of the existing Laika stack (Safari extension + native host + LLMCP JSON contract + Policy Gate + automation harness), but we will restructure UI and core workflows around collections, not single-page chat.

Primary inspirations (conceptual/UI):
- https://aifoc.us/if-notebooklm-was-a-web-browser/
- `./NotebookLM-Chrome/` (implementation reference for sources UI, chat + citations, transforms, sandboxed rendering, background execution)

Related Laika docs:
- `docs/Laika_pitch.md` (product narrative)
- `docs/LaikaOverview.md` (architecture + safety posture)
- `docs/laika_vocabulary.md` (Collect/Ask/Transform pipeline)
- `docs/laika_ui.md` (UI layouts + flows; created in this refactor)
- `docs/llm_context_protocol.md` (LLMCP protocol + tool schemas)
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

## Frontend/build choice (direction)

The vNext UI is no longer a “chat box”. It’s a small app (tabs, lists, modals, background statuses, artifact viewer).

Recommendation:
- Build the UI in **TypeScript** with a small UI framework (e.g. **Preact**) and a bundler (e.g. **Vite**).
- Keep the extension background + content script in plain JS initially if that reduces migration risk, then convert when stable.

Why:
- easier to build and maintain a multi-pane UI (state, routing, components)
- easy to adopt “boring good” libraries:
  - Markdown rendering + sanitization (`markdown-it`/`marked` + DOMPurify)
  - DOM -> Markdown capture (`@mozilla/readability` + Turndown)
- enables unit tests for renderer/extractor logic in a normal Node test runner

Packaging constraint:
- the Safari extension ultimately ships static JS/CSS assets; the build should emit into `src/laika/extension/` (or a committed `dist/` folder) so Xcode can bundle it.

---

## Data model (vNext)

Minimum entities (no compat required):

- Collection
  - `id`, `title`, `createdAt`, `updatedAt`, `tags?`

- Source
  - `id`, `collectionId`
  - `kind`: `url` | `note` | `image`
  - `url?`, `title?`, `capturedAt`
  - `captureStatus`: `pending` | `captured` | `failed`
  - `captureSummary` (short)
  - `captureMarkdown` (bounded; may be chunked)
  - `links[]` (extracted outbound links; optional P0)

- ChatEvent (per collection)
  - `id`, `collectionId`, `role`, `contentMarkdown`, `citations[]`, `createdAt`

- Artifact
  - `id`, `collectionId`, `type`, `title`, `contentMarkdown`, `sourceIds[]`, `createdAt`, `updatedAt`
  - `status` for background transforms: `pending` | `running` | `completed` | `failed` | `cancelled`

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

### Phase 0 — Reset + foundations (1-2 weeks)

Goal: make the codebase ready for collection-centric work.

- Replace the popover UI with a new app shell (tabs: Sources / Chat / Transforms / Settings).
- Extract a shared Markdown renderer (Markdown -> sanitized HTML) from the UI and add:
  - table support
  - better link styling and copy affordances
- Define the new persistence interfaces (Swift + JS) for collections/sources/artifacts.
- Update tool schema snapshots / validators to include P0 tool names and reject unknown keys.

Exit criteria:
- UI shell loads in both sidecar and panel window.
- Renderer supports tables and is shared across surfaces.
- Tool validation accepts P0 tool names (even if handlers are stubbed).

### Phase 1 — Collections + Sources UI (2-3 weeks)

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

### Phase 2 — Source capture pipeline (2-3 weeks)

Goal: sources have usable text snapshots for Q&A and transforms.

- Implement `source.capture`:
  - open URL in background tab (or capture from existing tab if already open)
  - run `browser.observe_dom` with detail options
  - normalize into bounded `captureMarkdown` (+ optional chunks)
  - extract outbound links list (optional P0)
- Persist captured sources (SQLite in native host preferred; extension storage only for small metadata).
- Implement refresh/retry semantics.

Exit criteria:
- Captured sources have consistent bounded Markdown.
- Capture failures are visible and recoverable.

### Phase 3 — Collection-scoped Chat (Ask/Summarize/Compare) (2-3 weeks)

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

### Phase 4 — Transforms + Artifacts + Viewer (3-4 weeks)

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

### Phase 5 — Discover (Suggested Links) (P1)

Goal: recommend what to add next.

- Extract outbound links from captured sources.
- Use an LLM ranking pass to filter/rank candidate links.
- UI shows top suggestions (title + reason + score) with Add buttons.

Exit criteria:
- Suggested links appears when sources contain links.
- Adding suggestions expands the collection and triggers capture.

### Phase 6 — Settings: models, privacy, usage (P1)

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
