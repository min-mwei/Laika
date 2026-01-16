#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Smoke test an MLX-converted LLM by loading it and generating a short response.",
    )
    parser.add_argument(
        "--model-dir",
        default="Qwen3-0.6B-MLX-4bit",
        help="Path to the local MLX model directory (default: %(default)s).",
    )
    parser.add_argument(
        "--prompt",
        default='Say "Hello world" and one short sentence.',
        help="Prompt to generate from.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=64,
        help="Maximum tokens to generate (default: %(default)s).",
    )
    parser.add_argument(
        "--enable-thinking",
        action="store_true",
        help="If supported by the tokenizer chat template, enable thinking mode.",
    )
    parser.add_argument(
        "--expect-substring",
        default="Hello",
        help="Fail unless the output contains this substring (default: %(default)s).",
    )
    parser.add_argument(
        "--mode",
        choices=["suite", "single"],
        default="suite",
        help="Run the built-in test suite or a single prompt (default: %(default)s).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print timing/throughput and stream tokens as they are generated.",
    )
    return parser.parse_args()


def _print_quant_info(model_dir: Path) -> None:
    config_path = model_dir / "config.json"
    if not config_path.exists():
        return
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        return
    quant = config.get("quantization") or config.get("quantization_config")
    if isinstance(quant, dict):
        bits = quant.get("bits")
        group_size = quant.get("group_size")
        mode = quant.get("mode")
        if bits is not None or group_size is not None or mode is not None:
            print(f"[INFO] quantization: bits={bits} group_size={group_size} mode={mode}")

def _strip_code_fences(text: str) -> str:
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    end = stripped.rfind("```")
    if end <= 0:
        return stripped
    inner = stripped[3:end].lstrip()
    # Remove optional language tag on the first line (e.g. "json")
    first_newline = inner.find("\n")
    if first_newline != -1:
        first_line = inner[:first_newline].strip()
        if re.fullmatch(r"[A-Za-z0-9_+-]+", first_line):
            inner = inner[first_newline + 1 :]
    return inner.strip()


def _extract_json_object(text: str) -> dict:
    cleaned = _strip_code_fences(text)
    try:
        return json.loads(cleaned)
    except Exception:
        pass

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("no JSON object found in output")
    return json.loads(cleaned[start : end + 1])


def _format_prompt(tokenizer, user_prompt: str, enable_thinking: bool) -> str:
    prompt = user_prompt
    if getattr(tokenizer, "chat_template", None) is not None:
        messages = [{"role": "user", "content": user_prompt}]
        try:
            prompt = tokenizer.apply_chat_template(
                messages,
                add_generation_prompt=True,
                enable_thinking=enable_thinking,
            )
        except TypeError:
            prompt = tokenizer.apply_chat_template(
                messages,
                add_generation_prompt=True,
            )
    return prompt


def _run_single(
    *,
    model,
    tokenizer,
    user_prompt: str,
    max_tokens: int,
    enable_thinking: bool,
    verbose: bool,
) -> str:
    from mlx_lm import generate

    prompt = _format_prompt(tokenizer, user_prompt, enable_thinking)
    return generate(
        model,
        tokenizer,
        prompt=prompt,
        max_tokens=max_tokens,
        verbose=verbose,
    ).strip()


