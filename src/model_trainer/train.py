#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Sequence

import torch
from datasets import load_dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    DataCollatorForSeq2Seq,
    Trainer,
    TrainingArguments,
    set_seed,
)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Full fine-tuning for Qwen3-0.6B on JSONL chat data.",
    )
    parser.add_argument(
        "--model-name",
        default="Qwen/Qwen3-0.6B",
        help="Base model name or local path.",
    )
    parser.add_argument(
        "--train-file",
        default="data/train.jsonl",
        help="Path to training JSONL file.",
    )
    parser.add_argument(
        "--eval-file",
        default="data/test.jsonl",
        help="Path to eval JSONL file.",
    )
    parser.add_argument(
        "--output-dir",
        default="Qwen3-0.6B-finetuned",
        help="Output directory for the fine-tuned model.",
    )
    parser.add_argument("--max-seq-length", type=int, default=2048)
    parser.add_argument("--num-train-epochs", type=int, default=3)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--per-device-eval-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--weight-decay", type=float, default=0.0)
    parser.add_argument("--warmup-steps", type=int, default=0)
    parser.add_argument("--logging-steps", type=int, default=10)
    parser.add_argument("--save-total-limit", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--bf16", action="store_true")
    parser.add_argument("--fp16", action="store_true")
    parser.add_argument("--gradient-checkpointing", action="store_true")
    parser.add_argument("--resume-from-checkpoint", default=None)
    parser.add_argument("--no-mask-user-tokens", dest="mask_user_tokens", action="store_false")
    parser.set_defaults(mask_user_tokens=True)
    parser.add_argument(
        "--enable-thinking",
        action="store_true",
        help="Pass enable_thinking to the chat template when supported.",
    )
    parser.add_argument("--no-trust-remote-code", dest="trust_remote_code", action="store_false")
    parser.set_defaults(trust_remote_code=True)
    return parser.parse_args()


def _ensure_messages(example: Dict[str, Any]) -> List[Dict[str, str]]:
    if "messages" in example:
        messages = example["messages"]
    elif "prompt" in example and "response" in example:
        messages = [
            {"role": "user", "content": example["prompt"]},
            {"role": "assistant", "content": example["response"]},
        ]
    else:
        raise ValueError("Each JSONL entry must include 'messages' or ('prompt' and 'response').")

    if not isinstance(messages, Sequence) or not messages:
        raise ValueError("messages must be a non-empty list.")
    normalized: List[Dict[str, str]] = []
    for msg in messages:
        if not isinstance(msg, dict):
            raise ValueError("Each message must be an object with role/content.")
        role = msg.get("role")
        content = msg.get("content")
        if not isinstance(role, str) or not isinstance(content, str):
            raise ValueError("Each message must include string role/content.")
        normalized.append({"role": role, "content": content})
    return normalized


def _apply_chat_template(
    tokenizer: AutoTokenizer,
    messages: List[Dict[str, str]],
    *,
    tokenize: bool,
    add_generation_prompt: bool,
    enable_thinking: bool,
) -> List[int]:
    if enable_thinking:
        try:
            return tokenizer.apply_chat_template(
                messages,
                tokenize=tokenize,
                add_generation_prompt=add_generation_prompt,
                enable_thinking=True,
            )
        except TypeError:
            pass
    return tokenizer.apply_chat_template(
        messages,
        tokenize=tokenize,
        add_generation_prompt=add_generation_prompt,
    )


def _tokenize_chat(
    tokenizer: AutoTokenizer,
    messages: List[Dict[str, str]],
    max_seq_length: int,
    mask_user_tokens: bool,
    enable_thinking: bool,
) -> Dict[str, List[int]]:
    full_ids = _apply_chat_template(
        tokenizer,
        messages,
        tokenize=True,
        add_generation_prompt=False,
        enable_thinking=enable_thinking,
    )
    if not isinstance(full_ids, list):
        full_ids = list(full_ids)

    labels = [-100] * len(full_ids)
    if mask_user_tokens:
        prefix_len = 0
        for idx, msg in enumerate(messages):
            prefix_ids = _apply_chat_template(
                tokenizer,
                messages[: idx + 1],
                tokenize=True,
                add_generation_prompt=False,
                enable_thinking=enable_thinking,
            )
            if not isinstance(prefix_ids, list):
                prefix_ids = list(prefix_ids)
            if msg["role"] == "assistant":
                end = min(len(prefix_ids), len(labels))
                for pos in range(prefix_len, end):
                    labels[pos] = full_ids[pos]
            prefix_len = len(prefix_ids)
    else:
        labels = full_ids.copy()

    if max_seq_length and len(full_ids) > max_seq_length:
        full_ids = full_ids[:max_seq_length]
        labels = labels[:max_seq_length]

    attention_mask = [1] * len(full_ids)
    return {"input_ids": full_ids, "labels": labels, "attention_mask": attention_mask}


def _write_training_stats(
    output_dir: Path,
    args: argparse.Namespace,
    train_metrics: Dict[str, Any],
    eval_metrics: Dict[str, Any],
    train_samples: int,
    eval_samples: int,
) -> None:
    stats = {
        "model_name": args.model_name,
        "train_file": args.train_file,
        "eval_file": args.eval_file,
        "train_samples": train_samples,
        "eval_samples": eval_samples,
        "max_seq_length": args.max_seq_length,
        "timestamp_utc": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "training_args": {
            "num_train_epochs": args.num_train_epochs,
            "per_device_train_batch_size": args.per_device_train_batch_size,
            "per_device_eval_batch_size": args.per_device_eval_batch_size,
            "gradient_accumulation_steps": args.gradient_accumulation_steps,
            "learning_rate": args.learning_rate,
            "weight_decay": args.weight_decay,
            "warmup_steps": args.warmup_steps,
            "bf16": args.bf16,
            "fp16": args.fp16,
            "gradient_checkpointing": args.gradient_checkpointing,
            "enable_thinking": args.enable_thinking,
        },
        "metrics": {
            "train": train_metrics,
            "eval": eval_metrics,
        },
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    with (output_dir / "training_stats.json").open("w", encoding="utf-8") as f:
        json.dump(stats, f, indent=2, sort_keys=True)
        f.write("\n")


def main() -> int:
    args = _parse_args()
    set_seed(args.seed)

    train_path = Path(args.train_file)
    eval_path = Path(args.eval_file)
    if not train_path.exists():
        raise FileNotFoundError(f"train file not found: {train_path}")
    if not eval_path.exists():
        raise FileNotFoundError(f"eval file not found: {eval_path}")

    tokenizer = AutoTokenizer.from_pretrained(
        args.model_name,
        trust_remote_code=args.trust_remote_code,
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model_name,
        trust_remote_code=args.trust_remote_code,
        torch_dtype=torch.bfloat16 if args.bf16 else (torch.float16 if args.fp16 else None),
    )
    if args.gradient_checkpointing:
        model.gradient_checkpointing_enable()
        model.config.use_cache = False

    raw_datasets = load_dataset(
        "json",
        data_files={"train": str(train_path), "eval": str(eval_path)},
    )

    def _map_fn(example: Dict[str, Any]) -> Dict[str, List[int]]:
        messages = _ensure_messages(example)
        return _tokenize_chat(
            tokenizer=tokenizer,
            messages=messages,
            max_seq_length=args.max_seq_length,
            mask_user_tokens=args.mask_user_tokens,
            enable_thinking=args.enable_thinking,
        )

    tokenized = raw_datasets.map(
        _map_fn,
        remove_columns=raw_datasets["train"].column_names,
    )

    data_collator = DataCollatorForSeq2Seq(
        tokenizer=tokenizer,
        padding=True,
        label_pad_token_id=-100,
    )

    training_args = TrainingArguments(
        output_dir=args.output_dir,
        num_train_epochs=args.num_train_epochs,
        per_device_train_batch_size=args.per_device_train_batch_size,
        per_device_eval_batch_size=args.per_device_eval_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        weight_decay=args.weight_decay,
        warmup_steps=args.warmup_steps,
        logging_steps=args.logging_steps,
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=args.save_total_limit,
        fp16=args.fp16,
        bf16=args.bf16,
        report_to="none",
        remove_unused_columns=False,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized["train"],
        eval_dataset=tokenized["eval"],
        data_collator=data_collator,
        tokenizer=tokenizer,
    )

    train_result = trainer.train(resume_from_checkpoint=args.resume_from_checkpoint)
    trainer.save_model(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)
    trainer.save_state()

    train_metrics = train_result.metrics
    trainer.save_metrics("train", train_metrics)

    eval_metrics = trainer.evaluate()
    trainer.save_metrics("eval", eval_metrics)

    _write_training_stats(
        output_dir=Path(args.output_dir),
        args=args,
        train_metrics=train_metrics,
        eval_metrics=eval_metrics,
        train_samples=len(tokenized["train"]),
        eval_samples=len(tokenized["eval"]),
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
