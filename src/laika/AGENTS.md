# Agent Guidance for src/laika

## Scope
This directory is reserved for the Safari extension, macOS companion app, and the thin model bridge that validate the AI Fortress design.

## Primary references
- `docs/LaikaOverview.md` for architecture and safety expectations.
- `docs/automation.md` for automation harness flow, options, and scenario format.
- `src/laika/PLAN.md` for the validation plan.
- `src/local_llm_quantizer/README.md` for MLX 4-bit model conversion details.

## Constraints to preserve
- Treat all web content as untrusted input.
- Do not send cookies, session tokens, or raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep the Safari extension thin; put policy, orchestration, and model calls in the app.
- Log actions in an append-only format and avoid storing sensitive raw page content.

## Layout conventions (create when needed)
- `src/laika/app` for Swift app code.
- `src/laika/extension` for Safari Web Extension code.
- `src/laika/model` for local model bridge glue.
- `src/laika/app/Sources/LaikaServer` for the legacy local HTTP bridge (no longer used by the extension).
- `src/laika/LaikaApp` for the Xcode macOS app + Safari extension project.

## Model integration defaults
- Prefer local inference via `mlx-swift` with MLX 4-bit model assets produced by `src/local_llm_quantizer`.
- If a cloud fallback is requested, make it opt-in and pass only redacted context packs.

## Development process (required)
1) Design and update the relevant design doc before coding.
2) Implement the feature and test locally.
3) Run the Laika automation harness to validate behavior (see `docs/automation.md`).
4) Fix bugs found in the automation run.
5) Re-run the Laika automation harness until clean.
6) Confirm the build works, logging is sufficient, then ask for manual user testing.
7) Read logs and incorporate user feedback.

## Build (Swift packages)

```bash
cd src/laika/app
swift build
```

## Run the plan server (local model)

Use the same model directory that Safari uses:

```bash
cd src/laika/app
MLX_METAL_JIT=1 ./.build/arm64-apple-macosx/debug/laika-server \
  --model-dir ../extension/lib/models/Qwen3-0.6B-MLX-4bit \
  --port 8765
```

## Automation harness (Safari UI)

```bash
cd src/laika/automation_harness
scripts/run_safari_ui_test.sh --scenario scripts/scenarios/hn.json --output /tmp/laika-hn.json
```

Run the full UI harness suite:

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation
```

## Automation harness (Playwright)

```bash
cd src/laika/automation_harness
npm install
npx playwright install webkit
node scripts/laika_harness.js --scenario scripts/scenarios/hn.json
```

## JavaScript unit tests (extension helpers)

```bash
node --test src/laika/extension/tests/*.js
```

## Swift tests (if present)

```bash
cd src/laika/app
swift test
```

## Logs (debugging)

- Extension logs: `~/Library/Containers/com.laika.Laika.Extension/Data/Laika/logs/llm.jsonl`
- CLI/server logs: `~/Laika/logs/llm.jsonl` (override with `LAIKA_HOME=/path/to/Laika`)

## Mode policy
- The prototype supports assist mode only; do not reintroduce observe-only mode branches.
