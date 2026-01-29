# Laika UI: Collections + Sources + Chat + Transforms

Purpose: define the UI surfaces, layouts, and interaction flows for the **collection-first** Laika (Safari). This doc is intentionally practical: it maps user-visible actions to the underlying **tools** and **LLM tasks** (LLMCP), and it specifies what must be rendered safely.

Non-goals:
- Pixel-perfect styling.
- Browser-vendor specifics (Chrome side panel wiring, context menus, etc.).
- Interactive HTML/JS artifacts in P0 (can be added later behind a strict sandbox).

Related:
- `docs/Laika_pitch.md` (what we are building, why it matters)
- `docs/laika_vocabulary.md` (Collect/Ask/Summarize/Compare/Transform verbs)
- `docs/LaikaArch.md` (architecture + safety posture)
- `docs/logging.md` (logging + audit: structured events and redaction posture)
- `docs/safehtml_mark.md` (Safe HTML <-> Markdown: capture + rendering + sanitization)
- `docs/llm_context_protocol.md` (LLMCP request/response + tool schemas)
- `src/laika/PLAN.md` (implementation plan and phases)

---

## 1) UI surfaces (where Laika lives)

Laika should feel like one coherent app that can render in multiple places:

1) **Sidecar (attached)**
   - An in-page panel attached to the current tab.
   - Best for "collect links from what I'm reading" and quick Q&A.

2) **Panel window (detached)**
   - A larger, persistent workspace window.
   - Best for managing collections, running transforms, and reading artifacts.

3) **Artifact viewer tab**
   - A trusted viewer surface (a dedicated tab/window) for opening saved artifacts.
   - Uses the same safe renderer as chat.

Design invariant: every surface renders only **allowlisted UI** and **sanitized rendered HTML** produced from Markdown. No raw model HTML.

---

## 1.5) UI implementation (tech stack + packaging)

The vNext Laika UI is an app (tabs, lists, modals, background statuses), so we should build it like one.

Decision:
- UI: **Preact + TypeScript**
- Build: **Vite**

Implementation direction:
- One UI codebase builds to static assets bundled with the Safari extension.
- The same UI app runs in multiple surfaces, selected by a query param:
  - `?surface=sidecar` (attached)
  - `?surface=panel` (detached)
  - `?surface=viewer` (artifact viewer)
 - Proposed layout: UI source `src/laika/extension/ui/` -> build output `src/laika/extension/ui_dist/`.

Packaging constraints (Safari extension):
- No remote code or runtime fetches for UI code (everything shipped in the extension bundle).
- Avoid `eval`/`new Function` in production bundles (CSP-compatible output).
- Keep the Markdown pipeline shared and deterministic across surfaces (see `docs/safehtml_mark.md`).

---

## 2) Global shell (common layout across surfaces)

All surfaces share the same app shell:

- Top bar: collection switcher + global actions
- Primary nav: `Sources | Chat | Transforms | Settings`
- Content area: tab-specific UI

```text
+--------------------------------------------------------------------------------+
|  Laika  |  Collection: [ Kyoto Trip Planning v ]   [ Collect + ]   [ ... ]     |
|--------------------------------------------------------------------------------|
|   Sources   |   Chat   |   Transforms   |   Settings                           |
|--------------------------------------------------------------------------------|
|                                                                                |
|   (active tab content)                                                         |
|                                                                                |
|--------------------------------------------------------------------------------|
|   (contextual footer; e.g. chat composer on Chat tab)                           |
+--------------------------------------------------------------------------------+
```

### Top bar (collection-aware)

Elements:
- **Collection switcher**: shows active collection name; dropdown to switch; quick "New collection...".
- **Collect +**: opens the Collect modal (two entry points: session + search).
- **Overflow menu**: rename collection, delete collection, export collection metadata, diagnostics.

Rules:
- Most actions are scoped to the active collection.
- If no collection is selected, Laika guides the user to create one (empty state).

---

## 3) Sources tab (Collect + manage sources)

The Sources tab is the "evidence locker" for the collection: what you have, what's captured, what failed, what to add next.

### 3.1 Layout

Sidecar-friendly layout (single column):

```text
Sources (Collection: Kyoto Trip)

[ Collect + ] [ Paste URL ] [ Add note ]

Capture queue: 6/10 captured  (2 pending)  (2 failed)  [Retry failed]

Sources
--------------------------------------------------------------------------------
o  (captured)  "Hotel A - booking page"            example.com         [Open]
o  (pending)   "Hotel B"                           example.org         [...]
o  (failed)    "Hotel C"                           example.net         [Retry]
o  (note)      "Constraints: $250/night, Gion..."  (note)              [Edit]
--------------------------------------------------------------------------------

(Optional P1) Suggested next sources
  - "Area guide: Gion walkability"  score 0.82  [Add]
  - "Cancellation policy explainer" score 0.74  [Add]
```

