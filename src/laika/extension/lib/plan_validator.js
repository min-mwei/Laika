(function (root) {
  "use strict";

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  var TOOL_SCHEMAS = {
    "browser.observe_dom": {
      required: {},
      optional: {
        maxChars: "number",
        maxElements: "number",
        maxBlocks: "number",
        maxPrimaryChars: "number",
        maxOutline: "number",
        maxOutlineChars: "number",
        maxItems: "number",
        maxItemChars: "number",
        maxComments: "number",
        maxCommentChars: "number",
        rootHandleId: "string"
      }
    },
    "browser.get_selection_links": {
      required: {},
      optional: { maxLinks: "number" }
    },
    "browser.click": { required: { handleId: "string" }, optional: {} },
    "browser.type": { required: { handleId: "string", text: "string" }, optional: {} },
    "browser.scroll": { required: { deltaY: "number" }, optional: {} },
    "browser.open_tab": { required: { url: "string" }, optional: {} },
    "browser.navigate": { required: { url: "string" }, optional: {} },
    "browser.back": { required: {}, optional: {} },
    "browser.forward": { required: {}, optional: {} },
    "browser.refresh": { required: {}, optional: {} },
    "browser.select": { required: { handleId: "string", value: "string" }, optional: {} },
    "search": { required: { query: "string" }, optional: { engine: "string", newTab: "bool" } },
    "app.calculate": { required: { expression: "string" }, optional: { precision: "number" } }
  };

  function getAllowedKeys(schema) {
    if (!schema) {
      return [];
    }
    var keys = [];
    var required = schema.required || {};
    var optional = schema.optional || {};
    for (var key in required) {
      if (Object.prototype.hasOwnProperty.call(required, key)) {
        keys.push(key);
      }
    }
    for (var optionalKey in optional) {
      if (Object.prototype.hasOwnProperty.call(optional, optionalKey)) {
        keys.push(optionalKey);
      }
    }
    return keys;
  }

  function validateToolCall(toolCall) {
    if (!isObject(toolCall)) {
      return "missing toolCall";
    }
    var schema = typeof toolCall.name === "string" ? TOOL_SCHEMAS[toolCall.name] : null;
    if (typeof toolCall.name !== "string" || !schema) {
      return "unsupported tool name";
    }
    if (typeof toolCall.id !== "string" || toolCall.id.length < 8) {
      return "missing tool id";
    }
    var args = toolCall.arguments || {};
    if (!isObject(args)) {
      return "invalid tool arguments";
    }
    function isFiniteNumber(value) {
      return typeof value === "number" && isFinite(value);
    }
    function hasOnlyKeys(allowed) {
      for (var key in args) {
        if (Object.prototype.hasOwnProperty.call(args, key) && allowed.indexOf(key) === -1) {
          return false;
        }
      }
      return true;
    }

    if (toolCall.name === "browser.observe_dom") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "observe_dom has unknown arguments";
      }
      if (typeof args.maxChars !== "undefined" && !isFiniteNumber(args.maxChars)) {
        return "observe_dom.maxChars must be number";
      }
      if (typeof args.maxElements !== "undefined" && !isFiniteNumber(args.maxElements)) {
        return "observe_dom.maxElements must be number";
      }
      if (typeof args.maxBlocks !== "undefined" && !isFiniteNumber(args.maxBlocks)) {
        return "observe_dom.maxBlocks must be number";
      }
      if (typeof args.maxPrimaryChars !== "undefined" && !isFiniteNumber(args.maxPrimaryChars)) {
        return "observe_dom.maxPrimaryChars must be number";
      }
      if (typeof args.maxOutline !== "undefined" && !isFiniteNumber(args.maxOutline)) {
        return "observe_dom.maxOutline must be number";
      }
      if (typeof args.maxOutlineChars !== "undefined" && !isFiniteNumber(args.maxOutlineChars)) {
        return "observe_dom.maxOutlineChars must be number";
      }
      if (typeof args.maxItems !== "undefined" && !isFiniteNumber(args.maxItems)) {
        return "observe_dom.maxItems must be number";
      }
      if (typeof args.maxItemChars !== "undefined" && !isFiniteNumber(args.maxItemChars)) {
        return "observe_dom.maxItemChars must be number";
      }
      if (typeof args.maxComments !== "undefined" && !isFiniteNumber(args.maxComments)) {
        return "observe_dom.maxComments must be number";
      }
      if (typeof args.maxCommentChars !== "undefined" && !isFiniteNumber(args.maxCommentChars)) {
        return "observe_dom.maxCommentChars must be number";
      }
      if (typeof args.rootHandleId !== "undefined" && typeof args.rootHandleId !== "string") {
        return "observe_dom.rootHandleId must be string";
      }
      return null;
    }

    if (toolCall.name === "browser.get_selection_links") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "get_selection_links has unknown arguments";
      }
      if (typeof args.maxLinks !== "undefined") {
        if (!isFiniteNumber(args.maxLinks)) {
          return "get_selection_links.maxLinks must be number";
        }
        if (Math.floor(args.maxLinks) !== args.maxLinks || args.maxLinks < 1 || args.maxLinks > 200) {
          return "get_selection_links.maxLinks must be integer 1..200";
        }
      }
      return null;
    }

    if (toolCall.name === "browser.click") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "click has unknown arguments";
      }
      return typeof args.handleId === "string" && args.handleId ? null : "click.handleId required";
    }
    if (toolCall.name === "browser.type") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "type has unknown arguments";
      }
      if (typeof args.handleId !== "string" || !args.handleId) {
        return "type.handleId required";
      }
      if (typeof args.text !== "string") {
        return "type.text required";
      }
      return null;
    }
    if (toolCall.name === "browser.select") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "select has unknown arguments";
      }
      if (typeof args.handleId !== "string" || !args.handleId) {
        return "select.handleId required";
      }
      if (typeof args.value !== "string" || !args.value) {
        return "select.value required";
      }
      return null;
    }
    if (toolCall.name === "browser.scroll") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "scroll has unknown arguments";
      }
      return isFiniteNumber(args.deltaY) ? null : "scroll.deltaY required";
    }
    if (toolCall.name === "browser.open_tab" || toolCall.name === "browser.navigate") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "url has unknown arguments";
      }
      return typeof args.url === "string" && args.url ? null : "url required";
    }
    if (toolCall.name === "browser.back" || toolCall.name === "browser.forward" || toolCall.name === "browser.refresh") {
      return Object.keys(args).length === 0 ? null : "no arguments allowed";
    }
    if (toolCall.name === "search") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "search has unknown arguments";
      }
      if (typeof args.query !== "string" || !args.query) {
        return "search.query required";
      }
      if (typeof args.engine !== "undefined" && typeof args.engine !== "string") {
        return "search.engine must be string";
      }
      if (typeof args.newTab !== "undefined" && typeof args.newTab !== "boolean") {
        return "search.newTab must be boolean";
      }
      return null;
    }
    if (toolCall.name === "app.calculate") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "calculate has unknown arguments";
      }
      if (typeof args.expression !== "string" || !args.expression) {
        return "calculate.expression required";
      }
      if (typeof args.precision !== "undefined") {
        if (typeof args.precision !== "number" || !isFinite(args.precision)) {
          return "calculate.precision must be number";
        }
        if (Math.floor(args.precision) !== args.precision || args.precision < 0 || args.precision > 6) {
          return "calculate.precision must be integer 0..6";
        }
      }
      return null;
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

  function getToolSchemaSnapshot() {
    return { tools: TOOL_SCHEMAS };
  }

  var api = {
    validatePlanResponse: validatePlanResponse,
    getToolSchemaSnapshot: getToolSchemaSnapshot
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaPlanValidator = api;
  }
})(typeof window !== "undefined" ? window : undefined);
