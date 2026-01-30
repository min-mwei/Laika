const test = require("node:test");
const assert = require("node:assert/strict");
const collector = require("../lib/collect_top_results");

test("normalizeUrlForDedup strips fragments and tracking params", () => {
  const input = "https://Example.com/path/?utm_source=foo&b=2#section";
  const normalized = collector.normalizeUrlForDedup(input);
  assert.equal(normalized, "https://example.com/path/?b=2");
});

test("extractTopResults dedupes and respects host cap", () => {
  const observation = {
    items: [
      { title: "A1", url: "https://news.example.com/a?utm_medium=x" },
      { title: "A2", url: "https://news.example.com/a" },
      { title: "B1", url: "https://other.example.org/b" },
      { title: "C1", url: "https://news.example.com/c" }
    ]
  };
  const result = collector.extractTopResults(observation, { maxResults: 10, hostCap: 1 });
  assert.equal(result.items.length, 2);
  assert.equal(result.items[0].url, "https://news.example.com/a");
  assert.equal(result.items[1].url, "https://other.example.org/b");
  assert.equal(result.skipped.duplicates, 1);
  assert.equal(result.skipped.hostCap, 1);
});

test("extractTopResults skips noise paths", () => {
  const observation = {
    items: [
      { title: "Privacy", url: "https://example.com/privacy" },
      { title: "Terms", url: "https://example.com/terms" },
      { title: "Article", url: "https://example.com/news/item-1" }
    ]
  };
  const result = collector.extractTopResults(observation, { maxResults: 5, hostCap: 2 });
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].url, "https://example.com/news/item-1");
  assert.ok(result.skipped.noise >= 2);
});
