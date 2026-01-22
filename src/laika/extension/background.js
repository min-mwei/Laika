"use strict";

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
  "browser.select": true
};

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

async function handleObserve(options, sender, tabOverride) {
  var tabId = await resolveTargetTabId(sender, tabOverride);
  if (!isNumericId(tabId)) {
    return { status: "error", error: "no_active_tab" };
  }
  try {
    var result = await browser.tabs.sendMessage(tabId, { type: "laika.observe", options: options || {} });
    if (!result || typeof result.status === "undefined") {
      return { status: "error", error: "no_context" };
    }
    if (result && typeof result === "object") {
      result.tabId = tabId;
    }
    return result;
  } catch (error) {
    return { status: "error", error: "no_context" };
  }
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
    var result = await browser.tabs.sendMessage(tabId, { type: type, side: side });
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
    return { status: "error", error: "unsupported_tool" };
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
    return handleObserve(options, sender, tabOverride);
  }
  if (toolName === "browser.open_tab") {
    if (args && args.url) {
      var safeUrl = sanitizeOpenUrl(args.url);
      if (!safeUrl) {
        return { status: "error", error: "invalid_url" };
      }
      if (!browser.tabs || !browser.tabs.create) {
        return { status: "error", error: "tabs_unavailable" };
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
        return { status: "error", error: "open_tab_failed" };
      }
    }
    return { status: "error", error: "missing_url" };
  }

  var tabId = null;
  if (isNumericId(tabOverride)) {
    if (await tabExists(tabOverride)) {
      tabId = tabOverride;
    } else {
      return { status: "error", error: "no_target_tab" };
    }
  } else {
    tabId = await resolveTargetTabId(sender, null);
  }
  if (!isNumericId(tabId)) {
    return { status: "error", error: "no_active_tab" };
  }
  if (toolName === "browser.navigate") {
    if (!args || !args.url) {
      return { status: "error", error: "missing_url" };
    }
    var navigateUrl = sanitizeOpenUrl(args.url);
    if (!navigateUrl) {
      return { status: "error", error: "invalid_url" };
    }
    if (!browser.tabs || !browser.tabs.update) {
      return { status: "error", error: "tabs_unavailable" };
    }
    try {
      await browser.tabs.update(tabId, { url: navigateUrl });
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: "navigate_failed" };
    }
  }
  if (toolName === "browser.back") {
    if (!browser.tabs || !browser.tabs.goBack) {
      return { status: "error", error: "tabs_unavailable" };
    }
    try {
      await browser.tabs.goBack(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: "back_failed" };
    }
  }
  if (toolName === "browser.forward") {
    if (!browser.tabs || !browser.tabs.goForward) {
      return { status: "error", error: "tabs_unavailable" };
    }
    try {
      await browser.tabs.goForward(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: "forward_failed" };
    }
  }
  if (toolName === "browser.refresh") {
    if (!browser.tabs || !browser.tabs.reload) {
      return { status: "error", error: "tabs_unavailable" };
    }
    try {
      await browser.tabs.reload(tabId);
      return { status: "ok" };
    } catch (error) {
      return { status: "error", error: "refresh_failed" };
    }
  }
  try {
    return await browser.tabs.sendMessage(tabId, { type: "laika.tool", toolName: toolName, args: args || {} });
  } catch (error) {
    return { status: "error", error: "no_context" };
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

browser.runtime.onMessage.addListener(function (message, sender) {
  if (!message || !message.type) {
    return Promise.resolve({ status: "error", error: "invalid_message" });
  }
  if (message.type === "laika.observe") {
    return handleObserve(message.options, sender, message.tabId);
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
  return Promise.resolve({ status: "error", error: "unknown_type" });
});

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
