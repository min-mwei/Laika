# Laika: Local LLM Runtime (Design Doc)

This document describes how Laika hosts, runs, and uses on-device models for agentic browsing in Safari, and how Laika can optionally ship improved model weights from a cloud training pipeline.

Laika’s product stance is **on-device by default**: Safari talks directly to websites; Laika keeps agent decisioning and safety filtering on your Mac by default. Optional BYO cloud models are supported, but they receive only **redacted context packs** and never cookies/session tokens.

Related:

- System boundaries + security posture: `docs/LaikaOverview.md`

---

## Goals

- **On-device decisioning by default** for:
  - planning + tool selection,
  - prompt-injection resistance checks,
  - input/output filtering and sensitive-field classification,
  - context-pack construction from SQLite run history.
- **Pluggable runtimes** so Laika can support multiple model formats and evolution over time.
- **Strong isolation and least privilege**:
  - local inference runs in sandboxed Swift processes (app and/or XPC worker),
  - inference workers can be configured with **no network entitlement**.
- **Long-running automation support**:
  - resumable runs (SQLite run log + checkpoints) even when Safari’s extension worker is suspended,
  - predictable cancellation/backpressure behavior across IPC.
- **Model updateability**:
  - allow Laika to ship improved local models (or adapters) as signed artifacts,
  - allow rollback and deterministic provenance.

## Prototype logging (local)

