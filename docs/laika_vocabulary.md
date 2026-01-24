# Laika Action Vocabulary (Internal)

This doc defines a small, composable **high-level action vocabulary** Laika can use internally to decompose a plain-English user request into safer, more reviewable steps. It also defines the canonical **low-level primitives** (typed tool calls) that Laika’s planner model can propose and that Policy Gate can mediate.

Users should write normal prompts. Laika may translate that intent into one or more internal actions like:

`Summarize(Entity), Find(Topic, Entity), Search(Query), Share(Artifact), Investigate(Topic, Entity), Create(Artifact), Price(Artifact), Buy(Artifact), Save(Artifact), Invoke(API), Calculate(Expression), Dossier(Topic, Entity)`.

For end-user scenarios and positioning, see `docs/laika_pitch.md`.

Laika uses a two-layer model:

- High-level vocabulary (this doc’s verbs): intent-level building blocks that are easy to plan, gate, and audit.
- Low-level primitives (typed tool calls): the only executable surface; small, deterministic operations implemented in trusted code (extension/app).

---

## 1. Intro

Laika is a security- and privacy-first AI Browser agent (starting in Safari) designed to help you get real work done on the sites you already use. Instead of being "just a chatbot," Laika is meant to:

- Read what is on the page (treating the web as untrusted input),
- Take safe, reviewable actions in the browser when you opt in,
- Produce durable outputs ("artifacts") like tables, memos, packets, and drafts,
- Keep an audit trail so you can understand what happened and why.

This doc focuses on the internal layer: a set of verbs that map well to how people actually browse, and that are easy to gate, preview, and audit.

If you are interested in the underlying tool execution and safety model, see:

- `docs/laika_pitch.md` (product narrative and examples)
- `docs/AIBrowser.md` (security, permissions, audit, artifacts)
- `docs/llm_context_protocol.md` (JSON context protocol and safe rendering contract)
- `docs/QWen3.md` (Qwen3 programming notes: thinking control, tool calling, deployment)

---

## 2. Why

Browsers are where sensitive work happens: money, identity, health, housing, procurement, and internal enterprise tools. Those workflows are not "one prompt = one answer"; they are multi-step and error-prone.

This vocabulary exists to solve a few practical problems:

1) Reduce ambiguity
- "Help me with this" is unclear; `Find("refund policy", ThisPage)` is clear.
- Clear intent makes it easier for Laika to plan, and easier for you to review.

2) Make safety boundaries explicit
- Read-only actions (like `Summarize`) should feel different from write actions (like `Buy`).
- A compact set of verbs helps the UI and policy layer consistently gate risky steps.

3) Make outcomes reviewable
- Browsing work often ends in outputs: a comparison table, an appeal letter draft, a packet for a dispute, a shortlist.
- Explicit `Create/Save/Share` makes "output" a first-class concept.

4) Make workflows repeatable
- Once you have a good sequence (for example: `Find -> Price -> Create -> Save -> Buy`), you can reuse it.
- Repeatability is a prerequisite for automation and for testing reliability.

5) Improve speed without sacrificing control
- You should be able to say what you want in one line, while still getting previews, approvals, and an audit trail for sensitive steps.

---

## 2.5 Low-Level Primitives (Typed Tool Calls)

Laika uses **typed tool calls** as its low-level primitives. The model only **proposes** these calls; Policy Gate decides allow/ask/deny, and trusted code in the extension/app executes them.

Low-level primitives should be:

- Generic: rely on web platform semantics (DOM + accessibility), not site-specific selectors.
- Efficient: aggressively budgeted, incremental, and safe to run repeatedly.
- Robust: deterministic output shapes, stable error codes, and self-verifying (re-observe after actions).
- Safe: treat web content as untrusted input; avoid data egress unless explicit; sanitize URLs.

Core primitives (v1):

- `browser.observe_dom`: capture page text + element handles (read-only).
- `browser.click`, `browser.type`, `browser.select`, `browser.scroll`: DOM actions.
- `browser.open_tab`, `browser.navigate`, `browser.back`, `browser.forward`, `browser.refresh`: tab actions.
- `search`: web search.

Scope note:

- The catalog in this doc is the browser primitive surface (extension + agent core).
- App-level primitives (artifact store, exports/sharing, connectors, deterministic compute) should also be typed and policy-gated. Their schemas live in `docs/llm_context_protocol.md` under “App-level primitives”.

Notes:

