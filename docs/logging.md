# Laika Logging + Audit (Design Doc)

This doc defines what Laika logs (and what it must not log) for the vNext "collections -> grounded chat -> transforms -> artifacts" workflow.

Goals:
- Make failures debuggable (capture issues, model JSON failures, tool validation, timeouts).
- Make behavior auditable (what ran, what data was used, what was shared).
- Preserve privacy by default (no raw HTML/cookies, redaction-first logging).
- Keep automation harness runs diagnosable and comparable over time.

Non-goals:
- Remote telemetry/analytics (P0 is local-only).
- Persisting full page content inside logs (captured source bodies live in SQLite).

Related:
- `docs/LaikaArch.md` (safety posture)
- `docs/llm_context_protocol.md` (LLMCP envelopes and tool calls)
- `docs/sqlite_schema_v1.sql` (`llm_runs`, `capture_jobs`, `artifacts`, `chat_events`)
- `docs/web_search.md` (search tool; query logging policy)

---

## 1) What is the source of truth?

Laika has three "persistence" layers with different purposes:

1) SQLite (source of truth)
- Collections, Sources (captured Markdown), CaptureJobs, ChatEvents, Artifacts.
- Optional `llm_runs` stores redacted request/response payloads + token/cost.

2) Append-only JSONL logs (debug/audit stream)
- High-frequency event stream for timing, failures, and operator debugging.
- Files live under `Laika/logs/` (see paths below).

3) OSLog / console logging (developer ergonomics)
- Helpful during local development, but not relied upon for audit.

Design rule: never rely on "logs" for user data correctness. Logs are diagnostic.

---

## 2) Log locations and files

Laika uses a single "Laika home" directory with subfolders:
- `logs/` (JSONL event streams)
- `db/` (SQLite)
- `audit/` (future: user-facing audit exports)

Resolved location depends on sandboxing:
- In sandboxed builds, home resolves inside the container.
- In non-sandboxed CLI/server runs, `LAIKA_HOME=/path/to/Laika` can override.

P0 log files:
- `logs/llm.jsonl`: primary JSONL stream (LLM traces + agent/tool/capture/transform events).

---

## 3) Redaction policy (privacy-first)

Hard invariants (must never appear in logs):
- Cookies, session tokens, Authorization headers, API keys.
- Raw HTML or full DOM dumps.

Default logging posture (recommended for release):
- Log counts, sizes, hashes, timing, and stable IDs.
- Avoid logging full user prompts, full captured Markdown, and full model outputs.

Developer override (for local debugging only):
- Allow short previews of prompts/outputs when explicitly enabled.
- Current prototype toggle: `LAIKA_LOG_FULL_LLM=0` disables previews.
- vNext decision: keep a toggle, but require explicit opt-in for previews in release builds.

Search query logging:
- Do not log full search queries unless the user/dev explicitly opts in (see `docs/web_search.md`).
- Prefer `query_hash` + `query_len` + engine + result count.

---

## 4) Event taxonomy (what we log)

Log everything as structured events with stable names and correlation IDs.

Recommended event types (directional):

- `run.started`, `run.finished`
- `collection.created`, `collection.activated`
- `source.added`, `source.removed`
- `capture.job_queued`, `capture.job_started`, `capture.job_succeeded`, `capture.job_failed`
- `llm.request`, `llm.response`, `llm.error`
- `tool.proposed`, `tool.approved`, `tool.denied`, `tool.executed`
- `transform.started`, `transform.completed`, `transform.failed`
- `artifact.opened`, `artifact.shared`

At minimum, every event should include:
- `timestamp` (ISO-8601 UTC)
- `type` (string)
- correlation IDs when available:
  - `run_id`, `conversation_id`
  - `collection_id`, `source_id`, `artifact_id`
  - `tool_call_id`, `request_id`
- `severity` (`info|warn|error`) (optional but recommended)
- `payload` object with typed fields (no raw HTML)

---

## 5) LLM logging (LLMCP-aware)

We need enough observability to debug:
- invalid JSON output
- tool schema misuse
- context overflow / truncation
- latency and streaming behavior

Recommended request fields:
- `stage` (`plan|web.answer|web.summarize|transform.run|ranking|summarization|capture`) and `model_id`
- prompt sizes: `system_prompt_chars`, `user_prompt_chars`, `context_chars`
- packing metrics: `text_chars`, `primary_chars`, `chunk_count` (and optional per-chunk sizes)
- input sizes (chars/tokens estimates) per context doc kind
- counts: sources included, chunks included, tool schema version
- redacted previews only when explicitly enabled

Recommended response fields:
- `status` (`ok|error|invalid_json|truncated`)
- output size + citations count + tool calls count
- timing (duration, first-token time when streaming is used)
- error classification (auth/network/rate_limit/schema/content_too_long)

Storage rule:
- Full captured Markdown belongs in `sources.capture_markdown` (SQLite), not in the LLM request log.
- `llm_runs.request_redacted_json` / `response_redacted_json` (SQLite) may store compact redacted payloads for replay/debugging.

---

## 6) Tool and Policy Gate logging

For every proposed tool call:
- Log the proposed `{ name, arguments }` (arguments may be redacted/hashed if sensitive).
- Log Policy Gate decision: `allow|ask|deny` + reason code.
- Log execution result status + duration.

This is essential for user trust and for automation regressions.

---

## 7) Capture logging (DOM -> Markdown)

Capture is a major failure mode in Safari, so log:
- capture mode selected (`article|list|auto`)
- bounding decisions (`max_markdown_chars`, truncated yes/no)
- extraction signals (`paywall_or_login`, `overlay_blocking`, `sparse_text`)
- result stats (markdown chars, link count)
- failure reason codes (timeout, navigation_failed, readability_failed, empty_content)

Never log:
- raw HTML
- full captured Markdown (unless explicitly enabled in local debug)

---

## 8) Rotation and retention (P0 recommendation)

P0 can start simple:
- JSONL is append-only.
- Rotate by size (e.g. 20MB): rename to `llm.1.jsonl`, keep last N (e.g. 5).
- Never upload logs by default.

This avoids unbounded growth while keeping enough history for debugging.
