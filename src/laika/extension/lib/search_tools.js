(function (root) {
  "use strict";

  var PROVIDERS = {
    google: { template: "https://www.google.com/search?q={query}" },
    duckduckgo: { template: "https://duckduckgo.com/?q={query}" },
    bing: { template: "https://www.bing.com/search?q={query}" },
    yahoo: { template: "https://search.yahoo.com/search?p={query}" }
  };

  var DEFAULT_SETTINGS = {
    mode: "direct",
    customTemplate: "https://www.google.com/search?q={query}",
    defaultEngine: "google",
    addLoopParam: false,
    loopParam: "laika_redirect",
    maxQueryLength: 512
  };

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function normalizeWhitespace(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  function clampPositiveInt(value, fallback) {
    if (typeof value !== "number" || !isFinite(value)) {
      return fallback;
    }
    var rounded = Math.floor(value);
    return rounded > 0 ? rounded : fallback;
  }

  function normalizeQuery(query, maxLength) {
    var normalized = normalizeWhitespace(query);
    if (!normalized) {
      return "";
    }
    var limit = clampPositiveInt(maxLength, DEFAULT_SETTINGS.maxQueryLength);
    if (normalized.length > limit) {
      normalized = normalized.slice(0, limit);
    }
    return normalized;
  }

  function normalizeEngine(engine) {
    return normalizeWhitespace(engine).toLowerCase();
  }

  function normalizeSettings(settings) {
    var normalized = {
      mode: DEFAULT_SETTINGS.mode,
      customTemplate: DEFAULT_SETTINGS.customTemplate,
      defaultEngine: DEFAULT_SETTINGS.defaultEngine,
      addLoopParam: DEFAULT_SETTINGS.addLoopParam,
      loopParam: DEFAULT_SETTINGS.loopParam,
      maxQueryLength: DEFAULT_SETTINGS.maxQueryLength
    };
    if (!isObject(settings)) {
      return normalized;
    }
    if (settings.mode === "direct" || settings.mode === "redirect-default") {
      normalized.mode = settings.mode;
    }
    if (typeof settings.customTemplate === "string") {
      var template = normalizeWhitespace(settings.customTemplate);
      if (template) {
        normalized.customTemplate = template;
      }
    }
    if (typeof settings.defaultEngine === "string") {
      var engine = normalizeEngine(settings.defaultEngine);
      if (engine === "custom" || PROVIDERS[engine]) {
        normalized.defaultEngine = engine;
      }
    }
    if (typeof settings.addLoopParam === "boolean") {
      normalized.addLoopParam = settings.addLoopParam;
    }
    if (typeof settings.loopParam === "string") {
      var loopParam = normalizeWhitespace(settings.loopParam);
      if (loopParam) {
        normalized.loopParam = loopParam;
      }
    }
    normalized.maxQueryLength = clampPositiveInt(settings.maxQueryLength, normalized.maxQueryLength);
    return normalized;
  }

  function resolveEngine(engine, settings) {
    var normalized = normalizeEngine(engine);
    if (normalized === "default") {
      normalized = normalizeEngine(settings.defaultEngine);
    }
    if (!normalized) {
      if (settings.mode === "redirect-default") {
        normalized = normalizeEngine(settings.defaultEngine);
      } else {
        normalized = "custom";
      }
    }
    if (normalized === "custom" || PROVIDERS[normalized]) {
      return normalized;
    }
    return "custom";
  }

  function applyTemplate(template, query) {
    var encoded = encodeURIComponent(query);
    if (template.indexOf("{query}") !== -1) {
      return template.split("{query}").join(encoded);
    }
    if (template.indexOf("%s") !== -1) {
      return template.split("%s").join(encoded);
    }
    return template + encoded;
  }

  function appendLoopParam(url, loopParam) {
    if (!loopParam) {
      return { url: url, alreadyApplied: false };
    }
    try {
      var parsed = new URL(url);
      if (parsed.searchParams.has(loopParam)) {
        return { url: parsed.toString(), alreadyApplied: true };
      }
      parsed.searchParams.set(loopParam, "1");
      return { url: parsed.toString(), alreadyApplied: false };
    } catch (error) {
      return { url: url, alreadyApplied: false };
    }
  }

  function buildSearchUrl(query, engine, settings) {
    var normalizedSettings = normalizeSettings(settings);
    var normalizedQuery = normalizeQuery(query, normalizedSettings.maxQueryLength);
    if (!normalizedQuery) {
      return { error: "missing_query" };
    }
    var resolvedEngine = resolveEngine(engine, normalizedSettings);
    var template = resolvedEngine === "custom"
      ? normalizedSettings.customTemplate
      : (PROVIDERS[resolvedEngine] ? PROVIDERS[resolvedEngine].template : normalizedSettings.customTemplate);
    if (!template) {
      return { error: "missing_template" };
    }
    var url = applyTemplate(template, normalizedQuery);
    var addLoopParam = normalizedSettings.addLoopParam;
    if (typeof addLoopParam !== "boolean") {
      addLoopParam = normalizedSettings.mode === "redirect-default";
    }
    var loopApplied = false;
    if (addLoopParam && normalizedSettings.loopParam) {
      var guarded = appendLoopParam(url, normalizedSettings.loopParam);
      url = guarded.url;
      loopApplied = !guarded.alreadyApplied;
    }
    return {
      url: url,
      query: normalizedQuery,
      engine: resolvedEngine,
      loopParam: normalizedSettings.loopParam,
      loopApplied: loopApplied
    };
  }

  var api = {
    DEFAULT_SETTINGS: DEFAULT_SETTINGS,
    PROVIDERS: PROVIDERS,
    normalizeSettings: normalizeSettings,
    normalizeQuery: normalizeQuery,
    resolveEngine: resolveEngine,
    applyTemplate: applyTemplate,
    appendLoopParam: appendLoopParam,
    buildSearchUrl: buildSearchUrl
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaSearchTools = api;
  }
})(typeof self !== "undefined" ? self : undefined);
