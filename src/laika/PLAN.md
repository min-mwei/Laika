# Laika implementation plan (focus: source collections + transforms + viewer tabs)

Purpose: implement Laika’s P0 “browser as workshop” workflows by extending the primitive tool surface and app-side persistence so users can:
- collect many sources (URLs/notes) into a durable collection,
- query across them with citations,
- run named transforms (comparison tables, timelines) that produce durable artifacts,
- open artifacts in a dedicated viewer tab/surface.

## P0 scenarios (must work end-to-end)

Scenario 1 (thread → multi-source synthesis):
- User selects many links on a thread/feed page and adds them to a new collection in one action.
- Laika captures/normalizes those sources and can answer “key differences in coverage” with citations per outlet.
- Laika can run `transform.run(type=comparison)` (table) and `transform.run(type=timeline)` (safe document timeline) and open results via `artifact.open(newTab=true)`.

Scenario 2 (shopping shortlist → total cost compare → order links):
- User asks for 5 winter jacket options; Laika produces a comparison table with direct product/order links.
- Total cost is computed as fixed-point money math (base + shipping + tax + optional warranty), with assumptions and “what to verify at checkout”.
- If the user asks Laika to proceed, Laika can navigate to the final checkout review step and must hard-stop before any commit action.

## Constraints to preserve
- Treat all web content as untrusted input.
- Do not send cookies, session tokens, or raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep the Safari extension thin; policy/orchestration/model calls live in the app.
- Log actions in append-only form; avoid storing sensitive raw page content.
- Assist-only mode; do not reintroduce observe-only branches.
- Automation is opt-in: default disabled, explicitly enabled for test runs.

Primary references:
- `docs/Laika_pitch.md` (scenario narrative)
- `docs/LaikaOverview.md` (walkthroughs + architecture + safety expectations)
- `docs/llm_context_protocol.md` (tool schemas)
- `docs/rendering.md` (safe render AST, including tables)
- `docs/automation.md` (Safari automation harness)

---

## Phase 0 — Align schemas + codegen boundaries

1) Make the new primitives first-class in the “single source of truth”
- Ensure tool names and argument schemas are versioned and shared across Swift + extension + docs.
- Add the new tools to the allowed tool list (strict validation; reject unknown tools and extra keys).

2) Rendering schema alignment
- Implement the `table` / `table_row` / `table_cell` nodes described in:
  - `docs/rendering.md`
  - `docs/llm_context_protocol.md` (“Allowed node types”)
- Update the UI renderer to allowlist-render tables (no Markdown parsing).

Exit criteria:
- Schema validation accepts the new tool names (even if they return “unimplemented” initially).
- Rendering supports table nodes end-to-end in the sidecar/companion UI.

---

## Phase 1 — Selection link capture (Scenario 1 on-ramp)

Implement `browser.get_selection_links` (browser primitive).

Tool schema:
- arguments: `{ "maxLinks": number? }` (optional integer, 1..200; default 50)

Tool result (extension → agent runner):
- `{ "status": "ok", "urls": [string], "totalFound": number, "truncated": bool }`

Behavior:
- Returns a unique list of http(s) URLs contained in the user’s current selection.
- Must be robust to:
  - selections inside anchors,
  - selections spanning multiple anchors,
  - multiple selection ranges (where supported),
  - resolved URLs (use `.href`).
- Must be a narrow, read-only primitive (no DOM mutation).
Note: selection can be cleared by focus/UI changes; run extraction immediately on user gesture (before opening/attaching UI that might steal focus).

Policy:
- Treat as read-only (allow by default), but still subject to untrusted input handling.

Validation:
- Add a fixture page with many links (thread/feed layout) and an automation scenario that:
  - sets up a selection automatically on load (avoid brittle UI selection automation),
  - calls `browser.get_selection_links`,
  - asserts the returned URL count and stability.
- Proposed harness scenario: `src/laika/automation_harness/scripts/scenarios/collection_selection_links.json`
- Proposed fixture: `src/laika/automation_harness/fixtures/collection_selection_links.html`

