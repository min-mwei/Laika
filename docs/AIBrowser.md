# Laika: Secure AI Agent Embedded in Safari (AIBrowser Design Doc)

Laika is a macOS Safari extension + companion app that embeds a **secure AI agent** in Safari, turning intent into safe actions inside your existing browsing sessions. Safari still talks directly to websites; Laika keeps agent decisioning and safety filtering on-device by default. If you opt into BYO cloud models (OpenAI/Anthropic), Laika sends only redacted context packs—never cookies or session tokens—and keeps Policy Gate enforcement local.

**What “on-device by default” means**

- Safari talks directly to websites; Laika does not proxy your browsing through a cloud browser.
- Your live session state (cookies/session tokens) and typed secrets stay on your Mac; Laika doesn’t upload your session to a cloud browser or model provider by default.
- If you enable BYO cloud models, Laika sends only a **redacted context pack** (never cookies/session tokens) and keeps Policy Gate enforcement local.

## Status

This is a design draft for an MVP. It focuses on security posture, system boundaries, and contracts. Specific implementation details (exact Safari APIs, storage schema, model selection) should be validated with prototypes.

Prototype UI note: the current build renders an attached, in-page **sidecar panel** inside the active tab, toggled by the toolbar icon (position configurable in Settings). The sidecar is scoped per Safari window; each window has its own attached panel. If the active tab can’t be scripted, the toolbar opens the same UI as a standalone panel window. Plan requests include a sanitized summary of open tabs in the current window (title + origin only, no query/hash) so the agent can reason about multi-tab context without gaining cross-tab access. References to a “popover” below should be read as “sidecar UI” for the prototype.

Prototype mode note: the current implementation runs in **assist-only** mode. Read-only tasks (summaries) are handled via the `content.summarize` tool plus policy gating; there is no separate observe-only mode in code.

Convergence note: further changes should be driven by probe/prototype results (Safari/WebExtension behavior, IPC limits, sandboxed local inference), not more design expansion.

Next steps (prototype checklist):

- Run the Safari capability probe harness across Safari/macOS versions and update the feasibility matrix from observed results.
- Prove sandboxed local inference viability in the intended process (app vs XPC worker) without extra entitlements.
- Validate IPC constraints: payload caps/latency, chunking, and cancellation/backpressure end-to-end.
- Walk permission UX flows on a clean Safari profile + Private windows and confirm the “permission failure ladder”.
- Fault-inject Stop/Panic paths (tab close mid-step, worker suspended, Safari crash/reopen) and confirm “no surprise replays”.

## At a glance

- Two execution surfaces: `Isolated` (default) + `My Browser` Connector (explicit opt-in)
- On-device decisioning (default): planning + safety filtering run on your Mac; optional BYO OpenAI/Anthropic via redacted context packs
- No cloud browser: automation executes locally (Safari tabs or local Isolated WKWebView); cloud inference is optional and uses redacted context packs
- Compute placement: local inference runs in sandboxed Swift (app/XPC); the extension stays thin (observe/act + UI + routing)
- Security moat: tool-only contract + Policy Gate + capability tokens + injection hardening
- Resumable automation: append-only SQLite run log; pause/resume; no surprise replays
- Context management: SQLite context store + checkpoints; no general RAG/vector DB

## Why AIBrowser

- Websites are interactive workflows: answers are buried behind navigation, filters, pagination, and multi-step forms.
- The most valuable work happens inside authenticated sessions (research tools, CRMs, finance portals) where you can’t safely “just paste everything into a chatbot”.
- Agentic browsing is uniquely attackable: prompt injection and data exfiltration are the default failure modes unless the architecture enforces boundaries.
- Real automation must be long-running and interruptible: humans step in, tabs suspend, pages change, and work has to resume safely.

## Why Not A Cloud Browser

Cloud-executed browsers can be useful, but they are harder to secure and harder to sell for sensitive workflows: remote browser instances, remote rendering/streaming, screenshot/DOM storage, auth bridging, and multi-tenant isolation all expand the attack surface and enterprise optics risk.

Laika’s stance is “privacy by architecture”:

- **No cloud browser**: automation executes locally in Safari (or the local Isolated surface), so your trusted sessions and IP stay on your Mac.
- **Cloud models are optional BYO**: when enabled, Laika sends only redacted context packs and never sends cookies/session tokens.
- **Security is visible in the UX**: Policy Gate reason codes, action previews, retention/redaction defaults, and “what gets sent” summaries are first-class UI.

## Goals

- **Super secure by default**
  - Runs an **on-device (local) LLM** with prompt-injection hardening as the default mode.
  - Treats all web content as *untrusted input* and constrains agent actions via a strict tool API + policy gate.
  - Keeps agent decisioning on-device by default; optional cloud models are explicit opt-in and use redacted context packs (never cookies/session tokens).
  - Minimizes permissions/entitlements and isolates components using macOS sandboxing.
- **Web browsing automation + autonomy**
  - Makes the web navigable by intent: reduces menu/filter/form “scavenger hunts” by turning goals into safe navigation, extraction, and form-filling—without requiring website redesign.
  - Turns user goals into plans, executes steps across pages/tabs, and adapts to changing DOMs.
  - Supports “autopilot” with graded safety levels and human-in-the-loop approvals for sensitive actions.
- **Multi-modal collaboration with humans**
  - Lets users talk, point, and show (voice + screenshots/selection + highlighting).
  - Explains what it’s doing, previews actions, and provides audit trails.

## Non-goals (initially)

- Fully automated money movement, trading, or irreversible account changes without explicit user approvals.
- Cloud-by-default inference or sending browsing/session content to third-party model providers without explicit opt-in.
- Circumventing websites’ terms of service, paywalls, or bot protections.

## Terminology (quick glossary)

- **Laika**: the macOS app + Safari extension product.
- **AIBrowser**: the “agentic browser” capability inside Laika (observe + assist + autopilot).
- **Agent Orchestrator**: Swift component that runs the plan/execute loop.
- **Agent Core**: the Swift-side “engine” (Policy Gate + Orchestrator + Storage + Models) that is the source of truth and performs all privileged work (GPU inference, file parsing, encryption).
- **Tool Router**: Swift component that dispatches validated tool calls to JS/native implementations.
- **Policy Gate**: Swift policy engine that decides `allow` / `ask` / `deny` for each tool call.
- **Tool**: a typed, versioned command the model can request (e.g., `browser.click`).
- **Capability token**: a signed, scoped token required for JS tool execution (per tab/session/site mode).
- **Element handle**: an opaque reference minted by trusted extraction code that maps to a DOM element in a specific tab/frame.
- **Execution surface**: where the agent operates (isolated app-owned browser vs “My Browser” Safari tabs).
- **Run / AgentFlow**: a long-running, resumable task execution recorded as steps/events.
- **Checkpoint**: a durable summary/snapshot event used to resume and to roll back safely.
- **Context pack**: the bounded, budgeted subset of stored context assembled for a specific model call.
- **Trusted vs untrusted inputs**:
  - Trusted: user prompt, local policy, signed app state, tool outputs.
  - Untrusted: all web content (DOM/text/HTML), OCR text, third-party documents shown in a tab.
- **LLM / SLM / VLM**: large language model / small language model / vision-language model, all run locally by default.

## Example Use Cases

1. **Housing analysis (Zillow / Redfin / listings)**
   - Compare properties, extract structured attributes, compute tradeoffs, and keep a watchlist.
2. **Company analysis (SEC/EDGAR)**
   - Pull filings, summarize risk factors, extract key financial tables, compare quarter-over-quarter changes.
3. **Medical research**
   - Search literature, extract evidence with citations, track inclusion/exclusion criteria, and build summaries.
4. **GitHub code browsing & reading**
   - Navigate repos, answer questions with file-level grounding, track call graphs, summarize PRs/issues.
5. **Banking balance analysis**
   - Read balances and statements, reconcile across accounts, flag anomalies (read-only by default).
6. **Credit card transaction analysis**
   - Categorize transactions locally, spot subscriptions, detect duplicates/fraud indicators, produce reports.

## Functional Requirements

### 1) Security + Privacy (default posture)

- **On-device decisioning (default)**: agent planning/tool use and safety filtering run on-device. Safari still loads websites normally; by default Laika does **not** send page content or Safari session state (cookies/session tokens/form values) to third-party model providers for agentic decisioning.
- **No cloud browser**: Laika does not proxy your browsing through a remote browser by default; automation runs inside your local Safari sessions (Connector) or the local Isolated surface.
- **Optional cloud models (explicit opt-in)**: users can connect their own OpenAI/Anthropic accounts for higher-quality planning/writing. When enabled, Laika sends only a redacted **context pack** (never cookies/tokens), and still enforces Policy Gate + local input/output classification to reduce exfiltration risk.
- **Prompt injection resilience**:
  - Web pages are treated as *untrusted content*; they cannot directly instruct the agent.
  - The agent must follow a fixed “tool-only” contract and a policy engine that can veto actions.
  - Compartmentalized memory (per-site / per-task) to prevent cross-site data leakage.
- **Least privilege**:
  - Only request Safari permissions and macOS entitlements when a feature needs them.
  - Sensitive capabilities (clipboard write, downloads, accessibility automation, screen recording, mic) are opt-in.
- **Explainability + audit**:
  - Action preview + step-by-step execution with a durable SQLite-backed audit/run log (with redaction controls).
- **User intent integrity**:
  - The only trusted instructions are from user input, signed extension-to-app messages, and local policies.

Security is a user-facing feature: Laika operates on untrusted web content and (optionally) inside your real authenticated sessions. “On-device” refers to *agent decisioning and memory*, not your browser’s normal web traffic. Laika is designed to be **prompt-injection resistant by default** via tool mediation + policy gating + strict data/instruction separation, with action previews and an auditable, redacted run log.

Privacy boundary (what leaves the device):

| Data plane | Default behavior | When cloud models are enabled |
| --- | --- | --- |
| Browser ↔ websites | Normal Safari traffic using your local sessions/IP | Same |
| Agent decisioning | Local models (planning + tool use + Guard/Filter) | Local Guard/Filter + Policy Gate still enforced |
| Cloud LLM (opt-in) | Off | Redacted context pack only; never cookies/session tokens |
| Storage | Local SQLite + encrypted artifacts (redacted) | Same |

### 2) Web Automation + Autonomy

- **Reliable interaction primitives**: click/type/scroll/select/upload/download/tab-management, with retries.
- **Structured extraction**: tables, key-value pairs, citations/anchors, and provenance for summaries.
- **Adaptive planning**: handles login gates, pagination, infinite scroll, and DOM updates.
- **Long-running workflows**: pause/resume across restarts and long approvals, backed by a durable run log.
- **Autonomy levels**:
  - *Assist* (current): propose actions; user approves each step or batch; read-only summaries run through `content.summarize`.
  - *Autopilot* (future): execute within strict policy constraints; escalates to user on sensitive steps.

### 3) Multi-modal Human Interaction

- **Voice**: “Laika, summarize this page” / “Find comparable listings under $X”.
- **Visual grounding**: user can select a region; Laika explains what it sees and acts on that target.
- **In-page guidance**: highlights elements before clicking/typing; shows “why this element” reasoning.
- **Accessible UX**: keyboard-first command palette, optional screen reader integration, and clear states.

## Threat Model (what we defend against)

- **Prompt injection**: pages that include malicious instructions (“ignore prior rules… exfiltrate data…”).
- **Data exfiltration via the browser**: tricking the agent into pasting secrets into a form or navigating to a leak URL.
- **Cross-site leakage**: learning from bank page and summarizing into another site without user intent.
- **Clickjacking / deceptive UI**: hidden or overlayed elements causing unintended actions.
- **Confused deputy**: user-provided instructions or pasted content that tries to override safety rules (“just run this”, “ignore policies”).
- **Clipboard attacks**: malicious clipboard contents or unintended paste destinations.
- **Local compromise**: local malware or other apps reading logs/artifacts if retention/redaction are weak.
- **Malicious extensions**: another extension attempting to influence/observe state or UI surfaces.
- **Supply-chain**: untrusted model files, unsigned updates, or third-party scripts increasing attack surface.

## Security Principles (design constraints)

1. **Untrusted-by-default**: everything from the web is data, not instruction.
2. **Tool mediation**: the model cannot “do” anything except request typed tools.
3. **Policy before execution**: every tool call is evaluated against user intent, site risk level, and capabilities.
4. **Compartmentalization**: isolate *tabs*, *sites*, *tasks*, and *secrets* to reduce blast radius.
5. **No silent side effects** on sensitive surfaces: explicit approvals for money/identity/medical/credentials.

## MVP Scope / Milestones

    - **MVP 0 (Assist-only)**: isolated surface, `observe_dom`, `extract_table`, citations, toolbar sidecar panel + companion UI, SQLite run log (audit + context).
- **MVP 1 (Assist)**: “My Browser” authorization, `find`, `click`, `type`, element highlighting, per-step approvals, dedicated task tab(s), pause on takeover.
- **MVP 2 (Autopilot on low-risk sites)**: policy matrix defaults, durable pause/resume + cancellation, timeouts/retries, rollback to checkpoints, recovery + verification loops.
- **MVP 3 (Multi-modal)**: viewport capture + region selection, voice input, optional vision grounding.
- **Hardening**: injection test suite, adversarial pages, Safari edge cases, perf/battery tuning.

