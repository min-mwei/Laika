#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import platform
import shutil
import sys
from pathlib import Path


DEFAULT_HF_MODEL = "Qwen/Qwen3-0.6B"
DEFAULT_OUT_DIR = "Qwen3-0.6B-MLX-4bit"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Qwen/Qwen3-0.6B to an MLX 4-bit model directory.",
    )
    parser.add_argument(
        "--hf-model",
        default=DEFAULT_HF_MODEL,
        help="Hugging Face model id or local path (default: %(default)s)",
    )
    parser.add_argument(
        "--revision",
        default=None,
        help="Optional Hugging Face revision (branch/tag/commit).",
    )
    parser.add_argument(
        "--out-dir",
        default=DEFAULT_OUT_DIR,
        help="Output directory to create (default: %(default)s). Must not exist unless --overwrite is set.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Delete --out-dir first if it already exists.",
    )
    parser.add_argument(
        "--bits",
        type=int,
        default=4,
        help="Quantization bits (default: %(default)s).",
    )
    parser.add_argument(
        "--group-size",
        type=int,
        default=128,
        help="Quantization group size (default: %(default)s).",
    )
    parser.add_argument(
        "--q-mode",
        default="affine",
        choices=["affine", "mxfp4", "nvfp4", "mxfp8"],
        help="Quantization mode used by MLX (default: %(default)s).",
    )
    parser.add_argument(
        "--dtype",
        default=None,
        choices=["float16", "bfloat16", "float32"],
        help="Optional dtype for non-quantized parameters (default: model config's torch_dtype).",
    )
    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Trust remote code when loading tokenizer (HF).",
    )
    parser.add_argument(
        "--upload-repo",
        default=None,
        help="Optional Hugging Face repo id to upload the converted model to (e.g. 'org/name').",
    )
    parser.add_argument(
        "--hf-transfer",
        action="store_true",
        help="Enable hf_transfer fast downloads by setting HF_HUB_ENABLE_HF_TRANSFER=1 (requires `pip install hf_transfer`).",
    )
    parser.add_argument(
        "--allow-non-apple-silicon",
        action="store_true",
        help="Skip the Apple Silicon check (conversion still requires MLX).",
    )
    return parser.parse_args()


def _require_apple_silicon(allow_override: bool) -> None:
    if allow_override:
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit(
            "MLX conversion requires Apple Silicon (macOS arm64). "
            "Re-run with --allow-non-apple-silicon to skip this check."
        )


def _enable_hf_transfer_if_requested(enable: bool) -> None:
    if not enable:
        return
    os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
    try:
        import hf_transfer  # noqa: F401
    except Exception:
        print(
            "[WARN] --hf-transfer was set but `hf_transfer` is not installed. "
            "Run: pip install hf_transfer",
            file=sys.stderr,
        )


def _ensure_empty_dir(path: Path, overwrite: bool) -> None:
    if not path.exists():
        return
    if not overwrite:
        raise SystemExit(f"Refusing to overwrite existing path: {path} (use --overwrite)")
    shutil.rmtree(path)


def _copy_optional_files(hf_model_or_path: str, out_dir: Path, revision: str | None) -> None:
    patterns = [
        "LICENSE",
        "LICENSE.txt",
        "NOTICE",
        "NOTICE.txt",
        "vocab.json",
        "merges.txt",
    ]

    src_path = Path(hf_model_or_path)
    if src_path.exists():
        base_path = src_path
    else:
        from huggingface_hub import snapshot_download

        base_path = Path(
            snapshot_download(
                repo_id=hf_model_or_path,
                revision=revision,
                allow_patterns=patterns,
            )
        )

    for name in patterns:
        src = base_path / name
        dst = out_dir / name
        if src.exists() and not dst.exists():
            shutil.copy2(src, dst)


def main() -> int:
    args = _parse_args()
    _require_apple_silicon(args.allow_non_apple_silicon)
    _enable_hf_transfer_if_requested(args.hf_transfer)

    out_dir = Path(args.out_dir).expanduser().resolve()
    _ensure_empty_dir(out_dir, args.overwrite)

    from mlx_lm import convert as mlx_convert

    mlx_convert(
        hf_path=args.hf_model,
        mlx_path=str(out_dir),
        quantize=True,
        q_group_size=args.group_size,
        q_bits=args.bits,
        q_mode=args.q_mode,
        dtype=args.dtype,
        upload_repo=args.upload_repo,
        revision=args.revision,
        trust_remote_code=args.trust_remote_code,
    )

    _copy_optional_files(args.hf_model, out_dir, args.revision)
    print(f"[OK] Wrote MLX model to: {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
