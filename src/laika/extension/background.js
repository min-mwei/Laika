"use strict";

var SearchTools = null;
var PlanValidator = null;
var AgentRunner = null;
var CalculateTools = null;
var SEARCH_TOOLS_INIT = { imported: false, usedFallback: false, importError: "" };
try {
  if (typeof importScripts === "function") {
    importScripts("lib/search_tools.js");
  }
} catch (error) {
  try {
    SEARCH_TOOLS_INIT.importError = String(error && error.message ? error.message : error);
  } catch (innerError) {
    SEARCH_TOOLS_INIT.importError = "import_failed";
  }
}
if (typeof self !== "undefined" && self.LaikaSearchTools) {
  SearchTools = self.LaikaSearchTools;
  SEARCH_TOOLS_INIT.imported = true;
}
try {
  if (typeof importScripts === "function") {
    importScripts("lib/plan_validator.js");
  }
} catch (error) {
}
if (typeof self !== "undefined" && self.LaikaPlanValidator) {
  PlanValidator = self.LaikaPlanValidator;
}
try {
  if (typeof importScripts === "function") {
    importScripts("lib/agent_runner.js");
  }
} catch (error) {
}
if (typeof self !== "undefined" && self.LaikaAgentRunner) {
  AgentRunner = self.LaikaAgentRunner;
}
try {
  if (typeof importScripts === "function") {
    importScripts("lib/calculate.js");
  }
} catch (error) {
}
if (typeof self !== "undefined" && self.LaikaCalculate) {
  CalculateTools = self.LaikaCalculate;
}
if (!SearchTools) {
  SEARCH_TOOLS_INIT.usedFallback = true;
  SearchTools = (function () {
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
    return {
      DEFAULT_SETTINGS: DEFAULT_SETTINGS,
      normalizeSettings: normalizeSettings,
      normalizeQuery: normalizeQuery,
      resolveEngine: resolveEngine,
      applyTemplate: applyTemplate,
      appendLoopParam: appendLoopParam,
      buildSearchUrl: buildSearchUrl
    };
  })();
}

var ALLOWED_TOOLS = {
  "browser.observe_dom": true,
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
  "app.calculate": true
};

var ToolErrorCode = {
  INVALID_ARGUMENTS: "INVALID_ARGUMENTS",
  MISSING_URL: "MISSING_URL",
  INVALID_URL: "INVALID_URL",
  NO_ACTIVE_TAB: "NO_ACTIVE_TAB",
  NO_TARGET_TAB: "NO_TARGET_TAB",
  NO_CONTEXT: "NO_CONTEXT",
  TIMEOUT: "TIMEOUT",
  UNSUPPORTED_TOOL: "UNSUPPORTED_TOOL",
  OPEN_TAB_FAILED: "OPEN_TAB_FAILED",
  NAVIGATION_FAILED: "NAVIGATION_FAILED",
  BACK_FAILED: "BACK_FAILED",
  FORWARD_FAILED: "FORWARD_FAILED",
  REFRESH_FAILED: "REFRESH_FAILED",
  RUNTIME_UNAVAILABLE: "RUNTIME_UNAVAILABLE",
  SEARCH_UNAVAILABLE: "SEARCH_UNAVAILABLE",
  SEARCH_FAILED: "SEARCH_FAILED"
};

var NATIVE_APP_ID = "com.laika.Laika";
var AUTOMATION_ALLOWED_HOSTS = {
  "127.0.0.1": true,
  "localhost": true
};
var AUTOMATION_RUNS = {};
var AUTOMATION_PORTS = {};
var AUTOMATION_ENABLED_KEY = "automationEnabled";
var AUTOMATION_ENABLED_DEFAULT = false;
var automationEnabledCache = null;
var automationEnabledPromise = null;
var AUTOMATION_STORAGE_PREFIX = "laika.automation.";
var TAB_MESSAGE_TIMEOUT_MS = 12000;
var TAB_READY_TIMEOUT_MS = 4000;
var TAB_SCRIPTABLE_TIMEOUT_MS = 2500;
var TAB_INJECTION_DELAY_MS = 250;
var TAB_PING_TIMEOUT_MS = 2000;
var TAB_PING_TOTAL_MS = 8000;
var CONTENT_SCRIPT_FILES = ["lib/text_utils.js", "content_script.js"];

var DEFAULT_SIDECAR_SIDE = "right";
var DEFAULT_SIDECAR_STICKY = true;
var PANEL_STATE_BY_OWNER = {};
var PANEL_TAB_TO_OWNER = {};
var PANEL_OPEN_PROMISES = {};
var MAX_TAB_CONTEXT = 12;
var MAX_TAB_TITLE = 120;
var SIDECAR_STATE_BY_WINDOW = {};
var SIDECAR_STATE_STORAGE_KEY = "sidecarOpenByWindow";
var sidecarStateLoaded = false;
var sidecarStateLoadPromise = null;
var sidecarStateSaveTimer = null;
var SIDECAR_RETRY_BY_TAB = {};
var SIDECAR_RETRY_LIMIT = 4;
var SIDECAR_RETRY_BASE_DELAY = 200;
var SIDECAR_LOG_ENABLED = true;
var SEARCH_LOG_ENABLED = true;
var SEARCH_SETTINGS_KEY = "searchSettings";
var searchSettingsCache = null;
var searchSettingsLoadPromise = null;

