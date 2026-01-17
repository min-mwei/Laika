const test = require("node:test");
const assert = require("node:assert/strict");
const utils = require("../lib/text_utils");

test("normalizeWhitespace collapses spaces", () => {
  const input = "  hello\nworld   ";
  assert.equal(utils.normalizeWhitespace(input), "hello world");
});

test("budgetText truncates to max", () => {
  const input = "a".repeat(10);
  assert.equal(utils.budgetText(input, 4), "aaaa");
});
