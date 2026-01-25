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

### High-level flow

1) Setup
- Ensure the Laika extension is installed and enabled in Safari.
- Ensure the extension is enabled for the selected Safari profile.
- Launch the Laika macOS app (native messaging host).

2) Start scenario
- UI automation opens Safari and navigates to the harness page.
- The harness page posts `laika.automation.start` with `{ runId, goals, targetUrl, options, nonce }`.
- The harness page retries `laika.automation.start` until it receives an ack to avoid content-script load races.
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
- Never include raw HTML or sensitive data in responses.

## Automation bridge contract (draft)

- Requests (page -> content script):
  - `laika.automation.start` { runId, goals, targetUrl, options, nonce, reportUrl }
  - `laika.automation.status` { runId }
  - `laika.automation.cancel` { runId }
- Responses (content script -> page):
  - `laika.automation.progress` { runId, step, action, observationSummary }
  - `laika.automation.result` { runId, summary, steps[] }
  - `laika.automation.error` { runId, error }

## Harness instrumentation

- The harness page emits lightweight telemetry events (config loaded, start sent, ack/status/progress) to the local harness server.
- On timeout, the harness includes the last telemetry event in the output to highlight where the run stalled.

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
    "resetStorage": true
  }
}
```

`resetStorage` defaults to `true` for automation runs; set it to `false` if you need to keep extension storage between scenarios.

## Runner outputs

- JSON file with:
  - Per-goal step summaries.
  - Tool calls and tool results.
  - Observation summaries (counts only, no raw HTML).
- Optional: attach native app log excerpts for each run.

## Execution (bridge + UI test)

```bash
# Start the harness + run the Safari UI test driver
cd src/laika/automation_harness
scripts/run_safari_ui_test.sh --scenario scripts/scenarios/hn.json --output /tmp/laika-hn.json
```

Run the full UI harness suite (HN/BBC/WSJ):

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation
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
Use `--quit-safari` if Safari activation is flaky. The harness emits `error: "timeout"` when no report arrives before `--timeout`.

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
