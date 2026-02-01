const test = require("node:test");
const assert = require("node:assert/strict");

const { postProcessMarkdown } = require("../lib/markdown_postprocess");

test("postProcessMarkdown removes obvious ad noise", () => {
  const input = [
    "Intro line",
    "Advertisement",
    "Cookie recipe: add butter and sugar",
    "Promoted",
    "Sponsored"
  ].join("\n");
  const output = postProcessMarkdown(input);
  assert.ok(!output.includes("Advertisement"));
  assert.ok(!output.includes("Promoted"));
  assert.ok(!output.includes("Sponsored"));
  assert.ok(output.includes("Cookie recipe"));
});

test("postProcessMarkdown preserves code fences", () => {
  const input = [
    "```",
    "Subscribe now",
    "```",
    "",
    "subscribe now"
  ].join("\n");
  const output = postProcessMarkdown(input);
  assert.ok(output.includes("Subscribe now"));
  const lines = output.split(/\r?\n/).map((line) => line.trim());
  assert.ok(!lines.includes("subscribe now"));
});

test("postProcessMarkdown splits long paragraphs", () => {
  const sentence = "This is a sentence that should be split.";
  const longLine = Array(40).fill(sentence).join(" ");
  const output = postProcessMarkdown(longLine);
  assert.ok(output.includes("\n"));
});
