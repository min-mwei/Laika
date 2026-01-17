# Laika AIBrowser — Pitch Card (Why / What / How)

**Understand your intents, Do the work. Keep it private.**

## Why customers care

- **Web portals are digital fortresses**: your money, identity, housing, and work live behind logins — you won’t hand the keys to a black-box agent.
- **“Answers” aren’t the job**: the job is navigating filters, downloading statements, reconciling numbers, cross-checking details, and filling forms correctly.
- **Sensitive workflows can’t be copy/pasted**: if the task touches bank statements, tax docs, medical claims, or internal tools, shipping it to a chatbot is a non-starter.
- **The cost is real**: missed details compound, and mistakes can be expensive.

## What

Laika is a security- and privacy-first AI Browser agent (embedded in Safari initially) that can safely complete multi-step tasks inside the websites and portals you already use — with explicit per-site permissions and a complete audit trail.

## Why now

- **AI is moving into the browser**: tools like Perplexity’s Comet are positioning the browser as an AI assistant, and general agents like Manus demonstrate the value of autonomous web research.
- **Trust is the blocker**: the moment a workflow touches money, identity, or sensitive enterprise data, you need local enforcement, scoped permissions, and transparent logs — not a magic black box.

## What Laika does

- **Autodrives web portals**: reads what’s on the page, extracts structured data, and takes actions (navigate, click, fill, download) inside your existing authenticated sessions.
- **Keeps you in control**: safe-by-default **Workspace** + opt-in **Connect to this site** so it can’t silently roam across tabs or domains.
- **Turns workflows into outcomes**: produces reviewable outputs like anomaly reports, tables, memos, evidence packets, and step-by-step “what happened and why”.
- **Stays usable for long tasks**: pause/resume, checkpoints, and an append-only run log so you can pick up where you left off.

## Where it shines (examples)

- **Banking & credit cards**: analyze transactions, flag suspicious patterns, generate a dispute-ready packet, and draft the message — ask before submitting anything.
- **Health & medical research (PubMed / guidelines / clinical trials)**: pull relevant studies, extract key outcomes into a table, summarize consensus vs. disagreement, and produce a “questions for my doctor” brief with citations (not medical advice).
- **Real estate (Zillow/Redfin/MLS portals)**: scan listings, pull comps, track price cuts, and build a ranked shortlist with links and notes.
- **Company research (SEC EDGAR)**: gather filings, extract material changes, and produce an investor-ready brief with source links.
- **Anything behind a login**: benefits portals, insurance claims, procurement sites, admin consoles, CRMs — the places you can’t “just ask the internet”.

## Why Laika (trust model)

- **On-device by default**: planning + safety filtering run locally; optional BYO cloud models only see redacted context packs (never cookies/session tokens).
- **Explicit permissions, not implicit access**: a local Policy Gate (allow/ask/deny) and scoped capability tokens protect write-actions.
- **Designed to resist data loss**: sensitive-field filtering before typing/logging/egress, injection hardening, and autonomy downgrade on suspicious content.
- **Auditable by design**: action previews, reason-coded decisions, and a complete history of what happened and why.

## A few “try this” prompts

- “Review my last 90 days of card transactions, flag anything suspicious, and prepare a dispute-ready summary. Ask before submitting anything.”
- “Find 2BR listings in my target neighborhoods, pull comps, and build a ranked shortlist with links and notes.”
- “Pull the latest 10-K/10-Q/8-K for $COMPANY, summarize material changes, and produce a 1-page brief with citations.”
- “Research $TOPIC on PubMed and clinical guidelines, summarize the evidence, and draft questions I should ask my doctor.”

## Business

- **Freemium**: Free tier for local-first, low-risk automation; Premium tier for the latest model pack (updated faster), higher limits, and included cloud credits for hard workflows.
- **Cost control**: pay-as-you-go credits for additional cloud usage; BYO model key for power users who want maximum control.
- **Teams/Enterprise**: per-seat pricing with centralized policy controls, shared usage pools, audit retention, and admin governance.
