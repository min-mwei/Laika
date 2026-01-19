(function (root) {
  "use strict";

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  var TOOL_NAMES = {
    "browser.observe_dom": true,
    "browser.click": true,
    "browser.type": true,
    "browser.scroll": true,
    "browser.open_tab": true,
    "browser.navigate": true,
    "browser.back": true,
    "browser.forward": true,
    "browser.refresh": true,
    "browser.select": true
  };

  function validateToolCall(toolCall) {
    if (!isObject(toolCall)) {
      return "missing toolCall";
    }
    if (typeof toolCall.name !== "string" || !TOOL_NAMES[toolCall.name]) {
      return "unsupported tool name";
    }
    if (typeof toolCall.id !== "string" || toolCall.id.length < 8) {
      return "missing tool id";
    }
    var args = toolCall.arguments || {};
    if (!isObject(args)) {
      return "invalid tool arguments";
    }

    if (toolCall.name === "browser.observe_dom") {
      if (typeof args.maxChars !== "undefined" && typeof args.maxChars !== "number") {
        return "observe_dom.maxChars must be number";
      }
      if (typeof args.maxElements !== "undefined" && typeof args.maxElements !== "number") {
        return "observe_dom.maxElements must be number";
      }
      if (typeof args.maxBlocks !== "undefined" && typeof args.maxBlocks !== "number") {
        return "observe_dom.maxBlocks must be number";
      }
      if (typeof args.maxPrimaryChars !== "undefined" && typeof args.maxPrimaryChars !== "number") {
        return "observe_dom.maxPrimaryChars must be number";
      }
      if (typeof args.maxOutline !== "undefined" && typeof args.maxOutline !== "number") {
        return "observe_dom.maxOutline must be number";
      }
      if (typeof args.maxOutlineChars !== "undefined" && typeof args.maxOutlineChars !== "number") {
        return "observe_dom.maxOutlineChars must be number";
      }
      if (typeof args.maxItems !== "undefined" && typeof args.maxItems !== "number") {
        return "observe_dom.maxItems must be number";
      }
      if (typeof args.maxItemChars !== "undefined" && typeof args.maxItemChars !== "number") {
        return "observe_dom.maxItemChars must be number";
      }
      if (typeof args.maxComments !== "undefined" && typeof args.maxComments !== "number") {
        return "observe_dom.maxComments must be number";
      }
      if (typeof args.maxCommentChars !== "undefined" && typeof args.maxCommentChars !== "number") {
        return "observe_dom.maxCommentChars must be number";
      }
      if (typeof args.rootHandleId !== "undefined" && typeof args.rootHandleId !== "string") {
        return "observe_dom.rootHandleId must be string";
      }
      return null;
    }

    if (toolCall.name === "browser.click") {
      return typeof args.handleId === "string" && args.handleId ? null : "click.handleId required";
    }
    if (toolCall.name === "browser.type") {
      if (typeof args.handleId !== "string" || !args.handleId) {
        return "type.handleId required";
      }
      if (typeof args.text !== "string") {
        return "type.text required";
      }
      return null;
    }
    if (toolCall.name === "browser.select") {
      if (typeof args.handleId !== "string" || !args.handleId) {
        return "select.handleId required";
      }
      if (typeof args.value !== "string" || !args.value) {
        return "select.value required";
      }
      return null;
    }
    if (toolCall.name === "browser.scroll") {
      return typeof args.deltaY === "number" ? null : "scroll.deltaY required";
    }
    if (toolCall.name === "browser.open_tab" || toolCall.name === "browser.navigate") {
      return typeof args.url === "string" && args.url ? null : "url required";
    }
    if (toolCall.name === "browser.back" || toolCall.name === "browser.forward" || toolCall.name === "browser.refresh") {
      return Object.keys(args).length === 0 ? null : "no arguments allowed";
    }

    return "unsupported tool";
  }

  function validateAction(action) {
    if (!isObject(action)) {
      return "invalid action";
    }
    var toolError = validateToolCall(action.toolCall);
    if (toolError) {
      return toolError;
    }
    if (!isObject(action.policy) || typeof action.policy.decision !== "string") {
      return "missing policy";
    }
    if (action.policy.decision !== "allow" && action.policy.decision !== "ask" && action.policy.decision !== "deny") {
      return "invalid policy decision";
    }
    return null;
  }

  function validatePlanResponse(payload) {
    if (!isObject(payload)) {
      return { ok: false, error: "invalid payload" };
    }
    if (!Array.isArray(payload.actions)) {
      return { ok: false, error: "missing actions array" };
    }
    for (var i = 0; i < payload.actions.length; i += 1) {
      var err = validateAction(payload.actions[i]);
      if (err) {
        return { ok: false, error: err };
      }
    }
    return { ok: true };
  }

  var api = {
    validatePlanResponse: validatePlanResponse
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaPlanValidator = api;
  }
})(typeof window !== "undefined" ? window : undefined);