Panel window layout (optional split view):

```text
+----------------------------------+-------------------------------------------+
| Sources (10)                     | Source detail                             |
|----------------------------------|-------------------------------------------|
| o Hotel A (captured)             | Title, URL, captured-at, status            |
| o Hotel B (pending)              |-------------------------------------------|
| o Hotel C (failed)               | Preview / summary (optional P1)            |
| o Note: constraints              | Captured text (bounded)                    |
|                                  | Extracted links (P1)                       |
+----------------------------------+-------------------------------------------+
```

### 3.2 Collect modal (two ways)

Collect must support two entry paths:

1) **Collect from session (tabs/selection)**
2) **Collect from search (search results / search + collect)**

```text
Collect sources
--------------------------------------------------------------------------------
From this session
  [Add current tab]  [Add selected links]  (optional) [Pick from open tabs]

From search
  [Collect top results on this page]   (detect current tab is search results)
  Search + collect:
    Query: [__________________________]  Results: (10 v)  [Search + collect]

Also
  [Paste URLs]  [Add note]  (optional P1) [Add images]
--------------------------------------------------------------------------------
```

#### Collect from selected links (preview + confirm)

Because selection link extraction is heuristic, show a preview list with checkboxes:

```text
Selected links (12 found)
[x] https://...
[x] https://...
[ ] https://...

[Add 11 to collection]   [Cancel]
```

### 3.3 Capture status + queue UX

Each URL source has a capture state:
- `pending`: queued or currently capturing
- `captured`: has bounded `captureMarkdown`
- `failed`: show reason code and a retry affordance

Capture queue UX requirements:
- Visible progress (e.g., "Capturing 3/10...").
- Per-source actions: `Retry`, `Open`, `Remove`.
- Clear warnings for partial captures (paywall/login/overlay signals).

### 3.4 Tools used by Sources tab

Collect flows compile down to these tool calls:

- `collection.create` (if needed)
- `collection.add_sources` (urls, notes)
- `browser.get_selection_links` (selected links)
- `browser.observe_dom` (extract items from a search results page)
- `search` (open a search results tab)
- `source.capture` (capture normalized bounded Markdown snapshots)
- `source.refresh` (retry/refresh capture)

Recommended execution sequence (session selection -> capture):

```text
browser.get_selection_links
 -> collection.add_sources(urls)
 -> source.capture(url) for each source (queue)
 -> UI updates statuses
```

Recommended execution sequence (search page -> collect top 10 -> capture):

```text
browser.observe_dom(root=search-results)
 -> extract top N items (urls)
 -> collection.add_sources(urls)
 -> source.capture(url) for each source (queue)
```

---

## 4) Chat tab (Ask / Summarize / Compare with citations)

Chat is always scoped to the active collection. The default behavior is grounded synthesis with citations.

### 4.1 Layout

```text
Chat (Kyoto Trip)   Context: 10 sources (8 captured, 2 pending)

--------------------------------------------------------------------------------
You: Compare these 10 hotels on price, cancellation, walkability, and notes.

Laika:
  (rendered doc; may include a table)

  Citations:
    [1] Hotel A - booking page
    [3] Area guide
    [7] Hotel B cancellation policy
--------------------------------------------------------------------------------

[ Ask about this collection...                                      ] [Send]
```

### 4.2 Citation UI (trust + traceability)

Requirements:
- Citations are **clickable** and map to `Source.id` + `Source.url`.
- Support multiple citations per answer section (chips/cards).
- Optional: open with URL text fragments when available (`#:~:text=`) to jump to the cited passage.

UI pattern:
- Inline markers in the rendered doc (e.g., `[1]`, `[2]`) are optional.
- The durable, machine-parseable citations list lives below the message, so it can't be "styled away".

### 4.3 Chat result rendering (rich, safe)

Chat messages render from `assistant.markdown` (canonical Markdown output).

P0 renderer must support:
- headings, paragraphs, lists, blockquotes, code blocks
- links (http/https/mailto)
- **tables** (comparison output is a primary use case)

Rendering must follow the Markdown -> safe HTML pipeline in `docs/safehtml_mark.md`.

### 4.4 LLM tasks used by Chat tab

Chat uses LLMCP tasks with collection context packs:

- `web.answer` for Ask/Compare
- `web.summarize` (optional) for single-source summarization if invoked from Source detail

Context packing (P0 direction):
- Include one `collection.index.v1` doc (lightweight list of sources).
- Include N `collection.source.v1` docs (bounded captured text).
- Use heuristic or two-pass compression when N is large (see `docs/LaikaArch.md`).

