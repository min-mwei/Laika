const test = require("node:test");
const assert = require("node:assert/strict");
const validator = require("../lib/plan_validator");

test("validatePlanResponse accepts actions array", () => {
  const payload = { actions: [] };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects missing actions", () => {
  const payload = { summary: "hi" };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});