- `handleId` values must come from the current observation.
- There is no legacy `content.summarize` or Markdown summary path; summaries are returned as `assistant.render` Documents (the "Summarize" verb is high-level intent, not a tool).
- Tool schemas live in `docs/llm_context_protocol.md`.
- Tool schemas are the source of truth; section 4.4 summarizes the browser tool catalog and documents reliability/safety rules (and `docs/AIBrowser.md` goes deeper on `browser.observe_dom`).
- Primitive error codes and observation `signals` are part of the interface. Treat them as versioned, stable enums with a single source of truth shared across Swift + JS + docs.

---

## 3. What

Think of the vocabulary as a small set of building blocks for browsing work. Each action is:

- A high-level intention (what outcome you want),
- That can expand into multiple low-level steps (navigate, read, extract, calculate, draft),
- While staying within Laika's safety model (read-only by default; ask before acting; explicit approval for high-risk steps).

### The core "types"

The signatures use a few nouns consistently:

- Entity: the thing you want to operate on.
- Topic: the question, subject, or criteria you're looking for.
- Artifact: an output you want created, saved, shared, priced, or bought.
- API: a configured integration endpoint (for import/export).
- Expression: a concrete computation you want performed.

#### Entity

An Entity is the target context. Common entities in a browser agent:

- The current page/tab: "this page", "this tab", "the active portal"
- A site or section: "Amazon cart", "Chase transactions", "EDGAR filings page"
- A collection: "open tabs", "my saved shortlist", "results on this page"
- A document: "this PDF", "the invoice", "the statement download"

In prompts, entities can be implied:

- "Summarize this page" (Entity is the active tab)
- "Find the refund policy on this page" (Entity is the active tab)

Or explicit:

- `Summarize("Stripe invoice page")`
- `Find("10-K deadline", "SEC EDGAR")`

#### Topic

A Topic is what you're trying to locate or understand:

- "refund policy", "return window", "cancellation terms"
- "material risks", "revenue breakdown", "pricing tiers"
- "which plan includes SSO", "why was this claim denied"

Topics work best when you include constraints:

- time window ("last 90 days")
- geography ("California", "EU")
- thresholds ("under $1200", "greater than 3% APR")
- definitions ("count as 'software' spend")

#### Artifact

An Artifact is a durable output. Typical artifacts for Laika:

- A table (comparison, extracted data, summary sheet)
- A memo/brief (1-pager, executive summary)
- A checklist (steps to do manually, verification list)
- A packet (evidence bundle for a dispute/appeal)
- A draft (email, form text, message to support)
- A saved collection (shortlist, bookmarks, sources)

Artifacts can be described in plain language:

- "a ranked shortlist of apartments"
- "a dispute-ready packet"
- "a price comparison table"
- "a one-page company brief with citations"

#### API

An API is an integration Laika can call to move data in/out of your workspace, for example:

- Google Sheets (append a row, write a table)
- Slack (post a message)
- Notion (create a page)
- Jira (create a ticket)
- Internal enterprise endpoints (procurement request, expense report, CRM record)

`Invoke(API)` is intentionally explicit because it represents data egress (or write access) outside the current browsing context.

#### Expression

An Expression is a computation you want done deterministically, such as:

- "129.99 * 1.0825" (price plus tax)
- "sum of charges tagged 'subscription' in last 90 days"
- "convert 18 kg to lbs"
- "APR to monthly payment estimate"

---

## 4. How

This section documents the vocabulary, what each action means, and how to get reliable results.

### 4.1 Syntax and usage style

Users should write normal prompts:

- "Find the refund policy on this page and draft a short email to support."
- "Investigate why this claim was denied and draft an appeal letter."

Internally, Laika can represent the same intent as an action chain using the vocabulary:

```text
Find("refund policy", ThisPage)
Create("support email draft requesting a refund")
Save("support email draft")
Share("support email draft")
```

Notes:

- Quotes make intent unambiguous when a string could be misread as an entity name.
- Entities can be implicit ("this page") or explicit ("Amazon cart").
- You can ask Laika to "ask before acting" for anything high-risk, even if the verb implies it.

### 4.2 Action reference

Below, each action includes:

- Purpose: what the action means.
- Typical output: what you should expect back.
- Safety notes: how it should behave in a privacy-first browser agent.
- Examples: compelling prompts and compositions.

Implementation model:

- High-level verbs are *not* Safari APIs. They are intent-level building blocks used for planning and auditing.
- When a verb requires browser interaction, it must compile down to one or more low-level primitives from the tool catalog (section 4.4), mediated by Policy Gate.
- Some verbs are primarily “local/model” work (summarization, drafting, calculation) and may require *zero* browser tool calls if the needed context is already present.