function isNumericId(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function logSidecar(message, details) {
  if (!SIDECAR_LOG_ENABLED || typeof console === "undefined") {
    return;
  }
  if (console.debug) {
    console.debug("[Laika][sidecar]", message, details || "");
    return;
  }
  if (console.log) {
    console.log("[Laika][sidecar]", message, details || "");
  }
}

function logSearch(message, details) {
  if (!SEARCH_LOG_ENABLED || typeof console === "undefined") {
    return;
  }
  if (console.debug) {
    console.debug("[Laika][search]", message, details || "");
    return;
  }
  if (console.log) {
    console.log("[Laika][search]", message, details || "");
  }
}

(function logSearchInit() {
  var details = {
    imported: SEARCH_TOOLS_INIT.imported,
    fallback: SEARCH_TOOLS_INIT.usedFallback
  };
  if (SEARCH_TOOLS_INIT.importError) {
    details.importError = SEARCH_TOOLS_INIT.importError;
  }
  if (SearchTools && SearchTools.DEFAULT_SETTINGS) {
    details.defaultEngine = SearchTools.DEFAULT_SETTINGS.defaultEngine || "";
    details.mode = SearchTools.DEFAULT_SETTINGS.mode || "";
  }
  logSearch("init", details);
})();

function isSearchResultsUrl(url) {
  if (!url) {
    return false;
  }
  try {
    var parsed = new URL(String(url));
    var host = (parsed.hostname || "").toLowerCase();
    var path = parsed.pathname || "";
    if (host.indexOf("google.") >= 0 && path === "/search") {
      return parsed.searchParams && parsed.searchParams.has("q");
    }
    if (host.indexOf("duckduckgo.com") >= 0 && path === "/") {
      return parsed.searchParams && parsed.searchParams.has("q");
    }
    if (host.indexOf("bing.com") >= 0 && path === "/search") {
      return parsed.searchParams && parsed.searchParams.has("q");
    }
    if (host === "search.yahoo.com" && path === "/search") {
      return parsed.searchParams && parsed.searchParams.has("p");
    }
  } catch (error) {
  }
  return false;
}

function isTrustedUiSender(sender) {
  if (!sender || !sender.url || !browser.runtime || !browser.runtime.getURL) {
    return false;
  }
  var base = browser.runtime.getURL("popover.html");
  return typeof sender.url === "string" && sender.url.indexOf(base) === 0;
}

function summarizeTemplateHost(template) {
  if (!template) {
    return "";
  }
  var replaced = String(template)
    .replace("{query}", "test")
    .replace("%s", "test");
  try {
    var parsed = new URL(replaced);
    return parsed.hostname || "";
  } catch (error) {
    return "";
  }
}

function urlInfo(url) {
  if (!url) {
    return { origin: "", path: "" };
  }
  try {
    var parsed = new URL(url);
    return { origin: parsed.origin, path: parsed.pathname };
  } catch (error) {
    return { origin: "", path: "" };
  }
}

function getOwnerKey(windowId) {
  if (!isNumericId(windowId)) {
    return "unknown";
  }
  return String(windowId);
}

function setSidecarOpenState(windowId, isOpen) {
  if (!isNumericId(windowId)) {
    return;
  }
  SIDECAR_STATE_BY_WINDOW[String(windowId)] = { isOpen: !!isOpen };
  queueSidecarStateSave();
  logSidecar("state", { windowId: windowId, isOpen: !!isOpen });
}

function isSidecarOpen(windowId) {
  if (!isNumericId(windowId)) {
    return false;
  }
  var state = SIDECAR_STATE_BY_WINDOW[String(windowId)];
  return !!(state && state.isOpen);
}

function clearSidecarState(windowId) {
  if (!isNumericId(windowId)) {
    return;
  }
  delete SIDECAR_STATE_BY_WINDOW[String(windowId)];
  queueSidecarStateSave();
  logSidecar("state_cleared", { windowId: windowId });
}

function normalizeSidecarState(value) {
  if (!value || typeof value !== "object") {
    return {};
  }
  var next = {};
  var keys = Object.keys(value);
  for (var i = 0; i < keys.length; i += 1) {
    var entry = value[keys[i]];
    if (!entry || typeof entry !== "object") {
      continue;
    }
    next[keys[i]] = { isOpen: !!entry.isOpen };
  }
  return next;
}

function mergeSidecarState(saved) {
  var normalized = normalizeSidecarState(saved);
  var currentKeys = Object.keys(SIDECAR_STATE_BY_WINDOW);
  for (var i = 0; i < currentKeys.length; i += 1) {
    normalized[currentKeys[i]] = SIDECAR_STATE_BY_WINDOW[currentKeys[i]];
  }
  SIDECAR_STATE_BY_WINDOW = normalized;
}

function loadSidecarState() {
  if (sidecarStateLoaded) {
    return Promise.resolve();
  }
  if (sidecarStateLoadPromise) {
    return sidecarStateLoadPromise;
  }
  if (!browser.storage || !browser.storage.local) {
    sidecarStateLoaded = true;
    return Promise.resolve();
  }
  sidecarStateLoadPromise = browser.storage.local
    .get((function () {
      var defaults = {};
      defaults[SIDECAR_STATE_STORAGE_KEY] = {};
      return defaults;
    })())
    .then(function (stored) {
      mergeSidecarState(stored ? stored[SIDECAR_STATE_STORAGE_KEY] : null);
      sidecarStateLoaded = true;
      logSidecar("state_loaded", { windows: Object.keys(SIDECAR_STATE_BY_WINDOW).length });
    })
    .catch(function () {
      sidecarStateLoaded = true;
      logSidecar("state_load_failed");
    });
  return sidecarStateLoadPromise;
}

function queueSidecarStateSave() {
  if (!browser.storage || !browser.storage.local) {
    return;
  }
  if (sidecarStateSaveTimer) {
    return;
  }
  sidecarStateSaveTimer = setTimeout(function () {
    sidecarStateSaveTimer = null;
    var payload = {};
    payload[SIDECAR_STATE_STORAGE_KEY] = SIDECAR_STATE_BY_WINDOW;
    var request = browser.storage.local.set(payload);
    if (request && request.catch) {
      request.catch(function () {
      });
    }
  }, 120);
}

function getPanelState(ownerWindowId) {
  return PANEL_STATE_BY_OWNER[getOwnerKey(ownerWindowId)] || null;
}

function setPanelState(ownerWindowId, state) {
  var key = getOwnerKey(ownerWindowId);
  PANEL_STATE_BY_OWNER[key] = state;
  if (state && isNumericId(state.panelTabId)) {
    PANEL_TAB_TO_OWNER[String(state.panelTabId)] = key;
  }
}

function clearPanelState(ownerWindowId) {
  var key = getOwnerKey(ownerWindowId);
  var existing = PANEL_STATE_BY_OWNER[key];
  if (existing && isNumericId(existing.panelTabId)) {
    delete PANEL_TAB_TO_OWNER[String(existing.panelTabId)];
  }
  delete PANEL_STATE_BY_OWNER[key];
}

function getPanelStateByTabId(tabId) {
  var key = PANEL_TAB_TO_OWNER[String(tabId)];
  if (!key) {
    return null;
  }
  return PANEL_STATE_BY_OWNER[key] || null;
}

function getPanelMeta(url) {
  if (!url || !browser.runtime || !browser.runtime.getURL) {
    return null;
  }
  try {
    var base = browser.runtime.getURL("popover.html");
    if (typeof base !== "string" || url.indexOf(base) !== 0) {
      return null;
    }
    var parsed = new URL(url);
    if (parsed.searchParams.get("panel") !== "1") {
      return null;
    }
    var ownerWindowId = parseInt(parsed.searchParams.get("ownerWindow") || "", 10);
    var ownerTabId = parseInt(parsed.searchParams.get("ownerTab") || "", 10);
    return {
      ownerWindowId: Number.isNaN(ownerWindowId) ? null : ownerWindowId,
      ownerTabId: Number.isNaN(ownerTabId) ? null : ownerTabId
    };
  } catch (error) {
    return null;
  }
}

function isPanelUrl(url) {
  return !!getPanelMeta(url);
}

async function findPanelTab(ownerWindowId) {
  if (!browser.tabs || !browser.tabs.query) {
    return null;
  }
  var tabs;
  try {
    tabs = await browser.tabs.query({});
  } catch (error) {
    return null;
  }
  var matchUnknownOwner = !isNumericId(ownerWindowId);
  for (var i = 0; i < tabs.length; i += 1) {
    var meta = getPanelMeta(tabs[i].url);
    if (!meta) {
      continue;
    }
    if (matchUnknownOwner) {
      if (isNumericId(meta.ownerWindowId)) {
        continue;
      }
    } else if (!isNumericId(meta.ownerWindowId) || meta.ownerWindowId !== ownerWindowId) {
      continue;
    }
    return { tab: tabs[i], meta: meta };
  }
  return null;
}

async function focusTab(tab) {
  if (!tab || typeof tab.id === "undefined") {
    return;
  }
  if (browser.tabs && browser.tabs.update) {
    try {
      await browser.tabs.update(tab.id, { active: true });
    } catch (error) {
    }
  }
  if (browser.windows && browser.windows.update && typeof tab.windowId !== "undefined") {
    try {
      await browser.windows.update(tab.windowId, { focused: true });
    } catch (error) {
    }
  }
}

async function getActiveTab(windowId) {
  var query = { active: true };
  if (isNumericId(windowId)) {
    query.windowId = windowId;
  } else {
    query.currentWindow = true;
  }
  try {
    var tabs = await browser.tabs.query(query);
    return tabs && tabs.length ? tabs[0] : null;
  } catch (error) {
    return null;
  }
}

function sleep(ms) {
  return new Promise(function (resolve) {
    setTimeout(resolve, ms);
  });
}

function withTimeout(promise, timeoutMs, timeoutCode) {
  return new Promise(function (resolve, reject) {
    var done = false;
    var timer = setTimeout(function () {
      if (done) {
        return;
      }
      done = true;
      var error = new Error(timeoutCode || "timeout");
      error.code = timeoutCode || "timeout";
      reject(error);
    }, timeoutMs);
    promise.then(function (result) {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timer);
      resolve(result);
    }).catch(function (error) {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function waitForTabComplete(tabId, timeoutMs) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get || !browser.tabs.onUpdated) {
    return false;
  }
  try {
    var tab = await browser.tabs.get(tabId);
    if (tab && (!tab.status || tab.status === "complete")) {
      return true;
    }
  } catch (error) {
    return false;
  }
  return new Promise(function (resolve) {
    var done = false;
    var timer = null;
    function cleanup() {
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      if (browser.tabs && browser.tabs.onUpdated && browser.tabs.onUpdated.removeListener) {
        browser.tabs.onUpdated.removeListener(handleUpdated);
      }
      if (browser.tabs && browser.tabs.onRemoved && browser.tabs.onRemoved.removeListener) {
        browser.tabs.onRemoved.removeListener(handleRemoved);
      }
    }
    function finish(ok) {
      if (done) {
        return;
      }
      done = true;
      cleanup();
      resolve(ok);
    }
    function handleUpdated(updatedTabId, changeInfo) {
      if (updatedTabId !== tabId || !changeInfo || changeInfo.status !== "complete") {
        return;
      }
      finish(true);
    }
    function handleRemoved(removedTabId) {
      if (removedTabId === tabId) {
        finish(false);
      }
    }
    if (browser.tabs && browser.tabs.onUpdated && browser.tabs.onUpdated.addListener) {
      browser.tabs.onUpdated.addListener(handleUpdated);
    }
    if (browser.tabs && browser.tabs.onRemoved && browser.tabs.onRemoved.addListener) {
      browser.tabs.onRemoved.addListener(handleRemoved);
    }
    var timeoutValue = typeof timeoutMs === "number" && isFinite(timeoutMs) && timeoutMs > 0
      ? Math.floor(timeoutMs)
      : TAB_READY_TIMEOUT_MS;
    timer = setTimeout(function () {
      finish(false);
    }, timeoutValue);
  });
}

async function waitForTabScriptable(tabId, timeoutMs) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get) {
    return false;
  }
  var timeoutValue = typeof timeoutMs === "number" && isFinite(timeoutMs) && timeoutMs > 0
    ? Math.floor(timeoutMs)
    : TAB_SCRIPTABLE_TIMEOUT_MS;
  var deadline = Date.now() + timeoutValue;
  while (Date.now() < deadline) {
    var tab = null;
    try {
      tab = await browser.tabs.get(tabId);
    } catch (error) {
      return false;
    }
    var url = "";
    if (tab) {
      if (typeof tab.url === "string" && tab.url) {
        url = tab.url;
      } else if (typeof tab.pendingUrl === "string" && tab.pendingUrl) {
        url = tab.pendingUrl;
      }
    }
    if (isScriptableUrl(url)) {
      return true;
    }
    await sleep(200);
  }
  return false;
}

async function injectContentScripts(tabId) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get) {
    return false;
  }
  var tab = null;
  try {
    tab = await browser.tabs.get(tabId);
  } catch (error) {
    return false;
  }
  if (!tab || !isScriptableUrl(tab.url || "")) {
    return false;
  }
  try {
    if (browser.scripting && browser.scripting.executeScript) {
      await browser.scripting.executeScript({
        target: { tabId: tabId },
        files: CONTENT_SCRIPT_FILES
      });
    } else if (browser.tabs.executeScript) {
      for (var i = 0; i < CONTENT_SCRIPT_FILES.length; i += 1) {
        await browser.tabs.executeScript(tabId, { file: CONTENT_SCRIPT_FILES[i] });
      }
    } else {
      return false;
    }
    return true;
  } catch (error) {
    return false;
  }
}

