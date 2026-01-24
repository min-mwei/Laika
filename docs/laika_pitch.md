# Laika AIBrowser - Scenarios First

**Understand your intent. Do the work. Keep it private.**

Browsers are great at showing pages. They are terrible at finishing work.

Laika is a privacy-first AI browser copilot (starting inside Safari) that helps you complete real tasks across the sites you already use: portals, forms, dashboards, and "do the thing" workflows. It turns messy browsing into reviewable outcomes, while keeping you in control.

## The problem (what your browser makes you do today)

- You become the "glue" between tabs: copy/paste, compare, reconcile, repeat.
- The web is full of portals and edge cases: filters, logins, attachments, confirmations, hidden fees, time windows.
- A task is not a page: it is 10-50 steps across pages, menus, PDFs, and forms.
- Mistakes are expensive: one wrong checkbox, one missed policy clause, one wrong total.
- You cannot safely delegate: the moment money, identity, healthcare, or work systems are involved, "just let the AI do it" feels risky.

## Why "AI browsers" are not enough (yet)

AI browsers like Perplexity Comet are pushing a compelling idea: the browser becomes an agent that can read, research, and act on your behalf. They can be genuinely useful for open-web research, summaries, and cross-tab comparisons. In practice, users still hit four recurring problems when they try to trust these browsers with real work:

1) Trust and privacy tradeoffs
- To be useful, an AI browser often needs to see what you see: logged-in pages, inboxes, calendars, carts, and forms.
- If that processing happens in the cloud, you are forced into a hard choice: convenience vs. privacy.
- The more the browser learns about you across sites, the higher the incentive (and temptation) to collect and retain more of your browsing context.

2) Safety: the web is untrusted input
- Security researchers have repeatedly shown that "agentic browsing" expands the attack surface: hidden instructions, malicious links, fake shops, and phishing pages can steer an AI into doing the wrong thing.
- Example failure modes: a "summarize this page" request gets hijacked by hidden instructions; a fake shop or phishing flow convinces the agent to click/pay; a crafted link triggers the assistant to pull from memory/connected apps and leak data.
- When the agent can click, buy, download, or send messages, "getting tricked" stops being annoying and becomes costly.

3) Reliability: the agent gets stuck
- Real websites are messy: popups, dynamic content, inconsistent flows, A/B tests, and fragile selectors.
- Early agentic browsers can be slower than doing it yourself and frequently fail on the last mile (the part that matters).

4) Accountability: what happened, exactly?
- In high-stakes work, you need a paper trail: what it read, what it changed, what it assumed, what it could not verify.
- "It said it did it" is not enough.

## What Laika is (in plain English)

Laika is built for the workflows where browsers and early AI browsers fall down:

- Private by default: designed so sensitive workflows do not have to leave your device.
- In control by default: you can keep Laika read-only, or let it act with clear "ask before acting" moments.
- Outcome-driven: it produces artifacts you can review, save, and share (tables, drafts, packets, memos, checklists).
- Built for long tasks: pause/resume, checkpoints, and a run log so you can pick up where you left off.

## Where it shines (real scenarios)

Each scenario includes: what you do today, what Laika does, and what you get at the end.

### 1) Refunds, cancellations, and "what did I actually agree to?"

Today:
- You hunt for the one paragraph that matters, then write a support message from scratch.

Laika:
- Summarizes the page, finds the exact refund/cancellation language, and drafts a short message that cites the relevant terms.

You get:
- A checklist of what to verify before you buy, plus a ready-to-send draft.

Try it:
- "Summarize this page, find the refund and cancellation terms, and draft a short email asking for a refund. Ask before sending anything."

### 2) Shopping with constraints (and a paper trail)

Today:
- You compare 8 tabs, forget why you opened half of them, and still miss shipping/tax/return policy details.

Laika:
- Finds candidates, builds a price-and-tradeoff table, and (if you ask) drives checkout until the final review screen and stops.

You get:
- A comparison you can trust, plus a purchase flow you can approve explicitly.

Try it:
- "Find 5 options that match my criteria, compare total cost (tax/shipping/warranty), recommend one with trade-offs, then take me to the final checkout review and stop before placing the order."

### 3) Credit cards: suspicious charge -> dispute-ready packet

Today:
- You click through transaction details, hunt for merchant info, and assemble evidence manually.

Laika:
- Investigates the charge, totals similar charges, finds refund/cancellation paths, and drafts a dispute packet and support message.

You get:
- A dispute-ready packet (timeline, amounts, links/evidence) you can save and reuse.

Try it:
- "Investigate this charge, total similar charges in the last 90 days, and create a dispute packet with evidence links plus a message to the merchant. Save a redacted version."

