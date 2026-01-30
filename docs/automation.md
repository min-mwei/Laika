# Automation Harness (Safari)

This repo needs an end-to-end automation path that exercises the real Safari extension + native app plan loop, not a simulated HTTP client. The current Playwright harness is useful for DOM extraction debugging but bypasses the extension UI, background logic, and native messaging. This doc describes a bridge-based design that runs in real Safari windows (not WebDriver automation windows).

## Goals

- Drive the real Safari Web Extension and native app in the same way a user does.
- Reproduce agent runs, tool calls, and observation collection inside Safari.
- Keep scenario inputs stable and deterministic where possible.
- Capture step-by-step outputs and logs for debugging regressions.

## Non-goals

- Headless browser support (Safari WebDriver does not support headless runs).
- Cross-browser testing (Safari only).
- Model quality evaluation beyond basic regression checks.

## Constraints (must preserve)

- Treat all web content as untrusted input.
- Do not send cookies, session tokens, or raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep the Safari extension thin; orchestration and model calls live in the app.
- Log actions in an append-only format and avoid storing sensitive raw page content.

## Proposed architecture (bridge-based)

### Components

1) Safari (normal window, selected profile)
- Use a real Safari window in the desired profile (Personal/Laika).
- Extension settings apply only in normal windows, not WebDriver automation windows.

2) UI automation driver
- Xcode UI tests (XCUIAutomation) or AppleScript/Accessibility to drive Safari.
- Owns scenario loading, browser lifecycle, and result collection.

3) Test harness page
- A local page served from `http://127.0.0.1:<port>` that kicks off runs.
- Sends `postMessage` requests with a per-run nonce and target URL.

4) Extension automation bridge (test-only)
- A content-script bridge that accepts `window.postMessage` requests when a test flag is set.
- Forwards requests to the extension background via `browser.runtime.sendMessage`.
- Returns responses back to the page via `window.postMessage` so WebDriver can read them.
- Must be disabled unless a test flag is present to avoid exposing new attack surface.

5) Shared agent runner module
- Extract the plan loop from `popover.js` into a shared module (e.g. `extension/lib/agent_runner.js`).
- Both the UI popover and the automation bridge call the same plan loop logic.
- Uses native messaging (`browser.runtime.sendNativeMessage`) for `plan` requests.
- Uses background tool execution (`browser.runtime.sendMessage`) for tools.

6) Fixture site (optional but recommended)
- Local static pages to avoid network flakiness and make regression snapshots stable.
  - The harness server serves `automation_harness/fixtures` at `/fixtures/*` (for example: `http://127.0.0.1:8766/fixtures/news.html`).

### High-level flow

1) Setup
- Ensure the Laika extension is installed and enabled in Safari.
- Ensure the extension is enabled for the selected Safari profile.
- Launch the Laika macOS app (native messaging host).

2) Start scenario
- UI automation opens Safari and navigates to the harness page.
- The harness page posts `laika.automation.start` with `{ runId, goals, targetUrl, options, nonce }`.
- The harness page retries `laika.automation.start` until it receives an ack to avoid content-script load races. It also listens for `laika.automation.ready` to start immediately once the bridge is injected.
- The background opens a new tab to `targetUrl` and runs the agent loop there.

3) Agent run (inside extension)
- Content-script bridge forwards the request to background.
- Background invokes the shared agent runner with the goal(s).
- The runner:
  - Observes DOM through the content script (same as UI).
  - Sends native `plan` requests to the macOS app.
  - Executes tools through background handlers (same as UI).
  - Emits step results and final assistant output.

4) Results
- The bridge posts structured results to the page.
- UI automation collects JSON output and writes a report.
- If the harness page is suspended or the content script unloads, the background can POST the final result directly to the harness server using a localhost-only `reportUrl` to avoid timeouts.
- The automation run clears extension local storage by default to avoid state carryover.

## Bridge gating and safety