Reference pattern: `NotebookLM-Chrome/src/lib/selection-links.ts` and the injected variant in `NotebookLM-Chrome/src/background.ts`.

---

## Phase 2 — Collections + source capture (durable multi-source context)

Goal: introduce a durable “collection” store and a capture pipeline that normalizes content per source (bounded text + metadata + provenance).

### 2.1 Storage model (Agent Core; SQLite + encrypted artifacts)

Minimum entities:
- `collections`: `{id, title, tags?, createdAt, updatedAt}`
- `sources`: `{id, collectionId, kind(url|note|image|file), url?, title?, capturedAt?, status, wordCount?, signals?, digest?}`
- `source_content`: stored as an encrypted artifact or encrypted blob keyed by `sourceId` (bounded text + outline + extracted links).

Privacy rules:
- “Private window” implies **no persistence** (no collections/sources/artifacts written).
- Default retention should avoid raw page text snapshots for sensitive sites; store derived summaries/structured extracts instead.

### 2.2 Tool surface (app-level)

Implement the tools described in `docs/llm_context_protocol.md`:
- `collection.create`
- `collection.add_sources`
- `collection.list_sources`
- `source.capture`
- `source.refresh`

Key decision: `source.capture` must support “My Browser” (authenticated) capture.

Recommended v1 capture approach:
- In the app (Agent Core), maintain a dedicated “capture tab” (or reuse an existing task tab) that:
  - navigates to the URL (sanitized http/https),
  - runs `browser.observe_dom`,
  - stores `primary` + `outline` + light metadata as normalized content.
- During capture, normalize aggressively:
  - Prefer Readability-style “main content” extraction and boilerplate stripping.
  - Preserve links separately (URL + anchor text + short surrounding context) for “suggested links” and follow-up expansion; avoid stuffing URLs into the main text.

Safety:
- Capture is read-only but still loads a page; treat it as `ask` on sensitive sites/origins if needed.
- Never persist cookies/session tokens; never send raw HTML to the model.

Reference pattern (source cleanup + link extraction): `NotebookLM-Chrome/src/content-script.ts`.

### 2.3 Context packing (collection → LLMCP documents)

Goal: make multi-source Q&A and transforms deterministic by assembling the same bounded context shape every time.

- Build a `collection.index.v1` document (metadata + source list).
- Attach N `collection.source.v1` documents (normalized text + outline + extracted links) for the selected sources.
- Keep total context within a fixed budget; chunk long sources as needed.

Exit criteria:
- Collections and sources persist across runs (non-private).
- Captured sources are bounded and provenance-tagged (URL/title/capturedAt/signals) with optional highlight anchors (e.g., text fragments) for usable citations.

### 2.4 Multi-source Q&A (collection-scoped `web.answer`)

Goal: make “ask across the collection” a first-class operation (distinct from transforms).

- Add a UI affordance for “active collection” (or explicit selection per question).
- Build an LLMCP request using:
  - 1× `collection.index.v1` + N× `collection.source.v1`
  - `input.task.name="web.answer"` with the user’s question
- Require citations that identify the supporting source(s) (URL/title at minimum; highlight anchors when available).

Exit criteria:
- Scenario 1 question (“key differences in how each outlet is covering this story”) produces an answer with per-outlet citations.

---

## Phase 3 — Transforms (comparison + timeline) + durable artifacts

Goal: run named transforms over a collection and store results as artifacts that can be reopened.

### 3.1 Transform runner (Agent Core)

Implement:
- `transform.list_types` (start with: `comparison`, `timeline`)
- `transform.run`

Runner requirements:
- Backgroundable/resumable (survive UI close; resumed from run log/state).
- Policy-gated model invocation (local by default; explicit opt-in for cloud).
- Deterministic output envelopes (artifact metadata + content type + size limits).
- Persistence + recovery:
  - Store transform records with stable IDs and statuses (`pending/running/completed/failed/cancelled`) plus `startedAt/completedAt/error`.
  - Avoid duplicate execution (idempotency key or in-memory “running set” guarded by persistence).
  - Resume pending/running transforms on app restart without replaying side effects.
  - Support cancellation as a state transition (never “best-effort cancel” only in UI).