## High-Level Architecture

Laika is best modeled as a **Safari Web Extension** plus a **sandboxed macOS companion app**.

For simplicity, the diagram below focuses on the Safari-integrated “My Browser” surface. The isolated surface uses the same Agent Orchestrator + Policy Gate, but different “browser tool” implementations (app-owned WebView instead of extension content scripts).

```text
┌─────────────── Safari Tab (untrusted web) ────────────────┐
│  Page DOM / JS / Network                                  │
│   ┌───────────────┐     messages      ┌─────────────────┐ │
│   │ Content Script│◀──────────────────▶│ Background/Worker│ │
│   └───────────────┘                   └─────────────────┘ │
└───────────────────────────────┬───────────────────────────┘
                                │ native messaging (typed)
                                ▼
┌──── Native App Extension (native messaging handler) ────────┐
│  Schema validation, routing, backpressure; no heavy work     │
└───────────────────────────────┬─────────────────────────────┘
                                │ XPC / app IPC (typed)
                                ▼
┌────────────────── Laika macOS App (sandboxed) ─────────────┐
│  UI (toolbar sidecar panel/overlay + companion window), Policy Gate, Audit Log │
│  Agent Orchestrator (plan/execute loop)                    │
│     ├─ Local Model Runtime (LLM/VLM)                        │
│     ├─ Tool Router (browser tools, local tools)             │
│     └─ Storage (SQLite context + durable logs; encrypted artifacts) │
│           ▲                    │                            │
│           └──── XPC services ──┘ (optional extra isolation) │
└─────────────────────────────────────────────────────────────┘
```

### Major Components

- **Safari Extension (JavaScript)**
  - Content scripts: DOM reading, element targeting, safe interactions, page overlays/highlights.
  - Background/service worker + sidecar UI: session routing, tool dispatch, permission prompts, native messaging.
- **macOS App (Swift)**
  - Agent Orchestrator: runs the autonomy loop; coordinates tools and model calls.
  - Policy Gate: enforces security rules and user-configured permissions; blocks unsafe tool calls.
  - Model Runtime: runs local models (text + optional vision) and manages context windows.
  - UI: companion window, approvals, action previews, audit views, settings, model management.
- **Optional XPC Services (Swift)**
  - “LLM Worker” service (GPU/Metal allowed) with **no network** entitlement for on-device inference.
  - “Artifact/File Worker” service for parsing and handling user-selected files (security-scoped bookmarks), and for encrypting/decrypting stored artifacts.
  - “Browser Tool Worker” service with limited, auditable command surface (optional extra isolation for DOM/action tooling logic).

## Data Flow / Trust Boundaries

Core rule: treat web content as untrusted; keep authorization and policy decisions in Swift.

```text
Untrusted Web Page (DOM/text/visuals)
   │
   ▼
Content Script (extract/act) ──► Background Script ──► Native Messaging ──► Native Bridge ──► Swift App
   ▲                                                                      │
   └──────────────────── tool results / observations ◄────────────────────┤
                                                                          ▼
                                         Policy Gate + Tool Router ◄─ Agent Orchestrator ◄─ Local Models
                                                                          │
                                                                          └─ Optional Cloud Models (BYO key, redacted context packs)
```

- **What crosses JS ⇄ Swift**: only typed tool requests/results and structured observations (never arbitrary JS/code).
- **What reaches the models (default)**: structured facts + short text snippets + citations; screenshots are optional and policy-gated.
- **If a cloud model is enabled**: send only a redacted context pack; never send cookies/session tokens; keep Policy Gate + local Guard/Filter enforcement on-device.
- **What is persisted**: an append-only SQLite run log (tool calls, policy decisions, approvals, summaries) plus user-approved artifacts; avoid storing raw page text/screenshots on sensitive sites by default.
- **At-rest protection**: Keychain for secrets; SQLite-backed context/audit logs + encrypted artifacts; strict scoping by `(profileId, site origin, tab, task)`.

## Execution Surfaces (Isolated vs “My Browser” Connector)

Many workflows don’t need your logged-in sessions; some absolutely do. Laika supports two execution surfaces (“two browsers, one unified experience”):

- **Isolated surface (default)**: an app-owned, sandboxed browsing surface (e.g., WKWebView) with a separate cookie jar and no access to your Safari sessions. Use this for research/extraction and low-risk navigation to reduce account risk.
- **My Browser surface (explicit opt-in; “Connector”)**: Laika operates inside Safari tabs using your trusted local sessions. This is the “local advantage”: actions come from your Mac’s trusted Safari session and IP, which reduces CAPTCHAs, suspicious “new device” prompts, and re-auth friction on premium/authenticated tools (CRMs, paid research platforms, etc.).
- **Surface selection**: default to `Isolated`, and escalate to `My Browser` only when the workflow truly needs authenticated access or user-specific state.

When a task requests “My Browser”, Laika should:

- Ask for **one-time authorization** scoped to the task + site mode; mint short-lived capability tokens.
- Open/attach to a **dedicated task tab** (or dedicated Safari window) so the user can watch in real time, take over, or stop instantly (close the tab/window or hit “Stop”).
- Treat **user interaction as takeover**: pause autopilot when the user focuses/types/clicks, and require re-authorization to continue.
- Make limitations explicit: complex interactions (drag/drop, multi-step wizards, bespoke widgets) may fail and should fall back to “assist with guidance”.
- Treat **closing the dedicated task tab** as a stop signal: revoke tokens, cancel in-flight work, and transition the run to `cancelled`.

### “My Browser Connector” flow (3-step UX)

This mirrors the mental model users expect from modern “browser agent” products:

1. **Turn on the Connector**: user selects `My Browser` for the current site/run (explicit opt-in).
2. **Authorize session**: Laika shows what it will access/do and requests one-time authorization (capability tokens + policy in effect).
3. **Monitor/intervene**: Laika operates in a dedicated task tab (or dedicated Safari window). User can take over by interacting, or stop instantly by closing the task tab/window or hitting `Stop/Panic`.

Authorization summary (must be user-facing, before step 2 completes). Reuse this exact layout in the sidecar panel, companion window, and any remote approval UI:

- Verified attachment target (this Safari tab/window) and the verified `origin`(s).
- Selected mode (`Observe`/`Assist`/`Autopilot`) and the allowed action categories (click/type/submit/download/paste).
- What always requires approval (and what is gesture-required vs. background-safe).
- What will be logged (audit trail) and what will be persisted (SQLite), plus the retention/“forget this run/site” controls.
- What may be sent to any model provider: `on-device only` by default; if cloud is enabled, show a preview of the redacted context pack and explicitly state that cookies/session tokens never leave the device.
- How to stop instantly (`Stop/Panic` and “close the task tab/window”), and how to revoke authorization.

Implementation note: Safari Web Extensions do not currently expose Chrome-like tab group APIs. Preserve the same mental model via a dedicated window and/or a consistent tab-title prefix (e.g., `[Laika] <task>`), plus a “Laika Tasks” entry in the companion window.

### Isolated surface parity (WKWebView)

The isolated surface is a major product lever (safe research + automation without touching Safari sessions). For MVP, make it concrete:

- **Cookie/session isolation**: use a WKWebView with a separate `WKWebsiteDataStore` from Safari. Default to an ephemeral store; allow an explicit “remember logins in Isolated” toggle that persists only inside Laika’s sandbox (still separate from Safari).
- **Tab model**: treat isolated tabs as app-managed “task tabs” shown in the companion window. A run can open multiple isolated tabs, but only one mutating step executes at a time per run.
- **Downloads & artifacts**: downloads initiated by the isolated surface go through Laika’s download manager. Store artifacts encrypted-at-rest and require explicit user action to export to the file system.
- **Transition Isolated → My Browser**: support “Continue in My Browser”:
  - Open the current isolated URL in Safari and attach the run to that Safari tab.
  - Do **not** share cookies/session state; require explicit Connector authorization and a fresh `observe_dom`.
  - Carry only a checkpoint summary + citations across surfaces; log the surface transition as an explicit event.
- **Top parity gaps vs Safari tabs (and fallbacks)**:
  1. **Password manager / passkeys / SSO**: isolated WebViews may not benefit from Safari’s saved sessions and some auth flows; fall back to “Continue in My Browser” or manual handoff.
  2. **Extension ecosystem + site-specific helpers**: isolated surface won’t have other Safari extensions; fall back to Safari tabs when a helper extension is required.
  3. **Complex widgets / hardened anti-bot flows**: canvas-heavy UIs, unusual drag/drop, device attestation, or aggressive bot defenses may degrade; fall back to Assist-with-guidance or Connector mode.

## Long-running Automation (Resumable AgentFlow)

Laika tasks should feel like long-running automation, not “one shot” chats: start a run, monitor it, pause/take over, and resume later. Under the hood, this is backed by an append-only SQLite run log so runs survive Safari/background suspension, app restarts, and long human-in-the-loop waits—without repeating unsafe actions.

### Principles

- **Resumable progress**: every step is recorded so the run can resume after crashes.
- **No surprise replays**: never automatically re-run side-effecting browser actions after a restart; re-observe and re-plan instead.
- **Idempotency by design**: tool calls carry `idempotencyKey`; Swift enforces “at most once” execution where possible.
- **Human signals**: approvals, edits, and overrides are first-class events that unblock the run.
- **Rollback is logical**: moving the run head changes Laika’s *plan/context*, but does not magically undo external side effects; recovery should re-observe and continue on a new branch.
- **Re-authorization on restart**: for “My Browser” runs, capability tokens should not be persisted; resuming requires explicit user re-authorization.

### SQLite-backed run log (sketch)

Use SQLite as an append-only source of truth for runs:

- `run`: one row per task run (`profileId`, status, selected surface, site mode, current head/checkpoint).
- `run_event`: immutable events (user message, observation, model call/result, tool request/result, policy decision, approval, cancellation).
- `run_step`: derived “current step state” (optional; can be rebuilt from events for auditing/debugging).

Example event types:

- `user.message`, `ui.approval`, `ui.takeover`, `ui.cancel`
- `page.observe`, `page.extract`, `browser.tool.request`, `browser.tool.result`
- `model.prompt`, `model.output`, `policy.decision`
- `run.checkpoint`, `run.rollback`, `run.branch`

Operational notes:

- Prefer **WAL mode** and a **single-writer queue** (SQLite is multi-reader/single-writer); treat writes as critical sections.
- Commit each step’s “intent + result” as a transaction so the run can always resume from a consistent point.
- Runs can be **evicted from memory** (idle/long waits) and later rehydrated by replaying events from SQLite.
- Store large artifacts (screenshots, PDFs) as encrypted files; store only metadata + hashes in SQLite.

**Audit log integrity (optional)**

For compliance-grade audits, make the run log tamper-evident and forward-compatible:

- **Hash chaining**: store `{prevEventHash, eventHash}` on each `run_event`, computed over a canonical serialization of the event payload. This makes edits/deletions detectable.
- **Schema versioning**: store `schemaVersion` (DB) + `protocolVersion` (tool/messaging) with each event so historical runs remain interpretable.
- **Migrations**: prefer additive migrations (new columns/tables) and avoid rewriting historical event payloads; keep a `schema_migration` table and test upgrades.
- **Export/verify**: when exporting a run, include the final/root hash so the user (or auditor) can verify integrity.

### Run State Machine (explicit states + UI)

Runs move through explicit states derived from the SQLite event log (UI surfaces render the same state):

- `idle`: no active run.
- `authorizing`: waiting for “My Browser” authorization (or missing permissions).
- `observing`: collecting fresh page facts/snapshots.
- `planning`: model call to produce the next step(s).
- `awaiting_approval`: policy returned `ask` or a user gesture is required.
- `executing`: performing a single tool step (mutating actions are serialized per tab/frame).
- `verifying`: checking success criteria / postconditions.
- `paused`: waiting on an external condition (tab reattach, long timer, user instruction).
- `takeover`: user is interacting with the page; automation is paused until explicit resume.
- `completed`: success.
- `cancelled`: user stopped the run (tokens revoked; in-flight work cancelled).
- `failed`: terminal error after bounded retries.

Common transitions:

- `idle → authorizing|observing` (start)
- `authorizing → observing` (authorized)
- `observing → planning → awaiting_approval|executing`
- `executing → verifying → observing|completed`
- `* → takeover` (user interaction detected)
- `takeover → paused` (user leaves page / timeout) or `takeover → observing` (explicit resume)
- `* → cancelled|failed` (stop/error)

UI mapping (principle): the toolbar sidecar panel shows the current state and “Stop/Resume”; the overlay is used only for previews/confirmations; the companion window is the primary place to view the full run log and queue.

### Stop / Panic reliability (must always work)

Stop is a product promise, not a button: it must work even when Safari suspends the extension, the task tab is gone, or the user is not looking at the sidecar panel.

- **Stop (per-run)**: cancels the active run, revokes its capability tokens, and cancels in-flight tool work. It should not lock future runs.
- **Panic (global)**: immediately cancels all runs, revokes all outstanding `My Browser` capability tokens, and puts the app into `locked` until the user explicitly unlocks/re-authorizes.
- **Always-available entry points**:
  - toolbar sidecar `Stop/Panic`
  - companion window `Stop/Panic` (primary reliability surface)
  - optional menubar item (quick Panic)
  - optional global hotkey (if feasible within macOS/Safari constraints)
  - remote control (if enabled) must always be able to Panic