Common mapping (informal):

| High-level verb | What provides the logic | Typical low-level primitives |
| --- | --- | --- |
| `Summarize` | LLM summarization over `observe_dom` documents + grounding checks | `browser.observe_dom` (optional re-observe/zoom) |
| `Find` | LLM/local retrieval over observed content | `browser.observe_dom` (scoped), `browser.scroll` |
| `Search` | Open a search results page | `search` |
| `Investigate` | Multi-step evidence gathering + synthesis | `search`, `browser.open_tab`/`browser.navigate`, `browser.observe_dom`, `browser.click`, `browser.scroll` |
| `Create` | LLM drafting/structuring (artifact generation) | (no browser primitive required) |
| `Save` / `Share` / `Invoke` | Persistence + egress (workspace + connectors) | `artifact.save`, `artifact.share`, `integration.invoke` (app-level primitives; not part of the browser tool surface) |
| `Price` | Extract + compare + compute totals/assumptions | (usually a mix of `Find`/`Search` + navigation + observation; plus deterministic calculation) |
| `Buy` | Assisted form/checkout flow with explicit approvals | `browser.click`, `browser.type`, `browser.select`, `browser.scroll` (+ navigation) |
| `Calculate` | Deterministic compute | `app.calculate` (app-level primitive) |
| `Dossier` | Structured brief with citations (often “Investigate + Create”) | (same as `Investigate`, plus synthesis) |

---

### Summarize(Entity)

Purpose:
- Produce a grounded digest of an entity (usually the current page), in the format you request.

Typical output:
- A short summary plus a structured outline, key takeaways, and links/anchors (when available).

Safety notes:
- Read-only by default. Should not navigate or click unless you explicitly ask it to.
- If the entity is another link/item ("summarize the first result"), it may use read-only navigation (`browser.open_tab`) to fetch that entity before summarizing.

Reliability notes:
- The summary must be grounded in the observed content. If the page appears blocked/sparse (paywall, login, overlay, CAPTCHA), say so and do not speculate.
- If grounding is weak, fall back to an extractive/quoted summary or ask for a re-observe/scroll rather than guessing.

Examples:

```text
Summarize(ThisPage)
```

```text
Summarize("this pricing page; focus on plan differences, limits, and hidden fees")
```

```text
Summarize("my open tabs about HSA providers; give me a 5-bullet comparison and what to verify next")
```

Good follow-ups:

```text
Find("cancellation", ThisPage)
Find("data retention", ThisPage)
Create("questions to ask sales based on this page")
```

---

### Find(Topic, Entity)

Purpose:
- Locate relevant items, passages, or candidates related to a topic within an entity.

Typical output:
- A short ranked list of matches (with citations/anchors when possible), plus suggested next steps.

Safety notes:
- Usually read-only within an entity. Use `Search(Query)` for web search / opening search results in a new tab.

Implementation notes (how to keep it robust):
- Prefer finding within the latest observation (`primary`, `blocks`, `items`, `outline`, `comments`) instead of clicking around.
- Return matches with quotes/snippets and (when possible) anchors/handles so the user can verify.
- Treat results as partial on dynamic/virtualized pages; if nothing is found, propose a deterministic next step (scroll + re-observe, re-observe with larger budget, or switch to `Search`).
- V1 decision: keep `Find` model-driven (observe + scroll + re-observe). Do not add a dedicated `browser.find_text` primitive unless we later need it for reliability/perf.

Examples:

```text
Find("refund policy", ThisPage)
```

```text
Find("where to download the 2024 statement PDF", "this bank portal")
```

```text
Find("2BR under $3500 near Mission District with in-unit laundry", "Zillow")
```

```text
Find("SOC 2 report", "vendor security page")
```

Pattern: "Find then extract"

```text
Find("pricing table", ThisPage)
Create("a 2-column table of plan name vs monthly price from the pricing table")
```

---

### Search(Query)

Purpose:
- Run a web search for a query and open the results (typically in a new tab).

Typical output:
- A brief preview of the query (and engine, if specified), then a search results page to browse/summarize.

Safety notes:
- Low-risk navigation, but the query is sent to a search engine (data egress). If the query includes personal/sensitive details, Laika should ask before searching.
- In practice, treat emails, phone numbers, full addresses, account/order numbers, and other identifiers as sensitive by default.

Examples:

```text
Search("SEC filing deadlines")
```

```text
Search("standing desk under $700 60x30")
```

```text
Search("refund policy Stripe cancellation terms")
```

Pattern: "Search -> Find -> Investigate"

