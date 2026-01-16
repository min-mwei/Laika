#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import time
from typing import Literal

DEFAULT_MODEL_ID = "ai21labs/AI21-Jamba2-3B"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Hello world for ai21labs/AI21-Jamba2-3B (Transformers)",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL_ID, help="Hugging Face model id")
    parser.add_argument(
        "--device",
        default="auto",
        choices=["auto", "cpu", "mps", "cuda"],
        help="Device to run on (default: auto)",
    )
    parser.add_argument(
        "--dtype",
        default="auto",
        choices=["auto", "float16", "bfloat16", "float32"],
        help="Model dtype (default: auto)",
    )
    parser.add_argument(
        "--mps-fallback",
        action="store_true",
        help="Set PYTORCH_ENABLE_MPS_FALLBACK=1 before importing torch",
    )
    parser.add_argument(
        "--no-mamba-kernels",
        action="store_true",
        help="Force Transformers' naive Mamba path (required on non-CUDA devices)",
    )
    parser.add_argument(
        "--prompt",
        default="Say 'Hello world' and then one short sentence about what Jamba2 is.",
        help="User prompt",
    )
    parser.add_argument("--max-new-tokens", type=int, default=80)
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument(
        "--compile",
        action="store_true",
        help="Try torch.compile() (may or may not help on your setup)",
    )
    return parser.parse_args()


def _pick_device(torch, device_arg: str):
    if device_arg != "auto":
        return torch.device(device_arg)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _pick_dtype(torch, dtype_arg: str, device) -> "torch.dtype":
    if dtype_arg == "float16":
        return torch.float16
    if dtype_arg == "bfloat16":
        return torch.bfloat16
    if dtype_arg == "float32":
        return torch.float32

    # auto
    if device.type == "mps":
        return torch.float16
    if device.type == "cuda":
        return torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    return torch.float32


def _first_param_device(torch, model):
    try:
        return next(model.parameters()).device
    except StopIteration:
        return torch.device("cpu")


def main() -> int:
    args = _parse_args()

    if args.mps_fallback:
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

    device = _pick_device(torch, args.device)
    dtype = _pick_dtype(torch, args.dtype, device)

    if args.seed:
        torch.manual_seed(args.seed)

    try:
        torch.set_float32_matmul_precision("high")
    except Exception:
        pass

    model_kwargs = {"dtype": dtype}
    if device.type == "cuda":
        model_kwargs["device_map"] = "auto"
    else:
        model_kwargs["attn_implementation"] = "sdpa"

    print(
        f"Loading {args.model} on {device.type} (dtype={dtype})...",
        file=sys.stderr,
    )
    config = AutoConfig.from_pretrained(args.model)
    if hasattr(config, "use_mamba_kernels") and (args.no_mamba_kernels or device.type != "cuda"):
        config.use_mamba_kernels = False

    model = AutoModelForCausalLM.from_pretrained(args.model, config=config, **model_kwargs).eval()
    tokenizer = AutoTokenizer.from_pretrained(args.model)

    if device.type != "cuda":
        model.to(device)

    if args.compile and hasattr(torch, "compile"):
        model = torch.compile(model)

    messages: list[dict[Literal["role", "content"], str]] = [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": args.prompt},
    ]
    prompt_text = tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=False,
    )

    inputs = tokenizer(prompt_text, return_tensors="pt")
    input_device = _first_param_device(torch, model)
    inputs = {k: v.to(input_device) for k, v in inputs.items()}

    generate_kwargs = {
        "max_new_tokens": args.max_new_tokens,
        "pad_token_id": tokenizer.pad_token_id,
    }
    if args.temperature and args.temperature > 0:
        generate_kwargs.update(
            {
                "do_sample": True,
                "temperature": args.temperature,
                "top_p": args.top_p,
            }
        )
    else:
        generate_kwargs["do_sample"] = False

    start = time.time()
    with torch.inference_mode():
        output_ids = model.generate(**inputs, **generate_kwargs)
    elapsed_s = time.time() - start

    prompt_len = inputs["input_ids"].shape[-1]
    new_tokens = output_ids[0][prompt_len:]
    text = tokenizer.decode(new_tokens, skip_special_tokens=True).strip()

    print(text)
    print(f"[generated {len(new_tokens)} tokens in {elapsed_s:.2f}s]", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