def main() -> int:
    args = _parse_args()
    model_dir = Path(args.model_dir).expanduser().resolve()
    if not model_dir.exists():
        print(f"[ERROR] model dir not found: {model_dir}", file=sys.stderr)
        return 2

    _print_quant_info(model_dir)
    print(f"[INPUT] mode: {args.mode}")
    print(f"[INPUT] model_dir: {model_dir}")

    from mlx_lm import load

    model, tokenizer = load(str(model_dir))

    if args.mode == "single":
        print(f"[INPUT] prompt: {args.prompt}")
        print(f"[INPUT] max_tokens: {args.max_tokens}")
        print(f"[INPUT] enable_thinking: {args.enable_thinking}")

        output = _run_single(
            model=model,
            tokenizer=tokenizer,
            user_prompt=args.prompt,
            max_tokens=args.max_tokens,
            enable_thinking=args.enable_thinking,
            verbose=args.verbose,
        )
        print("[OUTPUT]")
        print(output)
        sys.stdout.flush()

        if not output:
            print("[ERROR] empty output", file=sys.stderr)
            return 3
        if args.expect_substring and args.expect_substring not in output:
            print(
                f"[ERROR] output missing expected substring: {args.expect_substring!r}",
                file=sys.stderr,
            )
            return 4

        print("[OK] smoke test passed")
        return 0

    # Suite mode
    tests = [
        {
            "name": "hello_world",
            "prompt": 'Say "Hello world!"',
            "max_tokens": 16,
            "expect_substrings": ["Hello world", "Hello World"],
            "case_insensitive": True,
        },
        {
            "name": "exact_text_abc123",
            "prompt": "Reply with exactly: ABC123",
            "max_tokens": 16,
            "expect_substrings": ["ABC123"],
            "case_insensitive": False,
        },
        {
            "name": "json_echo",
            "prompt": 'Return only valid JSON (no markdown): {"foo": 1, "bar": 2}',
            "max_tokens": 64,
            "expect_json": {"foo": 1, "bar": 2},
        },
        {
            "name": "single_word_paris",
            "prompt": "Reply with exactly one word: Paris",
            "max_tokens": 16,
            "expect_substrings": ["Paris"],
            "case_insensitive": True,
        },
    ]

    passed = 0
    for t in tests:
        name = t["name"]
        user_prompt = t["prompt"]
        max_tokens = int(t["max_tokens"])
        print(f"[TEST] {name}")
        print(f"[INPUT] prompt: {user_prompt}")
        print(f"[INPUT] max_tokens: {max_tokens}")
        print(f"[INPUT] enable_thinking: {args.enable_thinking}")

        output = _run_single(
            model=model,
            tokenizer=tokenizer,
            user_prompt=user_prompt,
            max_tokens=max_tokens,
            enable_thinking=args.enable_thinking,
            verbose=args.verbose,
        )

        print("[OUTPUT]")
        print(output)
        sys.stdout.flush()

        if not output:
            print(f"[ERROR] {name}: empty output", file=sys.stderr)
            return 3

        expect_json = t.get("expect_json")
        if expect_json is not None:
            try:
                obj = _extract_json_object(output)
            except Exception as e:
                print(f"[ERROR] {name}: JSON parse failed: {e}", file=sys.stderr)
                return 4
            for k, v in expect_json.items():
                if k not in obj:
                    print(f"[ERROR] {name}: JSON missing key {k!r}", file=sys.stderr)
                    return 4
                try:
                    if int(obj[k]) != int(v):
                        print(
                            f"[ERROR] {name}: JSON key {k!r} expected {v!r} got {obj[k]!r}",
                            file=sys.stderr,
                        )
                        return 4
                except Exception:
                    print(
                        f"[ERROR] {name}: JSON key {k!r} not an int: {obj[k]!r}",
                        file=sys.stderr,
                    )
                    return 4

        expect_regex = t.get("expect_regex")
        if expect_regex is not None:
            if re.search(expect_regex, output) is None:
                print(
                    f"[ERROR] {name}: output did not match regex {expect_regex!r}",
                    file=sys.stderr,
                )
                return 4

        expect_substrings = t.get("expect_substrings")
        if expect_substrings:
            out_cmp = output.lower() if t.get("case_insensitive") else output
            ok = False
            for s in expect_substrings:
                s_cmp = s.lower() if t.get("case_insensitive") else s
                if s_cmp in out_cmp:
                    ok = True
                    break
            if not ok:
                print(
                    f"[ERROR] {name}: output missing expected substring(s): {expect_substrings!r}",
                    file=sys.stderr,
                )
                return 4

        passed += 1

    print(f"[OK] smoke test passed ({passed}/{len(tests)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