```text
Search("vendor SOC 2 report")
Find("SOC 2", ThisPage)
Investigate("is the SOC 2 current and what scope it covers", ThisPage)
```

---

### Investigate(Topic, Entity)

Purpose:
- Do deeper, evidence-driven analysis: follow links, cross-check details, and explain "what happened and why."

Typical output:
- An investigation note that includes: findings, evidence, uncertainties, and recommended actions.

Safety notes:
- Often expands into multiple steps (navigate, open details pages, compare sources).
- Should ask before doing anything that might submit forms, buy, upload, or share data externally.

Examples:

```text
Investigate("why my claim was denied", "this insurance portal")
```

```text
Investigate("is this charge legitimate", "my credit card transactions page")
```

```text
Investigate("what changed in the latest 8-K vs last quarter", "SEC EDGAR filings for $COMPANY")
```

Pattern: "Investigate then create a packet"

```text
Investigate("chargeback evidence needed", "merchant receipt + card statement pages")
Create("dispute packet with timeline, amounts, merchant info, and evidence links")
```

---

### Create(Artifact)

Purpose:
- Generate a concrete output you can use: tables, drafts, memos, checklists, packets, and structured datasets.

Typical output:
- The artifact content (often in Markdown/table form), and a suggested filename/title.

Safety notes:
- Creation itself is usually local and safe, but the inputs might be sensitive. If the artifact includes sensitive content, Laika should default to redaction and ask before sharing/exporting.

Examples:

```text
Create("a ranked shortlist of the top 10 listings from the results page with: address, price, commute time, and notes")
```

```text
Create("an email draft to support requesting a refund, citing the policy I found")
```

```text
Create("a comparison table: plan, monthly price, included seats, SSO, API limits, support tier")
```

```text
Create("a checklist of what I should verify manually before I submit this form")
```

---

### Save(Artifact)

Purpose:
- Persist an artifact to your workspace (or export it to a file) so it can be reused, audited, and shared later.

Typical output:
- Confirmation of what was saved, where, and under what title/tags.

Safety notes:
- Saving may be restricted or disabled in private browsing contexts or on sensitive sites (depending on policy).
- For sensitive workflows, prefer saving derived/aggregated artifacts rather than raw page text or screenshots.

Examples:

```text
Save("the price comparison table as laika/laptops_2026Q1.md")
```

```text
Save("this run log and outputs under 'Insurance Appeal - Jan 2026'")
```

```text
Save("a redacted version of the dispute packet (no account numbers)")
```

---

### Share(Artifact)

Purpose:
- Send an artifact outside the current Laika workspace: email, Slack, copy-to-clipboard, export as PDF, etc.

Typical output:
- A preview of what will be shared, the destination, and a confirmation step.

Safety notes:
- Sharing is data egress. It should be explicit, previewed, and gated.
- Redaction should be the default if the artifact contains personal or sensitive data.

Examples:

```text
Share("the appeal letter draft to my email")
```

```text
Share("the apartment shortlist to Slack #housing")
```

```text
Share("the vendor comparison table as a PDF")
```

Pattern: "Create -> Save -> Share"

```text
Create("1-page brief with citations")
Save("1-page brief")
Share("1-page brief")
```

---

### Price(Artifact)

Purpose:
- Compute or compare pricing for an artifact: carts, quotes, plans, itineraries, or a shortlist of options.

Typical output:
- A price breakdown (line items + assumptions), and (if relevant) a comparison across options.

Safety notes:
- Usually read-only, but may require navigation to gather prices.
- Should be explicit about assumptions: tax, region, discounts, shipping, subscription renewal terms.

Examples:

```text
Price("my cart on this page; include shipping, tax, and final total")
```

```text
Price("these 5 laptop options; compute total cost for each with estimated tax in CA and include warranty cost")
```

```text
Price("this trip itinerary: flights + hotel + local transit estimate for 4 days")
```

Pattern: "Search -> Price -> Create"

```text
Search("standing desk under $700 with 60x30 size")
Price("top 5 candidates")
Create("a recommendation with best value pick and what trade-offs I accept")
```

---

### Buy(Artifact)

Purpose:
- Perform a purchase or commit a transaction related to an artifact (placing an order, subscribing, paying, booking).

Typical output:
- A step-by-step preview of what will happen, followed by a confirmation gate before the final commit.

Safety notes:
- Highest risk. Should always ask before the final "Place order"/"Pay"/"Book" step.
- Payment credentials and sensitive fields should default to manual entry or system autofill.
- Prefer "dry run" behavior: add to cart, fill shipping, reach the final review screen, then stop for approval.

