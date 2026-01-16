# Laika AIBrowser - Investor Pitch Card

## One-liner

Laika is a secure AI agent embedded in Safari that turns intent into safe, automated actions inside your existing web sessions — policy-gated, on-device by default, and fully auditable.

## Thesis

Autonomy is where the value for Agentic AI is because most websites are interactive workflows, not documents. The winning product makes the web navigable by intent—inside real authenticated sessions—without requiring website redesign or unsafe data exposure.

## The problem

- Websites bury answers behind navigation, filters, and multi-step forms—turning “I know what I need” into a scavenger hunt across menus and tabs.
- The most valuable work lives behind login and UI flows: premium research, CRMs, finance portals, and internal tools still require manual navigation, extraction, and copy/paste across tabs.
- Delegating to AI is unsafe today: prompt injection and data exfiltration risks make “just give it control” a non-starter for sensitive sessions.
- Automation today is either “record-and-replay” that breaks, or custom integrations that take months—neither covers the long tail of real websites.

## The solution

Laika makes Safari programmable without compromising security or reliability.

- Two execution surfaces: an isolated browser for safe research and an explicit opt-in "My Browser" Connector that operates inside Safari tabs.
- On-device decisioning (default): Safari talks directly to websites, while agent decisions and safety filtering run on-device. Optional cloud models are BYO OpenAI/Anthropic, using redacted context packs (never cookies/session tokens).
- Secure-by-design automation: typed tool protocol, Policy Gate (allow/ask/deny), scoped capability tokens, element handles (not raw selectors).
- Resumable long-running automation: runs pause/resume across Safari suspension and app restarts with an append-only run log.
- Operator-grade UX: toolbar popover for one-click Observe/Summarize, in-page action previews, and a companion window for approvals and audit trails.

## Why now

- Apple Silicon makes high-quality local models viable with low latency and low marginal cost.
- Safari Web Extensions and native messaging enable deep, stable integration.
- Privacy-first AI workflows are becoming a buying criterion for enterprises and prosumers.

## Differentiation and moat

- Security system, not "safety vibes": strict tool contract, scoped capability tokens, Policy Gate enforcement, and explicit approvals.
- Injection-resilient by design: data/instruction separation, quarantine, and autonomy downgrade on suspicious content.
- Auditable, policy-gated execution: reason-coded decisions, append-only run log, explicit cross-site intent logging.
- On-device by default: minimizes data exposure and avoids cloud latency/cost.

## Wedge and expansion

- Start with Safari power users in authenticated web apps (operators, analysts, sales, researchers).
- Distribute via Apple’s App Store for one-click install and automatic updates, reducing user and IT friction.
- Land with Observe + Assist on high-value sites; expand to constrained Autopilot as policies harden.
- Grow into persistent, auditable workflows for teams and regulated industries.

## Business model

- Subscription per seat; enterprise tiers for policy controls, audit retention, and admin governance.
- Local inference lowers COGS and supports strong margins at scale.
