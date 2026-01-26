# Laika vocabulary implementation plan (focus: primitives + layering)

Purpose: implement `docs/laika_vocabulary.md` by finishing a small, robust primitive surface first, then layering the high-level vocabulary on top.

## Constraints to preserve
- Treat all web content as untrusted input.
- Do not send cookies, session tokens, or raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep the Safari extension thin; policy/orchestration/model calls live in the app.
- Log actions in append-only form; avoid storing sensitive raw page content.
- Assist-only mode; do not reintroduce observe-only branches.
- Automation is opt-in: default disabled, explicitly enabled for test runs.

## Phase 1 - Low-level primitives complete (v1)

1) Canonical primitive catalog + schema
- Single source of truth for tool names + argument schemas (Swift + extension + docs).
- Strict validation in the LLMCP parser; reject unknown tools and extra keys.
- Standardize tool execution result shape across JS/Swift:
  - ok: `{status:"ok", ...}`
  - error: `{status:"error", error:"<UPPER_SNAKE_CASE_CODE>", ...}`
- Define canonical `signals` and tool `error` codes as shared, versioned enums and enforce them at boundaries (Swift <-> JS) and in docs.

2) `browser.observe_dom` foundations
- Match the vocabulary schema: `text`, `primary`, `blocks`, `items`, `outline`, `comments`, `elements`, `signals`.
- Add observation metadata (`documentId`, `navigationGeneration`, `observedAtMs`).
- Traverse open shadow DOM and same-origin iframes; emit signals for closed/cross-origin frames.
- Support scoped re-observe via `rootHandleId` ("zoom in") without changing output shape.
- Define/emit a stable `signals` set and enforce the canonical names:
  - paywall_or_login/consent_modal/overlay_blocking/captcha_or_robot_check/age_gate/geo_block/script_required/url_redacted
  - sparse_text/non_text_content/cross_origin_iframe/closed_shadow_root/virtualized_list/infinite_scroll/pdf_viewer
- Propagate observation metadata into the shared `Observation` / `ContextPack` types and tie handle validity to (`documentId`, `navigationGeneration`).
- Enforce budgets and redaction; never emit raw HTML.

3) Handle semantics + staleness
- Bind `handleId` to document + navigation generation; invalidate on navigation/refresh.
- Maintain a handle store with role/label hints for resolution.
- Return stable errors (`STALE_HANDLE`, `NOT_FOUND`, `NOT_INTERACTABLE`, `DISABLED`, `BLOCKED_BY_OVERLAY`).

4) DOM action primitives
- Precondition checks (visible, enabled, correct role/type).
- Scroll-into-view + highlight + action, then re-observe for verification.
- Consistent action telemetry for approvals and logs.

5) Navigation + search primitives
- Sanitize URLs (http/https only) for `open_tab`/`navigate`.
- Implement search template config + `newTab` semantics.
- Treat search queries as data egress in policy (ask when sensitive).
- Codify a conservative sensitive-query detector (emails/phones/account-like strings) and add tests.

6) Deterministic compute (app-local)
- Implement a small, safe evaluator for `app.calculate` / `Calculate(Expression)` (at least arithmetic + rounding/formatting).
- Use it for `Price` totals and any math in investigation-style workflows.
- Define supported operators/functions and rounding rules so results are consistent and audit-friendly.

7) Policy gate + logging
- Extend field-kind detection (credential/payment/personal-id).
- Log tool calls/results with redacted payloads only.

8) Tests + harness
- Unit tests: URL sanitation, argument validation, handle staleness, deterministic compute.
- Extension tests: observe/action error codes.
- Automation harness scenarios per primitive + a small "capability probe" suite across representative sites/content types.
- Default scenarios use local fixtures; live-web smoke tests are opt-in.
- Preflight the bridge (via `/api/health`) before full UI runs; fail fast with actionable guidance.
- Ensure harness reporting survives tab teardown (sendBeacon/keepalive or background POST).
- Restore `automationEnabled` after test runs if the harness toggled it on.
- Prefer graceful Safari quits before a `pkill` fallback.
- Capture failure artifacts (screenshots + UI hierarchy) and print xcresult/log/telemetry paths on failure.
- Align timeouts (`runTimeoutMs < harnessTimeout < uiTestTimeout`) and clamp defaults centrally.
- Track simple probe metrics (success rate per primitive, common failure codes, and median/p95 timings).

