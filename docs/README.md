# Laika Docs

Quick index for design and research notes.

- `docs/LaikaOverview.md`: core architecture + security design for the Safari extension + app; current prototype UI uses a toolbar-toggled, attached sidecar panel in the active tab (with a standalone panel-window fallback when the sidecar can’t attach).
- `docs/Laika_pitch.md`: end-user narrative and scenario library (why Laika, what it does, where it shines).
- `src/laika/AGENTS.md`: build, run, automation, and test workflows for local development.
- `docs/laika_vocabulary.md`: canonical action + tool vocabulary (English intent → tool calls).
- `docs/local_llm.md`: local model runtime and safety/perf guidance.
- `docs/llm_context_protocol.md`: proposed JSON protocol for DOM context packs + JSON-only LLM responses + SQLite chat history.
- `docs/QWen3.md`: Qwen3 thinking/streaming/decoding one-pager.
- `docs/rendering.md`: Render Document AST rules and UI sanitization pipeline.

If you add a new doc, list it here. Keep entries short and focused on intent. 
