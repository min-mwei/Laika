# Qwen3-0.6B: Practical One‑Pager (Thinking, Streaming, Repetition)

This note is a compact set of patterns for using `Qwen/Qwen3-0.6B` effectively: **thinking vs non-thinking**, **streaming**, and **repetition mitigation**.

## Quick facts

- Context length: 32,768 tokens
- License: Apache-2.0
- Requires `transformers>=4.51.0` (older versions may raise `KeyError: 'qwen3'`)

## Thinking vs non-thinking mode

### Hard switch (recommended): `enable_thinking`

Qwen3 “thinking mode” is on by default. In Transformers, control it via the chat template:

```python
text = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True,
    enable_thinking=False,  # non-thinking mode
)
```

- `enable_thinking=True`: model may emit a `<think>...</think>` block followed by the final answer.
- `enable_thinking=False`: model will not generate the `<think>...</think>` block.

### Soft switch (per-turn): `/think` and `/no_think`

When `enable_thinking=True`, you can toggle thinking on a per-message basis by adding `/think` or `/no_think` in a user or system message (the most recent instruction wins):

```python
messages = [
  {"role": "system", "content": "You are concise."},
  {"role": "user", "content": "Explain attention in one sentence. /no_think"},
  {"role": "user", "content": "Now solve 38*47 and show work. /think"},
]
```

### Best practice: don’t keep thinking content in history

In multi-turn chat, keep only the final answer in history (exclude `<think>...</think>`). If you use Qwen’s official Jinja chat template, it will strip thinking content from assistant messages when formatting history; if you don’t, strip it yourself before saving.

## Local inference (Transformers)

### Minimal chat (non-thinking)

```python
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL = "Qwen/Qwen3-0.6B"
tokenizer = AutoTokenizer.from_pretrained(MODEL)
model = AutoModelForCausalLM.from_pretrained(MODEL, torch_dtype="auto", device_map="auto")

messages = [{"role": "user", "content": "Explain KV cache in 3 bullets. /no_think"}]
text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
inputs = tokenizer([text], return_tensors="pt").to(model.device)

out = model.generate(
    **inputs,
    max_new_tokens=256,
    do_sample=True,
    temperature=0.7,
    top_p=0.8,
    top_k=20,
    repetition_penalty=1.1,
)
print(tokenizer.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True))
```

### Thinking mode + extracting `<think>...</think>`

```python
messages = [{"role": "user", "content": "Solve 38*47 and show your work. /think"}]
text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=True)
inputs = tokenizer([text], return_tensors="pt").to(model.device)

out = model.generate(
    **inputs,
    max_new_tokens=512,
    do_sample=True,
    temperature=0.6,
    top_p=0.95,
    top_k=20,
)
decoded = tokenizer.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)

thinking, answer = "", decoded
if "</think>" in decoded:
    before, after = decoded.split("</think>", 1)
    thinking = before.split("<think>", 1)[-1].strip()
    answer = after.strip()

print("answer:", answer)
```

### Streaming (token-by-token) with `TextIteratorStreamer`

```python
from transformers import TextIteratorStreamer
import threading

messages = [{"role": "user", "content": "Explain KV cache in 3 bullets. /no_think"}]
text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
inputs = tokenizer([text], return_tensors="pt").to(model.device)

streamer = TextIteratorStreamer(tokenizer, skip_prompt=True, skip_special_tokens=True)
gen_kwargs = dict(
    **inputs,
    streamer=streamer,
    max_new_tokens=256,
    do_sample=True,
    temperature=0.7,
    top_p=0.8,
    top_k=20,
)
threading.Thread(target=model.generate, kwargs=gen_kwargs).start()
for chunk in streamer:
    print(chunk, end="", flush=True)
```

## Serving via an OpenAI-compatible endpoint (vLLM / SGLang)

### Run a server

```bash
# vLLM (OpenAI-compatible API at http://localhost:8000/v1 by default)
vllm serve Qwen/Qwen3-0.6B

# Optional: split thinking content into `reasoning_content` (not OpenAI API compatible)
# vLLM>=0.9.0:
vllm serve Qwen/Qwen3-0.6B --reasoning-parser qwen3
# vLLM<=0.8.x:
vllm serve Qwen/Qwen3-0.6B --enable-reasoning --reasoning-parser deepseek_r1

# SGLang (OpenAI-compatible API at http://localhost:30000/v1 by default)
python -m sglang.launch_server --model-path Qwen/Qwen3-0.6B
```

### Raw HTTP: disable thinking (hard switch)

`chat_template_kwargs.enable_thinking` is not part of the OpenAI API spec, but vLLM/SGLang support it:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role":"user","content":"Explain transformers in 3 bullets. /no_think"}],
    "temperature": 0.7,
    "top_p": 0.8,
    "top_k": 20,
    "max_tokens": 256,
    "presence_penalty": 1.5,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

### Python OpenAI SDK (streaming) + disabling thinking

`enable_thinking` is a chat-template feature, not part of the OpenAI API spec. vLLM/SGLang expose it via a non-standard extension (example below).

```python
from openai import OpenAI

client = OpenAI(api_key="EMPTY", base_url="http://localhost:8000/v1")
stream = client.chat.completions.create(
    model="Qwen/Qwen3-0.6B",
    messages=[{"role": "user", "content": "Explain transformers in 3 bullets. /no_think"}],
    stream=True,
    temperature=0.7,
    top_p=0.8,
    presence_penalty=1.5,  # helps if you see endless repetitions
    extra_body={
        "top_k": 20,
        "chat_template_kwargs": {"enable_thinking": False},
    },
)
for chunk in stream:
    delta = chunk.choices[0].delta.content or ""
    if delta:
        print(delta, end="", flush=True)
print()
```

## Repetition / “endless loop” checklist

- Don’t use greedy decoding in thinking mode; use sampling.
- Use Qwen’s recommended sampling presets:
  - Thinking: `temperature=0.6`, `top_p=0.95`, `top_k=20`
  - Non-thinking: `temperature=0.7`, `top_p=0.8`, `top_k=20`
- If supported by your runtime, tune `presence_penalty` in `[0, 2]` (Qwen suggests `1.5` when you see endless repetitions; higher values can cause occasional language mixing).
- Always set a sane `max_new_tokens`/`max_tokens` and constrain format (“3 bullets, <50 words”) to prevent run-on output.

## References

- Model card: https://huggingface.co/Qwen/Qwen3-0.6B
- Blog: https://qwenlm.github.io/blog/qwen3/
- GitHub: https://github.com/QwenLM/Qwen3
- Docs: https://qwen.readthedocs.io/en/latest/
- Technical report (arXiv): https://arxiv.org/abs/2505.09388
