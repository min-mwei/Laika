# Laika Action Vocabulary (Internal)

This doc defines a small, composable action vocabulary Laika can use internally to decompose a plain-English user request into safer, more reviewable steps.

Users should write normal prompts. Laika may translate that intent into one or more internal actions like:

`Summarize(Entity), Find(Topic, Entity), Share(Artifact), Investigate(Topic, Entity), Create(Artifact), Price(Artifact), Buy(Artifact), Save(Artifact), Invoke(API), Calculate(Expression), Dossier(Topic, Entity)`.

For end-user scenarios and positioning, see `docs/laika_pitch.md`.

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
- `docs/llm_tools.md` (typed tool calls and execution contract)

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

---

### Summarize(Entity)

Purpose:
- Produce a grounded digest of an entity (usually the current page), in the format you request.

Typical output:
- A short summary plus a structured outline, key takeaways, and links/anchors (when available).

Safety notes:
- Read-only by default. Should not navigate or click unless you explicitly ask it to.

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
- Usually read-only. If you intend cross-site navigation or searching the web, say so (or allow Laika to ask).

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

Pattern: "Find -> Price -> Create"

```text
Find("standing desk under $700 with 60x30 size", "web")
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
```

2) Research and decide

```text
Find(Topic, Entity)
Investigate(Topic, Entity)
Create(Artifact)
Save(Artifact)
Share(Artifact)
```

3) Shop and transact (with approvals)

```text
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
Find("product criteria", "web")
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
Find("weekly criteria", "web")
Create("structured table")
Invoke("GoogleSheets.writeTable: Tracker")  // optional
Invoke("Slack.postMessage: #channel")       // optional
Save("run outputs")
```
