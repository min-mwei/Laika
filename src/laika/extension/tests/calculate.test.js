const test = require("node:test");
const assert = require("node:assert/strict");
const calculate = require("../lib/calculate");

test("evaluateExpression handles arithmetic", () => {
  const result = calculate.evaluateExpression("1 + 2 * 3");
  assert.equal(result.ok, true);
  assert.equal(result.value, 7);

  const nested = calculate.evaluateExpression("(1 + 2) * 3");
  assert.equal(nested.ok, true);
  assert.equal(nested.value, 9);

  const unary = calculate.evaluateExpression("-4 + 2");
  assert.equal(unary.ok, true);
  assert.equal(unary.value, -2);
});

test("evaluateExpression supports decimals", () => {
  const result = calculate.evaluateExpression(".5 + 1");
  assert.equal(result.ok, true);
  assert.equal(result.value, 1.5);
});

test("evaluateExpression rejects invalid input", () => {
  const empty = calculate.evaluateExpression("");
  assert.equal(empty.ok, false);

  const bad = calculate.evaluateExpression("1 +");
  assert.equal(bad.ok, false);

  const divZero = calculate.evaluateExpression("10 / 0");
  assert.equal(divZero.ok, false);
});

test("normalizePrecision enforces bounds", () => {
  const ok = calculate.normalizePrecision(2);
  assert.equal(ok.ok, true);
  assert.equal(ok.value, 2);

  const badFloat = calculate.normalizePrecision(2.5);
  assert.equal(badFloat.ok, false);

  const outOfRange = calculate.normalizePrecision(7);
  assert.equal(outOfRange.ok, false);
});

test("formatValue applies precision", () => {
  const formatted = calculate.formatValue(1.2345, 2);
  assert.equal(formatted.result, 1.23);
  assert.equal(formatted.formatted, "1.23");
});
