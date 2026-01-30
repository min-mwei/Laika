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

test("validatePlanResponse rejects click action with extra args", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "browser.click",
          arguments: { handleId: "laika-1", extra: "nope" }
        },
        policy: { decision: "ask", reasonCode: "test" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse rejects observe_dom with unknown args", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "browser.observe_dom",
          arguments: { maxChars: 1200, extra: 1 }
        },
        policy: { decision: "allow", reasonCode: "observe_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse rejects observe_dom with non-finite numbers", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "browser.observe_dom",
          arguments: { maxChars: NaN }
        },
        policy: { decision: "allow", reasonCode: "observe_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse rejects scroll with non-finite delta", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "browser.scroll",
          arguments: { deltaY: Infinity }
        },
        policy: { decision: "allow", reasonCode: "scroll_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
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

test("validatePlanResponse accepts calculate action", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "app.calculate",
          arguments: { expression: "1 + 2", precision: 2 }
        },
        policy: { decision: "allow", reasonCode: "calculate_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects calculate without expression", () => {
  const payload = {
    actions: [
      {
        toolCall: { id: "12345678-1234-1234-1234-1234567890ab", name: "app.calculate", arguments: {} },
        policy: { decision: "allow", reasonCode: "calculate_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse rejects calculate with invalid precision", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "app.calculate",
          arguments: { expression: "1 + 2", precision: 2.5 }
        },
        policy: { decision: "allow", reasonCode: "calculate_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse accepts collection.create with tags", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "collection.create",
          arguments: { title: "My collection", tags: ["research", "2026"] }
        },
        policy: { decision: "allow", reasonCode: "collection_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects collection.create without title", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "collection.create",
          arguments: { tags: ["missing-title"] }
        },
        policy: { decision: "allow", reasonCode: "collection_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse accepts collection.add_sources url and note", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "collection.add_sources",
          arguments: {
            collectionId: "col_123",
            sources: [
              { type: "url", url: "https://example.com", title: "Example" },
              { type: "note", title: "Note", text: "Remember this" }
            ]
          }
        },
        policy: { decision: "allow", reasonCode: "collection_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects collection.add_sources with unknown keys", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "collection.add_sources",
          arguments: {
            collectionId: "col_123",
            sources: [
              { type: "url", url: "https://example.com", extra: "nope" }
            ]
          }
        },
        policy: { decision: "allow", reasonCode: "collection_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse accepts source.capture with mode and maxChars", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "source.capture",
          arguments: { collectionId: "col_123", url: "https://example.com", mode: "article", maxChars: 1200 }
        },
        policy: { decision: "allow", reasonCode: "capture_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, true);
});

test("validatePlanResponse rejects source.capture with invalid mode", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "source.capture",
          arguments: { collectionId: "col_123", url: "https://example.com", mode: "invalid" }
        },
        policy: { decision: "allow", reasonCode: "capture_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});

test("validatePlanResponse rejects disabled tools", () => {
  const payload = {
    actions: [
      {
        toolCall: {
          id: "12345678-1234-1234-1234-1234567890ab",
          name: "artifact.save",
          arguments: { title: "Brief", markdown: "# Hello" }
        },
        policy: { decision: "allow", reasonCode: "artifact_allowed" }
      }
    ]
  };
  const result = validator.validatePlanResponse(payload);
  assert.equal(result.ok, false);
});