async function sendTabMessageWithTimeout(tabId, payload, options) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.sendMessage) {
    throw new Error("no_tab_message");
  }
  var opts = options && typeof options === "object" ? options : {};
  var timeoutMs = typeof opts.timeoutMs === "number" && isFinite(opts.timeoutMs) && opts.timeoutMs > 0
    ? Math.floor(opts.timeoutMs)
    : TAB_MESSAGE_TIMEOUT_MS;
  var attempts = typeof opts.attempts === "number" && isFinite(opts.attempts) && opts.attempts > 0
    ? Math.floor(opts.attempts)
    : 2;
  var shouldWaitForReady = opts.waitForReady !== false;
  var allowInject = opts.allowInject !== false;
  var didInject = false;

  for (var attempt = 1; attempt <= attempts; attempt += 1) {
    if (shouldWaitForReady) {
      var ready = await waitForTabComplete(tabId, TAB_READY_TIMEOUT_MS);
      var scriptable = await waitForTabScriptable(tabId, TAB_SCRIPTABLE_TIMEOUT_MS);
      if (!scriptable) {
        var readyError = new Error("tab_not_ready");
        readyError.code = "tab_not_ready";
        if (attempt < attempts) {
          await sleep(300);
          continue;
        }
        throw readyError;
      }
      if (!ready) {
        await sleep(200);
      }
    }
    try {
      var response = await withTimeout(browser.tabs.sendMessage(tabId, payload), timeoutMs, "message_timeout");
      if (!response) {
        var responseError = new Error("no_response");
        responseError.code = "no_response";
        throw responseError;
      }
      return response;
    } catch (error) {
      if (allowInject && !didInject) {
        var injected = await injectContentScripts(tabId);
        if (injected) {
          didInject = true;
          await sleep(TAB_INJECTION_DELAY_MS);
          continue;
        }
      }
      if (attempt < attempts) {
        await sleep(300);
        continue;
      }
      throw error;
    }
  }
  throw new Error("message_failed");
}

async function waitForContentScript(tabId) {
  var deadline = Date.now() + TAB_PING_TOTAL_MS;
  while (Date.now() < deadline) {
    if (browser.tabs && browser.tabs.get) {
      try {
        var tab = await browser.tabs.get(tabId);
        if (tab) {
          await focusTab(tab);
        }
      } catch (error) {
      }
    }
    try {
      var result = await sendTabMessageWithTimeout(
        tabId,
        { type: "laika.ping" },
        { allowInject: true, waitForReady: true, timeoutMs: TAB_PING_TIMEOUT_MS, attempts: 2 }
      );
      if (result && result.status === "ok") {
        return true;
      }
    } catch (error) {
    }
    await sleep(300);
  }
  return false;
}

async function handleObserve(options, sender, tabOverride, ensureFocused) {
  var tabId = await resolveTargetTabId(sender, tabOverride);
  if (!isNumericId(tabId)) {
    return { status: "error", error: ToolErrorCode.NO_ACTIVE_TAB };
  }
  var senderUrl = sender && sender.tab ? (sender.tab.url || sender.url || "") : (sender && sender.url ? sender.url : "");
  var isAutomationSender = isAutomationHarnessUrl(senderUrl);
  var tabSnapshot = null;
  if (browser.tabs && browser.tabs.get) {
    try {
      tabSnapshot = await browser.tabs.get(tabId);
    } catch (error) {
      tabSnapshot = null;
    }
  }
  if (tabSnapshot && tabSnapshot.url && browser.permissions && browser.permissions.contains) {
    try {
      var origin = new URL(tabSnapshot.url).origin;
      var allowed = await browser.permissions.contains({ origins: [origin + "/*"] });
      if (!allowed) {
        return {
          status: "error",
          error: ToolErrorCode.NO_CONTEXT,
          tabId: tabId,
          errorDetails: { code: "host_permission_missing", url: tabSnapshot.url }
        };
      }
    } catch (error) {
    }
  }
  if (ensureFocused && browser.tabs && browser.tabs.get) {
    try {
      var tab = await browser.tabs.get(tabId);
      if (tab) {
        await focusTab(tab);
      }
    } catch (error) {
    }
  }
  var ready = await waitForContentScript(tabId);
  if (!ready) {
    if (isAutomationSender && browser.tabs && browser.tabs.reload) {
      try {
        await browser.tabs.reload(tabId);
      } catch (error) {
      }
      ready = await waitForContentScript(tabId);
    }
  }
  if (!ready) {
    return {
      status: "error",
      error: ToolErrorCode.NO_CONTEXT,
      tabId: tabId,
      errorDetails: {
        code: "no_content_script",
        url: tabSnapshot && tabSnapshot.url ? tabSnapshot.url : null,
        status: tabSnapshot && tabSnapshot.status ? tabSnapshot.status : null
      }
    };
  }
  try {
    var result = await sendTabMessageWithTimeout(
      tabId,
      { type: "laika.observe", options: options || {} },
      { allowInject: true, waitForReady: true }
    );
    if (!result || typeof result.status === "undefined") {
      return {
        status: "error",
        error: ToolErrorCode.NO_CONTEXT,
        tabId: tabId,
        errorDetails: { code: "no_response" }
      };
    }
    if (result && typeof result === "object") {
      result.tabId = tabId;
    }
    return result;
  } catch (error) {
    if (error && error.code === "no_response") {
      var ready = await waitForContentScript(tabId);
      if (ready) {
        try {
          var retry = await sendTabMessageWithTimeout(
            tabId,
            { type: "laika.observe", options: options || {} },
            { allowInject: true, waitForReady: true }
          );
          if (retry && typeof retry.status !== "undefined") {
            retry.tabId = tabId;
            return retry;
          }
        } catch (retryError) {
          error = retryError;
        }
      }
    }
    return {
      status: "error",
      error: error && error.code === "message_timeout" ? ToolErrorCode.TIMEOUT : ToolErrorCode.NO_CONTEXT,
      tabId: tabId,
      errorDetails: { code: error && error.code ? error.code : null }
    };
  }
}

async function handleSearchTool(args, sender, tabOverride) {
  if (!SearchTools || typeof SearchTools.buildSearchUrl !== "function") {
    logSearch("error", { stage: "init", error: ToolErrorCode.SEARCH_UNAVAILABLE });
    return { status: "error", error: ToolErrorCode.SEARCH_UNAVAILABLE };
  }
  if (!args || typeof args.query !== "string") {
    logSearch("error", { stage: "validate", error: ToolErrorCode.INVALID_ARGUMENTS });
    return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
  }
  var settings = await loadSearchSettings();
  var engine = typeof args.engine === "string" ? args.engine : "";
  var queryPreview = budgetText(args.query, 120);
  logSearch("request", {
    query: queryPreview,
    engine: engine || "(default)",
    newTab: typeof args.newTab === "boolean" ? args.newTab : true,
    mode: settings.mode,
    defaultEngine: settings.defaultEngine,
    templateHost: summarizeTemplateHost(settings.customTemplate)
  });
  var built = SearchTools.buildSearchUrl(args.query, engine, settings);
  if (!built || built.error) {
    logSearch("error", { stage: "build", error: ToolErrorCode.SEARCH_FAILED });
    return { status: "error", error: ToolErrorCode.SEARCH_FAILED };
  }
  var safeUrl = sanitizeOpenUrl(built.url);
  if (!safeUrl) {
    logSearch("error", { stage: "sanitize", error: ToolErrorCode.INVALID_URL, url: built.url });
    return { status: "error", error: ToolErrorCode.INVALID_URL };
  }
  var urlDetails = urlInfo(safeUrl);
  logSearch("built_url", { url: budgetText(safeUrl, 280) });
  logSearch("built", {
    engine: built.engine || "",
    origin: urlDetails.origin,
    path: urlDetails.path,
    loopApplied: !!built.loopApplied,
    loopParam: built.loopParam || ""
  });
  var openInNewTab = typeof args.newTab === "boolean" ? args.newTab : true;
  if (openInNewTab) {
    if (!browser.tabs || !browser.tabs.create) {
      logSearch("error", { stage: "open_tab", error: ToolErrorCode.RUNTIME_UNAVAILABLE });
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    var targetWindowId = await getTabWindowId(tabOverride);
    if (!isNumericId(targetWindowId)) {
      targetWindowId = resolveOwnerWindowId(sender, null);
    }
    var createOptions = { url: safeUrl, active: true };
    if (isNumericId(targetWindowId)) {
      createOptions.windowId = targetWindowId;
    }
    // Searches are typically intermediate steps; don't steal focus from the user's current tab.
    createOptions.active = false;
    try {
      var created = await browser.tabs.create(createOptions);
      logSearch("open_tab", {
        tabId: created && isNumericId(created.id) ? created.id : null,
        origin: urlDetails.origin
      });
      return {
        status: "ok",
        tabId: created && isNumericId(created.id) ? created.id : null,
        url: safeUrl,
        engine: built.engine || ""
      };
    } catch (error) {
      if (isNumericId(createOptions.windowId)) {
        try {
          var createdFallback = await browser.tabs.create({ url: safeUrl, active: false });
          logSearch("open_tab_fallback", {
            tabId: createdFallback && isNumericId(createdFallback.id) ? createdFallback.id : null,
            origin: urlDetails.origin
          });
          return {
            status: "ok",
            tabId: createdFallback && isNumericId(createdFallback.id) ? createdFallback.id : null,
            url: safeUrl,
            engine: built.engine || ""
          };
        } catch (innerError) {
        }
      }
      logSearch("error", {
        stage: "open_tab",
        error: ToolErrorCode.OPEN_TAB_FAILED,
        message: String(error && error.message ? error.message : error).slice(0, 200)
      });
      return { status: "error", error: ToolErrorCode.OPEN_TAB_FAILED };
    }
  }

  var tabId = null;
  if (isNumericId(tabOverride)) {
    if (await tabExists(tabOverride)) {
      tabId = tabOverride;
    } else {
      return { status: "error", error: ToolErrorCode.NO_TARGET_TAB };
    }
  } else {
    tabId = await resolveTargetTabId(sender, null);
  }
  if (!isNumericId(tabId)) {
    logSearch("error", { stage: "navigate", error: ToolErrorCode.NO_ACTIVE_TAB });
    return { status: "error", error: ToolErrorCode.NO_ACTIVE_TAB };
  }
  if (!browser.tabs || !browser.tabs.update) {
    logSearch("error", { stage: "navigate", error: ToolErrorCode.RUNTIME_UNAVAILABLE });
    return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
  }
  try {
    await browser.tabs.update(tabId, { url: safeUrl });
    logSearch("navigate", { tabId: tabId, origin: urlDetails.origin });
    return { status: "ok", url: safeUrl, engine: built.engine || "" };
  } catch (error) {
    logSearch("error", {
      stage: "navigate",
      error: ToolErrorCode.NAVIGATION_FAILED,
      message: String(error && error.message ? error.message : error).slice(0, 200)
    });
    return { status: "error", error: ToolErrorCode.NAVIGATION_FAILED };
  }
}

async function closeSearchTabs(tabIds, fallbackTabId) {
  if (!browser.tabs || !browser.tabs.get || !browser.tabs.remove) {
    return { status: "error", error: "tabs_unavailable" };
  }
  var ids = Array.isArray(tabIds) ? tabIds : [];
  var closed = 0;
  var skipped = 0;
  for (var i = 0; i < ids.length; i += 1) {
    var tabId = ids[i];
    if (!isNumericId(tabId)) {
      continue;
    }
    var tab;
    try {
      tab = await browser.tabs.get(tabId);
    } catch (error) {
      continue;
    }
    if (!tab || !isSearchResultsUrl(tab.url || "")) {
      skipped += 1;
      continue;
    }
    if (tab.active && isNumericId(fallbackTabId) && fallbackTabId !== tabId && browser.tabs.update) {
      try {
        await browser.tabs.update(fallbackTabId, { active: true });
      } catch (error) {
      }
    }
    try {
      await browser.tabs.remove(tabId);
      closed += 1;
    } catch (error) {
    }
  }
  logSearch("cleanup", { closed: closed, skipped: skipped, total: ids.length });
  return { status: "ok", closed: closed, skipped: skipped };
}

async function getSidecarSide() {
  if (!browser.storage || !browser.storage.local) {
    return DEFAULT_SIDECAR_SIDE;
  }
  var stored = await browser.storage.local.get({ sidecarSide: DEFAULT_SIDECAR_SIDE });
  return stored.sidecarSide === "left" ? "left" : DEFAULT_SIDECAR_SIDE;
}

async function getSidecarSticky() {
  if (!browser.storage || !browser.storage.local) {
    return DEFAULT_SIDECAR_STICKY;
  }
  var stored = await browser.storage.local.get({ sidecarSticky: DEFAULT_SIDECAR_STICKY });
  return stored.sidecarSticky !== false;
}

async function tabExists(tabId) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get) {
    return false;
  }
  try {
    await browser.tabs.get(tabId);
    return true;
  } catch (error) {
    return false;
  }
}

