# Automation Harness

This repo includes a lightweight automation harness that drives the real Laika planning loop against a live browser, without manual clicking. It uses Playwright (WebKit by default) plus Laika's `content_script.js`, so DOM observation and handle IDs match the extension.

## What it does

- Loads a page in a headless browser.
- Injects Laika's DOM observer and collects an Observation.
- Sends `PlanRequest` payloads to `laika-server`.
- Executes tool calls (observe/navigate/back/forward/refresh/click/type/scroll/select), then re-observes.
- Prints the final summaries for each goal and can write JSON output.

## How it works

1) Launches Playwright, sets `window.__LAIKA_HARNESS__ = true`, and injects `src/laika/extension/content_script.js`.
2) Waits a short post-load delay (configurable) and calls `window.LaikaHarness.observeDom()` to produce an Observation using the same extraction logic as the extension (handles, blocks, items, outline, comments).
3) Builds a `PlanRequest` with `context` (origin, mode, observation, recent tool calls/results, tabs, runId, step/maxSteps) and POSTs to `/plan`.
4) Picks the first action whose policy is `allow` or `ask`. With `--no-auto-approve`, it stops on `ask` instead of executing.
5) Executes the tool, then re-observes:
   - `browser.observe_dom` calls the observer directly.
   - `browser.open_tab` and `browser.navigate` map to `page.goto`.
   - `browser.back`, `browser.forward`, and `browser.refresh` map to Playwright navigation.
   - `browser.click`, `browser.type`, `browser.scroll`, and `browser.select` call `window.LaikaHarness.applyTool` (same handle IDs as the extension).
6) If the planner requests `content.summarize`, it POSTs to `/summarize` with the full summary context.
7) Prints the final summary per goal and optionally writes a JSON report with step-by-step details.

## Supported tools

- `browser.observe_dom`, `browser.open_tab`, `browser.navigate`, `browser.back`, `browser.forward`, `browser.refresh`.
- `browser.click`, `browser.type`, `browser.scroll`, `browser.select` (handle IDs from the observer).
- Other tool names return `unsupported_tool` in the harness.

## Limitations

- Single-tab only; `browser.open_tab` maps to `page.goto`, and `tabs` contains only the active tab.

## Prereqs

Node 18+ is required (for built-in `fetch`).

1) Run the plan server (use the same MLX model you test in Safari):

```bash
cd src/laika/app
swift run laika-server --model-dir /path/to/Qwen3-0.6B-MLX-4bit
```

2) Install Playwright:

```bash
cd src/laika/automation_harness
npm install
npx playwright install webkit
```

## Quick start

Run the Hacker News scenario:

```bash
node src/laika/automation_harness/scripts/laika_harness.js --scenario src/laika/automation_harness/scripts/scenarios/hn.json
```

Run the BBC or WSJ scenarios:

```bash
node src/laika/automation_harness/scripts/laika_harness.js --scenario src/laika/automation_harness/scripts/scenarios/bbc.json
node src/laika/automation_harness/scripts/laika_harness.js --scenario src/laika/automation_harness/scripts/scenarios/wsj.json
```

Run custom goals:

```bash
node src/laika/automation_harness/scripts/laika_harness.js --url https://news.ycombinator.com --goal "What is this page about?" --goal "Tell me about the first topic."
```

## Scenario format

Scenario files are JSON with a URL and one or more goals:

```json
{
  "url": "https://news.ycombinator.com",
  "goals": [
    "What is this page about?",
    "Tell me about the first topic."
  ]
}
```

## Options

- `--server http://127.0.0.1:8765` to point at a different plan server.
- `--browser webkit|chromium|firefox` (default: webkit).
- `--detail` for larger `observe_dom` budgets.
- `--headed` to watch the run in a visible browser.
- `--observe-wait 300` to delay before observing after loads/actions (useful for dynamic pages).
- `--output /tmp/results.json` to save JSON output.
- `--no-auto-approve` to stop on policy prompts instead of auto-approving.
- `--max-steps 6` to cap tool-call steps per goal.