Examples:

```text
Buy("the selected laptop option; stop at final review and ask before placing the order")
```

```text
Buy("book the refundable flight option with carry-on included; ask before paying")
```

```text
Buy("subscribe to the monthly plan; confirm renewal terms and cancellation steps first")
```

Pattern: "Price -> Buy -> Save"

```text
Price("this cart")
Buy("this cart; stop at final review")
Save("receipt + order confirmation page as an artifact")
```

---

### Invoke(API)

Purpose:
- Call a configured external integration to import/export structured data or trigger an action.

Typical output:
- The API call result (created row/page/ticket/message) plus a link/reference ID.

Safety notes:
- Treat as explicit egress/write. Require the destination to be clear and the payload previewed.
- Prefer sending structured, minimal data (for example: a summary table, not raw page text).

Examples:

```text
Invoke("GoogleSheets.append: Apartment Shortlist")
```

```text
Invoke("Slack.postMessage: #procurement")
```

```text
Invoke("Jira.createIssue: VENDOR-SECURITY-REVIEW")
```

Pattern: "Create -> Invoke"

```text
Create("a 10-row table of the shortlisted options with columns: name, price, pros, cons, link")
Invoke("GoogleSheets.writeTable: Purchases 2026")
```

---

### Calculate(Expression)

Purpose:
- Perform a deterministic computation (math, unit conversion, aggregation) and show the working.

Typical output:
- The result plus the formula/assumptions used.

Safety notes:
- Read-only and local. Still, be explicit about units and rounding.

Implementation notes:
- Prefer a deterministic evaluator (app-local) for arithmetic/unit conversion over asking an LLM to "do math".
- Define supported operators/functions and rounding rules so repeated runs are consistent and audit-friendly.

Examples:

```text
Calculate("129.99 * 1.0825")
```

```text
Calculate("($1200 / 12) + $15.99")
```

```text
Calculate("sum of the last 3 months of 'subscription' charges from the table we extracted")
```

Pattern: "Extract -> Calculate -> Create"

```text
Find("the pricing table", ThisPage)
Create("extract the pricing table into rows")
Calculate("annual cost per plan = monthly_price * 12")
Create("a final comparison table with annual costs and break-even notes")
```

---

### Dossier(Topic, Entity)

Purpose:
- Produce a structured, citation-backed brief ("everything I need to know") about a topic within an entity.

Typical output:
- A multi-section dossier, often including:
  - Executive summary
  - Key facts and definitions
  - Evidence and sources (with links/anchors)
  - Timeline (when relevant)
  - Risks / trade-offs / unknowns
  - Recommended next actions and verification checklist

Safety notes:
- Often involves wider navigation and source gathering; should be transparent about where information came from and what remains uncertain.

Examples:

```text
Dossier("material risks and recent changes", "SEC filings for $COMPANY")
```

```text
Dossier("refund eligibility for my order", "this merchant site + my order page")
```

```text
Dossier("vendor security posture", "vendor trust center + documentation")
```

Pattern: "Dossier -> Create"

```text
Dossier("options and trade-offs", "my shortlist")
Create("a decision memo: recommended choice, why, and what could change my mind")
```

---

### 4.3 Composition patterns (how the verbs fit together)

Most browsing work follows a few repeatable shapes:

1) Understand quickly (read-only)

```text
Summarize(Entity)
Find(Topic, Entity)
Search(Query)
```

2) Research and decide

```text
Search(Query)
Find(Topic, Entity)
Investigate(Topic, Entity)
Create(Artifact)
Save(Artifact)
Share(Artifact)
```

3) Shop and transact (with approvals)

```text
Search(Query)
Find(Topic, Entity)
Price(Artifact)
Create(Artifact)   // comparison table / recommendation
Buy(Artifact)      // stop at final review
Save(Artifact)     // receipt / confirmation
```

4) Export and integrate into your workflow

```text
Create(Artifact)
Invoke(API)
Share(Artifact)
```

---

### 4.4 Low-Level Primitives (typed tool calls + LLM integration)

This doc’s verbs (e.g., `Find`, `Buy`, `Summarize`) are **high-level intent**. Execution happens via **low-level primitives** (typed tool calls) that the model proposes and Laika enforces.

Core rules:

- The web is **untrusted input**; the model must treat page text as data, not instructions.
- The model never performs actions directly; it proposes **tool calls**.
- Tool calls are mediated by **Policy Gate** (allow/ask/deny), executed by trusted code, and logged.

#### Primitive lifecycle (one step)