- Only accept automation messages from localhost origins.
- Require a per-run nonce from the harness page.
- Gate automation behind a local config knob (`automationEnabled` in extension storage) so it can be disabled outside of test runs.
- Automation is disabled by default; the harness sends `laika.automation.enable` to turn it on for test runs.
- Never include raw HTML or sensitive data in responses.

## Automation bridge contract (draft)

- Requests (page -> content script):
  - `laika.automation.enable` { runId, nonce }
  - `laika.automation.start` { runId, goals, targetUrl, options, nonce, reportUrl }
  - `laika.automation.status` { runId }
  - `laika.automation.cancel` { runId }
- Responses (content script -> page):
  - `laika.automation.ready` { at }
  - `laika.automation.enabled` { runId, status, error }
  - `laika.automation.progress` { runId, step, action, observationSummary }
  - `laika.automation.result` { runId, summary, steps[] }
  - `laika.automation.error` { runId, error }

## Robustness notes (current behavior)

- The bridge accepts repeated `laika.automation.start` retries with the same runId/nonce after a failure; harness retry loops are idempotent until an ack arrives.
- The UI test driver prefers XCUI keystrokes for window creation and URL navigation; AppleScript is used only as a fallback and logs Automation permission hints when blocked.
- The UI test driver performs a bridge-ready preflight (polling `/api/health`) and captures screenshots/UI hierarchy dumps on key failures.
- Automation runs close tabs opened during the run (including the harness tab) after reporting results; shell runners can quit Safari for clean isolation.

## Harness instrumentation

- The harness page emits lightweight telemetry events (config loaded, ready, start sent, ack/status/progress) to the local harness server.
- On timeout, the harness includes the last telemetry event in the output to highlight where the run stalled.
- The harness server exposes `/api/health` to report the latest telemetry snapshot (used for preflight checks).

## Timeout alignment

- Agent run timeout (`options.runTimeoutMs`) is clamped below the harness timeout.
- Harness timeout is configured a few seconds below the UI test timeout.
- Default buffers keep `runTimeoutMs < harnessTimeout < uiTestTimeout`.

## Scenario format (draft)

Keep existing JSON but allow automation options:

```json
{
  "url": "https://news.ycombinator.com",
  "goals": [
    "What is this page about?",
    "Tell me about the first topic."
  ],
  "options": {
    "maxSteps": 6,
    "autoApprove": true,
    "observeDelayMs": 300,
    "blockedTools": ["browser.open_tab"],
    "disallowOpenTabs": true,
    "resetStorage": true
  }
}
```

Goals can be strings (plan loop) **or** typed objects. Use typed objects to
trigger collection-scoped actions without a plan loop:

```json
{
  "type": "collection.answer",
  "question": "What are the key differences in how each outlet is covering this story?",
  "collectionId": "col_123",  // optional (defaults to active collection)
  "maxSources": 10,            // optional
  "maxTokens": 3072            // optional
}
```

Use `collection.capture` when you want automation to create/select a collection,
add a fixed set of URLs, and run `source.capture` for each URL:

```json
{
  "type": "collection.capture",
  "title": "Meta 2026 coverage",   // optional (creates a new collection if provided)
  "collectionId": "col_123",       // optional (uses existing collection if set)
  "urls": [
    "https://investor.atmeta.com/investor-news/press-release-details/2026/Meta-Reports-Fourth-Quarter-and-Full-Year-2025-Results/default.aspx",
    "https://techcrunch.com/2026/01/28/zuckerberg-teases-agentic-commerce-tools-and-major-ai-rollout-in-2026/",
    "https://www.bloomberg.com/news/articles/2026-01-28/meta-says-2026-spending-will-blow-past-analysts-estimates"
  ],
  "maxChars": 24000               // optional per-source capture bound
}
```

