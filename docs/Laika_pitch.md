# Laika: AI Fortress for Web Work (Collect -> Ask -> Transform)

**Move faster on the web and trust what you produce. Private by default.**

Browsers are great at showing pages. They are terrible at helping you *work with* what you read.

Laika is a privacy-first **AI fortress** in **Safari (macOS + iOS)**: a protected workspace that turns your browsing session (open tabs, search results, and the pages you visit) into **collections**. From there, Laika runs LLM-powered **queries and transforms** (summaries, comparisons, briefs, timelines, quizzes) with citations back to sources so the output is reviewable and trustworthy.

Laika's thesis:

- The browser is the execution environment (state, identity, permissions)
- The web is the data source and context
- LLMs are the capability engine that turns context into structures you can reuse

The browser gives you state (sessions, identity, permissions). The web gives you context. LLMs turn that context into structures you can reuse.

That stack enables a fundamentally different way to interact with information: instead of tab-juggling and copy/paste, you build durable outputs directly from your session.

Laika has a simple yet very extensible pipeline:

1. **Collect** sources (from tabs or search)
2. **Ask / Summarize / Compare** with citations
3. **Transform** into an artifact (table, brief, timeline, quiz, etc.)
4. **Save / Share** what you created

## The Problem (Why Browsing Doesn't Convert to Decisions)

- Your research lives in 10-50 tabs, search results, and half-read pages.
- Copy/paste into Docs/Sheets breaks traceability and wastes time.
- Generic chatbots are not grounded in your reading set; you can't reliably answer "where did that come from?"
- The real work is synthesis across sources: reconcile claims, extract evidence, and produce a shareable output.

## The Shift: Collections and Artifacts

Laika turns the browser into a protected workspace:

- **Collection**: a named bundle of sources (URLs, notes, images) captured from your browsing session and searches.
- **Source**: a single captured item (URL + title + bounded Markdown snapshot + provenance).
- **Artifact**: a saved output generated from a collection (brief, table, timeline, quiz, etc.).

The goal is not "one prompt = one answer". The goal is repeatable workflows where sources and outputs stay linked.

## Collect (Two Ways)

Laika supports two primary collection entry points.

### 1) Collect From Browser Tabs (Session Capture)

Use Laika to turn your current browsing session into a collection:

- Add the current tab.
- Add selected tabs.
- On a thread/feed/search page, select a bunch of links and ask Laika to collect them.

Laika captures a bounded Markdown snapshot of each source so the collection can be queried later, and it preserves provenance (URL/title/captured-at).

### 2) Collect From Web Search (Search Mode)

Sometimes you don't have the sources yet.

Laika can collect 8-10 links starting from:

- A search results tab you opened manually ("collect the top 10 results").
- A Laika-initiated web search ("search for X and collect the best 10 sources").

This makes "build a reading list" a first-class action, not a manual tab explosion.

## What Laika Does With Your Collection

### Ask (Q&A with citations)
Ask questions across everything you've collected:

- "What are the key claims and where do the sources disagree? Cite each claim."
- "Extract the dates/metrics mentioned and cite the source for each."
- "What does Source A say that Source B does not?"

### Summarize (single source or whole collection)
Generate:

- A one-paragraph overview of the whole collection.
- Per-source summaries.
- Key takeaways with evidence.

### Compare (structured differences)
Compare is the "decision" move:

- Vendors/products
- Perspectives across outlets
- Approaches across papers/blogs

Laika can output structured comparison tables and include direct links back to sources.

### Transform (turn sources into artifacts)
Transforms generate reusable outputs from the collection, for example:

- Executive brief / report / outline
- Comparison table / pros-cons
- Timeline
- Glossary / FAQ
- Study guide / quiz / flashcards

The intent is: you shouldn't have to reinvent prompts every time you want a familiar format.

### Discover (suggest what to read next)
When your sources contain outbound links, Laika can recommend the most valuable next sources to add ("suggest 8 more links worth reading"), so collections can grow intelligently instead of randomly.