1. Observe: capture page context + element handles.
2. Plan: model emits an LLMCP JSON response with `assistant.render` plus optional `tool_calls`.
3. Gate: Policy Gate decides allow/ask/deny per tool call.
4. Act: allowed tools run (JS in the extension or Swift in Agent Core).
5. Re-observe: capture fresh state after navigation/interaction.

#### Planner response contract (current prototype)

The planner model must return **exactly one LLMCP response object**:

```json
{
  "protocol": { "name": "laika.llmcp", "version": 1 },
  "type": "response",
  "sender": { "role": "assistant" },
  "in_reply_to": { "request_id": "..." },
  "assistant": { "render": { "...": "Document" } },
  "tool_calls": []
}
```

Rules:

- `assistant.render` is required; never emit raw HTML or Markdown.
- If no action is needed, return `tool_calls: []`.
- Tool names must match the allowed list below.
- Arguments must match each tool’s schema (no extra keys).
- Use only `handleId` values from the latest observation; never invent handle ids.
- Prefer at most **one** tool call per step (for determinism and reviewability).

Parsing behavior (important for prompting):

- Laika extracts the **first top-level JSON object** from the model output; `<think>...</think>` and code fences are stripped first.
- Responses are validated against `laika.llmcp.response.v1`; invalid responses are rejected.
- Unknown tool names are ignored (not executed).
- Minor JSON issues may be repaired (e.g., trailing commas). For `browser.observe_dom`, `maxItemsChars`/`maxItemsChar` are normalized to `maxItemChars`.

Implementation note: Laika uses a JSON-only prompt + LLMCP parser. See `docs/QWen3.md` for thinking control and `docs/llm_context_protocol.md` for the protocol schema.

#### Primitive catalog (authoritative)

This table mirrors `docs/llm_context_protocol.md` (treat that doc as the schema source of truth). This is the **only** browser tool surface Laika should carry forward. App-level primitives (artifacts, exports, connectors, deterministic compute) are defined in `docs/llm_context_protocol.md` under “App-level primitives”.

| Category | Primitive | What it does | Arguments (JSON) | Runs in |
| --- | --- | --- | --- | --- |
| Observation | `browser.observe_dom` | Capture/refresh page text + structured blocks/items/comments + element handles. | `{ "maxChars"?: number, "maxElements"?: number, "maxBlocks"?: number, "maxPrimaryChars"?: number, "maxOutline"?: number, "maxOutlineChars"?: number, "maxItems"?: number, "maxItemChars"?: number, "maxComments"?: number, "maxCommentChars"?: number, "rootHandleId"?: string }` | Extension (content script via background) |
| DOM action | `browser.click` | Click a link/button element in the page. | `{ "handleId": string }` | Extension content script |
| DOM action | `browser.type` | Type into an editable field (input/textarea/contenteditable). | `{ "handleId": string, "text": string }` | Extension content script |
| DOM action | `browser.select` | Select a value in a `<select>`. | `{ "handleId": string, "value": string }` | Extension content script |
| DOM action | `browser.scroll` | Scroll the page by a delta. | `{ "deltaY": number }` | Extension content script |
| Navigation | `browser.open_tab` | Open a URL in a new tab. | `{ "url": string }` | Extension background |
| Navigation | `browser.navigate` | Navigate the current tab to a URL. | `{ "url": string }` | Extension background |
| Navigation | `browser.back` | Go back in tab history. | `{}` | Extension background |
| Navigation | `browser.forward` | Go forward in tab history. | `{}` | Extension background |
| Navigation | `browser.refresh` | Reload the current page. | `{}` | Extension background |
| Navigation | `search` | Open search results for a query (engine selection is optional). | `{ "query": string, "engine"?: string, "newTab"?: boolean }` | Extension background |

#### Implementing primitives (generic, efficient, robust)

Low-level primitives should be intentionally boring: small, deterministic, and site-agnostic. The reliability comes from (1) a strong observation primitive, (2) strict handle semantics, and (3) a re-observe/verify loop.

`browser.observe_dom` (the foundation):

- Extract a compact, structured view of the current page that works across content types:
  - `primary`: best-effort “main content” (article body, product detail, doc text).
  - `blocks`: paragraph-ish chunks with link density (helps ignore nav/ads).
  - `items`: list-like pages (search results, feeds, tables-as-cards).
  - `outline`: headings/section structure.
  - `comments`: discussion threads (often outside the primary root).
  - `elements`: interactive controls (role + label + handleId) for safe actioning.
  - `signals`: access/visibility hints (paywall/login/overlay/captcha/sparse_text/virtualized_list/etc).
