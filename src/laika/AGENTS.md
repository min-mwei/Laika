# Agent Guidance for src/laika

## Scope
This directory is reserved for the Safari extension, macOS companion app, and the thin model bridge that validate the AIBrowser design.

## Primary references
- `docs/AIBrowser.md` for architecture and safety expectations.
- `src/laika/PLAN.md` for the validation plan.
- `src/model_playground/README.md` for local model setup.

## Constraints to preserve
- Treat all web content as untrusted input.
- Do not send cookies, session tokens, or raw HTML to any model.
- Keep tool requests/results typed and schema-validated before execution.
- Keep the Safari extension thin; put policy, orchestration, and model calls in the app.
- Log actions in an append-only format and avoid storing sensitive raw page content.

## Layout conventions (create when needed)
- `src/laika/app` for Swift app code.
- `src/laika/extension` for Safari Web Extension code.
- `src/laika/model` for local model bridge glue.

## Model integration defaults
- Prefer local inference via `src/model_playground` over cloud inference.
- If a cloud fallback is requested, make it opt-in and pass only redacted context packs.