## Example Workflows (How Users Actually Use This)

### 1) Thread -> coverage comparison + timeline

Collect (from a thread/feed/search page):
- "Collect the links I selected into a new collection called 'Model release coverage'."

Ask:
- "How do these outlets differ in their claims? Quote or paraphrase with citations."

Transform:
- "Create a comparison table with columns: outlet, main claim, evidence, link."
- "Create a timeline of events mentioned across sources, with citations."

### 2) Study mode: reading list -> flashcards + quiz

Collect (tabs or search):
- "Search for 'backpropagation intuition' and collect 10 good explanations."

Transform:
- "Create 20 flashcards (question/answer) focused on misconceptions."
- "Generate a 10-question quiz and include explanations."

### 3) Vendor due diligence -> decision memo

Collect:
- "Collect these vendor docs: pricing, security page, DPA, and support terms into a collection called 'Vendor X'."

Compare:
- "Compare Vendor X vs Vendor Y on data retention, SSO, audit logs, and pricing."

Transform:
- "Write a one-page decision memo with a 'what we know' and 'what to verify' section, with citations."

### 4) Trip planning -> options table + itinerary

Collect (search-first):
- "Search for hotels near Gion under $250/night and collect 10 options."

Transform:
- "Make a comparison table (price, cancellation, walkability, notes) and recommend 2 with tradeoffs."
- "Draft a simple 5-day itinerary and a checklist of what to verify before booking."

### 5) Writing mode: sources -> outline -> brief -> email

Collect:
- "Collect these 8 sources into a collection called 'Q1 market update'."

Transform:
- "Create a detailed outline for a 1,000 word report with section headings and citations."
- "Write an executive brief (one page) with a risks/open-questions section."
- "Rewrite the brief as a short email update for leadership."

### 6) Shopping shortlist -> total cost comparison (with guardrails)

Collect (search-first):
- "Search for 5 options that match my criteria and collect the product pages."

Compare/Transform:
- "Build a table with base price, shipping, tax estimate, warranty, return window, and order links."
- "Recommend one and list what I should verify at checkout."

### 7) Visual sources -> explain diagram + integrate

Collect:
- Add a screenshot/diagram as a source alongside articles.

Ask:
- "Explain what the diagram shows and how it relates to the claims in the text sources. Cite the sources you use."

## Why It Feels Trustworthy

- **Grounded by default**: answers and artifacts are linked back to sources with citations.
- **Web content is untrusted input**: page text is treated as evidence, not instructions.
- **Clear safety boundary**: read-only workflows (collect/query/transform) are distinct from write/egress actions.
- **Private by default**: on-device inference is the default posture; optional cloud models are BYO and use redacted context packs.
- **Measurable**: track what was run (and optionally tokens/cost when using cloud models) so teams can reason about usage.

## Where Laika Is Heading

- **Fortress-first**: collections, citations, transforms, and a viewer for saved artifacts.
- **Optional operator mode**: when you explicitly ask, Laika can help with browser actions (forms/checkout) with hard stops and approvals.

For design details: `docs/LaikaOverview.md`, `docs/laika_vocabulary.md`, and `docs/laika_ui.md`.

## References

- "If NotebookLM Was a Web Browser" (inspiration for browser-native source collection workflows): https://aifoc.us/if-notebooklm-was-a-web-browser/
- Google: NotebookLM "Discover sources" (search-first source gathering): https://blog.google/technology/google-labs/notebooklm-discover-sources/
- Perplexity: Introducing Comet (session-native AI browsing direction): https://www.perplexity.ai/hub/blog/introducing-comet
- Microsoft: Copilot Mode in Edge (tabs/history as context): https://www.microsoft.com/edge/copilot-mode
- TechCrunch: Copilot Mode in Edge (summary + framing): https://techcrunch.com/2025/07/28/microsoft-edge-is-now-an-ai-browser-with-launch-of-copilot-mode/