- Include observation metadata in every result (at minimum: `documentId`, `navigationGeneration`, and `observedAtMs`). Handle validity should be tied to this metadata.
- Be aggressively budgeted:
  - Clamp counts and chars (`maxChars`, `maxItems`, `maxBlocks`, ...).
  - Prefer viewport-first extraction; include “tail” coverage only if budget remains.
  - Avoid expensive style/layout queries; use heuristics that work off DOM + cheap bounding checks.
- Support tight scoping:
  - `rootHandleId` should re-observe a specific container/section (a "zoom in") while preserving the same output schema.
- Be robust to modern web primitives:
  - Shadow DOM: traverse open shadow roots; treat closed shadow as not inspectable and surface a `signal`.
  - Iframes: traverse same-origin frames; emit a `signal` for cross-origin frames you can’t read.
  - Virtualized/infinite lists: treat output as partial; rely on `browser.scroll` + re-`browser.observe_dom` loops.
  - Non-text pages (canvas/images/video): rely on accessible names/alt text when present; otherwise emit `signal`s like `non_text_content` and return a minimal observation.
- Never emit raw HTML. Prefer line-preserving text with lightweight structure prefixes (headings, lists, quotes, code) so summarization is stable under truncation.
- Always mint action handles (`handleId`) only from trusted extraction; never from model text.

Handles + staleness (cross-cutting):

- Bind handles to a specific (`documentId`, `navigationGeneration`) and invalidate them on navigation/refresh. If the current page metadata does not match, return `stale_handle` and require a fresh `browser.observe_dom`.
- Make handle resolution resilient:
  - Keep an internal handle store (handleId -> element reference + fallback selectors/role/label hints).
  - If resolution fails, return a stable `stale_handle` / `not_found` error and force a fresh `browser.observe_dom`.

DOM action primitives (`browser.click`, `browser.type`, `browser.select`, `browser.scroll`):

- Treat each action as “attempt once, then verify”:
  - Precondition checks: element exists, is connected, is visible/disabled state, is the expected role/type.
  - Perform the action (scroll into view if needed).
  - Postcondition strategy: don’t guess; re-`browser.observe_dom` and let the planner decide next.
- Keep error codes stable and meaningful (`not_found`, `stale_handle`, `not_interactable`, `blocked_by_overlay`, ...). Models learn the retry strategy from these.

Canonical primitive error codes (v1):

- Tool execution results should use a stable shape: `{ "status": "ok" }` or `{ "status": "error", "error": "<code>" }`.
- Treat `error` codes as a versioned enum (shared across Swift + JS) so the orchestration layer can respond deterministically.
- Use lower_snake_case strings for codes (matches the extension tool surface and avoids casing drift).

Common codes (v1):

- `invalid_arguments`
- `missing_url`, `invalid_url`, `missing_query`, `missing_template`
- `no_active_tab`, `no_target_tab`, `tabs_unavailable`, `no_context`
- `unsupported_tool`
- `stale_handle`, `not_found`, `not_interactable`, `disabled`, `blocked_by_overlay`
- `not_editable`, `not_select`, `missing_value`
- `search_unavailable`, `search_failed`
- `open_tab_failed`, `navigate_failed`, `back_failed`, `forward_failed`, `refresh_failed`
- `permission_denied`, `rate_limited`, `timeout`, `verification_failed`

Navigation primitives (`browser.open_tab`, `browser.navigate`, `browser.back`, `browser.forward`, `browser.refresh`, `search`):

- Sanitize URLs and restrict to `http(s)`; never allow `javascript:`, `data:`, `file:`, or extension URLs.
- `search` should build URLs from engine templates and treat the query as data egress (gate sensitive queries).
- Use a conservative sensitive-query detector (emails/phones/account-like strings) and default to "ask" when unsure.

Canonical `signals` from `browser.observe_dom` (v1):

- Treat these as a versioned enum (shared across Swift + JS) so the model and UI can reliably explain limitations.

Signals should be designed to be:

- Present/absent booleans (no values), so they are easy to gate and easy to prompt on.
- Conservative (better to say "maybe blocked" than to pretend content is visible).

Currently emitted (v1):

- `auth_fields`, `auth_gate`
- `paywall`
- `overlay_or_dialog`, `consent_overlay`
- `age_gate`, `geo_block`, `script_required`
- `url_redacted`

Reserved / planned (v1+):

- `sparse_text`, `non_text_content`
- `captcha_or_robot_check`
- `cross_origin_iframe`, `closed_shadow_root`
- `virtualized_list`, `infinite_scroll`
- `pdf_viewer` (or `document_viewer`)

