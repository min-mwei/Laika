const test = require("node:test");
const assert = require("node:assert/strict");
const searchTools = require("../lib/search_tools");

test("buildSearchUrl uses custom template by default", () => {
  const result = searchTools.buildSearchUrl("hello world", "", {
    mode: "direct",
    customTemplate: "https://www.google.com/search?q={query}"
  });
  assert.equal(result.error, undefined);
  assert.equal(result.engine, "custom");
  assert.equal(result.url, "https://www.google.com/search?q=hello%20world");
});

test("buildSearchUrl supports engine override", () => {
  const result = searchTools.buildSearchUrl("unit test", "bing", {});
  assert.equal(result.error, undefined);
  assert.equal(result.engine, "bing");
  assert.equal(result.url, "https://www.bing.com/search?q=unit%20test");
});

test("appendLoopParam avoids duplicate guard params", () => {
  const settings = {
    customTemplate: "https://example.com/search?q={query}",
    addLoopParam: true,
    loopParam: "laika_redirect"
  };
  const first = searchTools.buildSearchUrl("check", "custom", settings);
  const parsed = new URL(first.url);
  assert.equal(parsed.searchParams.getAll("laika_redirect").length, 1);
  const second = searchTools.appendLoopParam(first.url, "laika_redirect");
  assert.equal(second.alreadyApplied, true);
});
