# Laika Workflow Vocabulary (Internal)

This doc defines a small, composable **high-level workflow vocabulary** for Laika: a browser-native system that turns a user's web session (tabs, search results, pages) into collections that can be queried and transformed.

Laika's thesis:

- The browser is the execution environment (state, identity, permissions)
- The web is the data source and context
- LLMs are the capability engine that turns context into structures you can reuse

The goal is to make multi-source work in the browser predictable:

- easy to plan (for the model)
- easy to gate (for Policy Gate)
- easy to audit (for the user)

Laika has a simple yet very extensible pipeline:

**Collect -> Ask/Summarize/Compare -> Transform -> Save/Share**

Users should write normal prompts. Internally, Laika can translate intent into one or more of the verbs below.

Related docs:

- `docs/Laika_pitch.md` (product narrative and examples)
- `docs/LaikaOverview.md` (architecture + safety posture)
- `docs/laika_ui.md` (UI layouts + flows)
- `docs/llm_context_protocol.md` (JSON protocol + tool schemas)
- `docs/safehtml_mark.md` (Safe HTML <-> Markdown: capture + rendering + sanitization)

---

## 1) Core Objects (What the Verbs Operate On)

### Collection

A **Collection** is a named bundle of sources you want to reason over.

Examples:

- "Kyoto trip planning"
- "Vendor X due diligence"
- "Model release coverage"

### Source

A **Source** is a single captured item.

Common source types:

- URL (a page snapshot: url/title + bounded Markdown + capture timestamp)
- Note (user-authored text)
- Image (optional, for multimodal grounding)

### Artifact

An **Artifact** is a saved output generated from a collection.

Examples:

- executive brief
- comparison table
- timeline
- study guide / quiz / flashcards

Artifacts should be durable and reopenable.

### Citation

A **Citation** is a machine-readable pointer from an output back to one or more sources.

In Laika, citations are not a vibe; they are a contract:

- If the model makes a claim based on sources, it must cite.
- If sources do not support an answer, Laika should say so.

---

## 2) The Vocabulary (High-Level Verbs)

### Collect

Purpose:
- Create or expand a collection by adding sources.

There are two primary collection pathways:

1) **Collect from tabs** (session capture)
- Add current tab / selected tabs / selected links on the current page.

2) **Collect from search** (search mode)
- Start from a search results tab you opened manually.
- Or ask Laika to run a search and collect the top ~8-10 links.

Typical outputs:
- A created/updated collection ID.
- A list of added sources (URLs/notes/images).

Safety notes:
- Collect is read-only with respect to websites.
- Capturing should treat web content as untrusted input.

Implementation mapping (planned tools):

- `collection.create`
- `collection.add_sources`
- `source.capture` (capture bounded Markdown snapshot)

Browser assist primitives commonly used:

- `browser.get_selection_links` (collect links from a highlighted selection)
- `browser.observe_dom` (read a search results page and extract top links)
- `search` (open a search page in a new tab)

Examples (user prompts):

- "Collect these tabs into a new collection called 'Kyoto trip'."
- "Collect the top 10 results from this search page into a collection."
- "Search for 'X' and collect 8 good sources (avoid SEO fluff)."

---

### Ask

Purpose:
- Ask a question over a collection (multi-source Q&A) with citations.

Typical outputs:
- An answer grounded only in the collection's sources.
- Citations for any claim that comes from sources.

Safety notes:
- If the sources do not contain enough information, Laika should say so and suggest what to collect next.

Implementation mapping:

- LLM task: `web.answer` with collection context packs (index + source snapshots)

Examples:

- "What are the top 5 claims across these sources? Cite each claim."
- "Where do the sources disagree, and what evidence does each side give?"

---

### Summarize

Purpose:
- Produce a grounded summary of:
  - a single source, or
  - the whole collection.

Typical outputs:
- A short overview + key takeaways + citations.