## Phase 1 exit criteria
- All primitives in `docs/laika_vocabulary.md` are implemented and schema-validated.
- Tool calls are rejected unless arguments are valid and `handleId` is current.
- Navigation/search are sanitized and policy-gated.
- `browser.observe_dom` supports `rootHandleId` scoping and emits stable `signals` for access/visibility limitations.
- Error codes are stable/documented (models can learn retry strategies).
- Deterministic `Calculate` is available for higher-level workflows.
- Harness passes fixture-based primitive scenarios with consistent logs; live-web smoke runs are clean when enabled.

## Phase 1 status (complete)
- [x] Tool schemas are unified across shared + extension + docs, and invalid tool calls are rejected.
- [x] Observation metadata/signals + handle staleness are enforced in JS and shared types.
- [x] DOM actions sanitize/validate inputs; search/navigation are gated and URL-sanitized.
- [x] Deterministic `app.calculate` is implemented with unit coverage.
- [x] Sensitive-field detection gates `browser.type`/`browser.select` for credential/payment/personal-id fields.
- [x] Automation harness includes preflight, default fixtures, opt-in live smoke tests, failure artifacts, aligned timeouts, and keepalive/beacon reporting.
- [x] Automation enable is restored after test runs, and Safari quits gracefully before forced termination.

## Phase 1 completion notes
- Fixtures suite passing for hn/bbc/sec_nvda; live-web smoke scenarios remain opt-in.

## Phase 2 - High-level vocabulary layer (Summarize/Find/Search/Investigate)

Orchestration invariants:
- At most 1 primitive call per step (reviewability and determinism).
- Re-observe after any navigation or DOM action before making the next decision.
- Enforce a step budget per run; stop with partial results + "what I need next" instead of looping.
- Back off on repeated primitive errors; ask the user for help when stuck (don't blind-retry).

### Summarize(Entity)
- Output shape: grounded summary + key takeaways + what to verify next; explicitly mention access limitations (paywall/login/sparse text).
- Typical primitives: `browser.observe_dom` (and `browser.open_tab` when the user explicitly asks to summarize a link/item).
- Reliability: grounding checks (anchors/quotes/URLs) + extractive fallback when grounding is weak; enforce this in Agent Core (not "best effort" in the model).

### Find(Topic, Entity)
- Output shape: ranked matches with quotes + handles/anchors; if not found, say so and propose the next deterministic step.
- Typical primitives: `browser.observe_dom` (scoped via `rootHandleId`), `browser.scroll` + re-observe loops (bounded).
- Strategy: search within `primary/blocks/items/outline/comments`; treat virtualized lists as partial and require scroll/re-observe.
- Decision: keep Find model-driven for v1 (no dedicated `browser.find_text` primitive).

### Search(Query)
- Output shape: preview the query/engine, open results in a new tab.
- Typical primitives: `search` (+ optional engine retry logic when blocked).
- Policy: ask before searching if the query contains sensitive personal details.

### Investigate(Topic, Entity)
- Output shape: Findings / Evidence / Uncertainties / Recommended actions (citation-backed where possible).
- Typical primitives: `browser.observe_dom`, `browser.open_tab`/`browser.navigate`, `browser.click`, `browser.scroll`, `search`.
- Strategy: maintain an evidence ledger, cross-check key claims, stop at budget and return what remains unknown.

Intent parsing + prompting:
- Extend goal parsing to recognize these verbs, set required output formats, and route to `web.summarize` vs `web.answer` appropriately.
- Keep "Find" and "Summarize" read-only by default; require explicit user intent before navigation, and explicit approval before mutating actions.

## Phase 3 - Artifacts + integrations
- Define an app-level primitive catalog in `docs/llm_context_protocol.md` (“App-level primitives”) with the same schema validation + policy gating + audit logging (e.g., `artifact.save`, `artifact.share`, `integration.invoke`, `app.calculate`).
- Artifact store for `Create`/`Save`/`Share` with redacted metadata and encrypted-at-rest storage.
- `Price`/`Buy` workflows with explicit confirmation gates and "stop at final review" behavior.
- `Invoke(API)` for opt-in integrations with explicit payload previews and minimal/redacted context packs.
- `Dossier` generation with audit trails (often "Investigate + Create").

## Open questions / decisions
- What are the first 10-20 capability-probe sites/tasks we will run continuously to harden primitives (news, ecommerce, docs, feeds, web apps)?

## Validation loop
- Update relevant design docs before coding.
- Implement + test locally.
- Run the automation harness scenarios.
- Verify build + logging, then request manual Safari testing.
- Review logs and iterate.