async function getTabWindowId(tabId) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get) {
    return null;
  }
  try {
    var tab = await browser.tabs.get(tabId);
    return isNumericId(tab.windowId) ? tab.windowId : null;
  } catch (error) {
    return null;
  }
}

async function getActiveTabInfo(tabId, windowId) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.get) {
    return null;
  }
  try {
    var tab = await browser.tabs.get(tabId);
    if (!tab || !tab.active) {
      return null;
    }
    if (isNumericId(windowId) && tab.windowId !== windowId) {
      return null;
    }
    return tab;
  } catch (error) {
    return null;
  }
}

function isScriptableUrl(url) {
  return typeof url === "string" && (url.indexOf("http:") === 0 || url.indexOf("https:") === 0);
}

function resolveOwnerWindowId(sender, fallbackWindowId) {
  if (isNumericId(fallbackWindowId)) {
    return fallbackWindowId;
  }
  if (sender && sender.tab) {
    if (isPanelUrl(sender.tab.url || sender.url)) {
      var panelState = getPanelStateByTabId(sender.tab.id);
      if (panelState && isNumericId(panelState.ownerWindowId)) {
        return panelState.ownerWindowId;
      }
      var meta = getPanelMeta(sender.tab.url || sender.url);
      if (meta && isNumericId(meta.ownerWindowId)) {
        return meta.ownerWindowId;
      }
    }
    if (isNumericId(sender.tab.windowId)) {
      return sender.tab.windowId;
    }
  }
  return null;
}

async function resolveTargetTabId(sender, explicitTabId) {
  if (isNumericId(explicitTabId)) {
    if (await tabExists(explicitTabId)) {
      return explicitTabId;
    }
  }
  if (sender && sender.tab && isPanelUrl(sender.tab.url || sender.url)) {
    var panelState = getPanelStateByTabId(sender.tab.id);
    var attachedTabId = panelState && isNumericId(panelState.attachedTabId) ? panelState.attachedTabId : null;
    if (isNumericId(attachedTabId) && (await tabExists(attachedTabId))) {
      return attachedTabId;
    }
    var ownerWindowId = resolveOwnerWindowId(sender, null);
    var activeInOwner = await getActiveTab(ownerWindowId);
    return activeInOwner ? activeInOwner.id : null;
  }
  if (sender && sender.tab && isNumericId(sender.tab.id)) {
    return sender.tab.id;
  }
  var activeTab = await getActiveTab();
  return activeTab ? activeTab.id : null;
}

async function sendSidecarMessage(type, sideOverride, sender, tabOverride) {
  await loadSidecarState();
  var tabId = await resolveTargetTabId(sender, tabOverride);
  if (!isNumericId(tabId)) {
    return { status: "error", error: "no_active_tab" };
  }
  var side = sideOverride || (await getSidecarSide());
  try {
    var result = await sendTabMessageWithTimeout(
      tabId,
      { type: type, side: side },
      { allowInject: true }
    );
    if (result && result.status === "ok") {
      if (type === "laika.sidecar.show" || type === "laika.sidecar.hide" || type === "laika.sidecar.toggle") {
        var windowId = await getTabWindowId(tabId);
        if (isNumericId(windowId)) {
          if (type === "laika.sidecar.show") {
            setSidecarOpenState(windowId, true);
          } else if (type === "laika.sidecar.hide") {
            setSidecarOpenState(windowId, false);
          } else if (type === "laika.sidecar.toggle" && typeof result.visible === "boolean") {
            setSidecarOpenState(windowId, result.visible);
          }
        }
      }
    }
    logSidecar("message", { type: type, tabId: tabId, status: result ? result.status : "unknown" });
    return result;
  } catch (error) {
    logSidecar("message_failed", { type: type, tabId: tabId, error: "no_context" });
    return { status: "error", error: "no_context" };
  }
}

function clearStickyRetry(tabId) {
  var key = String(tabId);
  var entry = SIDECAR_RETRY_BY_TAB[key];
  if (entry && entry.timer) {
    clearTimeout(entry.timer);
  }
  delete SIDECAR_RETRY_BY_TAB[key];
}

function scheduleStickyRetry(tabId, windowId) {
  var key = String(tabId);
  var entry = SIDECAR_RETRY_BY_TAB[key];
  var attempt = entry ? entry.attempt + 1 : 1;
  if (attempt > SIDECAR_RETRY_LIMIT) {
    clearStickyRetry(tabId);
    logSidecar("retry_giveup", { tabId: tabId, windowId: windowId });
    return;
  }
  if (entry && entry.timer) {
    clearTimeout(entry.timer);
  }
  var delay = SIDECAR_RETRY_BASE_DELAY * attempt;
  logSidecar("retry_schedule", { tabId: tabId, windowId: windowId, attempt: attempt, delayMs: delay });
  SIDECAR_RETRY_BY_TAB[key] = {
    attempt: attempt,
    timer: setTimeout(function () {
      var current = SIDECAR_RETRY_BY_TAB[key];
      if (!current || current.attempt !== attempt) {
        return;
      }
      SIDECAR_RETRY_BY_TAB[key].timer = null;
      syncStickySidecar(tabId, windowId);
    }, delay)
  };
}

async function syncStickySidecar(tabId, windowId) {
  if (!isNumericId(tabId) || !isNumericId(windowId)) {
    return;
  }
  await loadSidecarState();
  var sticky = await getSidecarSticky();
  if (!sticky) {
    clearStickyRetry(tabId);
    logSidecar("sync_skip", { tabId: tabId, windowId: windowId, reason: "sticky_off" });
    return;
  }
  var activeTab = await getActiveTabInfo(tabId, windowId);
  if (!activeTab) {
    logSidecar("sync_skip", { tabId: tabId, windowId: windowId, reason: "inactive" });
    return;
  }
  if (!isScriptableUrl(activeTab.url || "")) {
    clearStickyRetry(tabId);
    logSidecar("sync_skip", { tabId: tabId, windowId: windowId, reason: "non_scriptable" });
    return;
  }
  var type = isSidecarOpen(windowId) ? "laika.sidecar.show" : "laika.sidecar.hide";
  logSidecar("sync_send", { tabId: tabId, windowId: windowId, type: type });
  try {
    var result = await sendSidecarMessage(type, null, null, tabId);
    if (result && result.status === "ok") {
      clearStickyRetry(tabId);
      return;
    }
    if (result && result.error === "no_context") {
      scheduleStickyRetry(tabId, windowId);
    } else {
      clearStickyRetry(tabId);
    }
  } catch (error) {
  }
}

function sanitizeTabUrl(url) {
  if (!url) {
    return "";
  }
  try {
    var parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return "";
    }
    return parsed.origin;
  } catch (error) {
    return "";
  }
}

function sanitizeOpenUrl(url) {
  if (!url) {
    return "";
  }
  try {
    var parsed = new URL(String(url));
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return "";
    }
    return parsed.toString();
  } catch (error) {
    return "";
  }
}

function defaultSearchSettings() {
  if (SearchTools && typeof SearchTools.normalizeSettings === "function") {
    return SearchTools.normalizeSettings(null);
  }
  return {
    mode: "direct",
    customTemplate: "https://www.google.com/search?q={query}",
    defaultEngine: "google",
    addLoopParam: false,
    loopParam: "laika_redirect",
    maxQueryLength: 512
  };
}

function normalizeSearchSettings(value) {
  if (SearchTools && typeof SearchTools.normalizeSettings === "function") {
    return SearchTools.normalizeSettings(value);
  }
  return defaultSearchSettings();
}