Testing/hardening strategy:

- Unit test the pure logic (URL sanitation, handle invalidation rules, extraction heuristics).
- Maintain a small “capability probe” harness: run `observe_dom`/click/type/scroll on representative sites (news, web apps, ecommerce, docs, feeds) and record failure modes.
- Start with a fixed set of 10-20 probes and track simple metrics (success rate per primitive, common failure codes, and median/p95 timings).

Orchestration invariants (high-level verbs built on primitives):

- Prefer at most 1 primitive call per step (reviewability and determinism).
- Re-observe after any navigation or DOM action before making another decision.
- Enforce step budgets and stop conditions (return partial results + "what I need next" instead of looping).

#### Execution surfaces (prototype)

- Policy Gate runs in Swift (Agent Core).
- DOM actions (`browser.click/type/select/scroll/observe_dom`) execute in `content_script.js`.
- Tab actions (`browser.open_tab/navigate/back/forward/refresh/search`) execute in `background.js`.
- The UI renders `assistant.render` from the LLMCP response; no summary streaming.

#### Summary guidance (LLMCP)

Summaries are returned via `assistant.render` in the LLMCP response:

- `browser.observe_dom` emits line-preserved `text` with structure prefixes (`H2:`, `- `, `> `, `Code:` …) plus `blocks/items/comments/outline/signals`.
- `SummaryInputBuilder` picks a representation (list vs page text vs comments) and compacts it without losing structural hints.
- Agent Core validates grounding and replaces responses with a fallback summary when needed.

See `docs/dom_heuristics.md` and `docs/llm_context_protocol.md` for the prompt rules and response schema.

#### Debugging (LLM + tools)

- LLM traces: `~/Laika/logs/llm.jsonl` (or the sandbox container path). Control full prompt/output logging with `LAIKA_LOG_FULL_LLM=0`.
- Set `LAIKA_DEBUG=1` to log lightweight extraction/debug events.

---

## 5. Example decompositions

These examples show how a plain-English user prompt can map to the internal vocabulary. End-user scenario narratives live in `docs/laika_pitch.md`.

### Example 1: Refund terms -> checklist + email draft

User prompt:

```text
Summarize this page, find the exact refund and cancellation terms, and draft a short email asking for a refund. Ask before sending anything.
```

Internal action chain:

```text
Summarize(ThisPage)
Find("refund + cancellation terms", ThisPage)
Create("refund request email draft with cited terms")
Save("refund checklist + email draft")  // optional
```

---

### Example 2: Shopping -> compare -> stop at final checkout

User prompt:

```text
Find 5 options that match my criteria, compare total cost (tax/shipping/warranty), recommend one with trade-offs, then take me to the final checkout review and stop before placing the order.
```

Internal action chain:

```text
Search("product criteria")
Price("top options; include tax/shipping/warranty assumptions")
Create("comparison table + recommendation + what to verify")
Buy("recommended option; stop at final review; ask before placing order")
Save("comparison + receipt/confirmation")  // optional
```

---

### Example 3: Suspicious charge -> dispute packet

User prompt:

```text
Investigate this charge, total similar charges in the last 90 days, and create a dispute packet with evidence links plus a message to the merchant. Save a redacted version and ask before emailing anything.
```

Internal action chain:

```text
Investigate("is this charge legitimate + how to cancel/refund", "card portal")
Find("merchant contact + refund policy", "relevant pages")
Calculate("total amount of similar charges in last 90 days")
Create("dispute packet + merchant message draft")
Save("redacted dispute packet")
Share("message draft")  // ask before sending
```

---

### Example 4: Vendor due diligence -> decision memo

User prompt:

```text
Review this vendor's trust center. Summarize security posture, data retention, subprocessors, and compliance claims. Draft a decision memo and list what we still need to verify.
```

Internal action chain:

```text
Dossier("vendor security + privacy posture", "vendor trust center + docs")
Create("decision memo: what we know vs what to verify")
Save("decision memo")
Share("decision memo")  // optional
```

---

### Example 5: Weekly ops -> export to your tools

User prompt:

```text
Find postings that match my criteria from the last 7 days, build a table (company, role, location, link, notes), and ask before exporting it to my tracker and sharing a summary.
```

Internal action chain:

```text
Search("weekly criteria")
Create("structured table")
Invoke("GoogleSheets.writeTable: Tracker")  // optional
Invoke("Slack.postMessage: #channel")       // optional
Save("run outputs")
```
