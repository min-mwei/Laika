# Laika Docs

Quick index for design and research notes.

- `docs/LaikaOverview.md`: core architecture + security design for the Safari extension + app; current prototype UI uses a toolbar-toggled, attached sidecar panel in the active tab (with a standalone panel-window fallback when the sidecar can’t attach).
- `docs/Laika_pitch.md`: end-user narrative and scenario library (why Laika, what it does, where it shines).
- `src/laika/AGENTS.md`: build, run, automation, and test workflows for local development.
- `docs/laika_vocabulary.md`: canonical action + tool vocabulary (English intent → tool calls).
- `docs/laika_ui.md`: UI surfaces, layouts, and flows for collections + sources + chat + transforms (maps UI actions to tools/LLM tasks).
- `docs/local_llm.md`: local model runtime and safety/perf guidance.
- `docs/llm_context_protocol.md`: JSON protocol for Markdown context packs + JSON-only LLM responses (Markdown outputs) + tool calls + durable storage.
- `docs/QWen3.md`: Qwen3 thinking/streaming/decoding one-pager.
- `docs/safehtml_mark.md`: Safe HTML <-> Markdown (capture pipeline + rendering/sanitization rules).
- `src/laika/PLAN.md`: implementation plan for P0 workflows, including collections + transforms + viewer tabs and shopping guardrails.

If you add a new doc, list it here. Keep entries short and focused on intent. 
