# Laika MVP: macOS app + Safari Web Extension (native messaging)

This MVP runs the local MLX model inside the Safari Web Extension's native handler and uses native messaging (no HTTP bridge).

## 1) Build or convert the MLX model

Convert Qwen3-0.6B to MLX 4-bit using the quantizer:

```bash
cd src/local_llm_quantizer
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python convert_qwen3_to_mlx_4bit.py --out-dir ./Qwen3-0.6B-MLX-4bit
python smoke_test_mlx_model.py --model-dir ./Qwen3-0.6B-MLX-4bit
```

Copy the model directory into the extension bundle assets:

- `src/laika/extension/lib/models/Qwen3-0.6B-MLX-4bit`

If the model directory is missing, the extension build runs `src/local_llm_quantizer/convert_qwen3_to_mlx_4bit.py`
to populate it (requires Python + dependencies and an HF download on first run).

Shortcut to build/publish the model into the extension assets:

```bash
./src/laika_model_build.sh
```

## 2) Build and run the macOS app + extension

Open the Xcode project:

- `src/laika/LaikaApp/Laika/Laika.xcodeproj`

Build and run the `Laika` app target. The app hosts the extension; you must run it once to enable the extension in Safari.

Shortcut build script:

```bash
DEVELOPMENT_TEAM=4Z82EAJL2W ./src/laika_build.sh
```

By default the build script installs to `~/Applications` so Safari can see the extension. Set `INSTALL_APP=0` to skip install, or `OPEN_APP=1` to launch the app after install.

## 3) Enable the Safari extension

1. Open Safari and enable the Develop menu (`Safari` -> `Settings` -> `Advanced` -> "Show Develop menu").
2. Open `Safari` -> `Settings` -> `Extensions` and enable "Laika AIAgent".

## 4) Use the sidecar

1. Click the Laika toolbar icon to toggle the attached sidecar panel in the current tab (scoped to the current Safari window). By default, the sidecar stays open as you switch tabs, appears on the right, and the open/closed state is saved in extension storage. If the sidecar can’t attach, Laika opens the UI as a standalone panel window.
2. Ask a question (e.g., "summarize this page") and click "Send".
3. Approve or reject any proposed actions inline in the chat.
4. Adjust sidecar preferences in `Safari` -> `Settings` -> `Extensions` -> `Laika` (sticky vs per-tab, left vs right).

## 5) Development + test process

Follow this loop for any change:

1. Update the relevant design doc (`src/laika/PLAN.md` or `docs/LaikaOverview.md`).
2. Implement and run local tests.
3. Run the automation harness scenarios.
4. Verify the build + logging, then ask for manual Safari testing.
5. Review logs and incorporate user feedback.

## 6) Automation harness

Safari UI harness (real Safari + extension + native app):

```bash
cd src/laika/automation_harness
scripts/run_safari_ui_test.sh --scenario scripts/scenarios/hn.json --output /tmp/laika-hn.json
```

Run the full UI harness suite (HN/BBC/SEC):

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation
```

Optional live-web smoke suite:

```bash
cd src/laika/automation_harness
scripts/run_all_safari_ui_tests.sh --output-dir /tmp/laika-automation --include-live
```

Legacy Playwright harness (DOM-only). Start the local plan server:

```bash
cd src/laika/app
swift run LaikaServer --port 8765 --model-dir ../extension/lib/models/Qwen3-0.6B-MLX-4bit
```

Run scenarios (HN/BBC live + SEC):

```bash
cd src/laika/automation_harness
node scripts/laika_harness.js --scenario scripts/scenarios/hn_live.json --output /tmp/laika-hn.json
node scripts/laika_harness.js --scenario scripts/scenarios/bbc_live.json --output /tmp/laika-bbc.json
node scripts/laika_harness.js --scenario scripts/scenarios/sec_nvda.json --output /tmp/laika-sec_nvda.json
```

## Notes

- Safari UI harness uses native messaging (no local HTTP server required); the Playwright harness uses `LaikaServer`.
- Default HN/BBC scenarios use local fixtures; live-web smoke scenarios are `hn_live.json` and `bbc_live.json`.
- MLX Swift LM requires macOS 14+ (Apple Silicon).
- Local logs are written under the sandbox container when running in Safari: `~/Library/Containers/com.laika.Laika.Extension/Data/Laika/logs/llm.jsonl` (host app: `~/Library/Containers/com.laika.Laika/Data/Laika/logs/llm.jsonl`). Non-sandboxed CLI/server runs default to `~/Laika/logs/llm.jsonl` and can be overridden with `LAIKA_HOME=/path`. Full prompt/output previews are enabled by default; set `LAIKA_LOG_FULL_LLM=0` to disable.