Output formats:
- Default: store transform output as `assistant.render` Document AST.
- For `comparison`, prefer `table` nodes (not markdown tables).
- For `timeline`, default to a safe document; add interactive HTML only if we ship a sandboxed viewer.
  - For shopping comparisons, ensure the table includes per-item order links and the cost breakdown fields needed for totals (base/shipping/tax/warranty).

### 3.2 Artifact store + viewer

Implement:
- `artifact.save` (if not already executable)
- `artifact.open` (open in Workspace or a trusted viewer tab)

Viewer rules:
- Safe artifacts render using the allowlist Document renderer.
- Interactive artifacts (if supported) must render in a sandboxed container with no extension privileges.

Reference pattern (viewer isolation): `NotebookLM-Chrome/src/sandbox/` + `NotebookLM-Chrome/src/sidepanel/hooks/useTransform.ts`.
Reference pattern (background transforms + resume): `NotebookLM-Chrome/src/background.ts` (transform record lifecycle and startup resume).

Exit criteria:
- `transform.run` produces an `artifactId`.
- `artifact.open` displays the artifact in a dedicated viewer without mixing untrusted HTML into privileged UI.

---

## Phase 4 — Shopping guardrails (Scenario 2)

Goal: make “stop before placing order” enforceable and make totals more correct.

1) Currency-safe math
- Implement `app.money_calculate` (fixed-point) and migrate shopping totals to it.
  - Treat warranty as optional: show totals with/without warranty when possible.
- Prefer structured extraction for inputs:
  - Use `web.extract` (or trusted parsers) to pull `{basePrice, shipping, estimatedTax, warrantyPrice, returnWindow}` per product.
  - When values aren’t available until checkout, either (a) proceed in assist mode until a reliable estimate is shown, or (b) mark as unknown and add a “verify at checkout” row.

2) Tax/shipping estimation (privacy-first)
- Implement `commerce.estimate_tax` / `commerce.estimate_shipping` as local estimators or explicitly gated integrations.
- Store destination profiles locally; include in model context only with explicit user opt-in.

3) Commit-action hard stop
- Extend Policy Gate with commit-action classification (button labels/roles + context) and a run-level “intent” guard:
  - default: deny clicks on “Place order / Pay now / Submit order” when the goal is “stop before purchase”.
  - require explicit user intent change to allow.

Exit criteria:
- Automation can reach a page where a commit action is present and does not click it.
- Logs clearly record why a commit was blocked (stable reason code).

---

## Phase 5 — Automation harness coverage (regression-proofing)

Add fixture-backed scenarios described in `docs/automation.md`:
- selection links capture (`browser.get_selection_links`)
- capture normalization (`source.capture`)
- collection-scoped Q&A (`web.answer` over a collection context pack)
- transforms (`transform.run` → table/timeline artifacts)
- viewer open (`artifact.open`)
- shopping totals table (`app.money_calculate` + order links)
- shopping stop-before-commit invariants

Harness invariants:
- No raw HTML in logs/outputs by default.
- Timeouts aligned (`runTimeoutMs < harnessTimeout < uiTestTimeout`).
- Reporting survives tab teardown (background keepalive/post).

---

## Current status (high level)

Implemented today:
- Core browser primitives (`browser.observe_dom`, click/type/select/scroll, navigation, `search`)
- LLMCP JSON-only response contract and strict tool validation
- Policy Gate for sensitive fields (credential/payment/personal-id)
- Automation harness for fixture scenarios (HN/BBC/SEC) as a foundation

Not yet implemented (required for the P0 scenarios above):
- `browser.get_selection_links`
- Collection/source persistence tools (`collection.*`, `source.*`)
- Transform runner tools (`transform.*`)
- `artifact.open` + dedicated viewer surface
- Table nodes in render AST (and UI support)
- Money + commerce helpers (`app.money_calculate`, `commerce.*`)
