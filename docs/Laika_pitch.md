# Laika: AI Fortress - Scenarios First

**Understand your intent. Do the work. Keep it private.**

Browsers are great at showing pages. They are terrible at finishing work.

Laika is a privacy-first AI agent embedded in your browser, starting in **Safari (macOS + iOS)**, with **Chrome (Android)** planned later. It turns questions into outcomes in minutes across the sites you already use: portals, forms, dashboards, and "do the thing" workflows.

Laika is an **AI Fortress**: it turns your intent into safe, fast progress inside the browser. It does the mundane work (clicking, tab-juggling, copying, reformatting) and produces reviewable artifacts (tables, drafts, checklists) so you can spend your time thinking, asking better questions, and making decisions.

## The problem (what your browser makes you do today)

- You become the "glue" between tabs and Office apps: copy/paste, compare, reconcile, reformat, repeat.
- The web is full of portals and edge cases: filters, logins, attachments, confirmations, hidden fees, time windows.
- A task is not a page: it is 10-50 steps across pages, menus, PDFs, and forms.
- Mistakes are expensive: one wrong checkbox, one missed policy clause, one wrong total.
- You cannot safely delegate: the moment money, identity, healthcare, or work systems are involved, "just let the AI do it" feels risky.

## Why an AI Fortress (not a cloud AI browser)

AI browsers like Perplexity Comet are pushing a compelling idea: the browser becomes an agent that can read, research, and act on your behalf. They can be genuinely useful for open-web research, summaries, and cross-tab comparisons. In practice, users still hit four recurring problems when they try to trust cloud-first AI browsers with real work:

1) Trust and privacy tradeoffs
- To be useful, a cloud-first AI browser often needs to see what you see: logged-in pages, inboxes, calendars, carts, and forms.
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

Laika is built for the workflows where browsers and cloud-first AI browsers fall down:

- Private by default: designed so sensitive workflows do not have to leave your device.
- In control by default: you can keep Laika read-only, or let it act with clear "ask before acting" moments.
- Outcome-driven: it produces artifacts you can review, save, and share (tables, drafts, packets, memos, checklists).
- Built for long tasks: pause/resume, checkpoints, and a run log so you can pick up where you left off.
- Vocabulary-driven: it decomposes intent into a small, reviewable set of actions (read vs. write), so it stays predictable under pressure.

For architecture and safety posture, see `docs/LaikaOverview.md`.

## The niche Laika targets

Laika is built for the web workflows that are:

- High-friction: 10-50 steps across tabs, menus, and forms
- High-stakes: money, identity, health, insurance, work systems
- High-trust: you want the outcome, but you do not want to hand your sessions and personal data to a cloud agent