async function loadSearchSettings() {
  if (searchSettingsCache) {
    return searchSettingsCache;
  }
  if (searchSettingsLoadPromise) {
    return searchSettingsLoadPromise;
  }
  var defaults = defaultSearchSettings();
  if (!browser.storage || !browser.storage.local) {
    searchSettingsCache = defaults;
    logSearch("settings_loaded", {
      source: "defaults",
      mode: defaults.mode,
      defaultEngine: defaults.defaultEngine,
      templateHost: summarizeTemplateHost(defaults.customTemplate)
    });
    return defaults;
  }
  searchSettingsLoadPromise = browser.storage.local
    .get((function () {
      var payload = {};
      payload[SEARCH_SETTINGS_KEY] = defaults;
      return payload;
    })())
    .then(function (stored) {
      var settings = normalizeSearchSettings(stored ? stored[SEARCH_SETTINGS_KEY] : null);
      searchSettingsCache = settings;
      logSearch("settings_loaded", {
        source: "storage",
        mode: settings.mode,
        defaultEngine: settings.defaultEngine,
        templateHost: summarizeTemplateHost(settings.customTemplate),
        addLoopParam: !!settings.addLoopParam,
        loopParam: settings.loopParam || "",
        maxQueryLength: settings.maxQueryLength || 0
      });
      return settings;
    })
    .catch(function () {
      searchSettingsCache = defaults;
      logSearch("settings_load_failed", {
        source: "defaults",
        mode: defaults.mode,
        defaultEngine: defaults.defaultEngine,
        templateHost: summarizeTemplateHost(defaults.customTemplate)
      });
      return defaults;
    });
  return searchSettingsLoadPromise;
}