Citations contract (P0):
- Responses must include structured citations that map to sources:
  - at minimum: `source_id` (or `doc_id` for single-page), `url`, and a short `quote`/`excerpt`

---

## 5) Transforms tab (named generators -> durable artifacts)

Transforms are the "repeatable output formats" layer. They create artifacts you can reopen and share.

### 5.1 Layout

```text
Transforms (Kyoto Trip)

Pick a transform
  [ Comparison table ] [ Timeline ] [ Executive brief ] [ Flashcards ] [ Quiz ]

Config
  Depth: (concise v)   Items: (10 v)   Tone: (neutral v)
  Custom instructions:
    [_________________________________________________________]

[Run transform]   (runs in background; can be cancelled)

Artifacts (saved outputs)
--------------------------------------------------------------------------------
o  Comparison table (completed)   updated 2m ago   [Open] [Export]
o  Executive brief (running 40%)  started 10s ago  [Cancel]
o  Timeline (failed)              [Retry] [View logs]
--------------------------------------------------------------------------------
```

### 5.2 Transform execution UX

Requirements:
- Transforms are background/resumable.
- Each run has an explicit status and a stable `artifactId`.
- The UI always shows which collection and which sources were used.
- Errors are actionable ("Source 4 capture failed; retry capture").

### 5.3 Artifact viewer (trusted, reopenable)

Artifact viewer is a dedicated surface for reading/sharing:

```text
+--------------------------------------------------------------------------------+
| Artifact: "Kyoto hotels comparison"   (Kyoto Trip)   [Copy] [Export]           |
| Sources used: [1] Hotel A ...  [2] Hotel B ...  [3] Area guide ...             |
|--------------------------------------------------------------------------------|
| (rendered doc; tables supported; links sanitized)                               |
|--------------------------------------------------------------------------------|
| Notes / verification checklist (optional section)                               |
+--------------------------------------------------------------------------------+
```

### 5.4 Tools used by Transforms tab

- `transform.list_types`
- `transform.run`
- `artifact.save` (if the transform returns a doc and we want to explicitly persist)
- `artifact.open` (open in viewer)
- `artifact.share` (explicit egress; P0: clipboard + file export; P1: share sheet)

Transform results should be stored as:
- `Artifact.contentMarkdown` (Markdown)
- `Artifact.sourceIds[]`
- `Artifact.type`, `Artifact.title`
- `Artifact.status`

---

## 6) Settings tab (models, privacy, trust controls)

Settings should reinforce the "fortress" posture: clear boundaries, explicit choices, auditable behavior.

P0 settings:
- Active model (local default)
- Context limits (max sources / token budget knobs)
- Automation/test flags (dev only)

P1 settings:
- Optional BYO cloud models (explicit opt-in)
- Usage/cost tracking (when using cloud models)
- Tool permissions UI (Operator mode groundwork)

---

## 7) Rich rendering + safety (what UI must enforce)

### 7.1 Rendering rules

- Render Markdown to HTML in trusted UI, then sanitize with a strict allowlist.
- Sanitize links (http/https/mailto only).
- Never inject model-authored HTML directly into privileged UI surfaces.

### 7.2 Citations as first-class UI objects

Citations should not be "just text".

Minimum UI representation:
- `source_id` -> resolve to source title + URL
- short excerpt / quote
- click opens source URL

This makes outputs reviewable and "trustable" by default.

### 7.3 Separation of concerns (defense-in-depth)

- The model writes **documents**, not DOM.
- The model proposes **tool calls**, not actions.
- Policy Gate mediates anything that mutates state or causes egress.

---

## 8) Reference flows (end-to-end)

### Flow A: Thread -> collect selected links -> compare -> table

```text
User selects links on page
 -> Sources tab: Collect + -> Add selected links -> confirm
 -> collection.add_sources + source.capture queue runs
 -> Chat tab: "How do these outlets differ? Cite."
 -> web.answer returns assistant.markdown + citations
 -> Transforms tab: Run "comparison" -> artifact saved
 -> artifact.open in viewer
```

### Flow B: Search -> collect top 10 -> brief + checklist

```text
User opens a search results page
 -> Sources tab: Collect + -> Collect top results (10)
 -> capture queue
 -> Transforms tab: Executive brief (include "what to verify")
 -> artifact.open + artifact.share (clipboard)
```

---

## References

- Inspiration for a browser-native source collection + query workflow: https://aifoc.us/if-notebooklm-was-a-web-browser/
- Implementation reference (for UI patterns like sources list, citations, transforms, sandboxing): `./NotebookLM-Chrome/`
