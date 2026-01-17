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

## 2) Build and run the macOS app + extension

Open the Xcode project:

- `src/laika/LaikaApp/Laika/Laika.xcodeproj`

Build and run the `Laika` app target. The app hosts the extension; you must run it once to enable the extension in Safari.

## 3) Enable the Safari extension

1. Open Safari and enable the Develop menu (`Safari` -> `Settings` -> `Advanced` -> "Show Develop menu").
2. Open `Safari` -> `Settings` -> `Extensions` and enable "Laika AIAgent".

## 4) Use the popover

1. Click the Laika toolbar icon.
2. Ask a question (e.g., "summarize this page") and click "Send".
3. Approve or reject any proposed actions inline in the chat.

## Notes

- Native messaging is used for JS -> Swift communication; no local HTTP server is required.
- MLX Swift LM requires macOS 14+ (Apple Silicon).
