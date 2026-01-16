# Laika AIBrowser — VC Pitch Card (What / Why / How)

## One-liner

Laika is a secure AI agent embedded in Safari that turns intent into safe, automated actions inside your existing web sessions — policy-gated, on-device by default, and fully auditable.

## What

- A secure AI agent embedded in Safari that can observe, extract, and act inside your real, authenticated web sessions.
- Built for long-running automation with human-in-the-loop controls and an audit trail.

## Why

- Websites are interactive workflows: answers and actions are buried behind navigation, filters, and multi-step forms.
- The most valuable work is behind trusted sessions (research tools, CRMs, finance portals) and can’t be safely delegated to “copy/paste into a chatbot”.
- Agentic browsing is uniquely attackable: prompt injection and data exfiltration are default failure modes without strict boundaries.

## How

- Two execution surfaces: **Workspace** (isolated, safe default) + **Connect to this site** (explicit opt-in to operate inside Safari tabs).
- On-device by default: planning + safety filtering run locally; optional BYO cloud models use redacted context packs (never cookies/session tokens) with Policy Gate enforcement kept local.
- Security-by-design: typed tool protocol, Policy Gate (allow/ask/deny), scoped capability tokens, injection hardening, and sensitive-field filtering before typing/logging/egress.
- Resumable long-running automation: pause/resume with an append-only run log and explicit checkpoints.
- Transparent UX: action previews, reason-coded decisions, and an auditable history of what happened and why.

## Moat (Security)

- Security is the product: strict boundaries, local enforcement, and visible controls are harder to copy than “automation demos”.
- Prompt injection resistance is architectural: data/instruction separation, autonomy downgrade on suspicious content, and tool-only execution with explicit approvals.

## Business

- Subscription per seat; enterprise tiers for policy controls, audit retention, and admin governance.
- Local inference lowers COGS and supports strong margins at scale.