- Laika creates a `Laika/` folder with subfolders: `logs/`, `db/`, and `audit/`.
- In sandboxed builds, the home directory resolves to the container, so logs live under `~/Library/Containers/com.laika.Laika.Extension/Data/Laika/` (Safari extension) or `~/Library/Containers/com.laika.Laika/Data/Laika/` (host app).
- Non-sandboxed CLI/server runs default to `~/Laika/`; `LAIKA_HOME=/path/to/Laika` overrides only in those runs.
- LLM traces are written to `<base>/logs/llm.jsonl` (JSONL, append-only).
- If the preferred location is blocked, Laika falls back to Application Support under the container (for example: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Laika/`).
- Full prompt/output logging is enabled by default; set `LAIKA_LOG_FULL_LLM=0` to store only counts/metadata.
- The automation harness uses `laika-server` (SwiftPM executable) to host the same Agent Core + ModelRunner outside Safari for test runs.

## Qwen3 output length

- Qwen3-0.6B advertises a 32,768 token context window; Laika caps `maxTokens` by default to keep local latency reasonable.
- Increase `maxTokens` only when needed (summary truncation) and monitor latency, memory, and battery impact.

## Non-goals (initially)

- A “general RAG product” or persistent corpus retrieval system. (Laika may compute embeddings internally for scoring/deduping/ranking, but it does not ship a user-facing retrieval subsystem.)
- Running arbitrary Hugging Face code in-process (no Python plugin system inside the app).
- Supporting every open-weights architecture on day one; model support is gated by runtime compatibility and security review.

---

## High-level architecture

### Process placement (security + performance)

Local inference must not run inside Safari’s JS extension environment. Laika runs models in Swift; the current prototype and the target architecture differ in where that Swift code lives.

**Prototype (current):**

```text
Safari WebExtension (JS) ──native messaging──▶ SafariWebExtensionHandler (Swift)
                                               │
                                               ├── Agent Orchestrator + SummaryService
                                               └── ModelRunner (MLX/Qwen3)
```

**Target (planned):**

```text
Safari WebExtension (JS) ──native messaging──▶ Native app extension handler
                                               │
                                               └──IPC──▶ Agent Core (Swift)
                                                          │
                                                          └──XPC──▶ LLM Worker (Swift; GPU/Metal; no network)
```

Design constraints:

- **LLM Worker is the “compute boundary”**: heavy inference, tokenization, and (optional) embeddings live here.
- **Agent Core is the “policy boundary”**: prompts, tool schemas, redaction, and Policy Gate enforcement live here.
- **No secrets in JS**: the extension never sees cookies/session tokens, API keys, decrypted artifacts, or model weights.

### Core components

- **Model Manager (Agent Core)**:
  - installs/removes model packs,
  - verifies signatures/hashes,
  - tracks compatibility with tool schema versions,
  - exposes “available models” to settings/UI.
- **LLM Worker (XPC)**:
  - loads one model at a time (or a small bounded pool),
  - runs inference with streaming tokens,
  - provides guided/structured decoding for tool calls,
  - enforces strict memory/latency budgets and supports cancellation.
- **Prompt + Context Pack Builder (Agent Core)**:
  - constructs model input from the SQLite run log/checkpoints,
  - applies redaction and “data vs instruction” separation,
  - strips “thinking traces” from persisted history.

---

## Model roles inside Laika

Laika should treat “the model” as multiple roles with different safety/perf requirements:

1. **Guard / Policy helper (always local)**
   - Sensitive-field detection (credentials, payment, health, identifiers).
   - Prompt-injection heuristics (instruction vs data separation signals).
   - Output filtering: block data exfil, block disallowed tool calls, classify risk.
   - Target: low latency, small footprint, deterministic outputs.

2. **Planner / Tool user (local by default; cloud optional)**
   - Converts user intent + observations into a plan.
   - Emits typed tool calls (not free-form actions).
   - Target: strong tool-use reliability with constrained autonomy.

3. **Summarizer / Explainer (local by default; cloud optional)**
   - Produces user-facing explanations, citations, and audit summaries.
   - Must be constrained to “what was observed” and “what is about to happen”.

4. **Embeddings (optional; local)**
   - Similarity/deduping/ranking within a single run (e.g., picking candidate snippets).
   - Not a user-facing RAG system.

In MVP, roles (2) and (3) can share one “main” model; roles (1) and (4) may be separate smaller models if needed for latency.

---

## Current Qwen3 usage (prototype)

- Model: `Qwen3-0.6B-MLX-4bit` loaded from `src/laika/extension/lib/models/`.
- Planning: JSON-only LLMCP prompt; `enableThinking` is disabled to avoid non-JSON preambles. Plan budgets are small (roughly 256-384 tokens) for latency.
- Goal parsing: uses short budgets (72-128 tokens) to keep intent extraction fast; intent decomposition is model-driven with only minimal fallback for ordinals/comment hints on parse failure.
- Summaries: the model returns `assistant.render` directly in the LLMCP response; Agent Core applies grounding checks before returning.
- Streaming: the prototype UI renders a single response per plan turn (no summary streams).

## Model formats and runtimes

Laika should support multiple runtimes behind a single Swift protocol (e.g., `ModelRuntime`), so “model choice” doesn’t leak into the rest of the agent.

### GGUF (llama.cpp family)

**Use when:** we want wide BYO-model support, quantized weights, and predictable standalone inference on macOS.

- Example: `ai21labs/AI21-Jamba-Reasoning-3B-GGUF` (GGUF model pack; supported by llama.cpp / LM Studio / Ollama).
- Benefits:
  - straightforward on-device distribution (single file + metadata),
  - quantization options (size/quality tradeoff),
  - can use Metal acceleration in llama.cpp builds.
- Risks:
  - runtime must support the model architecture; “GGUF exists” is not enough by itself.
  - parser/loader is an attack surface; treat third-party weights as untrusted inputs.

**Implementation approach**

- Vendor a pinned, audited llama.cpp version as a static library.
- Wrap it in the LLM Worker with:
  - strict input size limits,
  - grammar-guided JSON decoding for tool calls,
  - cancellation + timeout enforcement,
  - memory pressure handling (unload/reload safely).

### Core ML (.mlmodelc)

**Use when:** we want the fastest and most Apple-native execution (ANE/GPU/CPU), especially for small “guard” and embedding models.

- Benefits:
  - good sandbox story and predictable macOS deployment,
  - performance via ANE/Metal,
  - aligns with “no network” worker configuration.
- Risks:
  - not all architectures convert cleanly,
  - conversion/tooling cost (quantization, attention kernels, long-context variants).

### MLX (current prototype)

**Use when:** we want strong Metal acceleration with open model compatibility (especially Qwen-family weights).

- Current prototype uses MLX for Qwen3-0.6B (4-bit) inside the Safari extension handler.
- Long-term, MLX can remain the default local runtime, with GGUF/Core ML as optional alternatives.

---

## Model selection and user experience

### Default model tiers

Recommend shipping 2–3 “tiers” instead of letting users pick from dozens:

- **Fast (default)**: small tool-using model for local planning + guard (lowest latency).
- **Reasoning**: medium model (3B–4B) for harder planning and longer tasks.
- **Cloud (optional)**: BYO OpenAI/Anthropic for maximum quality; still uses local guard + local policy enforcement.

### BYO models (advanced)

Support importing models as a deliberate “advanced” flow:

- Accept:
  - local GGUF files (user-selected),
  - optional “download from Hugging Face repo” via explicit user action.
- Always:
  - verify SHA-256,
  - store in app container,
  - show model provenance (repo, revision, hash),
  - require a “model trust” confirmation for third-party weights.

---

## Prompting + tool calling (reliability)

### Tool-only contract

All models must be constrained to “request tools” rather than “perform actions”.

Laika should use:

- **Structured tool schemas** (versioned JSON schema).
- **Guided decoding** for tool calls where supported (e.g., llama.cpp grammar).
- **Strict parsing**: invalid tool calls are rejected and counted as a model failure.

### Thinking traces

If the model emits “thinking” tokens (e.g., Qwen3’s `<think>...</think>`), Laika should:

- treat them as ephemeral and never store them in SQLite run history by default,
- store only:
  - the final tool call (structured),
  - the user-facing explanation (short and auditable).

This aligns with Qwen3’s own best practice: multi-turn history should contain only the final response, not the thinking content.

---

## Context window management (SQLite-backed)

Even if a model supports very long contexts (e.g., Jamba Reasoning 3B advertises **256K tokens**), Laika should still manage context aggressively:

- long contexts increase latency and cost (battery/thermals) and can increase data-exposure surface,
- most browsing tasks benefit more from **structured observations** than raw page dumps.

### Context pack builder rules

The Agent Core should build a per-step context pack from SQLite:

- **Always include**:
  - user intent + constraints (mode, allowed tools),
  - current verified origin + risk label,
  - recent observations (budgeted `observe_dom` summaries),
  - last N tool calls/results relevant to the current page.
- **Optionally include** (if needed and policy allows):
  - a rolling summary of older steps,
  - selected excerpts (redacted),
  - checkpoint metadata for safe rollback.
- **Never include by default**:
  - cookies/session tokens,
  - raw form values for sensitive fields,
  - decrypted artifacts beyond what’s needed for the current step.

### Long-context modes

Provide an explicit “Long context” mode for power users and specific tasks:

- Raise `n_ctx` (GGUF runtime) or enable YaRN/RoPE scaling (Qwen) only when needed.
- Keep separate performance guardrails (caps on tokens, timeouts, “stop if repeating” heuristics).
- Consider “read-only long context” (analysis/summarization) without enabling mutating tools.

---

## Performance + resource control

### Streaming

- LLM Worker streams tokens to Agent Core.
- Agent Core streams only small, safe UI deltas to the extension/sidecar panel.

### Concurrency

- Single GPU-backed inference queue by default (prevents runaway contention).
- Multiple runs are supported, but model compute is serialized or budgeted.

### Cancellation and timeouts

- Every inference request has `{requestId, deadlineMs}`.
- Cancellation propagates Agent Core → LLM Worker immediately.
- Timeouts fail safe: if the planner times out, downgrade autonomy (Observe-only) and ask the user.

---

## Security considerations specific to local models

Local inference reduces data egress, but it does not remove risk:

- **Model weights as untrusted input** (BYO): treat downloaded GGUF files as hostile until verified.
  - Load only in a sandboxed worker.
  - Validate headers, enforce size limits, and keep parsers up-to-date.
- **Prompt injection remains a threat**:
  - local models can still be induced to request unsafe tools,
  - therefore Policy Gate + capability tokens remain mandatory.
- **No network worker**:
  - configure the LLM Worker with no network entitlement where feasible,
  - keep any model download/update code out of that worker.

---

## Example model integrations

### AI21 Jamba Reasoning 3B (GGUF)

Source: https://huggingface.co/ai21labs/AI21-Jamba-Reasoning-3B-GGUF

Key properties from the model card:

- 3B parameters; hybrid Transformer–Mamba.
- Advertised **256K context**.
- GGUF quantizations (example sizes):
  - FP16: ~6.4 GB
  - Q4_K_M: ~1.93 GB
- License: Apache 2.0.
- Supported runtimes: llama.cpp, LM Studio, Ollama.

Laika guidance:

- Treat this as a “Reasoning tier” local planner candidate.
- Default to smaller practical contexts (e.g., 8K–32K) for responsiveness; enable long-context mode selectively.
- Prefer grammar-guided tool-call decoding to reduce invalid JSON and improve automation stability.

### Qwen3-4B

Source: https://huggingface.co/Qwen/Qwen3-4B

Key properties from the model card:

- 4.0B parameters.
- Context length: **32,768** natively; validated up to **131,072** tokens with YaRN (RoPE scaling).
- “Thinking” vs “non-thinking” mode via `enable_thinking` and prompt tags (`/think`, `/no_think`).
- Best practice: omit thinking content from multi-turn history.

Laika guidance:

- Treat this as a “Reasoning tier” local planner candidate with strong agent/tool capabilities.
- Use “thinking mode” internally when planning, but persist only structured tool calls and user-facing rationales.
- Enable YaRN only in explicit long-context mode (it can degrade short-context performance).
- Use repetition guardrails (presence penalty / stop-on-repeat heuristics) when running long outputs.

---

## Cloud training + fine-tuning pipeline (offline → signed updates)

Laika can improve local tool-use reliability over time via an offline cloud pipeline that produces **signed model artifacts** for download to devices.

### Principles

- **Opt-in data** only. No silent collection of raw browsing content.
- **Redaction first**: training data should be de-identified and scrubbed of secrets.
- **Separation of concerns**:
  - training happens in the cloud,
  - execution/policy remains local on the device.
- **Rollbackable updates**: every model update is versioned and reversible.

### Data sources (ranked by privacy safety)

1. **Synthetic tool trajectories** generated from a teacher model and validated by deterministic checks.
2. **Adversarial test corpus** (prompt injection pages, malicious DOM content) + expected safe behaviors.
3. **Opt-in user traces** (strictly redacted):
   - store tool calls/results and policy decisions,
   - store only derived, non-sensitive observations (or hashed/templated placeholders),
   - never store cookies/session tokens or typed secrets.

### Training approaches

- **SFT (supervised fine-tuning)** on tool-call traces:
  - focus on emitting valid schemas, correct tool selection, and safe “ask/deny” behavior.
- **Preference optimization** (DPO/ORPO) on “good vs bad” trajectories:
  - penalize unsafe actions, cross-site leakage, and invalid tool outputs.
- **RL (later)** for robustness:
  - reward successful completion with minimal tool calls under policy constraints,
  - heavily penalize policy violations and injection-following behavior.

### Artifact types to ship

- **LoRA / adapter weights** (preferred when runtime supports it):
  - small downloads, fast rollbacks.
- **Merged + quantized model** (GGUF):
  - best for llama.cpp runtime consistency.
- **Core ML packages** for small guard/embedding models:
  - optimized for ANE/GPU; can be updated independently.

### Signing, distribution, rollback

- Every artifact is signed by the Laika Model Service.
- Device verifies:
  - signature,
  - SHA-256,
  - compatibility constraints (`minAppVersion`, `toolSchemaVersion`, runtime type).
- Updates are staged:
  - canary → gradual rollout → broad.
- Rollback is one click:
  - keep last known-good model and last N versions.

### Evaluation gates (must-pass)

- Tool-call validity rate (JSON schema) above a threshold.
- Safety test suite:
  - prompt injection pages,
  - cross-origin data exfil attempts,
  - “tool misuse” adversaries.
- Regression tests on common browsing flows (observe → find → click → type → verify).

---

## Open questions / decisions to validate

- Primary runtime choice for MVP: “GGUF/llama.cpp only” vs “GGUF + Core ML guard”.
- Exact “no network” configuration feasibility for the LLM Worker under App Sandbox constraints.
- Practical maximum contexts on Apple Silicon (latency + memory) for:
  - Qwen3-4B at 32K+ contexts,
  - Jamba 3B at 64K/128K/256K contexts.
- Whether to ship LoRA/adapters vs full merged models for the first cloud training iteration.
