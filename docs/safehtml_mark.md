# Safe HTML <-> Markdown (Capture + Rendering)

This doc defines Laika's canonical content pipeline:

- **Capture**: web DOM/HTML -> **Markdown** (stored as source snapshots; sent to models)
- **Render**: **Markdown** -> **safe HTML** (displayed in trusted UI surfaces)

The goal is to make both directions reliable, auditable, and safe.

Related:
- `docs/llm_context_protocol.md` (LLMCP: JSON + Markdown)
- `docs/dom_heuristics.md` (extraction heuristics and page archetypes)

---

## 1) Threat model + invariants

We have two untrusted inputs:

1) **The web page** (untrusted HTML/DOM; may contain hostile content and prompt injection text).
2) **The model output** (untrusted text; may try to smuggle HTML/JS or malicious links).

Hard invariants:
- Never send cookies/session tokens to any model.
- Avoid sending raw HTML to models (prefer Markdown).
- Never render model-authored HTML directly in privileged UI. Render Markdown -> sanitize -> display.
- Links must be sanitized (`http`, `https`, `mailto` only).
- If we ever support interactive artifacts, they must run in a sandbox (P1+).

---

## 2) Canonical formats

Canonical stored formats:
- Sources: `captureMarkdown` (bounded Markdown)
- Chat/assistant output: `assistant.markdown`
- Artifacts: `artifact.contentMarkdown`

"Safe HTML" is *not* a stored canonical format. It's a UI-only rendering result produced by:
1) parsing Markdown, and
2) sanitizing the resulting HTML with a strict allowlist.

---

## 3) Capture pipeline (DOM/HTML -> Markdown)

Capture happens in the **content script** (where the DOM exists and where authenticated content is visible).

### 3.1 Capture steps

1) Select main content HTML
   - First try **Readability** (best for article-like pages).
   - Fallback to selector/heuristics for list/feed/search/thread pages.

2) Reduce obvious noise
   - Remove scripts, nav, headers/footers, forms, iframes, etc. (do this before conversion).

3) Convert HTML -> Markdown (canonical)
   - Convert the reduced main-content HTML into Markdown.
   - Bound it (`maxMarkdownChars`) so captures are stable and predictable.
     - Recommended P0 default: `24_000` chars (tunable).
     - If truncating, insert an explicit marker so users know it's partial.

4) Extract outbound links (for discovery)
   - Extract `{ url, text, context }` from the same reduced HTML prior to conversion.
   - Filter obvious noise (privacy/terms/login/share/rss/etc.) and duplicates.

5) Persist source snapshot
   - Store `captureMarkdown`, `capturedAt`, and extraction `signals` (paywall/login/overlay, sparse text, etc).

### 3.2 Recommended libraries (capture)

Follow the reference pattern in `./NotebookLM-Chrome/`:

- `@mozilla/readability` for main-content extraction when possible
- **Turndown** for HTML -> Markdown (P0 choice)

Why Turndown (JS) is preferred over Swift conversion:
- The DOM and best extraction tooling exist in the content script.
- You avoid sending raw HTML across the extension/native boundary.
- Turndown is easy to customize with rules (remove noise, flatten links, drop images).

Swift-side HTML -> Markdown conversion is possible, but tends to be higher-risk:
- you need an HTML parser + a Markdown emitter
- you likely end up moving raw HTML to the native app
- you now have two implementations (JS extraction + Swift conversion) to keep consistent

### 3.3 Turndown rules (baseline)

Baseline rule ideas (mirrors the reference):
- Remove: `style`, `script`, `noscript`, `iframe`, `head`, `nav`, `footer`, `header`, `aside`, `form`, inputs/buttons/selects
- Flatten links: keep anchor text, drop the link wrapper (optional; makes context cleaner for models)
- Remove images: drop `<img>` (optional; or store images as separate sources)

### 3.4 Notes on safety during capture

- Capture treats page content as **untrusted** even after conversion.
- We do not "execute" page content; we only read and normalize it.
- Captures should be bounded and provenance-tagged so we can explain what was used.

### 3.5 Implementation notes (vNext)

- The capture pipeline is driven by `source.capture` in the extension background.
- The background opens (or reuses) a tab, then sends `laika.capture` to the content script.
- The content script runs Readability + Turndown, bounds Markdown, and returns only Markdown + link metadata.
- The background forwards results to the native store via `collection.capture_update` (no raw HTML crosses the boundary).

---

## 4) Rendering pipeline (Markdown -> safe HTML)

Rendering happens in trusted UI surfaces (sidecar/panel/viewer).

### 4.1 Rendering steps (P0)

1) Parse Markdown -> HTML
   - P0 choice: `markdown-it` (already vendored as `src/laika/extension/lib/vendor/markdown-it.min.js`)
   - Configure to avoid raw HTML passthrough (`html: false`).

2) Sanitize HTML with DOMPurify
   - Vendored: `src/laika/extension/lib/vendor/purify.min.js`
   - Use a strict allowlist (see 4.2).
   - Keep the DOMPurify config in one shared module so sidecar/panel/viewer render identically.

3) Post-process links
   - allow only `http`, `https`, `mailto`
   - force `rel="noopener noreferrer"` and `target="_blank"`

4) Insert into the extension UI DOM (never into the page DOM).

### 4.2 Sanitization policy (recommended allowlist)

Disallow:
- `script`, `style`, `iframe`, `object`, `embed`, `form`
- inline event handlers (`on*`)
- `javascript:` / `data:` URLs

Allow a minimal set of tags:
- structure: `p`, `br`, `strong`, `em`, `code`, `pre`, `blockquote`, `hr`
- lists/headings: `ul`, `ol`, `li`, `h1`..`h6`
- tables: `table`, `thead`, `tbody`, `tr`, `th`, `td`
- links: `a`

Allow minimal attributes:
- `href` (sanitized)
- optionally `class` (only if needed for UI styling)

Notes:
- Table support is non-negotiable (Compare + transforms).
- Even if Markdown parsing allows inline HTML, sanitization must remove it.

---

## 5) Interactive artifacts (P1+)

Some transforms may eventually produce interactive experiences (HTML/CSS/JS).

If/when Laika supports this:
- interactive output must not be treated as Markdown
- it must render in a sandboxed viewer (iframe/WebView sandbox) with:
  - no extension privileges
  - no access to cookies/session tokens
  - strict navigation isolation
  - explicit communication via `postMessage` only

Markdown remains the default/canonical artifact format; interactive output is opt-in and isolated.

---

## 6) Build/testing implications

### 6.1 TypeScript build (vNext choice)

- Use a **TypeScript + Vite** build (UI is **Preact + TS**) to import:
  - `turndown` + `@mozilla/readability` (capture)
  - `markdown-it` + `dompurify` (render)
- Emit static JS/CSS assets into a deterministic folder in the extension bundle (e.g. `src/laika/extension/ui_dist/`) for Xcode to bundle.

### 6.2 Without a bundler (legacy/bridge)

- Vendor minified JS libs under `src/laika/extension/lib/vendor/`.
- Keep the renderer/capture helpers as plain JS modules.
- Acceptable as an interim step, but vNext should converge on the TS/Vite pipeline so all surfaces share one implementation.

### 6.3 Tests (minimum)

- Markdown renderer tests:
  - GFM table output renders correctly
  - disallowed tags/attrs are stripped
  - link schemes are enforced
- Capture tests:
  - Readability fallback behavior on fixtures
  - Turndown rules remove chrome/noise and bound output size