`resetStorage` defaults to `true` for automation runs; it clears automation-scoped keys and in-memory caches (not user settings). Set it to `false` if you need to keep automation state between scenarios.
`blockedTools` is an optional list of tool names to skip when selecting the next action (useful for live tests).
`disallowOpenTabs` is a convenience flag that adds `browser.open_tab` to `blockedTools`.
`blockedUrlHosts` is an optional list of hostname suffixes (e.g., `["linkedin.com"]`) that automation will block for `browser.open_tab` and `browser.navigate` (useful for live Techmeme tests to avoid social/login detours).

Default scenarios (`hn.json`, `bbc.json`, `sec_nvda.json`, `collection_selection_links.json`) use local fixtures where possible to reduce flakiness.
Live-web smoke scenarios are suffixed with `_live.json` and are opt-in.

## Planned scenarios (source collections + transforms)

The collections + transforms workflow (see `docs/LaikaArch.md` and `src/laika/PLAN.md`) adds requirements that are best validated end-to-end in Safari (collection capture, transforms, viewer tabs).

Add fixture-backed scenarios (names illustrative; keep them deterministic):

- `collection_selection_links.json`
  - Fixture: `fixtures/collection_selection_links.html` (auto-selects a "thread" region containing many outbound links).
  - Validates: `browser.get_selection_links` returns stable, deduped http(s) URLs (collection ingestion validation comes later).

- `collection_capture_normalization.json`
  - Fixture: a few representative pages (article, list, discussion) behind the same origin.
  - Validates: `source.capture` produces bounded normalized text + metadata; no raw HTML persistence; provenance is recorded.

- `collection_answer_differences.json`
  - Uses a small collection of sources about the same story.
  - Validates: `web.answer` over a collection context pack produces a "key differences" synthesis with usable citations back to each source.

- `transform_comparison_table.json`
  - Uses a small collection of sources.
  - Validates: `transform.run(type=comparison)` produces an artifact that renders as Markdown (including a table) via the shared Markdown renderer.

- `transform_timeline.json`
  - Uses sources with dates.
  - Validates: `transform.run(type=timeline)` produces a usable timeline artifact (safe document by default; interactive viewer optional).

- `artifact_open_viewer.json`
  - Creates an artifact, then opens it in a new viewer surface.
  - Validates: `artifact.open` opens a trusted viewer tab/window and never injects untrusted HTML into privileged UI.

- `shopping_compare_totals.json`
  - Fixture: 5 product pages with known base/shipping/tax/warranty fields.
  - Validates: Laika produces a comparison table with order links and deterministic totals (via `app.money_calculate`) plus "what to verify".

- `shopping_stop_before_commit.json`
  - Fixture: a checkout review page with a commit action (e.g., "Place order").
  - Validates: Policy Gate blocks commit clicks unless the user explicitly changes intent; run logs record a stable reason code.

## Pitch-based workflow scenarios (fixture-backed)

These scenarios mirror the "Try it" prompts in `docs/Laika_pitch.md` to keep the end-to-end harness aligned with product narratives while the underlying tools evolve.

- `pitch_news_synthesis.json`
  - Fixture: a thread page with multiple outlets covering the same story plus linked outlet pages.
  - Validates: multi-source differences summary, a comparison table draft, and a timeline draft (plain text is acceptable until transforms land).

- `pitch_shopping_constraints.json`
  - Fixture: five jacket product cards with prices, shipping, tax, warranty, and return policy fields.
  - Validates: total-cost comparison with explicit assumptions, order links, and "verify at checkout" notes plus a stop-before-purchase reminder.

- `pitch_trip_planning.json`
  - Fixture: three Kyoto hotel options plus trip constraints and itinerary notes.
  - Validates: options table, day-by-day itinerary, and a clear "ask before booking" checkpoint.

## Techmeme theme scenarios (fixture + live)

These scenarios mirror a current Techmeme theme so we can validate the "thread -> synthesis" flow on live news while keeping a deterministic fixture.

- `techmeme_maia_theme.json`
  - Fixture: Techmeme-style thread about Microsoft's Maia 200 AI accelerator launch.
  - Validates: multi-source differences summary, comparison table draft, and timeline draft (plain text until transforms land).