### 4) Insurance claims: denial -> appeal letter + attachment checklist

Today:
- You bounce between the portal and a policy PDF, unsure what matters, and you risk missing a required attachment.

Laika:
- Finds the denial reason, pulls the relevant policy language, suggests an appeal strategy, and drafts an appeal letter with a checklist.

You get:
- A complete appeal packet you can review and submit with confidence.

Try it:
- "Figure out why this claim was denied, find the relevant policy language, and draft an appeal letter with an attachment checklist. Ask before submitting anything."

### 5) Apartment hunting: from messy listings to a shareable shortlist

Today:
- You doomscroll listings, lose track of favorites, and keep re-evaluating the same trade-offs.

Laika:
- Applies your criteria, estimates total monthly cost, and produces a ranked shortlist with links and notes you can share.

You get:
- A decision-ready shortlist instead of a pile of tabs.

Try it:
- "Find 2BRs under $3500 in Mission or Noe with in-unit laundry and cats allowed. Estimate total monthly cost and make a ranked shortlist with links and dealbreakers. Save it."

### 6) Company research (SEC EDGAR): filings -> 1-page brief with citations

Today:
- You open filings, scroll, lose the thread, and still do not have something you can share.

Laika:
- Collects the relevant filings, highlights material changes and risks, and produces a 1-page brief with citations.

You get:
- A shareable research artifact, not just a chat answer.

Try it:
- "Build a source-linked brief from the latest 10-K/10-Q/8-K: material changes, key risks, and open questions. Keep it to one page and include citations."

### 7) Vendor due diligence: trust center -> decision memo

Today:
- You chase SOC 2s, DPAs, subprocessor lists, retention terms, and security FAQs across a dozen pages.

Laika:
- Builds a dossier of the vendor's security and privacy posture, extracts the terms that matter, and drafts a decision memo with a verification checklist.

You get:
- A procurement-ready memo with "what we know" vs. "what to verify."

Try it:
- "Review this vendor's trust center. Summarize security posture, data retention, subprocessors, and compliance claims. Draft a decision memo and list what we still need to verify."

### 8) Weekly ops: turn browsing into a workflow (Sheets/Slack/Notion)

Today:
- You repeat the same web work every week and manually retype it somewhere else.

Laika:
- Finds the weekly updates, compiles a table, and (if you ask) exports to your tools with a preview.

You get:
- A repeatable workflow with less busywork.

Try it:
- "Find new postings that match my criteria from the last 7 days, build a table (company, role, location, link, notes), and ask before exporting it to my tracker and sharing a summary."

## What makes Laika feel trustworthy

- It treats websites as untrusted input: it should not follow hidden instructions from pages.
- It asks before irreversible actions: purchases, submissions, messages, uploads, permission grants.
- It keeps you oriented: previews, checkpoints, and a run log so you can audit what happened.

## Under the hood (internal action vocabulary)

To make behavior more reliable and reviewable, Laika can decompose your request into a small set of internal actions:

Summarize, Find, Investigate, Dossier, Create, Price, Calculate, Save, Share, Invoke, Buy.

You never need to type these explicitly, but the constraint helps Laika stay consistent: read actions feel different from write actions, and high-risk actions are easier to gate.

For the full internal vocabulary reference, see `docs/laika_vocabulary.md`.

## Research notes (sources that shaped this pitch)

These are useful reads on the current state of agentic/AI browsers and why safety and privacy are hard problems:

- Brave: "Agentic Browser Security: Indirect Prompt Injection in Perplexity Comet" (Aug 20, 2025) - https://brave.com/blog/comet-prompt-injection/
- Guardio Labs: "Scamlexity" (agentic AI browsers interacting with scams) (Aug 20, 2025) - https://guard.io/labs/scamlexity-we-put-agentic-ai-browsers-to-the-test-they-clicked-they-paid-they-failed
- LayerX: "CometJacking: How One Click Can Turn Perplexity's Comet AI Browser Against You" (Oct 4, 2025) - https://layerxsecurity.com/blog/cometjacking-how-one-click-can-turn-perplexitys-comet-ai-browser-against-you/
- The Register: "Perplexity's Comet browser prompt injection" (Aug 20, 2025) - https://www.theregister.com/2025/08/20/perplexity_comet_browser_prompt_injection/
- PCMag: "I Switched to Perplexity's AI Comet Browser for a Week. Is It the Future?" (review) - https://www.pcmag.com/opinions/i-switched-to-perplexitys-ai-comet-browser-for-a-week-is-it-the-future
- ZDNet: "Perplexity's Comet AI browser could expose your private data" (Aug 2025) - https://www.zdnet.com/article/perplexitys-comet-ai-browser-could-expose-your-data-to-attackers-heres-how/
