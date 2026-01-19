# Development + Testing

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