Safety notes:
- Summaries must be grounded in the captured source text.
- If content is missing (blocked by login/paywall), say so rather than guessing.

Implementation mapping:

- LLM task: `web.summarize` (single-page) or `web.answer` (collection overview)
- Optionally saved via `artifact.save`

Examples:

- "Summarize this source in 5 bullets with citations."
- "Give me a one-paragraph overview of the whole collection."

---

### Compare

Purpose:
- Produce a structured comparison across sources or options.

Compare is the "decision" verb: it should highlight differences, tradeoffs, and disagreements.

Typical outputs:
- A comparison table, pros/cons list, or ranked recommendation.

Safety notes:
- Comparisons must cite the evidence for each row/claim.
- Avoid invented attributes; if something is unknown, label it unknown.

Implementation mapping:

- LLM task: `web.answer` (freeform compare with citations)
- Or a transform: `transform.run` with `type: "comparison"` (preferred for table outputs)

Examples:

- "Compare these vendors on SSO, retention, pricing, and export options. Cite each cell."
- "Compare the claims across sources and list points of disagreement."

---

### Transform

Purpose:
- Generate a named, reusable output format from a collection.

Transforms are how Laika turns "a pile of sources" into something you can ship.

Typical outputs:
- An artifact ID + renderable document.

Common transform types (directionally):

- `comparison` (table)
- `timeline`
- `executive_brief`
- `report`
- `outline`
- `study_guide`
- `quiz`
- `flashcards`

Safety notes:
- Transform outputs must be safe to render (Markdown -> sanitized HTML in trusted UI).
- If interactive content is ever supported, it must run in a sandboxed surface.

Implementation mapping:

- `transform.list_types`
- `transform.run` (with optional config)
- `artifact.save` / `artifact.open`

Examples:

- "Transform this collection into an executive brief with citations."
- "Create a timeline of events mentioned, and link each event to sources."

---

### Discover (Suggest Next Sources)

Purpose:
- Expand a collection intelligently by recommending what to read next.

Typical outputs:
- A short list of suggested links with reasons and scores.

Safety notes:
- Suggestions must not auto-open or auto-collect without explicit user intent.

Implementation mapping (direction):

- Extract outbound links from captured sources
- Rank/filter via `web.answer`/`web.extract` style tasks
- Add via `Collect` tools

Examples:

- "Suggest 8 additional sources worth adding next and explain why."

---

### Save

Purpose:
- Persist an output as an artifact.

Implementation mapping:

- `artifact.save`

Examples:

- "Save this as 'Vendor X decision memo'."

---

### Share

Purpose:
- Export an artifact (clipboard/file/share sheet) or send it via an integration.

Safety notes:
- Share is explicit data egress. It should always be user-visible and policy-gated.

Implementation mapping:

- `artifact.share`
- `integration.invoke` (optional)

Examples:

- "Export the comparison table as CSV."
- "Copy the executive brief to my clipboard."

---

## 3) Composition Patterns

These are common, repeatable workflows.

### Pattern A: Search-first research

- Collect (search -> top N links)
- Summarize (overview)
- Compare (differences)
- Transform (brief/table)
- Save/Share

### Pattern B: Tabs-first synthesis

- Collect (tabs/selection)
- Ask (Q&A with citations)
- Transform (timeline/comparison)
- Save/Share

### Pattern C: Study loop

- Collect (reading list)
- Summarize (key concepts)
- Transform (flashcards/quiz)
- Save

---

## 4) Low-Level Primitives (Typed Tool Calls)

The high-level verbs above compile down to **typed tool calls** mediated by Policy Gate.

Source of truth: `docs/llm_context_protocol.md`.

At a minimum, the collection workflow depends on:

- `browser.observe_dom`
- `browser.get_selection_links`
- `search`
- `collection.create`
- `collection.add_sources`
- `source.capture`
- `transform.run`
- `artifact.save` / `artifact.open` / `artifact.share`
