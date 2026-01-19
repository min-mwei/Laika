# Automation Harness

This repo includes a lightweight automation harness that drives the real Laika planning loop against a live browser, without manual clicking. It uses Playwright (WebKit by default) plus Laika's `content_script.js` for DOM observation so the handle IDs and item extraction match the extension.

## What it does

- Loads a page in a headless browser.
- Injects Laika's DOM observer and collects an Observation.
- Sends `PlanRequest` payloads to `laika-server`.
- Executes tool calls (navigate/click/type/observe), then re-observes.
- Prints the final summaries for each goal and can write JSON output.

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

Run custom goals:

```bash
node src/laika/automation_harness/scripts/laika_harness.js --url https://news.ycombinator.com --goal "What is this page about?" --goal "Tell me about the first topic."
```

## Options

- `--server http://127.0.0.1:8765` to point at a different plan server.
- `--browser webkit|chromium|firefox` (default: webkit).
- `--detail` for larger `observe_dom` budgets.
- `--headed` to watch the run in a visible browser.
- `--output /tmp/results.json` to save JSON output.
- `--no-auto-approve` to stop on policy prompts instead of auto-approving.