- `techmeme_maia_theme_live.json` (opt-in)
  - Live: Techmeme homepage or snapshot containing the Maia 200 AI accelerator coverage block.
  - Validates: identifies the theme and lists outlet perspectives without opening unrelated tabs.

- `techmeme_meta_coverage_live.json` (opt-in)
  - Live: Techmeme homepage coverage block about Meta's 2025 results/2026 spending.
  - Validates: collects specific Meta story links into a collection, captures sources, and answers with outlet differences + citations.

## Runner outputs

- JSON file with:
  - Per-goal step summaries.
  - Tool calls and tool results.
  - Observation summaries (counts only, no raw HTML).
- Optional: attach native app log excerpts for each run.

## Execution (bridge + UI test)

Pre-flight:
- If the extension UI is built via Vite (Preact + TS), ensure the built assets exist (e.g. `src/laika/extension/ui_dist/`) before running the Safari UI harness, or run the standard build script that generates them.

```bash
# Start the harness + run the Safari UI test driver
cd src/laika/automation_harness
scripts/run_safari_ui_test.sh --scenario scripts/scenarios/hn.json --output /tmp/laika-hn.json --quit-safari
```

Run the full UI harness suite (HN/BBC/SEC):

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation
```

Optional live-web smoke tests:

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation --include-live
```

Manual two-step flow (if you want to run the server and UI test separately):

```bash
# 1) Start the local harness server
node src/laika/automation_harness/scripts/laika_bridge_harness.js \
  --scenario src/laika/automation_harness/scripts/scenarios/hn.json \
  --output /tmp/laika-hn.json \
  --timeout 240

# 2) Run the UI test driver (opens Safari and waits for the output file)
cat <<EOF > /tmp/laika-automation-config.json
{"harnessURL":"http://127.0.0.1:8766/harness.html","outputPath":"/tmp/laika-hn.json","timeoutSeconds":240,"quitSafari":true}
EOF
xcodebuild test \
  -project src/laika/LaikaApp/Laika/Laika.xcodeproj \
  -scheme LaikaUITests \
  -destination "platform=macOS"
```

The UI test driver reads `/tmp/laika-automation-config.json` if present (env vars can also override it). `run_safari_ui_test.sh` will build + install the app into `~/Applications` by default; pass `--no-build` to skip. The driver expects the Safari extension to be enabled in the active profile and will open the harness page in a normal Safari window.
Use `--no-quit-safari` to keep Safari open between runs. Use `--retries`/`--retry-delay` to retry known flaky UI-test bootstrap failures. The harness emits `error: "timeout"` when no report arrives before `--timeout`.

## Legacy Playwright harness

The existing Playwright harness remains useful for fast DOM extraction debugging, but it does not exercise:
- Safari UI and extension messaging.
- Native app messaging.
- Real extension tool execution in Safari.

Use it only for unit-like checks, not end-to-end validation.

## Risks and open questions

- Safari WebDriver automation windows are isolated from user settings and profiles, so extension tests must run in normal Safari windows via UI automation.
- UI automation cannot reliably interact with the Safari toolbar or extension popovers; the bridge avoids this by running the agent loop without opening the UI.
- Harness page and bridge must remain locked down to avoid exposing automation controls to arbitrary sites.

## References

- Apple: Testing with WebDriver in Safari
  - https://developer.apple.com/documentation/webkit/testing-with-webdriver-in-safari
- Apple: About WebDriver for Safari (automation windows, glass panes)
  - https://developer.apple.com/documentation/webkit/about-webdriver-for-safari
- Selenium: Safari-specific WebDriver notes (`safaridriver --enable`)
  - https://www.selenium.dev/documentation/webdriver/browsers/safari/
- Apple Support: Extensions disabled by default in private windows
  - https://support.apple.com/en-us/102343
- Playwright: Extensions only work in Chromium
  - https://playwright.dev/docs/chrome-extensions
