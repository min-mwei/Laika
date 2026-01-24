# Rendering Design: Document AST

## Purpose
Define how Laika renders assistant output using a safe JSON document tree, avoiding raw HTML or Markdown while preserving structure.

This design applies to the Safari extension sidecar UI and any companion UI that renders chat history.

## Goals
- Render assistant messages with headings, lists, and code safely.
- Treat all model output as untrusted input.
- Keep the on-wire format deterministic for storage and replay.

## Non-goals
- Support arbitrary HTML/CSS/JS from the model.
- Parse Markdown or carry legacy Markdown fallbacks.
- Render rich media (images, tables, embeds).

## Document (assistant.render)
Assistant output is a JSON AST with a fixed allowlist:

Block nodes:
- `doc` (root, `children`)
- `heading` (`level`, `children`)
- `paragraph` (`children`)
- `list` (`ordered`, `items`)
- `list_item` (`children`)
- `blockquote` (`children`)
- `code_block` (`language?`, `text`)

Inline nodes:
- `text` (`text`)
- `link` (`href`, `children`)

## Data contract
- `assistant.render` is required for assistant messages.
- `assistant.citations` are optional and reference `(doc_id, node_id)` or `handle_id`.
- Chat history stores the document as the source of truth; no `summaryFormat` or Markdown fields.

## Rendering pipeline
1. Validate the root `doc` and walk the tree.
2. Convert nodes to an allowlisted DOM subset (`<p>`, `<h2>`, `<ul>`, `<li>`, `<pre><code>`, `<a>`).
3. Ignore unknown node types or invalid fields.
4. Enforce link sanitization (`http`, `https`, `mailto` only).

## Sanitization policy
- Only allow tags needed for the document AST.
- Strip unknown attributes and event handlers.
- Force `rel="noopener noreferrer"` and `target="_blank"` on links.

## LLM formatting guidance
System prompts must require `assistant.render`:
- No raw HTML or Markdown.
- Use headings and lists when it improves readability.
- Keep paragraphs concise.
- Use code blocks only for literal code or command output.

## UI styling notes
- Use `white-space: normal` for render messages.
- Provide consistent spacing between paragraphs and list items.
- Use monospace styling for `code` and `pre`.

## Security considerations
- Model output is untrusted even when local.
- Never inject model content back into the page DOM.
- Keep the extension UI isolated and allowlist-rendered.
