# Rendering Design: Markdown Subset

## Purpose
Define how Laika renders assistant output with a safe Markdown subset, improving readability without exposing the UI to untrusted HTML.

This design applies to the Safari extension sidecar UI and any companion UI that renders chat history.

## Goals
- Render assistant messages with richer structure (headings, lists, code) while preserving safety.
- Keep all web and model output treated as untrusted input.
- Ensure rendering is consistent across streaming and non-streaming summaries.
- Maintain a simple on-wire format that can be stored and re-rendered deterministically.

## Non-goals
- Support arbitrary HTML or inline styles from the model.
- Provide a full WYSIWYG editor.
- Allow Markdown in system or action messages.

## Markdown subset
Supported Markdown features for assistant messages:
- Paragraphs with blank lines.
- Headings: `##`, `###`, `####` only.
- Unordered lists with `-`.
- Ordered lists with `1.` style.
- Emphasis: `*italic*` and `**bold**`.
- Inline code with backticks.
- Code blocks with fenced triple backticks.
- Blockquotes with `>`.
- Links: `[label](https://example.com)`.

Disallowed:
- Raw HTML blocks or inline HTML.
- Images, iframes, or embedded media.
- Tables (can be added later if needed).

## Data contract
Add an explicit format field to assistant messages and summary streams.
- `format: "plain"` (default)
- `format: "markdown"`

Message payloads should store:
- `rawText` (the original model output in the declared format)
- `format` (plain or markdown)

Rendering is derived from `rawText` so history remains stable.

For plan responses, include `summaryFormat` alongside `summary` so the UI can render correctly.

## Rendering pipeline
1. If `format` is `plain`, render using `textContent`.
2. If `format` is `markdown`:
   - Parse Markdown to HTML using `markdown-it` with `html: false` and `linkify: true`.
   - Disable Markdown features outside the subset (`table`, `strikethrough`).
   - Sanitize HTML using `DOMPurify` with an explicit allowlist.
   - Render sanitized HTML into the message body.
3. Never render Markdown as HTML without sanitization.

## Sanitization policy
Allow these tags only:
- `p`, `br`
- `ul`, `ol`, `li`
- `strong`, `em`
- `code`, `pre`
- `blockquote`
- `h2`, `h3`, `h4`
- `a`

Allow these attributes only:
- `href`, `title`, `rel`, `target` (for `a` tags)

Link policy:
- Allow only `http`, `https`, and `mailto` schemes.
- Force `rel="noopener noreferrer"` and `target="_blank"` on all links.

Everything else is stripped.

## Streaming behavior
Summary streaming yields incremental chunks. For Markdown rendering:
- Accumulate `rawText`.
- Re-render the full message on a short throttle (100-200ms).
- Always sanitize the full HTML output on each render.

This avoids broken markup while keeping the UI responsive.

## LLM formatting guidance
Update system prompts so the assistant may emit the Markdown subset:
- No raw HTML.
- Use headings and lists when it improves readability.
- Keep paragraphs short and separated by blank lines.
- Use code blocks only for literal code or command output.

System and action messages remain plain text.

## UI styling notes
Apply chat content styles tuned for Markdown:
- `line-height: 1.5` to `1.7`.
- Consistent spacing between paragraphs and list items.
- Monospace font for `code` and `pre` blocks.
- Subtle background for code blocks to improve scanability.

## Security considerations
- Model output is untrusted even when local.
- Sanitization is required for all Markdown rendering.
- Do not allow event handlers, inline styles, or scriptable URLs.
- Keep the extension UI isolated from page DOM and never inject sanitized content back into the page.

## Implementation plan (design-level)
1. Add `format` to summary and plan responses, default to `plain`.
2. Update prompts and summary sanitization to allow Markdown output.
3. Add `markdown-it` and `DOMPurify` as bundled extension assets.
4. Update UI render path to use Markdown rendering for assistant messages only.
5. Add tests for sanitizer and renderer allowlist behavior.

## References
- markdown-it (v14.1.0): CommonMark compliant and extensible Markdown parser.
- DOMPurify (v3.3.1): DOM-based sanitizer compatible with Safari.
- marked: does not sanitize HTML and recommends pairing with a sanitizer.
