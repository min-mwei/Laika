# Qwen3-0.6B Programming Guide (Thinking, Tools, Streaming, Deployment)

This note compiles official guidance on programming `Qwen/Qwen3-0.6B` with Transformers, vLLM, SGLang, and Qwen-Agent. It focuses on chat templating, thinking control, tool calling, and common pitfalls.

## Quick facts

- Context length: 32,768 tokens (pretraining). Can be extended to 131,072 with YaRN RoPE scaling.
- Parameters: 0.6B, 28 layers, 16/8 heads (Q/KV), tied embeddings.
- License: Apache-2.0.
- Languages: 100+ languages and dialects across Qwen3.
- Transformers: >=4.51.0 required; torch >=2.6 recommended; GPU recommended.
- Default behavior: thinking mode enabled, outputs include a `<think>...</think>` block.

## Basic usage (Transformers)

### Pipeline (multi-turn)

```python
from transformers import pipeline

model_name = "Qwen/Qwen3-0.6B"
generator = pipeline(
    "text-generation",
    model_name,
    torch_dtype="auto",
    device_map="auto",
)

messages = [{"role": "user", "content": "Give me a short intro to LLMs."}]
messages = generator(messages, max_new_tokens=256)[0]["generated_text"]
```

### Manual generate (chat template)

```python
from transformers import AutoModelForCausalLM, AutoTokenizer

model_name = "Qwen/Qwen3-0.6B"
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    torch_dtype="auto",
    device_map="auto",
)

messages = [{"role": "user", "content": "Explain KV cache in 3 bullets. /no_think"}]
text = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True,
    enable_thinking=False,
)
inputs = tokenizer([text], return_tensors="pt").to(model.device)
output = model.generate(
    **inputs,
    max_new_tokens=256,
    do_sample=True,
    temperature=0.7,
    top_p=0.8,
    top_k=20,
)
print(tokenizer.decode(output[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True))
```

## Thinking control

### Hard switch: enable_thinking (recommended)

```python
text = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True,
    enable_thinking=False,  # True by default
)
```

### Soft switch: /think and /no_think (stateful)

When `enable_thinking=True`, add `/think` or `/no_think` to a system or user message. The most recent instruction wins across turns.

### Stateless one-turn disable (strict)

Transformers docs also show a stateless way to disable thinking for one turn by appending an assistant message that only contains:

```
<think>

</think>

```

This is strict for that single turn and does not affect later turns.

### Behavior notes

- With `enable_thinking=True`, responses always include a `<think>...</think>` block. If the user says `/no_think`, the block may be empty.
- With `enable_thinking=False`, `/think` and `/no_think` are ignored and no `<think>` block is emitted.

## Parsing thinking content

- Simple split: split on `</think>` and take the tail as the final answer.
- Token id method: the model card uses token id `151668` (</think>) to split output ids.
- Structured parse (from Qwen docs):

```python
import copy
import re

def parse_thinking_content(messages):
    messages = copy.deepcopy(messages)
    for message in messages:
        if message["role"] != "assistant":
            continue
        m = re.match(r"<think>\n(.+)</think>\n\n", message["content"], flags=re.DOTALL)
        if not m:
            continue
        message["content"] = message["content"][len(m.group(0)):]
        thinking = m.group(1).strip()
        if thinking:
            message["reasoning_content"] = thinking
    return messages
```

Best practice: do not keep thinking content in history. Store only the final answer in multi-turn chat.

## Sampling and repetition (best practices)

- Thinking mode: temperature 0.6, top_p 0.95, top_k 20, min_p 0. Do not use greedy decoding.
- Non-thinking mode: temperature 0.7, top_p 0.8, top_k 20, min_p 0.
- presence_penalty: tune in [0, 2]. Qwen suggests 1.5 when you see repetition.
- Output length: 32,768 tokens is recommended for most queries; for complex benchmark tasks, 38,912 tokens can help.
- Standardize outputs for evaluation (example: math prompts with `\boxed{}`; multiple choice using JSON `"answer": "C"`).

## Streaming

