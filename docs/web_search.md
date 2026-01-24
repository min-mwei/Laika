# Safari Search Redirect and Laika Tool

This doc captures a practical way to redirect Safari Smart Search field queries to a custom engine (for example, Google) and how that can be wired into Laika as an LLM tool.

## Reality check (Safari constraints)

Safari WebExtensions does not expose a search engine API (no `browser.search` equivalent). To change where Smart Search queries land, extensions rely on redirects.

## Redirect design (Safari extension)

Goal: detect address-bar searches that Safari sends to its default engine, then rewrite to a custom engine.

There are two viable interception points:

1. Background interception:
   - Listen to `webNavigation.onBeforeNavigate`.
   - If the URL matches the default engine pattern, cancel/redirect via `tabs.update`.
   - Advantage: avoids page flash.
   - Caveat: transition qualifiers may be missing or inconsistent in Safari, so use URL heuristics.
2. Content script interception:
   - Inject a content script into default engine domains.
   - If the URL matches address-bar markers, call `window.stop()` and `location.replace()` to a custom engine.
   - Advantage: works without transition metadata.
   - Caveat: allows a brief page load unless `window.stop()` happens early.

### Detection heuristics (address bar vs in-page search)

Heuristics need to be conservative so the extension does not hijack searches the user runs on the search engine site itself. A common pattern is to require a Safari-specific query segment that only appears in address-bar searches.

Observed example markers (from existing Safari search-redirect extensions):

| Engine | Hostname match | Query param | Safari-specific segment |
| --- | --- | --- | --- |
| Google | `www.google.` | `q` | `ie=` |
| Bing | `www.bing.` | `q` | `PC=` |
| Yahoo | `search.yahoo.` | `p` | `fr=aaplw` |
| DuckDuckGo | `duckduckgo.` | `q` | `t=osx` |

Notes:
- These markers are heuristics, not API guarantees. Treat them as best-effort signals.
- Always require `frameId == 0` or `details.parentFrameId == -1` to avoid subframe redirects.

### Redirect algorithm (content script)

Pseudocode:

```js
const customTemplate = "https://www.google.com/search?q={query}";
const safariMarkers = [
  { host: "www.google.", queryParam: "q", marker: "ie=" },
  { host: "www.bing.", queryParam: "q", marker: "PC=" },
  { host: "search.yahoo.", queryParam: "p", marker: "fr=aaplw" },
  { host: "duckduckgo.", queryParam: "q", marker: "t=osx" },
];

function isAddressBarSearch(url) {
  return safariMarkers.some(({ host, marker }) =>
    url.hostname.includes(host) && url.search.includes(marker)
  );
}

function buildRedirectUrl(url) {
  const marker = safariMarkers.find(({ host }) => url.hostname.includes(host));
  const params = new URLSearchParams(url.search);
  const query = params.get(marker.queryParam);
  if (!query) return null;
  return customTemplate.replace("{query}", encodeURIComponent(query));
}

if (isAddressBarSearch(window.location)) {
  const redirectUrl = buildRedirectUrl(window.location);
  if (redirectUrl) {
    window.stop();
    window.location.replace(redirectUrl);
  }
}
```

### Redirect guardrails

- Prevent redirect loops by tagging redirects (`laika_redirect=1`) and skipping if present.
- If the custom engine equals the default engine, no redirect.
- Only run on allowed domains. In Safari Web Extensions, the Safari wrapper "Allowed Domains" must include the default engine hosts, and the manifest `host_permissions` must match.
- Consider a "do not redirect" list for users who visit search engine sites directly.

## Laika integration as an LLM tool

Laika already reserves a `search` tool in `docs/llm_tools.md`. The search redirect can be integrated in two layers:

1. A search tool that opens the search results URL directly (simple and reliable).
2. An optional redirect layer that rewrites address-bar searches if the user wants Safari to behave like it has a custom engine.

### Proposed tool contract

Extend the existing tool to allow engine selection:

```json
{
  "name": "search",
  "arguments": {
    "query": "site:sec.gov 10-K deadline",
    "engine": "custom",
    "newTab": true
  }
}
```

Suggested arguments:
- `query` (string, required)
- `engine` (string, optional): `custom` | `default` | `google` | `duckduckgo` | `bing`
- `newTab` (boolean, optional; default true)

### Tool handler flow (background.js)

```js
function handleSearchTool({ query, engine = "custom", newTab = true }) {
  const provider = selectProvider(engine); // user config or defaults
  const url = provider.buildUrl(query);    // template + encode
  return openOrNavigate(url, newTab);
}
```

Integration options:
- If `engine == "custom"` and redirect is enabled, `provider.buildUrl` can return the Safari default engine URL so the redirect layer rewrites it.
- If redirect is disabled, `provider.buildUrl` should return the custom engine URL directly.

### Storage and settings

Store search config in extension storage:

```json
{
  "searchSettings": {
    "mode": "direct|redirect-default",
    "customTemplate": "https://www.google.com/search?q={query}",
    "defaultEngine": "google",
    "addLoopParam": false,
    "loopParam": "laika_redirect",
    "maxQueryLength": 512
  }
}
```

### Policy and safety

- Treat `search` as a navigation action (ask by default).
- Enforce an allowlist of engines and URL templates.
- Do not log full queries in plaintext in the run log unless the user opts in.

## Example end-to-end flows

1. LLM tool search (direct):
   - Tool: `search` with `engine=custom`.
   - Background opens `https://www.google.com/search?q=...`.
   - Results load; `browser.observe_dom` captures the page.

2. User address bar search (redirected):
   - User types in Safari Smart Search.
   - Content script sees Safari marker and redirects to the custom engine.
   - Redirect guardrail prevents loops.

## Testing checklist

- Trigger searches for each default engine with and without redirect enabled.
- Verify manual search on the engine site does not redirect.
- Confirm loop prevention when the custom engine is the same as the default.
- Confirm host permissions cover the default and custom engine domains.

## References

- Safari search redirect technique in the wild (content script): https://raw.githubusercontent.com/MentalGear/OpenSearchSafari/master/RedirectPlease%20Extension/openSearch.js
- Safari search engine limitations and redirect workaround explanation: https://lapcatsoftware.com/articles/2025/2/2.html