function normalizeWhitespace(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

function budgetText(text, maxChars) {
  var normalized = normalizeWhitespace(text);
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return normalized.slice(0, maxChars);
}

function normalizeTabTitle(title) {
  return budgetText(title, MAX_TAB_TITLE);
}

function buildTabSummary(tab) {
  var url = sanitizeTabUrl(tab.url || "");
  if (!url) {
    return null;
  }
  return {
    title: normalizeTabTitle(tab.title || ""),
    url: url,
    origin: url,
    isActive: !!tab.active
  };
}

async function listTabsForWindow(ownerWindowId) {
  if (!browser.tabs || !browser.tabs.query) {
    return [];
  }
  var query = {};
  if (isNumericId(ownerWindowId)) {
    query.windowId = ownerWindowId;
  } else {
    query.currentWindow = true;
  }
  var tabs;
  try {
    tabs = await browser.tabs.query(query);
  } catch (error) {
    return [];
  }
  tabs.sort(function (a, b) {
    if (a.active === b.active) {
      return (a.index || 0) - (b.index || 0);
    }
    return a.active ? -1 : 1;
  });
  var summaries = [];
  for (var i = 0; i < tabs.length; i += 1) {
    if (summaries.length >= MAX_TAB_CONTEXT) {
      break;
    }
    if (isPanelUrl(tabs[i].url)) {
      continue;
    }
    var summary = buildTabSummary(tabs[i]);
    if (summary) {
      summaries.push(summary);
    }
  }
  return summaries;
}

function buildPanelUrl(ownerWindowId) {
  if (!browser.runtime || !browser.runtime.getURL) {
    return "";
  }
  var base = browser.runtime.getURL("popover.html");
  if (!isNumericId(ownerWindowId)) {
    return base + "?panel=1";
  }
  return base + "?panel=1&ownerWindow=" + String(ownerWindowId);
}

async function openPanelWindowInner(ownerWindowId, ownerTabId) {
  if (!browser.runtime || !browser.runtime.getURL) {
    return { status: "error", error: "panel_unavailable" };
  }
  var state = getPanelState(ownerWindowId);
  if (state && isNumericId(state.panelTabId) && browser.tabs && browser.tabs.get) {
    try {
      var existing = await browser.tabs.get(state.panelTabId);
      if (existing && isPanelUrl(existing.url)) {
        state.panelWindowId = isNumericId(existing.windowId) ? existing.windowId : state.panelWindowId;
        if (isNumericId(ownerTabId)) {
          state.attachedTabId = ownerTabId;
        } else if (ownerTabId === null) {
          state.attachedTabId = null;
        }
        setPanelState(ownerWindowId, state);
        await focusTab(existing);
        return { status: "ok", reused: true, tabId: state.panelTabId, windowId: state.panelWindowId };
      }
    } catch (error) {
      clearPanelState(ownerWindowId);
    }
  }

  try {
    var found = await findPanelTab(ownerWindowId);
    if (found && found.tab) {
      var attachedTabId = isNumericId(ownerTabId) ? ownerTabId : null;
      var nextState = {
        ownerWindowId: ownerWindowId,
        panelWindowId: isNumericId(found.tab.windowId) ? found.tab.windowId : null,
        panelTabId: found.tab.id,
        attachedTabId: attachedTabId
      };
      setPanelState(ownerWindowId, nextState);
      await focusTab(found.tab);
      return { status: "ok", reused: true, tabId: nextState.panelTabId, windowId: nextState.panelWindowId };
    }
  } catch (error) {
  }

  var url = buildPanelUrl(ownerWindowId);
  if (browser.windows && browser.windows.create) {
    var height = 720;
    try {
      var current = await browser.windows.getCurrent();
      if (current && current.height) {
        height = Math.max(600, current.height - 120);
      }
    } catch (error) {
    }
    try {
      var panel = await browser.windows.create({
        url: url,
        type: "popup",
        width: 380,
        height: height,
        focused: true
      });
      var panelTabId = panel.tabs && panel.tabs[0] ? panel.tabs[0].id : null;
      var panelState = {
        ownerWindowId: ownerWindowId,
        panelWindowId: panel.id || null,
        panelTabId: panelTabId,
        attachedTabId: isNumericId(ownerTabId) ? ownerTabId : null
      };
      setPanelState(ownerWindowId, panelState);
      return { status: "ok", windowId: panelState.panelWindowId, tabId: panelState.panelTabId };
    } catch (error) {
      clearPanelState(ownerWindowId);
    }
  }
  if (browser.tabs && browser.tabs.create) {
    var createOptions = { url: url, active: true };
    if (isNumericId(ownerWindowId)) {
      createOptions.windowId = ownerWindowId;
    }
    var tab = await browser.tabs.create(createOptions);
    var panelState = {
      ownerWindowId: ownerWindowId,
      panelWindowId: isNumericId(tab.windowId) ? tab.windowId : null,
      panelTabId: tab.id,
      attachedTabId: isNumericId(ownerTabId) ? ownerTabId : null
    };
    setPanelState(ownerWindowId, panelState);
    return { status: "ok", tabId: panelState.panelTabId, windowId: panelState.panelWindowId };
  }
  return { status: "error", error: "panel_unavailable" };
}

function openPanelWindow(ownerWindowId, ownerTabId) {
  var key = getOwnerKey(ownerWindowId);
  if (PANEL_OPEN_PROMISES[key]) {
    return PANEL_OPEN_PROMISES[key];
  }
  var promise = openPanelWindowInner(ownerWindowId, ownerTabId);
  PANEL_OPEN_PROMISES[key] = promise;
  if (promise && promise.finally) {
    promise.finally(function () {
      if (PANEL_OPEN_PROMISES[key] === promise) {
        delete PANEL_OPEN_PROMISES[key];
      }
    });
  }
  return promise;
}

async function closePanelWindow(sender, ownerWindowOverride) {
  var senderPanelTabId = null;
  var senderPanelMeta = null;
  if (sender && sender.tab && isNumericId(sender.tab.id) && isPanelUrl(sender.tab.url || sender.url)) {
    senderPanelTabId = sender.tab.id;
    senderPanelMeta = getPanelMeta(sender.tab.url || sender.url);
  }

  var panelState = null;
  if (isNumericId(senderPanelTabId)) {
    panelState = getPanelStateByTabId(senderPanelTabId);
  }
  var ownerWindowId = resolveOwnerWindowId(sender, ownerWindowOverride);
  if (!panelState) {
    if (isNumericId(ownerWindowId)) {
      panelState = getPanelState(ownerWindowId);
    }
  }
  if (!panelState) {
    if (isNumericId(senderPanelTabId) && browser.tabs && browser.tabs.remove) {
      try {
        await browser.tabs.remove(senderPanelTabId);
      } catch (error) {
      }
      if (senderPanelMeta && isNumericId(senderPanelMeta.ownerWindowId)) {
        clearPanelState(senderPanelMeta.ownerWindowId);
      }
      return;
    }
    if (isNumericId(ownerWindowId)) {
      try {
        var found = await findPanelTab(ownerWindowId);
        if (found && found.tab && isNumericId(found.tab.id) && browser.tabs && browser.tabs.remove) {
          await browser.tabs.remove(found.tab.id);
        }
      } catch (error) {
      }
      clearPanelState(ownerWindowId);
    }
    return;
  }

  var panelTabId = isNumericId(panelState.panelTabId) ? panelState.panelTabId : senderPanelTabId;
  var panelWindowId = isNumericId(panelState.panelWindowId) ? panelState.panelWindowId : null;
  if (isNumericId(panelTabId) && browser.tabs && browser.tabs.get) {
    try {
      var candidate = await browser.tabs.get(panelTabId);
      if (!candidate || !isPanelUrl(candidate.url)) {
        clearPanelState(panelState.ownerWindowId);
        return;
      }
    } catch (error) {
      clearPanelState(panelState.ownerWindowId);
      return;
    }
  }

  if (isNumericId(panelTabId) && browser.tabs && browser.tabs.remove) {
    try {
      await browser.tabs.remove(panelTabId);
    } catch (error) {
    }
  } else if (isNumericId(panelWindowId) && browser.windows && browser.windows.remove) {
    try {
      await browser.windows.remove(panelWindowId);
    } catch (error) {
    }
  }

  clearPanelState(panelState.ownerWindowId);
}

async function handleTool(toolName, args, sender, tabOverride) {
  if (!ALLOWED_TOOLS[toolName]) {
    return { status: "error", error: ToolErrorCode.UNSUPPORTED_TOOL };
  }
  if (toolName === "browser.observe_dom") {
    function clampInt(value, min, max) {
      if (typeof value !== "number" || !isFinite(value)) {
        return undefined;
      }
      var rounded = Math.floor(value);
      if (rounded < min) {
        return min;
      }
      if (rounded > max) {
        return max;
      }
      return rounded;
    }
    var options = {
      maxChars: clampInt(args && args.maxChars, 2000, 16000),
      maxElements: clampInt(args && args.maxElements, 80, 200),
      maxBlocks: clampInt(args && args.maxBlocks, 20, 80),
      maxPrimaryChars: clampInt(args && args.maxPrimaryChars, 600, 4000),
      maxOutline: clampInt(args && args.maxOutline, 20, 120),
      maxOutlineChars: clampInt(args && args.maxOutlineChars, 80, 400),
      maxItems: clampInt(args && args.maxItems, 10, 60),
      maxItemChars: clampInt(args && args.maxItemChars, 120, 400),
      maxComments: clampInt(args && args.maxComments, 6, 80),
      maxCommentChars: clampInt(args && args.maxCommentChars, 120, 800)
    };
    if (args && typeof args.rootHandleId === "string" && args.rootHandleId) {
      options.rootHandleId = args.rootHandleId;
    }
    return handleObserve(options, sender, tabOverride, false);
  }
  if (toolName === "search") {
    return handleSearchTool(args || {}, sender, tabOverride);
  }
  if (toolName === "app.calculate") {
    if (!CalculateTools || typeof CalculateTools.evaluateExpression !== "function") {
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    if (!args || typeof args.expression !== "string") {
      return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
    }
    var precision = CalculateTools.normalizePrecision
      ? CalculateTools.normalizePrecision(args.precision)
      : { ok: true, value: null };
    if (!precision || precision.ok !== true) {
      return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
    }
    var evaluation = CalculateTools.evaluateExpression(args.expression);
    if (!evaluation || evaluation.ok !== true) {
      return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
    }
    var formatted = CalculateTools.formatValue
      ? CalculateTools.formatValue(evaluation.value, precision.value)
      : { result: evaluation.value, formatted: null };
    var payload = { status: "ok", result: formatted.result };
    if (precision.value !== null && typeof precision.value !== "undefined") {
      payload.precision = precision.value;
    }
    if (formatted.formatted) {
      payload.formatted = formatted.formatted;
    }
    return payload;
  }
  if (toolName === "browser.open_tab") {
    if (args && args.url) {
      var safeUrl = sanitizeOpenUrl(args.url);
      if (!safeUrl) {
        return { status: "error", error: ToolErrorCode.INVALID_URL };
      }
      if (!browser.tabs || !browser.tabs.create) {
        return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
      }
      var targetWindowId = await getTabWindowId(tabOverride);
      if (!isNumericId(targetWindowId)) {
        targetWindowId = resolveOwnerWindowId(sender, null);
      }
      var createOptions = { url: safeUrl, active: true };
      if (isNumericId(targetWindowId)) {
        createOptions.windowId = targetWindowId;
      }
      try {
        var created = await browser.tabs.create(createOptions);
        return { status: "ok", tabId: created && isNumericId(created.id) ? created.id : null };
      } catch (error) {
        if (isNumericId(createOptions.windowId)) {
          try {
            var createdFallback = await browser.tabs.create({ url: safeUrl, active: true });
            return { status: "ok", tabId: createdFallback && isNumericId(createdFallback.id) ? createdFallback.id : null };
          } catch (innerError) {
          }
        }
        return { status: "error", error: ToolErrorCode.OPEN_TAB_FAILED };
      }
    }
    return { status: "error", error: ToolErrorCode.MISSING_URL };
  }

  var tabId = null;
  if (isNumericId(tabOverride)) {
    if (await tabExists(tabOverride)) {
      tabId = tabOverride;
    } else {
      return { status: "error", error: ToolErrorCode.NO_TARGET_TAB };
    }
  } else {
    tabId = await resolveTargetTabId(sender, null);
  }
  if (!isNumericId(tabId)) {
    return { status: "error", error: ToolErrorCode.NO_ACTIVE_TAB };
  }
  if (toolName === "browser.navigate") {
    if (!args || !args.url) {
      return { status: "error", error: ToolErrorCode.MISSING_URL };
    }
    var navigateUrl = sanitizeOpenUrl(args.url);
    if (!navigateUrl) {
      return { status: "error", error: ToolErrorCode.INVALID_URL };
    }
    if (!browser.tabs || !browser.tabs.update) {
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    try {
      await browser.tabs.update(tabId, { url: navigateUrl });
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: ToolErrorCode.NAVIGATION_FAILED };
    }
  }
  if (toolName === "browser.back") {
    if (!browser.tabs || !browser.tabs.goBack) {
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    try {
      await browser.tabs.goBack(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: ToolErrorCode.BACK_FAILED };
    }
  }
  if (toolName === "browser.forward") {
    if (!browser.tabs || !browser.tabs.goForward) {
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    try {
      await browser.tabs.goForward(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: ToolErrorCode.FORWARD_FAILED };
    }
  }
  if (toolName === "browser.refresh") {
    if (!browser.tabs || !browser.tabs.reload) {
      return { status: "error", error: ToolErrorCode.RUNTIME_UNAVAILABLE };
    }
    try {
      await browser.tabs.reload(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: ToolErrorCode.REFRESH_FAILED };
    }
  }
  try {
    return await sendTabMessageWithTimeout(
      tabId,
      { type: "laika.tool", toolName: toolName, args: args || {} },
      { allowInject: true, waitForReady: true }
    );
  } catch (error) {
    return { status: "error", error: error && error.code === "message_timeout" ? ToolErrorCode.TIMEOUT : ToolErrorCode.NO_CONTEXT };
  }
}

function registerActionClick() {
  if (browser.action && browser.action.onClicked) {
    browser.action.onClicked.addListener(function (tab) {
      handleToolbarClick(tab).catch(function () {
        if (tab) {
          openPanelWindow(tab.windowId, null);
        } else {
          openPanelWindow(null, null);
        }
      });
    });
    return;
  }
  if (browser.browserAction && browser.browserAction.onClicked) {
    browser.browserAction.onClicked.addListener(function (tab) {
      handleToolbarClick(tab).catch(function () {
        if (tab) {
          openPanelWindow(tab.windowId, null);
        } else {
          openPanelWindow(null, null);
        }
      });
    });
  }
}

async function handleToolbarClick(tab) {
  var tabId = tab && isNumericId(tab.id) ? tab.id : null;
  var windowId = tab && isNumericId(tab.windowId) ? tab.windowId : null;
  var result = await sendSidecarMessage("laika.sidecar.toggle", null, null, tabId);
  if (!result || result.status !== "ok") {
    return openPanelWindow(windowId, null);
  }
  return result;
}

function isAllowedAutomationOrigin(origin) {
  if (!origin) {
    return false;
  }
  try {
    var parsed = new URL(origin);
    return !!AUTOMATION_ALLOWED_HOSTS[parsed.hostname];
  } catch (error) {
    return false;
  }
}

function resolveAutomationOrigin(sender, message) {
  var origin = sender && sender.url ? sender.url.split("#")[0] : (message && message.origin ? message.origin : "");
  try {
    origin = new URL(origin).origin;
  } catch (error) {
    origin = sender && sender.url ? sender.url.split("#")[0] : (message && message.origin ? message.origin : "");
  }
  return origin;
}

function resolveAutomationEnabled() {
  if (automationEnabledCache !== null) {
    return Promise.resolve(automationEnabledCache);
  }
  if (!browser.storage || !browser.storage.local || !browser.storage.local.get) {
    automationEnabledCache = AUTOMATION_ENABLED_DEFAULT;
    return Promise.resolve(automationEnabledCache);
  }
  if (!automationEnabledPromise) {
    var defaults = {};
    defaults[AUTOMATION_ENABLED_KEY] = AUTOMATION_ENABLED_DEFAULT;
    automationEnabledPromise = browser.storage.local.get(defaults).then(function (stored) {
      automationEnabledCache = stored[AUTOMATION_ENABLED_KEY] !== false;
      return automationEnabledCache;
    }).catch(function () {
      automationEnabledCache = AUTOMATION_ENABLED_DEFAULT;
      return automationEnabledCache;
    }).finally(function () {
      automationEnabledPromise = null;
    });
  }
  return automationEnabledPromise;
}

function setAutomationEnabled(enabled) {
  var nextValue = enabled === true;
  automationEnabledCache = nextValue;
  if (!browser.storage || !browser.storage.local || !browser.storage.local.set) {
    return Promise.resolve({ status: "error", error: "storage_unavailable" });
  }
  var payload = {};
  payload[AUTOMATION_ENABLED_KEY] = nextValue;
  return browser.storage.local.set(payload).then(function () {
    return { status: "ok", enabled: nextValue };
  }).catch(function () {
    return { status: "error", error: "storage_set_failed" };
  });
}

function enableAutomationForOrigin(origin) {
  if (!isAllowedAutomationOrigin(origin)) {
    return Promise.resolve({ status: "error", error: "origin_not_allowed" });
  }
  return resolveAutomationEnabled().then(function (enabled) {
    if (enabled) {
      return { status: "ok", enabled: true, alreadyEnabled: true };
    }
    return setAutomationEnabled(true);
  });
}

function normalizeAutomationReportUrl(reportUrl, origin) {
  if (!reportUrl || typeof reportUrl !== "string") {
    return null;
  }
  try {
    var parsed = new URL(reportUrl);
    if (!isAllowedAutomationOrigin(parsed.origin)) {
      return null;
    }
    if (origin && parsed.origin !== origin) {
      return null;
    }
    if (parsed.pathname !== "/api/report") {
      return null;
    }
    return parsed.toString();
  } catch (error) {
    return null;
  }
}

function isAutomationHarnessUrl(url) {
  if (!url || typeof url !== "string") {
    return false;
  }
  try {
    var parsed = new URL(url);
    if (!isAllowedAutomationOrigin(parsed.origin)) {
      return false;
    }
    return parsed.pathname.indexOf("harness.html") !== -1;
  } catch (error) {
    return false;
  }
}

function getAutomationRun(runId) {
  return runId && AUTOMATION_RUNS[runId] ? AUTOMATION_RUNS[runId] : null;
}

async function resetAutomationState() {
  if (!browser.storage || !browser.storage.local) {
    return { status: "error", error: "storage_unavailable" };
  }
  if (browser.storage.local.get && browser.storage.local.remove) {
    try {
      var stored = await browser.storage.local.get(null);
      var keys = Object.keys(stored || {}).filter(function (key) {
        return key.indexOf(AUTOMATION_STORAGE_PREFIX) === 0;
      });
      if (keys.length > 0) {
        await browser.storage.local.remove(keys);
      }
    } catch (error) {
      return { status: "error", error: "storage_clear_failed" };
    }
  }
  searchSettingsCache = null;
  searchSettingsLoadPromise = null;
  sidecarStateLoaded = false;
  sidecarStateLoadPromise = null;
  if (sidecarStateSaveTimer) {
    clearTimeout(sidecarStateSaveTimer);
    sidecarStateSaveTimer = null;
  }
  SIDECAR_STATE_BY_WINDOW = {};
  PANEL_STATE_BY_OWNER = {};
  PANEL_TAB_TO_OWNER = {};
  PANEL_OPEN_PROMISES = {};
  return { status: "ok" };
}

async function sendAutomationMessage(tabId, payload) {
  if (!isNumericId(tabId) || !browser.tabs || !browser.tabs.sendMessage) {
    return false;
  }
  try {
    await sendTabMessageWithTimeout(
      tabId,
      payload,
      { allowInject: true, waitForReady: false, timeoutMs: 4000, attempts: 1 }
    );
    return true;
  } catch (error) {
    return false;
  }
}

async function cleanupAutomationTabs(runState) {
  if (!runState || !browser.tabs || !browser.tabs.remove) {
    return;
  }
  var openedTabs = runState.openedTabs || {};
  var ids = Object.keys(openedTabs).map(function (key) {
    return parseInt(key, 10);
  }).filter(function (id) {
    return isNumericId(id) && id !== runState.reportTabId;
  });
  if (!ids.length) {
    return;
  }
  for (var i = 0; i < ids.length; i += 1) {
    try {
      await browser.tabs.remove(ids[i]);
    } catch (error) {
    }
  }
}

async function closeAutomationReportTab(runState) {
  if (!runState || !browser.tabs || !browser.tabs.get || !browser.tabs.remove) {
    return;
  }
  if (!isNumericId(runState.reportTabId)) {
    return;
  }
  try {
    var tab = await browser.tabs.get(runState.reportTabId);
    if (tab && isAutomationHarnessUrl(tab.url || "")) {
      await browser.tabs.remove(runState.reportTabId);
    }
  } catch (error) {
  }
}

async function postAutomationReport(reportUrl, payload) {
  if (!reportUrl || typeof fetch !== "function") {
    return false;
  }
  try {
    await fetch(reportUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload)
    });
    return true;
  } catch (error) {
    return false;
  }
}

async function deliverAutomationResult(runState, payload, kind) {
  var delivered = await sendAutomationMessage(runState.reportTabId, payload);
  if (delivered) {
    await cleanupAutomationTabs(runState);
    await closeAutomationReportTab(runState);
    delete AUTOMATION_RUNS[runState.runId];
    return;
  }
  if (!runState.reportUrl) {
    await cleanupAutomationTabs(runState);
    await closeAutomationReportTab(runState);
    delete AUTOMATION_RUNS[runState.runId];
    return;
  }
  var reportPayload = {
    runId: runState.runId,
    source: "background"
  };
  if (kind === "result") {
    reportPayload.result = payload.result;
  } else if (kind === "error") {
    reportPayload.error = payload.error;
    if (runState.errorDetails) {
      reportPayload.errorDetails = runState.errorDetails;
    }
  }
  await postAutomationReport(runState.reportUrl, reportPayload);
  await cleanupAutomationTabs(runState);
  await closeAutomationReportTab(runState);
  delete AUTOMATION_RUNS[runState.runId];
}

async function resolveAutomationTargetTabId(targetUrl, sender) {
  if (!targetUrl) {
    return null;
  }
  var senderUrl = sender && sender.tab ? (sender.tab.url || sender.url || "") : (sender && sender.url ? sender.url : "");
  if (sender && sender.tab && isNumericId(sender.tab.id) && !isAutomationHarnessUrl(senderUrl)) {
    var navigateResult = await handleTool("browser.navigate", { url: targetUrl }, sender, sender.tab.id);
    if (navigateResult && navigateResult.status === "ok") {
      return sender.tab.id;
    }
  }
  var openResult = await handleTool("browser.open_tab", { url: targetUrl }, sender, null);
  if (openResult && openResult.status === "ok" && isNumericId(openResult.tabId)) {
    return openResult.tabId;
  }
  return null;
}

async function startAutomationRun(message, sender) {
  if (!AgentRunner || typeof AgentRunner.runAutomationGoals !== "function") {
    return { status: "error", error: "runner_unavailable" };
  }
  if (!sender || !sender.tab || !isNumericId(sender.tab.id)) {
    return { status: "error", error: "no_sender_tab" };
  }
  var origin = resolveAutomationOrigin(sender, message);
  var automationEnabled = await resolveAutomationEnabled();
  if (!automationEnabled) {
    return { status: "error", error: "automation_disabled" };
  }
  if (!isAllowedAutomationOrigin(origin)) {
    return { status: "error", error: "origin_not_allowed" };
  }
  if (!message.nonce || typeof message.nonce !== "string") {
    return { status: "error", error: "missing_nonce" };
  }
  var reportUrl = normalizeAutomationReportUrl(message.reportUrl, origin);
  var goals = Array.isArray(message.goals) ? message.goals : (message.goal ? [message.goal] : []);
  if (!goals.length) {
    return { status: "error", error: "missing_goals" };
  }
  var shouldReset = true;
  if (message.options && typeof message.options.resetStorage === "boolean") {
    shouldReset = message.options.resetStorage;
  }
  if (shouldReset) {
    var resetResult = await resetAutomationState();
    if (!resetResult || resetResult.status !== "ok") {
      return { status: "error", error: resetResult && resetResult.error ? resetResult.error : "reset_failed" };
    }
  }
  var runId = message.runId && typeof message.runId === "string" ? message.runId : AgentRunner.generateRunId();
  var existingRun = getAutomationRun(runId);
  if (existingRun) {
    if (!existingRun.status || (existingRun.status !== "completed" && existingRun.status !== "error")) {
      return { status: "ok", runId: runId };
    }
    delete AUTOMATION_RUNS[runId];
  }

  var runState = {
    runId: runId,
    status: "starting",
    startedAt: Date.now(),
    reportTabId: sender.tab.id,
    reportUrl: reportUrl,
    cancelRequested: false,
    openedTabs: {}
  };
  AUTOMATION_RUNS[runId] = runState;
  function recordAutomationTab(tabId) {
    if (!isNumericId(tabId) || tabId === runState.reportTabId) {
      return;
    }
    runState.openedTabs[String(tabId)] = true;
  }
  var runTimeoutMs = null;
  if (message.options && typeof message.options.runTimeoutMs === "number" && isFinite(message.options.runTimeoutMs)) {
    if (message.options.runTimeoutMs > 0) {
      runTimeoutMs = Math.floor(message.options.runTimeoutMs);
    }
  }

  var targetTabId = null;
  if (message.targetUrl) {
    targetTabId = await resolveAutomationTargetTabId(message.targetUrl, sender);
    if (!targetTabId) {
      runState.status = "error";
      return { status: "error", error: "target_tab_failed" };
    }
    recordAutomationTab(targetTabId);
    await waitForContentScript(targetTabId);
  }
  var initialObserveSettings = null;
  if (targetTabId) {
    initialObserveSettings = { attempts: 14, delayMs: 350, initialDelayMs: 700 };
  }

  var ownerWindowId = resolveOwnerWindowId(sender, null);
  var deps = {
    observe: function (options, tabId) {
      return handleObserve(options, sender, tabId, true);
    },
    runTool: function (action, tabId) {
      return handleTool(action.toolCall.name, action.toolCall.arguments || {}, sender, tabId).then(function (result) {
        if (action && action.toolCall && (action.toolCall.name === "browser.open_tab" || action.toolCall.name === "search")) {
          if (result && typeof result.tabId === "number") {
            recordAutomationTab(result.tabId);
          }
        }
        return result;
      });
    },
    listTabs: function () {
      return listTabsForWindow(ownerWindowId);
    },
    requestPlan: function (goal, context, maxTokens) {
      return AgentRunner.requestPlan(goal, context, maxTokens, NATIVE_APP_ID);
    },
    validatePlan: PlanValidator && typeof PlanValidator.validatePlanResponse === "function"
      ? PlanValidator.validatePlanResponse
      : null,
    shouldCancel: function () {
      return !!runState.cancelRequested;
    },
    onStatus: function (status) {
      if (status) {
        runState.lastStatus = status;
      }
      runState.status = status || runState.status;
      sendAutomationMessage(runState.reportTabId, {
        type: "laika.automation.status",
        runId: runId,
        status: runState.status
      });
    },
    onStep: function (stepInfo, meta) {
      runState.lastStep = stepInfo && stepInfo.step ? stepInfo.step : runState.lastStep;
      runState.goalIndex = meta && typeof meta.goalIndex === "number" ? meta.goalIndex : runState.goalIndex;
      if (stepInfo && stepInfo.action && stepInfo.action.name) {
        runState.lastToolCall = stepInfo.action.name;
      }
      if (meta && meta.goal) {
        runState.lastGoal = meta.goal;
      }
      sendAutomationMessage(runState.reportTabId, {
        type: "laika.automation.progress",
        runId: runId,
        goal: meta ? meta.goal : null,
        goalIndex: meta ? meta.goalIndex : null,
        step: stepInfo
      });
    }
  };

  var runPromise = AgentRunner.runAutomationGoals({
    runId: runId,
    goals: goals,
    maxSteps: message.options && message.options.maxSteps,
    autoApprove: message.options && typeof message.options.autoApprove === "boolean" ? message.options.autoApprove : true,
    observeOptions: message.options && message.options.observeOptions,
    initialObserveSettings: message.options && message.options.initialObserveSettings
      ? message.options.initialObserveSettings
      : initialObserveSettings,
    detail: message.options && !!message.options.detail,
    maxTokens: message.options && message.options.maxTokens,
    planTimeoutMs: message.options && message.options.planTimeoutMs,
    tabId: targetTabId,
    nativeAppId: NATIVE_APP_ID,
    deps: deps
  });
  if (runTimeoutMs) {
    var basePromise = runPromise;
    runPromise = new Promise(function (resolve, reject) {
      var timeoutId = setTimeout(function () {
        reject(new Error("run_timeout"));
      }, runTimeoutMs);
      basePromise.then(function (result) {
        clearTimeout(timeoutId);
        resolve(result);
      }).catch(function (error) {
        clearTimeout(timeoutId);
        reject(error);
      });
    });
  }
  runPromise.then(function (result) {
    runState.status = "completed";
    runState.completedAt = Date.now();
    runState.result = result;
    var payload = {
      type: "laika.automation.result",
      runId: runId,
      result: result
    };
    deliverAutomationResult(runState, payload, "result");
  }).catch(function (error) {
    runState.status = "error";
    runState.completedAt = Date.now();
    runState.error = String(error && error.message ? error.message : error);
    var details = error && error.details && typeof error.details === "object" ? Object.assign({}, error.details) : {};
    if (details.lastStatus === undefined && runState.lastStatus) {
      details.lastStatus = runState.lastStatus;
    }
    if (details.lastStep === undefined && typeof runState.lastStep === "number") {
      details.lastStep = runState.lastStep;
    }
    if (details.lastToolCall === undefined && runState.lastToolCall) {
      details.lastToolCall = runState.lastToolCall;
    }
    if (details.lastGoalIndex === undefined && typeof runState.goalIndex === "number") {
      details.lastGoalIndex = runState.goalIndex;
    }
    if (details.lastGoal === undefined && runState.lastGoal) {
      details.lastGoal = runState.lastGoal;
    }
    if (Object.keys(details).length > 0) {
      runState.errorDetails = details;
    }
    var payload = {
      type: "laika.automation.error",
      runId: runId,
      error: runState.error
    };
    if (runState.errorDetails) {
      payload.errorDetails = runState.errorDetails;
    }
    deliverAutomationResult(runState, payload, "error");
  });

  return { status: "ok", runId: runId };
}

function getAutomationStatus(runId) {
  var runState = getAutomationRun(runId);
  if (!runState) {
    return { status: "error", error: "unknown_run" };
  }
  return {
    status: "ok",
    runId: runState.runId,
    state: runState.status,
    startedAt: runState.startedAt,
    completedAt: runState.completedAt || null,
    lastStep: runState.lastStep || null,
    goalIndex: typeof runState.goalIndex === "number" ? runState.goalIndex : null
  };
}

function cancelAutomationRun(runId) {
  var runState = getAutomationRun(runId);
  if (!runState) {
    return { status: "error", error: "unknown_run" };
  }
  runState.cancelRequested = true;
  runState.status = "cancel_requested";
  return { status: "ok", runId: runId };
}

browser.runtime.onMessage.addListener(function (message, sender) {
  if (!message || !message.type) {
    return Promise.resolve({ status: "error", error: "invalid_message" });
  }
  if (message.type === "laika.observe") {
    return handleObserve(message.options, sender, message.tabId, false);
  }
  if (message.type === "laika.tool") {
    return handleTool(message.toolName, message.args || {}, sender, message.tabId);
  }
  if (message.type === "laika.sidecar.hide") {
    return sendSidecarMessage("laika.sidecar.hide", message.side, sender, message.tabId);
  }
  if (message.type === "laika.sidecar.show") {
    return sendSidecarMessage("laika.sidecar.show", message.side, sender, message.tabId);
  }
  if (message.type === "laika.sidecar.toggle") {
    return sendSidecarMessage("laika.sidecar.toggle", message.side, sender, message.tabId);
  }
  if (message.type === "laika.tabs.list") {
    var ownerWindowId = resolveOwnerWindowId(sender, message.windowId);
    return listTabsForWindow(ownerWindowId).then(function (tabs) {
      return { status: "ok", tabs: tabs };
    });
  }
  if (message.type === "laika.panel.open") {
    return resolveTargetTabId(sender, message.tabId).then(function (tabId) {
      var ownerWindowId = resolveOwnerWindowId(sender, message.windowId);
      return openPanelWindow(ownerWindowId, tabId);
    });
  }
  if (message.type === "laika.panel.close") {
    return closePanelWindow(sender, message.windowId).then(function () {
      return { status: "ok" };
    });
  }
  if (message.type === "laika.automation.enable") {
    if (!message.nonce || typeof message.nonce !== "string") {
      return Promise.resolve({ status: "error", error: "missing_nonce" });
    }
    var origin = resolveAutomationOrigin(sender, message);
    return enableAutomationForOrigin(origin);
  }
  if (message.type === "laika.automation.start") {
    return startAutomationRun(message, sender);
  }
  if (message.type === "laika.automation.status") {
    return Promise.resolve(getAutomationStatus(message.runId));
  }
  if (message.type === "laika.automation.cancel") {
    return Promise.resolve(cancelAutomationRun(message.runId));
  }
  if (message.type === "laika.search.cleanup") {
    if (!isTrustedUiSender(sender)) {
      return Promise.resolve({ status: "error", error: "forbidden" });
    }
    return closeSearchTabs(message.tabIds || [], message.fallbackTabId);
  }
  return Promise.resolve({ status: "error", error: "unknown_type" });
});

function registerAutomationPort(port) {
  if (!port || port.name !== "laika.automation") {
    return;
  }
  var portKey = String(Date.now()) + "-" + Math.random().toString(16).slice(2);
  AUTOMATION_PORTS[portKey] = port;
  port.onDisconnect.addListener(function () {
    delete AUTOMATION_PORTS[portKey];
  });
  port.onMessage.addListener(function (message) {
    if (!message || message.type !== "laika.automation.ping") {
      return;
    }
    try {
      port.postMessage({ type: "laika.automation.pong", at: new Date().toISOString() });
    } catch (error) {
    }
  });
}

if (browser.runtime && browser.runtime.onConnect) {
  browser.runtime.onConnect.addListener(registerAutomationPort);
}

  if (browser.storage && browser.storage.onChanged) {
    browser.storage.onChanged.addListener(function (changes, areaName) {
      if (areaName !== "local" || !changes) {
        return;
      }
      if (changes[SEARCH_SETTINGS_KEY]) {
        searchSettingsCache = null;
        searchSettingsLoadPromise = null;
        logSearch("settings_invalidated", { source: "storage_change" });
      }
      if (changes[AUTOMATION_ENABLED_KEY]) {
        automationEnabledCache = null;
        automationEnabledPromise = null;
      }
    });
  }

registerActionClick();
loadSidecarState();

if (browser.tabs && browser.tabs.onActivated) {
  browser.tabs.onActivated.addListener(function (activeInfo) {
    if (!activeInfo || !isNumericId(activeInfo.tabId)) {
      return;
    }
    var windowId = isNumericId(activeInfo.windowId) ? activeInfo.windowId : null;
    syncStickySidecar(activeInfo.tabId, windowId);
  });
}

if (browser.tabs && browser.tabs.onUpdated) {
  browser.tabs.onUpdated.addListener(function (tabId, changeInfo, tab) {
    if (!changeInfo || changeInfo.status !== "complete") {
      return;
    }
    if (!tab || !tab.active) {
      return;
    }
    var windowId = isNumericId(tab.windowId) ? tab.windowId : null;
    syncStickySidecar(tabId, windowId);
  });
}

if (browser.windows && browser.windows.onRemoved) {
  browser.windows.onRemoved.addListener(function (windowId) {
    clearSidecarState(windowId);
    var keys = Object.keys(PANEL_STATE_BY_OWNER);
    for (var i = 0; i < keys.length; i += 1) {
      var state = PANEL_STATE_BY_OWNER[keys[i]];
      if (!state) {
        continue;
      }
      if (state.ownerWindowId === windowId) {
        if (isNumericId(state.panelWindowId) && state.panelWindowId !== windowId && browser.windows && browser.windows.remove) {
          var windowRemoval = browser.windows.remove(state.panelWindowId);
          if (windowRemoval && windowRemoval.catch) {
            windowRemoval.catch(function () {
            });
          }
        } else if (isNumericId(state.panelTabId) && browser.tabs && browser.tabs.remove) {
          var tabRemoval = browser.tabs.remove(state.panelTabId);
          if (tabRemoval && tabRemoval.catch) {
            tabRemoval.catch(function () {
            });
          }
        }
        clearPanelState(state.ownerWindowId);
        continue;
      }
      if (state.panelWindowId === windowId) {
        clearPanelState(state.ownerWindowId);
      }
    }
  });
}

if (browser.tabs && browser.tabs.onRemoved) {
  browser.tabs.onRemoved.addListener(function (tabId) {
    clearStickyRetry(tabId);
    var state = getPanelStateByTabId(tabId);
    if (state) {
      clearPanelState(state.ownerWindowId);
      return;
    }
    var keys = Object.keys(PANEL_STATE_BY_OWNER);
    for (var i = 0; i < keys.length; i += 1) {
      var entry = PANEL_STATE_BY_OWNER[keys[i]];
      if (entry && entry.attachedTabId === tabId) {
        entry.attachedTabId = null;
        setPanelState(entry.ownerWindowId, entry);
      }
    }
  });
}