```python
from transformers import TextIteratorStreamer
import threading

text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
inputs = tokenizer([text], return_tensors="pt").to(model.device)

streamer = TextIteratorStreamer(tokenizer, skip_prompt=True, skip_special_tokens=True)
threading.Thread(target=model.generate, kwargs=dict(
    **inputs,
    streamer=streamer,
    max_new_tokens=256,
    do_sample=True,
    temperature=0.7,
    top_p=0.8,
    top_k=20,
)).start()

for chunk in streamer:
    print(chunk, end="", flush=True)
```

## OpenAI-compatible serving (vLLM and SGLang)

### vLLM

```bash
vllm serve Qwen/Qwen3-0.6B
```

Parsing reasoning into `reasoning_content`:

```bash
# vLLM 0.9.0+
vllm serve Qwen/Qwen3-0.6B --reasoning-parser qwen3

# vLLM 0.8.5 and earlier
vllm serve Qwen/Qwen3-0.6B --enable-reasoning --reasoning-parser deepseek_r1
```

Notes:

- `chat_template_kwargs.enable_thinking` is not part of the OpenAI API spec.
- As of vLLM 0.8.5, `enable_thinking=False` is not compatible with reasoning parsing; this is fixed with the `qwen3` parser in vLLM 0.9.0.
- To strictly disable thinking for all requests, use the provided `qwen3_nonthinking.jinja` chat template at server startup.

### SGLang

```bash
python -m sglang.launch_server --model-path Qwen/Qwen3-0.6B
python -m sglang.launch_server --model-path Qwen/Qwen3-0.6B --reasoning-parser qwen3
```

Notes:

- `enable_thinking` can be passed in `chat_template_kwargs` but it is not OpenAI API compatible.
- A custom `qwen3_nonthinking.jinja` template can enforce no-thinking at the server level.
- SGLang warns that `enable_thinking=False` may not be compatible with reasoning parsing.

### Raw HTTP (disable thinking, vLLM or SGLang)

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

## Tool and function calling

- Qwen3 recommends Hermes-style tool use for best function calling quality.
- Avoid stopword-based tool call templates (like ReAct) with reasoning models because stopwords can appear inside `<think>` content.
- Tool schema uses JSON Schema. Tool arguments are JSON-formatted strings in tool calls.
- The Qwen3 tokenizer chat template already includes Hermes tool use, so vLLM can parse tool calls with:

```bash
vllm serve Qwen/Qwen3-0.6B --enable-auto-tool-choice --tool-call-parser hermes --reasoning-parser qwen3
```

- Qwen-Agent wraps tool calling for Qwen3 and can sit on top of an OpenAI-compatible endpoint. It currently expects `functions` rather than `tools`:

```python
functions = [tool["function"] for tool in tools]
```

## Quantization notes

- Qwen3 provides FP8 and AWQ variants (check HF model list for `Qwen/Qwen3-<size>-FP8` and `Qwen/Qwen3-<size>-AWQ`).
- FP8 requires GPUs with compute capability > 8.9 (Ada Lovelace, Hopper, or newer).
- Transformers 4.51 has known issues with FP8 across GPUs; workarounds include `CUDA_LAUNCH_BLOCKING=1` or patching `finegrained_fp8.py`.

## Long context with YaRN (Transformers)

Qwen3 pretraining context is 32,768 tokens, but YaRN RoPE scaling can extend this to 131,072.

```json
{
  "max_position_embeddings": 131072,
  "rope_scaling": {
    "rope_type": "yarn",
    "factor": 4.0,
    "original_max_position_embeddings": 32768
  }
}
```

Notes:

- Transformers uses static YaRN; enable only when you need long context.
- As of Transformers 4.52.3, `rope_scaling.factor` may be overridden by `max_position_embeddings/original_max_position_embeddings`. See HF issue 38224.

## References

- Model card: https://huggingface.co/Qwen/Qwen3-0.6B
- Qwen3 blog: https://qwenlm.github.io/blog/qwen3/
- Qwen3 GitHub: https://github.com/QwenLM/Qwen3
- Qwen docs (Transformers): https://qwen.readthedocs.io/en/latest/inference/transformers.html
- Qwen docs (vLLM): https://qwen.readthedocs.io/en/latest/deployment/vllm.html
- Qwen docs (SGLang): https://qwen.readthedocs.io/en/latest/deployment/sglang.html
- Qwen docs (Function Calling): https://qwen.readthedocs.io/en/latest/framework/function_call.html
- Technical report: https://arxiv.org/abs/2505.09388
