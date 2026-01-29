const test = require("node:test");
const assert = require("node:assert/strict");
const markdownRenderer = require("../lib/markdown_renderer");

test("markdown renderer outputs tables", () => {
  const purifyStub = {
    sanitize: (html) => html,
    addHook: () => {}
  };
  const renderer = markdownRenderer.createMarkdownRenderer({ purify: purifyStub });
  const html = renderer.render("| A | B |\n| - | - |\n| 1 | 2 |");
  assert.match(html, /<table>/);
});

test("markdown renderer blocks raw HTML passthrough", () => {
  const purifyStub = {
    sanitize: (html) => html,
    addHook: () => {}
  };
  const renderer = markdownRenderer.createMarkdownRenderer({ purify: purifyStub });
  const html = renderer.render("Hello <script>alert(1)</script>");
  assert.equal(html.includes("<script>"), false);
  assert.equal(html.includes("&lt;script"), true);
});

test("renderer config enforces safe link schemes", () => {
  const captured = { config: null, hooks: [] };
  const purifyStub = {
    sanitize: (html, config) => {
      captured.config = config;
      return html;
    },
    addHook: (hookName) => {
      captured.hooks.push(hookName);
    }
  };
  const renderer = markdownRenderer.createMarkdownRenderer({ purify: purifyStub });
  renderer.render("See [example](https://example.com).");
  assert.ok(captured.config);
  assert.ok(captured.config.ALLOWED_TAGS.includes("table"));
  assert.equal(captured.config.ALLOWED_URI_REGEXP.test("javascript:alert(1)"), false);
  assert.ok(captured.hooks.includes("afterSanitizeAttributes"));
});
