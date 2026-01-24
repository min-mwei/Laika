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

test("validatePlanResponse rejects unsupported tool name", () => {
  const payload = {
    actions: [
      {
        toolCall: { id: "12345678-1234-1234-1234-1234567890ab", name: "browser.nope", arguments: {} },
        policy: { decision: "ask", reasonCode: "test" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse accepts click action", () => {
  const payload = {
    actions: [
      {
        toolCall: { id: "12345678-1234-1234-1234-1234567890ab", name: "browser.click", arguments: { handleId: "laika-1" } },
        policy: { decision: "ask", reasonCode: "test" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse accepts search action", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "search",
          arguments: { query: "SEC filing deadlines", engine: "custom", newTab: true }
        },
        policy: { decision: "ask", reasonCode: "assist_requires_approval" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects search without query", () => {
  const payload = {
    actions: [
      {
        toolCall: { id: "12345678-1234-1234-1234-1234567890ab", name: "search", arguments: {} },
        policy: { decision: "ask", reasonCode: "assist_requires_approval" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});