- **Watchdog on disconnects**: if the extension/content script disconnects mid-step (service worker suspension, tab close, navigation unload), the app transitions the run to `paused` (or `cancelled` if the task tab was explicitly closed), revokes tokens, and requires a fresh reattach + `observe_dom` before any further mutating action.
- **“Close the task tab/window to stop” (Safari-tight)**:
  - When Laika opens a task tab/window, record `{runId, windowId?, tabId, createdByLaika: true}` in the run log and display a clear `[Laika] <task>` title prefix.
  - Treat `tabs.onRemoved` / window close events for that recorded target as an immediate Stop signal.
  - If Safari crashes/restarts and events are missing, the run resumes as `paused` and requires the user to reattach; never “continue in the background” without an active, attached target.

### Single-writer Persistence (SQLite ownership)

- The **Swift-side Agent Core** (Policy Gate + Orchestrator + Storage) is the single writer to SQLite (run log, checkpoints, user decisions).
- The **Native Bridge** and the JS extension (content/background/popup) **do not write** to SQLite; they send events/requests via IPC and render state streamed from the Agent Core.
- Store the SQLite DB and encrypted artifacts in an **App Group container** so the app and its bridge can access persistence, but keep write coordination in the Agent Core to avoid corruption and complex locking.

### App Group Data Security (encryption + access boundaries)

Treat the App Group container as a shared disk boundary and design so the extension never gains access to sensitive plaintext:

- **Key ownership**: encryption keys live in the app’s Keychain items; the extension does not have access to the decrypting key material.
- **Encrypted artifacts**: screenshots/PDFs/tables saved as files are encrypted at rest; SQLite stores only metadata + hashes.
- **Redacted logs by default**: avoid persisting raw page text and typed form values on sensitive sites; keep secrets out of SQLite entirely when possible.
- **State via messaging**: the extension UI should rely on state streamed from the app (already policy-gated/redacted), rather than reading any local database directly.

### Tab Attachment and Resume (My Browser)

Safari tab IDs and window lifecycles are not stable across restarts/suspension. Treat tab linkage as best-effort and user-confirmed:

- Persist a `tabRef` for “My Browser” runs: `{profileId, lastKnownOrigin, lastKnownURL, lastKnownTitle, lastSeenAt, previousTabId?}`.
- On resume:
  - If the previous `tabId` still exists and the origin matches, reattach and immediately `observe_dom`.
  - Otherwise, search open tabs for the same origin and present candidates for user confirmation (“Attach to this tab”).
  - If no suitable tab exists, enter `paused` and prompt the user to open the site and attach.

### Storage Compaction (summaries + artifact eviction)

Long-running runs can accumulate large histories. Keep the system responsive by compacting, without losing auditability:

- **Checkpoint summaries**: periodically write `run.checkpoint` events that summarize the last segment (goal, key facts, what succeeded/failed, next intent). Context packs prefer checkpoints over raw history.
- **Cold vs hot history**: keep recent events “hot” (full detail) and older events “cold” (summary + minimal provenance). Deleting should require explicit user intent (or retention policy).
- **Observation pruning**: allow pruning or redacting large `page.observe` payloads after a checkpoint while keeping citations/anchors and hashes.
- **Artifact eviction**: evict old screenshots/PDFs by retention policy; keep encrypted metadata + hashes in SQLite. Default to stricter retention on sensitive sites.
- Run compaction/maintenance in the optional worker (`VACUUM`/checkpointing/cleanup), never in content scripts.

## Context Window Management (SQLite-backed context store)

“Context” should not live in RAM and it should not equal the model’s context window. Laika keeps full-fidelity run history in SQLite, then compiles a bounded **context pack** for each model call.

Laika is **not** building a general RAG system over a persistent document corpus. Context packs are constructed from the current run’s durable history (observations, checkpoints, approvals) and explicit user intent. Embeddings may be computed locally for internal scoring (e.g., deduping or prioritizing snippets), but they are not a user-facing retrieval subsystem.

### What SQLite stores

- **Full run transcript**: user instructions, approvals, agent plans, tool I/O, policy decisions.
- **Observations**: structured DOM facts, extracted tables, citations, and (optional) screenshots with redaction metadata.
- **Derived memory**: summaries/checkpoints, pinned facts, per-site notes, and “do/don’t” preferences.

### Building a context pack (budgeted + scoped)

For each model invocation, construct inputs in priority order:

1. Fixed system constraints (security rules, tool contract, policy posture).
2. User goal + current autonomy/site mode.
3. Fresh page facts (from `observe`/`extract`, not raw HTML).
4. Recent step history (last N turns/tool calls) to preserve local coherence.
5. Checkpoint summaries + pinned facts (to carry long-run intent).

Hard requirements:

- **Profile scoping**: never mix state across Safari profiles/web app containers; treat `profileId` as a security boundary for memory, policy defaults, and run logs.
- **Origin scoping**: default to same-origin memory only; cross-site carry requires explicit user intent and is logged as such.
- **Redaction-first**: redact before persistence and again before model input; never include secrets typed into forms by default.
- **Rollback/branching**: “undo” is implemented by moving the run’s head pointer to a prior checkpoint/event (and optionally creating a new branch). This enables recovery from context poisoning and lets users revise decisions without losing auditability.

### Cross-site Intent UX (explicit carry)

Cross-site carry should be explicit, reviewable, and reversible:

- When a plan would **use data from Origin A while acting on Origin B**, Laika prompts: what will be carried (summary + fields), where it will be used, and why.
- User choices: `allow once`, `allow for this run`, `always allow for this site pair`, or `deny`.
- Record the decision as a durable event (`ui.cross_site_intent`) and show it in the audit log.
- Default behavior on sensitive origins: `deny` unless the user explicitly opts in.

## Remote Start & Monitoring (optional; roadmap)

Remote start/monitor is a headline use case for modern “browser agent” products: your Mac keeps the trusted local session/IP, while you initiate, watch, and intervene from another device.

Design constraints (security-first):

- **Explicit opt-in**: remote control is disabled by default; pairing requires a local, trusted action (QR code / one-time code) and can be revoked instantly.
- **Mac is the executor**: the phone cannot mint capabilities or bypass policy; all Policy Gate checks and `capabilityToken` issuance happen on the Mac.
- **End-to-end encryption**: remote messages should be E2E encrypted between the phone and the Mac; any relay service must not have plaintext access.
- **Data minimization by default**: remote views show redacted run state (step names, timestamps, decision reasons) and never stream cookies/session tokens. Sharing screenshots/DOM excerpts should be an explicit per-run toggle.
- **Panic is global**: remote must always be able to `Stop/Panic` a run immediately (revokes tokens, cancels in-flight work, locks “My Browser” until re-authorized).

Recommended “run control plane” UX:

- Current run status + last action + next pending approval (if any).
- Approve/deny prompts that include the verified origin, policy reason code, and what would be sent to any model provider (if cloud is enabled).
- Global `Stop/Panic` and a per-site Connector toggle state.

## Safari Integration (Swift + JavaScript)

### Why Safari (trust + distribution)

Safari’s constraints are real, but they can be a trust advantage for users and IT:

- **App Store distribution**: signed builds, automatic updates, and a familiar install path that reduces “random extension” risk.
- **Per-site permissions**: Safari’s model (per-site grants, visible extension controls) matches Laika’s explicit authorization posture.
- **Sandbox-first platform**: macOS entitlements and process isolation make it feasible to build “no-network” local-model workers and strict data boundaries.

### Safari Extension Architecture (Apple model)

Apple explicitly models a Safari web extension as three parts that operate independently in their own **sandboxed environments** (see: https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension):

- **Containing macOS app**: durable storage (SQLite), model runtime (local), policy gate, and the primary “full” UI (companion window).
- **Safari Web Extension (JS/HTML/CSS)**: content scripts + background/service worker + toolbar sidecar UI.
- **Native app extension (“Native Bridge”)**: mediates between the app and the extension’s JavaScript. It receives native messages (Swift entry point: `NSExtensionRequestHandling.beginRequest(with:)`), validates schemas, applies backpressure, and forwards typed requests into the app/XPC workers. Keep it thin; do not run heavy inference or file parsing here. (Xcode’s Safari Extension App template generates a `SafariWebExtensionHandler` for this role.)

Safari-specific constraints that affect Laika’s design (same Apple doc):

- **Content scripts cannot call native messaging**: route `content script → background/service worker → browser.runtime.sendNativeMessage()`.
- Safari ignores the `application.id` argument for `sendNativeMessage()`/`connectNative()` and always targets the containing app’s native app extension.
- In Safari 17+, messages can include a profile identifier (`SFExtensionProfileKey`) so you can scope stored state per Safari profile / web app.

For cross-process persistence (app ↔ native app extension), use an **App Group container**. Apple notes the app and the native app extension can’t share data via their private containers and should use app groups to share data.

Note: “share” refers to storage location and IPC boundaries, not decrypted access. Keep encryption keys in the app and stream only redacted state to extension UI surfaces.

### Viability evidence (links)

- Apple (packaging + distribution): https://developer.apple.com/documentation/safariservices/creating-a-safari-web-extension
- Apple (native messaging + app groups): https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension
- Apple (permissions UX + per-site grants): https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions
- Apple (MV3/service-worker lifecycle + nonpersistent background): https://developer.apple.com/documentation/safariservices/optimizing-your-web-extension-for-safari
- Prior art (market shape): https://manus.im/blog/manus-browser-operator
- Prior art (secure extension↔native connection patterns): https://support.1password.com/1password-browser-connection-security/
- App Store examples (Safari extensions shipped as apps): https://apps.apple.com/us/app/adguard-mini/id1440147259, https://apps.apple.com/us/app/adblock-for-safari/id1402042596, https://apps.apple.com/us/app/adblock-plus-for-safari-abp/id1432731683

### Manifest Version Decision (MV3-first)

