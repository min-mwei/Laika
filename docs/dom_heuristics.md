# DOM Extraction Heuristics

This note captures practical heuristics for walking DOM trees, extracting text, and shaping context for LLM summarization. It is intended to be a living guide for improving extraction quality without hard-coding for specific sites.

## DOM shape archetypes

- **Feed/list**: repeated rows/cards with a headline link + metadata row (author/time/comments). High link density, short text per item, repeated structure.
- **Article/essay**: one dominant container with an H1/H2 and multiple paragraphs. Lower link density, longer contiguous text.
- **Documentation**: left nav + main content, many headings, code blocks, and inline links; often a table of contents.
- **Thread/discussion**: repeated comment blocks with author/time/score, nested depth, reply links.
- **Search results**: repeated cards with title + snippet + source domain; often interleaved ads or special modules.
- **Product/landing**: hero section, repeated feature blocks, CTA buttons, testimonials; lots of UI chrome.
- **Table/report**: many rows with short cell text; structure matters more than long paragraphs.

## Useful signals (feature vector)

- **Text density**: text length vs element area.
- **Link density**: link text / total text.
- **Heading density**: heading count vs paragraphs, proximity of headings to blocks.
- **List ratio**: list item count vs paragraphs.
- **Layout order**: bounding box order (y, then x) to preserve reading flow.
- **Tag/role hints**: `article/main/section`, `role=main`, `itemprop=articleBody`, etc.
- **Metadata cues**: timestamps, author/byline, points/votes/comments.
- **Access gates**: visible overlays or gates (`overlay_or_dialog`, `paywall`, `auth_gate`, `auth_fields`, `consent_overlay`, `age_gate`, `geo_block`, `script_required`) that suggest content is blocked.
- **Interaction density**: buttons/inputs ratio (often indicates chrome or UI panels).

## Extraction heuristics

- **Root selection**: score candidates by `textLength * (1 - linkDensity) * qualityScore`, with semantic tag boosts. Cap candidates to avoid scans of thousands of nodes.
- **List root fallback**: when content roots are weak on feed/list pages, pick the dominant `table/ul/ol` container with many anchored items to stabilize ordering.
- **Visibility**: treat `display: contents` as visible; use text-node rects when parent boxes are zero.
- **Block selection**: prefer a primary-centered window plus tail coverage over the first N blocks.
- **Lists/tables**: keep list items and table rows as first-class blocks; preserve nesting via indentation.
- **Comments**: detect repeated blocks with author/time/reply patterns; preserve depth signals; pick a comment-root container when comment density dominates so comment threads don't collapse to a single block. Prefer containers that include author/time metadata to avoid shallow wrappers that drop context.
- **Shadow DOM**: traverse open roots and merge results in document order when possible.

## Structured context for LLMs

- **Line-preserved text** with prefixes: `H2:`, `- `, `> `, `Code:`.
- **Outline**: headings + small list items with levels.
- **Items**: `{title, url, snippet, linkCandidates[]}` for list-like pages.
- **Comments**: `{author, age, score, text, depth}` for discussion pages.
- **Access signals**: small string tags for overlays and gates (e.g. `paywall`, `auth_gate`, `overlay_or_dialog`).
- **Section summaries** (optional): short notes per heading to improve long-form coverage.

## Managing heuristics

- Keep **weights and thresholds** in one place so they are tunable without rewiring logic.
- Add **debug counters and timings** to see what was filtered and why.
- Use **scenario-driven evaluation** (HN/BBC/SEC + internal pages).
- Add **site-specific override rules** as last-resort patches, gated by origin.
- Prefer **feature-based logic** over string matching when possible.

## Suggested debug metrics

- Candidate counts and pruning ratios (`contentRootCandidates`, `prunedCount`).
- Root selection scores and selected element descriptors (tag/id/class/role).
- List-root candidate counts and selected element descriptors (`listRoot`).
- Comment-root candidate counts and selected element descriptors (`commentRoot`).
- Page state signals (readyState, visibility, body child count, body text length).
- Access signals (paywall/auth/overlay hints).
- Block window coverage (primary index, window start/end).
- Item/comment candidate counts and top scoring reasons.
- Per-stage timings (roots, text, blocks, items, comments).