This is not theoretical. Even the leading "computer use" / agentic tooling explicitly calls out unique risks on the internet: isolate the agent, avoid giving it sensitive data (like account login information), and ask a human to confirm meaningful real-world consequences (like financial transactions). It also warns that models can follow commands found in webpage content and recommends precautions against prompt injection (see: Anthropic "Computer use tool": https://docs.anthropic.com/en/docs/build-with-claude/computer-use).

Security researchers have also demonstrated prompt injection and scam flows against agentic browsers (see: Brave research on indirect prompt injection in Comet: https://brave.com/blog/comet-prompt-injection/ and Guardio Labs "Scamlexity": https://guard.io/labs/scamlexity-we-put-agentic-ai-browsers-to-the-test-they-clicked-they-paid-they-failed).

Laika's answer is the AI Fortress: on-device by default, strict separation of trusted user intent vs untrusted web content, and a policy-gated action interface with previews and an audit trail.

## Why Safari first

Safari is a large surface area where users are already doing sensitive work, especially on mobile. As of Dec 2025, Safari is ~22% of worldwide mobile browser share and ~5% of worldwide desktop browser share (StatCounter: https://gs.statcounter.com/browser-market-share/mobile/worldwide and https://gs.statcounter.com/browser-market-share/desktop/worldwide).

## Why now

Agentic browsing is arriving, but safety and privacy are the real blockers. Models are good enough to click around; what is missing (and what users want) is the fortress: clear boundaries, human-in-the-loop controls for irreversible actions, and a durable audit trail.

## Where it shines (real scenarios)

Each scenario includes: what you do today, what Laika does, and what you get at the end.

### 1) Shopping with constraints (and a paper trail)

Today:
- You compare 8 tabs, forget why you opened half of them, and still miss total cost (tax/shipping/fees) and return/warranty terms.

Laika:
- Finds candidates, builds a price-and-tradeoff table (including policy details), and (if you ask) drives checkout until the final review screen and stops.

You get:
- A comparison you can trust, plus a purchase flow that stops before you pay.

Try it:
- "Find 5 options that match my criteria, compare total cost (tax/shipping/warranty), recommend one with trade-offs, then take me to the final checkout review and stop before placing the order."

### 2) Trip planning: from constraints to a booking-ready plan

Today:
- You open a dozen tabs for flights, hotels, and "what should we do", then lose track of trade-offs, fees, and cancellation rules.

Laika:
- Finds options that match your constraints, prices them with explicit assumptions, and turns the research into a shareable itinerary with links (and "what to verify" notes).

You get:
- A saved plan: options table + itinerary + "what to verify" checklist.

Try it:
- "Plan a 5-day Kyoto trip in April for two adults: find 3 hotels near Gion under $250/night, suggest a simple day-by-day itinerary, and save it. Ask before booking anything."

### 3) Health research: from web reading to a cited brief

Today:
- You skim contradictory pages, miss key caveats, and still don't know what to ask next.

Laika:
- Searches credible sources, extracts evidence with citations, highlights red flags/contraindications, and drafts questions to bring to a clinician.

You get:
- A one-page brief with sources + a question list (research support, not medical advice).

Try it:
- "Research evidence-backed options for chronic migraine: summarize what helps, what the evidence says, and what questions I should ask my doctor. Include citations and save a one-page brief."

### 4) Subscriptions, refunds, and "what did I actually agree to?"

Today:
- You hunt for the one paragraph that matters, then try to find the "cancel" button, then wonder if you'll be charged anyway (or lose access immediately).

Laika:
- Finds the exact refund/cancellation language, locates the cancellation path, and (if you ask) navigates to the final cancel/review screen and stops. It can also draft a short message that cites the relevant terms.

You get:
- A checklist of what to verify, plus a ready-to-send draft and saved evidence when applicable.

Try it:
- "Find the refund/cancellation terms, take me to the final cancellation review screen and stop, and draft a short refund request message citing the terms. Ask before submitting anything."

### 5) Credit cards: suspicious charge -> dispute-ready packet

Today:
- You spot a charge you don't recognize, click through transaction details, and assemble evidence manually while the clock is ticking.

Laika:
- Investigates the charge, totals similar charges, finds refund/cancellation paths, and drafts a dispute packet and support message.

You get:
- A dispute-ready packet (timeline, amounts, links/evidence) you can save and reuse.

Try it:
- "Investigate this charge, total similar charges in the last 90 days, and create a dispute packet with evidence links plus a message to the merchant. Save a redacted version and ask before emailing anything."

### 6) Insurance claims: denial -> appeal letter + attachment checklist

Today:
- You bounce between the portal and a policy PDF, unsure what matters, and you risk missing a deadline or required attachment.

Laika:
- Finds the denial reason, pulls the relevant policy language, suggests an appeal strategy, and drafts an appeal letter with a checklist.

You get:
- A complete appeal packet you can review and submit with confidence.

Try it:
- "Figure out why this claim was denied, find the relevant policy language, and draft an appeal letter with an attachment checklist. Ask before submitting anything."

### 7) Apartment hunting: from messy listings to a shareable shortlist

Today:
- You doomscroll listings, lose track of favorites, and keep re-evaluating the same trade-offs (and worrying about scams and hidden fees).

Laika:
- Applies your criteria, estimates total monthly cost, flags obvious red flags, and produces a ranked shortlist with links and notes you can share.

You get:
- A decision-ready shortlist instead of a pile of tabs.

Try it:
- "Find 2BRs under $3500 in Mission or Noe with in-unit laundry and cats allowed. Estimate total monthly cost and make a ranked shortlist with links and dealbreakers. Save it."

### 8) Government + identity forms: applications -> submission-ready packet

Today:
- You bounce between requirements pages, PDFs, and form portals, and you still miss a document or a deadline.

Laika:
- Finds the requirements for your situation, builds a checklist, and helps fill the form up to the final review screen (then stops). It can assemble a submission-ready packet with links and notes.

You get:
- A submission-ready packet (checklist + draft form answers + links + "what to verify"), without surprise submissions.

Try it:
- "Help me apply for Global Entry: find the requirements, draft my answers, and take me to the final review screen without submitting. Save a checklist of what I need and ask before any submission."

### 9) Vendor due diligence: trust center -> decision memo

Today:
- You chase SOC 2s, DPAs, subprocessor lists, retention terms, and security FAQs across a dozen pages, then still need something you can send to stakeholders.

Laika:
- Builds a dossier of the vendor's security and privacy posture, extracts the terms that matter, and drafts a decision memo with a verification checklist.

You get:
- A procurement-ready memo with "what we know" vs. "what to verify."

Try it:
- "Review this vendor's trust center. Summarize security posture, data retention, subprocessors, and compliance claims. Draft a decision memo and list what we still need to verify."

### 10) Weekly ops: turn browsing into a workflow (Sheets/Slack/Notion)

Today:
- You repeat the same web work every week and manually retype it somewhere else, and it never quite stays consistent.

Laika:
- Finds the weekly updates, compiles a table, and (if you ask) exports to your tools with a preview and an audit trail.

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

Search, Summarize, Find, Investigate, Dossier, Create, Price, Calculate, Save, Share, Invoke, Buy.

You never need to type these explicitly, but the constraint helps Laika stay consistent: read actions feel different from write actions, and high-risk actions are easier to gate.

In practice, this vocabulary lets you focus on forming the right question. Great prompts usually include:

- The topic/decision (what you want to know)
- The target (this page/tab, a specific site/portal, or "open web")
- The artifact (table, itinerary, brief, packet, draft)
- Constraints (budget/time window/preferences)
- Autonomy ("ask before acting", "stop at final review", "read-only")

Example decompositions (plain English -> vocabulary):

### Shopping (compare + stop at checkout)

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

### Trip planning (options table + itinerary)

User prompt:

```text
Plan a 5-day Kyoto trip in April for two adults: find 3 hotels near Gion under $250/night, suggest a simple day-by-day itinerary, and save it. Ask before booking anything.
```

Internal action chain:

```text
Search("Kyoto April hotels near Gion under $250/night")
Find("must-know constraints (transit passes, closures, reservations)", "open web")
Price("3 hotel options; include assumptions and fees")
Create("5-day itinerary + options table + what to verify")
Save("trip plan")
```

### Health research (cited brief + questions)

User prompt:

```text
Research evidence-backed options for chronic migraine: summarize what helps, what the evidence says, and what questions I should ask my doctor. Include citations and save a one-page brief.
```

Internal action chain:

```text
Search("chronic migraine treatments guidelines meta-analysis RCT")
Investigate("evidence-backed options + caveats + contraindications", "credible sources")
Create("one-page brief with citations + questions for clinician")
Save("health research brief")
```

### Subscriptions + refunds (cancel safely)

User prompt:

```text
Find the refund/cancellation terms, take me to the final cancellation review screen and stop, and draft a short refund request message citing the terms. Ask before submitting anything.
```

Internal action chain:

```text
Summarize(ThisPage)
Find("refund/cancellation terms + renewal date", ThisPage)
Find("cancellation path", ThisSite)
Create("cancellation checklist + refund request draft with cited terms")
Save("cancellation/refund packet")
```

For the full internal vocabulary reference, see `docs/laika_vocabulary.md`.

## What to validate with users (fast)

- Trust boundary: what are the first workflows they would trust on-device vs cloud, and why?
- Stop points: where should Laika always pause (pay, submit, send, upload, accept terms), and what preview makes them comfortable?
- Artifacts: which outputs they actually want to keep/share (tables, packets, drafts, checklists), and what "done" looks like.
- Time-to-value: how many minutes saved per workflow, and what failure modes make them abandon.
- Privacy expectations: what data they consider too sensitive to ever leave the device.

## Research notes (sources that shaped this pitch)

These are useful reads on the current state of agentic browsing and why safety and privacy are hard problems:

- Anthropic: "Computer use tool" (risks + precautions, prompt injection notes) - https://docs.anthropic.com/en/docs/build-with-claude/computer-use
- Brave: "Agentic Browser Security: Indirect Prompt Injection in Perplexity Comet" (Aug 20, 2025) - https://brave.com/blog/comet-prompt-injection/
- Guardio Labs: "Scamlexity" (agentic AI browsers interacting with scams) (Aug 20, 2025) - https://guard.io/labs/scamlexity-we-put-agentic-ai-browsers-to-the-test-they-clicked-they-paid-they-failed
- LayerX: "CometJacking: How One Click Can Turn Perplexity's Comet AI Browser Against You" (Oct 4, 2025) - https://layerxsecurity.com/blog/cometjacking-how-one-click-can-turn-perplexitys-comet-ai-browser-against-you/
- The Register: "Perplexity's Comet browser prompt injection" (Aug 20, 2025) - https://www.theregister.com/2025/08/20/perplexity_comet_browser_prompt_injection/
- PCMag: "I Switched to Perplexity's AI Comet Browser for a Week. Is It the Future?" (review) - https://www.pcmag.com/opinions/i-switched-to-perplexitys-ai-comet-browser-for-a-week-is-it-the-future
- ZDNet: "Perplexity's Comet AI browser could expose your private data" (Aug 2025) - https://www.zdnet.com/article/perplexitys-comet-ai-browser-could-expose-your-data-to-attackers-heres-how/
- StatCounter: browser market share snapshots (Dec 2025) - https://gs.statcounter.com/browser-market-share/mobile/worldwide and https://gs.statcounter.com/browser-market-share/desktop/worldwide