- Prefer **Manifest V3** (service-worker background) to align with modern WebExtension lifecycles and to force durability into the macOS app (SQLite) rather than a long-lived background page.
- Safari unloads nonpersistent background pages/service workers when the user isn’t interacting; treat extension memory as ephemeral and persist state in the app (see: https://developer.apple.com/documentation/safariservices/optimizing-your-web-extension-for-safari).
- Treat the background as **ephemeral regardless**: even if MV2 is used temporarily for compatibility, do not rely on long-lived extension memory for correctness.
- Avoid MV2-only patterns and APIs; Safari already disallows some common MV2-era approaches (e.g., blocking `webRequest`).

### Safari API feasibility (prototype matrix)

Several MVP-critical capabilities must be validated against Safari’s actual WebExtension behavior. Treat this table as the “truth contract”: if Safari can’t do X reliably, Laika ships the explicit fallback Y and stays honest about constraints.

| Need | Safari API / permission (to validate) | Expected prompt | Failure mode | Fallback UX |
| --- | --- | --- | --- | --- |
| MV3 background suspend/wake | MV3 service worker lifecycle | none | worker suspended; messages dropped; timers stopped | app is source of truth; `run.sync` on reconnect; pause mutating steps until state is reattached |
| Just-in-time site access | `activeTab` + optional host permissions | Safari per-site prompt | permission lapses on navigation/suspension | show `permission-needed`; re-grant CTA; stay in `Observe` until restored |
| Dedicated task tab/window | `tabs.create` / `windows.create` | none | cannot create or focus reliably | open a regular task tab; fall back to companion window “Tasks” list + title prefixing |
| Viewport capture | `tabs.captureVisibleTab` (or alternative) | capture prompt (varies) | API unavailable or blocked on sensitive/restricted pages | disable visual mode; rely on DOM extraction; offer “Open in Isolated surface” with explicit consent if screen capture is enabled |
| Downloads | `downloads` API (or click-to-download) | download prompt (site/Safari) | downloads API unsupported; file save requires user | use click-to-download flows with explicit approval; manage artifacts in Isolated surface via app download manager |
| Context menu actions | `contextMenus` | none | API missing/limited | keep the sidecar as the primary entry point; use keyboard shortcut instead of context menu |
| Private window detection | Safari/private APIs may be limited | none | cannot detect reliably | default to conservative: disable Connector unless explicitly enabled; never persist if Private is suspected/unknown |
| Safari web apps (macOS 15+) | WebExtensions in web app containers | permission prompt differs | extension not available or partitioning differs | treat as separate `profileId`; if unsupported, show “Observe-only” with explanation and offer Isolated surface |
| Chrome-only features (e.g., tab groups) | N/A on Safari | n/a | feature absent | dedicated task tab/window + companion “Tasks” list; avoid tab-group copy in UI |

Prototype note: keep a small “capability probe” extension harness that records observed behavior per Safari version and drives documentation updates.

### Safari/WebExtension Constraints (design for “graceful failure”)

- **Cross-origin iframes**: content scripts can’t reliably read/act inside inaccessible frames; treat those regions as non-automatable unless an allowed frame script is present.
- **Background lifecycle**: Safari may suspend background/service worker; keep authoritative task state in the Swift app and make JS recoverable/stateless when possible.
- **File upload**: don’t attempt programmatic file selection; require explicit user flow (file picker) and/or manual upload.
- **Clipboard and paste**: gate behind explicit approvals; prefer “copy to clipboard” over silent paste.
- **Screenshots/tab capture**: gate behind explicit permissions; default off on sensitive sites.
- **Safari API gaps**: avoid relying on WebExtension APIs Safari ignores (e.g., blocking `webRequest`); plan for feature detection and fallbacks.
- **file:// access**: don’t rely on `file://` host permissions; treat local-file automation as out of scope unless the user explicitly opens files via the app.
- **Restricted pages/schemes**: many privileged surfaces are non-scriptable (e.g., `safari://` pages, Safari settings/new-tab, extension pages). Detect and show a clear “can’t automate here” state with a manual next step.
- **Degrade gracefully**: when blocked by policy or platform constraints, surface a clear manual next step (and log why).

### What Laika can’t do yet (and the fallback)

Set expectations explicitly and pair each limitation with an intentional UX path:

- **Login / 2FA / CAPTCHA**: pause and ask the user to complete it, then `Resume` (fresh `observe_dom` + re-plan).
- **Drag/drop and complex gesture widgets**: downgrade to Assist-with-guidance; highlight targets and explain next steps.
- **File pickers and uploads**: require an explicit user file chooser; Laika can fill metadata but won’t select files programmatically.
- **Cross-origin iframe apps**: explain that the frame is not automatable; suggest opening the content in a new tab or switching surfaces.
- **Highly dynamic/canvas-heavy UIs**: offer optional visual mode (screenshots) with explicit consent, or fall back to manual guidance.

### Gesture-required Actions (clipboard, downloads, uploads)

Some actions must be backed by a real user gesture or explicit user participation:

- **Clipboard/paste**: require explicit user approval; when executed, trigger from a sidecar/overlay button click so Safari treats it as user-initiated.
- **Downloads**: require explicit approval; prefer “ask then click to download” flows and log the destination choice if a file picker is involved.
- **Uploads**: do not attempt to programmatically select files; require the user to choose the file (or complete the upload step manually) and treat automation as guidance.

In the policy matrix, represent these as `ask (gesture)` rather than plain `ask`.

### User Gesture Semantics (`event.isTrusted` + user activation)

Gesture-gated actions are an implementation footgun unless treated as a hard contract:

- **User activation is fragile**: any approval that must count as a “user gesture” must execute the browser action **synchronously** inside a trusted UI click handler. Avoid `await`/async gaps before triggering paste/download/clipboard writes, or the browser may drop user activation.
- **Trust only real user input**: require `event.isTrusted` checks for:
  - takeover detection (`ui.takeover`) signals in the content script, and
  - any “gesture-required” CTA click handler (sidecar/companion).
  Ignore synthetic events dispatched by the page.
- **Concrete handshake: `ui.gesture_required`**
  - App emits `ui.gesture_required` with `{requestId, gestureKind, origin, summary, expiresAtMs}`.
  - Popover renders a single CTA (e.g., `Paste now`, `Confirm download`) and on click immediately triggers the action and sends `ui.gesture_performed(requestId)` back to the app.
  - If the gesture expires, the run returns to `awaiting_approval` and the app must request a fresh gesture (no background retries).

### Message Routing (JS ⇄ Swift ⇄ XPC)

Treat **content scripts as untrusted-adjacent**: they should not talk to native code directly. Route all native communication through the background/popup layer.

Safari-specific note (Apple): content scripts can’t call `browser.runtime.sendNativeMessage()`; only background scripts or extension pages can. Safari also ignores the `application.id` argument and routes native messages to the containing app’s native app extension. See: https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension

```text
Untrusted page
  │ (DOM read/act)
  ▼
Content script (isolated world)
  │ browser.runtime.sendMessage()
  ▼
Background/service worker + toolbar sidecar UI
  │ browser.runtime.sendNativeMessage()
  ▼
Native app extension (native messaging handler)
  │ IPC (typed; App Group queue or XPC)
  ▼
Agent Core (Swift: Policy Gate + Orchestrator + SQLite + Models)
  │
  ├─ XPC: LLM Worker (on-device inference; GPU/Metal allowed; no network)
  └─ XPC: Artifact/File Worker (user-selected files; parsing; encryption)
```

**App → extension push (macOS, optional)**: for immediate UI updates, the extension can open a native port with `browser.runtime.connectNative()`, and the containing app can push messages via `SFSafariApplication.dispatchMessage(withName:toExtensionWithIdentifier:userInfo:)` (see: https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension). Treat pushes as best-effort; the extension should still be able to pull state via `sendNativeMessage()` after suspension/wake.

### IPC for GPU compute + file system access (viability notes)

Safari WebExtensions cannot access the GPU or the file system directly in a way that is suitable for local models and durable storage. Laika’s design keeps privileged operations in sandboxed Swift processes and uses Apple-supported IPC:

- **Compute placement (non-negotiable)**:
  - DOM reads/writes run in **content scripts** (`observe_dom`, handle resolution, click/type execution).
  - Planning, policy, and all model inference run in the **Agent Core** and/or an **LLM Worker** XPC service.
  - The extension must never depend on WebGPU/GPU availability for correctness; GPU acceleration is an internal optimization inside Swift processes (Core ML / MLX / Metal).
- **JS → native bridge (supported)**: the extension uses `browser.runtime.sendNativeMessage()` to reach the containing app’s native app extension handler. This is the intended, App Store-safe path for WebExtension ↔ native communication on Safari.
- **Native bridge → Agent Core (IPC)**: forward requests to the Agent Core over typed IPC. Use an App Group-backed request/response queue as the reliability baseline; add XPC for lower latency where it proves stable in prototypes.
- **Native bridge must stay thin**: validate schemas, enforce backpressure, and forward. Avoid long-running inference or file parsing inside the bridge process to reduce the risk of Safari killing the extension host.
- **GPU-backed local inference lives in the app (or an XPC worker)**:
  - The Agent Core (single source of truth) calls an `LLM Worker` XPC service for inference. That worker may use Core ML / MLX / Metal for GPU acceleration and ships with **no network** entitlement.
  - This keeps model execution out of the JS environment and makes compute scheduling/budgets enforceable in one place.
- **File system access lives in the app (or an XPC worker)**:
  - The extension never receives raw file paths or security-scoped bookmarks.
  - User file reads/writes (PDF parsing, exports) go through an `Artifact/File Worker` that holds security-scoped access and writes encrypted artifacts into the app container/App Group.
  - The extension UI only references artifacts by opaque IDs and renders app-streamed, redacted previews.
- **Where the Agent Core runs**: MVP can run it inside the Laika app process (kept running while tasks execute). A hardened deployment can move the Agent Core into a dedicated helper process so the UI can quit without breaking runs; in both cases, the bridge talks to the Agent Core over typed IPC and never exposes GPU/FS access to JS.
- **IPC budgets (hard limits)**:
  - Treat native messaging as “small typed JSON”, not a bulk transport. Enforce strict size caps per message and per tool result.
  - `observe_dom` must be aggressively budgeted (cap candidate elements, truncate text, omit raw HTML, omit form values).
  - Screenshots (if enabled) must be downsampled/compressed in JS before any transfer; large blobs should be chunked with `{requestId, chunkIndex, totalChunks, sha256}` and reassembled/verified in Swift.
  - Prefer “store in Swift, reference by ID” over sending large payloads repeatedly; the extension should reference `artifactId`s and render app-streamed redacted previews.
- **Cancellation/backpressure across IPC**:
  - Cancellation is end-to-end: `tool.cancel(requestId)` must propagate Agent Core → native bridge → background → content script; each hop should stop work and return `CANCELLED` if possible.
  - If MV3 suspension prevents delivery, Agent Core treats the disconnect as `UNAVAILABLE`, revokes capability tokens, and pauses the run (no retries of side effects). On reconnect, JS must treat unknown `requestId`s as “do not execute” unless re-issued by the Agent Core.

### Lifecycle & Performance Notes

- Assume the background/service worker is **ephemeral**. Keep it thin, event-driven, and safe to restart.
- Persist run state in SQLite so long-running automations can pause/resume; rehydrate state by replaying events from the run log.
- Keep content scripts stateless; on resume, re-observe and reacquire handles rather than trusting stale references.

### App lifecycle semantics (App Store-friendly)

Long-running automation is only “durable” if lifecycle behavior is explicit. Laika should make it clear what continues and what pauses.

- **Agent Core must be running**: all planning, policy, logging, and (optionally) local inference live in the Agent Core. If it is not running, the extension enters `app-offline` and stays in read-only UI with a one-click `Open Laika`.
- **“My Browser” runs require Safari + an attached tab**:
  - If Safari quits, the task tab closes, or the tab can’t be reattached, the run transitions to `paused` (never “continue headless”).
  - On resume, require a fresh `observe_dom` and explicit re-authorization for `My Browser` (capability tokens are not persisted across restarts).
- **Mac sleep / screen lock / user logout**:
  - Treat sleep/lock/logout as a pause boundary for mutating actions. On wake/unlock/login, reattach and re-observe before acting.
  - Never queue up side effects “to run later” while the machine is asleep; timeouts should fail safe and require user confirmation to continue.
- **Always-on vs only-while-open (user choice)**:
  - Default: runs execute only while Laika is open (simple, App Store-friendly).
  - Optional: “Always available” mode as a user-enabled login item/menubar app so the Agent Core stays available for remote monitoring/start. This must be explicit opt-in with clear battery/privacy implications and a one-click Panic/disable.

### Permissions Strategy (Safari-first)

- Prefer minimal `host_permissions`; avoid `all_urls` unless there is a clear user benefit and a strong safety story.
- Use `activeTab` for just-in-time access and `optional_permissions` for escalation (e.g., enabling `Assist`/`Autopilot` on a site).
- Mirror Safari’s permission UX: show “permission needed” state in the toolbar sidecar and route the user to Safari’s per-site grant UI.
- Treat `activeTab` access as **ephemeral**: permissions can lapse across navigation, suspension, or time. Tool calls should fail with `PERMISSION_REQUIRED` and the UI should offer a one-click “re-grant” path.

### Permission UX flows (Safari-specific; exact paths)

Safari permission UX differs from Chrome/Firefox and can be hard to deep-link. Laika should ship explicit flows with graceful fallbacks.

**First-run: read-only on current site (default)**

1. User opens the toolbar sidecar → sees `Observe/Summarize`.
2. If the site is not yet granted, show `permission-needed` with a single CTA: `Enable on this website`.
3. If Safari shows a prompt/menu, the user grants per-site access (typically with choices like single-use / “for the day” / all websites); otherwise show step-by-step instructions: `Safari → Settings… → Extensions → Laika → Allow on <site>` (keep copy short; provide a `Copy instructions` link).
4. Once granted, run `observe_dom` and answer in Read-only mode.

**Enable Connector: “Connect to this site”**

1. User asks for an action → Laika proposes enabling control and shows the authorization summary (origins, allowed actions, logging, what gets sent).
2. CTA: `Connect to this site` (requests the needed site permission / optional host permission if applicable; Safari may offer “allow once/for the day/always” choices).
3. CTA: `Authorize once` (mints capability tokens scoped to `{origin, tabId, mode, allowedTools, ttl}`).
4. Laika opens/attaches to the task tab/window and starts Assist/Autopilot under Policy Gate.

**Re-grant after `activeTab` lapses**

1. A tool call returns `PERMISSION_REQUIRED`.
2. Popover switches to `permission-needed` with a single CTA: `Restore access`.
3. On click, request access again (or route to Safari settings if the prompt can’t be shown); once restored, re-`observe_dom` and continue (never re-execute the previous mutating tool call blindly).

**When Safari won’t deep-link to the right settings page**

- The sidecar should fall back to clear, short copy (“Open Safari Settings → Extensions → Laika”) and keep the user in a usable Read-only mode.
- Provide a safe alternative path: `Open in Workspace` (Isolated surface) or `Tell me what to do manually`.

**Permission failure ladder (users never feel stuck)**

```text
Blocked by Safari / missing permission / restricted page
  → Stay Read-only (Observe/Summarize)
  → Offer “Open in Workspace” (Isolated surface)
  → Offer step-by-step manual guidance (with safe citations)
```

### Profiles and Multi-window Behavior

- Include a `profileId` (or equivalent partition identifier) in run context and scope all persisted data and capability tokens by it.
- Treat `profileId` as a hard boundary: per-site defaults, sensitive-site labels, and run history must not leak across profiles.
- If multiple tabs/windows match the same origin, require the user to select which tab the run is attached to and display the attachment target in the UI.
- If the active Safari profile changes, treat it as a detach event: revoke tokens, pause the run, and require explicit reattach.
- Safari web apps (macOS 15+): treat each web app context as its own `profileId`/partition for policy + persistence. If automation is not supported in a given web app container, show a clear degraded state.

### Private Browsing (Private Windows)

Private browsing should behave like a hard “no persistence” boundary:

- Default stance: disable `My Browser` automation in Private windows unless the user explicitly opts in.
- If enabled, enforce **zero persistence**:
  - No SQLite/App Group writes (no run log, no checkpoints, no artifacts).
  - No cross-run memory; no exports unless the user explicitly saves a redacted summary to a non-private run.
  - Prefer local-only models; if a cloud model is enabled globally, require a separate opt-in for Private windows.
- UX: Private detection may be unreliable; default to conservative behavior when unsure (Connector off; read-only). When Private is detected (or explicitly enabled), show a “Private window” banner that states: “No logs, no saved artifacts, no cloud calls unless you opt in for Private.”

### Restricted Pages and Special URL Schemes

Some Safari surfaces are non-scriptable or intentionally blocked (e.g., `safari://` pages, Safari settings/new-tab, extension pages). When the active tab is not automatable:

- Lock the site mode to `Observe` (or disable entirely) and show `cannot automate this page`.
- Provide a safe alternative: “Open in Isolated surface”, “Copy URL”, or “Tell me what to do manually”.
- Log a stable reason code (e.g., `E_RESTRICTED_PAGE`) so failures are diagnosable.

### Manifest Hardening (Web-to-extension boundaries)

- Keep `externally_connectable` **disabled by default** to avoid webpage-to-extension messaging.
- If an exception is required, scope it to specific extension IDs and require an authenticated handshake at the tool protocol layer.
- Treat all inbound messages as untrusted and validate schemas; never accept tool requests originating from the page.

### Connector UX (authorization + monitoring)

- Use dedicated task tab(s) for “My Browser” runs so the user can monitor and intervene.
- Make “Stop” immediate (revoke capability tokens; cancel outstanding tool work). Also provide a global **Panic** control that revokes tokens, cancels runs, and temporarily locks “My Browser” until re-authorized.
- Treat user interaction with the tab as takeover; pause automation until explicitly resumed.
- Show approvals/denials in trusted UI (sidecar/companion) with a clear Laika visual signature and the verified target `origin`; use the in-page overlay for previews/highlights, not as an authority source.

### User-facing language (make it feel native)

Users should not have to learn internal architecture terms (“surfaces”, “tokens”, “AgentFlow”). The UI labels should carry the meaning:

- `Isolated` surface (internal) → **Workspace** (app-owned; safe default; separate from Safari sessions)
- `My Browser` Connector (internal) → **Connect to this site** (toggle) + **Authorize** (one-time)
- `Observe` mode → **Read-only**
- `Assist` mode → **Ask before acting**
- `Autopilot` mode → **Auto (safe actions only)**

Default sidecar path (one primary interaction):

1. User opens the sidecar panel and asks a question → Laika runs **Read-only** `Observe/Summarize`.
2. If the user asks Laika to *do* something, Laika prompts: **Connect to this site** (explains the Connector + shows the authorization summary).
3. User taps **Authorize** → Laika opens/attaches to the task tab/window, previews actions, and requests approvals as needed.

### Toolbar Sidecar Layout (default entry points)

The toolbar sidecar panel is the default entry point. It should be usable in 1 click:

- **Top row**: current site + mode (`Observe`/`Assist`/`Autopilot`) and a clear permission indicator.
- **Primary actions**: `Observe/Summarize` (always available) + optional context actions (e.g., `Extract table`, `Find on page`).
- **Run card**: current run state (from the state machine), next action preview when relevant, and `Stop` / `Resume automation`.
- **Deep work**: a prominent `Open full panel` that brings up the macOS companion window for planning, logs, and settings.

Additional entry points (to reduce friction, not to add power):

- **Context menu**: “Ask Laika about selection” / “Extract table” on highlighted regions (read-only by default).
- **Keyboard shortcut**: open the companion window / toggle overlay; supports keyboard-first workflows.

### Trusted UI Rendering Rules (sidecar + companion)

Treat anything derived from a webpage as untrusted content and render it accordingly:

- **Text-only rendering**: page excerpts, titles, and extracted strings must be rendered as text (escape everything; never `innerHTML`).
- **No untrusted labels**: never use page text as a button label, menu item, or approval CTA. CTAs must be app-defined strings.
- **Safe citations/anchors**:
  - Display the verified `origin` next to citations so users can see where content came from.
  - Treat URLs as untrusted: prefer `Copy link` over auto-open on sensitive sites; when opening is allowed, require an explicit user click and show the destination origin.
  - Avoid “privileged opens” (e.g., opening `file://` or `safari://`) from untrusted citations; degrade to copy-only with a reason code.

### Toolbar Item States (badge + update rules)

The toolbar item should communicate state even when the sidecar panel is closed:

- `idle`: no badge; click opens the sidecar.
- `permission-needed`: badge `!`; sidecar shows what’s missing and routes to Safari per-site grants.
- `app-offline`: badge `×`; sidecar shows `Open Laika` and explains that automation requires Laika (Agent Core) to be running.
- `running`: badge indicates active run (e.g., `RUN` or step count) and the current mode.
- `paused` / `awaiting_approval`: badge indicates a wait (e.g., `…`); sidecar offers the pending approval/gesture action.
- `takeover`: badge indicates manual control (e.g., `||`); sidecar offers `Resume automation`.

Update rules:

- Badge is derived from the run state in the Agent Core (single source of truth).
- Permission-needed state overrides mode/running badges.

### First-run Onboarding (in Safari)

On first open of the sidecar (and whenever Laika is disabled), show a 1–2 step onboarding:

1. Explain modes (`Observe` is safe default; `Assist` requires approvals; `Autopilot` is constrained). Emphasize that `My Browser` is **explicit opt-in** via a Connector toggle: turn it on → authorize once → watch in a dedicated task tab/window you can close to stop instantly.
2. Explain Safari per-site permissions and provide a single CTA to enable for the current site (or remain in `Observe`).

### UI State Sync (single source of truth)

The toolbar sidecar, in-page overlay, and companion window must render the same run state.

- **Source of truth**: the Agent Core (derived from the SQLite run/event log).
- **Ownership**: the Agent Core owns the run queue; the companion window is the primary UI; the sidecar is a remote control; the overlay is display + lightweight confirmation UI.
- **Conflict resolution**: the Agent Core serializes commands; takeover and stop are highest priority and preempt pending actions.

### Agent Core ⇄ extension state streaming (redacted + cache-safe)

The extension must be able to render the full UX (sidecar/overlay badges, run card, pending approvals) without reading SQLite/App Group files directly.

**Agent Core → extension: minimal run-state payload (redacted)**

- Transport: pushed on changes (preferred) and/or pulled via `run.sync(lastSeenEventId)`.
- Size budget: keep each payload small (e.g., ≤ 32–64 KB) so the sidecar opens instantly.
- Must include (illustrative fields):
  - `appState`: `online|offline|locked`
  - `site`: `{origin, mode, connectorEnabled, permissionState}`
  - `run`: `{runId, status, attachedTarget?, lastActionSummary?, nextStepPreview?, pendingApproval?, lastReasonCode?}`
  - `controls`: `{canStop, canResume, needsGesture?, openLaikaAvailable}`
  - `policy`: `{decision?, reasonCode?, requiresGesture?}` for the *next* action only (not the full log)
- Must never include:
  - cookies/session tokens, request headers, or raw network data
  - `capabilityToken`s, encryption keys, or Keychain material
  - raw DOM/HTML, full-page text dumps, screenshots, or typed form values (unless the user explicitly enables a specific “share visual context” feature and the payload is still redacted/budgeted)

**Extension caching rules**

- Default: memory-only cache, cleared when the service worker/popup is torn down.
- Optional: `storage.session` may store only non-sensitive routing pointers (e.g., `runId`, `lastSeenEventId`, `uiPrefs`), never redacted content or approvals.
- Never use `storage.sync` for run state; avoid `storage.local` for anything tied to browsing/session data.
- Private windows: hard no-persist (memory-only; no App Group writes; no `storage.session`).

### Run Concurrency (tabs + runs)

- **One active “mutating” run per tab**: serialize click/type/submit/navigation per `(profileId, tabId)`; other runs targeting the same tab must queue, attach, or require user choice.
- **Read-only can be concurrent**: allow observe/extract to run in parallel across tabs (still scoped by origin and budgets).
- **Conflicts are explicit**: if two runs want the same tab, show a UI choice: “Switch run to this tab”, “Open a new task tab”, or “Stop the other run”.
- **Locks are durable**: store tab-lock ownership in the run log so resumes don’t accidentally interleave actions after restarts.

### Extension Structure

Laika uses JavaScript where it must (DOM interaction) and Swift where it helps (policy, models, storage):

- **JavaScript (extension) responsibilities**
  - Extract page content in a *structured* form (DOM snapshot, tables, anchors, semantic sections).
  - Perform tool actions (click/type/scroll) using resilient element targeting (handles + fingerprints) and element verification.
  - Render lightweight in-page UI (highlights, “about to click” preview, user selection capture).
- **Swift (app) responsibilities**
  - Execute the agent loop, run local inference, and maintain user/task state.
  - Evaluate security policy and user preferences before allowing any tool execution.
  - Store memory/notes safely (Keychain for secrets; SQLite-backed context/audit logs; encrypted store for task artifacts).

### Concrete Safari Integration Points

Laika can be implemented in two common Safari-supported shapes; the recommended default is the first:

- **Safari Web Extension + Swift host app (recommended)**:
  - JavaScript uses standard WebExtension APIs (`browser.*`) for content scripts, background scripts, tab state, and storage.
  - Swift host app handles native functionality (models, storage, policy) via Safari’s native messaging bridge (the native app extension handler generated by the Safari Extension App template).
- **Safari App Extension (macOS-only)**:
  - Swift extension code can communicate with injected scripts using Safari App Extension messaging APIs (e.g., page-level message passing).
  - Useful when you want a tighter coupling to Safari’s native extension model, at the cost of portability.

In both cases, Laika assumes:

- Content scripts run in an isolated world and should never execute model-provided code.
- Cross-origin iframes and sandboxed frames may require special handling (or be non-automatable by design).

### Messaging and Typed Tool API

All JS⇄Swift communication uses a **strictly typed, versioned tool protocol**, with schema validation on both sides and no “eval-like” surfaces.

**Envelope requirements**

- `protocolVersion`: semver; Swift rejects unknown major versions.
- `requestId`: UUID for correlation and audit (and for cancellation).
- `requestNonce` (optional): additional replay protection if needed; Swift may require it for high-risk actions.
- `capabilityToken`: signed, scoped token (per tab/session + site mode + allowed tools).
- `context`: includes `profileId` (if available), `tabId`, `frameId`, `origin`, plus `documentId` and `navigationGeneration` for replay safety on SPAs.
- `deadlineMs`: tool execution deadline enforced by Swift and JS.
- `idempotencyKey` (recommended): prevents accidental double-submit on retries for side-effecting tools.
- Cancellation: Swift can send `tool.cancel(requestId)`; JS should abort work and return `CANCELLED` if possible.
- Retries: only retry if `error.retryable` and the tool is idempotent (or carries an `idempotencyKey`).

**Schema source of truth + codegen**

- Define tool request/response schemas as **JSON Schema in-repo** (one directory per `protocolVersion`); treat schema diffs as API changes.
- Generate Swift `Codable` types + TypeScript types from the same schemas; validate at runtime on both sides (reject unknown fields by default).
- Pin model prompts to a `toolSchemaHash` so the model and router agree on the exact tool surface.

**Tool capabilities handshake (version compatibility)**

- On extension startup, JS sends `system.hello` (protocol version, schema hash, supported tools/features).
- Swift replies with `system.welcome` (accepted version, allowed tools for the current site/mode, payload limits, feature flags).
- If incompatible, Swift returns `UNSUPPORTED` and the UI shows a concrete next step (e.g., “Update Laika”).

**Connection lifecycle + resync**

- Use a long-lived `runtime.connect` port (sidecar/overlay ↔ background) and a single native-messaging channel (background ↔ native bridge).
- On reconnect (service worker suspension, UI reopen), send `run.sync(lastSeenEventId)`; Swift replies with missing events + current authoritative run state.
- If the native side (Laika app/agent core) is not reachable, enter `app-offline`: disable automation, keep read-only UI copy, and offer a one-click “Open Laika”.
- **“Open Laika” mechanics (App Store-safe)**: on user click, attempt a deterministic bring-to-front flow:
  - Preferred: open an app-registered URL scheme (e.g., `laika://open?source=safari`) or Universal Link that the app handles, so the OS launches/activates Laika.
  - Fallback: show clear instructions (“Open Laika.app to continue”) and keep the extension in read-only mode.
- **App locked / Panic**: after a Panic or explicit lock, the app refuses to mint new `capabilityToken`s for `My Browser` until the user re-authorizes in the app. The extension should render a clear “locked” state and route the user to unlock.

**Message sequencing + backpressure**

- Serialize **mutating** tool calls per `(tabId, frameId)` (click/type/submit/navigation) to avoid racing the page.
- Enforce a bounded queue in the background/app; if the queue is full, return `RATE_LIMITED` and re-plan after a fresh `observe_dom`.
- Treat disconnects (service worker suspension, tab close, content script unloaded) as first-class failures: cancel in-flight work and return `CANCELLED`/`UNAVAILABLE`.
- Dedupe delivery with `requestId`: if a request is re-delivered, return the cached result (or `CANCELLED`) rather than re-executing a side effect.
- Prefer a two-phase flow for mutating calls: `accepted` quickly, then `result` (or a single response if the action is fast), so the UI can show progress and backpressure cleanly.
- If needed, add `sequence` (monotonic) and `channelId` (run-scoped) fields so both sides can detect reordering and drop stale messages.

Example request:

```json
{
  "protocolVersion": "1.0",
  "requestId": "0a2e5f8a-6f57-4fe0-9cbb-1a6f1fa1b5a2",
  "toolName": "browser.click",
  "arguments": { "handle": "h_..." },
  "context": { "tabId": 3, "frameId": 0, "origin": "https://example.com" },
  "capabilityToken": "ct_...",
  "deadlineMs": 5000,
  "idempotencyKey": "9d6e3a6b-38b0-4dc1-a71c-9d51a1e7e8b6"
}
```

Example response:

```json
{
  "protocolVersion": "1.0",
  "requestId": "0a2e5f8a-6f57-4fe0-9cbb-1a6f1fa1b5a2",
  "ok": true,
  "result": { "clicked": true },
  "timing": { "startedAtMs": 1730000000000, "durationMs": 120 },
  "provenance": { "url": "https://example.com/page", "origin": "https://example.com" }
}
```

**Error taxonomy (illustrative)**

- `INVALID_ARGUMENT`, `SCHEMA_MISMATCH`, `PERMISSION_REQUIRED`, `POLICY_DENIED`, `PRECONDITION_FAILED`, `VERIFICATION_FAILED`, `NOT_FOUND`, `STALE_HANDLE`
- `TIMEOUT`, `CANCELLED`, `UNAVAILABLE`, `UNSUPPORTED`, `RATE_LIMITED`, `INTERNAL`

Errors should carry `{code, message, retryable}` and be safe to show in the UI/audit log (with redaction).

### Browser Tools (examples)

Core browser tools exposed to the model (via the Swift Tool Router):

- `browser.observe_dom(tab, scope)` → structured DOM snapshot + visible text + key element handles
- `browser.find(target)` → locate clickable/input elements by intent; returns candidate handles + confidence
- `browser.click(handle)` / `browser.type(handle, text)` / `browser.select(handle, option)`
- `browser.scroll(direction, amount)` / `browser.wait_for(condition, timeout)`
- `browser.extract_table(handle)` → structured rows/columns with header normalization
- `browser.capture_viewport()` → screenshot + element map (for multimodal grounding)
- `browser.open_url(url)` / `browser.new_tab(url)` / `browser.switch_tab(id)`

### MVP tool surface (min viable set)

Make the MVP tool surface explicit so the model contract (and the safety envelope) is unambiguous.

**MVP 0 (Observe-only)**

- `browser.observe_dom` (scoped; redact-by-default)
- `browser.extract_table` (handle-only; structured output)
- Optional (gated): `browser.open_url` / `browser.new_tab` on the Isolated surface

**MVP 1 (Assist)**

- `browser.find` (returns handles; never executes selectors from the model)
- `browser.click`, `browser.type`, `browser.select` (handle-only; preview + approval by default)
- `browser.scroll`, `browser.wait_for` (bounded; used for verification loops)
- Optional (gated): `browser.switch_tab`

**Intentionally excluded (MVP)**

- Arbitrary selector execution (no `querySelector`, XPath, or “run JS” tools).
- Full-page raw dumps (no raw HTML; no “export the entire DOM/text” tool).
- Programmatic file uploads or file picker control (user gesture required).
- Programmatic downloads/clipboard writes without explicit user gesture and approval.
- Cross-origin iframe traversal beyond what Safari permits.
- Any direct “payments/transfers/identity changes” tool; those remain `deny` by default and require explicit product policy work first.

#### Abbreviated example schemas (contract sketch)

These are intentionally short; the full source of truth should be JSON Schema in-repo and codegenned.

`browser.observe_dom` (arguments only; tab/origin binding comes from the envelope `context`):

```json
{
  "type": "object",
  "required": ["scope"],
  "properties": {
    "scope": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": { "enum": ["viewport", "document", "container"] },
        "containerHandle": { "type": "string" }
      }
    },
    "settleMs": { "type": "integer", "minimum": 0, "maximum": 2000 }
  }
}
```

`browser.find`:

```json
{
  "type": "object",
  "required": ["query"],
  "properties": {
    "query": { "type": "string", "minLength": 1 },
    "withinHandle": { "type": "string" },
    "k": { "type": "integer", "minimum": 1, "maximum": 20 }
  }
}
```

`browser.click`:

```json
{
  "type": "object",
  "required": ["handle"],
  "properties": {
    "handle": { "type": "string" },
    "clickKind": { "enum": ["single", "double"] },
    "expectNavigation": { "type": "boolean" }
  }
}
```

`browser.type`:

```json
{
  "type": "object",
  "required": ["handle", "text"],
  "properties": {
    "handle": { "type": "string" },
    "text": { "type": "string" },
    "clearFirst": { "type": "boolean" }
  }
}
```

**Observation contract: `browser.observe_dom` (security-critical)**

`observe_dom` defines what untrusted page content enters the agent loop. Default output should be structured and redact-by-default:

- Returns `{url, title, origin, documentId, navigationGeneration, observedAtMs}` plus:
  - `visibleText`: visible text snippets only (no raw HTML), truncated and chunked with citations/anchors.
  - `elements`: interactive candidates with `{handle, role, accessibleName, boundingBox}` plus an allowlist of safe attributes.
  - `forms`: field metadata only (`type`, `label`, `required`, `autocomplete`), never current values.
  - `redactions`: what was removed (e.g., `inputValues`, `passwordFields`, `hiddenNodes`) and why.
- Supports `scope` (viewport vs container handle) and a short `settleMs` wait for DOM stability to avoid capturing transient loading states.

**Redaction rules (default)**

- Never capture `input.value`, `textarea.value`, `contenteditable` text, or password fields.
- Treat `aria-label` / accessible names as untrusted text; include them only for identification alongside role + structure.
- Exclude hidden/inert nodes (`display:none`, `visibility:hidden`, `aria-hidden`, zero-size) unless explicitly requested for accessibility debugging.
- On sensitive sites, prefer derived aggregates (tables/sums) over raw text; optionally disable screenshots.

**Performance notes (Safari/battery-friendly)**

`observe_dom` must be cheap enough to run repeatedly on real pages:

- **Cap candidates**: select only the top N interactive elements (e.g., 100–300) prioritized by visibility, clickability, and proximity to the viewport; avoid “everything in the DOM”.
- **Avoid layout thrash**: minimize `getBoundingClientRect()` calls; compute bounding boxes only for shortlisted candidates and batch reads in a single frame when possible.
- **Incremental by default**: prefer `scope=viewport` (or a known container) for re-observations; widen to `scope=document` only when needed (e.g., repeated `NOT_FOUND`, pagination, or an explicit user request).
- **Huge DOMs / virtualized lists**: treat results as partial; rely on `find` + scroll + re-observe loops rather than trying to snapshot the whole list at once.

**Iframe policy (explicit)**

- Same-origin iframes: extract normally (within budgets) and attribute citations to the frame origin.
- Cross-origin iframes: include a placeholder entry with `{frameOrigin?, blocked: true, reasonCode}` and never attempt extraction/actions inside the frame unless a dedicated, explicitly allowed frame script exists. The planner must treat blocked frames as “manual step required” surfaces.

**Non-DOM surfaces (PDF/canvas/iframes)**

- **PDF viewers**: prefer explicit download → parse locally in the app; store artifacts encrypted with retention controls.
- **Canvas-heavy apps**: require explicit visual mode consent (screenshots) and/or fall back to “assist with guidance”.
- **Cross-origin iframes**: treat as non-automatable unless a frame script is explicitly allowed; surface a clear “manual step required” UI.

Implementation detail: JS never executes selectors provided by the model without validation. Instead it:

- Resolves *element handles* created by trusted extraction,
- Re-checks visibility/role (button/link/input) at execution time,
- Enforces same-origin + frame constraints unless explicitly permitted.

### Element Handles (format + lifecycle)

Element handles are intentionally opaque; they exist so the model can refer to UI targets without injecting selectors.

- **Minting**: handles are created only by trusted extraction (`observe_dom`, `find`) inside a content script.
- **Scope**: a handle is valid only for a specific `(profileId, tabId, frameId, origin, documentId, navigationGeneration)`.
- **Mapping**: content scripts maintain an in-memory map `handle → element` plus a minimal fingerprint for re-resolution (role/type, accessible name, text snippet, bounding box).
- **Validation at use-time**: `click/type/select` re-check that the resolved element still matches the expected fingerprint and is visible/interactive.
- **Invalidation**: on navigation/refresh or when the element can’t be re-resolved, return `STALE_HANDLE` and force `observe_dom`/`find` again.
- **Replay/spoofing resistance**: handles are unguessable (random) and useless without a valid `capabilityToken` and matching scope.

**Document identity + navigation generation (SPA-safe)**

Safari tabs can change content without a full reload (SPAs). To avoid replaying actions against the “same URL but different page”, content scripts track document identity and expose it everywhere:

- `documentId`: random ID minted once per document load (changes on full reload).
- `navigationGeneration`: monotonic counter incremented on significant in-document navigation (e.g., `pushState/replaceState`, `popstate/hashchange`) and major DOM replacements (MutationObserver heuristics).
- Every `observe_dom` result, tool request `context`, element handle, and capability token includes `(documentId, navigationGeneration)`.
- When either changes, **rotate capability tokens** and treat existing handles as stale; require a fresh `observe_dom` before any mutating action.

**Handle staleness thresholds + re-resolution heuristics**

- Treat handles as **short-lived** on dynamic pages (virtualized lists, infinite scroll): re-observe before any high-risk action, and always re-validate after scrolling.
- Consider a handle stale if:
  - `(documentId, navigationGeneration)` changes,
  - the element fails fingerprint checks (role/name/type/visibility),
  - the element moved frames/origin, or
  - the element can’t be scrolled into view without changing page state unexpectedly.
- Re-resolution strategy (in order):
  1. Re-`observe_dom` in a tight scope (viewport/container) and re-select by role + accessible name + nearby context.
  2. Re-run `find(target)` with stricter intent (include expected form/section).
  3. Ask the user to confirm the candidate via highlight preview when multiple matches remain.

### “Why this element” Explanations (trusted rationale)

When Laika explains a proposed click/type target, it should ground the explanation in trusted extraction and UI semantics, not arbitrary page text:

- Prefer structured attributes (role/type, accessible name/label, form association, position/context) and the user’s goal.
- Avoid quoting untrusted page text verbatim when it looks instruction-like (“click here to… ignore…”); show citations/anchors instead.
- Never let page content alter policy decisions or tool preconditions.

## Leveraging macOS Sandbox, Entitlements, and Isolation

### Sandboxing Strategy

Laika’s default configuration minimizes escape hatches:

- **No network for the LLM worker** (local inference only).
- **GPU-backed local inference**: the LLM worker may use Core ML / MLX / Metal; no network entitlement is required for GPU acceleration.
- If cloud models are enabled, run them in a separate “Cloud Model” worker with the minimum network entitlements, and require redaction/egress filtering before any request leaves the device.
- **No arbitrary file system access**: only app container + user-selected files via security-scoped bookmarks.
- **Keychain isolation**: secrets are stored only in Keychain items scoped to the app.
- **Separated processes**:
  - UI/app process (handles user interaction)
  - LLM worker (runs inference; no network; GPU/Metal allowed)
  - Artifact/File worker (parsing, exports, encryption; security-scoped file access)
  - Optional Cloud Model worker (network; BYO key; redaction + audit)
  - Optional “Indexer” worker (SQLite maintenance + compaction; optional embeddings; no network)

### Network entitlements (make them explicit)

Safari itself loads websites; Laika’s native processes should request network access only when a feature truly needs it, and keep “no-network” boundaries meaningful:

- **Must be no-network**:
  - LLM worker (local inference)
  - Policy Gate (decisioning)
  - Indexer/compaction worker (SQLite maintenance)
- **May require network (feature-gated)**:
  - Isolated surface (WKWebView) if Laika is acting as a browser in-app
  - Optional Cloud Model worker (BYO OpenAI/Anthropic)
  - Model updates/downloadable models (if supported)
  - Remote start/monitor relay (if supported)

Recommended placement:

- Put networked features into their own process boundaries (e.g., Cloud Model worker; optional Isolated surface worker) so the Agent Core + LLM worker can remain no-network.
- If MVP runs Agent Core inside the UI app process, treat “no network” as a **policy** constraint (defense-in-depth) until the Agent Core is moved into a no-network helper process.

### Capability-Based Permissions

Laika treats sensitive actions as *capabilities* that require explicit enablement:

- Per-site modes: `Observe`, `Assist`, `Autopilot`
- Sensitive categories: `Banking`, `Healthcare`, `Identity`, `Payments`
- Action gates: `Paste`, `Upload`, `Submit form`, `Download`, `Navigate cross-site`

Policy is enforced in Swift, and mirrored in JS with defense-in-depth checks.

**Capability tokens (recommended shape)**

- Minted by Swift per tab/session and bound to `(profileId, tabId, origin, documentId, navigationGeneration, siteMode, allowedTools, expiresAt)`.
- Rotated on document changes, mode changes, and on a short TTL; not persisted across restarts by default.
- Stored only in extension memory; never exposed to the page; avoid sync storage.
- Revoked immediately on tab close, user “panic”/lock, or per-site mode downgrade; Swift refuses revoked/expired tokens.

**Token signing + replay controls (concrete choice)**

- **Signing scheme**: HMAC-SHA256 with a Keychain-held secret key (app-owned). Encode as `base64url(payload).base64url(signature)` (JWT-like, but keep it minimal and canonical).
- **Canonical payload**: sign a canonical JSON (stable key ordering) or CBOR payload containing:
  - binding fields `(profileId, tabId, origin, documentId, navigationGeneration)`,
  - policy scope `(siteMode, allowedTools)`,
  - `issuedAtMs`, `expiresAtMs`, and a `keyId` for rotation.
- **Rotation**: rotate on `(documentId, navigationGeneration)` change, per-site mode change, short TTL expiry, and on Panic/lock. Do not persist tokens to disk.
- **Replay controls**:
  - Treat `requestId` as a nonce: reject duplicate `requestId` executions for mutating tools and return the cached result instead.
  - For side-effecting calls, enforce “at most once” by recording `{requestId → resultHash/status}` in the run log.
  - If extra defense is needed, add a `requestNonce` field and require it to be unconsumed within the token’s lifetime.

### Policy Defaults (illustrative matrix)

Policy returns `allow` / `ask` / `deny` for every tool call plus a stable `reasonCode`, and the UI reflects the decision (preview + confirmation for `ask`).

Default stance (illustrative; tune via user settings and site classification):

| Action | Observe | Assist | Autopilot (low-risk site) | Autopilot (sensitive site) |
| --- | --- | --- | --- | --- |
| Read/extract (`observe_dom`, `extract_table`) | allow | allow | allow | allow (redacted) |
| Navigate within same origin | deny | ask | allow | ask |
| Click non-destructive (expand/sort) | deny | ask | allow | ask |
| Type into non-sensitive fields | deny | ask | ask | deny |
| Paste clipboard | deny | ask | ask | deny |
| Submit forms | deny | ask | ask | deny |
| Downloads | deny | ask | ask | deny |
| Uploads | deny | ask | deny | deny |
| Cross-origin navigation | deny | ask | ask | deny |
| Payments/transfers/identity changes | deny | deny | deny | deny |

Site classification inputs (highest precedence first):

- User labels / overrides
- Heuristics (URL patterns, presence of password fields, “payment”/“transfer” affordances)
- Optional curated lists (local, signed, updatable)

### Policy Gate implementation (v1: testable, not magic)

Start with a concrete, reproducible v1:

- **Hard-coded invariants**: a small set of “never allow” rules (e.g., credential exfil, payments/transfers, cross-site carry from sensitive origins) that ship as code and are unit-tested.
- **Data-driven matrix**: a compact allow/ask/deny matrix stored as JSON (versioned in-repo) with user overrides stored in SQLite (`site_policy_override`). This keeps behavior explainable and patchable without inventing a full DSL on day one.
- **Minimal site classification**:
  - User labels (always win) exposed in the sidecar/companion as a simple “This is a sensitive site” toggle.
  - Heuristics: password fields, common auth/payment affordances, and known “bank/health/identity” URL patterns.
  - Optional curated lists: signed, local, updatable (enterprise policy packs later).
- **Deterministic decision function**: every decision is reproducible from `{origin, mode, tool, requiresGesture, context}` → `{allow|ask|deny, reasonCode, requiresGesture}`. This is required for unit tests and for explaining decisions to users.

### Policy Reason Codes (stable + queryable)

Every policy decision should include:

- `decision`: `allow|ask|deny`
- `reasonCode`: stable identifier (for UI copy, analytics, and audit log queries)
- `reason`: user-readable explanation (localized, never derived from page text)
- `requiresGesture`: whether execution must be initiated from a trusted user click

Example `reasonCode`s (illustrative): `P_DENY_SENSITIVE_SITE`, `P_ASK_SUBMIT_FORM`, `P_ASK_PASTE`, `P_DENY_CROSS_ORIGIN`, `P_ALLOW_READONLY`.

### Scoped Approvals (reduce approval fatigue)

Approvals should be explicit, revocable, and scoped so users don’t have to click “Allow” repeatedly:

- Scope by **action type** (e.g., “allow submit on this site”) and **target** (specific form or origin).
- Scope by **time** (e.g., 5 minutes) and/or **navigation boundary** (expires when `(documentId, navigationGeneration)` changes).
- Always show active scopes in the sidecar/companion window with one-click revoke; record grants/revokes as durable events.

### Data Retention, Logging, and Redaction

- **Audit log**: stored as append-only SQLite run events; records tool calls, policy decisions, and user approvals with minimal provenance; default is to redact typed text and sensitive page content.
- **Artifacts** (tables, screenshots): stored only with explicit user approval or non-sensitive mode; encrypted at rest; scoped by `(site origin, task)`.
- **Sensitive-site defaults**: avoid storing raw page text/screenshots; store derived aggregates only.
- **Rollback/branching**: implemented by moving the run head to a prior checkpoint/event (history is preserved unless the user wipes it).
- **User controls**: per-site “forget” (wipe SQLite rows + artifacts), global retention window, export.

#### Typed text logging (`browser.type`) (audit-usable, secret-safe)

By default, Laika should never persist raw typed text. For audit usefulness, log a redacted representation:

- `tool`: `browser.type`
- `target`: `{origin, tabId, documentId, navigationGeneration, handleFingerprint}`
- `field`: `{inputType?, autocomplete?, labelHint?, formHint?}` (untrusted metadata, length-capped)
- `text`: `{redacted: true, length: N, newlineCount?, charClassHint?}` (no plaintext)
- `sensitivity`: `{fieldClass, textClass, combinedClass}` (see classifier below)
- `approval`: `{decision, reasonCode, requiresGesture, approvedByUser: bool}`
- Optional (only when `combinedClass=non_sensitive` and user enables “verbose audits”): a short prefix preview (e.g., first 8 chars) and/or a keyed HMAC for dedupe. Never store previews/hashes for credential-like fields.

### Credentials / PII Handling

- Treat password fields and common PII fields (SSN, DOB, account numbers) as sensitive; never log their values and avoid sending them to the model by default.
- For `browser.type`, require explicit user approval when typing into any credential-like field; prefer user manual entry or system autofill.
- Never store raw credentials; rely on system Keychain/autofill where possible.

#### Sensitive field classifier (pre-type / pre-log / pre-egress)

Before Laika types, logs, or includes user-entered values in any model context pack, run a deterministic classifier on the *field* and a lightweight classifier on the *text*.

- **Field classifier inputs** (handle metadata from trusted extraction):
  - `input.type` (`password`, `email`, `tel`, `number`), `autocomplete` (`current-password`, `one-time-code`, `cc-number`, `cc-csc`, etc.)
  - label/placeholder/name/id patterns (e.g., `password`, `otp`, `ssn`, `routing`, `account`)
  - form context (presence of password fields nearby, login URLs, payment affordances)
- **Text classifier inputs** (local-only):
  - simple heuristics (length, digit patterns, email/phone detection) and/or a small local Guard/Filter model
- **Outputs**:
  - `fieldClass`: `credential|payment|pii|sso|generic`
  - `textClass`: `secret_like|pii_like|normal`
  - `combinedClass` and a stable `reasonCode` used by the Policy Gate (e.g., `P_ASK_CREDENTIAL_FIELD`, `P_DENY_PAYMENT_FIELD_AUTOPILOT`)
- **User overrides**:
  - per-site override: “treat this site as sensitive” / “read-only by default”
  - per-field allowlist: user can approve a specific field fingerprint for this origin/run (durably logged and revocable)

### Entitlements & System Permissions (principles)

Prefer not to request (or only enable with an explicit user toggle):

- Network entitlements for model execution (local inference should not need them)
- Accessibility permission (TCC) unless the user enables out-of-browser automation
- Screen recording permission (TCC) unless the user enables visual grounding beyond the tab
- Microphone permission (TCC) unless voice control is enabled

When enabled, Laika shows:

- Why the permission is needed
- What is captured/sent (local-only by default)
- How to revoke it (Safari extension settings and/or System Settings)

## Prompt Injection Hardening (Core Design)

### Data/Instruction Separation

Laika maintains strict separation between:

- **Trusted inputs**: user prompts, local policies, tool outputs, signed app state
- **Untrusted inputs**: web page text/HTML, OCR, third-party content, emails/docs opened in a tab

Untrusted inputs are wrapped and labeled; the planner model is instructed to treat them as **evidence only**.

### Two-Stage Understanding (recommended default)

To reduce injection risk and context poisoning:

1. **Extractor pass (read-only)**: converts page content → structured facts + citations (no actions).
2. **Planner pass**: plans steps using only extracted facts and tool affordances.

Optionally, a **Policy/Safety model** (small) scores tool calls for risk and blocks/asks approval.

### Injection Detection + Quarantine (defense-in-depth)

Even with careful prompting, real-world computer-use systems can still be misled by instructions embedded in pages or images. Add defense-in-depth:

- **Detect likely injections** in extracted text/visible UI (rule-based patterns + optional small local classifier).
- **Quarantine suspicious content**: store it as untrusted evidence, but require confirmation before any subsequent action step.
- **Autonomy downgrade** on suspicion: switch to `Assist` or `Observe` and explain why.
- **Context rollback**: revert the run head to the last safe checkpoint if the working memory appears poisoned (then re-observe and proceed with a sanitized plan).

### Confused Deputy Mitigation (user intent vs policy)

Users are trusted, but policies still apply. Laika should not become a “confused deputy” that executes unsafe actions just because the user asked:

- User requests are checked against the same Policy Gate (`allow`/`ask`/`deny`) as model-proposed steps.
- User-provided content (pasted instructions, page text, documents rendered in a tab) is treated as **untrusted evidence**, not authority to bypass policy.
- If a user requests a disallowed action (e.g., “paste my password into this form”), Laika should refuse or require explicit, scoped approvals and log the decision.

### Compartmentalized Memory

- Memory is scoped by `(profileId, site origin, tab, task)`.
- Cross-site summarization requires explicit user intent (“use bank data to make a budget report”).
- Sensitive sites store only derived aggregates by default (e.g., totals, categories), not raw transactions.

### Exfiltration Resistance

Mitigations include:

- Default **read-only** on sensitive domains; “act” requires explicit enablement.
- Block tool calls that would:
  - Type secrets into unknown fields
  - Paste clipboard into web forms without confirmation
  - Navigate to a new origin while carrying sensitive context
- Action previews with element highlighting before execution (click/type is visible to the user).

## Models and Decisioning (On-device by default; cloud optional)

### Model Roles (practical split)

- **Browser Agent SLM** (local, small): specialized for robust tool use (DOM reasoning, action selection) and simple automation under tight constraints.
- **Guard/Filter SLM** (local, always-on): input/output classification, redaction, injection/exfiltration detection, and risk scoring for proposed tool calls. Runs even if a cloud planner is enabled.
- **Planner/Writer LLM**: produces plans and higher-quality writing. Local by default; optional cloud via user-provided credentials.
- **Embeddings (optional)**: used internally for similarity tasks (deduping, clustering, ranking candidates); Laika does not implement a general RAG system or a vector database.
- **Vision model (optional)**: interprets screenshots/selected regions to ground actions visually.

### Cloud Models (optional, bring your own key)

If the user connects OpenAI/Anthropic (or other providers), treat cloud calls as an opt-in “assist” feature, not a requirement:

- Send only a **redacted context pack** (never cookies/session tokens; avoid raw page dumps on sensitive sites).
- Run the local Guard/Filter before *and* after (egress filtering) and keep Policy Gate decisions local.
- Offer per-site toggles and a “preview what will be sent” UI for sensitive workflows.

### Runtime Options (Apple Silicon-friendly)

- Core ML models for tight OS integration and sandboxed deployment.
- MLX for early validation: package 4-bit MLX models produced by `src/local_llm_quantizer` and load them in the LLM Worker via `mlx-swift`.
- llama.cpp / MLC as alternative development backends; ship as Core ML when stable.
- Quantization for on-device performance (e.g., 4–8 bit), with per-model quality/perf profiles.

### Model Updates

- Ship models signed with the app; updates via normal app update channels.
- If supporting downloadable models, require signature verification + user opt-in.

## Agent Loop: Planning, Execution, Recovery

### Control Loop

1. Observe (DOM + screenshot if needed)
2. Extract facts (read-only)
3. Plan (tool calls + success criteria)
4. Policy check (site mode + risk rules)
5. Execute one step
6. Verify outcome (DOM checks)
7. Repeat / escalate to user if uncertain

Each step appends to the SQLite run log; runs can pause/resume (approvals, takeovers, app restarts) without losing progress.

### Tool Verification Contract (pre/postconditions)

Every tool should define explicit preconditions/postconditions so verification is deterministic and failures are actionable:

- **Preconditions** (checked before execution): handle scope matches `(profileId, tabId, origin, documentId, navigationGeneration)`, element is visible/enabled, action is permitted by Policy Gate, and the target field is not credential-like unless explicitly approved.
- **Postconditions** (checked after execution): expected page change occurred (e.g., URL or `(documentId, navigationGeneration)` changed, element value changed, a success marker appears, a modal opened), otherwise return `VERIFICATION_FAILED`.
- **When postconditions fail**: re-`observe_dom` in a tight scope, re-plan with fresh facts, and downgrade autonomy if repeated failures occur (never loop blind retries).

### User Takeover Heuristics

- Treat user input (typing, scrolling, pointer interactions) as a takeover signal: emit `ui.takeover`, pause automation, and require explicit resume.
- Provide a clear “Resume automation” control in the toolbar sidecar/companion window; never auto-resume after takeover.
- If the user continues interacting for a while, keep the run in `paused` until a fresh `observe_dom` confirms the page is stable.

### Manual Handoff (login / 2FA / consent)

When the workflow hits a step Laika should not automate (login, 2FA, consent dialogs, CAPTCHA, file picker):

- Enter `paused` or `takeover` with a clear instruction (“Complete 2FA, then click Resume”); record `ui.handoff_required`.
- Do not try to “watch” secret entry; do not store typed values in logs/context.
- On resume, require a fresh `observe_dom` and re-plan from the new page state.

### Failure Handling (re-observe vs re-plan vs escalate)

- `STALE_HANDLE` / `NOT_FOUND`: re-observe and re-plan; don’t keep retrying the same action blindly.
- `TIMEOUT` / `UNAVAILABLE`: cancel the in-flight step, surface a manual next step, and require user confirmation to continue.
- Bound retries per step and per run; when exceeded, downgrade autonomy and ask for human guidance.

### Detach Safety (tokens + in-flight work)

- On tab close, permission revoke, or profile switch: revoke capability tokens and cancel in-flight tool work safely.
- Ensure “Stop” is always available and immediate across UI surfaces.

### Reliability Techniques

- **Element handles**: avoid brittle CSS selectors; use stable attributes + role + text + bounding boxes.
- **Wait conditions**: explicit waits for DOM states; handle spinners/infinite scroll.
- **Fallback strategies**: if handle resolution fails, re-observe and re-plan.
- **Deterministic constraints**: cap retries, timeouts, and maximum actions per autopilot run.
- **Resumable checkpoints**: checkpoint progress to SQLite so long runs resume reliably and side effects are not repeated by accident.

### Budgets & Guardrails (efficiency)

- **Observation budgets**: cap DOM/text size, filter to visible/interactive regions, and prefer incremental re-observation over repeated full scans.
- **Screenshot budgets**: capture only when necessary (visual grounding/verification), downscale, and rate-limit captures during rapid steps.
- **Model call budgets**: cap steps per run, enforce CPU/battery guardrails, limit concurrent model calls, and use early-exit heuristics when stuck.

## Multi-Modal Interaction Design

### UX Surfaces

- **Safari toolbar sidecar**: quick actions, per-site mode indicator, permission-needed state, “open full panel”.
- **Companion window (macOS app)**: chat + plan + action queue + citations + run controls (works alongside Safari).
- **In-page overlay**: opt-in highlights, “click preview”, region selection, inline confirmations; always easy to dismiss.
- **Keyboard-first controls**: command palette + selection-based actions; keep common flows one-click from the toolbar.

### Accessibility + Localization

- Popover/companion/overlay should be VoiceOver-friendly: correct roles/labels, predictable focus order, and keyboard-accessible approvals.
- Run state changes should be announced accessibly (e.g., “Awaiting approval”, “Paused due to takeover”).
- Policy decisions use stable `reasonCode`s, while `reason` strings are localized UI copy (never derived from page text).

### Overlay Isolation (safety + compatibility)

Overlays must not hijack the page or leak data across origins:

- Render UI inside a **Shadow DOM** (or similarly isolated root) and namespace all styles to avoid clobbering the page.
- Default overlay container to `pointer-events: none`; enable pointer events only for explicit overlay controls.
- Maintain a strict z-index policy and keep an always-available **dismiss** affordance (e.g., `Esc` + close button).
- Never read sensitive fields for rendering; never inject model-provided HTML/JS; treat overlay text as trusted UI only.
- Use a consistent **Laika visual signature** (icon + color + typography) and show the target `origin` from trusted state; never let the page “spoof” approvals.
- Never use untrusted page text as button labels; when displaying page text, render it as a quoted *untrusted excerpt* with clear provenance.

### Voice + Visual

- Voice input via macOS Speech framework; local transcription where possible.
- Visual grounding via:
  - `browser.capture_viewport()` screenshots
  - user-drawn selection rectangles
  - element maps (DOM to screen coordinates) to avoid OCR when possible

### End-to-End MVP Flows (UI + policy)

**Assist mode: click/type with preview**

1. User sets site mode to `Assist`.
2. Agent proposes the next action with an element highlight + “why this element” (based on tool observations, not page instructions).
3. Policy Gate returns `ask`; user approves; tool executes; agent verifies outcome; audit log records the decision.

**Sensitive site: read-only with redaction**

1. User opens a banking domain; site classification defaults to `Observe`.
2. Agent can extract balances/transactions into a derived summary, but policy blocks typing/paste/submit/download.
3. User can explicitly override per-site mode; overrides are visible and reversible.

## Use Case Walkthroughs (How Laika Behaves)

### Housing analysis (Zillow)

- Observe listing results; extract price, location, beds/baths, HOA, taxes, listing age.
- Open top N candidates in new tabs; extract key facts + compute a comparison table locally.
- Ask user for preferences (“commute time vs. school rating vs. budget”) and re-rank.
- Autopilot constraints:
  - No sending emails/contacting agents without approval
  - No form submissions by default

### SEC/EDGAR company analysis

- Navigate to company filings; download/open 10-K/10-Q (PDF/HTML).
- Extract tables (revenue, margins, cash flow), summarize risk factors with citations.
- Compare multiple years and produce a structured report.
- Safe mode: read-only; minimal risk.

### Medical research

- Search PubMed/clinical trial registries; extract abstracts and key outcomes.
- Build an evidence table with citations, study type, sample size, and limitations.
- Safety: always include uncertainty; avoid “medical advice”; present sources and let user decide.

### GitHub code browsing & reading

- Use structured extraction: repo tree, file contents, symbol search, issue/PR context.
- Provide grounded answers with file paths/lines when available (or per-page citations in-browser).
- Assist mode: can open files and navigate; no external execution without explicit permission.

### Banking balance analysis

- Default mode: **Observe-only** on known banking domains.
- Extract balances and recent transactions; store only derived aggregates unless user opts in.
- Produce local reports (spend by category, month-over-month).
- Explicit gates:
  - Never initiate transfers
  - Never change personal info
  - Confirm before downloading statements

### Credit card transaction analysis

- Observe-only by default; extract transaction table into a local encrypted SQLite store.
- Categorize with a local model; detect subscriptions, duplicates, and anomalies.
- Optional export to CSV requires explicit confirmation and file destination selection.

## Testing + Validation Plan

### Safari-specific scenarios

- Permission grant/revoke/restore (per-site), including “activeTab” flows and optional permission escalation.
- Background/service worker suspension and recovery; ensure runs resume from SQLite without repeating side effects.
- App not running/unavailable: extension shows `app-offline`, offers “Open Laika”, and resyncs state after launch.
- App locked/panic: extension shows `locked`, refuses `My Browser` token minting until the user re-authorizes/unlocks in the app.
- Tab lifecycle changes: tab IDs changing, windows closing, and reattach flows when tabs can’t be found.
- Cross-origin iframe access failures and “graceful failure” UX.
- Gesture-required actions: `event.isTrusted` + user-activation tests for paste/download/clipboard; ensure “gesture-required” approvals execute synchronously (no async gaps).
- Profile/multi-window: switching profiles and multiple matching tabs for the same origin.
- Private windows: verify the “no persistence” guarantee (no SQLite writes, no artifacts) and no cloud egress unless explicitly opted in for Private.
- Restricted pages/schemes (`safari://`, settings/new-tab, extension pages): verify “cannot automate here” messaging and safe fallbacks.
- App Group boundaries: extension cannot read decrypted artifacts or keys; state is streamed redacted from the app.
- Safari web apps (macOS 15+): confirm profileId scoping, permission prompts, and graceful failure when unsupported.
- Safari capability probe: maintain a small harness that exercises required APIs/permissions per Safari version and records expected fallbacks (keeps the feasibility matrix honest).
- Fault injection: service worker suspension, tab close mid-step, app restart, Safari crash/reopen; validate “no surprise replays” and reliable Stop/Panic.
- `observe_dom` stress: huge DOMs, virtualized tables, many iframes; confirm budgets, incremental scoping, and CPU/battery guardrails.

### Safari capability probe plan (source of truth)

Turn the feasibility matrix into something executable:

- A small “probe” extension mode that runs a fixed suite and writes a JSON report `{safariVersion, macOSVersion, results[]}`.
- Probe categories (minimum):
  - MV3 suspend/wake behavior and message delivery guarantees
  - `activeTab` / optional permission prompts and re-grant behavior
  - `windows.create` / `tabs.create` (dedicated task window/tab)
  - viewport capture (`tabs.captureVisibleTab` or confirmed alternatives)
  - downloads behavior (API vs click-to-download)
  - context menu support and limitations
  - private window detection reliability
  - Safari web app container behavior / partitioning
  - local inference sandbox viability (Core ML / Metal): confirm it runs in the intended process (app vs XPC) with acceptable latency and without additional entitlements
- Each probe must record: required permission, expected prompt, observed behavior, failure mode, and the fallback UX that Laika will use.
- The doc should be updated from probe results (not memory): when Safari behavior differs by version, the matrix must call it out explicitly.

### Prototype acceptance targets (initial; validate and tune)

Set measurable goals so “feels native” and “safe” are testable:

- Popover time-to-interactive (P95): ≤ 150 ms (cached) / ≤ 300 ms (cold).
- `observe_dom` runtime (P95): ≤ 250 ms for viewport scope on typical pages; ≤ 800 ms on heavy pages (bounded by budgets).
- Stop/Panic latency (P95): ≤ 200 ms from user action → token revocation + UI state update (best effort if Safari is suspended).
- Message payload caps: run-state payload ≤ 64 KB; tool results ≤ 256 KB; larger data must be chunked or stored as artifacts referenced by ID.
- Screenshot budgets (if enabled): downsampled to a fixed max dimension; hard cap on captures per minute; no screenshots on sensitive sites by default.
- Battery guardrails: bounded model calls per minute, bounded DOM scans per minute, and a “low power mode” that forces Read-only + disables visual capture.

### Policy + tool contract validation

- Schema validation for all tool requests/results; unknown tool/version handling.
- Error taxonomy behavior (`TIMEOUT`, `CANCELLED`, `STALE_HANDLE`, etc.) and bounded retry policies.
- Cancellation semantics: immediate stop, token revocation, and safe cleanup of in-flight actions.
- Idempotency enforcement for side-effecting calls; audit log integrity (append-only + redaction guarantees).

## Open Questions / Roadmap

- Per-site risk classification: heuristics vs. user labeling vs. signed curated lists.
- Policy definition approach: hard-coded rules vs. small policy DSL + unit tests.
- On-device vision: best tradeoffs among VLM size, latency, and privacy.
- Session memory: how to retain helpful context without increasing cross-site leakage risk.
- Isolated surface implementation: WKWebView vs other sandboxed browser surfaces; capability parity with “My Browser”.
- SQLite durability details: schema + migrations, checkpoint/rollback UX, and compaction policies for long runs.
- Remote monitoring/control (optional): securely start/monitor runs from another device while the Mac executes locally (explicit opt-in, strong auth, least-privilege, and on-device inference).

## Appendix: Training/Fine-Tuning SLMs (Jamba, Qwen3 Small) for Tool Use

Laika benefits from a small, fast “tool-using” model that can robustly operate the browser tools under tight constraints. This section outlines a practical path to train/fine-tune models such as **Jamba** or **Qwen3 small** variants for reliable tool use.

For on-device model hosting/runtimes, model management, and the cloud training → signed model update pipeline, see `docs/local_llm.md`.

### 1) Define the Tool Contract (the “API surface”)

- Freeze a minimal set of tools with JSON schemas and clear pre/post conditions.
- Make tool outputs deterministic and structured (avoid free-form strings when possible).
- Add a `risk` field and provenance metadata to every tool result.

### 2) Build Training Data (trajectories)

Data sources:

- **Synthetic trajectories**: generate multi-step browser tasks with a larger teacher model, then verify.
- **Human demonstrations**: record assist-mode sessions (with consent), then convert to tool-call traces.
- **Adversarial pages**: include prompt-injection examples and require the model to ignore/contain them.

Each example ideally includes:

- Task goal + constraints (site mode, allowed actions)
- Observations (structured DOM facts, optional screenshots)
- Tool call sequence + expected outcomes
- Safety labels (should ask approval? should refuse?)

### 3) Fine-Tuning Approach

- **SFT (supervised fine-tuning)** over tool-call traces to learn:
  - When to observe vs. act
  - How to select elements and verify outcomes
  - How to escalate to the user when uncertain
- **Preference optimization** (optional) to reward:
  - Fewer unnecessary steps
  - Higher success rates
  - Safer decisions under ambiguity
- **Tool-use generalization**: mix tasks across sites and layouts; focus on intent-based element selection.

Practical notes:

- Use LoRA/QLoRA to keep iteration fast and enable on-device-friendly variants.
- Maintain strict separation between “reasoning” (internal) and “tool call JSON” (external), to improve reliability.

### 4) Evaluation Harness (must-have)

Evaluate models against:

- **Tool accuracy**: correct tool selection + valid arguments + success rate.
- **Robustness**: DOM changes, missing elements, pagination, popups, cookie banners.
- **Security**: injection suites that try to cause exfiltration, cross-site leakage, or policy violations.
- **Latency**: per-step response time on target Macs (M-series), with quantized models.

### 5) Deployment in Laika

- Ship a “stable” tool model that is small and fast (default).
- Allow advanced users to swap in larger local models for higher quality planning/writing.
- Keep the **Policy Gate** independent of model behavior (never rely on training alone for safety).
