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
        rootHandleId: "string",
        includeMarkdown: "bool",
        captureMode: "string",
        captureMaxChars: "number",
        captureLinks: "bool"
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
    "browser.navigate": { required: { url: "string" }, optional: { waitForReady: "bool" } },
    "browser.back": { required: {}, optional: { waitForReady: "bool" } },
    "browser.forward": { required: {}, optional: { waitForReady: "bool" } },
    "browser.refresh": { required: {}, optional: { waitForReady: "bool" } },
    "browser.select": { required: { handleId: "string", value: "string" }, optional: {} },
    "search": { required: { query: "string" }, optional: { engine: "string", newTab: "bool" } },
    "app.calculate": { required: { expression: "string" }, optional: { precision: "number" } },
    "artifact.save": {
      required: { title: "string", markdown: "string" },
      optional: { tags: "array", redaction: "string" }
    },
    "artifact.open": {
      required: { artifactId: "string" },
      optional: { target: "string", newTab: "bool" }
    },
    "artifact.share": {
      required: { artifactId: "string", format: "string" },
      optional: { filename: "string", target: "string" }
    },
    "integration.invoke": {
      required: { integration: "string", operation: "string", payload: "object" },
      optional: { idempotencyKey: "string" }
    },
    "collection.create": { required: { title: "string" }, optional: { tags: "array" } },
    "collection.add_sources": { required: { collectionId: "string", sources: "array" }, optional: {} },
    "collection.list_sources": { required: { collectionId: "string" }, optional: {} },
    "source.capture": {
      required: { collectionId: "string", url: "string" },
      optional: { mode: "string", maxChars: "number" }
    },
    "source.refresh": { required: { sourceId: "string" }, optional: {} },
    "transform.list_types": { required: {}, optional: {} },
    "transform.run": { required: { collectionId: "string", type: "string" }, optional: { config: "object" } }
  };

  var ENABLED_TOOLS = {
    "browser.observe_dom": true,
    "browser.get_selection_links": true,
    "browser.click": true,
    "browser.type": true,
    "browser.scroll": true,
    "browser.open_tab": true,
    "browser.navigate": true,
    "browser.back": true,
    "browser.forward": true,
    "browser.refresh": true,
    "browser.select": true,
    "search": true,
    "app.calculate": true,
    "collection.create": true,
    "collection.add_sources": true,
    "collection.list_sources": true,
    "source.capture": true
  };

  function isToolEnabled(name) {
    return !!ENABLED_TOOLS[name];
  }

  function enabledSchemas() {
    var output = {};
    Object.keys(ENABLED_TOOLS).forEach(function (name) {
      if (TOOL_SCHEMAS[name]) {
        output[name] = TOOL_SCHEMAS[name];
      }
    });
    return output;
  }

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
    if (typeof toolCall.name !== "string" || !isToolEnabled(toolCall.name)) {
      return "unsupported tool name";
    }
    var schema = TOOL_SCHEMAS[toolCall.name];
    if (!schema) {
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
    function isString(value) {
      return typeof value === "string" && value.length > 0;
    }
    function isStringArray(value) {
      if (!Array.isArray(value)) {
        return false;
      }
      for (var index = 0; index < value.length; index += 1) {
        if (typeof value[index] !== "string") {
          return false;
        }
      }
      return true;
    }
    function isPlainObject(value) {
      return isObject(value);
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
      if (typeof args.includeMarkdown !== "undefined" && typeof args.includeMarkdown !== "boolean") {
        return "observe_dom.includeMarkdown must be boolean";
      }
      if (typeof args.captureLinks !== "undefined" && typeof args.captureLinks !== "boolean") {
        return "observe_dom.captureLinks must be boolean";
      }
      if (typeof args.captureMode !== "undefined") {
        if (args.captureMode !== "auto" && args.captureMode !== "article" && args.captureMode !== "list") {
          return "observe_dom.captureMode invalid";
        }
      }
      if (typeof args.captureMaxChars !== "undefined" && !isFiniteNumber(args.captureMaxChars)) {
        return "observe_dom.captureMaxChars must be number";
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
      if (!isString(args.expression)) {
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

    if (toolCall.name === "artifact.save") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "artifact.save has unknown arguments";
      }
      if (!isString(args.title)) {
        return "artifact.save.title required";
      }
      if (!isString(args.markdown)) {
        return "artifact.save.markdown required";
      }
      if (typeof args.tags !== "undefined" && !isStringArray(args.tags)) {
        return "artifact.save.tags must be string[]";
      }
      if (typeof args.redaction !== "undefined") {
        if (args.redaction !== "default" && args.redaction !== "none") {
          return "artifact.save.redaction invalid";
        }
      }
      return null;
    }

    if (toolCall.name === "artifact.open") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "artifact.open has unknown arguments";
      }
      if (!isString(args.artifactId)) {
        return "artifact.open.artifactId required";
      }
      if (typeof args.target !== "undefined") {
        if (args.target !== "viewer" && args.target !== "source" && args.target !== "download") {
          return "artifact.open.target invalid";
        }
      }
      if (typeof args.newTab !== "undefined" && typeof args.newTab !== "boolean") {
        return "artifact.open.newTab must be boolean";
      }
      return null;
    }

    if (toolCall.name === "artifact.share") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "artifact.share has unknown arguments";
      }
      if (!isString(args.artifactId)) {
        return "artifact.share.artifactId required";
      }
      if (!isString(args.format)) {
        return "artifact.share.format required";
      }
      var allowedFormats = ["markdown", "text", "json", "csv", "pdf"];
      if (allowedFormats.indexOf(args.format) === -1) {
        return "artifact.share.format invalid";
      }
      if (typeof args.filename !== "undefined" && !isString(args.filename)) {
        return "artifact.share.filename must be string";
      }
      if (typeof args.target !== "undefined") {
        var allowedTargets = ["viewer", "source", "download"];
        if (allowedTargets.indexOf(args.target) === -1) {
          return "artifact.share.target invalid";
        }
      }
      return null;
    }

    if (toolCall.name === "integration.invoke") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "integration.invoke has unknown arguments";
      }
      if (!isString(args.integration)) {
        return "integration.invoke.integration required";
      }
      if (!isString(args.operation)) {
        return "integration.invoke.operation required";
      }
      if (!isPlainObject(args.payload)) {
        return "integration.invoke.payload required";
      }
      if (typeof args.idempotencyKey !== "undefined" && !isString(args.idempotencyKey)) {
        return "integration.invoke.idempotencyKey must be string";
      }
      return null;
    }

    if (toolCall.name === "collection.create") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "collection.create has unknown arguments";
      }
      if (!isString(args.title)) {
        return "collection.create.title required";
      }
      if (typeof args.tags !== "undefined" && !isStringArray(args.tags)) {
        return "collection.create.tags must be string[]";
      }
      return null;
    }

    if (toolCall.name === "collection.add_sources") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "collection.add_sources has unknown arguments";
      }
      if (!isString(args.collectionId)) {
        return "collection.add_sources.collectionId required";
      }
      if (!Array.isArray(args.sources)) {
        return "collection.add_sources.sources required";
      }
      for (var sourceIndex = 0; sourceIndex < args.sources.length; sourceIndex += 1) {
        var sourceItem = args.sources[sourceIndex];
        if (!isPlainObject(sourceItem)) {
          return "collection.add_sources.sources invalid";
        }
        if (sourceItem.type === "url") {
          if (!isString(sourceItem.url)) {
            return "collection.add_sources.url required";
          }
          if (typeof sourceItem.title !== "undefined" && !isString(sourceItem.title)) {
            return "collection.add_sources.title must be string";
          }
          var urlKeys = Object.keys(sourceItem);
          for (var urlKeyIndex = 0; urlKeyIndex < urlKeys.length; urlKeyIndex += 1) {
            var urlKey = urlKeys[urlKeyIndex];
            if (["type", "url", "title"].indexOf(urlKey) === -1) {
              return "collection.add_sources has unknown source keys";
            }
          }
        } else if (sourceItem.type === "note") {
          if (!isString(sourceItem.text)) {
            return "collection.add_sources.text required";
          }
          if (typeof sourceItem.title !== "undefined" && !isString(sourceItem.title)) {
            return "collection.add_sources.title must be string";
          }
          var noteKeys = Object.keys(sourceItem);
          for (var noteKeyIndex = 0; noteKeyIndex < noteKeys.length; noteKeyIndex += 1) {
            var noteKey = noteKeys[noteKeyIndex];
            if (["type", "text", "title"].indexOf(noteKey) === -1) {
              return "collection.add_sources has unknown source keys";
            }
          }
        } else {
          return "collection.add_sources.type invalid";
        }
      }
      return null;
    }

    if (toolCall.name === "collection.list_sources") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "collection.list_sources has unknown arguments";
      }
      if (!isString(args.collectionId)) {
        return "collection.list_sources.collectionId required";
      }
      return null;
    }

    if (toolCall.name === "source.capture") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "source.capture has unknown arguments";
      }
      if (!isString(args.collectionId)) {
        return "source.capture.collectionId required";
      }
      if (!isString(args.url)) {
        return "source.capture.url required";
      }
      if (typeof args.mode !== "undefined") {
        if (args.mode !== "auto" && args.mode !== "article" && args.mode !== "list") {
          return "source.capture.mode invalid";
        }
      }
      if (typeof args.maxChars !== "undefined" && !isFiniteNumber(args.maxChars)) {
        return "source.capture.maxChars must be number";
      }
      return null;
    }

    if (toolCall.name === "source.refresh") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "source.refresh has unknown arguments";
      }
      if (!isString(args.sourceId)) {
        return "source.refresh.sourceId required";
      }
      return null;
    }

    if (toolCall.name === "transform.list_types") {
      return Object.keys(args).length === 0 ? null : "transform.list_types has unknown arguments";
    }

    if (toolCall.name === "transform.run") {
      if (!hasOnlyKeys(getAllowedKeys(schema))) {
        return "transform.run has unknown arguments";
      }
      if (!isString(args.collectionId)) {
        return "transform.run.collectionId required";
      }
      if (!isString(args.type)) {
        return "transform.run.type required";
      }
      if (typeof args.config !== "undefined" && !isPlainObject(args.config)) {
        return "transform.run.config must be object";
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
    return { tools: enabledSchemas() };
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
